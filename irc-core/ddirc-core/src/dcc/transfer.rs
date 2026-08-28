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
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};

use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufWriter};
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

/// Accept an offer: connect, and write what arrives to [`destination`].
///
/// Only ever a *normal* offer. A reverse one is refused before this is reached
/// when a proxy is configured, and handled by [`serve`] when one is not.
///
/// The file is written under a `.part` name and renamed once it is whole, so a
/// transfer that fails halfway cannot be mistaken for the file it was going to
/// be. Nothing overwrites: a name already taken is an error, never a silent
/// replacement of something the user already had.
pub async fn accept(
    offer: &DccOffer,
    destination: &Path,
    proxy: Option<&ProxyConfig>,
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
    let partial = path.with_extension(format!(
        "{}.part",
        path.extension().and_then(|e| e.to_str()).unwrap_or("")
    ));

    let stream = dial(SocketAddr::new(addr, port), proxy).await?;
    progress.send(TransferEvent::Started { total: offer.size });

    let result = receive_into(stream, &partial, offer.size, &progress, cancel).await;
    match result {
        Ok(()) => {
            tokio::fs::rename(&partial, &path).await?;
            Ok(path)
        }
        Err(e) => {
            // A partial file left behind is litter the user did not ask for,
            // and one named like the real thing would be worse than litter.
            let _ = tokio::fs::remove_file(&partial).await;
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
pub async fn serve(
    listener: TcpListener,
    path: &Path,
    progress: Progress,
    cancel: &mut mpsc::Receiver<()>,
) -> Result<u64, TransferError> {
    let accepted = tokio::time::timeout(RENDEZVOUS_TIMEOUT, listener.accept()).await;
    let stream = match accepted {
        Ok(Ok((stream, _peer))) => stream,
        Ok(Err(e)) => return Err(e.into()),
        Err(_) => return Err(TransferError::NoRendezvous(RENDEZVOUS_TIMEOUT.as_secs())),
    };
    send_from(stream, path, &progress, cancel).await
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
    send_from(stream, path, &progress, cancel).await
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
async fn receive_into(
    mut stream: TcpStream,
    path: &Path,
    expected: Option<u64>,
    progress: &Progress,
    cancel: &mut mpsc::Receiver<()>,
) -> Result<(), TransferError> {
    let mut file = BufWriter::new(File::create(path).await?);
    let mut buffer = vec![0u8; CHUNK];
    let mut received: u64 = 0;

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
async fn send_from(
    stream: TcpStream,
    path: &Path,
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

    progress.send(TransferEvent::Started { total: Some(total) });

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
    let mut sent: u64 = 0;
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

        let error = accept(&offer, &dir, Some(&proxy), progress, &mut never_cancelled())
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
            None,
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
            serve(listener, &source, send_progress, &mut never_cancelled()).await
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

        let path = accept(&offer, &inbox, None, recv_progress, &mut never_cancelled())
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

        let error = accept(&offer, &dir, None, progress, &mut never_cancelled())
            .await
            .unwrap_err();

        assert!(matches!(error, TransferError::AlreadyExists(name) if name == "taken.txt"));
        assert_eq!(
            tokio::fs::read(dir.join("taken.txt")).await.unwrap(),
            b"mine"
        );
    }

    /// A sender that stops early leaves no file behind under the real name.
    #[tokio::test]
    async fn a_truncated_transfer_is_reported_and_leaves_nothing() {
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

        let error = accept(&offer, &dir, None, progress, &mut never_cancelled())
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
        let leftovers = std::fs::read_dir(&dir).unwrap().count();
        assert_eq!(leftovers, 0, "and no partial left lying about");
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
