#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Classification: EDIT-agnostic — builds and validates the EDIT_MODE=0 shim.

# shellcheck disable=SC1091,SC2154

set -eu

_pass=0
_fail=0
_skip=0

_here=$(CDPATH="" cd -P -- "$(dirname -- "$0")" && pwd)
# shellcheck source=testlib.sh
. "$_here/testlib.sh"
# shellcheck source=testlib-parser.sh
. "$_here/testlib-parser.sh"

DOASUDO_TEST_EDIT_MODE=0
export DOASUDO_TEST_EDIT_MODE
_parser_setup "$@"

_disabled_msg='edit mode is not built into this doasudo'

_assert_disabled_edit() {
  _label=$1
  shift
  _run_capture_streams "$_shim" "$@"
  _assert_exit "${_label}: exits 1" 1 "$_rc"
  _assert_string_contains "${_label}: stub message" "$_disabled_msg" "$_err"
}

printf '\n-- Disabled edit-mode stubs ---------------------------------------------------\n'

_target="${_tmp}/target.txt"
printf 'content\n' > "$_target"

_assert_disabled_edit "-e" -e "$_target"
_assert_disabled_edit "--edit" --edit "$_target"
_assert_disabled_edit "-e -u" -e -u root "$_target"
_assert_disabled_edit "-e -i" -e -i "$_target"
_assert_disabled_edit "-e -s" -e -s "$_target"

_sudoedit="${_tmp}/sudoedit"
ln -sf "$_shim" "$_sudoedit"
_run_capture_streams "$_sudoedit" "$_target"
_assert_exit "sudoedit symlink: exits 1" 1 "$_rc"
_assert_string_contains "sudoedit symlink: stub message" "$_disabled_msg" "$_err"

printf '\n-- Disabled help/version/dispatch --------------------------------------------\n'

_run_capture_streams "$_shim" -h
_assert_exit "help: exits 0" 0 "$_rc"
_assert_string_excludes "help: no -e/--edit synopsis" "-e, --edit" "$_out"
_assert_string_excludes "help: no sudoedit reference" "sudoedit" "$_out"
_assert_string_excludes "help: no editas reference" "editas" "$_out"

_run_capture_streams "$_shim" --version
_assert_exit "version: exits 0" 0 "$_rc"
_assert_string_contains "version: doasudo" "doasudo" "$_out"

_run_capture_streams "$_shim" "${_mockbin}/doas"
_assert_exit "normal dispatch: exits 0" 0 "$_rc"

_broker_count=$(grep -c '_EDIT_BROKER_' "$_shim" 2>/dev/null || true)
if [ "$_broker_count" -eq 0 ]; then
  _pass_t "disabled shim: no _EDIT_BROKER_ vars"
else
  _fail_t "disabled shim: no _EDIT_BROKER_ vars" "count=${_broker_count}"
fi

_tests_summary
