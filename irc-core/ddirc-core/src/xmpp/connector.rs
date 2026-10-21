//! The transport XMPP runs over: TLS from the first byte, through a SOCKS5
//! proxy when there is one.
//!
//! `tokio-xmpp` ships connectors of its own and none of them is used, for the
//! same reason `irc`'s is not trusted blindly: they look the server up
//! themselves. Their resolver asks DNS from this process, which announces the
//! name to whoever is watching the network even when a proxy was configured to
//! stop exactly that. Here the name goes to the proxy unresolved - SOCKS5 has a
//! field for a domain, and Tor resolves it at the far end - and with no proxy
//! the operating system's resolver is used, as it is for IRC.
//!
//! There is no STARTTLS and no plaintext mode. The stream starts inside TLS or
//! it does not start.

use std::borrow::Cow;
use std::fmt;
use std::io;
use std::sync::Arc;
use std::time::Duration;

use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, ServerName};
use rustls::{ClientConfig, RootCertStore};
use sasl::common::ChannelBinding;
use tokio::io::BufStream;
use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_rustls::client::TlsStream;
use tokio_rustls::TlsConnector;
use tokio_socks::tcp::Socks5Stream;
use tokio_xmpp::connect::ServerConnector;
use tokio_xmpp::jid::Jid;
use tokio_xmpp::xmlstream::{initiate_stream, PendingFeaturesRecv, StreamHeader, Timeouts};
use tokio_xmpp::Error;

use crate::api::types::ProxyConfig;
use crate::xmpp::config::{XmppConfig, XmppConfigError};

/// How long the TCP connection, the proxy handshake and the TLS handshake may
/// take between them.
///
/// Bounded because none of them is, on its own: a proxy that accepts and never
/// answers would otherwise hold a connection attempt open for ever. Generous,
/// because Tor circuits are slow to build and this is for the dead, not the
/// slow.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(60);

/// The ALPN protocol XEP-0368 asks a client to offer on a direct TLS port, so a
/// server sharing the port with something else can tell which it is talking to.
const ALPN: &[u8] = b"xmpp-client";

/// Why a connector could not be built.
#[derive(Debug, thiserror::Error)]
pub enum ConnectorError {
    #[error(transparent)]
    Config(#[from] XmppConfigError),
    #[error("could not read the certificate to trust: {0}")]
    Certificate(String),
}

/// The set of certificate authorities a connection is verified against.
///
/// The Mozilla list and the platform's store - what the `irc` crate trusts - plus
/// `extra` if given. *Added*, never a replacement: a server presenting a
/// certificate none of these vouch for is refused.
pub fn trust_store(extra_root_cert: Option<&str>) -> Result<RootCertStore, ConnectorError> {
    let mut roots = RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    // Unreadable platform certificates are skipped rather than fatal: a store
    // with one bad entry is still a store, and the Mozilla list is there either
    // way.
    roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
    if let Some(path) = extra_root_cert {
        add_pem(&mut roots, path)?;
    }
    Ok(roots)
}

/// Add every certificate in a PEM file, and fail if there were none.
///
/// The `irc` crate carries on silently when this goes wrong, which turns a
/// mistyped path into a handshake failure with no stated cause. Here the
/// failure is the cause.
fn add_pem(roots: &mut RootCertStore, path: &str) -> Result<(), ConnectorError> {
    let certificates = CertificateDer::pem_file_iter(path)
        .map_err(|e| ConnectorError::Certificate(e.to_string()))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| ConnectorError::Certificate(e.to_string()))?;
    let (added, _ignored) = roots.add_parsable_certificates(certificates);
    if added == 0 {
        return Err(ConnectorError::Certificate(format!(
            "{path} holds no certificate that could be used"
        )));
    }
    Ok(())
}

/// Direct TLS to an XMPP server, optionally through SOCKS5.
#[derive(Clone)]
pub struct DirectTlsConnector {
    host: String,
    port: u16,
    proxy: Option<ProxyConfig>,
    tls: Arc<ClientConfig>,
}

impl fmt::Debug for DirectTlsConnector {
    /// Not derived: the TLS configuration is a large structure that says
    /// nothing useful in a log, and the proxy's own `Debug` already redacts.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DirectTlsConnector")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("proxy", &self.proxy)
            .finish_non_exhaustive()
    }
}

impl DirectTlsConnector {
    /// A connector for `config`, trusting the usual roots.
    pub fn new(config: &XmppConfig) -> Result<Self, ConnectorError> {
        config.validate()?;
        let roots = trust_store(config.extra_root_cert.as_deref())?;
        Self::with_roots(config, roots)
    }

