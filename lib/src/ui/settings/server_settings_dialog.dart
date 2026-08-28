import 'package:flutter/material.dart';

import '../../model/proxy.dart';
import '../../model/session.dart';
import '../../model/settings.dart';
import '../../model/workspace.dart';
import '../../rust/api/types.dart';
import '../../theme.dart';
import 'settings_chrome.dart';

/// Settings for the connection this session is running on.
///
/// Host, port and credentials are fixed for the life of a connection — the
/// core validates and consumes them at connect time and zeroizes the secrets
/// afterwards. They are shown here as facts, not fields, so the dialog never
/// implies an edit that would silently do nothing.
class ServerSettingsDialog extends StatefulWidget {
  const ServerSettingsDialog({super.key, required this.session});

  final SessionModel session;

  static Future<void> show(
    BuildContext context, {
    required SessionModel session,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => ServerSettingsDialog(session: session),
    );
  }

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  late final TextEditingController _nick = TextEditingController(
    text: widget.session.nick,
  );

  String? _note;
  bool _noteIsError = false;
  bool _busy = false;

  /// Shown on the field itself, in red, with a shake.
  String? _nickError;
  int _shake = 0;

  SessionModel get session => widget.session;

  @override
  void initState() {
    super.initState();
    // Every keystroke rebuilds: the button's enabled state depends on the
    // text, and editing is also the user answering any complaint, so the red
    // clears as they type rather than on the next attempt.
    _nick.addListener(() {
      if (!mounted) return;
      setState(() => _nickError = null);
    });
    // The nick can change underneath us — a forced rename, or a NICK we sent
    // landing — so keep the field honest while the dialog is open.
    session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    _nick.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    if (!_busy && _nick.text.trim() == session.nick) return;
    setState(() {});
  }

  bool get _nickChanged => _nick.text.trim() != session.nick;

  /// Returns the problem with the typed nick, or null if it is usable.
  String? _nickProblem() {
    final nick = _nick.text.trim();
    if (nick.isEmpty) return 'A nickname cannot be empty.';
    if (nick.contains(RegExp(r'\s'))) return 'No spaces in a nickname.';
    return null;
  }

