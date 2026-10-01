import 'package:flutter/material.dart';

import '../model/people.dart';
import '../model/session.dart';
import '../model/settings.dart';
import '../rust/api/types.dart';
import '../theme.dart';
import 'avatar.dart';
import 'nick_color.dart';
import 'person_dialog.dart';
import 'settings/settings_chrome.dart';

/// Who someone is, in one place: what the server says about them, what you
/// share with them, what you wrote about them, and what you can do about
/// them.
///
/// Opened from a name in the scrollback and from the member list. The WHOIS
/// is asked for when the sheet opens and not before — it is a request the
/// other side's server sees, and nobody should be looked up because their
/// name scrolled past.
class PersonSheet extends StatefulWidget {
  const PersonSheet({super.key, required this.session, required this.nick});

  final SessionModel session;
  final String nick;

  static Future<void> show(
    BuildContext context, {
    required SessionModel session,
    required String nick,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => PersonSheet(session: session, nick: nick),
    );
  }

  @override
  State<PersonSheet> createState() => _PersonSheetState();
}

class _PersonSheetState extends State<PersonSheet> {
  late final Future<WhoisInfo?> _whois;

  @override
  void initState() {
    super.initState();
    _whois = widget.session.whois(widget.nick);
  }

  /// Channels this session is in where [nick] is too.
  List<String> _shared() {
    final folded = widget.nick.toLowerCase();
    return [
      for (final conversation in widget.session.conversations)
        if (conversation.isChannel &&
            conversation.members.any((m) => m.nick.toLowerCase() == folded))
          conversation.name,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final settings = SettingsScope.of(context);
    final session = widget.session;
    final profileId = session.profileId;
    final nick = widget.nick;
    final isSelf = nick.toLowerCase() == session.nick.toLowerCase();

    return ListenableBuilder(
      listenable: People.instance,
      builder: (context, _) {
        final card = People.instance.of(profileId, nick);
        final color =
            card?.color ??
            (settings.colorNicks ? NickPalette.of(nick, t) : t.text);
        final shared = _shared();
        final blocked = settings.isBlocked(profileId, nick);
        final muted = settings.isNickMuted(profileId, nick);

        return SettingsDialog(
          title: card?.alias ?? nick,
          subtitle: card?.alias == null ? null : nick,
          children: [
            if (card?.hasPicture ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Center(child: Avatar(card: card, size: 56)),
              ),
            if (card?.note case final note?) SettingsNote(text: note),
            SettingsSection(
              label: 'On the server',
              children: [
                FutureBuilder<WhoisInfo?>(
                  future: _whois,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: color,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Asking the server…',
                              style: TextStyle(color: t.muted, fontSize: 12.5),
                            ),
                          ],
                        ),
                      );
                    }
                    final whois = snapshot.data;
                    if (whois == null) {
                      return const SettingsNote(
                        text: 'The server did not answer.',
                      );
                    }
                    if (!whois.found) {
                      return SettingsNote(
                        text: '$nick is not online on this network right now.',
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (whois.realname case final name?
                            when name.trim().isNotEmpty)
                          SettingsReadout(label: 'Real name', value: name),
                        if (whois.user != null || whois.host != null)
                          SettingsReadout(
                            label: 'Address',
                            value: '${whois.user ?? '?'}@${whois.host ?? '?'}',
                          ),
                        if (whois.account case final account?)
                          SettingsReadout(label: 'Account', value: account),
                        if (whois.away case final away?)
                          SettingsReadout(label: 'Away', value: away),
                        if (whois.idleSecs case final idle?)
                          SettingsReadout(
                            label: 'Idle',
                            value: _describeIdle(idle.toInt()),
                          ),
                        if (whois.server case final server?)
                          SettingsReadout(label: 'Server', value: server),
                        SettingsReadout(
                          label: 'Connection',
                          value: whois.secure
                              ? 'Encrypted (TLS)'
                              : 'Not reported as encrypted',
                        ),
                        if (whois.operator_)
                          const SettingsReadout(
                            label: 'Role',
                            value: 'Network operator',
                          ),
                        if (whois.channels.isNotEmpty)
                          SettingsReadout(
                            label: 'Channels',
                            value: whois.channels.join(' '),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
            if (shared.isNotEmpty)
              SettingsSection(
                label: 'Channels you share',
                children: [
                  SettingsReadout(label: 'In', value: shared.join(', ')),
                ],
              ),
            if (!isSelf)
              SettingsActions(
                children: [
                  SettingsPrimaryButton(
                    label: 'Message',
                    onPressed: () {
                      Navigator.of(context).pop();
                      session.openDirect(nick);
                    },
                  ),
                  SettingsSecondaryButton(
                    label: 'Name & note…',
                    onPressed: () => PersonDialog.show(
                      context,
                      profileId: profileId,
                      nick: nick,
                    ),
                  ),
                ],
              ),
            if (!isSelf)
              SettingsSection(
                label: 'Quieter',
                children: [
                  SettingsSwitch(
                    label: 'Hide in channels',
                    description:
                        'Their lines stop appearing in channels you share. '
                        'They can still message you directly, and nothing '
                        'is sent to tell them.',
                    value: muted,
                    onChanged: (v) => settings.setNickMuted(profileId, nick, v),
                  ),
                  SettingsSwitch(
                    label: 'Block direct messages',
                    description:
                        'Their private messages are dropped before they '
                        'reach a conversation, a count or a log.',
                    value: blocked,
                    onChanged: (v) => v
                        ? settings.block(profileId, nick)
                        : settings.unblock(profileId, nick),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }

  static String _describeIdle(int seconds) {
    if (seconds < 60) return 'Active just now';
    if (seconds < 3600) return '${seconds ~/ 60} min';
    if (seconds < 86400) {
      return '${seconds ~/ 3600} h ${(seconds % 3600) ~/ 60} min';
    }
    return '${seconds ~/ 86400} days';
  }
}
