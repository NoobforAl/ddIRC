//! `RPL_ISUPPORT` (005) parsing.
//!
//! Networks differ in ways that silently corrupt state if assumed. Two matter
//! most here:
//!
//! * **`PREFIX`** maps privilege modes to their nick prefixes. Hardcoding `@`
//!   and `+` breaks on networks with halfops (`%`), owners (`~`) or admins
//!   (`&`), so we read the real mapping.
//! * **`CHANMODES`** says which modes carry a parameter. Without it, parsing
//!   `MODE #c +bo mask nick` mis-aligns the arguments and we would grant ops to
//!   the wrong user — a correctness bug with a security flavour.
//!
//! `CASEMAPPING` matters too: IRC nicks and channels are case-insensitive, and
//! under the RFC 1459 mapping `[]\` are the uppercase forms of `{}|`. Comparing
//! with plain ASCII lowercase would treat `Foo[bar]` and `foo{bar}` as different
//! users on a network that considers them the same.

/// How the server compares nicks and channel names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CaseMapping {
    /// Plain ASCII `A-Z`.
    Ascii,
    /// ASCII plus `[]\^` as the uppercase forms of `{}|~`.
    #[default]
    Rfc1459,
    /// As `Rfc1459` but `^`/`~` are distinct.
    Rfc1459Strict,
}

impl CaseMapping {
    pub fn from_token(token: &str) -> Option<Self> {
        match token.to_ascii_lowercase().as_str() {
            "ascii" => Some(Self::Ascii),
            "rfc1459" => Some(Self::Rfc1459),
            "rfc1459-strict" | "strict-rfc1459" => Some(Self::Rfc1459Strict),
            _ => None,
        }
    }

    /// Fold `name` to its canonical comparison form.
    ///
    /// Use the result as a map key; keep the original for display.
    pub fn normalize(&self, name: &str) -> String {
        name.chars()
            .map(|c| match (self, c) {
                (_, 'A'..='Z') => c.to_ascii_lowercase(),
                (Self::Rfc1459 | Self::Rfc1459Strict, '[') => '{',
                (Self::Rfc1459 | Self::Rfc1459Strict, ']') => '}',
                (Self::Rfc1459 | Self::Rfc1459Strict, '\\') => '|',
                (Self::Rfc1459, '~') => '^',
                _ => c,
            })
            .collect()
    }

    /// Case-insensitive equality under this mapping.
    pub fn eq(&self, a: &str, b: &str) -> bool {
        self.normalize(a) == self.normalize(b)
    }
}

/// The `PREFIX=(modes)prefixes` mapping, highest privilege first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prefixes {
    /// `(mode, prefix)` pairs in descending order of privilege.
    pairs: Vec<(char, char)>,
}

impl Default for Prefixes {
    /// The near-universal baseline: op and voice.
    fn default() -> Self {
        Self {
            pairs: vec![('o', '@'), ('v', '+')],
        }
    }
}

impl Prefixes {
    /// Parse a `PREFIX` value such as `(ov)@+` or `(qaohv)~&@%+`.
    ///
    /// Returns `None` if malformed, in which case the caller should keep the
    /// previous mapping rather than guessing.
    pub fn parse(spec: &str) -> Option<Self> {
        let spec = spec.trim();
        // An empty value is legal and means the server has no prefix modes.
        if spec.is_empty() {
            return Some(Self { pairs: Vec::new() });
        }

        let rest = spec.strip_prefix('(')?;
        let (modes, prefixes) = rest.split_once(')')?;
        // `PREFIX=()` is well-formed and means the server has no prefix modes;
        // a length mismatch is not, and leaves the mapping ambiguous.
        if modes.chars().count() != prefixes.chars().count() {
            return None;
        }

        Some(Self {
            pairs: modes.chars().zip(prefixes.chars()).collect(),
        })
    }

    /// The prefix character granted by `mode`, if it is a privilege mode.
    pub fn prefix_for_mode(&self, mode: char) -> Option<char> {
        self.pairs.iter().find(|(m, _)| *m == mode).map(|(_, p)| *p)
    }

    /// True if `mode` grants a nick prefix (and therefore takes a parameter).
    pub fn is_prefix_mode(&self, mode: char) -> bool {
        self.pairs.iter().any(|(m, _)| *m == mode)
    }

    /// True if `c` is one of the prefix characters, e.g. the `@` in `@nick`.
    pub fn is_prefix_char(&self, c: char) -> bool {
        self.pairs.iter().any(|(_, p)| *p == c)
    }

    /// Privilege rank of a prefix character: lower is more privileged.
    pub fn rank(&self, prefix: char) -> Option<usize> {
        self.pairs.iter().position(|(_, p)| *p == prefix)
    }

