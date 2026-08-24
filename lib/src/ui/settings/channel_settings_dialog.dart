import 'package:flutter/material.dart';

import '../../model/session.dart';
import '../../model/settings.dart';
import '../../theme.dart';
import 'settings_chrome.dart';

/// Settings for one channel: its topic, how loudly it may interrupt, and the
/// way out of it.
class ChannelSettingsDialog extends StatefulWidget {
  const ChannelSettingsDialog({
    super.key,
    required this.session,
    required this.conversation,
  });

  final SessionModel session;
  final Conversation conversation;

  static Future<void> show(
    BuildContext context, {
    required SessionModel session,
    required Conversation conversation,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) =>
          ChannelSettingsDialog(session: session, conversation: conversation),
    );
  }

  @override
  State<ChannelSettingsDialog> createState() => _ChannelSettingsDialogState();
}

class _ChannelSettingsDialogState extends State<ChannelSettingsDialog> {
  late final TextEditingController _topic = TextEditingController(
    text: widget.conversation.topic ?? '',
  );

  String? _note;
  bool _noteIsError = false;
  bool _busy = false;

  /// A rejected topic is about the topic, so it is shown on the topic.
  String? _topicError;
  int _shake = 0;

  Conversation get conversation => widget.conversation;

  @override
  void initState() {
    super.initState();
    // Rebuild on every keystroke: whether "Set topic" is available depends on
    // the text, and typing also clears any complaint about it.
    _topic.addListener(() {
      if (!mounted) return;
      setState(() => _topicError = null);
    });
  }

  @override
  void dispose() {
    _topic.dispose();
    super.dispose();
  }

  bool get _topicChanged =>
      _topic.text.trim() != (conversation.topic ?? '').trim();

  Future<void> _saveTopic() async {
    setState(() {
      _busy = true;
      _note = null;
      _topicError = null;
    });
    final error = await widget.session.setTopic(conversation.name, _topic.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error != null) {
        _topicError = error;
        _shake++;
        return;
      }
      // The server is the authority: it may refuse on a +t channel, and the
      // change only really happened once it echoes a TOPIC back.
      _noteIsError = false;
      _note = 'Sent. The channel updates when the server confirms.';
    });
  }

  Future<void> _leave() async {
    final error = await widget.session.leave(conversation.name);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _noteIsError = true;
        _note = error;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final settings = SettingsScope.of(context);
    final members = conversation.members;
    final privileged = members.where((m) => m.prefix != null).length;
    final away = members.where((m) => m.away).length;

    return SettingsDialog(
      title: 'Channel settings',
      subtitle: conversation.name,
      children: [
        if (conversation.isChannel) ...[
          SettingsSection(
            label: 'Topic',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
                child: SettingsField(
                  controller: _topic,
                  hint: 'No topic set',
                  maxLines: 4,
                  error: _topicError,
                  shakeTick: _shake,
                  onSubmitted: (_) => _topicChanged ? _saveTopic() : null,
                ),
              ),
              SettingsActions(
                children: [
                  SettingsPrimaryButton(
                    label: _busy ? 'Sending…' : 'Set topic',
                    onPressed: _busy || !_topicChanged ? null : _saveTopic,
                  ),
                ],
              ),
              if (_note != null)
                SettingsNote(text: _note!, isError: _noteIsError),
            ],
          ),
          const SettingsRule(),
        ],
        SettingsSection(
          label: 'Notifications',
          children: [
            SettingsChoice<NotifyLevel>(
              label: 'Unread badge',
              description:
                  'Messages always arrive and are kept; this only decides '
                  'whether ${conversation.name} asks to be read.',
              options: NotifyLevel.values,
              labelFor: (l) => l.label,
              value: settings.notifyFor(
                widget.session.profileId,
                conversation.name,
              ),
              onChanged: (level) {
                settings.setNotifyFor(
                  widget.session.profileId,
                  conversation.name,
                  level,
                );
                setState(() {});
              },
            ),
          ],
        ),
        if (conversation.isChannel) ...[
          const SettingsRule(),
          SettingsSection(
            label: 'Members',
            children: [
              SettingsReadout(label: 'Present', value: '${members.length}'),
              SettingsReadout(
                label: 'With a prefix',
                value: privileged == 0
                    ? 'none'
                    : '$privileged (operators, voice and above)',
              ),
              SettingsReadout(
                label: 'Away',
                value: away == 0 ? 'none' : '$away',
              ),
            ],
          ),
        ],
        const SettingsRule(),
        SettingsSection(
          label: conversation.isChannel ? 'Leave' : 'Close',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
              child: Text(
                conversation.isChannel
                    ? 'Leaving removes the channel and its scrollback from this '
                          'session. Rejoin any time with /join ${conversation.name}.'
                    : 'This conversation closes when you leave it.',
                style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.4),
              ),
            ),
            if (conversation.isChannel)
              SettingsActions(
                children: [
                  SettingsDangerButton(
                    label: 'Leave channel',
                    onPressed: _leave,
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}
