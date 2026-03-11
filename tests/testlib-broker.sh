#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doas-sudo-shim.
#
# Helpers for broker-focused shell tests. Source tests/testlib.sh first (_pass_t / _fail_t),
# then this file. Used from tests/edit-mode_test.sh, broker/tests/*.sh, etc.
#
# Assertions below use _pass_t / _fail_t from testlib.sh and optionally ${_err} for stderr checks.

# ---- Assertions shared by edit-mode_test + broker-integration_test -----------------

_assert_exit() {
  if [ "$3" -eq "$2" ]; then _pass_t "${1}: exit ${2}"
  else _fail_t "${1}: exit ${2}" "got exit ${3}; stderr: ${_err:-<empty>}"; fi
}

_assert_stderr_contains() {
  case "$3" in
    *"${2}"*) _pass_t "${1}: stderr contains '${2}'" ;;
    *)        _fail_t "${1}: stderr contains '${2}'" "got: ${3}" ;;
  esac
}

# $1 label; $2 path; $3 expected (trailing newline lost via $())
_assert_file_content() {
  if [ -f "$2" ]; then
    _got=$(cat "$2")
    if [ "$_got" = "$3" ]; then _pass_t "${1}: file content"
    else _fail_t "${1}: file content" "expected '${3}', got '${_got}'"; fi
  else
    _fail_t "${1}: file content" "file does not exist: $2"
  fi
}

_assert_str_eq() {
  if [ "$2" = "$3" ]; then _pass_t "$1"
  else _fail_t "$1" "expected '${3}', got '${2}'"; fi
}

# ---- kill -0 probe ------------------------------------------------------------------------
# Sandboxes sometimes hide child PIDs from kill -0 (broker timeout + lock paths).
_broker_kill0_usable=0

# Probe whether kill -0 polling on child PIDs is trustworthy here.
# Sets _broker_kill0_usable to 1 (yes) or 0 (no); exits 0 / 1 accordingly.
_broker_check_kill0() {
  sleep 2 >/dev/null 2>&1 &
  _bck0_pid=$!
  if kill -0 "$_bck0_pid" 2>/dev/null; then
    _broker_kill0_usable=1
  fi
  wait "$_bck0_pid" 2>/dev/null || true
  [ "$_broker_kill0_usable" -eq 1 ]
}

# $1=key; $2=path to KEY=value contracts file (no sourcing).
_broker_get_contract_value() {
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$2"
}

# Tracker for paths from _broker_make_temp (space-separated).
_broker_tmps=

_broker_rm_tmps() {
  for _broker_t in $_broker_tmps; do
    rm -f "$_broker_t"
  done
  _broker_tmps=
}

# Prints one tempfile path to stdout; registers it for _broker_rm_tmps.
_broker_make_temp() {
  _broker_m=$(mktemp "${TMPDIR:-/tmp}/broker.XXXXXX") || return 1
  _broker_tmps="$_broker_tmps $_broker_m"
  printf '%s\n' "$_broker_m"
}

# ---- Shim bake with SUDO_SHIM_EDIT_BROKER (edit-mode + broker-integration) ---------------

# $1=output path $2=edit-broker path $3=EDIT_BROKER_METADATA value
# Requires: _build_test_shim (testlib.sh); _repo_root _shim_src _mockbin _sys_path
# _utils_metadata _version _eb_client _eb_client_meta (harness fills before call).
# shellcheck disable=SC2154 # globals set by sourcing harness before call
_build_edit_test_shim() {
  _build_test_shim "$_repo_root" "$_shim_src" "$1" "${_mockbin}:${_sys_path}" \
    "${_utils_metadata}" "${_version}" "${_repo_root}/lib/shim-utils.sh" \
    "${_eb_client}" "${_eb_client_meta}" \
    "$2" "$3" \
    --stub-edit-mode-root-guard \
    --stub-check-path-walk || return
  chmod +x "$1"
}
