import 'package:flutter/material.dart';

import '../../model/profile.dart';
import '../../model/settings.dart';
import '../../model/workspace.dart';
import '../../rust/api/client.dart' as core;
import '../../theme.dart';
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

  final Map<_Input, String> _errors = {};
  int _shake = 0;
  bool _busy = false;
  bool _showSasl = false;
  bool _passwordTouched = false;

  bool get _isNew => widget.profile == null;

  @override
  void initState() {
    super.initState();
    _showSasl = widget.profile?.usesSasl ?? false;
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
    super.dispose();
  }

  String _text(_Input field) => _fields[field]!.text.trim();

  Map<_Input, String> _validate() {
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
    );
  }

  Future<void> _save({required bool thenConnect}) async {
    final errors = _validate();
    if (errors.isNotEmpty) {
      setState(() {
        _errors
          ..clear()
          ..addAll(errors);
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
      await store.save(_build(), password: password);
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
