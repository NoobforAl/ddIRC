#!/usr/bin/env bash
#
# Refuse a release whose tag and manifest disagree about the version.
#
# There are three places a version lives, and only two of them are checked
# anywhere else. `test/version_test.dart` keeps `pubspec.yaml` and
# `lib/src/version.dart` in step, because neither can read the other at
# runtime. Nothing keeps the *tag* in step with either — and the tag is what
# the release workflow passes to `--build-name`, so a tag nobody bumped the
# manifest for ships an APK whose Android versionName says one thing and whose
# own settings screen says another. The tag only exists at release time, which
# is why this check lives here and not in the test suite.
#
# Only the leading MAJOR.MINOR.PATCH has to match. The tags this project has
# used carry a pre-release or build suffix the manifest does not — `v0.1.0-beta.1`,
# `v0.2.0+beta` — and that is a labelling choice about the release, not a
# disagreement about which version it is.
#
# A script rather than an inline `run:` block so both jobs invoke one copy, and
# so it can be run by hand before tagging:
#
#     GITHUB_REF_NAME=v0.3.0 .github/tag-matches-manifest.sh
set -euo pipefail

tag="${GITHUB_REF_NAME:?no tag: set GITHUB_REF_NAME}"
version="${tag#v}"
# Everything before the first '-' or '+', so a suffix is allowed but ignored.
core="${version%%[-+]*}"

manifest="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)"
manifest="${manifest%%+*}"

if [ "$core" != "$manifest" ]; then
    echo "Tag '$tag' is version '$core'; pubspec.yaml says '$manifest'." >&2
    echo "Bump pubspec.yaml and lib/src/version.dart, or retag." >&2
    exit 1
fi

echo "Tag '$tag' agrees with the manifest ($manifest)."
