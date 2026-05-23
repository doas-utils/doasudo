#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# metadata-utils.sh: helpers to emit file installation metadata.

set -eu

_pick_sha_tool() {
  _SHA_TOOL=
  _SHA_KIND=
  _SHA_FLAG=
  _pst=$(command -v sha256sum 2>/dev/null || true)
  [ -n "$_pst" ] && { _SHA_TOOL=$_pst; _SHA_KIND=sha256sum; return 0; }
  _pst=$(command -v sha256 2>/dev/null || true)
  [ -n "$_pst" ] && { _SHA_TOOL=$_pst; _SHA_KIND=sha256; return 0; }
  _pst=$(command -v shasum 2>/dev/null || true)
  [ -n "$_pst" ] && { _SHA_TOOL=$_pst; _SHA_KIND=shasum; _SHA_FLAG='-a 256'; return 0; }
  return 1
}

# Resolves SHA-256 tool once, then exposes a deterministic name in <dir>.
# Used by build/test paths that need a stable executable path.
_setup_sha_tool() {
  _dst_dir=${1:?"usage: _setup_sha_tool <dir> [error-message]"}
  _msg=${2:-'no SHA-256 checksum tool found'}
  _pick_sha_tool || { printf 'error: %s\n' "$_msg" >&2; return 1; }
  _wrapper="${_dst_dir}/${_SHA_KIND}"
  # Wrapper (not symlink): macOS Perl shasum returns empty when invoked via
  # a symlink; same binary works fine directly.
  printf '#!/bin/sh\nexec %s %s "$@"\n' "$_SHA_TOOL" "$_SHA_FLAG" > "$_wrapper" \
    && chmod +x "$_wrapper" \
    || return 1
  printf '%s\n' "$_wrapper"
}

# uid:gid:mode for $1 using the same GNU/BSD stat(1) probe as lib/shim-utils.sh.
_stat_live_ugm() {
  if stat -c '%u' "$1" >/dev/null 2>&1; then
    stat -c '%u:%g:%a' "$1" 2>/dev/null
    return
  fi
  if stat -f '%u' "$1" >/dev/null 2>&1; then
    stat -f '%u:%g:%Lp' "$1" 2>/dev/null
    return
  fi
  return 1
}

# Emits "<sha256>:<uid>:<gid>:<mode>" for regular files. By default, the mode is
# set to 0:0 (root-owned install expectation). If caller passes 'stat-ug' as
# third argument, the UID, GID, and mode are derived from stat(1) and the second
# argument is ignored (useful for tests/harnesses that bake live file metadata).
_compute_metadata() {
  _f=$1
  _mode=$2
  _third=${3:-}

  case "$_third" in
    '') ;;
    stat-ug) ;;
    *) printf 'error: unknown third argument %s (expected stat-ug or omit)\n' "$_third" >&2; return 1 ;;
  esac
  case "$_mode" in
    *[!0-7]*) printf 'error: mode must be octal digits: %s\n' "$_mode" >&2; return 1 ;;
  esac
  [ -n "$_mode" ] || { printf 'error: empty mode\n' >&2; return 1; }
  [ -f "$_f" ] || { printf 'error: not a file: %s\n' "$_f" >&2; return 1; }

  _pick_sha_tool || { printf 'error: could not hash %s\n' "$_f" >&2; return 1; }

  _sha=
  # shellcheck disable=SC2086
  case "$_SHA_KIND" in
    sha256sum) _sha=$("$_SHA_TOOL" $_SHA_FLAG <"$_f" 2>/dev/null | awk 'NR==1{print $1}') ;;
    sha256) _sha=$("$_SHA_TOOL" $_SHA_FLAG <"$_f" 2>/dev/null | awk 'NR==1{print $NF}') ;;
    shasum) _sha=$("$_SHA_TOOL" $_SHA_FLAG <"$_f" 2>/dev/null | awk 'NR==1{print $1}') ;;
  esac
  [ -n "$_sha" ] || { printf 'error: could not hash %s\n' "$_f" >&2; return 1; }

  if [ "$_third" = stat-ug ]; then
    _live=$(_stat_live_ugm "$_f") || {
      printf 'error: could not stat uid:gid:mode for %s\n' "$_f" >&2
      return 1
    }
    printf '%s:%s\n' "$_sha" "$_live"
  else
    printf '%s:0:0:%s\n' "$_sha" "$_mode"
  fi
}
