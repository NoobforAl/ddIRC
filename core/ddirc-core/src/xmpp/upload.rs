//! Sharing a file: HTTP Upload (XEP-0363).
//!
//! XMPP has no way to carry a file in a message. The way every current client
//! shares one is this: ask the server for a *slot* - an address to `PUT` the
//! bytes to and an address anyone can `GET` them from - upload to the first,
//! and send the second as the message. The recipient's client shows a link.
//!
//! Two things in that are the server's to say and ours to distrust. The
//! addresses come from the server, and the upload connects to one of them with
//! the user's file in hand. So the address is checked before anything is sent:
//! it must be `https`, carry no credentials, and name a host rather than an
//! address, so that a server cannot point an upload at a machine on the user's
//! own network. And the upload goes the way the rest of the connection does -
//! through the proxy when there is one - because a file that left by another
//! road would be a leak of exactly the kind the proxy is there to prevent.
//!
//! Nothing is fetched. A link someone sends is shown as a link; opening it is
//! the user's decision, as it is for any other.

use std::net::IpAddr;
use std::path::Path;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::time::timeout;
use tokio_xmpp::jid::Jid;
use tokio_xmpp::parsers::data_forms::DataForm;
use tokio_xmpp::parsers::disco::DiscoInfoResult;
use tokio_xmpp::parsers::http_upload::SlotResult;
use url::{Host, Url};

pub const NS_UPLOAD: &str = "urn:xmpp:http:upload:0";

/// The largest file this client will upload whatever the server allows.
///
/// A server that says "no limit" is a server that has not thought about one,
/// and a phone sending a film over a mobile connection is not something to do
/// by accident.
pub const HARD_LIMIT: u64 = 100 * 1024 * 1024;

/// The longest address accepted from a server, for either direction.
const MAX_URL: usize = 2048;

/// The most extra headers accepted with a slot. The protocol allows three.
const MAX_HEADERS: usize = 8;

/// How much of an HTTP response head is read before giving up.
const MAX_RESPONSE_HEAD: usize = 8 * 1024;

/// How long any one step of the upload may wait on the server.
const STALL: Duration = Duration::from_secs(60);

/// How much is read from the file and sent at a time.
const CHUNK: usize = 16 * 1024;

/// Where files are uploaded, as discovered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadService {
    pub jid: Jid,
    /// The largest file the service says it takes.
    pub max_bytes: Option<u64>,
}

/// What a service says it accepts, from its `disco#info` answer, if it is an
/// upload service at all.
pub fn service_from_info(jid: &Jid, info: &DiscoInfoResult) -> Option<UploadService> {
    if !info.features.contains(NS_UPLOAD) {
        return None;
    }
    let max_bytes = info
        .extensions
        .iter()
        .filter(|form| is_upload_form(form))
        .flat_map(|form| form.fields.iter())
        .find(|field| field.var.as_deref() == Some("max-file-size"))
        .and_then(|field| field.values.first())
        .and_then(|v| v.trim().parse::<u64>().ok());
    Some(UploadService {
        jid: jid.clone(),
        max_bytes,
    })
}

fn is_upload_form(form: &DataForm) -> bool {
    form.form_type().is_some_and(|t| t == NS_UPLOAD)
}

/// The most that may be uploaded to this service: what it says, and never more
/// than [`HARD_LIMIT`].
pub fn limit(service: &UploadService) -> u64 {
    service.max_bytes.map_or(HARD_LIMIT, |m| m.min(HARD_LIMIT))
}

/// A media type from a file's name, for the slot request.
///
/// By extension and no more: reading the file to find out would be work for a
/// hint, and `application/octet-stream` is a true answer to "what is this".
pub fn content_type(filename: &str) -> &'static str {
    let extension = filename
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();
    match extension.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "pdf" => "application/pdf",
        "txt" | "log" | "md" => "text/plain",
        "mp3" => "audio/mpeg",
        "ogg" | "opus" => "audio/ogg",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "zip" => "application/zip",
        _ => "application/octet-stream",
    }
}

