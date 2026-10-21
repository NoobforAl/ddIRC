//! Moving the bytes, once an offer has been agreed.
//!
//! A transfer is its own TCP connection with its own lifetime, and deliberately
//! not part of the connection actor's `select!` loop: a file takes minutes, the
//! IRC socket has to stay responsive throughout, and a stalled transfer must
//! never be able to ping-timeout the connection that negotiated it. So each one
//! runs as its own task and reports back over a channel, exactly as the actor
//! reports to the UI.
//!
//! # The address problem, answered
//!
//! [`super`] sets out the question this module had to settle: a normal DCC
//! offer names an address for the other side to dial, and in an app whose proxy
//! setting can be "route everything through Tor" that would be the file
//! transfer quietly undoing the setting. The answer implemented here is a
//! single rule — **a transfer discloses no more than the connection that
//! negotiated it** — which comes out as four cases:
//!
//! | | No proxy | Proxy configured |
//! |---|---|---|
//! | **Accepting** a normal offer | dial them directly | dial them **through the proxy** |
//! | **Accepting** a reverse offer | listen, and send our address back | **refused** — listening means disclosing where we are |
//! | **Sending** | listen, and offer our address | **refused** — see below |
//!
//! The two refusals are the important entries. Accepting a reverse offer from
//! behind Tor has no way to keep the promise, because the whole shape of it is
//! "tell me where you are and I will connect to you"; refusing with a reason
//! the user can read is far better than a transfer that works and silently
//! publishes their address.
//!
//! Sending from behind a proxy *has* an answer — a reverse offer of our own,
//! where they listen and we dial out through the proxy — and it is not built
//! yet: it needs a token round-trip, matching their reply against an offer we
//! made. [`serve_by_dialling`] is the half of it that exists. Until the rest
//! does, sending is refused rather than falling back to a direct offer,
//! because a fallback is precisely what this rule exists to prevent.
//!
//! There is no direct-connection fallback anywhere here, for the same reason
//! there is none on the IRC path: a proxy that cannot be reached is a transfer
//! that fails.

use std::io;
use std::io::SeekFrom;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use tokio::fs::{File, OpenOptions};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt, BufWriter};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_socks::tcp::Socks5Stream;

use crate::api::types::ProxyConfig;
use crate::dcc::offer::DccOffer;

/// How much is moved per read or write.
///
/// 64 KiB is large enough that the syscall overhead disappears against the
/// network, and small enough that progress moves visibly on a slow link rather
/// than jumping in quarter-megabyte steps.
const CHUNK: usize = 64 * 1024;

/// The largest file this will move, in either direction.
///
/// A ceiling rather than a judgement about what is reasonable to send. The
/// number in an offer is the sender's claim, and without a limit a hostile one
/// can ask us to fill a disk — so the cap is enforced against the bytes that
/// actually arrive, not against the claim.
pub const MAX_TRANSFER_BYTES: u64 = 4 * 1024 * 1024 * 1024;

/// How long to wait for the other side to appear.
///
/// Applies to dialling them and to waiting for them to dial us. Generous,
/// because a transfer may be crossing Tor; bounded, because an offer nobody
/// ever answers must not leave a listener open for the life of the app.
const RENDEZVOUS_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// How long to wait for a sender to answer a `DCC RESUME` before giving up on
/// resuming and fetching the whole file again.
///
/// Short, because the other side is a person's client that either understands
/// the request or does not, and one that does answers at once. A sender that
/// stays silent is one that does not support it, and the transfer should not
/// sit for minutes finding that out.
pub const RESUME_REPLY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// How long to go on reading acknowledgements after the last byte is sent.
///
/// Only about closing the connection politely once the file is delivered, so
/// seconds rather than minutes: the transfer has already succeeded by the time
/// this matters, and the only thing waiting longer buys is tidiness.
const ACK_DRAIN_GRACE: std::time::Duration = std::time::Duration::from_secs(5);

/// What went wrong, in terms the user can act on.
#[derive(Debug, thiserror::Error)]
pub enum TransferError {
    /// An incoming *reverse* offer while a proxy is configured. Accepting one
    /// means listening, and listening means telling the sender where we are.
    #[error(
        "this offer asks your client to accept a connection, which would tell \
         the sender your address and defeat the proxy. Ask them to send it \
         normally instead."
    )]
    WouldDiscloseAddress,

    /// Sending while a proxy is configured.
    ///
    /// Deliberately a separate error from the one above. They are refused for
    /// the same reason, but they are not the same situation, and a single
    /// message covering both describes the wrong one half the time — which is
    /// exactly what it did.
    #[error(
        "sending a file would publish your address, which is the thing the \
         proxy is there to hide. Send with the proxy off for this network, or \
         ask them to send to you instead."
    )]
    WouldDiscloseAddressBySending,

    #[error("the proxy refused the connection: {0}")]
    Proxy(String),

    #[error("nobody connected within {0} seconds")]
    NoRendezvous(u64),

    #[error("a file called '{0}' is already there")]
    AlreadyExists(String),

    #[error("the file is larger than the {0} GB limit")]
    TooLarge(u64),

    #[error("the sender stopped after {received} of {expected} bytes")]
    Truncated { received: u64, expected: u64 },

    #[error("cancelled")]
    Cancelled,

    #[error(
        "could not work out which address to give them. An offer has to name          one, and there is no safe guess."
    )]
    NoRoutableAddress,

    #[error("{0}")]
    Io(String),
}

impl From<io::Error> for TransferError {
    fn from(e: io::Error) -> Self {
        Self::Io(e.to_string())
    }
}

/// Progress, reported as it happens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransferEvent {
    /// The connection is up and bytes are about to move. For an outgoing
    /// transfer this is also the moment the other side accepted.
    Started { total: Option<u64> },
    /// Bytes moved so far. Emitted at most once per [`CHUNK`], and dropped
    /// rather than queued if the UI is behind — a progress number nobody read
    /// is worth nothing, and blocking here would stall the transfer itself.
    Progress { transferred: u64 },
}

/// Where a transfer should send its progress.
#[derive(Clone)]
pub struct Progress(mpsc::Sender<TransferEvent>);

impl Progress {
    pub fn new(sender: mpsc::Sender<TransferEvent>) -> Self {
        Self(sender)
    }

    fn send(&self, event: TransferEvent) {
        // Deliberately `try_send`. See `TransferEvent::Progress`.
        let _ = self.0.try_send(event);
    }
}

/// What a listening side ended up listening on.
///
/// The port is what goes into an offer; the address does not, because the
/// address in an offer is the *routable* one and a listener bound to `0.0.0.0`
/// does not know it. Deciding what to advertise is [`local_address`]'s job.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Listening {
    pub port: u16,
}

