#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Validates that the execution path (`_doas_exec`) and the write-back path
# (`_doas`) emit identical `doas` flags across all valid option combinations.
#
# The harness executes a mocked `doas` that records arguments up to the first
# `--` boundary and exits. To test the edit path, a mocked editor mutates the
# target file, forcing the shim to trigger the elevated write-back call.
#
# Coverage:
# - Execution (`_doas_exec`): Validates flag propagation for commands.
# - Write-back (`_doas`): Validates flag propagation for file edits.
# - Parity: Asserts both paths produce identical flags for identical inputs.
#
# Usage:
#   sh doas-flags-parity_test.sh [path/to/doasudo.in]     # source mode (default)
#   sh doas-flags-parity_test.sh --built path/to/doasudo  # built mode
#
# Constraints:
# - Built mode requires a real `doas`; skips fixtures that need compilation.
# - Edit-path assertions require a non-root EUID and an unreadable target file
#   (root execution triggers an early rejection guard before `doas` runs).
#   If these conditions cannot be met, the affected tests SKIP.

set -eu

_pass=0
_fail=0
_skip=0

# ---- Locate source -----------------------------------------------------------------------

_here=$(CDPATH="" cd -P -- "$(dirname "$0")" && pwd)
_repo=$(CDPATH="" cd -P -- "$_here/.." && pwd)

_built=
case "${1:-}" in
  --built)
    [ $# -ge 2 ] || { printf 'error: --built requires a path argument\n' >&2; exit 1; }
    _shim_built="$2"
    _built=1
    ;;
  *)
    _shim_src="${1:-${_repo}/doasudo.in}"
    [ -f "$_shim_src" ] || { printf 'error: shim source not found: %s\n' "$_shim_src" >&2; exit 1; }
    ;;
esac

# shellcheck source=testlib.sh
. "$_here/testlib.sh"
# shellcheck source=../utils/metadata-utils.sh
. "$_repo/utils/metadata-utils.sh"

( [ -f "$_repo/lib/shim-utils.sh" ] && [ -f "$_repo/lib/edit-broker-client.sh" ] ) \
  || (cd "$_repo" && "${MAKE:-make}" $(_make_s) lib/shim-utils.sh lib/edit-broker-client.sh) \
  || {
    printf 'error: run make lib/shim-utils.sh lib/edit-broker-client.sh from %s\n' "$_repo" >&2
    exit 1
  }

# ---- Scratch area ------------------------------------------------------------------------

_setup_mockbin
trap '_rm_tmp' EXIT

_shim="${_tmp}/sudo"
_record="${_mockbin}/last_flags"

# ---- Mock binaries -----------------------------------------------------------------------

# mock doas: flags (argv before first `--`) -> $_record via dirname $0 (not env).
# Survives _doas_exec stripping of `/usr/bin/env -- ...`.
cat > "${_mockbin}/doas" << 'EOF'
#!/bin/sh
_out="$(dirname "$0")/last_flags"
_flags=
for _a in "$@"; do
  [ "$_a" = "--" ] && break
  _flags="${_flags:+${_flags} }${_a}"
done
printf '%s\n' "$_flags" > "$_out"
exit 0
EOF
chmod +x "${_mockbin}/doas"

# mock editor: one byte -> mtime -> write-back -> _doas /bin/sh -c ...
cat > "${_mockbin}/editor" << 'EOF'
#!/bin/sh
printf 'x' >> "$1"
touch "$1"
exit 0
EOF
chmod +x "${_mockbin}/editor"

# mock true: exec-path command target.
cat > "${_mockbin}/true" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${_mockbin}/true"

# Stub broker path + metadata for shim bake (parity test never runs broker IPC).
cat > "${_mockbin}/edit-broker" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "${_mockbin}/edit-broker"

