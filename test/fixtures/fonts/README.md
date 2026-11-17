# Test fonts

`Roboto-Regular.ttf` is Roboto, copied unmodified from the Flutter SDK's
`bin/cache/artifacts/material_fonts/`, under the Apache License 2.0 (the full text
is `LICENSE-Roboto.txt` beside it).

It is used by `test/ui/settings/settings_header_test.dart` and by nothing that is
built into the app: nothing under `test/` is bundled. `flutter test` draws every
glyph as a full square unless a real font is loaded, so a test that asks whether a
line of text *fits* needs one. Roboto is what an Android phone draws these in.

It is a file here and not read from the SDK because the SDK only has it when a
Flutter build has already fetched it: a Windows machine that has built the app does,
and a clean Linux CI runner does not.
