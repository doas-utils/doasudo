#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Validates edit-mode (-e) argument parsing, path-walk rejections, sudoedit/editas
# alias dispatch, and edit-mode mutual-exclusion rules.
#
# The harness uses a mock `doas` to record the final argument vector.
#
# Usage:
#   sh edit-mode-parser_test.sh [path/to/doasudo.in]     # source mode (default)
#   sh edit-mode-parser_test.sh --built path/to/doasudo  # built mode
#
# Constraints:
# - Built mode requires a real `doas`; skips fixtures that need compilation.
# - Edit mode (-e) tests require an unreadable host file (e.g., /etc/shadow).
#   If none exist (when running as root), relevant assertions SKIP.

# shellcheck disable=SC2154,SC1091,SC2016,SC2015,SC2086

set -eu

_pass=0
_fail=0
_skip=0

_here=$(CDPATH="" cd -P -- "$(dirname -- "$0")" && pwd)
_repo=$(CDPATH="" cd -P -- "$_here/.." && pwd)
# shellcheck source=testlib.sh
. "$_here/testlib.sh"
# shellcheck source=testlib-parser.sh
. "$_here/testlib-parser.sh"

_parser_setup "$@"

# ---- Edit-only shim builds ---------------------------------------------------------------

_build_edit_parser_shims() {
  _shim_edit="${_tmp}/sudo_edit"
  _parser_build_shim "$_shim_edit" "$_bindir_std" "$_utils_meta" "$_shim_utils_src" \
    --stub-edit-mode-root-guard

  _shim_edit_leaf="${_tmp}/sudo_edit_leaf"
  _parser_build_shim "$_shim_edit_leaf" "$_bindir_std" "$_utils_meta" "$_shim_utils_src" \
    --stub-edit-mode-root-guard \
    --stub-check-path-walk
}

if [ -z "$_built" ]; then
  _build_edit_parser_shims
fi

# ---- Edit-only skip helpers --------------------------------------------------------------

_skip_src_only_msg='source-only (requires re-baked edit harness)'

_skip_unreadable_host() {
  _skip_t "-e: no unreadable host file (typical when EUID 0); need e.g. /etc/shadow ! -r"
  _skip_t "-e: _doas path (no env wrapper)"
  _skip_t "-e -n exits 0"
  _skip_t "-e -n: doas flags"
  _skip_t "-e -u root exits 0"
  _skip_t "-e -u root: doas flags"
}

_skip_built_e_mode() {
  _skip_t "-e coverage: $_skip_src_only_msg"
  _skip_t "-e -n [edit-flags]: $_skip_src_only_msg"
  _skip_t "-e -u root [edit-flags]: $_skip_src_only_msg"
  _skip_t "-e no file: $_skip_src_only_msg"
}

_skip_built_mutex_options() {
  _skip_t "-e -i: $_skip_src_only_msg"
  _skip_t "-e -s: $_skip_src_only_msg"
  _skip_t "-e -H: $_skip_src_only_msg"
  _skip_t "-e VAR=value: $_skip_src_only_msg"
}

# ---- Tests -------------------------------------------------------------------------------

printf '\n── Root-invoked edit mode ──────────────────────────────────────────────────────\n'

if [ -z "$_built" ]; then
  _run_parser_shim "$_shim" -e "$_edit_dummy"
  _assert_exit               "root -e: exits 1" 1 "$_rc"
  _assert_stderr_contains    "root -e: diagnostic" "not supported when invoked by root" "$_err"
else
  _skip_t "root -e: source-only (requires re-baked root-id harness)"
fi

printf '\n── -e / edit mode ──────────────────────────────────────────────────────────────\n'
#
# _doas: no env wrapper, no SUDO_*. First call: `doas [flags] -- cat -- <file>`.

if [ -z "$_built" ]; then
  if [ -n "$_editfile" ]; then
    _run_parser_shim "$_shim_edit" -e "$_editfile"
    _assert_exit               "-e exits 0" 0 "$_rc"
    _got=$(_after_dashdash)
    case "$_got" in
      /usr/bin/env) _fail_t "-e: _doas path (no env wrapper)" "got /usr/bin/env" ;;
      *)            _pass_t "-e: _doas path (no env wrapper)" ;;
    esac

    # Flags: need _doas cat (unreadable file).
    _run_parser_shim "$_shim_edit" -e -n "$_editfile"
    _assert_exit               "-e -n exits 0" 0 "$_rc"
    if _record_has "-n"; then
      _assert_doas_flags         "-e -n: doas flags" "-n"
    else
      _skip_t "-e -n [edit-flags]: no unreadable candidate found"
    fi

    _run_parser_shim "$_shim_edit" -e -u root "$_editfile"
    _assert_exit               "-e -u root exits 0" 0 "$_rc"
    if _record_has "-u"; then
      _assert_doas_flags         "-e -u root: doas flags" "-u root"
    else
      _skip_t "-e -u root [edit-flags]: no unreadable candidate found"
    fi
  else
    _skip_unreadable_host
  fi

  _run_parser_shim "$_shim_edit" -e
  _assert_exit               "-e no file: exits 1" 1 "$_rc"
else
  _skip_built_e_mode
fi

