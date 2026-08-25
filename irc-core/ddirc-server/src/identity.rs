//! The local server's TLS identity, and the trust anchor the client is given.
//!
//! # Why there is a certificate at all
//!
//! The client requires TLS on every connection and has no bypass — see
//! `ServerConfig` in `ddirc-core`, where `use_tls` is set unconditionally and
//! `dangerously_accept_invalid_certs` is never set. A local server that spoke
//! plaintext would therefore be unreachable from the very app it lives inside.
//! That is the same constraint that shaped `dev/`, and it has the same answer:
//! real TLS, with a certificate the client genuinely verifies.
//!
//! # Why generating one is safe here, when trusting a pasted one would not be
//!
//! `extra_root_cert` exists on the core's config and is deliberately absent
//! from the FFI type, so nothing the *user* can configure has ever been able to
//! add a trust root. That property is worth keeping: a control that says "trust
//! this certificate" is a control someone can be talked into using.
//!
//! Nothing here weakens it. The app is both ends of this connection — it issues
//! the certificate, and it is the only thing that will ever be shown it. No
//! certificate from outside the machine enters the trust store, the anchor is
//! scoped to one loopback address the app itself chose, and the private key is
//! generated locally and never sent anywhere.
//!
//! # The shape: a persisted CA, an ephemeral leaf
//!
//! The CA is written to disk because the client's trust anchor has to survive a
//! restart — otherwise every launch would present a certificate the app had not
//! yet been told to trust. The leaf is generated fresh in memory on every start
//! and never written anywhere, so the key that actually terminates connections
//! lives exactly as long as the server does.
//!
//! The CA's private key does sit on disk, since new leaves have to be signed.
//! Stealing it would let an attacker impersonate a server on this machine's own
//! loopback interface, to this user's own client — which is to say it buys
//! nothing that reading the same user's files did not already buy. It is still
//! written user-only, because defaults that are wrong by accident are how small
//! exposures become large ones.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use rcgen::{
    date_time_ymd, BasicConstraints, CertificateParams, DnType, IsCa, Issuer, KeyPair,
    KeyUsagePurpose,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};

/// The names the certificate is issued for.
///
/// Exactly the addresses a loopback client can use to reach it, and no others.
/// A certificate that also claimed a routable name would be one that could be
/// used off this machine if the key ever left it.
const NAMES: &[&str] = &["localhost", "127.0.0.1", "::1"];

/// The window on both certificates.
///
/// Wide on purpose. This is a private anchor for a loopback service, and what
/// actually bounds its life is the file existing — the leaf is thrown away at
/// every shutdown regardless of what its own validity says. A tight window
/// would add one failure mode and remove none: a machine with a wrong clock is
/// common, and it would present as the local server being mysteriously broken
/// rather than as anything to do with time.
const VALID_FROM: (i32, u8, u8) = (2020, 1, 1);
const VALID_UNTIL: (i32, u8, u8) = (2120, 1, 1);

/// The file the client is pointed at. The certificate alone, never the key.
const CA_CERT: &str = "local-server-ca.pem";
const CA_KEY: &str = "local-server-ca.key.pem";

#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error("could not read or write the local server's certificate at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("could not generate the local server's certificate: {0}")]
    Generate(#[from] rcgen::Error),
    #[error(
        "the local server's stored certificate at {0} is not usable; \
         delete it to have a new one issued"
    )]
    Corrupt(PathBuf),
}

/// A loaded CA, plus the freshly-issued leaf the listener will present.
pub struct Identity {
    /// The chain sent to the client: leaf first, then the CA that signed it.
    pub chain: Vec<CertificateDer<'static>>,
    /// The leaf's private key. In memory only.
    pub key: PrivateKeyDer<'static>,
    /// The file the client points `extra_root_cert` at.
    pub anchor_path: PathBuf,
}

