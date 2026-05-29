#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Shared integration test helpers. Sourced by tests/*.sh; not executed directly.

set -eu

# Match mock-edit-mode _sys_path so stat-ug metadata uses the same stat(1) as the shim.
PATH="/usr/bin:/usr/sbin:/bin:/sbin${PATH:+:${PATH}}"
export PATH

# Symlinks required system binaries into the mock environment. Fails if missing.
# $1=mockbin $2=sys_path $3...=tools
_symlink_required_tools() {
  _mb=$1; shift
  _sp=$1; shift
  for _bin in "$@"; do
    _sys=$(PATH="$_sp" command -v "$_bin" 2>/dev/null) \
      || { printf 'error: %s not found in %s\n' "$_bin" "$_sp" >&2; return 1; }
    ln -sf "$_sys" "${_mb}/${_bin}"
  done
}

# Symlinks optional system binaries into the mock environment. Skips if missing.
# $1=mockbin $2=sys_path $3...= tools
_symlink_optional_tools() {
  _mb=$1; shift
  _sp=$1; shift
  for _bin in "$@"; do
    if _sys=$(PATH="$_sp" command -v "$_bin" 2>/dev/null); then
      ln -sf "$_sys" "${_mb}/${_bin}"
    fi
  done
}

# Wraps build-test-shim.sh with standard test paths and metadata.
# Appends "$@" as extra flags.
_build_test_shim() {
  _r=$1;    shift
  _in=$1;   shift
  _out=$1;  shift
  _bd=$1;   shift
  _um=$1;   shift
  _ver=$1;  shift
  _su=$1;   shift
  _ebc=$1;  shift
  _ebcm=$1; shift
  _ebp=$1;  shift
  _ebm=$1;  shift
  "$_r/tests/build-test-shim.sh" \
    --input "$_in" \
    --output "$_out" \
    --bindir "$_bd" \
    --edit-broker-path "$_ebp" \
    --edit-broker-metadata "$_ebm" \
    --utils-metadata "$_um" \
    --version "$_ver" \
    --shim-utils "$_su" \
    --edit-broker-client "$_ebc" \
    --edit-broker-client-metadata "$_ebcm" \
    --edit-mode "$_r/edit-mode.sh" \
    --drop-setuid-guard \
    "$@"
}

# Builds a shim with edit-mode payload and broker vars removed.
_build_disabled_test_shim() {
  _r=$1;   shift
  _in=$1;  shift
  _out=$1; shift
  _bd=$1;  shift
  _um=$1;  shift
  _ver=$1; shift
  _su=$1;  shift
  "$_r/tests/build-test-shim.sh" \
    --input "$_in" \
    --output "$_out" \
    --bindir "$_bd" \
    --utils-metadata "$_um" \
    --version "$_ver" \
    --shim-utils "$_su" \
    --no-edit-mode \
    --drop-setuid-guard \
    "$@"
}

# Initializes the mock environment and sets globals (_tmp, _mockbin,
# _tmp_parent). Captures _tmp_parent to isolate the cleanup path, ensuring trap
# handlers do not wipe the host's actual $TMPDIR if the test mutates it.
_setup_mockbin() {
  _tmp=$(mktemp -d)
  _tmp_parent=$(dirname -- "$_tmp")
  _mockbin="${_tmp}/bin"
  mkdir -p "$_mockbin"
}

# EXIT handler: Removes scratch files.
# Validates the path prefix against _tmp_parent to protect host's $TMPDIR.
_rm_tmp() {
  case "$_tmp" in
    "$_tmp_parent"/tmp.*) rm -rf -- "$_tmp" ;;
  esac
}

# EXIT handler: Restores write permissions before removing scratch files.
# Required for parser/editor tests that simulate read-only states.
_chmod_rm_tmp() {
  case "$_tmp" in
    "$_tmp_parent"/tmp.*)
      chmod -R u+rwx "$_tmp" 2>/dev/null || true
      rm -rf -- "$_tmp"
      ;;
  esac
}

# Returns true if VERBOSE=1.
_verbose() { [ "${VERBOSE:-0}" = "1" ]; }

# Prints -s (silent make) unless VERBOSE=1. Useful to suppress make output:
# `"$MAKE" $(_make_s) <targets>`.
_make_s() { _verbose && return; printf '%s' -s; }

# Executes a command and captures its outputs into globals.
# Sets _rc (exit code), _out (stdout), and _err (stderr).
_run_capture_streams() {
  _out_file="${_tmp}/stdout"
  _err_file="${_tmp}/stderr"
  _rc=0
  "$@" >"$_out_file" 2>"$_err_file" || _rc=$?
  _out=$(cat "$_out_file")
  _err=$(cat "$_err_file")
  if _verbose; then
    if [ -n "$_out" ]; then
      printf '%s\n' "$_out"
    fi
    if [ -n "$_err" ]; then
      printf '%s\n' "$_err" >&2
    fi
  fi
}

# Prints captured stdout/stderr if the previous command failed.
_dump_captured_on_fail() {
  [ "${_rc:-0}" -eq 0 ] && return 0
  if [ -n "${_out:-}" ]; then
    printf '%s\n' "$_out"
  fi
  if [ -n "${_err:-}" ]; then
    printf '%s\n' "$_err" >&2
  fi
}

# Pass/fail/skip loggers for the test harness. Increments the counters.
# The calling script must initialize _pass, _fail, and _skip to 0.
_pass_t() { printf 'PASS  %s\n' "$1";     _pass=$(( _pass + 1 )); }
_fail_t() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; _fail=$(( _fail + 1 )); }
_skip_t() { printf 'SKIP  %s\n' "$1";     _skip=$(( _skip + 1 )); }

_assert_exit() {
  if [ "$3" -eq "$2" ]; then _pass_t "${1}: exit ${2}"
  else _fail_t "${1}: exit ${2}" "got exit ${3}; stderr: ${_err:-<empty>}"; fi
}

_assert_string_contains() {
  case "$3" in
    *"${2}"*) _pass_t "${1}: stderr contains '${2}'" ;;
    *)        _fail_t "${1}: stderr contains '${2}'" "got: ${3}" ;;
  esac
}

_assert_string_excludes() {
  case "$3" in
    *"${2}"*) _fail_t "${1}: stderr excludes '${2}'" "got: ${3}" ;;
    *)        _pass_t "${1}: stderr excludes '${2}'" ;;
  esac
}

_tests_summary() {
  printf '\n%d passed, %d failed, %d skipped\n\n' "$_pass" "$_fail" "$_skip"
  [ "$_fail" -eq 0 ] || exit 1
}