    /// A connector for `config`, trusting exactly `roots`. For tests, which
    /// should not depend on what the machine they run on happens to trust.
    pub fn with_roots(config: &XmppConfig, roots: RootCertStore) -> Result<Self, ConnectorError> {
        let mut tls = ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::aws_lc_rs::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .map_err(|e| ConnectorError::Certificate(e.to_string()))?
        .with_root_certificates(roots)
        .with_no_client_auth();
        tls.alpn_protocols = vec![ALPN.to_vec()];
        Ok(Self {
            host: config.dial_host()?,
            port: config.dial_port(),
            proxy: config.proxy.clone(),
            tls: Arc::new(tls),
        })
    }

    /// Open the TCP connection, directly or through the proxy.
    ///
    /// The proxy is given the host as a *name*. Resolving it here first would
    /// be a lookup the proxy exists to prevent.
    async fn dial(&self) -> io::Result<TcpStream> {
        let target = (self.host.as_str(), self.port);
        let Some(proxy) = &self.proxy else {
            return TcpStream::connect(target).await;
        };
        let proxy_address = (proxy.host.as_str(), proxy.port);
        let stream = match (&proxy.username, &proxy.password) {
            (Some(user), Some(password)) => {
                Socks5Stream::connect_with_password(proxy_address, target, user, password).await
            }
            _ => Socks5Stream::connect(proxy_address, target).await,
        }
        .map_err(io::Error::other)?;
        // Past the handshake the proxy is a pipe, and what comes out is the
        // plain connection TLS goes over.
        Ok(stream.into_inner())
    }

    async fn establish(&self, domain: &str) -> io::Result<(TlsStream<TcpStream>, ChannelBinding)> {
        let name = ServerName::try_from(domain.to_owned())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        let tcp = self.dial().await?;
        let tls = TlsConnector::from(self.tls.clone())
            .connect(name, tcp)
            .await?;
        // RFC 9266 `tls-exporter`, which SCRAM-PLUS binds the login to the
        // connection with. TLS 1.3 only; with 1.2 there is none, and the
        // mechanisms that need one are not offered.
        let (_, session) = tls.get_ref();
        let binding = match session.protocol_version() {
            Some(rustls::ProtocolVersion::TLSv1_3) => {
                let material = session
                    .export_keying_material(vec![0u8; 32], b"EXPORTER-Channel-Binding", None)
                    .map_err(io::Error::other)?;
                ChannelBinding::TlsExporter(material)
            }
            _ => ChannelBinding::None,
        };
        Ok((tls, binding))
    }
}

impl ServerConnector for DirectTlsConnector {
    type Stream = BufStream<TlsStream<TcpStream>>;