/// Where an unfinished download of [`filename`] is kept in [`destination`].
///
/// The name the file has while it is incomplete, so that nothing half-written
/// can be mistaken for the real thing — and the name a later attempt looks for
/// to carry on from. Just the offered name with `.part` after it: the one rule
/// that holds for a name with no extension too, which an extension-swapping
/// rule does not.
pub fn partial_path(destination: &Path, filename: &str) -> PathBuf {
    destination.join(format!("{filename}.part"))
}

/// How many bytes of [`filename`] are already here from an earlier attempt, if
/// there are any. `None` for no partial file, an empty one, or something that
/// is not a file.
pub async fn partial_len(destination: &Path, filename: &str) -> Option<u64> {
    let meta = tokio::fs::metadata(partial_path(destination, filename))
        .await
        .ok()?;
    (meta.is_file() && meta.len() > 0).then_some(meta.len())
}

/// The first line of a record kept beside a partial file. Anything that does
/// not start with it is not ours, and is neither read as one nor replaced.
const ORIGIN_MAGIC: &str = "ddirc-partial 1";

/// Where the record of who a partial file came from is kept: beside it.
pub fn origin_path(destination: &Path, filename: &str) -> PathBuf {
    destination.join(format!("{filename}.part.from"))
}

/// What the record says: who offered the file, and how big they said it was.
///
/// A partial file is a stranger's bytes, and resuming one means asking somebody
/// to send the rest of it. That is only meaningful if the rest belongs to the
/// same file — so a partial is carried on only for the person who started it, at
/// the size they gave. The nick is compared without regard to case, as IRC does.
fn origin_text(from: &str, size: u64) -> String {
    format!(
        "{ORIGIN_MAGIC}\nfrom={}\nsize={size}\n",
        from.to_ascii_lowercase()
    )
}

/// Whether [`path`] is a record this program wrote, judged by its first bytes
/// so that a large file somebody named the same thing is not read in full.
async fn is_origin_record(path: &Path) -> bool {
    use tokio::io::AsyncReadExt;
    let Ok(file) = tokio::fs::File::open(path).await else {
        return false;
    };
    let mut head = Vec::new();
    let _ = file
        .take(ORIGIN_MAGIC.len() as u64)
        .read_to_end(&mut head)
        .await;
    head == ORIGIN_MAGIC.as_bytes()
}

/// Note who a partial file is from. Best effort, and never over something that
/// is not a record of ours: a file that merely has the same name is somebody's
/// download, and nothing here overwrites those. Without a record a partial file
/// is simply never resumed, which is the safe way to fail.
async fn write_origin(destination: &Path, filename: &str, from: &str, size: u64) {
    let path = origin_path(destination, filename);
    if tokio::fs::try_exists(&path).await.unwrap_or(false) && !is_origin_record(&path).await {
        return;
    }
    let _ = tokio::fs::write(&path, origin_text(from, size)).await;
}

/// Forget the record, if it is ours to forget.
async fn remove_origin(destination: &Path, filename: &str) {
    let path = origin_path(destination, filename);
    if is_origin_record(&path).await {
        let _ = tokio::fs::remove_file(&path).await;
    }
}

/// How much of [`filename`] is here from an earlier attempt *by [`from`] at
/// this [`size`]*, or `None` — including when there is a partial file that
/// someone else started, or one with no record at all.
pub async fn resumable_len(
    destination: &Path,
    filename: &str,
    from: &str,
    size: u64,
) -> Option<u64> {
    use tokio::io::AsyncReadExt;
    let expected = origin_text(from, size);
    let file = tokio::fs::File::open(origin_path(destination, filename))
        .await
        .ok()?;
    let mut record = Vec::new();
    // One byte more than expected, so a longer record cannot pass as equal.
    file.take(expected.len() as u64 + 1)
        .read_to_end(&mut record)
        .await
        .ok()?;
    if record != expected.as_bytes() {
        return None;
    }
    partial_len(destination, filename).await
}

/// Accept an offer: connect, and write what arrives to [`destination`].
///
/// Only ever a *normal* offer. A reverse one is refused before this is reached
/// when a proxy is configured, and handled by [`serve`] when one is not.
///
/// The file is written under a `.part` name and renamed once it is whole, so a
/// transfer that fails halfway cannot be mistaken for the file it was going to
/// be. Nothing overwrites: a name already taken is an error, never a silent
/// replacement of something the user already had.
///
/// # Resuming
///
/// [`start_at`] is how many bytes of the file the sender has agreed to skip:
/// the transfer carries on after that point in the existing `.part` file
/// instead of beginning again. It is taken on trust from nobody — the caller
/// passes only what it negotiated with the sender, and it is checked here
/// against the file actually on disk, the size actually offered, and *who
/// started that partial file* ([`from`], against the record kept beside it), so
/// a number that does not fit any of them is treated as zero and the file is
/// fetched whole.
///
/// A transfer that fails part-way leaves its `.part` file where it is, which is
/// what makes resuming possible. One the user *cancelled* does not: stopping a
/// download is a decision to be rid of it, and an unfinished copy of something
/// the user turned away has no business staying. Nor does one that broke the
/// size limit, which is a sender misbehaving rather than a connection dropping.
/// And one whose size was never given is not kept either, as it could not be
/// resumed.
pub async fn accept(
    offer: &DccOffer,
    destination: &Path,
    from: &str,
    proxy: Option<&ProxyConfig>,
    start_at: u64,
    progress: Progress,
    cancel: &mut mpsc::Receiver<()>,
) -> Result<PathBuf, TransferError> {
    if offer.is_reverse() && proxy.is_some() {
        return Err(TransferError::WouldDiscloseAddress);
    }
    let (Some(addr), Some(port)) = (offer.addr, offer.port) else {
        return Err(TransferError::WouldDiscloseAddress);
    };
    if offer.size.is_some_and(|size| size > MAX_TRANSFER_BYTES) {
        return Err(TransferError::TooLarge(
            MAX_TRANSFER_BYTES / (1024 * 1024 * 1024),
        ));
    }

    let path = destination.join(&offer.filename);
    if tokio::fs::try_exists(&path).await.unwrap_or(false) {
        return Err(TransferError::AlreadyExists(offer.filename.clone()));
    }
    let partial = partial_path(destination, &offer.filename);

    // Only a point inside the file, and only bytes we really have.
    let on_disk = match offer.size {
        Some(size) => resumable_len(destination, &offer.filename, from, size)
            .await
            .unwrap_or(0),
        None => 0,
    };
    let start_at = match offer.size {
        Some(size) if start_at > 0 && start_at < size && start_at <= on_disk => start_at,
        _ => 0,
    };

    let stream = dial(SocketAddr::new(addr, port), proxy).await?;
    progress.send(TransferEvent::Started { total: offer.size });

    // From here the partial file is this attempt's, so the record says so.
    match offer.size {
        Some(size) => write_origin(destination, &offer.filename, from, size).await,
        None => remove_origin(destination, &offer.filename).await,
    }

    let result = receive_into(stream, &partial, offer.size, start_at, &progress, cancel).await;
    match result {
        Ok(()) => {
            tokio::fs::rename(&partial, &path).await?;
            remove_origin(destination, &offer.filename).await;
            Ok(path)
        }
        Err(e) => {
            // Kept when the connection simply went away, so that it can be
            // carried on; removed when the user stopped it or the sender broke
            // the size limit, and when nothing was written at all. See the note
            // on this function.
            let keep = offer.size.is_some()
                && !matches!(e, TransferError::Cancelled | TransferError::TooLarge(_))
                && partial_len(destination, &offer.filename).await.is_some();
            if !keep {
                let _ = tokio::fs::remove_file(&partial).await;
                remove_origin(destination, &offer.filename).await;
            }
            Err(e)
        }
    }
}

