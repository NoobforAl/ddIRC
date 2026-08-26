import 'package:flutter/material.dart';

import '../../model/directory.dart';
import '../../model/profile.dart';
import '../../model/proxy.dart';
import '../../model/settings.dart';
import '../../model/workspace.dart';
import '../../rust/api/client.dart' as core;
import '../../theme.dart';
import '../motion.dart';
import '../touchable.dart';
import 'network_picker_dialog.dart';
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
  const ProfileEditorDialog({super.key, this.profile, this.preset});

  /// Null when adding.
  final Profile? profile;

  /// What the network picker chose, when the user arrived that way.
  ///
  /// Only read when [profile] is null: it is a starting point for a new
  /// network, never something that overwrites one the user already has.
  final NetworkPick? preset;

  static Future<ProfileEditorResult?> show(
    BuildContext context, {
    Profile? profile,
    NetworkPick? preset,
  }) {
    return showDialog<ProfileEditorResult>(
      context: context,
      builder: (_) => ProfileEditorDialog(profile: profile, preset: preset),
    );
  }

  @override
  State<ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

enum _Input { name, host, port, nick, channels, account, password }

class _ProfileEditorDialogState extends State<ProfileEditorDialog> {
  /// The picker's answer, or null. Never consulted while editing an existing
  /// profile — [ProfileEditorDialog.preset] only starts new ones.
  KnownNetwork? get _preset =>
      widget.profile == null ? widget.preset?.network : null;

  /// The channels ticked in the picker, on the same terms.
  List<String>? get _presetChannels =>
      widget.profile == null ? widget.preset?.channels : null;

  late final Map<_Input, TextEditingController> _fields = {
    _Input.name: TextEditingController(
      text: widget.profile?.name ?? _preset?.name ?? '',
    ),
    _Input.host: TextEditingController(
      text: widget.profile?.host ?? _preset?.host ?? '',
    ),
    _Input.port: TextEditingController(
      text: '${widget.profile?.port ?? _preset?.port ?? core.defaultTlsPort()}',
    ),
    _Input.nick: TextEditingController(text: widget.profile?.nickname ?? ''),
    _Input.channels: TextEditingController(
      text:
          widget.profile?.channels.join(', ') ??
          _presetChannels?.join(', ') ??
          '',
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
      channels: _channelList(),
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
            _networkNote(t),
            _field(t, _Input.channels, 'Channels', hint: 'Comma-separated'),
            _suggestedChannels(t),
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

  /// The catalogue entry for whatever address is currently typed, or null.
  ///
  /// Resolved from the field rather than held from the picker, so someone who
  /// types `irc.oftc.net` by hand gets the same suggestions and the same
  /// warnings as someone who arrived through Browse networks.
  KnownNetwork? get _known => knownNetworkFor(_text(_Input.host));

  /// Anything the network needs the user to know before they connect.
  Widget _networkNote(Tokens t) {
    final note = _known?.note;
    return Reveal(
      child: note == null
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 14, color: t.warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      note,
                      style: TextStyle(
                        color: t.muted,
                        fontSize: 11.5,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// The channels this network is known for, as toggles over the field above.
  ///
  /// Toggles rather than a second list: the comma-separated field stays the
  /// one place a channel list lives, and these write into it. Anything typed
  /// by hand that is not in the catalogue is left alone by them, and a
  /// suggestion the user has typed themselves still reads as selected.
  Widget _suggestedChannels(Tokens t) {
    final network = _known;
    final suggestions = network?.channels ?? const <KnownChannel>[];
    final joined = _channelList().map((c) => c.toLowerCase()).toSet();

    return Reveal(
      child: suggestions.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Popular on ${network!.name}',
                    style: TextStyle(color: t.faint, fontSize: 11.5),
                  ),
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final channel in suggestions)
                        _ChannelChip(
                          label: channel.name,
                          tooltip: channel.blurb,
                          selected: joined.contains(channel.name.toLowerCase()),
                          onTap: () => _toggleChannel(channel.name),
                        ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  /// The channels field, parsed. The same split the profile is built with.
  List<String> _channelList() => parseChannels(_text(_Input.channels));

  /// Add or remove one channel, leaving every other entry where it was.
  ///
  /// Written back through the controller rather than held in state, so the
  /// correction is visible in the field the user could also have typed into —
  /// there is never a selection that disagrees with what is on screen. The
  /// field's own listener calls setState, which repaints the chips.
  void _toggleChannel(String name) {
    _fields[_Input.channels]!.text = toggleChannel(
      _channelList(),
      name,
    ).join(', ');
  }

  /// Where this network's proxy comes from.
  ///
  /// Three choices rather than a switch, because "off" and "not set" are
  /// different answers here: a server that must never be proxied has to be
  /// able to say so, or turning on the app-wide proxy would silently take it
  /// with everything else.
  Widget _proxySection(Tokens t) {
    final settings = ProxyScope.of(context);
    final global = settings.active;
    // Built-in Tor takes every network, so none of the three choices below is
    // in force while it is on. The choice stays editable — it is what this
    // network goes back to when Tor is switched off — but saying nothing here
    // would leave someone reading "Direct" off the screen and believing it.
    final overridden = settings.overridesProfiles;
    return SettingsSection(
      label: 'Proxy',
      children: [
        if (overridden)
          const SettingsNote(
            text:
                'Built-in Tor is on, so this network connects through Tor '
                'whatever is chosen here. The choice below applies again once '
                'Tor is switched off.',
          ),
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
        if (!overridden && _proxyMode == ProxyMode.followDefault)
          SettingsReadout(
            label: 'App default',
            value: global == null
                ? 'Not set — this network connects directly'
                : global.label,
          ),
        if (!overridden && _proxyMode == ProxyMode.direct)
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

/// One suggested channel, on or off.
///
/// Small enough that a dozen of them wrap into the space a select box would
/// have taken, and each one says what it is on hover rather than needing a
/// second line of its own.
class _ChannelChip extends StatelessWidget {
  const _ChannelChip({
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Touchable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        builder: (context, touch) => AnimatedContainer(
          duration: m.fast,
          curve: Motion.curve,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            // Selected chips carry the accent at low opacity rather than at
            // full strength: a dozen filled accent chips would outrank every
            // control in the dialog, including the button that saves it.
            color: selected
                ? t.accent.withValues(alpha: 0.16)
                : t.surfaceHover.withValues(alpha: touch.wash),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? t.accent : t.rule,
              width: selected ? 1 : Tokens.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Appear(
                child: selected
                    ? Padding(
                        key: const ValueKey('check'),
                        padding: const EdgeInsets.only(right: 5),
                        child: Icon(Icons.check, size: 11, color: t.accent),
                      )
                    : null,
              ),
              Text(
                label,
                style: TextStyle(
                  color: selected ? t.text : t.muted,
                  fontSize: 12,
                  fontFamily: Fonts.mono,
                  fontFamilyFallback: Fonts.monoFallback,
                ),
              ),
            ],
          ),
        ),
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