printf '\n── Edit mode rejections (early die) ────────────────────────────────────────────\n'

# _shim_edit_leaf stubs path walk -> leaf symlink rejection only.
mkdir -p "${_tmp}/er_symlink"
chmod 755 "${_tmp}/er_symlink"
ln -sf /etc/hosts "${_tmp}/er_symlink/thelink"
chmod 555 "${_tmp}/er_symlink"
if [ -z "$_built" ]; then
  _run_parser_shim "$_shim_edit_leaf" -e "${_tmp}/er_symlink/thelink"
  _assert_exit               "-e symlink target: exits 1" 1 "$_rc"
  _assert_stderr_contains    "-e symlink target" "editing symbolic links is not permitted" "$_err"
else
  _skip_t "-e symlink target: source-only (requires re-baked leaf-symlink harness)"
fi

# Block/char device.
if [ -z "$_built" ]; then
  _run_parser_shim "$_shim_edit" -e /dev/zero
  _assert_exit               "-e device file: exits 1" 1 "$_rc"
  _assert_stderr_contains    "-e device file" "device special" "$_err"
else
  _skip_t "-e device file: $_skip_src_only_msg"
fi

# Writable parent on path (non-root only; root skips _check_path_walk).
if [ -z "$_built" ] && [ "$(id -u)" -ne 0 ]; then
  _id_edit="${_tmp}/id.bak.writable"
  mv "${_mockbin}/id" "$_id_edit"
  _mock_id_real
  mkdir -p "${_tmp}/er_writable"
  chmod 777 "${_tmp}/er_writable"
  echo x > "${_tmp}/er_writable/wfile"
  _run_parser_shim "$_shim_edit" -e "${_tmp}/er_writable/wfile"
  _assert_exit               "-e writable directory: exits 1" 1 "$_rc"
  _assert_stderr_contains    "-e writable directory" "writable directory is not permitted" "$_err"
  mv "$_id_edit" "${_mockbin}/id"
elif [ -n "$_built" ]; then
  _skip_t "-e writable directory: $_skip_src_only_msg"
else
  _skip_t "-e writable directory: requires non-root (path walk skipped for UID 0)"
fi

printf '\n── sudoedit / editas aliases ───────────────────────────────────────────────────\n'
#
# `/nonexistent` under `/`: path walk empty. Mock doas exits 0; write-back not
# really exercised.

if [ -z "$_built" ]; then
  ln -sf "$(basename "$_shim_edit")" "${_tmp}/sudoedit"
  ln -sf "$(basename "$_shim_edit")" "${_tmp}/editas"
else
  ln -sf "$(basename "$_shim")" "${_tmp}/sudoedit"
  ln -sf "$(basename "$_shim")" "${_tmp}/editas"
fi

_rc=0; _err=$(SUDO_EDITOR="${_mockbin}/editor" "${_tmp}/sudoedit" /nonexistent 2>&1) || _rc=$?
[ "$_rc" -eq 0 ] && _pass_t "sudoedit: /nonexistent handled (exit 0)" \
  || _fail_t "sudoedit: /nonexistent handled (exit 0)" "got exit $_rc"

_rc=0; _err=$(SUDO_EDITOR="${_mockbin}/editor" "${_tmp}/editas" /nonexistent 2>&1) || _rc=$?
[ "$_rc" -eq 0 ] && _pass_t "editas: /nonexistent handled (exit 0)" \
  || _fail_t "editas: /nonexistent handled (exit 0)" "got exit $_rc"

_rc=0; _err=$(SUDO_EDITOR="${_mockbin}/editor" "${_tmp}/sudoedit" -i "$_edit_dummy" 2>&1) || _rc=$?
[ "$_rc" -ne 0 ] && _pass_t "sudoedit -i: exits non-zero" \
  || _fail_t "sudoedit -i: exits non-zero" "got exit 0"
_assert_stderr_contains    "sudoedit -i: diagnostic" "not valid in edit mode" "$_err"

printf '\n── Post-parse mutual exclusion (edit-mode arms) ────────────────────────────────\n'

if [ -z "$_built" ]; then
  _run_parser_shim "$_shim_edit" -e -i "$_edit_dummy"
  _assert_exit               "-e -i: exits 1"  1 "$_rc"
  _assert_stderr_contains    "-e -i: diagnostic" "not valid in edit mode" "$_err"

  _run_parser_shim "$_shim_edit" -e -s "$_edit_dummy"
  _assert_exit               "-e -s: exits 1"  1 "$_rc"
  _assert_stderr_contains    "-e -s: diagnostic" "not valid in edit mode" "$_err"

  _run_parser_shim "$_shim_edit" -e -H "$_edit_dummy"
  _assert_exit               "-e -H: exits 1"  1 "$_rc"
  _assert_stderr_contains    "-e -H: diagnostic" "not valid in edit mode" "$_err"

  _run_parser_shim "$_shim_edit" -e FOO=bar "$_edit_dummy"
  _assert_exit               "-e VAR=value: exits 1"    1 "$_rc"
  _assert_stderr_contains    "-e VAR=value: diagnostic" "environment variables" "$_err"
else
  _skip_built_mutex_options
fi

# ---- Summary -----------------------------------------------------------------------------

_tests_summary