/// Offer a file: listen, wait for them to dial, and send it.
///
/// Returns the port that was bound, so the caller can put it in the offer,
/// paired with the future that actually serves the file. The two are separate
/// because the offer cannot be sent until the port is known, and the file
/// cannot be served until the offer has been sent.
pub async fn listen() -> Result<(TcpListener, Listening), TransferError> {
    // Port 0 asks the operating system for a free one. Binding to all
    // interfaces rather than loopback, because the point is to be reachable;
    // what is *advertised* is a separate decision, made by the caller.
    let listener = TcpListener::bind((IpAddr::from([0, 0, 0, 0]), 0)).await?;
    let port = listener.local_addr()?.port();
    Ok((listener, Listening { port }))
}

/// Serve [`path`] to whoever connects to [`listener`] first.
///
/// [`offset`] is where in the file to begin, and is read *after* the connection
/// arrives, not before. A receiver that asks to resume says so first and only
/// then connects, so the actor that hears the request has until that moment to
/// set it; one that asks for nothing leaves it at zero and gets the whole file.
pub async fn serve(
    listener: TcpListener,
    path: &Path,
    offset: Arc<AtomicU64>,
    progress: Progress,
    cancel: &mut mpsc::Receiver<()>,
) -> Result<u64, TransferError> {
    let accepted = tokio::time::timeout(RENDEZVOUS_TIMEOUT, listener.accept()).await;
    let stream = match accepted {
        Ok(Ok((stream, _peer))) => stream,
        Ok(Err(e)) => return Err(e.into()),
        Err(_) => return Err(TransferError::NoRendezvous(RENDEZVOUS_TIMEOUT.as_secs())),
    };
    send_from(
        stream,
        path,
        offset.load(Ordering::Acquire),
        &progress,
        cancel,
    )
    .await
}

/// Serve [`path`] by dialling *them* — the sending half of a reverse offer.
///
/// This is what a sender behind a proxy does: they listened, they told us
/// where, and we connect out through the proxy. No address of ours is
/// disclosed, which is the entire point of the arrangement.
pub async fn serve_by_dialling(
    addr: SocketAddr,
    path: &Path,
    proxy: Option<&ProxyConfig>,
    progress: Progress,
    cancel: &mut mpsc::Receiver<()>,
) -> Result<u64, TransferError> {
    let stream = dial(addr, proxy).await?;
    // From the start: resuming a reverse transfer is not supported, so there is
    // nobody who could have asked to begin anywhere else.
    send_from(stream, path, 0, &progress, cancel).await
}

/// Open a TCP connection, through the proxy when there is one.
///
/// The absence of a direct fallback is the point: if a proxy is configured and
/// cannot be reached, this fails. Dialling direct instead would defeat the one
/// thing a proxy is for, at exactly the moment it mattered most.
async fn dial(addr: SocketAddr, proxy: Option<&ProxyConfig>) -> Result<TcpStream, TransferError> {
    let connect = async {
        match proxy {
            None => TcpStream::connect(addr).await.map_err(TransferError::from),
            Some(proxy) => {
                let via = (proxy.host.as_str(), proxy.port);
                let stream = match (&proxy.username, &proxy.password) {
                    (Some(user), Some(password)) => {
                        Socks5Stream::connect_with_password(via, addr, user, password).await
                    }
                    _ => Socks5Stream::connect(via, addr).await,
                }
                .map_err(|e| TransferError::Proxy(e.to_string()))?;
                Ok(stream.into_inner())
            }
        }
    };

    match tokio::time::timeout(RENDEZVOUS_TIMEOUT, connect).await {
        Ok(result) => result,
        Err(_) => Err(TransferError::NoRendezvous(RENDEZVOUS_TIMEOUT.as_secs())),
    }
}

/// Treat an abrupt hang-up as the end of the stream rather than as a failure.
///
/// A peer that closes without a shutdown gives POSIX a clean zero-length read
/// and Windows a `ConnectionAborted` — the same event, reported as success on
/// one platform and as an error on the other. Without this the *ordinary* case
/// of a sender that finishes and hangs up promptly would fail on Windows with
/// "an established connection was aborted", and a genuinely short transfer
/// would be reported as an I/O fault rather than as the truncation it is.
///
/// Whether the bytes were all there is decided by counting them, which is the
/// only trustworthy test either way.
fn end_of_stream(read: io::Result<usize>) -> io::Result<usize> {
    match read {
        Err(e)
            if matches!(
                e.kind(),
                io::ErrorKind::ConnectionReset
                    | io::ErrorKind::ConnectionAborted
                    | io::ErrorKind::BrokenPipe
                    | io::ErrorKind::UnexpectedEof
            ) =>
        {
            Ok(0)
        }
        other => other,
    }
}