impl std::fmt::Debug for Identity {
    /// Hand-written because the derived version would print the private key.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Identity")
            .field("chain_len", &self.chain.len())
            .field("key", &"<redacted>")
            .field("anchor_path", &self.anchor_path)
            .finish()
    }
}

/// Load the CA from `dir`, issuing one first if there is not one already, and
/// mint a leaf for this run.
pub fn load_or_create(dir: &Path) -> Result<Identity, IdentityError> {
    let cert_path = dir.join(CA_CERT);
    let key_path = dir.join(CA_KEY);

    fs::create_dir_all(dir).map_err(|source| IdentityError::Io {
        path: dir.to_path_buf(),
        source,
    })?;

    let (ca_pem, ca_key_pem) = match (read(&cert_path)?, read(&key_path)?) {
        (Some(cert), Some(key)) => (cert, key),
        // One without the other cannot be repaired, only replaced: a
        // certificate whose key is gone can sign nothing, and a key whose
        // certificate is gone has no name. Reissuing both is the only move
        // that leaves a working server.
        _ => {
            let (cert, key) = issue_ca()?;
            write_private(&key_path, &key)?;
            write(&cert_path, &cert)?;
            (cert, key)
        }
    };

    let ca_key =
        KeyPair::from_pem(&ca_key_pem).map_err(|_| IdentityError::Corrupt(key_path.clone()))?;
    let issuer = Issuer::new(ca_params()?, ca_key);

    let leaf_key = KeyPair::generate()?;
    let mut leaf = params(NAMES)?;
    leaf.distinguished_name
        .push(DnType::CommonName, "ddIRC local server");
    leaf.use_authority_key_identifier_extension = true;
    let leaf_cert = leaf.signed_by(&leaf_key, &issuer)?;

    let ca_der = pem_to_der(&ca_pem).ok_or_else(|| IdentityError::Corrupt(cert_path.clone()))?;

    Ok(Identity {
        chain: vec![
            CertificateDer::from(leaf_cert.der().to_vec()),
            CertificateDer::from(ca_der),
        ],
        key: PrivateKeyDer::try_from(leaf_key.serialize_der())
            .map_err(|_| IdentityError::Corrupt(key_path))?,
        anchor_path: cert_path,
    })
}

/// The CA's parameters, written once so that issuing it and later signing with
/// it cannot disagree about its name. A mismatch there produces a chain that
/// looks right and does not verify.
fn ca_params() -> Result<CertificateParams, IdentityError> {
    let mut ca = params(&[])?;
    ca.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    ca.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    ca.distinguished_name
        .push(DnType::CommonName, "ddIRC local server CA");
    Ok(ca)
}

fn params(names: &[&str]) -> Result<CertificateParams, IdentityError> {
    let names: Vec<String> = names.iter().map(|n| (*n).to_string()).collect();
    let mut p = CertificateParams::new(names)?;
    p.not_before = date_time_ymd(VALID_FROM.0, VALID_FROM.1, VALID_FROM.2);
    p.not_after = date_time_ymd(VALID_UNTIL.0, VALID_UNTIL.1, VALID_UNTIL.2);
    Ok(p)
}

fn issue_ca() -> Result<(String, String), IdentityError> {
    let key = KeyPair::generate()?;
    let cert = ca_params()?.self_signed(&key)?;
    Ok((cert.pem(), key.serialize_pem()))
}

fn read(path: &Path) -> Result<Option<String>, IdentityError> {
    match fs::read_to_string(path) {
        Ok(s) => Ok(Some(s)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(source) => Err(IdentityError::Io {
            path: path.to_path_buf(),
            source,
        }),
    }
}

fn write(path: &Path, contents: &str) -> Result<(), IdentityError> {
    fs::write(path, contents).map_err(|source| IdentityError::Io {
        path: path.to_path_buf(),
        source,
    })
}

/// Write a file only this user can read.
///
/// The mode is set as the file is created rather than afterwards, so there is
/// no window in which the key exists and is world-readable. Windows has no
/// equivalent bit; the app's data directory is already per-user there, which is
/// the same protection by a different mechanism.
fn write_private(path: &Path, contents: &str) -> Result<(), IdentityError> {
    let to_io = |source| IdentityError::Io {
        path: path.to_path_buf(),
        source,
    };

    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }

    use std::io::Write;
    let mut file = options.open(path).map_err(to_io)?;
    file.write_all(contents.as_bytes()).map_err(to_io)?;
    file.sync_all().map_err(to_io)
}

