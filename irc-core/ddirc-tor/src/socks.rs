//! A SOCKS5 listener on loopback, with Tor on the other side of it.
//!
//! The app already knows how to talk to a SOCKS5 proxy — that is how it has
//! reached Tor since the day the proxy setting existed, and it is what every
//! test of that path exercises. Bundling Tor therefore does not need a new way
//! for a connection to leave the app; it needs the proxy to be *here* instead
//! of somewhere the user was expected to have installed.
//!
//! So this speaks the same protocol the external Tor daemon speaks, on a port
//! the app chose, and the connection path above it does not change at all.
//! Nothing else was worth the alternative: giving the core a second transport
//! would mean a second implementation of connect, of proxy reporting, and of
//! every failure message about them, all to reach the same circuits.
//!
//! Only `CONNECT` is implemented. `BIND` and `UDP ASSOCIATE` are refused with
//! the code that says so, because Tor cannot carry either and answering as if
//! it could is worse than answering no.

use std::io;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::sync::Arc;

use arti_client::{StreamPrefs, TorClient};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tor_rtcompat::PreferredRuntime;

const VERSION: u8 = 5;
const NO_AUTH: u8 = 0x00;
const NO_ACCEPTABLE: u8 = 0xFF;

const CMD_CONNECT: u8 = 0x01;

const ATYP_V4: u8 = 0x01;
const ATYP_DOMAIN: u8 = 0x03;
const ATYP_V6: u8 = 0x04;

const REP_OK: u8 = 0x00;
const REP_FAILED: u8 = 0x01;
const REP_UNREACHABLE: u8 = 0x04;
const REP_CMD_UNSUPPORTED: u8 = 0x07;
const REP_ATYP_UNSUPPORTED: u8 = 0x08;

/// Accept forever, one task per connection.
///
/// Returns only when the listener itself fails, which on loopback means the
/// socket was closed under it — that is the shutdown path, not an error worth
/// reporting upwards.
pub async fn serve(listener: TcpListener, client: Arc<TorClient<PreferredRuntime>>) {
    loop {
        let (socket, from) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(e) => {
                tracing::debug!("tor: the SOCKS listener stopped accepting: {e}");
                return;
            }
        };
        let client = client.clone();
        tokio::spawn(async move {
            if let Err(e) = handle(socket, client).await {
                // Debug, not warn: a client that hangs up mid-handshake is
                // ordinary, and this is the app talking to itself.
                tracing::debug!("tor: SOCKS connection from {from} ended: {e}");
            }
        });
    }
}

async fn handle(
    mut inbound: TcpStream,
    client: Arc<TorClient<PreferredRuntime>>,
) -> io::Result<()> {
    // Nagle off for the same reason as everywhere else here: what travels over
    // this is IRC, which is small messages that matter immediately.
    let _ = inbound.set_nodelay(true);

    greet(&mut inbound).await?;
    let (host, port) = match request(&mut inbound).await? {
        Some(target) => target,
        // `request` has already sent the reply saying why.
        None => return Ok(()),
    };

    // A circuit per connection.
    //
    // Each network the app is connected to gets its own path through the
    // network, so two networks cannot be tied together by having arrived at
    // the same exit at the same moment. IRC connections are few and long
    // lived, which is exactly the shape where this costs almost nothing — the
    // usual objection to isolating every stream is a browser opening hundreds.
    let mut prefs = StreamPrefs::new();
    prefs.isolate_every_stream();

    let stream = match client.connect_with_prefs((host.as_str(), port), &prefs).await {
        Ok(stream) => stream,
        Err(e) => {
            tracing::debug!("tor: could not reach {host}:{port}: {e}");
            reply(&mut inbound, REP_UNREACHABLE).await?;
            return Ok(());
        }
    };
    reply(&mut inbound, REP_OK).await?;

    // The bound address in the reply is `0.0.0.0:0`, and truthfully so: there
    // is no local socket to name, because the far end of this is a circuit.
    let mut stream = stream;
    tokio::io::copy_bidirectional(&mut inbound, &mut stream).await?;
    Ok(())
}

/// The method negotiation. No authentication, because there is nobody else on
/// this socket: it is loopback, and both ends are this process.
async fn greet(inbound: &mut TcpStream) -> io::Result<()> {
    let mut head = [0u8; 2];
    inbound.read_exact(&mut head).await?;
    if head[0] != VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("not SOCKS5: version byte {}", head[0]),
        ));
    }
    let mut methods = vec![0u8; head[1] as usize];
    inbound.read_exact(&mut methods).await?;
    if !methods.contains(&NO_AUTH) {
        inbound.write_all(&[VERSION, NO_ACCEPTABLE]).await?;
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the client offered no authentication method this proxy accepts",
        ));
    }
    inbound.write_all(&[VERSION, NO_AUTH]).await?;
    Ok(())
}

/// The CONNECT request, or `None` if it was refused — in which case the reply
/// saying so has already been written.
async fn request(inbound: &mut TcpStream) -> io::Result<Option<(String, u16)>> {
    let mut head = [0u8; 4];
    inbound.read_exact(&mut head).await?;
    if head[0] != VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the request did not repeat the SOCKS version",
        ));
    }
    if head[1] != CMD_CONNECT {
        reply(inbound, REP_CMD_UNSUPPORTED).await?;
        return Ok(None);
    }

    let host = match head[3] {
        ATYP_V4 => {
            let mut octets = [0u8; 4];
            inbound.read_exact(&mut octets).await?;
            Ipv4Addr::from(octets).to_string()
        }
        // The one that matters. A hostname sent as a hostname is a hostname
        // Tor resolves at the exit; resolving it here first would put the
        // lookup on this machine's DNS, which is the leak this whole feature
        // exists to close.
        ATYP_DOMAIN => {
            let mut len = [0u8; 1];
            inbound.read_exact(&mut len).await?;
            let mut name = vec![0u8; len[0] as usize];
            inbound.read_exact(&mut name).await?;
            match String::from_utf8(name) {
                Ok(name) => name,
                Err(_) => {
                    reply(inbound, REP_FAILED).await?;
                    return Ok(None);
                }
            }
        }
        ATYP_V6 => {
            let mut octets = [0u8; 16];
            inbound.read_exact(&mut octets).await?;
            Ipv6Addr::from(octets).to_string()
        }
        _ => {
            reply(inbound, REP_ATYP_UNSUPPORTED).await?;
            return Ok(None);
        }
    };

    let mut port = [0u8; 2];
    inbound.read_exact(&mut port).await?;
    Ok(Some((host, u16::from_be_bytes(port))))
}

async fn reply(inbound: &mut TcpStream, code: u8) -> io::Result<()> {
    inbound
        .write_all(&[VERSION, code, 0x00, ATYP_V4, 0, 0, 0, 0, 0, 0])
        .await
}
