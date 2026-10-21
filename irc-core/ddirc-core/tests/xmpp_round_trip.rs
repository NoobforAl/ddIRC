//! The real XMPP actor, against a scripted server, over real TLS.
//!
//! Nothing to install and nothing to start: the "server" is a few dozen lines
//! of this file speaking just enough XMPP to log in and host one room, bound to
//! an ephemeral loopback port. It exists to prove the things the unit tests
//! cannot - that the connector, the library's stream, the login and the session
//! fit together - and the two policies that were the reason the library's own
//! client is not used.

use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::{ConnectionStatus, Target};
use ddirc_core::conn::actor::{ClientCommand, ConnectionHandle};
use ddirc_core::xmpp::actor;
use ddirc_core::xmpp::config::XmppConfig;
use rcgen::{
    date_time_ymd, BasicConstraints, CertificateParams, DnType, IsCa, Issuer, KeyPair,
    KeyUsagePurpose,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc::Receiver;
use tokio_rustls::TlsAcceptor;
use zeroize::Zeroizing;

const DOMAIN: &str = "example.org";
const ROOM: &str = "lobby@conference.example.org";
const TIMEOUT: Duration = Duration::from_secs(20);

/// A CA and a certificate for [`DOMAIN`], and the CA written where
/// `extra_root_cert` can find it.
struct Pki {
    chain: Vec<CertificateDer<'static>>,
    key: Vec<u8>,
    ca_path: std::path::PathBuf,
}

impl Drop for Pki {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.ca_path);
    }
}

fn pki(tag: &str) -> Pki {
    let params = |names: Vec<String>| {
        let mut p = CertificateParams::new(names).unwrap();
        p.not_before = date_time_ymd(2020, 1, 1);
        p.not_after = date_time_ymd(2099, 1, 1);
        p
    };
    let ca_key = KeyPair::generate().unwrap();
    let mut ca_params = params(Vec::new());
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    ca_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    ca_params
        .distinguished_name
        .push(DnType::CommonName, "ddIRC XMPP test CA");
    let ca_cert = ca_params.clone().self_signed(&ca_key).unwrap();
    let issuer = Issuer::new(ca_params, ca_key);

    let leaf_key = KeyPair::generate().unwrap();
    let mut leaf = params(vec![DOMAIN.to_owned()]);
    leaf.use_authority_key_identifier_extension = true;
    let leaf_cert = leaf.signed_by(&leaf_key, &issuer).unwrap();

    let ca_path = std::env::temp_dir().join(format!("ddirc-xmpp-round-trip-{tag}.pem"));
    std::fs::write(&ca_path, ca_cert.pem()).unwrap();
    Pki {
        chain: vec![leaf_cert.der().clone(), ca_cert.der().clone()],
        key: leaf_key.serialize_der(),
        ca_path,
    }
}

fn acceptor(pki: &Pki) -> TlsAcceptor {
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(
        pki.chain.clone(),
        PrivateKeyDer::try_from(pki.key.clone()).unwrap(),
    )
    .unwrap();
    TlsAcceptor::from(Arc::new(config))
}

/// Read until `needle` has arrived, and return everything up to the end of it.
/// What follows stays buffered for the next call.
async fn expect<S: AsyncRead + Unpin>(io: &mut S, buffer: &mut String, needle: &str) -> String {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    loop {
        if let Some(at) = buffer.find(needle) {
            let end = at + needle.len();
            return buffer.drain(..end).collect();
        }
        let mut chunk = [0u8; 4096];
        let read = tokio::time::timeout_at(deadline, io.read(&mut chunk))
            .await
            .unwrap_or_else(|_| panic!("timed out waiting for {needle:?}; had {buffer:?}"))
            .unwrap_or_else(|e| {
                panic!("the client's connection failed waiting for {needle:?}: {e}; had {buffer:?}")
            });
        assert!(
            read > 0,
            "the client hung up waiting for {needle:?}; had {buffer:?}"
        );
        buffer.push_str(&String::from_utf8_lossy(&chunk[..read]));
    }
}

