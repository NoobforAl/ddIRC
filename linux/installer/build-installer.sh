#!/usr/bin/env bash
#
# Build the self-extracting Linux installer: install.sh.in, then the release
# bundle as a compressed archive.
#
#   linux/installer/build-installer.sh <bundle-dir> <version> <icon.png> <out-dir>
#
# `make installer-linux` calls it. A script rather than a few lines of Makefile
# because it has a checksum to compute and a marker to place, and because the
# smoke test builds one from a fake bundle to prove the installer works without
# a Flutter build.
set -euo pipefail

bundle="${1:?usage: build-installer.sh <bundle-dir> <version> <icon.png> <out-dir>}"
version="${2:?version}"
icon="${3:?icon}"
out="${4:?out-dir}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -x "$bundle/ddirc" ] || { echo "no executable $bundle/ddirc: build the release bundle first" >&2; exit 1; }
[ -f "$icon" ] || { echo "no icon at $icon" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The application plus the icon the menu entry will use, owned by nobody in
# particular and in a stable order, so the same build gives the same bytes.
stage="$work/stage"
mkdir -p "$stage"
cp -a "$bundle/." "$stage/"
cp "$icon" "$stage/ddirc.png"
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$stage" -cf - . | gzip -9n > "$work/payload.tar.gz"

sum="$(sha256sum "$work/payload.tar.gz" | cut -d' ' -f1)"
mkdir -p "$out"
file="$out/ddIRC-$version-linux-x64-installer.sh"
sed -e "s/@VERSION@/$version/" -e "s/@PAYLOAD_SHA256@/$sum/" "$here/install.sh.in" > "$file"
cat "$work/payload.tar.gz" >> "$file"
chmod 755 "$file"
echo "-> $file ($(du -h "$file" | cut -f1))"
