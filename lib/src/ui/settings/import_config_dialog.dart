import 'package:flutter/material.dart';

import '../../model/errors.dart';
import '../../model/ircconfig.dart';
import '../../model/profile.dart';
import '../../model/proxy.dart';
import '../../rust/api/client.dart' as core;
import '../../rust/api/types.dart' as rust;
import '../../theme.dart';
import '../motion.dart';
import '../touchable.dart';
import 'settings_chrome.dart';

/// What a `.irc` file or a scanned QR code named, waiting to be saved.
///
/// One dialog for both sources, because the moment either has handed over
/// text that `parseIrcConfig` accepted, a file and a QR code are the same
/// thing: a list of networks nobody has agreed to add yet. Nothing is saved
/// by parsing alone — this is where that agreement happens, network by
/// network, the same way the network picker hands the profile editor an
/// address rather than committing one on the user's behalf.
///
/// It is also where a credential is settled. A file may carry passwords and
/// may carry none, and either way the answer to "will this actually connect"
/// is worth having *before* the network is saved and the workspace starts
/// reconnecting at it. So each row opens onto the credentials it arrived with
/// and a **Test** button that runs the real thing — proxy, TLS, capability
/// negotiation, SASL — and reports back beside the field responsible. A
/// rejected password is then fixed here, in place, rather than by saving a
/// network, watching it fail, and going looking for the editor.
class ImportConfigDialog extends StatefulWidget {
  const ImportConfigDialog({super.key, required this.networks});

  /// Already parsed, and already carrying a fresh id each — see
  /// `parseIrcConfig`. This dialog only decides which of them get saved, and
  /// with which credentials.
  final List<ImportedNetwork> networks;

  /// Returns how many were actually saved, so the caller can say so.
  static Future<int> show(
    BuildContext context,
    List<ImportedNetwork> networks,
  ) async {
    final imported = await showDialog<int>(
      context: context,
      builder: (_) => ImportConfigDialog(networks: networks),
    );
    return imported ?? 0;
  }

  @override
  State<ImportConfigDialog> createState() => _ImportConfigDialogState();
}

/// One network's row, and everything the user can change about it before it
/// is saved.
///
/// The controllers live here rather than inside the row widget so that
/// importing can read what was typed without the row having to hand it back
/// up, and so that collapsing a row does not throw away an edit made in it.
class _Draft {
  _Draft(this.source)
    : server = TextEditingController(text: source.serverPassword ?? ''),
      account = TextEditingController(text: source.profile.saslAccount ?? ''),
      sasl = TextEditingController(text: source.saslPassword ?? ''),
      nickserv = TextEditingController(text: source.nickservPassword ?? '');

  final ImportedNetwork source;

  final TextEditingController server;
  final TextEditingController account;
  final TextEditingController sasl;
  final TextEditingController nickserv;

  /// Everything starts ticked. A file somebody chose to import, or a QR code
  /// they chose to scan, is already the deliberate step — asking again per
  /// network would be asking the same question twice for no reason a shared
  /// file with one bad entry does not already cover by being untickable here.
  bool selected = true;

  /// Whether the credentials are showing. Closed by default: the common file
  /// has no password in it and nothing to answer for, and a dialog that
  /// opened four text fields per network would bury the list under them.
  bool open = false;

  bool testing = false;
  String? note;
  bool failed = false;

  /// True once a test has come back clean, so the row can say so at a glance
  /// after it is collapsed again.
  bool get passed => note != null && !failed;

  /// The profile as it would be saved: the file's, plus whatever the account
  /// field says now.
  Profile get profile =>
      source.profile.copyWith(saslAccount: account.text.trim());

  /// Whether this row has anything a keychain would hold.
  bool get hasSecret =>
      server.text.isNotEmpty ||
      sasl.text.isNotEmpty ||
      nickserv.text.isNotEmpty ||
      source.proxyPassword != null;