    /// The most privileged prefix among `held`, which is what the UI shows.
    pub fn highest<'a>(&self, held: impl IntoIterator<Item = &'a char>) -> Option<char> {
        held.into_iter()
            .filter(|c| self.is_prefix_char(**c))
            .min_by_key(|c| self.rank(**c).unwrap_or(usize::MAX))
            .copied()
    }

    /// Split any leading prefix characters off a name from `RPL_NAMREPLY`.
    ///
    /// With the `multi-prefix` capability a name may carry several, e.g. `@+bob`.
    pub fn split_prefixes<'a>(&self, name: &'a str) -> (Vec<char>, &'a str) {
        let split = name
            .char_indices()
            .find(|(_, c)| !self.is_prefix_char(*c))
            .map_or(name.len(), |(i, _)| i);
        (name[..split].chars().collect(), &name[split..])
    }
}

/// The `CHANMODES=A,B,C,D` classification, used to align mode parameters.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChanModes {
    /// Type A: list modes; always take a parameter (`b`, `e`, `I`).
    list: String,
    /// Type B: always take a parameter (`k`).
    always_param: String,
    /// Type C: take a parameter only when being set (`l`).
    param_when_set: String,
    /// Type D: never take a parameter (`i`, `m`, `n`, `t`).
    no_param: String,
}

impl Default for ChanModes {
    fn default() -> Self {
        Self {
            list: "beI".to_owned(),
            always_param: "k".to_owned(),
            param_when_set: "l".to_owned(),
            no_param: "imnpstr".to_owned(),
        }
    }
}

impl ChanModes {
    pub fn parse(spec: &str) -> Option<Self> {
        let mut parts = spec.split(',');
        let (a, b, c, d) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
        Some(Self {
            list: a.to_owned(),
            always_param: b.to_owned(),
            param_when_set: c.to_owned(),
            no_param: d.to_owned(),
        })
    }

    /// Whether `mode` consumes a parameter in this direction.
    ///
    /// Unknown modes are assumed to take no parameter, matching how servers
    /// treat modes a client does not know about.
    pub fn takes_parameter(&self, mode: char, adding: bool) -> bool {
        if self.list.contains(mode) || self.always_param.contains(mode) {
            true
        } else if self.param_when_set.contains(mode) {
            adding
        } else {
            false
        }
    }

    /// True if the mode is known at all, for diagnostics.
    pub fn is_known(&self, mode: char) -> bool {
        self.list.contains(mode)
            || self.always_param.contains(mode)
            || self.param_when_set.contains(mode)
            || self.no_param.contains(mode)
    }
}

/// The subset of `RPL_ISUPPORT` this client acts on.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ISupport {
    pub casemapping: CaseMapping,
    pub prefixes: Prefixes,
    pub chanmodes: ChanModes,
    /// Server-advertised network name, for display.
    pub network: Option<String>,
    /// Longest permitted channel name, if advertised.
    pub channel_len: Option<usize>,
    /// Longest permitted nick, if advertised.
    pub nick_len: Option<usize>,
}

impl ISupport {
    /// Apply the parameters of one `005` line.
    ///
    /// Tokens look like `KEY=value`, bare `KEY`, or `-KEY` to negate. The final
    /// human-readable trailing parameter ("are supported by this server") is
    /// ignored because it contains spaces.
    pub fn apply(&mut self, tokens: &[String]) {
        for token in tokens {
            // The trailing description is not a token.
            if token.contains(' ') {
                continue;
            }
            let (key, value) = match token.split_once('=') {
                Some((k, v)) => (k, Some(v)),
                None => (token.as_str(), None),
            };

            // `-KEY` resets a setting to its default.
            if let Some(key) = key.strip_prefix('-') {
                self.reset(key);
                continue;
            }

            match key.to_ascii_uppercase().as_str() {
                "PREFIX" => {
                    if let Some(p) = value.and_then(Prefixes::parse) {
                        self.prefixes = p;
                    }
                }
                "CHANMODES" => {
                    if let Some(c) = value.and_then(ChanModes::parse) {
                        self.chanmodes = c;
                    }
                }
                "CASEMAPPING" => {
                    if let Some(m) = value.and_then(CaseMapping::from_token) {
                        self.casemapping = m;
                    }
                }
                "NETWORK" => self.network = value.map(str::to_owned),
                "CHANNELLEN" => self.channel_len = value.and_then(|v| v.parse().ok()),
                "NICKLEN" => self.nick_len = value.and_then(|v| v.parse().ok()),
                _ => {}
            }
        }
    }

