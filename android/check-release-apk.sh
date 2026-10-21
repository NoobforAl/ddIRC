#!/usr/bin/env bash
# Checks a release APK for what R8 must not have done to it.
#
# Some code is reached by name rather than by a call the compiler can see - the
# shared_preferences plugin is called from Dart through JNI, which looks each
# Kotlin method up by its name and descriptor. R8 renames and removes what
# nothing visible refers to, so a release build can lose a class that a debug or
# profile build of the same code still has, and the app fails at run time on a
# phone, not at build time. android/app/proguard-rules.pro keeps what has to
# keep its name; this proves it did.
#
# Two things are checked in the finished APK:
#   - the Kotlin classes the JNI bindings name are all there under their names;
#   - the plugin's getAll still has the descriptor the Dart side asks for, which
#     names kotlin.coroutines.Continuation. (If R8 renames Continuation the
#     descriptor no longer matches and the app reads no preferences at all.)
#
# This is a floor, not a proof: it names what has broken before. The proof is a
# release build on a phone that comes up with its saved networks and no
# "unavailable" lines in `adb logcat -s flutter`.
#
# usage: android/check-release-apk.sh path/to/release.apk
set -euo pipefail

apk=${1:?usage: android/check-release-apk.sh path/to/release.apk}
[ -f "$apk" ] || { echo "no such file: $apk" >&2; exit 2; }

sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
dexdump=$(ls "$sdk"/build-tools/*/dexdump* 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$dexdump" ]; then
  echo "dexdump not found under \$ANDROID_HOME/build-tools (is the Android SDK installed?)" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unzip -q -o "$apk" 'classes*.dex' -d "$work"
for dex in "$work"/classes*.dex; do
  "$dexdump" "$dex" >> "$work/dump.txt"
done

failed=0

# Looked up by name: Class.forName in the bindings, and the descriptors.
for class in \
  io/flutter/plugins/sharedpreferences/SharedPreferencesApiRegistrar \
  kotlin/coroutines/Continuation \
  kotlin/coroutines/intrinsics/CoroutineSingletons \
  kotlin/coroutines/intrinsics/IntrinsicsKt \
  kotlin/Unit \
  kotlin/Result \
  'kotlin/Result$Failure'; do
  if ! grep -qF "Class descriptor  : 'L${class};'" "$work/dump.txt"; then
    echo "FAIL: class ${class//\//.} is not in the APK under its own name" >&2
    failed=1
  fi
done

if ! awk '
    /Class descriptor/ { inside = ($0 ~ /sharedpreferences\/SharedPreferencesApiRegistrar;/) }
    inside && /name +: .getAll./ { want = 1; next }
    want && /type +:/ {
      if ($0 ~ /Ljava\/util\/List;Lkotlin\/coroutines\/Continuation;\)/) found = 1
      want = 0
    }
    END { exit !found }' "$work/dump.txt"; then
  echo "FAIL: SharedPreferencesApiRegistrar.getAll no longer has the descriptor the Dart bindings look up" >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  cat >&2 <<'EOF'

A release built like this cannot read its own preferences: it starts with no
saved networks, default settings, the app lock and built-in Tor off, and the
first-run screen showing. R8 has renamed or removed a class the shared_preferences
plugin is looked up by. See android/app/proguard-rules.pro: the classes a
JNI-bound binding names have to be kept.
EOF
  exit 1
fi
echo "ok: the classes and descriptors the preferences plugin is looked up by are intact"