/// A slot the server granted, checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Slot {
    pub put: Url,
    pub headers: Vec<(String, String)>,
    /// Where it can be fetched from, to be sent as the message.
    pub get: String,
}

/// Why a slot was not accepted.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum SlotError {
    #[error("the server gave an upload address that is not a valid https address")]
    BadAddress,
    #[error("the server gave an upload address that is not a normal website address")]
    UnsafeHost,
    #[error("the server gave a header that cannot be sent")]
    BadHeader,
}

/// Check a slot before anything is sent to it.
///
/// `account_domain` is the domain of the account: an upload address *inside* it
/// may name a single-label host such as `localhost`, as a server set up for
/// development does, and nowhere else may.
pub fn check_slot(slot: &SlotResult, account_domain: &str) -> Result<Slot, SlotError> {
    let put = parse_https(&slot.put.url)?;
    let get = parse_https(&slot.get.url)?;

    match put.host() {
        Some(Host::Domain(name)) => {
            // `localhost.` is `localhost`, and `Localhost` and `LOCALHOST` are
            // too: compare what the name means, not how it was spelled.
            let name = name.trim_end_matches('.').to_ascii_lowercase();
            let domain = account_domain.trim_end_matches('.').to_ascii_lowercase();
            let inside =
                !domain.is_empty() && (name == domain || name.ends_with(&format!(".{domain}")));
            let loopback_name = name == "localhost" || name.ends_with(".localhost");
            if !inside && (!name.contains('.') || loopback_name) {
                return Err(SlotError::UnsafeHost);
            }
        }
        // An address, of either kind: a way to name a machine the server picked
        // without the name a certificate would be checked against.
        _ => return Err(SlotError::UnsafeHost),
    }

    if slot.put.headers.len() > MAX_HEADERS {
        return Err(SlotError::BadHeader);
    }
    let mut headers = Vec::new();
    for header in &slot.put.headers {
        let value = header.value.trim();
        if value.is_empty()
            || value.len() > 4096
            || value.chars().any(|c| c.is_control() || !c.is_ascii())
        {
            return Err(SlotError::BadHeader);
        }
        headers.push((header.name.as_str().to_owned(), value.to_owned()));
    }
    Ok(Slot {
        put,
        headers,
        get: get.to_string(),
    })
}

fn parse_https(address: &str) -> Result<Url, SlotError> {
    if address.len() > MAX_URL {
        return Err(SlotError::BadAddress);
    }
    let url = Url::parse(address).map_err(|_| SlotError::BadAddress)?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.host().is_none()
        || url.fragment().is_some()
    {
        return Err(SlotError::BadAddress);
    }
    // A literal address typed as a name, which `Url` has already told apart.
    if let Some(Host::Domain(name)) = url.host() {
        if name.parse::<IpAddr>().is_ok() {
            return Err(SlotError::UnsafeHost);
        }
    }
    Ok(url)
}

