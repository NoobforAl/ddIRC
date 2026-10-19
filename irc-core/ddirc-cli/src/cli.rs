//! What was typed on the command line.
//!
//! Two programs live in this binary — a client and a server — and one of them
//! used to be the whole thing. Flags that predate the split, with no subcommand
//! in front of them, still mean the client: `ddirc-cli --server x --nick y` has
//! worked since the first day, and a dev script that breaks over a rename is a
//! bad trade for a tidier usage line.
//!
//! Passwords are read from the environment rather than argv, because command
//! lines are visible to other processes and land in shell history.

use std::path::PathBuf;

use ddirc_core::api::types::{ProxyConfig, ServerConfig};
use ddirc_server::state::{DEFAULT_NETWORK_NAME, DEFAULT_SERVER_NAME};
use zeroize::Zeroizing;

pub const USAGE: &str = "\
ddirc-cli — an IRC client and an IRC server for the terminal

USAGE:
    ddirc-cli client --nick <NICK> [OPTIONS]
    ddirc-cli server [OPTIONS]
    ddirc-cli <client options>           same as `client`

Each has a full-screen interface. Pass --no-tui for plain lines instead; that
is also what you get when the output is not a terminal.

Run `ddirc-cli client --help` or `ddirc-cli server --help` for the options.
";

pub const CLIENT_USAGE: &str = "\
ddirc-cli client — connect to an IRC server

USAGE:
    ddirc-cli client --nick <NICK> [OPTIONS]

OPTIONS:
    --server <HOST>        Server hostname [default: irc.libera.chat]
    --port <PORT>          TLS port [default: 6697]
    --nick <NICK>          Nickname (required)
    --channel <CHANNEL>    Channel to join; repeatable
    --sasl-account <NAME>  SASL account name
    --ca-file <PATH>       Also trust this certificate, e.g. dev/ergo/fullchain.pem
    --proxy <HOST:PORT>    Dial through a SOCKS5 proxy, e.g. 127.0.0.1:9050
    --proxy-user <NAME>    SOCKS5 username (needs DDIRC_PROXY_PASSWORD)
    --no-tui               Plain lines on stdin and stdout, no full screen
    --log-file <PATH>      Write the core's diagnostics here (full-screen mode
                           has nowhere else to put them)

ENVIRONMENT:
    DDIRC_SASL_PASSWORD      SASL password (with --sasl-account)
    DDIRC_NICKSERV_PASSWORD  NickServ password, used only if SASL is unavailable
    DDIRC_SERVER_PASSWORD    Server-level PASS
    DDIRC_PROXY_PASSWORD     SOCKS5 password (with --proxy-user)

COMMANDS (once connected; F1 shows them in the full-screen interface):
    /join #channel     /part [#channel] [reason]    /nick <new>
    /me <action>       /msg <target> <text>         /query <nick>
    /topic <text>      /kick <nick> [reason]        /whois <nick>
    /list              /close                       /clear
    /quit [reason]     Anything else is sent to the current conversation
";

pub const SERVER_USAGE: &str = "\
ddirc-cli server — run an IRC server

The server listens on this machine only (127.0.0.1 and ::1), over TLS, with a
certificate it issues itself. A client has to be told to trust that certificate;
the line printed at startup shows how.

USAGE:
    ddirc-cli server [OPTIONS]

OPTIONS:
    --port <PORT>        TLS port [default: 6697]; 0 picks a free one
    --name <NAME>        What the server calls itself [default: ddirc.local]
    --network <NAME>     What it calls the network [default: Local]
    --motd <LINE>        A line of the message of the day; repeatable
    --data-dir <PATH>    Where its certificate authority is kept
    --no-tui             Print a log to stdout and take no input, instead of
                         the full-screen manager. Ctrl-C stops it. This is
                         also what you get when the output is not a terminal.

In the full-screen manager you can see who is connected and what channels
exist, and kick, disconnect or ban people, close channels, set topics, give and
take operator status, and send notices. F1 lists the keys and commands.
";