fn header(id: &str) -> String {
    format!(
        "<?xml version='1.0'?><stream:stream xmlns='jabber:client' \
         xmlns:stream='http://etherx.jabber.org/streams' version='1.0' \
         from='{DOMAIN}' id='{id}' xml:lang='en'>"
    )
}

/// What the scripted server observed.
#[derive(Debug)]
struct Seen {
    login: String,
    room_join: String,
    said: String,
}

type Tls = tokio_rustls::server::TlsStream<tokio::net::TcpStream>;

/// The login half: stream, SASL PLAIN, restarted stream, resource binding.
/// Returns `None` if the credentials were refused.
async fn log_in(tls: &mut Tls, buffer: &mut String, password: &str) -> Option<String> {
    expect(tls, buffer, "<stream:stream").await;
    expect(tls, buffer, ">").await;
    let features = "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\
                    <mechanism>PLAIN</mechanism></mechanisms></stream:features>";
    tls.write_all(format!("{}{features}", header("one")).as_bytes())
        .await
        .unwrap();

    let auth = expect(tls, buffer, "</auth>").await;
    let payload = auth
        .rsplit_once('>')
        .and_then(|_| auth.split_once('>'))
        .map(|(_, rest)| rest.trim_end_matches("</auth>").to_owned())
        .unwrap();
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(payload.trim())
        .expect("PLAIN is base64");
    let login = String::from_utf8_lossy(&decoded).replace('\0', "|");

    if login != format!("|alice|{password}") {
        tls.write_all(
            b"<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>",
        )
        .await
        .unwrap();
        let _ = tls.flush().await;
        return None;
    }
    tls.write_all(b"<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        .await
        .unwrap();

    expect(tls, buffer, "<stream:stream").await;
    expect(tls, buffer, ">").await;
    // Stream management is offered on purpose: the client must decline to use
    // it (see `login` in xmpp/actor.rs), and the test asserts it did.
    let features = "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>                    <sm xmlns='urn:xmpp:sm:3'/></stream:features>";
    tls.write_all(format!("{}{features}", header("two")).as_bytes())
        .await
        .unwrap();

    let bind = expect(tls, buffer, "</iq>").await;
    let id = bind
        .split("id=")
        .nth(1)
        .and_then(|rest| rest.get(1..))
        .and_then(|rest| rest.split(['\'', '"']).next())
        .expect("the bind request has an id")
        .to_owned();
    tls.write_all(
        format!(
            "<iq type='result' id='{id}'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>\
             <jid>alice@{DOMAIN}/test</jid></bind></iq>"
        )
        .as_bytes(),
    )
    .await
    .unwrap();
    Some(login)
}

/// A server that logs the client in, lets it into one room with `bob` already
/// there, has bob say something, and records what the client says back.
async fn serve_room(listener: TcpListener, acceptor: TlsAcceptor) -> Seen {
    let (tcp, _) = listener.accept().await.unwrap();
    let mut tls = acceptor.accept(tcp).await.unwrap();
    let mut buffer = String::new();

    let login = log_in(&mut tls, &mut buffer, "hunter2")
        .await
        .expect("the right password is accepted");

    // The client sets itself up, then asks to join the room.
    let room_join = expect(&mut tls, &mut buffer, &format!("to='{ROOM}/alice'")).await;
    expect(&mut tls, &mut buffer, "</presence>").await;

    tls.write_all(
        format!(
            "<presence from='{ROOM}/bob'><x xmlns='http://jabber.org/protocol/muc#user'>\
             <item affiliation='none' role='moderator'/></x></presence>\
             <presence from='{ROOM}/alice'><x xmlns='http://jabber.org/protocol/muc#user'>\
             <item affiliation='none' role='participant'/><status code='110'/></x></presence>\
             <message type='groupchat' from='{ROOM}/bob' id='b1'><body>welcome, alice</body></message>"
        )
        .as_bytes(),
    )
    .await
    .unwrap();

    let said = expect(&mut tls, &mut buffer, "</message>").await;
    Seen {
        login,
        room_join,
        said,
    }
}

/// Wait for an event that `pick` accepts, passing over the ones that come
/// before it.
async fn wait_for<T>(
    events: &mut Receiver<IrcEvent>,
    mut pick: impl FnMut(&IrcEvent) -> Option<T>,
) -> T {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    loop {
        let event = tokio::time::timeout_at(deadline, events.recv())
            .await
            .expect("timed out waiting for an event")
            .expect("the actor stopped");
        if let Some(found) = pick(&event) {
            return found;
        }
    }
}

fn account(port: u16, pki: Option<&Pki>, password: &str) -> XmppConfig {
    XmppConfig {
        jid: format!("alice@{DOMAIN}"),
        password: Zeroizing::new(password.to_owned()),
        host: Some("127.0.0.1".to_owned()),
        port: Some(port),
        rooms: vec![ROOM.to_owned()],
        nickname: None,
        extra_root_cert: pki.map(|p| p.ca_path.to_string_lossy().into_owned()),
        proxy: None,
    }
}

async fn send(handle: &ConnectionHandle, command: ClientCommand) {
    handle.send(command).await.expect("the actor is running");
}

#[tokio::test]
async fn logs_in_joins_a_room_and_talks() {
    let pki = pki("talk");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(serve_room(listener, acceptor(&pki)));

    let (handle, mut events) = actor::spawn(account(port, Some(&pki), "hunter2"));

    wait_for(&mut events, |e| {
        matches!(
            e,
            IrcEvent::Status {
                status: ConnectionStatus::Connected,
                ..
            }
        )
        .then_some(())
    })
    .await;
    let registered = wait_for(&mut events, |e| match e {
        IrcEvent::Registered { nick, network, .. } => Some((nick.clone(), network.clone())),
        _ => None,
    })
    .await;
    assert_eq!(registered.0, "alice@example.org");
    assert_eq!(registered.1.as_deref(), Some("example.org"));

    wait_for(&mut events, |e| {
        matches!(e, IrcEvent::Joined { is_self: true, .. }).then_some(())
    })
    .await;
    let members = wait_for(&mut events, |e| match e {
        IrcEvent::MemberList { members, .. } => Some(members.clone()),
        _ => None,
    })
    .await;
    let nicks: Vec<_> = members
        .iter()
        .map(|m| (m.nick.as_str(), m.prefix.as_deref()))
        .collect();
    assert_eq!(nicks, [("bob", Some("@")), ("alice", None)]);

    let welcome = wait_for(&mut events, |e| match e {
        IrcEvent::Message(m) => Some((**m).clone()),
        _ => None,
    })
    .await;
    assert_eq!(welcome.target, Target::Channel(ROOM.to_owned()));
    assert_eq!(welcome.sender, "bob");

    send(
        &handle,
        ClientCommand::SendMessage {
            target: ROOM.to_owned(),
            text: "hello room".to_owned(),
        },
    )
    .await;
    let seen = tokio::time::timeout(TIMEOUT, server)
        .await
        .expect("the server finished")
        .expect("the server did not panic");
    assert_eq!(
        seen.login, "|alice|hunter2",
        "SCRAM would be preferred if offered"
    );
    assert!(seen.room_join.contains(&format!("{ROOM}/alice")));
    assert!(
        !seen.room_join.contains("urn:xmpp:sm:3") && !seen.said.contains("urn:xmpp:sm:3"),
        "the client asked for stream management, which it does not use: {}",
        seen.room_join
    );
    assert!(
        seen.said.contains("type=\"groupchat\"") || seen.said.contains("type='groupchat'"),
        "{}",
        seen.said
    );
    assert!(
        seen.said.contains("<body>hello room</body>"),
        "{}",
        seen.said
    );

    send(&handle, ClientCommand::Disconnect { reason: None }).await;
    wait_for(&mut events, |e| {
        matches!(
            e,
            IrcEvent::Status {
                status: ConnectionStatus::Disconnected,
                ..
            }
        )
        .then_some(())
    })
    .await;
}

#[tokio::test]
async fn a_wrong_password_is_reported_and_never_retried() {
    let pki = pki("wrong-password");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let acceptor = acceptor(&pki);

    // Accepts connections, refuses each, and counts them.
    let counter = Arc::new(std::sync::atomic::AtomicU32::new(0));
    let counted = counter.clone();
    let server = tokio::spawn(async move {
        loop {
            let Ok((tcp, _)) = listener.accept().await else {
                return;
            };
            counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                let mut tls = acceptor.accept(tcp).await.unwrap();
                let mut buffer = String::new();
                let _ = log_in(&mut tls, &mut buffer, "the-real-password").await;
                // Hold the line open so the client has to be the one to give up.
                tokio::time::sleep(Duration::from_secs(10)).await;
            });
        }
    });

    let (_handle, mut events) = actor::spawn(account(port, Some(&pki), "not-the-password"));

    let message = wait_for(&mut events, |e| match e {
        IrcEvent::Error {
            message,
            fatal: true,
        } => Some(message.clone()),
        _ => None,
    })
    .await;
    assert!(message.contains("password"), "{message}");
    wait_for(&mut events, |e| {
        matches!(
            e,
            IrcEvent::Status {
                status: ConnectionStatus::Disconnected,
                ..
            }
        )
        .then_some(())
    })
    .await;

    // The first backoff is two seconds at most. Wait past it: a client that
    // were going to try again would have, by now.
    tokio::time::sleep(Duration::from_millis(3_500)).await;
    assert_eq!(
        counter.load(std::sync::atomic::Ordering::SeqCst),
        1,
        "a refused password was tried again, which is how accounts get locked"
    );
    server.abort();
}

