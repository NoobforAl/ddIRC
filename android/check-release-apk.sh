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
#   - the plugin's getAll has exactly the descriptor the Dart side asks for. That
#     descriptor is read from the locked plugin's own bindings
#     (lib/src/messages.g.jni.dart, found through .dart_tool/package_config.json)
#     and not written down here, because the plugin changes it: 2.5.4 took a
#     List, 2.5.5 took a byte array, and a guard that hard-coded the first failed
#     a release whose APK was fine. It names kotlin.coroutines.Continuation, so
#     if R8 renames that class the descriptor stops matching and the app reads
#     no preferences at all.
#
# If the bindings cannot be found or read, this FAILS rather than falling back to
# a weaker check: a guard that quietly passes is worse than none. Set
# SHARED_PREFERENCES_JNI_BINDINGS to a bindings file to use that one instead.
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

# What the Dart side asks for: the descriptor in the locked plugin's bindings.
root=$(cd "$(dirname "$0")/.." && pwd)
bindings=${SHARED_PREFERENCES_JNI_BINDINGS:-}
if [ -z "$bindings" ]; then
  # No jq on a stock runner or in Git Bash, so sed. rootUri is a file URI:
  # file:///home/... on Linux, file:///C:/... on Windows.
  uri=$(sed -n '/"name": *"shared_preferences_android"/,/"rootUri"/{s/.*"rootUri": *"\([^"]*\)".*/\1/p}' \
    "$root/.dart_tool/package_config.json" 2>/dev/null || true)
  path=${uri#file://}
  case "$path" in /[A-Za-z]:*) path=${path#/} ;; esac
  path=${path//%20/ }
  [ -n "$uri" ] && bindings="$path/lib/src/messages.g.jni.dart"
fi
if [ -z "$bindings" ] || [ ! -f "$bindings" ]; then
  echo "FAIL: cannot find the shared_preferences_android bindings (looked for: ${bindings:-none}); run 'flutter pub get', or set SHARED_PREFERENCES_JNI_BINDINGS" >&2
  failed=1
else
  # `..._id_getAll = SharedPreferencesApiRegistrar._class.instanceMethodId(` then
  # the name, then the descriptor: three lines. The async registrar is a
  # different class name and is not matched.
  want=$(grep -A2 '_id_getAll = SharedPreferencesApiRegistrar\._class\.instanceMethodId' "$bindings" \
    | sed -n '3p' | sed -E "s/^ *r'(.*)',? *\$/\1/" || true)
  cat > "$work/getall.awk" <<'AWK'
/Class descriptor/ { inside = ($0 ~ /sharedpreferences\/SharedPreferencesApiRegistrar;/) }
inside && /name +: .getAll./ { want = 1; next }
want && /type +:/ { sub(/^[^\047]*\047/, ""); sub(/\047.*$/, ""); print; want = 0 }
AWK
  have=$(awk -f "$work/getall.awk" "$work/dump.txt" || true)
  if [ -z "$want" ]; then
    echo "FAIL: could not read the getAll descriptor from $bindings; the bindings changed shape and this check has to be updated" >&2
    failed=1
  elif ! printf '%s\n' "$have" | grep -Fxq -- "$want"; then
    echo "FAIL: SharedPreferencesApiRegistrar.getAll in the APK does not have the descriptor the Dart bindings look up" >&2
    echo "  the bindings ask for: $want" >&2
    echo "  the APK has:          ${have:-no getAll at all}" >&2
    failed=1
  fi
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