# Symlink real id, awk, stat, cat, tee, mv, chmod, rm, tty (and optional getent).
# Write-back runs, but mock doas exits 0 before /bin/sh -c side effects.
# _sys_path mirrors the non-mock SHIM_PATH tail, so _resolve_bin sees shim-like tools.
_sys_path="/usr/bin:/usr/sbin:/bin:/sbin"
_symlink_required_tools "$_mockbin" "$_sys_path" id awk stat cat tee mv chmod rm tty \
  || exit 1
_symlink_optional_tools "$_mockbin" "$_sys_path" getent

# SHA-256 tool for edit-mode digest init (shim-utils.sh).
_setup_sha_tool "$_mockbin" "no SHA-256 checksum tool found in $_sys_path" >/dev/null \
  || exit 1

MAKE=${MAKE:-make}
rm -f "$_repo/lib/shim-utils.sh"
(cd "$_repo" && "$MAKE" $(_make_s) lib/shim-utils.sh SHIM_PATH="${_mockbin}:${_sys_path}") \
  || { printf 'error: make lib/shim-utils.sh failed\n' >&2; exit 1; }

_utils_meta=$(_compute_metadata "$_repo/lib/shim-utils.sh" 644 stat-ug) \
  || {
    printf 'error: could not compute UTILS_METADATA for lib/shim-utils.sh\n' >&2
    exit 1
  }
_eb_client_meta=$(_compute_metadata "$_repo/lib/edit-broker-client.sh" 644 stat-ug) \
  || {
    printf 'error: could not compute metadata for lib/edit-broker-client.sh\n' >&2
    exit 1
  }
_broker_shim_meta=$(_compute_metadata "${_mockbin}/edit-broker" 755 stat-ug) \
  || {
    printf 'error: could not compute metadata for mock edit-broker\n' >&2
    exit 1
  }

# ---- Build shim --------------------------------------------------------------------------
# sed @BINDIR@ in-tree so each run bakes the current _mockbin.
# Drop the setuid guard (deploy-only); tests do not need root.
if [ -n "$_built" ]; then
  [ -f "$_shim_built" ] || { printf 'error: built shim not found: %s\n' "$_shim_built" >&2; exit 1; }
  cp "$_shim_built" "${_tmp}/sudo"
  chmod +x "${_tmp}/sudo"
  _shim="${_tmp}/sudo"
else
  _version=$(cat "${_here}/VERSION" 2>/dev/null) || _version='unknown'
  _build_test_shim "$_repo" "$_shim_src" "$_shim" "${_mockbin}:${_sys_path}" \
    "$_utils_meta" "$_version" "${_repo}/lib/shim-utils.sh" \
    "${_repo}/lib/edit-broker-client.sh" "$_eb_client_meta" \
    "${_mockbin}/edit-broker" "${_broker_shim_meta}" \
    || exit 1
  chmod +x "$_shim"
fi

# ---- Edit mode target --------------------------------------------------------------------
#
# Unreadable host file forces `_doas cat -- <file>` and avoids writable-/tmp checks.
_editfile=
for _candidate in /etc/shadow /etc/gshadow /etc/doas.conf /opt/local/etc/doas.conf; do
  [ -e "$_candidate" ] && [ ! -r "$_candidate" ] && { _editfile="$_candidate"; break; }
done

_euid=$("${_mockbin}/id" -ru) || {
  printf 'error: %s/id -ru failed\n' "$_mockbin" >&2
  exit 1
}
case "$_euid" in *[!0-9]*)
  printf 'error: id -ru not a decimal uid: %s\n' "$_euid" >&2
  exit 1
  ;;
esac

# Runs edit-side flag assertions only when the shim can reach _doas (not root).
_run_edit_doas_flags=0
if [ -n "$_editfile" ] && [ "$_euid" -ne 0 ]; then
  _run_edit_doas_flags=1
fi

_skip_edit_flags_reason=
if [ "$_run_edit_doas_flags" -ne 1 ]; then
  if [ -z "$_editfile" ]; then
    _skip_edit_flags_reason='no unreadable edit target (e.g. EUID 0 readable paths)'
  else
    _skip_edit_flags_reason='EUID 0 (shim rejects edit mode before any doas call)'
  fi