#[tokio::test]
async fn a_server_that_never_answers_is_given_up_on_after_a_few_tries() {
    // Nothing listening here.
    let closed = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = closed.local_addr().unwrap().port();
    drop(closed);

    let (_handle, mut events) = actor::spawn(account(port, None, "hunter2"));

    let mut failures = 0;
    loop {
        let event = tokio::time::timeout(Duration::from_secs(30), events.recv())
            .await
            .expect("timed out")
            .expect("the actor stopped");
        match event {
            IrcEvent::Error { fatal: false, .. } => failures += 1,
            IrcEvent::Error {
                message,
                fatal: true,
            } => {
                assert!(message.contains("Gave up"), "{message}");
                break;
            }
            _ => {}
        }
    }
    assert_eq!(failures, 2, "two retried failures, then the third gives up");
}

#[tokio::test]
async fn a_certificate_nobody_vouches_for_is_a_stop_not_a_retry() {
    let pki = pki("untrusted");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let acceptor = acceptor(&pki);
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let _ = acceptor.accept(tcp).await;
        }
    });

    // The same server, but the client has not been told to trust its CA.
    let (_handle, mut events) = actor::spawn(account(port, None, "hunter2"));
    let message = wait_for(&mut events, |e| match e {
        IrcEvent::Error {
            message,
            fatal: true,
        } => Some(message.clone()),
        _ => None,
    })
    .await;
    assert!(
        message.contains("not issued by an authority") || message.contains("certificate"),
        "{message}"
    );
}

#[tokio::test]
async fn an_invalid_account_is_refused_before_anything_is_dialled() {
    let mut config = account(5223, None, "hunter2");
    config.jid = "no-at-sign".to_owned();
    let (_handle, mut events) = actor::spawn(config);
    let event = tokio::time::timeout(TIMEOUT, events.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(
        matches!(event, IrcEvent::Error { fatal: true, .. }),
        "{event:?}"
    );
}
