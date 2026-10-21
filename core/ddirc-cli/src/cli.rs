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

use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::{ProxyConfig, ServerConfig};
use ddirc_core::conn::actor::{self, ConnectionHandle};
use ddirc_core::xmpp::config::XmppConfig;
use ddirc_server::state::{DEFAULT_NETWORK_NAME, DEFAULT_SERVER_NAME};
use tokio::sync::mpsc::Receiver;
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

    ddirc-cli client --xmpp <ADDRESS> [OPTIONS]      an XMPP account instead

OPTIONS:
    --server <HOST>        Server hostname [default: irc.libera.chat]; for
                           --xmpp, only if it is not the address's own domain
    --port <PORT>          TLS port [default: 6697; 5223 for --xmpp]
    --nick <NICK>          Nickname (required; not used with --xmpp)
    --xmpp <ADDRESS>       Log in to an XMPP account, e.g. alice@example.org.
                           The password is read from DDIRC_XMPP_PASSWORD.
    --channel <CHANNEL>    Channel to join; repeatable. With --xmpp, a room
                           address such as lobby@conference.example.org
    --sasl-account <NAME>  SASL account name
    --ca-file <PATH>       Also trust this certificate, e.g. dev/ergo/fullchain.pem
    --proxy <HOST:PORT>    Dial through a SOCKS5 proxy, e.g. 127.0.0.1:9050
    --proxy-user <NAME>    SOCKS5 username (needs DDIRC_PROXY_PASSWORD)
    --no-tui               Plain lines on stdin and stdout, no full screen
    --log-file <PATH>      Write the core's diagnostics here (full-screen mode
                           has nowhere else to put them)

ENVIRONMENT:
    DDIRC_XMPP_PASSWORD      XMPP account password (with --xmpp)
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
    pub connection: Connection,
    pub tui: bool,
    pub log_file: Option<PathBuf>,
}

/// What the client connects to: an IRC network or an XMPP account.
///
/// One type so everything past parsing - the screens, the plain mode - holds a
/// connection and does not care which kind. They differ in how they start, and
/// in a few words (what the server buffer is called, how to describe it).
#[derive(Debug)]
pub enum Connection {
    Irc(ServerConfig),
    Xmpp(XmppConfig),
}

impl Connection {
    pub fn is_xmpp(&self) -> bool {
        matches!(self, Self::Xmpp(_))
    }

    pub fn validate(&self) -> Result<(), String> {
        match self {
            Self::Irc(config) => config.validate().map_err(|e| e.to_string()),
            Self::Xmpp(config) => config.validate().map_err(|e| e.to_string()),
        }
    }

    /// Who we are: the nickname, or the account's address.
    pub fn nick(&self) -> String {
        match self {
            Self::Irc(config) => config.nickname.clone(),
            Self::Xmpp(config) => config.jid.clone(),
        }
    }

    /// What the server buffer is called.
    pub fn host(&self) -> String {
        match self {
            Self::Irc(config) => config.host.clone(),
            Self::Xmpp(config) => config.dial_host().unwrap_or_default(),
        }
    }

    pub fn first_channel(&self) -> Option<String> {
        match self {
            Self::Irc(config) => config.channels.first().cloned(),
            Self::Xmpp(config) => config.rooms.first().cloned(),
        }
    }

    /// One line saying where this goes, for the plain mode's first output.
    pub fn describe(&self) -> String {
        let (target, proxy) = match self {
            Self::Irc(config) => (
                format!("{}:{} as {}", config.host, config.port, config.nickname),
                &config.proxy,
            ),
            Self::Xmpp(config) => (
                format!(
                    "{}:{} as {}",
                    config.dial_host().unwrap_or_default(),
                    config.dial_port(),
                    config.jid
                ),
                &config.proxy,
            ),
        };
        let via = match proxy {
            Some(proxy) => format!(", via SOCKS5 {}:{}", proxy.host, proxy.port),
            None => String::new(),
        };
        format!("connecting to {target} (TLS{via})")
    }

