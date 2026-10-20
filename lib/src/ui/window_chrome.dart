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
Future<void> prepareWindow(Tokens t) async {
  if (!hasWindowChrome) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: Size(1180, 780),
      minimumSize: Size(420, 480),
      center: true,
      backgroundColor: t.bg,
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
    final t = context.tokens;
    return Container(
      height: windowChromeHeight,
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(
          bottom: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      // The frame sits above the navigator, so there is no Material in scope;
      // without one, Flutter marks every Text as unstyled with a yellow
      // underline. A transparent Material supplies the default text style and
      // nothing else.
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          children: [
            const SizedBox(width: 12),
            // Each desktop gets the controls its own users already know:
            // the lights at the left on macOS, caption buttons at the right
            // on Windows and Linux. Drawing macOS's on every platform put
            // "close" at the opposite corner from where a Windows or Linux
            // hand goes looking for it.
            //
            // They sit beside the drag region, not inside it. Nesting them
            // would put every click into a gesture arena with the drag
            // recogniser, and dragging from a window button does nothing on
            // any platform anyway.
            if (_usesTrafficLights) ...const [
              TrafficLights(),
              SizedBox(width: 12),
            ],
            // DragToMoveArea brings its own double-tap-to-maximise, so the
            // strip behaves like a title bar without us restating it.
            const Expanded(child: DragToMoveArea(child: _Title())),
            if (!_usesTrafficLights) const WindowControls(),
          ],
        ),
      ),
    );
  }
}

/// macOS is the only platform whose window controls are the three lights.
bool get _usesTrafficLights => defaultTargetPlatform == TargetPlatform.macOS;

/// Minimise, maximise-or-restore and close, at the right of the strip.
///
/// Windows gets the shape its users expect: flush, full-height rectangles that
/// fill on hover, with close turning red. Linux gets smaller round buttons that
/// sit inside the strip the way GTK's do. Both are drawn by [_CaptionGlyphPainter]
/// rather than set in a font, since a font's minus and box are different
/// weights at this size and neither matches the platform's own.
///
/// The maximise button follows the window — it shows *restore* while the
/// window is maximised — so it is a [WindowListener] and not a constant.
class WindowControls extends StatefulWidget {
  const WindowControls({super.key});

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> with WindowListener {
  bool _maximised = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refresh();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  // The listener reports the change; this reads the starting state, and covers
  // a window that was already maximised when the strip was built.
  Future<void> _refresh() async {
    try {
      final now = await windowManager.isMaximized();
      if (mounted && now != _maximised) setState(() => _maximised = now);
    } catch (_) {
      // No window manager (a test, or a platform that never started one): the
      // buttons still draw, they just start in the un-maximised state.
    }
  }

  @override
  void onWindowMaximize() => setState(() => _maximised = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximised = false);

  Future<void> _toggleMaximise() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final style = windows ? _CaptionStyle.windows : _CaptionStyle.linux;
    return Padding(
      padding: EdgeInsets.only(right: windows ? 0 : 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CaptionButton(
            label: 'Minimise',
            glyph: _CaptionGlyph.minimise,
            style: style,
            onTap: windowManager.minimize,
          ),
          if (!windows) const SizedBox(width: 2),
          _CaptionButton(
            label: _maximised ? 'Restore' : 'Maximise',
            glyph: _maximised ? _CaptionGlyph.restore : _CaptionGlyph.maximise,
            style: style,
            onTap: _toggleMaximise,
          ),
          if (!windows) const SizedBox(width: 2),
          _CaptionButton(
            label: 'Close',
            glyph: _CaptionGlyph.close,
            style: style,
            isClose: true,
            onTap: windowManager.close,
          ),
        ],
      ),
    );
  }
}

enum _CaptionStyle { windows, linux }

enum _CaptionGlyph { minimise, maximise, restore, close }

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.label,
    required this.glyph,
    required this.style,
    required this.onTap,
    this.isClose = false,
  });

  final String label;
  final _CaptionGlyph glyph;
  final _CaptionStyle style;
  final bool isClose;
  final Future<void> Function() onTap;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final windows = widget.style == _CaptionStyle.windows;

    // Windows' own close red, and its lighter pressed state. Used as the one
    // fixed colour here because it is the platform's, not the app's: a themed
    // red would read as a different control. Elsewhere the theme's is used.
    const windowsClose = Color(0xFFE81123);
    const windowsClosePressed = Color(0xFFF1707A);

    Color? fill;
    var ink = _hover ? t.text : t.muted;
    if (widget.isClose && (_hover || _down)) {
      fill = windows
          ? (_down ? windowsClosePressed : windowsClose)
          : t.bad.withValues(alpha: _down ? 0.28 : 0.16);
      ink = windows ? Colors.white : t.bad;
    } else if (_down) {
      fill = t.text.withValues(alpha: 0.14);
    } else if (_hover) {
      fill = t.text.withValues(alpha: windows ? 0.08 : 0.10);
    }

    // Tooltips need an Overlay, and the frame is mounted above the navigator,
    // so the label goes to assistive technology instead.
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _down = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: Container(
            width: windows ? 46 : 30,
            height: windows ? windowChromeHeight : 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: windows ? null : BorderRadius.circular(12),
            ),
            child: CustomPaint(
              size: const Size.square(10),
              painter: _CaptionGlyphPainter(widget.glyph, ink),
            ),
          ),
        ),
      ),
    );
  }
}

/// The four caption glyphs, one pixel wide and square-ended, on a 10-unit box.
class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter(this.glyph, this.color);

  final _CaptionGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..isAntiAlias = false;
    // Half a unit in, so a one-pixel line lands on a pixel and not across two.
    const o = 0.5;
    final w = size.width - 1;
    final h = size.height - 1;

    switch (glyph) {
      case _CaptionGlyph.minimise:
        canvas.drawLine(Offset(0, h / 2 + o), Offset(w + 1, h / 2 + o), paint);
      case _CaptionGlyph.maximise:
        canvas.drawRect(Rect.fromLTWH(o, o, w, h), paint);
      case _CaptionGlyph.restore:
        // Two squares, the back one showing only its top and right edges.
        canvas.drawRect(Rect.fromLTWH(o, o + 2, w - 2, h - 2), paint);
        canvas.drawPath(
          Path()
            ..moveTo(o + 2, o + 2)
            ..lineTo(o + 2, o)
            ..lineTo(o + w, o)
            ..lineTo(o + w, o + h - 2)
            ..lineTo(o + w - 2, o + h - 2),
          paint,
        );
      case _CaptionGlyph.close:
        paint.isAntiAlias = true;
        canvas.drawLine(
          const Offset(0, 0),
          Offset(size.width, size.height),
          paint,
        );
        canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}

class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        'ddIRC',
        style: TextStyle(color: t.faint, fontSize: 11.5, letterSpacing: 0.3),
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
