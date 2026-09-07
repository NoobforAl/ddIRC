import 'package:flutter/material.dart';

import '../../model/history.dart';
import '../../model/settings.dart';
import '../../rust/api/store.dart' as store;
import 'settings_chrome.dart';

/// Whether conversations are kept after the app is closed.
///
/// Sits beside the chat log rather than anywhere else on purpose: they are the
/// two switches on this page that write down what people said, and someone
/// deciding about one is entitled to see the other in the same breath. The
/// framing is deliberately the same — off by default, and the description says
/// what ends up on disk rather than what the feature is called.
///
/// What is different is that this one is read back, so it earns two things the
/// log does not have: a readout of how much is being kept, and a way to delete
/// it. A store the app reads from is a store the user has to be able to empty.
class MessageHistorySection extends StatefulWidget {
  const MessageHistorySection({super.key});

  @override
  State<MessageHistorySection> createState() => _MessageHistorySectionState();
}

class _MessageHistorySectionState extends State<MessageHistorySection> {
  /// What the store holds, once it has been asked. Null while it has not been,
  /// and on any failure — the readout says "unknown" rather than inventing a
  /// number.
  store.StoreStats? _stats;
  bool _measuring = false;

  /// The delete needs a second press.
  ///
  /// Not a dialog: a modal over a modal to confirm a two-word action is worse
  /// than the button saying what it is about to do and waiting to be pressed
  /// again. Reset whenever anything else on this section changes, so a primed
  /// button cannot be left lying around.
  bool _confirmingDelete = false;

  MessageHistory get history => MessageHistory.instance;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    if (!history.enabled) {
      if (mounted) setState(() => _stats = null);
      return;
    }
    setState(() => _measuring = true);
    final stats = await history.stats();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _measuring = false;
    });
  }

  Future<void> _toggle(AppSettings settings, bool on) async {
    settings.saveMessages = on;
    // The switch is followed by a listener in `main`, so the store opens or
    // closes on its own. This only waits long enough for the readout below to
    // stop describing the previous state.
    setState(() {
      _confirmingDelete = false;
      _stats = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (mounted) await _measure();
  }

  Future<void> _delete() async {
    if (!_confirmingDelete) {
      setState(() => _confirmingDelete = true);
      return;
    }
    setState(() => _confirmingDelete = false);
    await history.clear();
    if (mounted) await _measure();
  }

  /// Bytes as something a person reads, to one decimal place.
  static String _size(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  String get _held {
    if (!history.enabled) return 'Nothing is being kept';
    if (_measuring && _stats == null) return 'Counting…';
    final stats = _stats;
    if (stats == null) return 'Unknown';
    final lines = stats.lines;
    return '$lines line${lines == 1 ? '' : 's'}, ${_size(stats.bytes)}';
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsScope.of(context);
    final failure = history.lastError;

    return SettingsSection(
      label: 'Message history',
      children: [
        SettingsSwitch(
          label: 'Save messages to a database',
          description:
              'Keeps conversations after ddIRC is closed, so rejoining a '
              'channel shows what was said last time instead of an empty '
              'screen. Written to this device only, unencrypted, in the app\'s '
              'own data folder — anyone who can read that folder can read your '
              'conversations. Off by default, like the chat log above, and for '
              'the same reason.',
          value: settings.saveMessages,
          onChanged: (v) => _toggle(settings, v),
        ),
        if (failure != null && settings.saveMessages)
          SettingsNote(text: failure, isError: true),
        SettingsReadout(
          label: 'File',
          // Shown whether or not the switch is on, so it is possible to know
          // where it would go before agreeing to it.
          value: history.path ?? 'Unavailable on this platform',
        ),
        SettingsReadout(label: 'Held', value: _held),
        SettingsReadout(
          label: 'Restored',
          value:
              'The last ${MessageHistory.restoreLines} lines of a conversation '
              'when it opens',
        ),
        if (settings.saveMessages) ...[
          if (_confirmingDelete)
            const SettingsNote(
              text:
                  'This deletes every saved message, on every network, and '
                  'gives the disk space back. It cannot be undone.',
            ),
          SettingsActions(
            children: [
              SettingsDangerButton(
                label: _confirmingDelete
                    ? 'Delete everything'
                    : 'Delete saved messages',
                onPressed: _delete,
              ),
            ],
          ),
        ],
      ],
    );
  }
}