/// Read the stream into a file, acknowledging as DCC expects.
///
/// [`start_at`] bytes are already in the file: it is opened where they end and
/// everything that arrives is added after them. Counts, acknowledgements and
/// progress are all *positions in the whole file* from then on, which is what a
/// sender that was asked to resume expects to be told.
async fn receive_into(
    mut stream: TcpStream,
    path: &Path,
    expected: Option<u64>,
    start_at: u64,
    progress: &Progress,
    cancel: &mut mpsc::Receiver<()>,
) -> Result<(), TransferError> {
    let raw = if start_at > 0 {
        // Cut to exactly the agreed point first: the file may hold more than
        // was agreed (a transfer that died after the last full write), and
        // anything beyond it is not something the sender is going to resend.
        let mut file = OpenOptions::new().write(true).open(path).await?;
        file.set_len(start_at).await?;
        file.seek(SeekFrom::Start(start_at)).await?;
        file
    } else {
        File::create(path).await?
    };
    let mut file = BufWriter::new(raw);
    let mut buffer = vec![0u8; CHUNK];
    let mut received: u64 = start_at;
    if start_at > 0 {
        // So the ring starts where the file already is, not at nothing.
        progress.send(TransferEvent::Progress {
            transferred: start_at,
        });
    }

    loop {
        // `Some(())` rather than `_`: a cancel channel whose sender has been
        // dropped yields `None` for ever, and matching that as a cancellation
        // would abort every transfer the instant nobody was holding the other
        // end. An unmatched pattern disables the branch instead, which is
        // exactly "there is no way to cancel this one".
        let read = tokio::select! {
            biased;
            Some(()) = cancel.recv() => return Err(TransferError::Cancelled),
            read = stream.read(&mut buffer) => end_of_stream(read)?,
        };
        if read == 0 {
            break;
        }

        received = received.saturating_add(read as u64);
        // Checked against what arrived rather than against what was promised:
        // the size in an offer is the sender's claim, and a hostile sender's
        // claim of "small" must not become permission to write for ever.
        if received > MAX_TRANSFER_BYTES {
            return Err(TransferError::TooLarge(
                MAX_TRANSFER_BYTES / (1024 * 1024 * 1024),
            ));
        }

        file.write_all(&buffer[..read]).await?;

        // Classic DCC acknowledges with the running total as a big-endian
        // u32. Modern senders ignore it and stream ahead; older ones wait for
        // it and would stall without it. Sending it costs four bytes and is
        // the difference between working with old clients and not.
        let ack = (received as u32).to_be_bytes();
        if stream.write_all(&ack).await.is_err() {
            // A sender that has closed its read half is not an error — plenty
            // do, having sent everything they intended to.
        }

        progress.send(TransferEvent::Progress {
            transferred: received,
        });

        if expected.is_some_and(|total| received >= total) {
            break;
        }
    }

    file.flush().await?;

    if let Some(total) = expected {
        if received < total {
            return Err(TransferError::Truncated {
                received,
                expected: total,
            });
        }
    }
    Ok(())
}

/// Write a file to the stream, draining acknowledgements as they arrive.
///
/// Begins [`start`] bytes in. A point outside the file means the request that
/// set it was wrong, and the whole file is sent instead: more than was asked
/// for is a transfer that works, where less than nothing is not.
async fn send_from(
    stream: TcpStream,
    path: &Path,
    start: u64,
    progress: &Progress,
    cancel: &mut mpsc::Receiver<()>,
) -> Result<u64, TransferError> {
    let mut file = File::open(path).await?;
    let total = file.metadata().await?.len();
    if total > MAX_TRANSFER_BYTES {
        return Err(TransferError::TooLarge(
            MAX_TRANSFER_BYTES / (1024 * 1024 * 1024),
        ));
    }
    let start = if start < total { start } else { 0 };
    if start > 0 {
        file.seek(SeekFrom::Start(start)).await?;
    }

    progress.send(TransferEvent::Started { total: Some(total) });
    if start > 0 {
        progress.send(TransferEvent::Progress { transferred: start });
    }

    // Split so acknowledgements can be drained while writing. They are not
    // waited for — that is what makes this "send ahead" rather than lockstep —
    // but they must be read, or the receiver's writes eventually fill their
    // send buffer and the transfer deadlocks with both sides blocked.
    let (mut reader, mut writer) = tokio::io::split(stream);
    let drain = tokio::spawn(async move {
        let mut sink = [0u8; 64];
        while reader.read(&mut sink).await.unwrap_or(0) > 0 {}
    });

    let mut buffer = vec![0u8; CHUNK];
    let mut sent: u64 = start;
    let result = async {
        loop {
            // See the note in `receive_into`: `Some(())`, never `_`.
            let read = tokio::select! {
                biased;
                Some(()) = cancel.recv() => return Err(TransferError::Cancelled),
                read = file.read(&mut buffer) => read?,
            };
            if read == 0 {
                break;
            }
            writer.write_all(&buffer[..read]).await?;
            sent = sent.saturating_add(read as u64);
            progress.send(TransferEvent::Progress { transferred: sent });
        }
        writer.flush().await?;
        // Half-close, and it is load-bearing rather than tidiness.
        //
        // Without it, returning from here drops the socket while the
        // receiver's acknowledgements are still sitting unread in our receive
        // buffer — and closing a TCP socket with unread data is an *abortive*
        // close. Windows sends an RST, which throws away whatever is still in
        // our send buffer: the tail of the file, silently, on a transfer that
        // reported success. It cost the last 17 bytes of a 131,089-byte file
        // often enough to be a flaky test and rarely enough to look like one.
        //
        // A shutdown sends FIN instead, so the receiver reads every byte and
        // then sees a clean end of stream.
        writer.shutdown().await?;
        Ok(sent)
    }
    .await;

    match &result {
        // Now let the acknowledgements finish arriving. The drain ends by
        // itself when the receiver closes its side; the timeout is only so a
        // peer that never does cannot hold the task open for ever.
        Ok(_) => {
            let _ = tokio::time::timeout(ACK_DRAIN_GRACE, drain).await;
        }
        // Cancelled or failed: there is nothing left worth delivering, and
        // waiting would make stopping feel like hanging.
        Err(_) => drain.abort(),
    }
    result
}

/// The address to advertise in an offer, as DCC's 32-bit integer form.
///
/// DCC predates IPv6 and writes the address as a decimal `u32`, which is why
/// this returns a number rather than a string. IPv6 has no place in that
/// format, so an offer cannot be made from an IPv6-only host — reported rather
/// than silently sent as something the other side would misread.
pub fn dcc_address(addr: IpAddr) -> Option<u32> {
    match addr {
        IpAddr::V4(v4) => Some(u32::from(v4)),
        IpAddr::V6(_) => None,
    }
}

/// The address to put in an offer, in DCC's integer form.
///
/// Asked of the routing table rather than guessed: a machine with a VPN, a
/// container bridge and a wireless card has several addresses and only one of
/// them reaches the person we are talking to. Connecting a UDP socket sends no
/// packet — it only asks the kernel which local address it *would* use for that
/// destination — so this costs nothing and needs no network to be up.
///
/// [`None`] when there is no answer, which is the honest outcome for an
/// IPv6-only host: DCC's address field has no room for one, and an offer that
/// named a truncated address would fail in a way nobody could diagnose.
pub async fn routable_address(peer_host: &str) -> Option<u32> {
    // Port 0 is fine for a connected UDP socket: nothing is ever sent, and the
    // routing decision does not depend on it.
    let socket = tokio::net::UdpSocket::bind((IpAddr::from([0, 0, 0, 0]), 0))
        .await
        .ok()?;
    socket.connect((peer_host, 9)).await.ok()?;
    dcc_address(socket.local_addr().ok()?.ip())
}

