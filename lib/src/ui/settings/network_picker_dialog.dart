import 'package:flutter/material.dart';

import '../../model/directory.dart';
import '../../theme.dart';
import '../motion.dart';
import '../touchable.dart';
import 'settings_chrome.dart';

/// A network the user picked, and the channels they want to land in.
@immutable
class NetworkPick {
  const NetworkPick({required this.network, required this.channels});

  final KnownNetwork network;

  /// In catalogue order, so the autojoin list reads the same way the picker
  /// did rather than in the order things happened to be tapped.
  final List<String> channels;
}

/// Pick a network from the ones ddIRC already knows, then the rooms to open.
///
/// Two steps in one dialog rather than two dialogs: choosing OFTC and choosing
/// `#debian` is one decision made in two moves, and a second dialog would put
/// a stack between the user and going back on the first move.
///
/// This does not connect and does not save. It hands its answer to the profile
/// editor, which is still where a network is created — so the address, the
/// nickname and the proxy are reviewed in the one form that has always been
/// responsible for them, rather than being committed behind a two-tap flow.
class NetworkPickerDialog extends StatefulWidget {
  const NetworkPickerDialog({super.key});

  static Future<NetworkPick?> show(BuildContext context) {
    return showDialog<NetworkPick>(
      context: context,
      builder: (_) => const NetworkPickerDialog(),
    );
  }

  @override
  State<NetworkPickerDialog> createState() => _NetworkPickerDialogState();
}

class _NetworkPickerDialogState extends State<NetworkPickerDialog> {
  final _query = TextEditingController();

  /// Null on the list step, set on the channel step. There is no separate
  /// step enum, because the selected network *is* the step.
  KnownNetwork? _network;

  final _channels = <String>{};

  @override
  void initState() {
    super.initState();
    _query.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(KnownNetwork network) {
    setState(() {
      _network = network;
      _channels
        ..clear()
        // The network's own help channel, and nothing else. Somewhere to ask
        // is the one room a newcomer certainly wants; the rest is a guess
        // about their interests that they can make faster than we can.
        ..addAll(network.channels.take(1).map((c) => c.name));
    });
  }

  void _back() => setState(() => _network = null);

  void _done() {
    final network = _network;
    if (network == null) return;
    Navigator.of(context).pop(
      NetworkPick(
        network: network,
        channels: network.channels
            .map((c) => c.name)
            .where(_channels.contains)
            .toList(growable: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final network = _network;
    return SettingsDialog(
      title: network == null ? 'Browse networks' : network.name,
      subtitle: network == null
          ? 'Still running, and reachable over TLS'
          : '${network.host}:${network.port}',
      width: 460,
      children: network == null
          ? _list(context)
          : _channelStep(context, network),
    );
  }

  // ---- Step one: the networks ------------------------------------------

  List<Widget> _list(BuildContext context) {
    final t = context.tokens;
    final matches = searchNetworks(_query.text);

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
        child: SettingsField(
          controller: _query,
          hint: 'Search networks and channels — try "debian"',
        ),
      ),
      if (matches.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: Text(
            'Nothing here matches “${_query.text.trim()}”. Any other server '
            'can still be added by hand.',
            style: TextStyle(color: t.faint, fontSize: 12.5, height: 1.4),
          ),
        )
      else
        for (final network in matches)
          _NetworkRow(network: network, onTap: () => _open(network)),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
        child: Text(
          'Picking one fills in the address and the channels. You still get '
          'the full form afterwards, so nothing connects until you say so.',
          style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.4),
        ),
      ),
    ];
  }

  // ---- Step two: the channels ------------------------------------------

  List<Widget> _channelStep(BuildContext context, KnownNetwork network) {
    final t = context.tokens;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
        child: Text(
          network.blurb,
          style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.45),
        ),
      ),
      if (network.note != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
          child: _Note(text: network.note!),
        ),
      if (network.sasl)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
          child: Text(
            'Supports SASL, so an account can be filled in on the next screen.',
            style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.4),
          ),
        ),
      const SizedBox(height: 4),
      if (network.channels.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
          child: Text(
            'No channels suggested for this network. Type the ones you want '
            'on the next screen.',
            style: TextStyle(color: t.faint, fontSize: 12.5, height: 1.4),
          ),
        )
      else ...[
        SettingsSection(
          label: 'Popular channels',
          children: [
            for (final channel in network.channels)
              _ChannelRow(
                channel: channel,
                selected: _channels.contains(channel.name),
                onTap: () => setState(() {
                  if (!_channels.remove(channel.name)) {
                    _channels.add(channel.name);
                  }
                }),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
          child: Text(
            'Suggestions, not a directory — a channel can go quiet between '
            'releases of this app. Any others can be typed on the next '
            'screen.',
            style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.4),
          ),
        ),
      ],
      const SettingsRule(),
      SettingsActions(
        children: [
          _BackButton(onPressed: _back),
          SettingsPrimaryButton(
            label: _channels.isEmpty
                ? 'Continue'
                : 'Continue with ${_channels.length}',
            onPressed: _done,
          ),
        ],
      ),
      const SizedBox(height: 6),
    ];
  }
}

/// One network in the list.
class _NetworkRow extends StatelessWidget {
  const _NetworkRow({required this.network, required this.onTap});

  final KnownNetwork network;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final count = network.channels.length;

    return Touchable(
      onTap: onTap,
      builder: (context, touch) => AnimatedContainer(
        duration: context.motion.fast,
        curve: Motion.curve,
        color: t.surfaceHover.withValues(alpha: touch.wash),
        padding: const EdgeInsets.fromLTRB(18, 11, 14, 11),
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
                          network.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: t.text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (network.sasl) ...[
                        const SizedBox(width: 7),
                        _Tag(label: 'SASL'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${network.host}:${network.port}',
                    style: TextStyle(color: t.faint, fontSize: 11.5),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    network.blurb,
                    style: TextStyle(color: t.muted, fontSize: 12, height: 1.4),
                  ),
                  if (count > 0) ...[
                    const SizedBox(height: 5),
                    Text(
                      count == 1
                          ? '1 channel suggested'
                          : '$count channels suggested',
                      style: TextStyle(color: t.faint, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.chevron_right, size: 18, color: t.faint),
            ),
          ],
        ),
      ),
    );
  }
}

/// One suggested channel, with its box.
class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    required this.channel,
    required this.selected,
    required this.onTap,
  });

  final KnownChannel channel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;

    return Touchable(
      onTap: onTap,
      builder: (context, touch) => AnimatedContainer(
        duration: m.fast,
        curve: Motion.curve,
        color: t.surfaceHover.withValues(alpha: touch.wash),
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
        child: Row(
          children: [
            AnimatedContainer(
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
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    channel.name,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 13,
                      fontFamily: Fonts.mono,
                      fontFamilyFallback: Fonts.monoFallback,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    channel.blurb,
                    style: TextStyle(color: t.faint, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Something about the network the user should read before connecting.
class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: t.warn.withValues(alpha: 0.35),
          width: Tokens.hairline,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: t.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// A one-word fact beside a network's name.
class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.rule, width: Tokens.hairline),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: t.faint,
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// Back to the network list. Quiet, like the editor's Save-without-connecting.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});

  final VoidCallback onPressed;

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
      child: const Text('Back'),
    );
  }
}
