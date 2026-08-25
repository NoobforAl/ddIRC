import 'package:flutter/material.dart';

import '../../model/profile.dart';
import '../../model/proxy.dart';
import '../../model/settings.dart';
import '../../model/workspace.dart';
import '../../rust/api/client.dart' as core;
import '../../theme.dart';
import 'proxy_form.dart';
import 'settings_chrome.dart';

/// What the editor closed with, so the caller knows whether to connect.
enum ProfileEditorResult { saved, savedAndConnect, deleted }

/// Create or edit one saved network.
///
/// This is also the connect form: a profile *is* the connection settings, and
/// having two near-identical forms for "connect once" and "save a server"
/// would be two places to get validation wrong.
class ProfileEditorDialog extends StatefulWidget {
  const ProfileEditorDialog({super.key, this.profile});

  /// Null when adding.
  final Profile? profile;

  static Future<ProfileEditorResult?> show(
    BuildContext context, {
    Profile? profile,
  }) {
    return showDialog<ProfileEditorResult>(
      context: context,
      builder: (_) => ProfileEditorDialog(profile: profile),
    );
  }

  @override
  State<ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

enum _Input { name, host, port, nick, channels, account, password }

class _ProfileEditorDialogState extends State<ProfileEditorDialog> {
  late final Map<_Input, TextEditingController> _fields = {
    _Input.name: TextEditingController(text: widget.profile?.name ?? ''),
    _Input.host: TextEditingController(text: widget.profile?.host ?? ''),
    _Input.port: TextEditingController(
      text: '${widget.profile?.port ?? core.defaultTlsPort()}',
    ),
    _Input.nick: TextEditingController(text: widget.profile?.nickname ?? ''),
    _Input.channels: TextEditingController(
      text: widget.profile?.channels.join(', ') ?? '',
    ),
    _Input.account: TextEditingController(
      text: widget.profile?.saslAccount ?? '',
    ),
    _Input.password: TextEditingController(),
  };

  late final ProxyFormController _proxy = ProxyFormController(
    endpoint: widget.profile?.proxy,
    hasStoredPassword: widget.profile?.usesProxyAuth ?? false,
    defaultPort: core.torSocksPort(),
  );

  final Map<_Input, String> _errors = {};
  int _shake = 0;
  bool _busy = false;
  bool _showSasl = false;
  bool _passwordTouched = false;
  late ProxyMode _proxyMode =
      widget.profile?.proxyMode ?? ProxyMode.followDefault;
  late bool _autoConnect = widget.profile?.autoConnect ?? false;

  bool get _isNew => widget.profile == null;

