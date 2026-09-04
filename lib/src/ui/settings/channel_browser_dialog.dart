import 'package:flutter/material.dart';

import '../../model/session.dart';
import '../../rust/api/types.dart';
import '../../theme.dart';
import '../motion.dart';
import '../touchable.dart';
import 'settings_chrome.dart';

/// What the server has, so a channel can be chosen rather than typed.
///
/// Until this existed the only way into a room you had not saved was `/join
/// #name`, which is a fine command and a hopeless discovery mechanism: it
/// requires already knowing the answer. The empty channel list said as much,
/// and said it to precisely the people least able to act on it.
///
/// Sorted by how busy each channel is, and that ordering is the whole design.
/// A network's full directory is tens of thousands of rooms, most of them
/// empty and many of them abandoned; the two hundred busiest are a place to
/// start, and everything past that is better reached by name.
///
/// One channel per visit. Tapping joins it and closes, because joining is the
/// end of the errand — and because a browser that let five be ticked at once
/// would put five tabs on screen, which is the thing the tab strip was just
/// taught not to do.
class ChannelBrowserDialog extends StatefulWidget {
  const ChannelBrowserDialog({super.key, required this.session});

  final SessionModel session;

  static Future<void> show(BuildContext context, SessionModel session) {
    return showDialog<void>(
      context: context,
      builder: (_) => ChannelBrowserDialog(session: session),
    );
  }

  @override
  State<ChannelBrowserDialog> createState() => _ChannelBrowserDialogState();
}

class _ChannelBrowserDialogState extends State<ChannelBrowserDialog> {
  final _query = TextEditingController();

  SessionModel get session => widget.session;

  @override
  void initState() {
    super.initState();
    _query.addListener(() {
      if (mounted) setState(() {});
    });
    session.addListener(_onSession);
    // Only when there is nothing to show. Reopening the browser keeps what
    // arrived last time rather than emptying it and asking again, because the
    // question is expensive and the answer does not change by the minute.
    if (session.directory.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => session
          .browseChannels());
    }
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    _query.dispose();
    super.dispose();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  void _join(String channel) {
    session.joinChannel(channel);
    Navigator.of(context).pop();
  }

  /// What the query matches, in the order the server's population put them.
  ///
  /// Name and topic both, because half of why anybody looks at a directory is
  /// to find rooms about something rather than rooms called something.
  List<ChannelListing> get _matches {
    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return session.directory;
    return session.directory
        .where(
          (c) =>
              c.name.toLowerCase().contains(query) ||
              c.topic.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;

    return SettingsDialog(
      title: 'Browse channels',
      subtitle: session.network ?? session.config.host,
      width: 480,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
          child: SettingsField(
            controller: _query,
            hint: 'Filter by name or topic',
          ),
        ),
        _status(context),
        if (matches.isEmpty)
          _empty(context)
        else
          for (final channel in matches)
            _ChannelRow(
              listing: channel,
              joined: session.isIn(channel.name),
              onTap: () => _join(channel.name),
            ),
        const SizedBox(height: 8),
      ],
    );
  }

  /// One line about where the list came from, and never nothing.
  ///
  /// A directory with no provenance is a directory you cannot judge: 200 rows
  /// out of 40,000 look exactly like all 200 a server has, and the difference
  /// decides whether it is worth typing a name instead.
  Widget _status(BuildContext context) {
    final t = context.tokens;
    final total = session.directory.length;
    final loading = session.directoryLoading;

    final String text;
    if (loading && total == 0) {
      text = 'Asking the server…';
    } else if (loading) {
      text = '$total so far, busiest first — still arriving';
    } else if (total == 0) {
      text = 'Nothing came back.';
    } else if (session.directoryTruncated) {
      text = 'The $total busiest. There are more; type a name to join it.';
    } else {
      text = total == 1 ? 'One channel' : '$total channels';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
      child: Row(
        children: [
          if (loading) ...[
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation(t.faint),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.4),
            ),
          ),
          if (!loading)
            TextButton(
              onPressed: session.browseChannels,
              style: TextButton.styleFrom(
                foregroundColor: t.muted,
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: const Text('Refresh'),
            ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final t = context.tokens;
    final filtering = _query.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
      child: Text(
        filtering
            ? 'Nothing here matches that. A channel can still be joined by '
                  'name, whether or not the server lists it.'
            : session.directoryLoading
            ? 'The busiest channels will appear here as they arrive.'
            : 'This server did not list its channels. Many do not, and some '
                  'refuse the question outright — joining by name still works.',
        style: TextStyle(color: t.faint, fontSize: 12, height: 1.5),
      ),
    );
  }
}

/// One channel, as something to decide about.
class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    required this.listing,
    required this.joined,
    required this.onTap,
  });

  final ChannelListing listing;

  /// Already in it. Shown rather than hidden — a directory that silently
  /// dropped the channels you are in would look like they had closed.
  final bool joined;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Touchable(
      onTap: onTap,
      builder: (context, touch) => AnimatedContainer(
        duration: context.motion.fast,
        curve: Motion.curve,
        color: t.surfaceHover.withValues(alpha: touch.wash),
        padding: const EdgeInsets.fromLTRB(18, 9, 18, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          listing.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: t.text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (joined) ...[
                        const SizedBox(width: 7),
                        Text(
                          'joined',
                          style: TextStyle(color: t.accent, fontSize: 10.5),
                        ),
                      ],
                    ],
                  ),
                  if (listing.topic.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      listing.topic,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.muted,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            // The population, which is the one fact that makes a list of names
            // choosable. Right-aligned in a fixed column so the numbers line up
            // and the eye can run down them.
            SizedBox(
              width: 44,
              child: Text(
                '${listing.users}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: t.faint,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