fi

# ---- Test framework ----------------------------------------------------------------------

_skip_flag_combinations() {
  _sfc_scope="$1"; _sfc_reason="$2"
  _skip_t "[${_sfc_scope}] no flags: ${_sfc_reason}"
  _skip_t "[${_sfc_scope}] -n: ${_sfc_reason}"
  _skip_t "[${_sfc_scope}] -u USER: ${_sfc_reason}"
  _skip_t "[${_sfc_scope}] -n -u USER: ${_sfc_reason}"
}
_for_each_flag_combination() {
  _fefc_cb="$1"
  "$_fefc_cb" "no flags"   ""
  "$_fefc_cb" "-n"         "-n"              -n
  "$_fefc_cb" "-u USER"    "-u ${_user}"     -u "$_user"
  "$_fefc_cb" "-n -u USER" "-n -u ${_user}"  -n -u "$_user"
}

# $1 label; $2 message tag (exec|run); $3 expected flags; remaining: shim argv.
_assert_recorded_flags() {
  _label="$1"; _mode="$2"; _expected="$3"; shift 3
  : > "$_record"
  # Ignore exit (shim may be non-zero if editor missing from PATH; SUDO_EDITOR is absolute).
  _run_capture_streams env SUDO_EDITOR="${_mockbin}/editor" "$_shim" "$@"
  _got=$(cat "$_record")
  if [ "$_got" = "$_expected" ]; then
    _pass_t "[${_mode}] ${_label}: recorded flags"
  else
    _fail_t "[${_mode}] ${_label}: recorded flags" "expected '${_expected}', got '${_got}'"
  fi
}

# ---- Test cases --------------------------------------------------------------------------
# Expected strings match _doas/_doas_exec. Mock omits trailing `--`.

_user=${TEST_USER:-${USER:-$(id -un)}}

_assert_exec_case() {
  _aec_label="$1"; _aec_expected="$2"; shift 2
  _assert_recorded_flags "$_aec_label" exec "$_aec_expected" "$@" "${_mockbin}/true"
}
_assert_run_case() {
  _arc_label="$1"; _arc_expected="$2"; shift 2
  _assert_recorded_flags "$_arc_label" run "$_arc_expected" -e "$@" "$_editfile"
}
printf '\n── _doas_exec path (normal dispatch, exec) ─────────────────────────────────────\n'
_for_each_flag_combination _assert_exec_case

printf '\n── _doas path (edit mode, non-exec) ────────────────────────────────────────────\n'
if [ "$_run_edit_doas_flags" -eq 1 ]; then
  _for_each_flag_combination _assert_run_case
else
  _skip_flag_combinations run "$_skip_edit_flags_reason"
fi

printf '\n── Cross-check: _doas == _doas_exec for each combination ───────────────────────\n'

# Compares exec vs edit records directly; catches drift even if literals above stale.
_assert_exec_run_flag_parity() {
  _label="$1"; _unused_expected="$2"; shift 2
  : > "$_record"
  _run_capture_streams env SUDO_EDITOR="${_mockbin}/editor" "$_shim" "$@" "${_mockbin}/true"
  _exec_flags=$(cat "$_record")
  : > "$_record"
  _run_capture_streams env SUDO_EDITOR="${_mockbin}/editor" "$_shim" -e "$@" "$_editfile"
  _run_flags=$(cat "$_record")

  if [ "$_exec_flags" = "$_run_flags" ]; then
    _pass_t "[parity] ${_label}: exec and edit paths match"
  else
    _fail_t "[parity] ${_label}: exec and edit paths match" "exec: ${_exec_flags}; run: ${_run_flags}"
  fi
}

if [ "$_run_edit_doas_flags" -eq 1 ]; then
  _for_each_flag_combination _assert_exec_run_flag_parity
else
  _skip_flag_combinations parity "$_skip_edit_flags_reason"
fi

# ---- Summary -----------------------------------------------------------------------------

_tests_summary
