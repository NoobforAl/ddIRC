#!/usr/bin/env bash
#
# Prove the installer installs, upgrades and uninstalls, in a throwaway home.
#
#   linux/installer/smoke-test.sh [installer.sh]
#
# With no argument it builds an installer around a fake application, so it runs
# anywhere with bash and tar and tells you about the *installer* - which is the
# part nothing else tests. With a path it tests that file, which is what CI does
# with the real one after building it.
#
# Never touches the real home: HOME and the prefix are a temp directory.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"

# Run on something that is not a Linux x86_64 machine (a maintainer's laptop),
# the installer would rightly refuse. A stand-in for `uname` lets the checks that
# are about the installer's own logic run anyway; CI runs them on the real thing.
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
  mkdir -p "$work/fakebin"
  printf '#!/bin/sh
case "$1" in -s) echo Linux;; -m) echo x86_64;; *) echo Linux;; esac
' > "$work/fakebin/uname"
  chmod 755 "$work/fakebin/uname"
  export PATH="$work/fakebin:$PATH"
  echo "note: not Linux x86_64 here; using a stand-in uname"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

if [ $# -ge 1 ]; then
  installer="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
else
  mkdir -p "$work/bundle/lib" "$work/bundle/data"
  printf '#!/bin/sh\necho "fake ddirc"\n' > "$work/bundle/ddirc"
  chmod 755 "$work/bundle/ddirc"
  echo lib > "$work/bundle/lib/libx.so"
  echo data > "$work/bundle/data/asset"
  printf 'PNG' > "$work/icon.png"
  "$here/build-installer.sh" "$work/bundle" 9.9.9 "$work/icon.png" "$work/out" > /dev/null
  installer="$work/out/ddIRC-9.9.9-linux-x64-installer.sh"
fi
[ -f "$installer" ] || fail "no installer at $installer"

prefix="$HOME/.local"
app="$prefix/share/ddirc"
desktop="$prefix/share/applications/dev.ddirc.ddirc.desktop"
icon="$prefix/share/icons/hicolor/512x512/apps/dev.ddirc.ddirc.png"

# --- it refuses to be root -------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  if sh "$installer" >/dev/null 2>&1; then fail "installed as root"; fi
  ok "refuses to run as root"
  echo "(the remaining checks need a normal user)"
  exit 0
fi

# --- install ---------------------------------------------------------------
sh "$installer" > "$work/install.log" || { cat "$work/install.log"; fail "install failed"; }
[ -x "$app/ddirc" ] || fail "program not installed"
[ -L "$prefix/bin/ddirc" ] || fail "no link in bin"
[ "$(readlink "$prefix/bin/ddirc")" = "$app/ddirc" ] || fail "link points elsewhere"
[ -f "$desktop" ] || fail "no menu entry"
grep -q "^Exec=\"$app/ddirc\"" "$desktop" || fail "menu entry does not run the installed program"
[ -f "$icon" ] || fail "no icon"
[ -x "$app/uninstall.sh" ] || fail "no uninstaller"
ok "installs into the user's own home"

# Everything it created is under the prefix.
outside="$(find "$HOME" -mindepth 1 \( -type f -o -type l \) -not -path "$prefix/*" || true)"
[ -z "$outside" ] || fail "wrote outside the prefix: $outside"
ok "writes nothing outside the prefix"

# --- upgrade keeps working ---------------------------------------------------
echo stale > "$app/leftover"
sh "$installer" > /dev/null || fail "upgrade failed"
[ ! -e "$app/leftover" ] || fail "upgrade left the old version's files"
[ -z "$(ls -A "$prefix/share" | grep -E 'old\.|ddirc-install' || true)" ] || fail "upgrade left a backup or temp directory behind"
[ -x "$app/ddirc" ] || fail "upgrade lost the program"
ok "upgrades in place"

# --- user data is never touched ----------------------------------------------
mkdir -p "$HOME/.config/ddirc"
echo mine > "$HOME/.config/ddirc/settings"
"$prefix/bin/ddirc-uninstall" > /dev/null || fail "uninstall failed"
[ ! -e "$app" ] || fail "program still there"
[ ! -e "$prefix/bin/ddirc" ] || fail "link still there"
[ ! -e "$desktop" ] || fail "menu entry still there"
[ ! -e "$icon" ] || fail "icon still there"
[ "$(cat "$HOME/.config/ddirc/settings")" = mine ] || fail "uninstall touched the user's settings"
ok "uninstalls cleanly and leaves settings alone"

# --- the installer can uninstall too, and is idempotent ----------------------
sh "$installer" > /dev/null
sh "$installer" --uninstall > /dev/null || fail "--uninstall failed"
[ ! -e "$app" ] || fail "--uninstall left the program"
sh "$installer" --uninstall > /dev/null || fail "--uninstall twice failed"
ok "--uninstall works, twice"

# --- a link that is not ours is not removed ----------------------------------
mkdir -p "$prefix/bin"
ln -s /bin/true "$prefix/bin/ddirc"
sh "$installer" --uninstall > /dev/null
[ -L "$prefix/bin/ddirc" ] || fail "removed somebody else's link"
rm -f "$prefix/bin/ddirc"
ok "leaves a same-named link that is not its own"

# --- a damaged file is refused ------------------------------------------------
cp "$installer" "$work/damaged.sh"
printf 'x' >> "$work/damaged.sh"
if sh "$work/damaged.sh" > /dev/null 2>&1; then fail "installed a damaged file"; fi
[ ! -e "$app" ] || fail "a damaged file left something installed"
ok "refuses a damaged download"

# --- a prefix that could break out of its quotes is refused --------------------
if sh "$installer" --prefix "$work/it's" > /dev/null 2>&1; then fail "accepted a quote in the prefix"; fi
ok "refuses a prefix with a quote in it"

# --- a different prefix ---------------------------------------------------------
sh "$installer" --prefix "$work/elsewhere" > /dev/null || fail "custom prefix failed"
[ -x "$work/elsewhere/share/ddirc/ddirc" ] || fail "custom prefix not used"
"$work/elsewhere/bin/ddirc-uninstall" > /dev/null
ok "honours --prefix"

echo "all installer checks passed"
