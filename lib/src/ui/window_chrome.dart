import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';

/// True where the app draws its own window frame.
///
/// Mobile has no window chrome to replace, so everything here is inert there
/// and the app renders exactly as it did before.
final bool hasWindowChrome =
    !kIsWeb &&
    const {
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform);

/// Height of the title strip. Tall enough to grab, short enough to disappear.
const double windowChromeHeight = 34;

/// Hide the native title bar before the first frame.
///
/// Called from `main`, and only on desktop — the window must be reconfigured
/// while it is still hidden, otherwise the caption flashes on screen first.
Future<void> prepareWindow() async {
  if (!hasWindowChrome) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1180, 780),
      minimumSize: Size(420, 480),
      center: true,
      backgroundColor: Tokens.bg,
      // The frame is ours from here on; the OS draws nothing — including
      // macOS's own traffic lights, which would otherwise sit beside ours.
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      title: 'ddIRC',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
}

/// Wraps a screen in the custom title strip.
///
/// Applied once, in `MaterialApp.builder`, so every route gets the same frame
/// and no screen has to remember to include it.
class WindowFrame extends StatelessWidget {
  const WindowFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!hasWindowChrome) return child;

    return Column(
      children: [
        const _TitleStrip(),
        Expanded(child: child),
      ],
    );
  }
}

class _TitleStrip extends StatelessWidget {
  const _TitleStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: windowChromeHeight,
      decoration: const BoxDecoration(
        color: Tokens.bg,
        border: Border(
          bottom: BorderSide(color: Tokens.rule, width: Tokens.hairline),
        ),
      ),
      // The frame sits above the navigator, so there is no Material in scope;
      // without one, Flutter marks every Text as unstyled with a yellow
      // underline. A transparent Material supplies the default text style and
      // nothing else.
      child: const Material(
        type: MaterialType.transparency,
        child: Row(
          children: [
            SizedBox(width: 12),
            // The lights sit beside the drag region, not inside it. Nesting
            // them would put every click into a gesture arena with the drag
            // recogniser, and dragging from a window button does nothing on
            // any platform anyway.
            TrafficLights(),
            SizedBox(width: 12),
            // DragToMoveArea brings its own double-tap-to-maximise, so the
            // strip behaves like a title bar without us restating it.
            Expanded(child: DragToMoveArea(child: _Title())),
          ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.centerLeft,
      child: Text(
        'ddIRC',
        style: TextStyle(
          color: Tokens.faint,
          fontSize: 11.5,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// Close, minimise, maximise — in the macOS order and colours.
///
/// The glyphs only appear on hover over the group, which is what makes the
/// resting state three quiet dots rather than three buttons.
class TrafficLights extends StatefulWidget {
  const TrafficLights({super.key});

  @override
  State<TrafficLights> createState() => _TrafficLightsState();
}

class _TrafficLightsState extends State<TrafficLights> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Light(
            color: const Color(0xFFFF5F57),
            glyph: _Glyph.close,
            showGlyph: _hovering,
            onTap: windowManager.close,
          ),
          const SizedBox(width: 8),
          _Light(
            color: const Color(0xFFFEBC2E),
            glyph: _Glyph.minimise,
            showGlyph: _hovering,
            onTap: windowManager.minimize,
          ),
          const SizedBox(width: 8),
          _Light(
            color: const Color(0xFF28C840),
            glyph: _Glyph.maximise,
            showGlyph: _hovering,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
        ],
      ),
    );
  }
}

enum _Glyph { close, minimise, maximise }

class _Light extends StatelessWidget {
  const _Light({
    required this.color,
    required this.glyph,
    required this.showGlyph,
    required this.onTap,
  });

  static const _diameter = 12.0;

  final Color color;
  final _Glyph glyph;
  final bool showGlyph;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    // No tooltip: the frame is mounted above the navigator, so there is no
    // Overlay to host one. The hover glyph is the label — which is how these
    // controls have always identified themselves anyway.
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: _diameter,
          height: _diameter,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            // A hairline rim keeps the dots from dissolving into the
            // background at the lighter end of the palette.
            border: Border.all(
              color: Colors.black.withValues(alpha: 0.22),
              width: Tokens.hairline,
            ),
          ),
          child: AnimatedOpacity(
            opacity: showGlyph ? 1 : 0,
            duration: const Duration(milliseconds: 110),
            child: CustomPaint(painter: _GlyphPainter(glyph)),
          ),
        ),
      ),
    );
  }
}

/// Draws the hover glyph inside a light.
///
/// Painted rather than typed: at 12 logical pixels a font glyph is a smear,
/// and these three shapes are two strokes each.
class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph);

  final _Glyph glyph;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final reach = size.width * 0.22;
    final paint = Paint()
      ..color = const Color(0xCC000000)
      ..strokeWidth = 1.15
      ..strokeCap = StrokeCap.round;

    switch (glyph) {
      case _Glyph.close:
        canvas.drawLine(
          centre.translate(-reach, -reach),
          centre.translate(reach, reach),
          paint,
        );
        canvas.drawLine(
          centre.translate(reach, -reach),
          centre.translate(-reach, reach),
          paint,
        );
      case _Glyph.minimise:
        canvas.drawLine(
          centre.translate(-reach, 0),
          centre.translate(reach, 0),
          paint,
        );
      case _Glyph.maximise:
        canvas.drawLine(
          centre.translate(-reach, 0),
          centre.translate(reach, 0),
          paint,
        );
        canvas.drawLine(
          centre.translate(0, -reach),
          centre.translate(0, reach),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph;
}