  Future<void> _applyNick() async {
    final problem = _nickProblem();
    if (problem != null) {
      setState(() {
        _nickError = problem;
        _note = null;
        _shake++;
      });
      return;
    }

    setState(() {
      _busy = true;
      _note = null;
      _nickError = null;
    });
    final error = await session.changeNick(_nick.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      // A failure is about this field, so it belongs on this field.
      if (error != null) {
        _nickError = error;
        _shake++;
        return;
      }
      _noteIsError = false;
      _note = 'Sent. The server decides whether the name is free.';
    });
  }

  void _disconnect() {
    // Only this network goes down; any others stay up behind the dialog.
    WorkspaceScope.of(context).disconnect(session.profileId);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final config = session.config;
    final (statusLabel, statusColor) = _describe(session.status, t);

    return SettingsDialog(
      title: 'Server settings',
      subtitle: session.network ?? config.host,
      children: [
        SettingsSection(
          label: 'Identity',
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(18, 2, 18, 6),
              child: Text(
                'Nickname',
                style: TextStyle(color: t.text, fontSize: 13.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: SettingsField(
                controller: _nick,
                hint: session.nick,
                error: _nickError,
                shakeTick: _shake,
                onSubmitted: (_) => _busy ? null : _applyNick(),
              ),
            ),
            SettingsActions(
              children: [
                SettingsPrimaryButton(
                  label: _busy ? 'Sending…' : 'Change nickname',
                  // Enabled even when the field is empty: pressing it is how
                  // the user finds out why, and a dead button explains nothing.
                  onPressed: _busy || (!_nickChanged && _nickError == null)
                      ? null
                      : _applyNick,
                ),
              ],
            ),
            if (_note != null)
              SettingsNote(text: _note!, isError: _noteIsError),
            if (config.altNicks.isNotEmpty)
              SettingsReadout(
                label: 'Fallbacks',
                value: config.altNicks.join(', '),
              ),
          ],
        ),
        const SettingsRule(),
        SettingsSection(
          label: 'Connection',
          children: [
            SettingsReadout(
              label: 'Status',
              value: statusLabel,
              valueColor: statusColor,
            ),
            SettingsReadout(
              label: 'Server',
              value: '${config.host}:${config.port}',
              monospace: true,
            ),
            SettingsReadout(
              label: 'Network',
              value: session.network ?? 'not reported yet',
            ),
            const SettingsReadout(
              label: 'Transport',
              value: 'TLS, certificate verified',
            ),
            SettingsReadout(
              label: 'Route',
              // Read from the config this connection was opened with, so
              // changing the proxy setting does not change what this says
              // about a connection that is already up.
              value: config.proxy == null
                  ? 'Direct — no proxy'
                  : 'SOCKS5 via ${config.proxy!.label}',
            ),
            SettingsReadout(
              label: 'Authentication',
              value: _describeAuth(session.auth, config),
            ),
            if (config.channels.isNotEmpty)
              SettingsReadout(
                label: 'Auto-join',
                value: config.channels.join(', '),
              ),
          ],
        ),
        const SettingsRule(),
        _blocked(t),
        const SettingsRule(),
        SettingsSection(
          label: 'Disconnect',
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(18, 2, 18, 10),
              child: Text(
                'Closes this network and its conversations. Other networks '
                'stay connected. Scrollback is not kept.',
                style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.4),
              ),
            ),
            SettingsActions(
              children: [
                SettingsDangerButton(
                  label: 'Disconnect',
                  onPressed: _disconnect,
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  /// Who has been turned away on this network, and how to let them back.
  ///
  /// Per network, because that is what a nick means: `alice` on one server is
  /// not `alice` on another, and a list that pretended otherwise would block a
  /// stranger somewhere the user has never met them.
  ///
  /// Shown even when empty. A block list nobody can find until it has something
  /// in it is one the user has to already know about to look for, and this is
  /// the only place declining a request can be undone.
  Widget _blocked(Tokens t) {
    final settings = SettingsScope.of(context);
    final nicks = settings.blockedFor(session.profileId);

    return SettingsSection(
      label: 'Blocked',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
          child: Text(
            nicks.isEmpty
                ? 'Nobody. Declining someone’s first message blocks them '
                      'here, and their later messages are dropped without a '
                      'trace.'
                : 'Their messages are dropped before they reach a '
                      'conversation. Unblocking does not tell them anything.',
            style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.4),
          ),
        ),
        for (final nick in nicks)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 10, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    nick,
                    style: TextStyle(color: t.text, fontSize: 12.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    settings.unblock(session.profileId, nick);
                    setState(() {});
                  },
                  style: TextButton.styleFrom(foregroundColor: t.accent),
                  child: const Text('Unblock'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static (String, Color) _describe(ConnectionStatus status, Tokens t) =>
      switch (status) {
        ConnectionStatus_Connected() => ('Connected', t.ok),
        ConnectionStatus_Connecting() => ('Connecting', t.warn),
        ConnectionStatus_Registering() => ('Registering', t.warn),
        ConnectionStatus_Reconnecting(:final retryInSecs, :final attempt) => (
          'Reconnecting in ${retryInSecs}s (attempt $attempt)',
          t.warn,
        ),
        ConnectionStatus_Disconnected() => ('Disconnected', t.bad),
      };

  /// Never renders a credential — only which mechanism was used.
  static String _describeAuth(AuthOutcome? auth, ServerConfig config) {
    return switch (auth) {
      AuthOutcome_Sasl() => 'SASL PLAIN as ${config.saslAccount ?? 'account'}',
      AuthOutcome_NickServFallback(:final reason) =>
        'NickServ — SASL unavailable ($reason)',
      AuthOutcome_Anonymous() => 'None',
      null => 'not established yet',
    };
  }
}