    /// Start the connection. Must be called inside a runtime.
    pub fn spawn(self) -> (ConnectionHandle, Receiver<IrcEvent>) {
        match self {
            Self::Irc(config) => actor::spawn(config),
            Self::Xmpp(config) => ddirc_core::xmpp::actor::spawn(config),
        }
    }
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
    // Whether the server or port was given, which only matters for an XMPP
    // account: there they are an override, not a default to start from.
    let mut server_given = false;
    let mut port_given = false;
    let mut xmpp = None;

    let mut tui = true;
    let mut log_file = None;
    let mut proxy_user = None;
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Ok(Parsed::Help(CLIENT_USAGE)),
            "--server" => {
                config.host = value()?;
                server_given = true;
            }
            "--port" => {
                let raw = value()?;
                config.port = raw.parse().map_err(|_| format!("invalid port: {raw}"))?;
                port_given = true;
            }
            "--xmpp" => xmpp = Some(value()?),
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

    if let Some(jid) = xmpp {
        // The flags that are IRC's, refused rather than quietly ignored: a
        // --sasl-account given to an XMPP login is a mistake worth saying.
        if !config.nickname.is_empty() || config.sasl_account.is_some() {
            return Err(
                "--nick and --sasl-account are IRC's, and do not apply with --xmpp".to_owned(),
            );
        }
        let password = secret("DDIRC_XMPP_PASSWORD")
            .ok_or_else(|| "--xmpp requires DDIRC_XMPP_PASSWORD to be set".to_owned())?;
        let mut account = XmppConfig {
            jid,
            password,
            host: server_given.then_some(config.host),
            port: port_given.then_some(config.port),
            rooms: config.channels,
            nickname: None,
            extra_root_cert: config.extra_root_cert,
            proxy: config.proxy,
        };
        if let Some(proxy) = &mut account.proxy {
            proxy.username = proxy_user;
            proxy.password = secret("DDIRC_PROXY_PASSWORD");
        } else if proxy_user.is_some() {
            return Err("--proxy-user requires --proxy".to_owned());
        }
        return Ok(Parsed::Client(Box::new(ClientArgs {
            connection: Connection::Xmpp(account),
            tui,
            log_file,
        })));
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
        connection: Connection::Irc(config),
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
        data_dir: PathBuf::new(),
        tui: true,
    };
    let mut data_dir = None;

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
            "--data-dir" => data_dir = Some(PathBuf::from(value()?)),
            "--no-tui" => out.tui = false,
            other => return Err(format!("unrecognised argument: {other}")),
        }
    }
    // After the loop, so `--help` works on a machine with no such directory.
    out.data_dir = resolve_data_dir(data_dir, default_data_dir())?;
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

/// Where the server keeps its certificate authority when not told, if there is
/// somewhere that belongs to this user.
///
/// Per-user and out of the way, because the CA's private key is in it: a
/// current-directory default would drop that key into whatever repository
/// someone happened to be standing in. No crate for this — three platforms'
/// conventions are three lines, and a dependency to avoid them would be the
/// larger thing.
///
/// `None` when the environment gives no such place, and that is deliberately not
/// papered over with the temporary directory: that is shared, and a CA key left
/// in a shared place is one another user could read the directory of, replace,
/// or pre-create. See [`resolve_data_dir`].
fn default_data_dir() -> Option<PathBuf> {
    default_data_dir_from(|name| {
        std::env::var_os(name)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    })
}

/// [`default_data_dir`] over any source of environment variables, so the
/// absence of one can be tested without unsetting a real one.
fn default_data_dir_from(var: impl Fn(&str) -> Option<PathBuf>) -> Option<PathBuf> {
    let base = if cfg!(windows) {
        var("LOCALAPPDATA")
    } else if cfg!(target_os = "macos") {
        var("HOME").map(|h| h.join("Library").join("Application Support"))
    } else {
        var("XDG_DATA_HOME").or_else(|| var("HOME").map(|h| h.join(".local").join("share")))
    };
    base.map(|b| b.join("ddirc").join("server"))
}

