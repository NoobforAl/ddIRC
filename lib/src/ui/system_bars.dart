import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Gives the phone's own bars — the clock and battery above, the buttons
/// below — the app's colours, and the right colour of icon on them.
///
/// Nothing set these, so the platform chose. On a dark app that was close
/// enough to invisible. On a light one it was a grey band over the top of a warm
/// off-white page, and a solid black strip under it holding white icons: the
/// two brightest things on the screen were the two most obviously not part of
/// the app. A dialog's dimming made the top one worse, because it fell on the
/// bar's grey rather than on the page.
///
/// The bars take the ground colour, the same as the page behind the header and
/// the composer, so the app reads as one surface from edge to edge. The icons
/// are the opposite brightness to it — dark on light, light on dark — which is
/// the half the platform cannot guess, and getting it wrong is how a status bar
/// ends up with white icons on white.
class SystemBars extends StatelessWidget {
  const SystemBars({super.key, required this.child});

  final Widget child;

  /// What the bars should look like under [t]. A function of the palette alone,
  /// so a test can hold both themes to it without a device.
  static SystemUiOverlayStyle styleFor(Tokens t) {
    final light = t.brightness == Brightness.light;
    final icons = light ? Brightness.dark : Brightness.light;
    return SystemUiOverlayStyle(
      statusBarColor: t.bg,
      statusBarIconBrightness: icons,
      // iOS reads the brightness of the bar's *background* instead, which is
      // the opposite of the icons.
      statusBarBrightness: light ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: t.bg,
      systemNavigationBarIconBrightness: icons,
      // No line between the app and the buttons: the colour is the same, and a
      // divider would be the one seam left.
      systemNavigationBarDividerColor: Colors.transparent,
      // Android otherwise darkens a transparent-looking bar to keep its buttons
      // legible, which is exactly the grey this is here to remove. The icons
      // are chosen against the colour, so there is nothing to enforce.
      systemNavigationBarContrastEnforced: false,
      systemStatusBarContrastEnforced: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: styleFor(context.tokens),
      child: child,
    );
  }
}