/// What the user asked for.
#[derive(Debug)]
pub enum Parsed {
    Help(&'static str),
    Client(Box<ClientArgs>),
    Server(ServerArgs),
}

#[derive(Debug)]
pub struct ClientArgs {
    pub config: ServerConfig,
    pub tui: bool,
    pub log_file: Option<PathBuf>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct ServerArgs {
    pub port: u16,
    pub name: String,
    pub network: String,
    pub motd: Vec<String>,
    pub data_dir: PathBuf,
    pub tui: bool,
}

/// Parse argv (without the program name).
pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Parsed, String> {
    let mut args: Vec<String> = args.into_iter().collect();
    match args.first().map(String::as_str) {
        Some("server") => {
            args.remove(0);
            parse_server(args)
        }
        Some("client") => {
            args.remove(0);
            parse_client(args)
        }
        Some("-h" | "--help" | "help") => Ok(Parsed::Help(USAGE)),
        // No subcommand: the flags are the client's, as they always were.
        _ => parse_client(args),
    }
}

fn parse_client(args: Vec<String>) -> Result<Parsed, String> {
    let mut config = ServerConfig {
        host: "irc.libera.chat".to_owned(),
        port: ServerConfig::DEFAULT_TLS_PORT,
        ..Default::default()
    };

    let mut tui = true;
    let mut log_file = None;
    let mut proxy_user = None;
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Ok(Parsed::Help(CLIENT_USAGE)),
            "--server" => config.host = value()?,
            "--port" => {
                let raw = value()?;
                config.port = raw.parse().map_err(|_| format!("invalid port: {raw}"))?;
            }
            "--nick" => config.nickname = value()?,
            "--channel" => config.channels.push(value()?),
            "--sasl-account" => config.sasl_account = Some(value()?),
            // Adds a trusted root for this connection; verification stays on.
            // For the dev server's self-signed certificate — see dev/README.md.
            "--ca-file" => config.extra_root_cert = Some(value()?),
            "--proxy" => config.proxy = Some(parse_proxy(&value()?)?),
            "--proxy-user" => proxy_user = Some(value()?),
            "--no-tui" => tui = false,
            "--log-file" => log_file = Some(PathBuf::from(value()?)),
            other => return Err(format!("unrecognised argument: {other}")),
        }
    }

    if config.nickname.is_empty() {
        return Err("--nick is required".to_owned());
    }

    // Secrets come from the environment, never argv.
    config.sasl_password = secret("DDIRC_SASL_PASSWORD");
    config.nickserv_password = secret("DDIRC_NICKSERV_PASSWORD");
    config.server_password = secret("DDIRC_SERVER_PASSWORD");

    if config.sasl_account.is_some() && config.sasl_password.is_none() {
        return Err("--sasl-account requires DDIRC_SASL_PASSWORD to be set".to_owned());
    }
    if config.sasl_password.is_some() && config.sasl_account.is_none() {
        return Err("DDIRC_SASL_PASSWORD requires --sasl-account".to_owned());
    }

    if let Some(proxy) = &mut config.proxy {
        proxy.username = proxy_user;
        proxy.password = secret("DDIRC_PROXY_PASSWORD");
    } else if proxy_user.is_some() {
        return Err("--proxy-user requires --proxy".to_owned());
    }
    // Left to `validate` to reject a half credential, so the harness and the
    // app refuse the same configurations for the same stated reasons.

    Ok(Parsed::Client(Box::new(ClientArgs {
        config,
        tui,
        log_file,
    })))
}

fn parse_server(args: Vec<String>) -> Result<Parsed, String> {
    let mut out = ServerArgs {
        port: 6697,
        name: DEFAULT_SERVER_NAME.to_owned(),
        network: DEFAULT_NETWORK_NAME.to_owned(),
        motd: Vec::new(),
        data_dir: default_data_dir(),
        tui: true,
    };

    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Ok(Parsed::Help(SERVER_USAGE)),
            "--port" => {
                let raw = value()?;
                out.port = raw.parse().map_err(|_| format!("invalid port: {raw}"))?;
            }
            "--name" => out.name = word(&arg, value()?)?,
            "--network" => out.network = word(&arg, value()?)?,
            "--motd" => out.motd.push(value()?),
            "--data-dir" => out.data_dir = PathBuf::from(value()?),
            "--no-tui" => out.tui = false,
            other => return Err(format!("unrecognised argument: {other}")),
        }
    }
    Ok(Parsed::Server(out))
}

/// A name that ends up in the middle of protocol lines, so it cannot be allowed
/// to carry a space or a control character into one.
fn word(flag: &str, value: String) -> Result<String, String> {
    if value.is_empty() || value.contains(|c: char| c.is_whitespace() || c.is_control()) {
        Err(format!("{flag} must be a single word"))
    } else {
        Ok(value)
    }
}

/// Parse `host:port` for `--proxy`.
///
/// One colon only, for the same reason the app's address box splits on one:
/// a bare IPv6 literal has several, and `[::1]:9050` has none outside the
/// brackets. The port is required — guessing between 9050 and 1080 on the
/// user's behalf would be guessing which proxy they meant.
fn parse_proxy(raw: &str) -> Result<ProxyConfig, String> {
    let (host, port) = raw
        .rsplit_once(':')
        .ok_or_else(|| format!("--proxy needs host:port, got {raw}"))?;
    let host = host.trim_start_matches('[').trim_end_matches(']');
    let port: u16 = port
        .parse()
        .map_err(|_| format!("invalid proxy port: {port}"))?;
    Ok(ProxyConfig {
        host: host.to_owned(),
        port,
        ..Default::default()
    })
}

