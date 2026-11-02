# `lib/` — the Flutter app

Read [`../CLAUDE.md`](../CLAUDE.md) first for the `make` commands, which apply here
unchanged. This file is only about the Dart side. For the Rust side see
[`../core/CLAUDE.md`](../core/CLAUDE.md).

The app is Android-first and also builds for Windows, Linux, macOS and iOS. It does
**no protocol work of its own**: it asks the Rust core to connect, send and store,
and draws what comes back.

## Layout

```
lib/
├─ main.dart            startup, then the workspace
└─ src/
   ├─ model/            state and logic, no widgets — start here to understand behaviour
   ├─ ui/               widgets, one concern per file; ui/settings/ for the settings dialogs
   ├─ text/markdown.dart
   ├─ theme.dart        colour tokens (`Tokens`)
   ├─ version.dart
   └─ rust/             GENERATED bindings to core/ddirc-bridge — never edit
test/                   Flutter tests, one *_test.dart per feature (root of the repo, not here)
tool/make_icons.dart    `make icons` — redraws launcher icons from ui/mark_spec.dart
```

- **`model/`** holds what the app *knows*: `session.dart` (a live connection and its
  conversations), `workspace.dart` (all of them), `chat_state.dart` (a user's own
  per-conversation state: drafts, read position, pins), `history.dart` (the optional
  message database), `secrets.dart`, `settings.dart`, `proxy.dart`, `tor.dart`,
  `mcp.dart` (the local MCP server agents can drive the app through). Widgets read
  these; they do not duplicate their logic.
- **`ui/`** holds what the app *shows*. Sizes, motion and colour come from three
  token sets: `Tokens` (colour, `theme.dart`), `Motion` (time, `ui/motion.dart`) and
  the layout tokens (`ui/layout.dart`, read as `context.layout`). Ask a token a
  question (`layout.channelsPinned`) instead of comparing a pixel width in a widget.
- **Platform splits** are paired files: `notifier.dart` with `notifier_android.dart`
  and `notifier_desktop.dart`, the same for `background*`. Put platform code in the
  specific file and keep the shared one platform-free.

## Rules for this side

- **Never edit `lib/src/rust/**`.** Change the Rust API in `core/ddirc-bridge/src/api/`
  and run `make codegen`. The folder is excluded from analysis (it is machine output
  and would trip the stricter rules by the thousand) but is still format-checked, so
  commit it as the generator wrote it.
- **Credentials go through `model/secrets.dart` and nowhere else.** Do not construct
  a second `FlutterSecureStorage`; its options are per instance and the defaults are
  wrong for this app. Never log, persist in preferences or put a secret in a URL.
- **The analyzer is strict** (`analysis_options.yaml`): `strict-casts`,
  `strict-inference`, `strict-raw-types`, plus rules such as `unawaited_futures`,
  `avoid_dynamic_calls` and `prefer_const_constructors`. Practical consequences:
  - a Future you deliberately do not wait for is wrapped in `unawaited(...)`
    (`import 'dart:async' show unawaited;`), otherwise `await` it;
  - give generics explicitly where inference fails (`_invoke<void>('stop')`);
  - cast `dynamic` (such as a `MethodCall.arguments`) to a real type before use;
  - `make fix` runs `dart fix` and `dart format` for the mechanical ones.
- **Mind both protocols.** IRC and XMPP share one event type and one command type.
  A name, a message's text or an identity is not always IRC-shaped (a JID is not a
  nick); the tests named `xmpp_*_test.dart` show where that assumption bit before.
- **Respect reduced motion and large text.** Animations go through `Motion` so they
  stop under reduced motion; layouts are tested at 2.0× text and right-to-left
  (`xmpp_layout_test.dart`, `layout_test.dart`). A new screen should survive both.

## Testing

`make test` runs everything here; add a test next to the behaviour in `test/`, named
`<thing>_test.dart`.

- **The Rust core is faked, not run.** Tests install a fake with
  `RustLib.initMock(api: _FakeCore())` (a class that `implements RustLibApi`) and
  `RustLib.dispose` in teardown. Copy the pattern from `test/xmpp_contacts_test.dart`
  rather than inventing another. Real end-to-end behaviour belongs in the Rust
  integration suites.
- Widget tests use `tester.pump` with explicit durations; a test that needs real time
  is usually a design problem.
- `flutter test` also fails if the committed launcher icons are stale relative to
  `mark_spec.dart` — the fix is `make icons`, not editing the test.
- Check a UI change on a device or emulator when it is about gesture, scrolling, the
  keyboard or system bars: widget tests do not model those. Android builds go through
  `make build-android`; see [`../docs/building.md`](../docs/building.md).

## Documents for this area

[`../docs/features.md`](../docs/features.md) (what each feature should do),
[`../docs/privacy.md`](../docs/privacy.md) and [`../SECURITY.md`](../SECURITY.md)
(what must not leak), [`../docs/architecture.md`](../docs/architecture.md) (how the
two halves meet).
