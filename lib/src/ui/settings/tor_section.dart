import 'package:flutter/material.dart';

import '../../model/proxy.dart';
import '../../model/tor.dart';
import '../../theme.dart';
import 'settings_chrome.dart';

/// The bundled Tor, as shown in App settings — beta.
///
/// One switch, not two. Starting Tor and routing through it are separate
/// operations underneath, but there is no reason to want one without the
/// other: a Tor running that nothing goes through is a few hundred megabytes
/// of directory data and a set of guards, in exchange for nothing.
///
/// It sits above the proxy section because it is the answer most people
/// reaching for that section actually want, and because leaving it below
/// would mean the first thing offered is a form asking for an address they do
/// not have.
class TorSection extends StatefulWidget {
  const TorSection({super.key});

  @override
  State<TorSection> createState() => _TorSectionState();
}

class _TorSectionState extends State<TorSection> {
  bool _busy = false;

  Future<void> _set(TorSettings tor, ProxySettings proxies, bool on) async {
    setState(() => _busy = true);
    // Tor first when turning on, so the port exists before anything is
    // pointed at it; the proxy first when turning off, so nothing is left
    // pointed at a port that has stopped answering. Either order works —
    // `resolveProxy` refuses the gap rather than connecting around it — but
    // there is no reason to open a gap that does not have to exist.
    if (on) {
      await tor.setEnabled(true);
      await proxies.useBuiltIn(true);
    } else {
      await proxies.useBuiltIn(false);
      await tor.setEnabled(false);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tor = TorScope.of(context);
    final proxies = ProxyScope.of(context);
    final on = proxies.route == ProxyRoute.builtIn;
    final progress = tor.progress;

    return SettingsSection(
      label: 'Tor',
      beta: true,
      children: [
        SettingsSwitch(
          label: 'Route everything through the built-in Tor',
          description:
              'Tor is inside the app — there is nothing to install and '
              'nothing else to run. The first start has to fetch a directory '
              'of the network, which takes a while; after that it is quick. '
              'While this is on it is the only way out: every network goes '
              'through it, including any set to Direct or to its own proxy.',
          value: on,
          onChanged: _busy ? (_) {} : (v) => _set(tor, proxies, v),
        ),
        if (on) ...[
          SettingsReadout(
            label: 'Status',
            value: tor.running
                ? (progress.ready
                      ? 'Ready — ${progress.summary}'
                      : '${(progress.progress * 100).round()}% — '
                            '${progress.summary}')
                : 'Not running',
          ),
          // A bar as well as the words, because this is the one wait in the
          // app long enough that "is it doing anything" is a real question.
          if (tor.running && !progress.ready)
            _BootstrapBar(value: progress.progress),
          SettingsReadout(
            label: 'Address',
            value: tor.port == null ? 'None yet' : '127.0.0.1:${tor.port}',
          ),
          // Not "every network set to App default", which is what the proxy
          // below applies to. This one takes the lot, and saying so here is
          // cheaper than someone discovering it from a network that stopped
          // connecting directly the way they had set it to.
          const SettingsReadout(
            label: 'Applies to',
            value: 'Every network, with no exceptions',
          ),
          // Said plainly rather than left to be inferred from a connection
          // that never completes. Until Tor is ready there is no proxy to go
          // through, and the app will not go around it.
          if (!progress.ready)
            SettingsNote(
              text: tor.running
                  ? 'Networks will not connect until this finishes. ddIRC '
                        'will not fall back to a direct connection.'
                  : 'Tor is switched on but not running, so nothing will '
                        'connect. It will not fall back to a direct '
                        'connection.',
              isError: !tor.running,
            ),
          if (progress.blocked != null)
            SettingsNote(text: progress.blocked!, isError: true),
          if (tor.failure != null)
            SettingsNote(text: tor.failure!, isError: true),
        ],
      ],
    );
  }
}

/// The bootstrap, as a hairline.
///
/// Deliberately thin and in the muted colour rather than the accent: this is
/// a wait being reported, not an achievement.
class _BootstrapBar extends StatelessWidget {
  const _BootstrapBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          minHeight: 3,
          backgroundColor: t.surfaceHover,
          valueColor: AlwaysStoppedAnimation(t.muted),
        ),
      ),
    );
  }
}
