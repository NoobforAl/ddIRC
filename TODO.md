# TODO

- ✅ Add a light theme.
- ✅ Add tests for the Rust core.
- ✅ Add a dev IRC server with Docker Compose, for tests.
- ✅ Add GitHub CI to run the lint checks.
- ✅ Add the test suite to CI.
- ✅ Add app settings to the home page.
- ✅ Add animations for every action in the app.
  (Member *departures* are still instant — animating one means holding a
  row the model no longer has, which is a much bigger change than it looks.)
- ✅ Make the layout responsive.
- ✅ Create an app icon.
- ✅ Add build configuration for the other platforms: Linux, macOS and iOS.
  (Scaffolded and configured; none of the three has been built yet - no host.)
- ✅ Give the core a reconnect command, so "Retry now" can wake the backoff
  instead of tearing the connection down and losing the scrollback.
- ✅ Let the app reach the dev server without trusting its certificate
  machine-wide. (DDIRC_DEV_CA, debug builds only — it *adds* a root rather
  than skipping verification, and is compiled out of release. See dev/README.md.)
