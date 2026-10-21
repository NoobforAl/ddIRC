import 'package:flutter/material.dart';

import '../model/session.dart';
import '../rust/api/types.dart' show Availability, ContactView, Subscription;
import '../theme.dart';
import 'menu.dart';
import 'motion.dart';
import 'settings/settings_chrome.dart';

/// The colour of a presence dot, and the words for it.
///
/// Shared by the list and the status picker, so the dot that says what a
/// contact is doing and the dot that says what *you* are doing cannot drift
/// into meaning different things.
Color availabilityColor(Tokens t, Availability a) => switch (a) {
  Availability.available => t.ok,
  Availability.away || Availability.extendedAway => t.warn,
  Availability.dnd => t.bad,
  Availability.offline => t.faint,
};

String availabilityLabel(Availability a) => switch (a) {
  Availability.available => 'Available',
  Availability.away => 'Away',
  Availability.extendedAway => 'Away for a while',
  Availability.dnd => 'Busy',
  Availability.offline => 'Offline',
};

/// The people on an XMPP account's contact list, who is waiting to be let in,
/// and how the user themselves is.
///
/// A dialog rather than a pane of its own: it is something you open, act on and
/// leave, and on a phone it fills the screen the way every other dialog here
/// does. Nothing in it is answered on the user's behalf — a request to see when
/// you are online waits here until the user says yes or no, because saying yes
/// tells a stranger that you exist and are reading.
class ContactsDialog extends StatefulWidget {
  const ContactsDialog({
    super.key,
    required this.session,
    required this.onOpenChat,
  });

  final SessionModel session;

  /// Open a conversation with this address.
  final ValueChanged<String> onOpenChat;

  static Future<void> show(
    BuildContext context,
    SessionModel session, {
    required ValueChanged<String> onOpenChat,
  }) {
    return showSoftDialog<void>(
      context: context,
      builder: (_) => ContactsDialog(session: session, onOpenChat: onOpenChat),
    );
  }

  @override
  State<ContactsDialog> createState() => _ContactsDialogState();
}

class _ContactsDialogState extends State<ContactsDialog> {
  final _address = TextEditingController();
  String? _problem;
  bool _busy = false;