/// Whether an address is one on the public internet, as far as its number says.
///
/// What a name must resolve to for an upload to be sent to it, when this
/// process does the resolving. A server cannot name a private address in the
/// slot (see [`check_slot`]), but a name it controls can *resolve* to one, and
/// a file sent to a printer or a router's admin page is the same mistake with
/// extra steps. Not `IpAddr::is_global`, which is not stable.
pub fn is_public_address(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            !(v4.is_unspecified()
                || v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_multicast()
                || v4.is_documentation()
                // Shared address space (carrier-grade NAT), reserved, and the
                // "this network" block.
                || (o[0] == 100 && (64..=127).contains(&o[1]))
                || o[0] == 0
                || o[0] >= 240
                // Benchmarking, 198.18.0.0/15.
                || (o[0] == 198 && (o[1] == 18 || o[1] == 19))
                || (o[0] == 192 && o[1] == 0 && o[2] == 0))
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_public_address(IpAddr::V4(v4));
            }
            let s = v6.segments();
            let first = s[0];
            // Forms that carry an IPv4 address inside, which is the address the
            // packet ends up at: judge it by that one. NAT64 (64:ff9b::/96),
            // IPv4-compatible (::/96) and 6to4 (2002::/16, the address in bits
            // 16-48).
            let embedded = |hi: u16, lo: u16| {
                IpAddr::V4(std::net::Ipv4Addr::new(
                    (hi >> 8) as u8,
                    hi as u8,
                    (lo >> 8) as u8,
                    lo as u8,
                ))
            };
            if first == 0x64 && s[1] == 0xff9b && s[2..6] == [0, 0, 0, 0] {
                return is_public_address(embedded(s[6], s[7]));
            }
            if s[..6] == [0, 0, 0, 0, 0, 0] {
                return is_public_address(embedded(s[6], s[7]));
            }
            if first == 0x2002 {
                return is_public_address(embedded(s[1], s[2]));
            }
            // Refused outright: they tunnel to an address this check cannot see
            // (Teredo 2001::/32, local-use NAT64 64:ff9b:1::/48), are
            // deprecated site-local (fec0::/10), or discard traffic (100::/64).
            if (first == 0x2001 && s[1] == 0)
                || (first == 0x64 && s[1] == 0xff9b && s[2] == 1)
                || (first & 0xffc0) == 0xfec0
                || (first == 0x100 && s[1..4] == [0, 0, 0])
            {
                return false;
            }
            !(v6.is_unspecified()
                || v6.is_loopback()
                || v6.is_multicast()
                // Unique local fc00::/7, link local fe80::/10, documentation.
                || (first & 0xfe00) == 0xfc00
                || (first & 0xffc0) == 0xfe80
                || (first == 0x2001 && v6.segments()[1] == 0x0db8))
        }
    }
}

/// Why an upload did not complete.
#[derive(Debug, thiserror::Error)]
pub enum UploadError {
    #[error("could not read the file: {0}")]
    File(std::io::Error),
    #[error("the file changed while it was being sent")]
    Changed,
    #[error("could not reach the upload server: {0}")]
    Connection(std::io::Error),
    #[error("the upload server stopped answering")]
    Stalled,
    #[error("the upload server refused the file (status {0})")]
    Refused(u16),
    #[error("the upload server's answer could not be understood")]
    BadResponse,
}

/// Send `file` to `slot` over `stream`, reporting how much has gone.
///
/// HTTP/1.1 and no more of it than is needed: one `PUT`, a `Content-Length`
/// rather than chunking, `Connection: close`, the headers the server asked for
/// and none it did not. No `User-Agent`: nothing requires one, and it would be
/// the client telling a web server what it is. Redirects are not followed - a
/// server that answers an upload with one is not one to send a file to.
pub async fn put<S>(
    mut stream: S,
    slot: &Slot,
    file: &Path,
    size: u64,
    content_type: &str,
    mut progress: impl FnMut(u64),
) -> Result<(), UploadError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut source = tokio::fs::File::open(file)
        .await
        .map_err(UploadError::File)?;
    let host = slot.put.host_str().unwrap_or_default();
    let authority = match slot.put.port() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_owned(),
    };
    let mut target = slot.put.path().to_owned();
    if let Some(query) = slot.put.query() {
        target.push('?');
        target.push_str(query);
    }
    let mut head = format!(
        "PUT {target} HTTP/1.1\r\nHost: {authority}\r\nContent-Length: {size}\r\n\
         Content-Type: {content_type}\r\nConnection: close\r\n"
    );
    for (name, value) in &slot.headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    send(&mut stream, head.as_bytes()).await?;

    let mut buffer = vec![0u8; CHUNK];
    let mut sent = 0u64;
    while sent < size {
        let want = usize::try_from((size - sent).min(CHUNK as u64)).unwrap_or(CHUNK);
        let read = source
            .read(&mut buffer[..want])
            .await
            .map_err(UploadError::File)?;
        if read == 0 {
            // The file is shorter than it was. Sending less than promised
            // leaves the server waiting for the rest.
            return Err(UploadError::Changed);
        }
        send(&mut stream, &buffer[..read]).await?;
        sent += read as u64;
        progress(sent);
    }
    timeout(STALL, stream.flush())
        .await
        .map_err(|_| UploadError::Stalled)?
        .map_err(UploadError::Connection)?;
    // Longer than it was: whatever came after `size` is not what was agreed.
    let mut extra = [0u8; 1];
    if source.read(&mut extra).await.map_err(UploadError::File)? != 0 {
        return Err(UploadError::Changed);
    }

    let status = read_status(&mut stream).await?;
    if (200..300).contains(&status) {
        Ok(())
    } else {
        Err(UploadError::Refused(status))
    }
}