  @override
  void initState() {
    super.initState();
    _showSasl = widget.profile?.usesSasl ?? false;
    _proxy.addListener(() {
      if (mounted) setState(() {});
    });
    for (final entry in _fields.entries) {
      entry.value.addListener(() {
        if (!mounted) return;
        setState(() {
          _errors.remove(entry.key);
          if (entry.key == _Input.password) _passwordTouched = true;
        });
      });
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _proxy.dispose();
    super.dispose();
  }

  String _text(_Input field) => _fields[field]!.text.trim();

  /// Move a port typed into the address box into the port box.
  ///
  /// `irc.example.org:6697` is how every other client, every wiki page and
  /// every `/server` line writes an address, so it is what people paste — and
  /// the form beside it already holds 6697, which quietly produced a host of
  /// `irc.example.org:6697:6697` and a DNS failure that named nothing useful.
  ///
  /// Split rather than rejected: the user said what they meant, and the form
  /// can put it where it goes. Done in the fields themselves so the correction
  /// is on screen rather than applied behind the user's back.
  ///
  /// One colon only. `::1` and every other bare IPv6 literal has more, and
  /// splitting one would turn a valid address into nonsense; those are written
  /// `[::1]` when a port is involved, which has no bare colon at all.
  void _liftPortOutOfAddress() {
    final host = _text(_Input.host);
    final colon = host.indexOf(':');
    if (colon <= 0 || colon != host.lastIndexOf(':')) return;

    final tail = host.substring(colon + 1);
    if (tail.isEmpty || tail.length > 5) return;
    if (!tail.split('').every((c) => '0123456789'.contains(c))) return;

    _fields[_Input.host]!.text = host.substring(0, colon);
    _fields[_Input.port]!.text = tail;
  }

  Map<_Input, String> _validate() {
    _liftPortOutOfAddress();
    final errors = <_Input, String>{};

    if (_text(_Input.host).isEmpty) {
      errors[_Input.host] = 'Enter a server address.';
    }

    final port = int.tryParse(_text(_Input.port));
    if (_text(_Input.port).isEmpty) {
      errors[_Input.port] = 'Required.';
    } else if (port == null || port < 1 || port > 65535) {
      errors[_Input.port] = 'Must be 1-65535.';
    }

    final nick = _text(_Input.nick);
    if (nick.isEmpty) {
      errors[_Input.nick] = 'Pick a nickname — it is how people address you.';
    } else if (nick.contains(RegExp(r'\s'))) {
      errors[_Input.nick] = 'No spaces in a nickname.';
    }

    // Half a SASL credential authenticates nobody. On an existing profile a
    // blank password means "keep the stored one", so it is only missing if the
    // user has never set one and has not typed one now.
    final account = _text(_Input.account);
    final password = _fields[_Input.password]!.text;
    final storedPassword = !_isNew && widget.profile!.usesSasl;
    if (account.isNotEmpty && password.isEmpty && !storedPassword) {
      errors[_Input.password] = 'Required with an account.';
    }

    return errors;
  }

  Profile _build() {
    final host = _text(_Input.host);
    final name = _text(_Input.name);
    return Profile(
      id: widget.profile?.id ?? ProfileStore.newId(),
      // An unnamed profile takes the host, so the rail always has something
      // to show and the user is never forced to invent a label.
      name: name.isEmpty ? host : name,
      host: host,
      port: int.parse(_text(_Input.port)),
      nickname: _text(_Input.nick),
      altNicks: widget.profile?.altNicks ?? const [],
      channels: _text(
        _Input.channels,
      ).split(',').map((c) => c.trim()).where((c) => c.isNotEmpty).toList(),
      saslAccount: _text(_Input.account).isEmpty ? null : _text(_Input.account),
      autoConnect: _autoConnect,
      proxyMode: _proxyMode,
      // Kept even when the mode is not Custom, so switching to the app
      // default and back does not mean typing the address again. Nothing
      // reads it unless the mode says to.
      proxy: _proxy.isEmpty ? widget.profile?.proxy : _proxy.build(),
    );
  }

  Future<void> _save({required bool thenConnect}) async {
    final errors = _validate();
    // Only checked when this profile actually brings its own proxy: a stale
    // half-filled form behind "App default" must not block a save.
    final proxyErrors = _proxyMode == ProxyMode.custom
        ? _proxy.validate()
        : const <ProxyField, String>{};

    if (errors.isNotEmpty || proxyErrors.isNotEmpty) {
      setState(() {
        _errors
          ..clear()
          ..addAll(errors);
        _proxy.errors
          ..clear()
          ..addAll(proxyErrors);
        _shake++;
        if (errors.keys.any(
          (f) => f == _Input.account || f == _Input.password,
        )) {
          _showSasl = true;
        }
      });
      return;
    }

    setState(() => _busy = true);
    final store = ProfileScope.of(context);
    // Only write the password when the user actually typed into the field;
    // otherwise an edit would wipe a credential the user never touched.
    final password = _passwordTouched ? _fields[_Input.password]!.text : null;

    try {
      await store.save(
        _build(),
        password: password,
        proxyPassword: _proxyMode == ProxyMode.custom
            ? _proxy.passwordToSave()
            : null,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errors[_Input.host] = 'Could not save: $e';
        _shake++;
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(
      thenConnect
          ? ProfileEditorResult.savedAndConnect
          : ProfileEditorResult.saved,
    );
  }

  Future<void> _delete() async {
    final profile = widget.profile;
    if (profile == null) return;

    final store = ProfileScope.of(context);
    final workspace = WorkspaceScope.of(context);
    final settings = SettingsScope.of(context);

    // Order matters: drop the live connection before the profile it belongs
    // to, so nothing is left holding a socket for a network that no longer
    // exists.
    workspace.forget(profile.id);
    await settings.forgetProfile(profile.id);
    await store.remove(profile.id);

    if (!mounted) return;
    Navigator.of(context).pop(ProfileEditorResult.deleted);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final connected = WorkspaceScope.of(
      context,
    ).isConnected(widget.profile?.id ?? '');

    return SettingsDialog(
      title: _isNew ? 'Add a network' : 'Edit network',
      subtitle: _isNew ? 'Every connection uses TLS' : widget.profile!.name,
      children: [
        SettingsSection(
          label: 'Server',
          children: [
            _field(
              t,
              _Input.name,
              'Name',
              hint: 'Optional — defaults to the host',
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: _field(
                    t,
                    _Input.host,
                    'Address',
                    hint: 'irc.example.org',
                  ),
                ),
                Expanded(child: _field(t, _Input.port, 'Port')),
              ],
            ),
            _field(t, _Input.channels, 'Channels', hint: 'Comma-separated'),
            SettingsSwitch(
              label: 'Connect at launch',
              description:
                  'Opens this network when ddIRC starts. Several may be '
                  'marked; they connect together, and the first in the list '
                  'is the one you land on.',
              value: _autoConnect,
              onChanged: (v) => setState(() => _autoConnect = v),
            ),
          ],
        ),
        const SettingsRule(),
        SettingsSection(
          label: 'Identity',
          children: [
            _field(t, _Input.nick, 'Nickname'),
            _saslToggle(t),
            if (_showSasl) ...[
              _field(t, _Input.account, 'SASL account'),
              _field(
                t,
                _Input.password,
                'SASL password',
                obscure: true,
                hint: !_isNew && widget.profile!.usesSasl
                    ? 'Stored — leave blank to keep it'
                    : null,
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(18, 0, 18, 10),
                child: Text(
                  'Kept in the platform keychain, never in app settings, and '
                  'zeroized by the core once authentication completes.',
                  style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.4),
                ),
              ),
            ],
          ],
        ),
        const SettingsRule(),
        _proxySection(t),
        const SettingsRule(),
        SettingsActions(
          children: [
            if (!_isNew)
              SettingsDangerButton(
                label: connected ? 'Delete & disconnect' : 'Delete',
                onPressed: _busy ? null : _delete,
              ),
            _SecondaryButton(
              label: 'Save',
              onPressed: _busy ? null : () => _save(thenConnect: false),
            ),
            SettingsPrimaryButton(
              label: _busy
                  ? 'Saving…'
                  : connected
                  ? 'Save & switch'
                  : 'Save & connect',
              onPressed: _busy ? null : () => _save(thenConnect: true),
            ),
          ],
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  /// Where this network's proxy comes from.
  ///
  /// Three choices rather than a switch, because "off" and "not set" are
  /// different answers here: a server that must never be proxied has to be
  /// able to say so, or turning on the app-wide proxy would silently take it
  /// with everything else.
  Widget _proxySection(Tokens t) {
    final global = ProxyScope.of(context).active;
    return SettingsSection(
      label: 'Proxy',
      children: [
        SettingsChoice<ProxyMode>(
          label: 'Connect through',
          options: ProxyMode.values,
          labelFor: (m) => m.label,
          value: _proxyMode,
          onChanged: (m) => setState(() {
            _proxyMode = m;
            // Errors from a form that is no longer being read would sit there
            // in red with no way to clear them.
            if (m != ProxyMode.custom) _proxy.errors.clear();
          }),
        ),
        if (_proxyMode == ProxyMode.followDefault)
          SettingsReadout(
            label: 'App default',
            value: global == null
                ? 'Not set — this network connects directly'
                : global.label,
          ),
        if (_proxyMode == ProxyMode.direct)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: Text(
              'This network always connects directly, even when the app-wide '
              'proxy is on. Worth being deliberate about: if the proxy is '
              'there to keep your address private, this network will still '
              'see it.',
              style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.4),
            ),
          ),
        if (_proxyMode == ProxyMode.custom)
          ProxyFields(
            controller: _proxy,
            shakeTick: _shake,
            onSubmitted: _busy ? null : () => _save(thenConnect: true),
          ),
      ],
    );
  }

  Widget _saslToggle(Tokens t) {
    return InkWell(
      onTap: () => setState(() => _showSasl = !_showSasl),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
        child: Row(
          children: [
            Icon(
              _showSasl ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: t.muted,
            ),
            const SizedBox(width: 4),
            Text(
              'SASL account (optional)',
              style: TextStyle(color: t.muted, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    Tokens t,
    _Input field,
    String label, {
    String? hint,
    bool obscure = false,
  }) {
    final error = _errors[field];
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: error == null ? t.muted : t.bad,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 5),
          SettingsField(
            controller: _fields[field]!,
            hint: hint,
            obscure: obscure,
            error: error,
            shakeTick: _shake,
            onSubmitted: (_) => _busy ? null : _save(thenConnect: true),
          ),
        ],
      ),
    );
  }
}

/// Save without connecting: present, but not the thing being suggested.
class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: t.muted,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}