  SessionModel get session => widget.session;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _address.text.trim();
    if (text.isEmpty || _busy) return;
    // The shape of an address is checked here for a plain answer; the core
    // checks it again, because this is the courtesy and that is the rule.
    final at = text.indexOf('@');
    if (at < 1 || at == text.length - 1 || text.contains(' ')) {
      setState(
        () => _problem =
            'That is not an address. It looks like name@example.org.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    final error = await session.addContact(text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = error;
      if (error == null) _address.clear();
    });
  }

  Future<void> _answer(String jid, bool accept) async {
    final error = await session.answerSubscription(jid, accept: accept);
    if (mounted && error != null) setState(() => _problem = error);
  }

  Future<void> _remove(ContactView contact) async {
    final error = await session.removeContact(contact.jid);
    if (mounted && error != null) setState(() => _problem = error);
  }

  void _chat(String jid) {
    Navigator.of(context).pop();
    widget.onOpenChat(jid);
  }

  Future<void> _status() async {
    await StatusDialog.show(context, session);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final contacts = session.contacts;
        final requests = session.subscriptionRequests;
        return SettingsDialog(
          title: 'Contacts',
          subtitle: session.nick,
          width: 440,
          children: [
            _SelfRow(session: session, onTap: _status),
            if (requests.isNotEmpty) ...[
              _Heading('Waiting for your answer'),
              for (final jid in requests)
                _RequestRow(
                  jid: jid,
                  onAccept: () => _answer(jid, true),
                  onDecline: () => _answer(jid, false),
                ),
              const SettingsProse(
                'Accepting lets them see when you are online and what you '
                'say about yourself. Declining tells them nothing more '
                'than that.',
              ),
            ],
            _Heading('Add a contact'),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
              child: Row(
                children: [
                  Expanded(
                    child: SettingsField(
                      controller: _address,
                      hint: 'name@example.org',
                      error: _problem,
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SettingsPrimaryButton(
                    label: 'Add',
                    onPressed: _busy ? null : _add,
                  ),
                ],
              ),
            ),
            const SettingsProse(
              'They are asked whether you may see when they are online. '
              'Nothing is shown until they say yes.',
            ),
            _Heading(
              contacts.isEmpty
                  ? 'No contacts yet'
                  : 'Contacts (${contacts.length})',
            ),
            for (final contact in contacts)
              _ContactRow(
                contact: contact,
                onChat: () => _chat(contact.jid),
                onRemove: () => _remove(contact),
                onAskToSee: () => session.addContact(contact.jid),
              ),
            if (contacts.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: Text(
                  'People you add appear here, with whether they are online.',
                  style: TextStyle(color: t.faint, fontSize: 12, height: 1.45),
                ),
              ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
      child: Text(
        text,
        style: TextStyle(
          color: t.muted,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// The user's own status, which is also the way to change it.
class _SelfRow extends StatelessWidget {
  const _SelfRow({required this.session, required this.onTap});

  final SessionModel session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final status = session.myStatus;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
        child: Row(
          children: [
            _Dot(color: availabilityColor(t, session.myAvailability)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'You: ${availabilityLabel(session.myAvailability)}',
                    style: TextStyle(color: t.text, fontSize: 14),
                  ),
                  if (status.isNotEmpty)
                    Text(
                      status,
                      style: TextStyle(color: t.muted, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Text('Change', style: TextStyle(color: t.accent, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({
    required this.jid,
    required this.onAccept,
    required this.onDecline,
  });

  final String jid;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final address = Text(
      jid,
      style: TextStyle(color: t.text, fontSize: 14),
      overflow: TextOverflow.ellipsis,
    );
    final buttons = [
      TextButton(
        onPressed: onDecline,
        style: TextButton.styleFrom(foregroundColor: t.muted),
        child: const Text('Decline'),
      ),
      FilledButton(
        onPressed: onAccept,
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          elevation: 0,
        ),
        child: const Text('Accept'),
      ),
    ];
    // Side by side when there is room, and the buttons under the address when
    // there is not: with text turned up, the two buttons alone are most of a
    // phone's width, and an address squeezed between them and the edge is
    // nothing but an ellipsis.
    final large = MediaQuery.textScalerOf(context).scale(1) > 1.2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 12, 4),
      child: large
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                address,
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: buttons,
                ),
              ],
            )
          : Row(
              children: [
                Expanded(child: address),
                ...buttons,
              ],
            ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.contact,
    required this.onChat,
    required this.onRemove,
    required this.onAskToSee,
  });

  final ContactView contact;
  final VoidCallback onChat;
  final VoidCallback onRemove;
  final VoidCallback onAskToSee;

  /// What to say under the name: what they say they are doing, or else what
  /// state the two of you are in, when that is something to act on.
  String? _subtitle() {
    if (contact.status.isNotEmpty) return contact.status;
    if (contact.asked) return 'Waiting for them to accept';
    switch (contact.subscription) {
      case Subscription.from:
        return 'They can see you; you cannot see them';
      case Subscription.unlinked:
        return 'You cannot see when they are online';
      case Subscription.to || Subscription.both:
        return contact.name == null ? null : contact.jid;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final subtitle = _subtitle();
    final canAsk =
        !contact.asked &&
        (contact.subscription == Subscription.from ||
            contact.subscription == Subscription.unlinked);
    return InkWell(
      onTap: onChat,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 6, 8),
        child: Row(
          children: [
            Semantics(
              label: availabilityLabel(contact.availability),
              child: _Dot(color: availabilityColor(t, contact.availability)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name ?? contact.jid,
                    style: TextStyle(color: t.text, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: TextStyle(color: t.muted, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: Icon(Icons.more_vert, size: 18, color: t.muted),
              onSelected: (value) {
                switch (value) {
                  case 'chat':
                    onChat();
                  case 'ask':
                    onAskToSee();
                  case 'remove':
                    onRemove();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'chat',
                  child: MenuRow(
                    icon: Icons.chat_bubble_outline,
                    label: 'Message',
                  ),
                ),
                if (canAsk)
                  const PopupMenuItem(
                    value: 'ask',
                    child: MenuRow(
                      icon: Icons.visibility_outlined,
                      label: 'Ask to see them',
                    ),
                  ),
                const PopupMenuItem(
                  value: 'remove',
                  child: MenuRow(
                    icon: Icons.person_remove_outlined,
                    label: 'Remove',
                    danger: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Say how you are, to everyone who can see you.
///
/// The text is whatever the user types and is sent as typed. It is the one
/// thing the app says about the user on its own account that the user wrote,
/// and the dialog says who sees it.
class StatusDialog extends StatefulWidget {
  const StatusDialog({super.key, required this.session});

  final SessionModel session;

  static Future<void> show(BuildContext context, SessionModel session) {
    return showSoftDialog<void>(
      context: context,
      builder: (_) => StatusDialog(session: session),
    );
  }

  @override
  State<StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<StatusDialog> {
  late Availability _availability = widget.session.myAvailability;
  late final TextEditingController _text = TextEditingController(
    text: widget.session.myStatus,
  );
  String? _problem;
  bool _busy = false;

  /// What can be chosen. Offline is not one: it is what nobody has said, not
  /// something to say.
  static const _choices = [
    Availability.available,
    Availability.away,
    Availability.dnd,
    Availability.extendedAway,
  ];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    final error = await widget.session.setAvailability(
      _availability,
      status: _text.text,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _problem = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SettingsDialog(
      title: 'Your status',
      subtitle: widget.session.nick,
      width: 400,
      children: [
        for (final choice in _choices)
          InkWell(
            onTap: () => setState(() => _availability = choice),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Row(
                children: [
                  _Dot(color: availabilityColor(t, choice)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      availabilityLabel(choice),
                      style: TextStyle(color: t.text, fontSize: 14),
                    ),
                  ),
                  if (choice == _availability)
                    Icon(Icons.check_rounded, size: 18, color: t.accent),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
          child: SettingsField(
            controller: _text,
            hint: 'What you are up to (optional)',
            error: _problem,
            onSubmitted: (_) => _save(),
          ),
        ),
        const SettingsProse(
          'Everyone who can see when you are online sees this, and so '
          'does every room you are in. It is sent exactly as you write it.',
        ),
        SettingsActions(
          children: [
            SettingsTertiaryButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(context).pop(),
            ),
            SettingsPrimaryButton(
              label: 'Save',
              onPressed: _busy ? null : _save,
            ),
          ],
        ),
      ],
    );
  }
}
