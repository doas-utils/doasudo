#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Exercise broker/allowlist-parse.awk (path-only allowlist).
#
#   sh broker/tests/allowlist-parse_test.sh

set -eu

_here=$(CDPATH="" cd -P -- "$(dirname -- "$0")" && pwd)
_repo=$(CDPATH="" cd -P -- "$_here/../.." && pwd)
# shellcheck disable=SC1091
# shellcheck source=../../tests/testlib-broker.sh
. "$_repo/tests/testlib-broker.sh"
AWK=${AWK:-awk}
_PARSER="$_repo/broker/allowlist-parse.awk"
_FIX="$_here/fixtures/allowlist"

trap '_broker_rm_tmps' EXIT

[ -f "$_PARSER" ] || {
	printf 'FAIL allowlist-parse_test: missing %s\n' "$_PARSER" >&2
	exit 1
}

fail() {
	printf 'FAIL allowlist-parse_test: %s\n' "$1" >&2
	exit 1
}

pass_dump() {
	_label=$1
	_ed=$_FIX/$2
	_want=$_FIX/$3
	_out=$(_broker_make_temp) || fail "$_label: mktemp"
	# stderr may contain executable warnings (DUMP runs test -x); compare stdout only
	if ! "$AWK" -v DUMP=1 -f "$_PARSER" "$_ed" 2>/dev/null >"$_out"; then
		fail "$_label: expected success"
	fi
	if ! diff -u "$_want" "$_out" >&2; then
		fail "$_label: dump mismatch"
	fi
	printf 'PASS allowlist-parse_test: %s\n' "$_label"
}

# EDITOR=... query mode: EXEC + PROFILE lines, no test -x, stdout only
pass_query() {
	_label=$1
	_ed=$_FIX/$2
	_editor=$3
	_want=$_FIX/$4
	_out=$(_broker_make_temp) || fail "$_label: mktemp"
	if ! "$AWK" -v EDITOR="$_editor" -f "$_PARSER" "$_ed" >"$_out"; then
		fail "$_label: expected success"
	fi
	if ! diff -u "$_want" "$_out" >&2; then
		fail "$_label: query mismatch"
	fi
	printf 'PASS allowlist-parse_test: %s\n' "$_label"
}

pass_fail() {
	_label=$1
	_ed=$_FIX/$2
	if "$AWK" -f "$_PARSER" "$_ed" >/dev/null 2>&1; then
		fail "$_label: expected parse failure"
	fi
	printf 'PASS allowlist-parse_test: %s\n' "$_label"
}

# Valid file, EDITOR not listed -> exit 2 (broker: user-facing "not allowlisted").
pass_fail_query() {
	_label=$1
	_ed=$_FIX/$2
	_editor=$3
	_rc=0
	"$AWK" -v EDITOR="$_editor" -f "$_PARSER" "$_ed" >/dev/null 2>&1 || _rc=$?
	[ "$_rc" -eq 2 ] || fail "$_label: expected exit 2 (no match), got $_rc"
	printf 'PASS allowlist-parse_test: %s\n' "$_label"
}

# Malformed file with EDITOR set -> exit 1 (broker: admin / allowlist file problem).
pass_fail_query_parse() {
	_label=$1
	_ed=$_FIX/$2
	_editor=$3
	_rc=0
	"$AWK" -v EDITOR="$_editor" -f "$_PARSER" "$_ed" >/dev/null 2>&1 || _rc=$?
	[ "$_rc" -eq 1 ] || fail "$_label: expected exit 1 (parse error), got $_rc"
	printf 'PASS allowlist-parse_test: %s\n' "$_label"
}

printf '\n── Allowlist parse ─────────────────────────────────────────────────────────────\n'

pass_dump 'ok minimal dump' 'ok-minimal.editors' 'ok-minimal.dump'
pass_dump 'ok vi header dump' 'ok-vi-alias.editors' 'ok-vi-alias.dump'
pass_dump 'ok unknown profile token (broker resolves)' 'ok-unknown-profile.editors' 'ok-unknown-profile.dump'

pass_query 'ok query vim exact' 'ok-minimal.editors' '/stub/p/vim' 'ok-query-vim-exact.query'
pass_query 'ok query vim alias path' 'ok-minimal.editors' '/stub/p/vim-alias' 'ok-query-vim-alias.query'
pass_query 'ok query nano' 'ok-minimal.editors' '/stub/p/nano' 'ok-query-nano.query'
pass_query 'ok query red' 'ok-minimal.editors' '/stub/p/red' 'ok-query-red.query'
pass_query 'ok query unknown profile name' 'ok-unknown-profile.editors' '/stub/p/nvim' 'ok-unknown-profile.query'

pass_fail_query 'reject query no matching path' 'ok-minimal.editors' '/nonexistent/editor'
pass_fail_query_parse 'reject query mode parse error' 'bad-unknown-key.editors' '/stub/p/vim'

pass_fail 'reject line before [profile]' 'bad-before-header.editors'
pass_fail 'reject duplicate path across stanzas' 'bad-dupe-path.editors'
pass_fail 'reject unknown key' 'bad-unknown-key.editors'
pass_fail 'reject bad profile header case' 'bad-profile-case.editors'
pass_fail 'reject flags in allowlist' 'bad-dup-flags.editors'
pass_fail 'reject stanza without path' 'bad-no-path.editors'
pass_fail 'reject relative path' 'bad-relative-path.editors'
pass_fail 'reject env key' 'bad-env-name.editors'
pass_fail 'reject env value with space (split token)' 'bad-env-space.editors'
pass_fail 'reject config key' 'bad-dup-config.editors'
pass_fail 'reject empty file (no stanzas)' 'bad-empty.editors'
pass_fail 'reject flags key (any length)' 'bad-flags-key.editors'

printf '\n'