async fn send<S: AsyncWrite + Unpin>(stream: &mut S, bytes: &[u8]) -> Result<(), UploadError> {
    timeout(STALL, stream.write_all(bytes))
        .await
        .map_err(|_| UploadError::Stalled)?
        .map_err(UploadError::Connection)
}

/// Read the response head and return its status code.
async fn read_status<S: AsyncRead + Unpin>(stream: &mut S) -> Result<u16, UploadError> {
    let mut seen = Vec::new();
    let mut buffer = [0u8; 1024];
    loop {
        let n = timeout(STALL, stream.read(&mut buffer))
            .await
            .map_err(|_| UploadError::Stalled)?
            .map_err(UploadError::Connection)?;
        if n == 0 {
            return Err(UploadError::BadResponse);
        }
        seen.extend_from_slice(&buffer[..n]);
        // More than one head can arrive: a server may say `100 Continue` or
        // `103 Early Hints` before the answer that counts.
        loop {
            let mut headers = [httparse::EMPTY_HEADER; 96];
            let mut response = httparse::Response::new(&mut headers);
            match response.parse(&seen) {
                Ok(httparse::Status::Complete(length)) => {
                    let code = response.code.ok_or(UploadError::BadResponse)?;
                    if (100..200).contains(&code) && code != 101 {
                        seen.drain(..length);
                        continue;
                    }
                    return Ok(code);
                }
                Ok(httparse::Status::Partial) if seen.len() < MAX_RESPONSE_HEAD => break,
                _ => return Err(UploadError::BadResponse),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use tokio_xmpp::parsers::http_upload::{Get, Header, HeaderName, Put};

    fn slot(put: &str, get: &str) -> SlotResult {
        SlotResult {
            put: Put {
                url: put.to_owned(),
                headers: Vec::new(),
            },
            get: Get {
                url: get.to_owned(),
            },
        }
    }

    // ---- discovery --------------------------------------------------------

    fn info(xml: &str) -> DiscoInfoResult {
        let element: tokio_xmpp::minidom::Element = xml.parse().unwrap();
        DiscoInfoResult::try_from(element).unwrap()
    }

    #[test]
    fn a_service_that_offers_upload_is_found_with_its_limit() {
        let result = info(
            "<query xmlns='http://jabber.org/protocol/disco#info'>\
             <identity category='store' type='file' name='up'/>\
             <feature var='urn:xmpp:http:upload:0'/>\
             <x xmlns='jabber:x:data' type='result'>\
             <field var='FORM_TYPE' type='hidden'><value>urn:xmpp:http:upload:0</value></field>\
             <field var='max-file-size'><value>5242880</value></field>\
             </x></query>",
        );
        let found = service_from_info(&"up.example.org".parse().unwrap(), &result).unwrap();
        assert_eq!(found.max_bytes, Some(5_242_880));
    }

    #[test]
    fn a_service_that_does_not_is_not() {
        let result = info(
            "<query xmlns='http://jabber.org/protocol/disco#info'>\
             <identity category='conference' type='text'/>\
             <feature var='http://jabber.org/protocol/muc'/></query>",
        );
        assert!(service_from_info(&"conf.example.org".parse().unwrap(), &result).is_none());
    }

    #[test]
    fn a_limit_in_some_other_form_is_not_ours() {
        let result = info(
            "<query xmlns='http://jabber.org/protocol/disco#info'>\
             <feature var='urn:xmpp:http:upload:0'/>\
             <x xmlns='jabber:x:data' type='result'>\
             <field var='FORM_TYPE' type='hidden'><value>urn:example:other</value></field>\
             <field var='max-file-size'><value>1</value></field>\
             </x></query>",
        );
        let found = service_from_info(&"up.example.org".parse().unwrap(), &result).unwrap();
        assert_eq!(found.max_bytes, None);
    }

    #[test]
    fn the_limit_is_the_servers_and_never_more_than_ours() {
        let jid: Jid = "up.example.org".parse().unwrap();
        let svc = |max| UploadService {
            jid: jid.clone(),
            max_bytes: max,
        };
        assert_eq!(limit(&svc(Some(1000))), 1000);
        assert_eq!(limit(&svc(None)), HARD_LIMIT);
        assert_eq!(limit(&svc(Some(u64::MAX))), HARD_LIMIT);
    }

    #[test]
    fn media_types_come_from_the_extension() {
        assert_eq!(content_type("photo.JPG"), "image/jpeg");
        assert_eq!(content_type("notes.txt"), "text/plain");
        assert_eq!(content_type("noextension"), "application/octet-stream");
        assert_eq!(content_type("weird.xyz"), "application/octet-stream");
    }

    // ---- addresses ------------------------------------------------------------

    #[test]
    fn private_and_special_addresses_are_not_public() {
        for a in [
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.1",
            "169.254.169.254",
            "0.0.0.0",
            "255.255.255.255",
            "224.0.0.1",
            "100.64.0.1",
            "100.127.255.255",
            "192.0.2.1",
            "198.51.100.1",
            "203.0.113.1",
            "240.0.0.1",
            "::1",
            "::",
            "fe80::1",
            "fc00::1",
            "fd12:3456::1",
            "ff02::1",
            "2001:db8::1",
            "::ffff:127.0.0.1",
            "::ffff:10.0.0.1",
            "198.18.0.1",
            "198.19.255.255",
            // Embedded IPv4: NAT64, IPv4-compatible, 6to4.
            "64:ff9b::7f00:1",
            "64:ff9b::a00:1",
            "64:ff9b::c0a8:101",
            "::7f00:1",
            "::a00:1",
            "2002:7f00:1::",
            "2002:a9fe:a9fe::",
            "2002:c0a8:101::",
            // Tunnels, site-local, discard.
            "2001:0:4136:e378:8000:63bf:3fff:fdd2",
            "64:ff9b:1::1",
            "fec0::1",
            "100::1",
        ] {
            assert!(!is_public_address(a.parse().unwrap()), "{a}");
        }
    }

    #[test]
    fn ordinary_public_addresses_are_public() {
        for a in [
            "8.8.8.8",
            "1.1.1.1",
            "93.184.216.34",
            "100.63.0.1",
            "100.128.0.1",
            "2606:4700::1111",
            "::ffff:8.8.8.8",
            "198.20.0.1",
            "64:ff9b::808:808",
            "2002:808:808::",
        ] {
            assert!(is_public_address(a.parse().unwrap()), "{a}");
        }
    }

    // ---- slots ------------------------------------------------------------

    #[test]
    fn spellings_of_localhost_are_all_localhost() {
        for host in [
            "localhost.",
            "LOCALHOST",
            "Localhost.",
            "foo.localhost",
            "a.b.localhost.",
        ] {
            assert_eq!(
                check_slot(
                    &slot(&format!("https://{host}/p"), "https://up.example.org/g"),
                    "example.org"
                ),
                Err(SlotError::UnsafeHost),
                "{host}"
            );
        }
        // Still allowed where the account itself lives there.
        assert!(check_slot(
            &slot("https://localhost.:5443/p", "https://localhost:5443/g"),
            "localhost"
        )
        .is_ok());
    }

    #[test]
    fn an_empty_account_domain_makes_nothing_inside_it() {
        assert_eq!(
            check_slot(&slot("https://router/p", "https://up.example.org/g"), ""),
            Err(SlotError::UnsafeHost)
        );
    }

    #[test]
    fn an_ordinary_slot_is_accepted() {
        let s = check_slot(
            &slot(
                "https://up.example.org/put/abc/photo.jpg",
                "https://up.example.org/get/abc/photo.jpg",
            ),
            "example.org",
        )
        .unwrap();
        assert_eq!(s.get, "https://up.example.org/get/abc/photo.jpg");
    }

    #[test]
    fn plain_http_is_refused() {
        assert_eq!(
            check_slot(
                &slot("http://up.example.org/p", "https://up.example.org/g"),
                "example.org"
            ),
            Err(SlotError::BadAddress)
        );
    }

    #[test]
    fn credentials_in_the_address_are_refused() {
        assert_eq!(
            check_slot(
                &slot("https://u:p@up.example.org/p", "https://up.example.org/g"),
                "example.org"
            ),
            Err(SlotError::BadAddress)
        );
    }

    #[test]
    fn an_address_instead_of_a_name_is_refused() {
        for put in [
            "https://192.168.1.1/p",
            "https://10.0.0.5:8443/p",
            "https://[::1]/p",
            "https://127.0.0.1/p",
        ] {
            assert_eq!(
                check_slot(&slot(put, "https://up.example.org/g"), "example.org"),
                Err(SlotError::UnsafeHost),
                "{put}"
            );
        }
    }

    #[test]
    fn a_single_label_host_is_refused_unless_it_is_the_accounts_own() {
        assert_eq!(
            check_slot(
                &slot("https://router/p", "https://up.example.org/g"),
                "example.org"
            ),
            Err(SlotError::UnsafeHost)
        );
        assert_eq!(
            check_slot(
                &slot("https://localhost/p", "https://up.example.org/g"),
                "example.org"
            ),
            Err(SlotError::UnsafeHost)
        );
        // A development server on localhost, with an account on localhost.
        assert!(check_slot(
            &slot("https://localhost:5443/p", "https://localhost:5443/g"),
            "localhost"
        )
        .is_ok());
    }

    #[test]
    fn an_upload_may_go_to_a_different_domain_than_the_account() {
        assert!(check_slot(
            &slot(
                "https://files.cdn-example.net/p",
                "https://files.cdn-example.net/g"
            ),
            "example.org"
        )
        .is_ok());
    }

    #[test]
    fn nonsense_and_oversized_addresses_are_refused() {
        assert_eq!(
            check_slot(
                &slot("not a url", "https://up.example.org/g"),
                "example.org"
            ),
            Err(SlotError::BadAddress)
        );
        let long = format!("https://up.example.org/{}", "a".repeat(MAX_URL));
        assert_eq!(
            check_slot(&slot(&long, "https://up.example.org/g"), "example.org"),
            Err(SlotError::BadAddress)
        );
    }

    #[test]
    fn a_header_value_that_would_inject_another_is_refused() {
        let mut s = slot("https://up.example.org/p", "https://up.example.org/g");
        s.put.headers.push(Header {
            name: HeaderName::Authorization,
            value: "Bearer x\r\nX-Evil: 1".to_owned(),
        });
        assert_eq!(check_slot(&s, "example.org"), Err(SlotError::BadHeader));
    }

    #[test]
    fn the_headers_the_server_asked_for_are_kept() {
        let mut s = slot("https://up.example.org/p", "https://up.example.org/g");
        s.put.headers.push(Header {
            name: HeaderName::Authorization,
            value: "Bearer token".to_owned(),
        });
        let checked = check_slot(&s, "example.org").unwrap();
        assert_eq!(
            checked.headers,
            vec![("Authorization".to_owned(), "Bearer token".to_owned())]
        );
    }

    // ---- the upload itself --------------------------------------------------

    /// A file that is removed when it goes out of scope.
    struct TempFile(std::path::PathBuf);

    impl Drop for TempFile {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    fn temp_file(bytes: &[u8]) -> (TempFile, std::path::PathBuf) {
        let path =
            std::env::temp_dir().join(format!("ddirc-upload-{:016x}", rand::random::<u64>()));
        std::fs::write(&path, bytes).unwrap();
        (TempFile(path.clone()), path)
    }

    fn granted() -> Slot {
        check_slot(
            &slot(
                "https://up.example.org:8443/put/abc/f.bin?token=1",
                "https://up.example.org/get/abc/f.bin",
            ),
            "example.org",
        )
        .unwrap()
    }

    /// The server's half: read the request until the body is complete, answer
    /// with `reply`, and return what was received.
    async fn server<S: AsyncRead + AsyncWrite + Unpin>(
        mut stream: S,
        body_len: usize,
        reply: &str,
    ) -> Vec<u8> {
        let mut seen = Vec::new();
        let mut buf = [0u8; 4096];
        let head_end = loop {
            let n = stream.read(&mut buf).await.unwrap();
            assert!(n > 0, "client closed before finishing the head");
            seen.extend_from_slice(&buf[..n]);
            if let Some(i) = seen.windows(4).position(|w| w == b"\r\n\r\n") {
                break i + 4;
            }
        };
        while seen.len() < head_end + body_len {
            let n = stream.read(&mut buf).await.unwrap();
            if n == 0 {
                break;
            }
            seen.extend_from_slice(&buf[..n]);
        }
        stream.write_all(reply.as_bytes()).await.unwrap();
        stream.flush().await.unwrap();
        seen
    }

    #[tokio::test]
    async fn the_file_is_sent_with_exactly_the_headers_agreed() {
        let body: Vec<u8> = (0..50_000u32).map(|i| (i % 251) as u8).collect();
        let (_dir, path) = temp_file(&body);
        let (client, remote) = tokio::io::duplex(64 * 1024);
        let mut slot = granted();
        slot.headers
            .push(("Authorization".to_owned(), "Bearer t".to_owned()));
        let expected = body.len();
        let server =
            tokio::spawn(
                async move { server(remote, expected, "HTTP/1.1 201 Created\r\n\r\n").await },
            );

        let mut last = 0;
        put(client, &slot, &path, body.len() as u64, "image/png", |n| {
            last = n
        })
        .await
        .unwrap();
        let received = server.await.unwrap();
        let head_end = received.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
        let head = String::from_utf8(received[..head_end].to_vec()).unwrap();

        assert!(head.starts_with("PUT /put/abc/f.bin?token=1 HTTP/1.1\r\n"));
        assert!(head.contains("Host: up.example.org:8443\r\n"));
        assert!(head.contains("Content-Length: 50000\r\n"));
        assert!(head.contains("Content-Type: image/png\r\n"));
        assert!(head.contains("Authorization: Bearer t\r\n"));
        // Nothing about who is asking.
        assert!(!head.to_ascii_lowercase().contains("user-agent"));
        assert_eq!(&received[head_end..], &body[..]);
        assert_eq!(last, body.len() as u64, "progress reached the end");
    }

    #[tokio::test]
    async fn a_refusal_is_an_error_with_the_status() {
        let (_dir, path) = temp_file(b"hello");
        let (client, remote) = tokio::io::duplex(4096);
        let server =
            tokio::spawn(async move { server(remote, 5, "HTTP/1.1 403 Forbidden\r\n\r\n").await });
        let result = put(client, &granted(), &path, 5, "text/plain", |_| {}).await;
        server.await.unwrap();
        assert!(matches!(result, Err(UploadError::Refused(403))));
    }

    #[tokio::test]
    async fn an_interim_answer_is_not_the_answer() {
        let (_dir, path) = temp_file(b"hello");
        let (client, remote) = tokio::io::duplex(4096);
        let server = tokio::spawn(async move {
            server(
                remote,
                5,
                "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\n\r\n",
            )
            .await
        });
        let result = put(client, &granted(), &path, 5, "text/plain", |_| {}).await;
        server.await.unwrap();
        assert!(result.is_ok(), "{result:?}");
    }

    #[tokio::test]
    async fn a_redirect_is_not_followed_and_is_not_success() {
        let (_dir, path) = temp_file(b"hello");
        let (client, remote) = tokio::io::duplex(4096);
        let server = tokio::spawn(async move {
            server(
                remote,
                5,
                "HTTP/1.1 307 Temporary Redirect\r\nLocation: https://elsewhere/\r\n\r\n",
            )
            .await
        });
        let result = put(client, &granted(), &path, 5, "text/plain", |_| {}).await;
        server.await.unwrap();
        assert!(matches!(result, Err(UploadError::Refused(307))));
    }

    #[tokio::test]
    async fn an_answer_that_is_not_http_is_an_error() {
        let (_dir, path) = temp_file(b"hello");
        let (client, remote) = tokio::io::duplex(4096);
        let server =
            tokio::spawn(async move { server(remote, 5, "garbage garbage\r\n\r\n").await });
        let result = put(client, &granted(), &path, 5, "text/plain", |_| {}).await;
        server.await.unwrap();
        assert!(matches!(result, Err(UploadError::BadResponse)));
    }

    #[tokio::test]
    async fn a_file_that_shrank_is_an_error_and_not_a_short_upload() {
        let (_dir, path) = temp_file(b"abc");
        let (client, remote) = tokio::io::duplex(4096);
        let _keep = remote;
        // Promised ten bytes, the file has three.
        let result = put(client, &granted(), &path, 10, "text/plain", |_| {}).await;
        assert!(matches!(result, Err(UploadError::Changed)));
    }

    #[tokio::test]
    async fn a_file_that_grew_is_an_error() {
        let (_dir, path) = temp_file(b"abcdef");
        let (client, remote) = tokio::io::duplex(4096);
        let _keep = remote;
        let result = put(client, &granted(), &path, 3, "text/plain", |_| {}).await;
        assert!(matches!(result, Err(UploadError::Changed)));
    }

    #[tokio::test]
    async fn a_file_that_is_not_there_is_an_error() {
        let (client, remote) = tokio::io::duplex(4096);
        let _keep = remote;
        let result = put(
            client,
            &granted(),
            Path::new("/no/such/file"),
            3,
            "text/plain",
            |_| {},
        )
        .await;
        assert!(matches!(result, Err(UploadError::File(_))));
    }

    #[tokio::test]
    async fn a_server_that_never_answers_is_given_up_on() {
        let (_dir, path) = temp_file(b"hello");
        let (client, remote) = tokio::io::duplex(4096);
        tokio::time::pause();
        let task =
            tokio::spawn(
                async move { put(client, &granted(), &path, 5, "text/plain", |_| {}).await },
            );
        // Read the request, say nothing.
        let mut remote = remote;
        let mut buf = [0u8; 4096];
        let _ = remote.read(&mut buf).await;
        tokio::time::sleep(STALL + Duration::from_secs(1)).await;
        assert!(matches!(task.await.unwrap(), Err(UploadError::Stalled)));
    }
}
