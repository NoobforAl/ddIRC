# Building and installing

Requires Rust 1.82+. The Android targets are only needed for an Android build.

```bash
cd irc-core
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo audit
```

## Running the CLI harness

Secrets are read from the environment, never from argv — command lines are
visible to other processes and land in shell history.

```bash
export DDIRC_SASL_PASSWORD='...'
cargo run -p ddirc-cli -- \
  --server irc.libera.chat --nick yournick \
  --sasl-account youraccount --channel '#test'
```

Once connected: `/join #channel`, `/part [reason]`, `/nick <new>`, `/me <action>`,
`/msg <target> <text>`, `/quit`. Anything else is sent to the current channel.

## Building the Android app

**The minimum is Android 10, API 29.** It is pinned in
`android/app/build.gradle.kts` rather than inherited from whatever the installed
Flutter happens to default to, and set to the same number in
`rust_builder/android/build.gradle` for the native library — cargokit reads that
one to pick the NDK API level, so the two have to agree or the halves are built
for different platforms. The reason for 29 is written next to it:
`android:foregroundServiceType`, which `ConnectionService` declares and which
staying connected in the background rests on, does not exist before it, and TLS
1.3 is on by default from Android 10. Raising it again wants a reason in the
same place.

Flutter is not on `PATH` here; use `C:\Users\noobf\flutter` (3.47.5 stable).
`C:\src\flutter` exists but has never been initialised — ignore it.

One-time setup:

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk flutter_rust_bridge_codegen cargo-expand
flutter pub get
```

`cargo-expand` and the Dart `freezed` package are both required by codegen — our
event type is an enum carrying data, which becomes a sealed class in Dart.

```bash
export ANDROID_NDK_HOME="$LOCALAPPDATA/Android/Sdk/ndk/27.0.12077973"
export PATH="$HOME/flutter/bin:$PATH"   # codegen shells out to `flutter`
flutter_rust_bridge_codegen generate    # after changing irc-core/ddirc-bridge/src/api/**
make build-android                      # or build-android-release for the shipped one
```

Cargokit compiles the Rust automatically as part of the Flutter build; there is
no separate `cargo ndk` step. Generated Dart under `lib/src/rust/` is committed
so CI does not need the codegen toolchain.

The APK *is* Android's installer, so there is no packaging step here the way
Windows has one — but `make build-android-release` currently signs with the
**debug key**, which is what `android/app/build.gradle.kts` still names as its
release signing config. Fine for a beta somebody sideloads; not fine for a
store, and not fine for upgrading across a later key change.

## Building the Windows app

Needs Visual Studio with the C++ desktop workload (2026 18.9.1 works here).

```bash
flutter build windows --debug     # → build/windows/x64/runner/Debug/ddirc.exe
flutter run -d windows
```

### The installer

A zip of a build directory is not a way to give someone an application, so
`make installer` wraps the release build in one `.exe`. It needs
[Inno Setup](https://jrsoftware.org/isdl.php) 6.3 or newer — the only tool in
this project that is needed to *ship* rather than to build — and the script it
compiles is `windows/installer/ddirc.iss`.

```bash
make installer                      # → build/installer/ddIRC-<version>-windows-x64-setup.exe
make installer ISCC=/path/to/ISCC.exe
```

It installs **for the person running it**, into `%LOCALAPPDATA%\Programs\ddIRC`,
and never asks for administrator rights. That is deliberate and not a
convenience: nothing ddIRC does needs them, and an installer that asks for
elevation is asking to be trusted with the whole machine in order to put a chat
client on it. There is no "for all users" option to pick by accident — the
script forbids it — so there is no UAC prompt on any path through it.

Uninstalling removes the program and leaves `%APPDATA%\ddIRC` alone, so saved
networks, settings and logs survive a reinstall. Deleting them is a thing to
decide about, not something an uninstaller should do quietly.

Still open: the installer is unsigned, which means SmartScreen warns the first
person to run each release until enough of them have run it anyway. That is
worth deciding about before a release rather than after someone is frightened by
it.

## Building for Linux, macOS and iOS

Scaffolded, configured, and **not yet built by anyone** — every one of them
needs a host we do not have. They are here so that the first person with a Mac
or a Linux box starts from a project that is already wired up rather than from
`flutter create`, and so that the things which are easy to get wrong are
already right. Expect to fix something; do not expect to start from scratch.

```bash
make build-linux    # on Linux:  needs GTK 3, ninja, clang, pkg-config
make build-macos    # on macOS:  needs Xcode
make build-ios      # on macOS:  builds unsigned, for a simulator or a device
```

The Rust side needs nothing new: `rust_builder` (the `ddirc_bridge` plugin)
already ships cargokit glue for all five platforms, so the core is compiled by
the Flutter build exactly as it is on Windows and Android. On macOS and iOS you
will want `rustup target add` for the architectures you are building for.

What was set beyond the template:

| | |
|---|---|
| **macOS** | `com.apple.security.network.client` in **both** entitlement files. This is the one that matters: under the App Sandbox an outgoing connection is refused without it, and it surfaces as a TLS error rather than as a permissions one, so it costs an afternoon to find |
| **iOS** | Display name, and icons with no alpha channel — an iOS icon with one is rejected on upload |
| **Linux** | No `GtkHeaderBar`. The app draws its own title strip on every desktop, and a header bar is a *client-side* titlebar that survives undecorating on some window managers, leaving two of them. Default window size matches what `prepareWindow` asks for |
| all three | The mark, generated into each platform's icon format by `make icons` |

Bundle identifier is `dev.ddirc.ddirc` throughout, matching Android. There is no
signing configuration and no CI job for these — CI has no macOS runner, and a
Linux job would be the only one of the three it could ever run.

## Picking a network to test against

Libera.Chat is the default, but it rejects connections from many VPN exit IPs
via DroneBL — you get a clear "banned from this server" line and a backoff
retry, which is the client behaving correctly, not a bug. If that happens,
`irc.snoonet.org` accepts a wider range of addresses.

Avoid the bare `irc.dal.net` round-robin: some of its servers run **plaintext**
on 6697, so the TLS handshake fails with a frame error. Use a specific host such
as `twisted.dal.net` instead.