    fn reset(&mut self, key: &str) {
        match key.to_ascii_uppercase().as_str() {
            "PREFIX" => self.prefixes = Prefixes::default(),
            "CHANMODES" => self.chanmodes = ChanModes::default(),
            "CASEMAPPING" => self.casemapping = CaseMapping::default(),
            "NETWORK" => self.network = None,
            "CHANNELLEN" => self.channel_len = None,
            "NICKLEN" => self.nick_len = None,
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn parses_standard_prefix_spec() {
        let p = Prefixes::parse("(ov)@+").unwrap();
        assert_eq!(p.prefix_for_mode('o'), Some('@'));
        assert_eq!(p.prefix_for_mode('v'), Some('+'));
        assert_eq!(p.prefix_for_mode('q'), None);
    }

    #[test]
    fn parses_extended_prefix_spec_with_ranks() {
        let p = Prefixes::parse("(qaohv)~&@%+").unwrap();
        assert_eq!(p.prefix_for_mode('h'), Some('%'));
        // Owner outranks op outranks voice.
        assert!(p.rank('~').unwrap() < p.rank('@').unwrap());
        assert!(p.rank('@').unwrap() < p.rank('+').unwrap());
    }

    #[test]
    fn rejects_malformed_prefix_specs() {
        assert!(Prefixes::parse("(ov)@").is_none(), "count mismatch");
        assert!(Prefixes::parse("ov)@+").is_none(), "missing open paren");
        assert!(Prefixes::parse("(ov@+").is_none(), "missing close paren");
        assert!(Prefixes::parse("()").unwrap().pairs.is_empty());
    }

    #[test]
    fn highest_prefix_wins() {
        let p = Prefixes::parse("(qaohv)~&@%+").unwrap();
        assert_eq!(p.highest(&['+', '@']), Some('@'));
        assert_eq!(p.highest(&['%', '+']), Some('%'));
        assert_eq!(p.highest(&[]), None);
        assert_eq!(p.highest(&['x']), None, "unknown prefixes are ignored");
    }

    #[test]
    fn splits_multi_prefix_names() {
        let p = Prefixes::parse("(qaohv)~&@%+").unwrap();
        assert_eq!(p.split_prefixes("@+bob"), (vec!['@', '+'], "bob"));
        assert_eq!(p.split_prefixes("alice"), (vec![], "alice"));
        assert_eq!(p.split_prefixes("~owner"), (vec!['~'], "owner"));
    }

    #[test]
    fn split_prefixes_handles_names_that_are_all_prefixes() {
        let p = Prefixes::default();
        // Degenerate but must not panic or slice out of bounds.
        assert_eq!(p.split_prefixes("@@@"), (vec!['@', '@', '@'], ""));
        assert_eq!(p.split_prefixes(""), (vec![], ""));
    }

    #[test]
    fn rfc1459_casemapping_folds_bracket_characters() {
        let m = CaseMapping::Rfc1459;
        assert!(m.eq("Foo[bar]", "foo{bar}"));
        assert!(m.eq("a\\b", "a|b"));
        assert!(m.eq("Nick~", "nick^"));
    }

    #[test]
    fn ascii_casemapping_keeps_brackets_distinct() {
        let m = CaseMapping::Ascii;
        assert!(m.eq("FooBar", "foobar"));
        assert!(!m.eq("Foo[bar]", "foo{bar}"));
    }

    #[test]
    fn strict_rfc1459_keeps_tilde_distinct() {
        let m = CaseMapping::Rfc1459Strict;
        assert!(m.eq("A[b]", "a{b}"));
        assert!(!m.eq("nick~", "nick^"));
    }

    #[test]
    fn chanmodes_align_parameters_correctly() {
        let c = ChanModes::parse("beI,k,l,imnpst").unwrap();
        assert!(
            c.takes_parameter('b', true),
            "list modes always take a param"
        );
        assert!(c.takes_parameter('b', false));
        assert!(c.takes_parameter('k', false), "key takes a param both ways");
        assert!(c.takes_parameter('l', true), "limit takes a param when set");
        assert!(!c.takes_parameter('l', false), "but not when cleared");
        assert!(!c.takes_parameter('n', true));
    }

    #[test]
    fn unknown_modes_are_assumed_parameterless() {
        let c = ChanModes::default();
        assert!(!c.takes_parameter('Z', true));
        assert!(!c.is_known('Z'));
    }

    #[test]
    fn isupport_applies_and_negates_tokens() {
        let mut s = ISupport::default();
        s.apply(&tokens(&[
            "PREFIX=(qaohv)~&@%+",
            "CHANMODES=beI,k,l,imnpst",
            "CASEMAPPING=ascii",
            "NETWORK=Libera.Chat",
            "NICKLEN=16",
            "are supported by this server",
        ]));

        assert_eq!(s.prefixes.prefix_for_mode('h'), Some('%'));
        assert_eq!(s.casemapping, CaseMapping::Ascii);
        assert_eq!(s.network.as_deref(), Some("Libera.Chat"));
        assert_eq!(s.nick_len, Some(16));

        s.apply(&tokens(&["-PREFIX", "-NETWORK"]));
        assert_eq!(s.prefixes, Prefixes::default());
        assert_eq!(s.network, None);
    }

    #[test]
    fn malformed_isupport_values_keep_previous_settings() {
        let mut s = ISupport::default();
        s.apply(&tokens(&["PREFIX=(qaohv)~&@%+"]));
        let good = s.prefixes.clone();

        // A broken PREFIX must not wipe the mapping we already trust.
        s.apply(&tokens(&["PREFIX=garbage", "CASEMAPPING=nonsense"]));
        assert_eq!(s.prefixes, good);
        assert_eq!(s.casemapping, CaseMapping::default());
    }

    #[test]
    fn default_prefixes_cover_op_and_voice() {
        let p = Prefixes::default();
        assert!(p.is_prefix_mode('o') && p.is_prefix_mode('v'));
        assert!(p.is_prefix_char('@') && p.is_prefix_char('+'));
        assert!(!p.is_prefix_char('x'));
    }
}