/// The one PEM block in `pem`, as DER.
///
/// Reads a file this crate wrote itself: one block, one type. `rustls-pemfile`
/// is in the tree and would also do, but it answers a more general question
/// than the one being asked.
fn pem_to_der(pem: &str) -> Option<Vec<u8>> {
    let body: String = pem
        .lines()
        .skip_while(|l| !l.starts_with("-----BEGIN"))
        .skip(1)
        .take_while(|l| !l.starts_with("-----END"))
        .collect();
    base64_decode(body.trim())
}

/// Standard base64. Small enough to write, and the alternative is reaching for
/// a dependency to serve one call.
fn base64_decode(s: &str) -> Option<Vec<u8>> {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::with_capacity(s.len() / 4 * 3);
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    for c in s.bytes() {
        if c == b'=' {
            break;
        }
        let v = TABLE.iter().position(|&t| t == c)? as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A directory that cleans itself up, so the tests leave no keys behind.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let mut p = std::env::temp_dir();
            p.push(format!("ddirc-server-identity-{tag}"));
            let _ = fs::remove_dir_all(&p);
            fs::create_dir_all(&p).unwrap();
            TempDir(p)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn issues_a_chain_and_an_anchor() {
        let dir = TempDir::new("issue");
        let id = load_or_create(&dir.0).unwrap();
        // Leaf then CA, so a client trusting the anchor can build the chain.
        assert_eq!(id.chain.len(), 2);
        assert!(id.anchor_path.is_file());
    }

    #[test]
    fn the_anchor_survives_a_restart_but_the_leaf_does_not() {
        let dir = TempDir::new("restart");
        let first = load_or_create(&dir.0).unwrap();
        let second = load_or_create(&dir.0).unwrap();

        // The trust anchor has to be the same across restarts, or every launch
        // would present something the client had not been told to trust.
        assert_eq!(first.chain[1], second.chain[1]);
        // The leaf must not be, or "in memory only" would not be true.
        assert_ne!(first.chain[0], second.chain[0]);
    }

    #[test]
    fn the_private_key_is_never_written_beside_the_anchor() {
        let dir = TempDir::new("secrets");
        let id = load_or_create(&dir.0).unwrap();
        let anchor = fs::read_to_string(&id.anchor_path).unwrap();
        assert!(anchor.contains("BEGIN CERTIFICATE"));
        assert!(
            !anchor.contains("PRIVATE KEY"),
            "the file handed to the client must be the certificate alone"
        );
    }

    #[test]
    fn a_lost_key_is_reissued_rather_than_left_broken() {
        let dir = TempDir::new("halfgone");
        let id = load_or_create(&dir.0).unwrap();
        fs::remove_file(dir.0.join(CA_KEY)).unwrap();

        // A certificate whose key is gone can sign nothing, so the only move
        // that leaves a working server is to reissue both.
        let after = load_or_create(&dir.0).unwrap();
        assert_ne!(id.chain[1], after.chain[1]);
    }

    #[test]
    fn the_anchor_on_disk_is_the_one_in_the_chain() {
        let dir = TempDir::new("pem");
        let id = load_or_create(&dir.0).unwrap();
        let pem = fs::read_to_string(&id.anchor_path).unwrap();
        assert_eq!(pem_to_der(&pem).unwrap(), id.chain[1].as_ref());
    }
}
