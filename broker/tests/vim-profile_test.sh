#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doas-sudo-shim.
#
# Verifies broker vim profile wiring and shipped vimrc hardening:
# - _resolve_editor vim arm uses fixed flags/config basename.
# - vim(1) runtime matches broker _check_vim expectation (VIM + +autocmd + +eval).
# - config/vimrc enforces core trust-boundary options.
# - shell escape and modeline paths remain blocked under that vimrc.
#
# Usage:
#   sh broker/tests/vim-profile_test.sh

set -eu

_root=$(CDPATH="" cd -P -- "$(dirname -- "$0")/../.." && pwd)
_broker_in="$_root/broker/edit-broker.sh.in"
_vimrc="$_root/config/vimrc"

fail() {
  printf 'FAIL vim-profile_test: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS vim-profile_test: %s\n' "$1"
}

printf '\n── Vim profile ─────────────────────────────────────────────────────────────────\n'

[ -r "$_broker_in" ] || fail "missing broker source: $_broker_in"
[ -r "$_vimrc" ] || fail "missing vimrc: $_vimrc"

_want_flags="-u \$CONFIG -U NONE -i NONE -N -Z"
_got_flags=$(
  awk '
    /vim\)/ { in_vim=1; next }
    in_vim && /_editor_flags=/ {
      line=$0
      sub(/^[[:space:]]*_editor_flags='\''/, "", line)
      sub(/'\''[[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$_broker_in"
)
[ -n "$_got_flags" ] || fail "vim profile _editor_flags not found"
[ "$_got_flags" = "$_want_flags" ] \
  || fail "vim profile flags drifted (expected '$_want_flags', got '$_got_flags')"
pass "vim profile flags are fixed"

_got_cfg=$(
  awk '
    /vim\)/ { in_vim=1; next }
    in_vim && /_config_file=/ {
      line=$0
      sub(/^[[:space:]]*_config_file='\''/, "", line)
      sub(/'\''[[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$_broker_in"
)
[ "$_got_cfg" = "vimrc" ] || fail "vim profile config basename must be vimrc (got '$_got_cfg')"
pass "vim profile config basename is vimrc"

_vim=$(command -v vim 2>/dev/null || true)
[ -n "$_vim" ] || {
  printf 'SKIP vim-profile_test: vim not on PATH (static checks passed)\n'
  exit 0
}

_vv_out=$("$_vim" --version 2>/dev/null || true)
case "$_vv_out" in
  *VIM*'+autocmd'*'+eval'*) ;;
  *)
    fail "${_vim} --version missing VIM/+autocmd/+eval pattern"
    ;;
esac
pass "vim runtime has +autocmd and +eval"

_tmp=$(
  mktemp -d "${TMPDIR:-/tmp}/vimrc-profile-test.XXXXXX" 2>/dev/null \
    || mktemp -d -t vimrc-profile-test
)
trap 'rm -rf "$_tmp"' EXIT HUP INT TERM

_io_blocked() {
  _label=$1
  _cmd=$2
  _target=$3
  _out="$4"
  rm -f "$_target"
  printf 'seed\n' > "$_out"
  # Direct +:cmd in -es bypasses cmdline mappings; feedkeys exercises cnoremap
  # dispatch path used by interactive broker sessions.
  "$_vim" -Nu "$_vimrc" -n -es "$_tmp/buffer.txt" \
    '+call setline(1, "edited")' \
    '+call feedkeys(":'"$_cmd"'\\<CR>", "xt")' \
    '+sleep 100m' \
    '+qa!' >"$_out" 2>&1 || {
      fail "${_label}: vim probe failed (non-zero exit; see ${_out})"
    }
  [ ! -e "$_target" ] || fail "${_label}: wrote external file $_target"
  pass "${_label}: blocked and no external write"
}

_opts="$_tmp/options.out"
"$_vim" -Nu "$_vimrc" -n -es \
  '+redir! > '"$_opts" \
  '+set modeline? modelines? exrc? secure? shell? loadplugins? packpath?' \
  '+redir END' \
  '+qa!' >/dev/null 2>&1 || fail "vim option probe failed"

for _needle in \
  "nomodeline" \
  "modelines=0" \
  "noexrc" \
  "secure" \
  "shell=/bin/false" \
  "noloadplugins" \
  "packpath="
do
  grep -E -q "(^|[[:space:]])${_needle}([[:space:]]|$)" "$_opts" \
    || fail "missing hardened option '${_needle}' in vim probe output"
done
pass "vimrc hardened options active"

_shell_marker="$_tmp/shell_escape_marker"
"$_vim" -Nu "$_vimrc" -n -es \
  '+silent !printf pwn > '"$_shell_marker" \
  '+qa!' >/dev/null 2>&1 || {
    fail "shell escape probe: vim exited non-zero"
  }
[ ! -e "$_shell_marker" ] || fail "shell escape executed under hardened vimrc"
pass "shell escape blocked"

_ml_file="$_tmp/modeline.txt"
printf 'x\n# vim: set nonumber :\n' > "$_ml_file"
_ml_out="$_tmp/modeline.out"
"$_vim" -Nu "$_vimrc" -n -es "$_ml_file" \
  '+redir! > '"$_ml_out" \
  '+set number?' \
  '+redir END' \
  '+qa!' >/dev/null 2>&1 || fail "modeline probe failed"

grep -E -q '[[:space:]]number([[:space:]]|$)' "$_ml_out" \
  || fail "modeline affected option state (expected number to remain enabled)"
pass "modeline execution disabled"

printf 'seed\n' > "$_tmp/buffer.txt"

_io_blocked "io escape :w /tmp/..." 'w /tmp/vimrc-io-escape-w' \
  "/tmp/vimrc-io-escape-w" "$_tmp/io_w.out"
_io_blocked "io escape :saveas /tmp/..." 'saveas /tmp/vimrc-io-escape-saveas' \
  "/tmp/vimrc-io-escape-saveas" "$_tmp/io_saveas.out"
_io_blocked "io escape :r /tmp/..." 'r /tmp/vimrc-io-escape-read-src' \
  "/tmp/vimrc-io-escape-read-src" "$_tmp/io_read.out"
_io_blocked "io escape :w !cmd > /tmp/..." 'w !printf pwn > /tmp/vimrc-io-escape-shellpipe' \
  "/tmp/vimrc-io-escape-shellpipe" "$_tmp/io_shellpipe.out"
_io_blocked "io escape :e /tmp/..." 'e /tmp/vimrc-io-escape-edit' \
  "/tmp/vimrc-io-escape-edit" "$_tmp/io_edit.out"
_io_blocked "io escape :split /tmp/..." 'split /tmp/vimrc-io-escape-split' \
  "/tmp/vimrc-io-escape-split" "$_tmp/io_split.out"
_io_blocked "io escape :vsplit /tmp/..." 'vsplit /tmp/vimrc-io-escape-vsplit' \
  "/tmp/vimrc-io-escape-vsplit" "$_tmp/io_vsplit.out"
_io_blocked "io escape :new /tmp/..." 'new /tmp/vimrc-io-escape-new' \
  "/tmp/vimrc-io-escape-new" "$_tmp/io_new.out"
_io_blocked "io escape :vnew /tmp/..." 'vnew /tmp/vimrc-io-escape-vnew' \
  "/tmp/vimrc-io-escape-vnew" "$_tmp/io_vnew.out"
_io_blocked "io escape :global ... w /tmp/..." 'g/./w /tmp/vimrc-io-escape-global-w' \
  "/tmp/vimrc-io-escape-global-w" "$_tmp/io_global_w.out"
_io_blocked "io escape :r !cmd > /tmp/..." 'r !printf pwn > /tmp/vimrc-io-escape-read-shell' \
  "/tmp/vimrc-io-escape-read-shell" "$_tmp/io_read_shell.out"
_io_blocked "io escape :execute \"w /tmp/...\"" "execute 'w /tmp/vimrc-io-escape-execute-w'" \
  "/tmp/vimrc-io-escape-execute-w" "$_tmp/io_execute_w.out"
_io_blocked "io escape :source /tmp/..." 'source /tmp/vimrc-io-escape-source' \
  "/tmp/vimrc-io-escape-source" "$_tmp/io_source.out"
_io_blocked "io escape :runtime /tmp/..." 'runtime /tmp/vimrc-io-escape-runtime' \
  "/tmp/vimrc-io-escape-runtime" "$_tmp/io_runtime.out"

printf '\n'