/// Read a secret from the environment and remove it from our own environment,
/// so it is not inherited by anything we might later spawn.
fn secret(name: &str) -> Option<Zeroizing<String>> {
    let value = std::env::var(name).ok()?;
    std::env::remove_var(name);
    (!value.is_empty()).then(|| Zeroizing::new(value))
}

/// Where the server keeps its certificate authority when not told.
///
/// Per-user and out of the way, because the CA's private key is in it: a
/// current-directory default would drop that key into whatever repository
/// someone happened to be standing in. No crate for this — three platforms'
/// conventions are three lines, and a dependency to avoid them would be the
/// larger thing.
fn default_data_dir() -> PathBuf {
    let var = |name: &str| {
        std::env::var_os(name)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    };
    let base = if cfg!(windows) {
        var("LOCALAPPDATA")
    } else if cfg!(target_os = "macos") {
        var("HOME").map(|h| h.join("Library").join("Application Support"))
    } else {
        var("XDG_DATA_HOME").or_else(|| var("HOME").map(|h| h.join(".local").join("share")))
    };
    base.unwrap_or_else(std::env::temp_dir)
        .join("ddirc")
        .join("server")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_str(line: &str) -> Result<Parsed, String> {
        parse(line.split_whitespace().map(str::to_owned))
    }

    #[test]
    fn a_proxy_is_parsed_as_host_and_port() {
        let proxy = parse_proxy("127.0.0.1:9050").expect("should parse");
        assert_eq!(proxy.host, "127.0.0.1");
        assert_eq!(proxy.port, 9050);

        // An IPv6 literal keeps its own colons and loses only the brackets.
        let proxy = parse_proxy("[::1]:1080").expect("should parse");
        assert_eq!(proxy.host, "::1");
        assert_eq!(proxy.port, 1080);

        assert!(parse_proxy("127.0.0.1").is_err());
        assert!(parse_proxy("127.0.0.1:not-a-port").is_err());
    }

    #[test]
    fn flags_with_no_subcommand_still_mean_the_client() {
        let Ok(Parsed::Client(args)) = parse_str("--server localhost --nick me --channel #a")
        else {
            panic!("expected the client");
        };
        assert_eq!(args.config.host, "localhost");
        assert_eq!(args.config.channels, vec!["#a".to_owned()]);
        assert!(args.tui, "the full-screen interface is the default");

        let Ok(Parsed::Client(args)) = parse_str("client --nick me --no-tui") else {
            panic!("expected the client");
        };
        assert!(!args.tui);
    }

    #[test]
    fn the_client_still_needs_a_nick() {
        assert!(parse_str("client --server x").is_err());
    }

    #[test]
    fn the_server_has_sensible_defaults() {
        let Ok(Parsed::Server(args)) = parse_str("server") else {
            panic!("expected the server");
        };
        assert_eq!(args.port, 6697);
        assert_eq!(args.name, "ddirc.local");
        assert_eq!(args.network, "Local");
        assert!(args.tui);
        assert!(args.data_dir.ends_with("server"));
    }

    #[test]
    fn server_options_are_read() {
        let Ok(Parsed::Server(args)) =
            parse_str("server --port 0 --name irc.test --network Test --motd hello --motd world --no-tui --data-dir x")
        else {
            panic!("expected the server");
        };
        assert_eq!(args.port, 0);
        assert_eq!(args.name, "irc.test");
        assert_eq!(args.network, "Test");
        assert_eq!(args.motd, vec!["hello".to_owned(), "world".to_owned()]);
        assert_eq!(args.data_dir, PathBuf::from("x"));
        assert!(!args.tui);
    }

    #[test]
    fn names_that_would_break_a_protocol_line_are_refused() {
        let spaced = parse(
            ["server", "--name", "two words"]
                .into_iter()
                .map(str::to_owned),
        );
        assert!(spaced.is_err());
        assert!(parse_str("server --port nope").is_err());
        assert!(parse_str("server --wat").is_err());
    }

    #[test]
    fn help_is_per_subcommand() {
        assert!(matches!(parse_str("--help"), Ok(Parsed::Help(u)) if u == USAGE));
        assert!(matches!(parse_str("client -h"), Ok(Parsed::Help(u)) if u == CLIENT_USAGE));
        assert!(matches!(parse_str("server --help"), Ok(Parsed::Help(u)) if u == SERVER_USAGE));
    }
}