/// Render a filename for the offer line.
///
/// DCC separates its fields with spaces, so a name containing one has to be
/// quoted or the receiver reads the rest of the name as an address. Quotes are
/// stripped rather than escaped — the protocol has no escape, and
/// [`super::offer::safe_filename`] is what the other end will run on it anyway.
pub fn quote_filename(name: &str) -> String {
    let cleaned: String = name.chars().filter(|c| *c != '"').collect();
    if cleaned.contains(' ') {
        format!("\"{cleaned}\"")
    } else {
        cleaned
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn progress() -> (Progress, mpsc::Receiver<TransferEvent>) {
        let (tx, rx) = mpsc::channel(64);
        (Progress::new(tx), rx)
    }

    fn never_cancelled() -> mpsc::Receiver<()> {
        let (_tx, rx) = mpsc::channel(1);
        rx
    }

    #[test]
    fn an_ipv4_address_becomes_dccs_integer_form() {
        assert_eq!(dcc_address("127.0.0.1".parse().unwrap()), Some(2130706433));
        assert_eq!(dcc_address("0.0.0.0".parse().unwrap()), Some(0));
    }

    #[test]
    fn ipv6_has_no_place_in_that_format_and_says_so() {
        assert_eq!(dcc_address("::1".parse().unwrap()), None);
    }

    /// The refusal that keeps the promise. A reverse offer asks us to listen,
    /// which means telling the sender where we are — so behind a proxy it is
    /// declined rather than quietly performed.
    #[tokio::test]
    async fn a_reverse_offer_behind_a_proxy_is_refused() {
        let offer = DccOffer {
            filename: "cat.jpg".to_owned(),
            addr: None,
            port: None,
            size: Some(10),
            token: Some(7),
        };
        let proxy = ProxyConfig {
            host: "127.0.0.1".to_owned(),
            port: 9050,
            ..Default::default()
        };
        let (progress, _rx) = progress();
        let dir = std::env::temp_dir();

        let error = accept(
            &offer,
            &dir,
            "alice",
            Some(&proxy),
            0,
            progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap_err();

        assert!(matches!(error, TransferError::WouldDiscloseAddress));
    }

    #[tokio::test]
    async fn an_offer_claiming_more_than_the_cap_is_refused_before_connecting() {
        let offer = DccOffer {
            filename: "huge.bin".to_owned(),
            addr: Some("127.0.0.1".parse().unwrap()),
            port: Some(1),
            size: Some(MAX_TRANSFER_BYTES + 1),
            token: None,
        };
        let (progress, _rx) = progress();

        let error = accept(
            &offer,
            &std::env::temp_dir(),
            "alice",
            None,
            0,
            progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap_err();

        assert!(matches!(error, TransferError::TooLarge(_)));
    }

    /// End to end over loopback: one side serves a file, the other accepts the
    /// offer, and the bytes arrive intact under the right name.
    #[tokio::test]
    async fn a_file_survives_the_round_trip() {
        let dir = tempdir();
        let source = dir.join("source.bin");
        // Larger than one chunk, so the loop runs more than once and the
        // acknowledgement path is exercised rather than skipped.
        let contents: Vec<u8> = (0..(CHUNK * 2 + 17)).map(|i| (i % 251) as u8).collect();
        tokio::fs::write(&source, &contents).await.unwrap();

        let (listener, listening) = listen().await.unwrap();
        let (send_progress, _sp) = progress();
        let serving = tokio::spawn(async move {
            serve(
                listener,
                &source,
                Arc::new(AtomicU64::new(0)),
                send_progress,
                &mut never_cancelled(),
            )
            .await
        });

        let inbox = dir.join("in");
        tokio::fs::create_dir_all(&inbox).await.unwrap();
        let offer = DccOffer {
            filename: "arrived.bin".to_owned(),
            addr: Some("127.0.0.1".parse().unwrap()),
            port: Some(listening.port),
            size: Some(contents.len() as u64),
            token: None,
        };
        let (recv_progress, mut events) = progress();

        let path = accept(
            &offer,
            &inbox,
            "alice",
            None,
            0,
            recv_progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap();

        assert_eq!(serving.await.unwrap().unwrap(), contents.len() as u64);
        assert_eq!(path, inbox.join("arrived.bin"));
        assert_eq!(tokio::fs::read(&path).await.unwrap(), contents);

        // And nothing is left behind under the partial name.
        let leftovers: Vec<_> = std::fs::read_dir(&inbox)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(leftovers, vec!["arrived.bin".to_owned()]);

        let mut saw_started = false;
        let mut last = 0;
        while let Ok(event) = events.try_recv() {
            match event {
                TransferEvent::Started { total } => {
                    saw_started = true;
                    assert_eq!(total, Some(contents.len() as u64));
                }
                TransferEvent::Progress { transferred } => last = transferred,
            }
        }
        assert!(saw_started, "the receiver announced the start");
        assert_eq!(last, contents.len() as u64);
    }

    /// Nothing is overwritten. A name already taken is an error, because a
    /// stranger choosing a filename must never be able to replace a file the
    /// user already had.
    #[tokio::test]
    async fn an_existing_file_is_never_replaced() {
        let dir = tempdir();
        tokio::fs::write(dir.join("taken.txt"), b"mine")
            .await
            .unwrap();

        let offer = DccOffer {
            filename: "taken.txt".to_owned(),
            addr: Some("127.0.0.1".parse().unwrap()),
            port: Some(1),
            size: Some(4),
            token: None,
        };
        let (progress, _rx) = progress();

        let error = accept(
            &offer,
            &dir,
            "alice",
            None,
            0,
            progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap_err();

        assert!(matches!(error, TransferError::AlreadyExists(name) if name == "taken.txt"));
        assert_eq!(
            tokio::fs::read(dir.join("taken.txt")).await.unwrap(),
            b"mine"
        );
    }

    /// A sender that stops early leaves no file behind under the real name — but
    /// does keep what did arrive, under the partial name, so it can be resumed.
    #[tokio::test]
    async fn a_truncated_transfer_is_reported_and_keeps_its_partial_file() {
        let dir = tempdir();
        let (listener, listening) = listen().await.unwrap();

        // Serves four bytes and hangs up, having promised a hundred.
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let _ = stream.write_all(b"stop").await;
                let _ = stream.shutdown().await;
            }
        });

        let offer = DccOffer {
            filename: "half.bin".to_owned(),
            addr: Some("127.0.0.1".parse().unwrap()),
            port: Some(listening.port),
            size: Some(100),
            token: None,
        };
        let (progress, _rx) = progress();

        let error = accept(
            &offer,
            &dir,
            "alice",
            None,
            0,
            progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap_err();

        assert!(
            matches!(
                error,
                TransferError::Truncated {
                    received: 4,
                    expected: 100
                }
            ),
            "expected a truncation, got {error:?}"
        );
        assert!(
            !dir.join("half.bin").exists(),
            "no file under the real name"
        );
        // What did arrive is kept, under a name nothing could mistake for the
        // finished file, because that is what a resume starts from.
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        let mut leftovers = leftovers;
        leftovers.sort();
        assert_eq!(
            leftovers,
            vec!["half.bin.part".to_owned(), "half.bin.part.from".to_owned()]
        );
        assert_eq!(std::fs::read(dir.join("half.bin.part")).unwrap(), b"stop");
    }

    #[test]
    fn the_partial_name_is_the_offered_name_with_part_after_it() {
        let dir = Path::new("inbox");
        assert_eq!(partial_path(dir, "cat.jpg"), dir.join("cat.jpg.part"));
        assert_eq!(partial_path(dir, "a.tar.gz"), dir.join("a.tar.gz.part"));
        // The case a rule that swaps the extension gets wrong: nothing to swap.
        assert_eq!(partial_path(dir, "README"), dir.join("README.part"));
    }

    /// The record a real attempt would have left beside a partial file.
    async fn leave_origin(inbox: &Path, name: &str, from: &str, size: usize) {
        tokio::fs::write(origin_path(inbox, name), origin_text(from, size as u64))
            .await
            .unwrap();
    }

    /// A deterministic body, long enough to span several chunks, and not a
    /// repeating pattern a wrong offset could still match.
    fn body(len: usize) -> Vec<u8> {
        (0..len)
            .map(|i| ((i * 7919 + i / 251) % 256) as u8)
            .collect()
    }

    fn offering(name: &str, port: u16, size: usize) -> DccOffer {
        DccOffer {
            filename: name.to_owned(),
            addr: Some("127.0.0.1".parse().unwrap()),
            port: Some(port),
            size: Some(size as u64),
            token: None,
        }
    }

    /// Serve [`contents`] from [`offset`] and return the port to dial.
    async fn serving_from(
        dir: &Path,
        contents: &[u8],
        offset: u64,
    ) -> (u16, tokio::task::JoinHandle<Result<u64, TransferError>>) {
        let source = dir.join("source.bin");
        tokio::fs::write(&source, contents).await.unwrap();
        let (listener, listening) = listen().await.unwrap();
        let handle = tokio::spawn(async move {
            let (sp, _rx) = progress();
            serve(
                listener,
                &source,
                Arc::new(AtomicU64::new(offset)),
                sp,
                &mut never_cancelled(),
            )
            .await
        });
        (listening.port, handle)
    }

    /// The point of the feature: carry on from the bytes already here, and end
    /// with exactly the file that was offered.
    #[tokio::test]
    async fn a_download_carries_on_from_its_partial_file() {
        let dir = tempdir();
        let inbox = dir.join("in");
        tokio::fs::create_dir_all(&inbox).await.unwrap();
        let contents = body(CHUNK * 3 + 123);
        let have = CHUNK + 500;
        tokio::fs::write(partial_path(&inbox, "big.bin"), &contents[..have])
            .await
            .unwrap();
        leave_origin(&inbox, "big.bin", "alice", contents.len()).await;

        let (port, serving) = serving_from(&dir, &contents, have as u64).await;
        let (recv_progress, mut events) = progress();
        let path = accept(
            &offering("big.bin", port, contents.len()),
            &inbox,
            "alice",
            None,
            have as u64,
            recv_progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap();

        assert_eq!(tokio::fs::read(&path).await.unwrap(), contents);
        assert_eq!(serving.await.unwrap().unwrap(), contents.len() as u64);
        assert!(!partial_path(&inbox, "big.bin").exists(), "renamed away");

        // Progress is a position in the whole file: it starts where the file
        // already was and never reports less than that.
        let mut positions = Vec::new();
        while let Ok(event) = events.try_recv() {
            if let TransferEvent::Progress { transferred } = event {
                positions.push(transferred);
            }
        }
        assert_eq!(positions.first().copied(), Some(have as u64));
        assert!(positions.iter().all(|p| *p >= have as u64));
        assert_eq!(positions.last().copied(), Some(contents.len() as u64));
    }

    /// Bytes beyond the agreed point are not something the sender will resend,
    /// so they must not survive into the finished file.
    #[tokio::test]
    async fn a_partial_file_longer_than_the_agreed_point_is_cut_back() {
        let dir = tempdir();
        let inbox = dir.join("in");
        tokio::fs::create_dir_all(&inbox).await.unwrap();
        let contents = body(CHUNK * 2 + 9);
        let agreed = 1000usize;
        // Right up to the agreed point, then garbage a failed write left behind.
        let mut partial = contents[..agreed].to_vec();
        partial.extend(std::iter::repeat_n(0xEE, 5000));
        tokio::fs::write(partial_path(&inbox, "cut.bin"), &partial)
            .await
            .unwrap();
        leave_origin(&inbox, "cut.bin", "alice", contents.len()).await;

        let (port, serving) = serving_from(&dir, &contents, agreed as u64).await;
        let (progress, _rx) = progress();
        let path = accept(
            &offering("cut.bin", port, contents.len()),
            &inbox,
            "alice",
            None,
            agreed as u64,
            progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap();

        assert_eq!(tokio::fs::read(&path).await.unwrap(), contents);
        serving.await.unwrap().unwrap();
    }

    /// A resume point is checked against what is really on disk and what was
    /// really offered. One that fits neither is no resume point.
    #[tokio::test]
    async fn a_resume_point_that_does_not_fit_means_the_whole_file() {
        let contents = body(5000);

        for (label, partial_len, start_at) in [
            ("more than the file holds", 10usize, 2000u64),
            ("no partial file at all", 0, 2000),
            ("past the end of the offer", 3000, 6000),
            ("exactly the end", 3000, 5000),
        ] {
            let dir = tempdir();
            let inbox = dir.join("in");
            tokio::fs::create_dir_all(&inbox).await.unwrap();
            if partial_len > 0 {
                tokio::fs::write(partial_path(&inbox, "f.bin"), &contents[..partial_len])
                    .await
                    .unwrap();
                leave_origin(&inbox, "f.bin", "alice", contents.len()).await;
            }

            // The sender, who was never told to skip anything, sends it all.
            let (port, serving) = serving_from(&dir, &contents, 0).await;
            let (progress, _rx) = progress();
            let path = accept(
                &offering("f.bin", port, contents.len()),
                &inbox,
                "alice",
                None,
                start_at,
                progress,
                &mut never_cancelled(),
            )
            .await
            .unwrap_or_else(|e| panic!("{label}: {e:?}"));

            assert_eq!(tokio::fs::read(&path).await.unwrap(), contents, "{label}");
            serving.await.unwrap().unwrap();
        }
    }

    /// The app reads this record too, to say "already here" on the card before
    /// anything is accepted, and has its own copy of the text. They must agree.
    #[test]
    fn the_record_is_the_text_the_app_expects() {
        assert_eq!(
            origin_text("Alice", 5000),
            "ddirc-partial 1
from=alice
size=5000
"
        );
    }

    /// Resuming splices two files together if the partial one belongs to a
    /// different offer, so it is only done for the person who started it, at
    /// the size they gave.
    #[tokio::test]
    async fn a_partial_file_is_only_resumable_for_who_started_it() {
        let dir = tempdir();
        let inbox = dir.join("in");
        tokio::fs::create_dir_all(&inbox).await.unwrap();
        tokio::fs::write(partial_path(&inbox, "a.bin"), b"12345")
            .await
            .unwrap();

        assert_eq!(
            resumable_len(&inbox, "a.bin", "alice", 100).await,
            None,
            "no record, so nobody"
        );

        leave_origin(&inbox, "a.bin", "alice", 100).await;
        assert_eq!(resumable_len(&inbox, "a.bin", "alice", 100).await, Some(5));
        assert_eq!(
            resumable_len(&inbox, "a.bin", "ALICE", 100).await,
            Some(5),
            "nicks are compared without case"
        );
        assert_eq!(resumable_len(&inbox, "a.bin", "mallory", 100).await, None);
        assert_eq!(resumable_len(&inbox, "a.bin", "alice", 101).await, None);
        assert_eq!(resumable_len(&inbox, "b.bin", "alice", 100).await, None);

        // A record that merely starts like ours is not ours.
        tokio::fs::write(
            origin_path(&inbox, "a.bin"),
            format!("{}extra", origin_text("alice", 100)),
        )
        .await
        .unwrap();
        assert_eq!(resumable_len(&inbox, "a.bin", "alice", 100).await, None);
    }

    /// The same, end to end: a partial file somebody else started is not carried
    /// on, however plausible the position the sender agrees to.
    #[tokio::test]
    async fn a_download_from_someone_else_starts_over() {
        let dir = tempdir();
        let inbox = dir.join("in");
        tokio::fs::create_dir_all(&inbox).await.unwrap();
        let contents = body(CHUNK * 2 + 77);
        let have = CHUNK;
        // Alice's bytes — different from what mallory is about to send, so a
        // splice would show.
        tokio::fs::write(partial_path(&inbox, "x.bin"), vec![0xAA; have])
            .await
            .unwrap();
        leave_origin(&inbox, "x.bin", "alice", contents.len()).await;

        // Mallory was never asked to skip anything, so sends all of it.
        let (port, serving) = serving_from(&dir, &contents, 0).await;
        let (progress, _rx) = progress();
        let path = accept(
            &offering("x.bin", port, contents.len()),
            &inbox,
            "mallory",
            None,
            have as u64,
            progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap();

        assert_eq!(
            tokio::fs::read(&path).await.unwrap(),
            contents,
            "all of it from mallory, none of it from the old partial file"
        );
        serving.await.unwrap().unwrap();
    }

    /// What a download leaves behind, and what it takes away.
    #[tokio::test]
    async fn the_record_lives_as_long_as_the_partial_file() {
        let dir = tempdir();
        let inbox = dir.join("in");
        tokio::fs::create_dir_all(&inbox).await.unwrap();
        let contents = body(CHUNK * 2);

        // A connection that dies leaves both, so a resume can be checked.
        let (port, handle) = {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let cut = contents[..CHUNK].to_vec();
            let handle = tokio::spawn(async move {
                let (mut s, _) = listener.accept().await.unwrap();
                s.write_all(&cut).await.unwrap();
                s.shutdown().await.unwrap();
                let mut rest = Vec::new();
                let _ = s.read_to_end(&mut rest).await;
            });
            (port, handle)
        };
        let (progress1, _rx1) = progress();
        accept(
            &offering("r.bin", port, contents.len()),
            &inbox,
            "alice",
            None,
            0,
            progress1,
            &mut never_cancelled(),
        )
        .await
        .unwrap_err();
        handle.await.unwrap();
        assert_eq!(
            resumable_len(&inbox, "r.bin", "alice", contents.len() as u64).await,
            Some(CHUNK as u64)
        );

        // Finishing it takes both away.
        let (port, serving) = serving_from(&dir, &contents, CHUNK as u64).await;
        let (progress2, _rx2) = progress();
        accept(
            &offering("r.bin", port, contents.len()),
            &inbox,
            "alice",
            None,
            CHUNK as u64,
            progress2,
            &mut never_cancelled(),
        )
        .await
        .unwrap();
        serving.await.unwrap().unwrap();
        assert!(!origin_path(&inbox, "r.bin").exists());
        assert!(!partial_path(&inbox, "r.bin").exists());
    }

    /// Nothing here overwrites a file the user already has — including one that
    /// happens to be named like a record.
    #[tokio::test]
    async fn a_file_named_like_a_record_is_left_alone() {
        let dir = tempdir();
        let inbox = dir.join("in");
        tokio::fs::create_dir_all(&inbox).await.unwrap();
        let contents = body(CHUNK + 9);
        let theirs = origin_path(&inbox, "n.bin");
        tokio::fs::write(&theirs, b"a file somebody sent me")
            .await
            .unwrap();

        let (port, serving) = serving_from(&dir, &contents, 0).await;
        let (progress, _rx) = progress();
        accept(
            &offering("n.bin", port, contents.len()),
            &inbox,
            "alice",
            None,
            0,
            progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap();
        serving.await.unwrap().unwrap();

        assert_eq!(
            tokio::fs::read(&theirs).await.unwrap(),
            b"a file somebody sent me"
        );
    }

    /// A sender asked to start part-way sends only the rest, and says how much
    /// it sent as a position in the whole file.
    #[tokio::test]
    async fn a_file_is_served_from_the_point_it_was_asked_to() {
        let dir = tempdir();
        let contents = body(CHUNK + 4321);
        let from = 40_000u64;
        let (port, serving) = serving_from(&dir, &contents, from).await;

        let mut stream = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        let mut got = Vec::new();
        // Acknowledge nothing: a sender that streams ahead does not wait.
        stream.read_to_end(&mut got).await.unwrap();

        assert_eq!(got, contents[from as usize..]);
        assert_eq!(serving.await.unwrap().unwrap(), contents.len() as u64);
    }

    #[tokio::test]
    async fn a_start_outside_the_file_sends_all_of_it() {
        let dir = tempdir();
        let contents = body(3000);
        for from in [3000u64, 9999, u64::MAX] {
            let (port, serving) = serving_from(&dir, &contents, from).await;
            let mut stream = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
            let mut got = Vec::new();
            stream.read_to_end(&mut got).await.unwrap();
            assert_eq!(got, contents, "from {from}");
            serving.await.unwrap().unwrap();
        }
    }

    /// The whole story, end to end: a download that dies, a partial file that
    /// survives it, and a second attempt that finishes the job.
    #[tokio::test]
    async fn an_interrupted_download_can_be_finished() {
        let dir = tempdir();
        let inbox = dir.join("in");
        tokio::fs::create_dir_all(&inbox).await.unwrap();
        let contents = body(CHUNK * 4 + 77);
        let cut_after = CHUNK * 2 + 11;

        // First attempt: a sender that hangs up part-way through.
        let (listener, listening) = listen().await.unwrap();
        let first = contents.clone();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let _ = stream.write_all(&first[..cut_after]).await;
                let _ = stream.shutdown().await;
                // Read what the receiver sent back before letting go. Closing
                // with its acknowledgements unread is an abortive close, which
                // on Windows throws away bytes still in flight — the very thing
                // `send_from` takes care to avoid, and a test sender has to as
                // well or it measures its own rudeness.
                let mut acks = Vec::new();
                let _ = stream.read_to_end(&mut acks).await;
            }
        });
        let (progress1, _rx1) = progress();
        let failure = accept(
            &offering("movie.bin", listening.port, contents.len()),
            &inbox,
            "alice",
            None,
            0,
            progress1,
            &mut never_cancelled(),
        )
        .await
        .unwrap_err();
        assert!(matches!(failure, TransferError::Truncated { .. }));

        // What survived is exactly what arrived.
        let kept = partial_len(&inbox, "movie.bin").await.unwrap();
        assert_eq!(kept, cut_after as u64);
        assert!(!inbox.join("movie.bin").exists());

        // Second attempt: ask to resume from there, as the actor would.
        let (port, serving) = serving_from(&dir, &contents, kept).await;
        let (progress2, _rx2) = progress();
        let path = accept(
            &offering("movie.bin", port, contents.len()),
            &inbox,
            "alice",
            None,
            kept,
            progress2,
            &mut never_cancelled(),
        )
        .await
        .unwrap();

        assert_eq!(tokio::fs::read(&path).await.unwrap(), contents);
        serving.await.unwrap().unwrap();
        assert!(partial_len(&inbox, "movie.bin").await.is_none());
    }

    /// Stopping a download is a decision to be rid of it: nothing is kept.
    #[tokio::test]
    async fn cancelling_a_download_removes_its_partial_file() {
        let dir = tempdir();
        let inbox = dir.join("in");
        tokio::fs::create_dir_all(&inbox).await.unwrap();

        // A sender that sends some, then stalls.
        let (listener, listening) = listen().await.unwrap();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let _ = stream.write_all(&[7u8; 20_000]).await;
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
            }
        });

        let (cancel_tx, mut cancel_rx) = mpsc::channel(1);
        let (progress, mut events) = progress();
        let offer = offering("stalls.bin", listening.port, 1_000_000);
        let inbox2 = inbox.clone();
        let task = tokio::spawn(async move {
            accept(&offer, &inbox2, "alice", None, 0, progress, &mut cancel_rx).await
        });

        // Wait until something has really been written, then stop it.
        while !matches!(
            events.recv().await,
            Some(TransferEvent::Progress { transferred }) if transferred >= 20_000
        ) {}
        cancel_tx.send(()).await.unwrap();

        assert!(matches!(
            task.await.unwrap().unwrap_err(),
            TransferError::Cancelled
        ));
        assert!(partial_len(&inbox, "stalls.bin").await.is_none());
        assert_eq!(std::fs::read_dir(&inbox).unwrap().count(), 0);
    }

    /// A sender that is the one misbehaving does not get its bytes kept.
    #[tokio::test]
    async fn an_oversized_download_is_not_kept_either() {
        let dir = tempdir();
        let inbox = dir.join("in");
        tokio::fs::create_dir_all(&inbox).await.unwrap();
        let offer = DccOffer {
            filename: "huge.bin".to_owned(),
            addr: Some("127.0.0.1".parse().unwrap()),
            port: Some(1),
            size: Some(MAX_TRANSFER_BYTES + 1),
            token: None,
        };
        let (progress, _rx) = progress();
        let error = accept(
            &offer,
            &inbox,
            "alice",
            None,
            0,
            progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap_err();
        assert!(matches!(error, TransferError::TooLarge(_)));
        assert_eq!(std::fs::read_dir(&inbox).unwrap().count(), 0);
    }

    /// The sending half of a reverse offer: they listen, we dial out.
    ///
    /// Nothing calls this in the app yet — the token round-trip that would
    /// choose it is the one piece of DCC still missing — so without a test it
    /// would be untested scaffolding rotting quietly until someone needed it.
    /// Proving it moves bytes now is what makes it ready rather than merely
    /// present.
    #[tokio::test]
    async fn a_file_can_be_served_by_dialling_the_receiver() {
        let dir = tempdir();
        let source = dir.join("outgoing.bin");
        let contents: Vec<u8> = (0..5000).map(|i| (i % 251) as u8).collect();
        tokio::fs::write(&source, &contents).await.unwrap();

        // The receiver listens, which is what a reverse offer asks of them.
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        let received = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buffer = Vec::new();
            stream.read_to_end(&mut buffer).await.unwrap();
            buffer
        });

        let (progress, _events) = progress();
        let sent = serve_by_dialling(
            addr,
            &source,
            // No proxy: dialling out through one is the same code path as
            // `accept` uses, and is covered by the refusal tests above.
            None,
            progress,
            &mut never_cancelled(),
        )
        .await
        .unwrap();

        assert_eq!(sent, contents.len() as u64);
        assert_eq!(received.await.unwrap(), contents);
    }

    /// A directory of our own, removed when the test process ends. Avoids a
    /// dev-dependency for something this small.
    fn tempdir() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "ddirc-dcc-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