  void dispose() {
    server.dispose();
    account.dispose();
    sasl.dispose();
    nickserv.dispose();
  }
}

class _ImportConfigDialogState extends State<ImportConfigDialog> {
  late final List<_Draft> _drafts = [
    for (final network in widget.networks) _Draft(network),
  ];

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The status mark reads the fields, so typing in one has to repaint the
    // row above it. Per draft rather than one shared listener: a result
    // belongs to the row that produced it, and editing one network is not a
    // reason to withdraw what was proved about another.
    for (final draft in _drafts) {
      for (final field in [draft.server, draft.sasl, draft.nickserv]) {
        field.addListener(() => _onEdited(draft));
      }
    }
  }

  /// A credential changed, so whatever the last test concluded is now about a
  /// password that is no longer there. Clearing a *passing* note is the honest
  /// answer: a green tick beside an edited field would be claiming a result
  /// nothing produced. A failing one stays, because the reason it failed is
  /// what the user is reading while they fix it.
  void _onEdited(_Draft draft) {
    if (!mounted) return;
    setState(() {
      if (!draft.testing && draft.passed) draft.note = null;
    });
  }

  int get _selectedCount => _drafts.where((d) => d.selected).length;

  /// Whether any file in this import arrived with a credential in it.
  ///
  /// Worth saying once, at the top, and only when it is true: a file that
  /// carries a password is a password sitting in the clear wherever that file
  /// is, and the moment somebody is looking at the import screen is the only
  /// moment that fact is actionable.
  bool get _anyFromFile => widget.networks.any((n) => n.carriesSecret);

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  /// Run the real connection, with what is typed now.
  ///
  /// Deliberately the same [core.testConnection] the network editor uses, so
  /// there is one answer to "does this work" and not a second, looser one
  /// that only importing can give. Nothing is saved on the way: the profile
  /// exists for the length of the call and the secrets come from the fields.
  Future<void> _test(_Draft draft) async {
    setState(() {
      draft.testing = true;
      draft.note = null;
    });

    final profile = draft.profile;
    String note;
    var failed = true;
    try {
      final config = profile.toConfig(
        saslPassword: draft.sasl.text,
        serverPassword: draft.server.text,
        // Deliberately not passed, matching the editor: the probe never
        // identifies to NickServ, because sending a password to a service is
        // a side effect and a test is supposed to leave nothing behind.
        proxy: await _proxyFor(draft, profile),
      );
      final report = await core.testConnection(config: config);
      failed = false;
      note = _describe(report, profile);
    } catch (error) {
      note = describeError(error);
    }

    if (!mounted) return;
    setState(() {
      draft.testing = false;
      draft.note = note;
      draft.failed = failed;
      // A failure is almost always a credential, and the fields that would
      // fix it are the ones this row is hiding. Open it rather than making
      // the user work out that the answer is behind a chevron.
      if (failed) draft.open = true;
    });
  }

  /// The route to test through — the same one connecting would take.
  ///
  /// [resolveProxy] reads the proxy password from the keychain, and this
  /// network has no keychain entry yet: it is not saved. So a password that
  /// came in the file has to be layered on afterwards, exactly as the editor
  /// does for one typed into the form and not yet saved.
  Future<rust.ProxyConfig?> _proxyFor(_Draft draft, Profile profile) async {
    final resolved = await resolveProxy(
      profile,
      ProxyScope.of(context),
      ProfileScope.of(context),
    );
    final password = draft.source.proxyPassword;
    if (resolved == null ||
        password == null ||
        profile.proxyMode != ProxyMode.custom) {
      return resolved;
    }
    return rust.ProxyConfig(
      host: resolved.host,
      port: resolved.port,
      username: resolved.username,
      password: password,
    );
  }

  /// What a successful test found, in one sentence. Shorter than the
  /// editor's, because here it sits inside a row rather than under a form.
  String _describe(rust.ProbeReport report, Profile profile) {
    final seconds = (report.elapsedMs.toInt() / 1000).toStringAsFixed(1);
    final nick = report.nickname == profile.nickname
        ? report.nickname
        : '${report.nickname} — not the ${profile.nickname} you asked for';
    final auth = switch (report.auth) {
      rust.AuthOutcome_Sasl() => ' SASL accepted.',
      rust.AuthOutcome_NickServFallback(:final reason) =>
        ' SASL did not authenticate you ($reason).',
      rust.AuthOutcome_Anonymous() => '',
    };
    return 'Connected over TLS as $nick in ${seconds}s.$auth';
  }

  Future<void> _import() async {
    if (_selectedCount == 0) return;
    setState(() => _busy = true);

    final store = ProfileScope.of(context);
    var saved = 0;
    for (final draft in _drafts) {
      if (!draft.selected) continue;
      await store.save(
        draft.profile,
        // Empty means "there is none", which for a network being created for
        // the first time is the same as clearing: there is nothing stored
        // under a fresh id for an empty string to wipe.
        password: draft.sasl.text,
        serverPassword: draft.server.text,
        nickservPassword: draft.nickserv.text,
        proxyPassword: draft.source.proxyPassword ?? '',
      );
      saved++;
    }

    if (!mounted) return;
    Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final count = _drafts.length;
    final selected = _selectedCount;

    return SettingsDialog(
      title: count == 1 ? 'Import a network' : 'Import networks',
      subtitle: count == 1 ? _drafts.single.profile.name : '$count found',
      children: [
        for (final draft in _drafts)
          _NetworkRow(
            draft: draft,
            busy: _busy,
            onToggle: () => setState(() => draft.selected = !draft.selected),
            onExpand: () => setState(() => draft.open = !draft.open),
            onTest: () => _test(draft),
          ),
        const SettingsRule(),
        if (_anyFromFile)
          const SettingsNote(
            text:
                'This file had passwords written in it. Importing moves them '
                'into the device keychain, where they are stored as secrets '
                'and not as settings — but the file itself is still plain '
                'text. Delete it, or keep it somewhere you would keep a '
                'password.',
          )
        else
          const SettingsProse(
            'No passwords came with this file. Anything typed in above is '
            'stored as a secret in the device keychain, never in app '
            'settings — as is anything added later in the editor.',
          ),
        SettingsActions(
          children: [
            SettingsTertiaryButton(
              label: 'Cancel',
              onPressed: _busy ? null : () => Navigator.of(context).pop(0),
            ),
            SettingsPrimaryButton(
              label: _busy
                  ? 'Importing…'
                  : selected == count
                  ? 'Import $selected'
                  : 'Import $selected of $count',
              onPressed: _busy || selected == 0 ? null : _import,
            ),
          ],
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}

/// One network in the list: the box that decides whether it is kept, and
/// behind a chevron, the credentials it will be kept with.
class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.draft,
    required this.busy,
    required this.onToggle,
    required this.onExpand,
    required this.onTest,
  });

  final _Draft draft;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback onExpand;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;
    final profile = draft.profile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Touchable(
          onTap: busy ? null : onToggle,
          builder: (context, touch) => AnimatedContainer(
            duration: m.fast,
            curve: Motion.curve,
            color: t.surfaceHover.withValues(alpha: touch.wash),
            padding: const EdgeInsets.fromLTRB(18, 10, 8, 10),
            child: Row(
              children: [
                _Check(selected: draft.selected),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${profile.host}:${profile.port} · ${profile.nickname}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.faint, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                _Status(draft: draft),
                IconButton(
                  onPressed: busy ? null : onExpand,
                  icon: AnimatedRotation(
                    turns: draft.open ? 0.5 : 0,
                    duration: m.fast,
                    curve: Motion.curve,
                    child: const Icon(Icons.expand_more, size: 18),
                  ),
                  color: t.muted,
                  visualDensity: VisualDensity.compact,
                  tooltip: draft.open
                      ? 'Hide credentials'
                      : 'Credentials and connection test',
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: m.fast,
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: draft.open
              ? _Credentials(draft: draft, busy: busy, onTest: onTest)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// The tick box. Its own widget only so the row above stays readable.
class _Check extends StatelessWidget {
  const _Check({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;
    return AnimatedContainer(
      duration: m.fast,
      curve: Motion.curve,
      width: 17,
      height: 17,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? t.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: selected ? t.accent : t.rule,
          width: selected ? 1 : Tokens.hairline,
        ),
      ),
      child: Appear(
        child: selected
            ? Icon(
                Icons.check,
                key: const ValueKey('check'),
                size: 12,
                color: t.onAccent,
              )
            : null,
      ),
    );
  }
}

/// A word about where this row stands, when there is one worth saying.
///
/// Three states earn a mark and no others: tested and good, tested and
/// refused, and carrying a password nobody has checked yet. A row with
/// nothing to report shows nothing, so the marks that do appear mean
/// something.
class _Status extends StatelessWidget {
  const _Status({required this.draft});

  final _Draft draft;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (draft.testing) {
      return SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: t.muted),
      );
    }
    if (draft.passed) {
      return Tooltip(
        message: 'Tested — this connects',
        child: Icon(Icons.check_circle_outline, size: 15, color: t.ok),
      );
    }
    if (draft.failed) {
      return Tooltip(
        message: 'Tested — this did not connect',
        child: Icon(Icons.error_outline, size: 15, color: t.bad),
      );
    }
    if (draft.hasSecret) {
      return Tooltip(
        message: 'Has a password, untested',
        child: Icon(Icons.key_outlined, size: 14, color: t.faint),
      );
    }
    return const SizedBox.shrink();
  }
}

/// The credentials for one network, and the button that tries them.
class _Credentials extends StatelessWidget {
  const _Credentials({
    required this.draft,
    required this.busy,
    required this.onTest,
  });

  final _Draft draft;
  final bool busy;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(
          top: BorderSide(color: t.rule, width: Tokens.hairline),
          bottom: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          SettingsLabelledField(
            label: 'Server password',
            controller: draft.server,
            obscure: true,
            hint: 'Optional',
            help:
                'Sent as the server\'s PASS before registration. Goes to the '
                'platform keychain when you import, never to app settings.',
            onSubmitted: (_) => busy ? null : onTest(),
          ),
          SettingsLabelledField(
            label: 'SASL account',
            controller: draft.account,
            hint: 'Optional',
            onSubmitted: (_) => busy ? null : onTest(),
          ),
          SettingsLabelledField(
            label: 'SASL password',
            controller: draft.sasl,
            obscure: true,
            hint: 'Optional',
            help:
                'The password for the account above. Kept in the platform '
                'keychain and zeroized by the core once authentication '
                'completes.',
            onSubmitted: (_) => busy ? null : onTest(),
          ),
          SettingsLabelledField(
            label: 'NickServ password',
            controller: draft.nickserv,
            obscure: true,
            hint: 'Optional',
            help:
                'Used to identify with NickServ if SASL was not accepted. '
                'Never sent by the connection test — a test is supposed to '
                'leave nothing behind.',
            onSubmitted: (_) => busy ? null : onTest(),
          ),
          const SecretStorageNote(),
          if (draft.note case final note?)
            SettingsNote(text: note, isError: draft.failed),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    draft.failed
                        ? 'Fix the password above and test again.'
                        : 'Connects for real — nothing is saved.',
                    style: TextStyle(color: t.faint, fontSize: 11.5),
                  ),
                ),
                const SizedBox(width: 10),
                SettingsSecondaryButton(
                  label: draft.testing ? 'Testing…' : 'Test connection',
                  onPressed: busy || draft.testing ? null : onTest,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