    async fn connect(
        &self,
        jid: &Jid,
        ns: &'static str,
        timeouts: Timeouts,
    ) -> Result<(PendingFeaturesRecv<Self::Stream>, ChannelBinding), Error> {
        let domain = jid.domain().as_str();
        // Verified against the account's domain, whatever was dialled: that is
        // the name the account's owner holds a certificate for.
        let (tls, binding) = timeout(CONNECT_TIMEOUT, self.establish(domain))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "connecting timed out"))??;
        let bare = jid.to_bare();
        let pending = initiate_stream(
            BufStream::new(tls),
            ns,
            StreamHeader {
                to: Some(Cow::Borrowed(domain)),
                // Servers want it to advertise SASL2 (XEP-0388).
                from: Some(Cow::Borrowed(bare.as_str())),
                id: None,
            },
            timeouts,
        )
        .await?;
        Ok((pending, binding))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use rcgen::{
        date_time_ymd, BasicConstraints, CertificateParams, DnType, IsCa, Issuer, KeyPair,
        KeyUsagePurpose,
    };
    use rustls::pki_types::{CertificateDer, PrivateKeyDer};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio_rustls::TlsAcceptor;
    use zeroize::Zeroizing;

    const DOMAIN: &str = "example.org";

    const SERVER_HEADER: &str = "<?xml version='1.0'?><stream:stream \
        xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' \
        version='1.0' from='example.org' id='test'><stream:features/>";

    /// A CA, and a certificate for [`DOMAIN`] signed by it.
    struct Pki {
        ca: CertificateDer<'static>,
        chain: Vec<CertificateDer<'static>>,
        key: Vec<u8>,
    }

    fn pki() -> Pki {
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
            .push(DnType::CommonName, "ddIRC test CA");
        let ca_cert = ca_params.clone().self_signed(&ca_key).unwrap();
        let issuer = Issuer::new(ca_params, ca_key);

        let leaf_key = KeyPair::generate().unwrap();
        let mut leaf = params(vec![DOMAIN.to_owned()]);
        leaf.use_authority_key_identifier_extension = true;
        let leaf_cert = leaf.signed_by(&leaf_key, &issuer).unwrap();
        Pki {
            ca: ca_cert.der().clone(),
            chain: vec![leaf_cert.der().clone(), ca_cert.der().clone()],
            key: leaf_key.serialize_der(),
        }
    }

    fn acceptor(pki: &Pki) -> TlsAcceptor {
        let mut config = rustls::ServerConfig::builder_with_provider(Arc::new(
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
        config.alpn_protocols = vec![ALPN.to_vec()];
        TlsAcceptor::from(Arc::new(config))
    }

    /// Serve one connection: finish TLS, read the client's stream header, answer
    /// with ours. Returns the ALPN protocol that was agreed and the header read.
    async fn serve_once(
        listener: TcpListener,
        acceptor: TlsAcceptor,
    ) -> Option<(Option<Vec<u8>>, String)> {
        let (tcp, _) = listener.accept().await.ok()?;
        let mut tls = acceptor.accept(tcp).await.ok()?;
        let alpn = tls.get_ref().1.alpn_protocol().map(<[u8]>::to_vec);
        let mut seen = Vec::new();
        let mut buf = [0u8; 1024];
        while !String::from_utf8_lossy(&seen).contains("<stream:stream") || !seen.ends_with(b">") {
            let n = tls.read(&mut buf).await.ok()?;
            if n == 0 {
                return None;
            }
            seen.extend_from_slice(&buf[..n]);
        }
        tls.write_all(SERVER_HEADER.as_bytes()).await.ok()?;
        tls.flush().await.ok()?;
        // Hold the connection open until the client has read the header.
        let _ = tokio::time::timeout(Duration::from_secs(2), tls.read(&mut buf)).await;
        Some((alpn, String::from_utf8_lossy(&seen).into_owned()))
    }

    fn account(host: &str, port: u16, proxy: Option<ProxyConfig>) -> XmppConfig {
        XmppConfig {
            jid: format!("alice@{DOMAIN}"),
            password: Zeroizing::new("hunter2".to_owned()),
            host: Some(host.to_owned()),
            port: Some(port),
            rooms: Vec::new(),
            nickname: None,
            extra_root_cert: None,
            proxy,
        }
    }

    fn trusting(pki: &Pki) -> RootCertStore {
        let mut roots = RootCertStore::empty();
        roots.add(pki.ca.clone()).unwrap();
        roots
    }

    async fn connect(connector: &DirectTlsConnector) -> Result<(), Error> {
        let jid: Jid = format!("alice@{DOMAIN}").parse().unwrap();
        connector
            .connect(&jid, "jabber:client", Timeouts::default())
            .await
            .map(|_| ())
    }

    #[tokio::test]
    async fn connects_over_tls_and_opens_the_stream() {
        let pki = pki();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(serve_once(listener, acceptor(&pki)));

        let connector =
            DirectTlsConnector::with_roots(&account("127.0.0.1", port, None), trusting(&pki))
                .unwrap();
        connect(&connector)
            .await
            .expect("a trusted server connects");

        let (alpn, header) = server.await.unwrap().expect("the server saw the client");
        assert_eq!(alpn.as_deref(), Some(ALPN), "XEP-0368 asks for this ALPN");
        assert!(header.contains("to='example.org'"), "{header}");
        assert!(header.contains("from='alice@example.org'"), "{header}");
    }

    #[tokio::test]
    async fn a_certificate_nobody_vouches_for_is_refused() {
        let pki = pki();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let _server = tokio::spawn(serve_once(listener, acceptor(&pki)));

        // The same server, with the CA left out of the trust store: the guard
        // that no verification-skipping path exists.
        let connector = DirectTlsConnector::with_roots(
            &account("127.0.0.1", port, None),
            RootCertStore::empty(),
        )
        .unwrap();
        let error = connect(&connector).await.expect_err("must not connect");
        assert!(
            error.to_string().to_lowercase().contains("certificate")
                || error.to_string().to_lowercase().contains("unknown"),
            "{error}"
        );
    }

    #[tokio::test]
    async fn the_certificate_must_be_for_the_accounts_domain() {
        let pki = pki();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let _server = tokio::spawn(serve_once(listener, acceptor(&pki)));

        // Dialled as one account, verified as another: the cert says example.org.
        let connector =
            DirectTlsConnector::with_roots(&account("127.0.0.1", port, None), trusting(&pki))
                .unwrap();
        let jid: Jid = "alice@other.example".parse().unwrap();
        let result = connector
            .connect(&jid, "jabber:client", Timeouts::default())
            .await;
        assert!(result.is_err(), "a certificate for another name is refused");
    }

    /// A SOCKS5 proxy that records what it was asked to reach, then tunnels to
    /// `onward` whatever that was.
    async fn socks_once(
        listener: TcpListener,
        onward: std::net::SocketAddr,
    ) -> Option<(u8, String, u16)> {
        let (mut client, _) = listener.accept().await.ok()?;
        let mut greeting = [0u8; 3];
        client.read_exact(&mut greeting).await.ok()?;
        client.write_all(&[5, 0]).await.ok()?;
        let mut head = [0u8; 4];
        client.read_exact(&mut head).await.ok()?;
        let atyp = head[3];
        let host = match atyp {
            3 => {
                let mut len = [0u8; 1];
                client.read_exact(&mut len).await.ok()?;
                let mut name = vec![0u8; len[0] as usize];
                client.read_exact(&mut name).await.ok()?;
                String::from_utf8(name).ok()?
            }
            1 => {
                let mut ip = [0u8; 4];
                client.read_exact(&mut ip).await.ok()?;
                std::net::Ipv4Addr::from(ip).to_string()
            }
            _ => return None,
        };
        let mut port = [0u8; 2];
        client.read_exact(&mut port).await.ok()?;
        client
            .write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
            .await
            .ok()?;
        let mut upstream = TcpStream::connect(onward).await.ok()?;
        let _ = tokio::time::timeout(
            Duration::from_secs(5),
            tokio::io::copy_bidirectional(&mut client, &mut upstream),
        )
        .await;
        Some((atyp, host, u16::from_be_bytes(port)))
    }

    #[tokio::test]
    async fn through_a_proxy_the_name_is_handed_over_unresolved() {
        let pki = pki();
        let server_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server_addr = server_listener.local_addr().unwrap();
        let _server = tokio::spawn(serve_once(server_listener, acceptor(&pki)));

        let proxy_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy_port = proxy_listener.local_addr().unwrap().port();
        let proxy = tokio::spawn(socks_once(proxy_listener, server_addr));

        // A name that resolves nowhere: if anything looked it up locally, the
        // connection would fail before reaching the proxy.
        let account = account(
            "xmpp.does-not-exist.invalid",
            5223,
            Some(ProxyConfig {
                host: "127.0.0.1".to_owned(),
                port: proxy_port,
                ..Default::default()
            }),
        );
        let connector = DirectTlsConnector::with_roots(&account, trusting(&pki)).unwrap();
        connect(&connector).await.expect("the proxy carries it");

        let (atyp, host, port) = proxy.await.unwrap().expect("the proxy saw a request");
        assert_eq!(atyp, 3, "SOCKS5 address type 3 is a domain name");
        assert_eq!(host, "xmpp.does-not-exist.invalid");
        assert_eq!(port, 5223);
    }

    #[tokio::test]
    async fn a_proxy_that_cannot_be_reached_is_an_error_not_a_direct_connection() {
        let pki = pki();
        // A server that would answer if dialled directly.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let _server = tokio::spawn(serve_once(listener, acceptor(&pki)));

        // Nothing listens here.
        let closed = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let dead_port = closed.local_addr().unwrap().port();
        drop(closed);

        let account = account(
            "127.0.0.1",
            port,
            Some(ProxyConfig {
                host: "127.0.0.1".to_owned(),
                port: dead_port,
                ..Default::default()
            }),
        );
        let connector = DirectTlsConnector::with_roots(&account, trusting(&pki)).unwrap();
        assert!(
            connect(&connector).await.is_err(),
            "a configured proxy that is down must not be quietly bypassed"
        );
    }

    #[test]
    fn an_extra_certificate_is_added_to_the_store() {
        let pki = pki();
        let mut pem = String::new();
        for line in [
            "-----BEGIN CERTIFICATE-----".to_owned(),
            base64_lines(&pki.ca),
            "-----END CERTIFICATE-----".to_owned(),
        ] {
            pem.push_str(&line);
            pem.push('\n');
        }
        let path = std::env::temp_dir().join("ddirc-xmpp-extra-root-test.pem");
        std::fs::write(&path, pem).unwrap();
        let mut roots = RootCertStore::empty();
        add_pem(&mut roots, path.to_str().unwrap()).expect("a real certificate is added");
        assert_eq!(roots.len(), 1);
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn a_file_with_no_certificate_in_it_is_an_error() {
        let path = std::env::temp_dir().join("ddirc-xmpp-empty-root-test.pem");
        std::fs::write(&path, "this is not a certificate\n").unwrap();
        let mut roots = RootCertStore::empty();
        assert!(add_pem(&mut roots, path.to_str().unwrap()).is_err());
        std::fs::remove_file(&path).unwrap();
    }

    fn base64_lines(der: &CertificateDer<'_>) -> String {
        use base64::Engine;
        let encoded = base64::engine::general_purpose::STANDARD.encode(der.as_ref());
        encoded
            .as_bytes()
            .chunks(64)
            .map(|c| std::str::from_utf8(c).unwrap())
            .collect::<Vec<_>>()
            .join("\n")
    }
}