/// The directory to use: what was asked for, else the per-user default, else an
/// error that says how to fix it.
fn resolve_data_dir(
    explicit: Option<PathBuf>,
    default: Option<PathBuf>,
) -> Result<PathBuf, String> {
    explicit.or(default).ok_or_else(|| {
        "no per-user data directory could be found (LOCALAPPDATA, XDG_DATA_HOME or HOME is \
         not set), and the server's private key will not be kept in a shared one; pass \
         --data-dir"
            .to_owned()
    })
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
        let Connection::Irc(config) = &args.connection else {
            panic!("expected an IRC network");
        };
        assert_eq!(config.host, "localhost");
        assert_eq!(config.channels, vec!["#a".to_owned()]);
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
    fn an_xmpp_account_is_an_address_and_a_password_from_the_environment() {
        std::env::set_var("DDIRC_XMPP_PASSWORD", "hunter2");
        let Ok(Parsed::Client(args)) = parse_str(
            "client --xmpp alice@example.org --channel lobby@conference.example.org --no-tui",
        ) else {
            panic!("expected the client");
        };
        let Connection::Xmpp(account) = &args.connection else {
            panic!("expected an XMPP account");
        };
        assert_eq!(account.jid, "alice@example.org");
        assert_eq!(
            account.rooms,
            vec!["lobby@conference.example.org".to_owned()]
        );
        assert_eq!(account.password.as_str(), "hunter2");
        assert_eq!(account.host, None, "the address names the server");
        assert_eq!(account.port, None);
        assert!(args.connection.is_xmpp());
        assert_eq!(args.connection.nick(), "alice@example.org");
        assert_eq!(args.connection.host(), "example.org");
        assert!(!args.tui);
        // And the password is not left in this process's environment.
        assert!(std::env::var("DDIRC_XMPP_PASSWORD").is_err());
    }

    #[test]
    fn an_xmpp_server_and_port_are_overrides() {
        std::env::set_var("DDIRC_XMPP_PASSWORD", "hunter2");
        let Ok(Parsed::Client(args)) =
            parse_str("client --xmpp alice@example.org --server xmpp.host.example --port 5443")
        else {
            panic!("expected the client");
        };
        let Connection::Xmpp(account) = &args.connection else {
            panic!("expected an XMPP account");
        };
        assert_eq!(account.host.as_deref(), Some("xmpp.host.example"));
        assert_eq!(account.port, Some(5443));
    }

    #[test]
    fn an_xmpp_account_needs_its_password_and_refuses_irc_flags() {
        std::env::remove_var("DDIRC_XMPP_PASSWORD");
        assert!(parse_str("client --xmpp alice@example.org").is_err());

        std::env::set_var("DDIRC_XMPP_PASSWORD", "hunter2");
        assert!(parse_str("client --xmpp alice@example.org --nick me").is_err());
        std::env::set_var("DDIRC_XMPP_PASSWORD", "hunter2");
        assert!(parse_str("client --xmpp alice@example.org --sasl-account me").is_err());
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

    #[test]
    fn without_a_per_user_directory_there_is_no_default() {
        assert_eq!(default_data_dir_from(|_| None), None);
    }

    #[test]
    fn the_default_is_beneath_the_users_own_directory() {
        let dir = default_data_dir_from(|_| Some(PathBuf::from("/home/someone"))).unwrap();
        assert!(dir.starts_with("/home/someone"), "{dir:?}");
        assert!(dir.ends_with(std::path::Path::new("ddirc").join("server")));
    }

    #[test]
    fn the_shared_temp_directory_is_never_a_fallback() {
        // With nothing to go on the server refuses, and says what to do.
        let error = resolve_data_dir(None, None).unwrap_err();
        assert!(error.contains("--data-dir"), "{error}");

        let asked = PathBuf::from("mine");
        assert_eq!(
            resolve_data_dir(Some(asked.clone()), None),
            Ok(asked.clone())
        );
        // And being asked beats the default.
        assert_eq!(
            resolve_data_dir(Some(asked.clone()), Some(PathBuf::from("theirs"))),
            Ok(asked)
        );
        assert_eq!(
            resolve_data_dir(None, Some(PathBuf::from("theirs"))),
            Ok(PathBuf::from("theirs"))
        );
    }
}
