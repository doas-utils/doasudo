#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doas-sudo-shim.
#
# Verifies the auto-update process for stale shim metadata. Integration suites
# rebuild lib/shim-utils.sh (e.g., to mock SHIM_PATH) without rebuilding the
# main doas-sudo-shim binary. This script asserts that a forced rebuild
# (`make -B`) correctly synchronizes the embedded _SHIM_UTILS_METADATA hash.

set -eu

_root=$(CDPATH="" cd -P -- "$(dirname -- "$0")/.." && pwd)
cd "$_root"
MAKE=${MAKE:-make}
# shellcheck source=tests/testlib.sh disable=SC1091
. "$_root/tests/testlib.sh"

fail() {
  printf 'FAIL stale-metadata_test: %s\n' "$1" >&2
  exit 1
}

# shellcheck disable=SC1091
. "$_root/utils/metadata-utils.sh"
_pick_sha_tool || fail 'no sha256sum / sha256 / shasum'

_meta_from_shim() {
  sed -n "s/^_SHIM_UTILS_METADATA='\\([^']*\\)'$/\\1/p" "$_root/doas-sudo-shim" | head -n1
}

# Prior tests leave lib/shim-utils.sh newer than .in but still mock-embedded; without
# -B, make skips lib regen and want_rel would be mock digest while repair restores release.
# shellcheck disable=SC2046
"$MAKE" $(_make_s) -B lib/shim-utils.sh doas-sudo-shim \
  || fail 'release lib/shim build failed'
[ -f "$_root/doas-sudo-shim" ] || fail 'doas-sudo-shim missing'

want_rel=$(_compute_metadata "$_root/lib/shim-utils.sh" 644) \
  || fail '_compute_metadata release failed'
got=$(_meta_from_shim)
[ -n "$got" ] || fail 'empty _SHIM_UTILS_METADATA in shim'
[ "$got" = "$want_rel" ] || fail "release pair mismatch (got=$got want=$want_rel)"

_mroot=$(mktemp -d "${TMPDIR:-/tmp}/shim-stale-meta.XXXXXX") || fail 'mktemp failed'
mkdir -p "$_mroot/mockbin" || fail 'mkdir mockbin failed'

_cleanup() {
  rm -rf "$_mroot"
}
trap _cleanup EXIT

# Same pattern as doas-flags-parity / parser / edit-mode: rm forces regen; Makefile
# does not list SHIM_PATH as a prerequisite, so plain `make` would skip rewrite.
rm -f "$_root/lib/shim-utils.sh"
# shellcheck disable=SC2046
"$MAKE" $(_make_s) lib/shim-utils.sh \
  "SHIM_PATH=${_mroot}/mockbin:/usr/bin:/bin:/usr/sbin:/sbin" \
  || fail 'mock lib/shim-utils.sh rebuild failed'

want_mock=$(_compute_metadata "$_root/lib/shim-utils.sh" 644) \
  || fail '_compute_metadata mock failed'
[ "$want_mock" != "$want_rel" ] \
  || fail 'mock SHIM_PATH did not change lib/shim-utils.sh digest (unexpected)'

got=$(_meta_from_shim)
[ "$got" = "$want_rel" ] \
  || fail "binary bake changed without rebuild (got=$got want_rel=$want_rel)"
[ "$got" != "$want_mock" ] \
  || fail 'REGRESSION: shim bake already matches mocked lib (stale class not observable; check test assumptions)'

# shellcheck disable=SC2046
"$MAKE" $(_make_s) -B lib/shim-utils.sh doas-sudo-shim || fail 'repair make failed'

want_fin=$(_compute_metadata "$_root/lib/shim-utils.sh" 644) \
  || fail '_compute_metadata after repair failed'
got=$(_meta_from_shim)
[ "$got" = "$want_fin" ] || fail "after repair, bake still wrong (got=$got want=$want_fin)"
[ "$got" = "$want_rel" ] \
  || fail "repair did not restore release metadata (got=$got want_rel=$want_rel)"

rm -f doas-sudo-shim

printf '\nPASS stale-metadata_test\n\n'
