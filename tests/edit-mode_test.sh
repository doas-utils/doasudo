#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Validates the `sudoedit` (-e) execution path, focusing on secure temporary
# file handling, elevated write-back logic, and interactive confirmations.
#
# The harness executes a mocked `doas` via `exec "$@"`. It simulates a UID 0
# environment to trigger the root-invoked edit path, but strips the root guard 
# and runs the "privileged" `sh -c` write-back on user-owned scratch files.
#
# Coverage:
# - Session Integrity: Verifies file checksums before and after the editor runs.
# - Directory Safety: Validates inode sweeps and temporary directory seals.
# - File Anchors: Ensures file descriptors (fd 3, fd 5) prevent substitution.
# - Path Resolution: Ensures CDPATH does not break relative target paths.
# (Shim + mock EDITBROKER IPC matrix: broker/tests/broker-integration_test.sh.)
#
# Usage:
#   sh edit-mode_test.sh [path/to/doasudo.in]
#
# Constraints:
# - Interactive confirmations (`y`) require a `socat` pseudo-terminal.
# - Negative confirmations (`n`) require a fake TTY probe via `/dev/shm`.
# - Write-failure assertions require a read-only parent directory (`chmod 555`).
#   If these conditions cannot be met, the affected tests SKIP.

set -eu

_pass=0
_fail=0
_skip=0

# ---- Locate source -----------------------------------------------------------------------

_self_dir=$(cd "$(dirname "$0")" && pwd)
_repo_root=$(CDPATH="" cd -P -- "$_self_dir/.." && pwd)

_shim_src="${1:-${_repo_root}/doasudo.in}"
[ -f "$_shim_src" ] || { printf 'error: shim source not found: %s\n' "$_shim_src" >&2; exit 1; }

# shellcheck source=testlib.sh
. "$_self_dir/testlib.sh"
# shellcheck source=testlib-broker.sh
. "$_self_dir/testlib-broker.sh"
# shellcheck source=../utils/metadata-utils.sh
. "$_repo_root/utils/metadata-utils.sh"

_eb_contracts="$_repo_root/config/edit-broker-contracts.env"
[ -r "$_eb_contracts" ] || { printf 'error: missing %s\n' "$_eb_contracts" >&2; exit 1; }
_eb_magic=$(_broker_get_contract_value MAGIC "$_eb_contracts")
_eb_max=$(_broker_get_contract_value MAX_BROKER_BYTES "$_eb_contracts")
_eb_to=$(_broker_get_contract_value BROKER_RESPONSE_TIMEOUT_S "$_eb_contracts")
[ -n "$_eb_magic" ] && [ -n "$_eb_max" ] && [ -n "$_eb_to" ] || {
  printf 'error: MAGIC, MAX_BROKER_BYTES, or BROKER_RESPONSE_TIMEOUT_S missing in %s\n' "$_eb_contracts" >&2
  exit 1
}

# ---- Scratch area ------------------------------------------------------------------------

_setup_mockbin
export TMPDIR="$_tmp"
trap '_chmod_rm_tmp' EXIT

# kill -0 may be flaky in sandboxes (PTY + broker deadline polling).
_broker_check_kill0 || true

_shim="${_tmp}/sudo"

chmod 755 "$_mockbin"

# ---- Test framework ----------------------------------------------------------------------
# _assert_* and _build_edit_test_shim: ./testlib-broker.sh
# Remaining _assert_* helpers: edit-mode only.

_assert_stderr_excludes() {
  case "$3" in
    *"${2}"*) _fail_t "${1}: stderr excludes '${2}'" "got: ${3}" ;;
    *)        _pass_t "${1}: stderr excludes '${2}'" ;;
  esac
}

_assert_pty_prompt_once() {
  if [ "${_pty_prompt_count:-0}" -eq 1 ]; then _pass_t "$1"
  else _fail_t "$1" "count=${_pty_prompt_count:-<unset>}"; fi
}

_mode_of() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  elif stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    printf '%s' '-'
  fi
}

_uid_gid_of() {
  if stat -c '%u:%g' "$1" >/dev/null 2>&1; then
    stat -c '%u:%g' "$1"
  elif stat -f '%u:%g' "$1" >/dev/null 2>&1; then
    stat -f '%u:%g' "$1"
  else
    printf '%s' '-'
  fi
}

_inode_of() {
  if stat -c '%d:%i' "$1" >/dev/null 2>&1; then
    stat -c '%d:%i' "$1"
  elif stat -f '%i' "$1" >/dev/null 2>&1; then
    stat -f '%i' "$1"
  else
    printf '%s' '-'
  fi
}

# $1 path; echo GNU/BSD stat inode args for the shim replay tests, or nothing.
_stat_fd_flag() {
  _sff_tmp=$(mktemp "${TMPDIR:-/tmp}/.fd-XXXXXX")
  if stat -c '%i' "$_sff_tmp" >/dev/null 2>&1; then
    printf '%s\n' '-c %d:%i'
  elif stat -f '%i' "$_sff_tmp" >/dev/null 2>&1; then
    _sff_fmt='%i'
    (
      exec 3>"$_sff_tmp" || exit 1
      _f=$(stat -L -f '%d:%i' /dev/fd/3 2>/dev/null)
      _p=$(stat -f '%d:%i' "$_sff_tmp" 2>/dev/null)
      [ -n "$_f" ] && [ "$_f" = "$_p" ]
    ) && _sff_fmt='%d:%i'
    printf '%s\n' "-f $_sff_fmt"
  else
    printf '%s\n' ''
  fi
  rm -f "$_sff_tmp"
}

# $1 label; $2 path; $3 expected mode (octal digits, e.g. 600)
_assert_file_mode() {
  _cm_got=$(_mode_of "$2")
  if [ "$_cm_got" = "$3" ]; then _pass_t "$1"
  else _fail_t "$1" "got mode=$_cm_got"; fi
}

# SUDO_EDITOR $1 (after optional leading -n); remaining args are -e targets.
_run_editor_mode() {
  _rse_n=
  if [ "${1:-}" = -n ]; then _rse_n=1; shift; fi
  _rse_ed=$1
  shift
  if [ -n "$_rse_n" ]; then
    _run_capture_streams env SUDO_EDITOR="$_rse_ed" "$_shim" -n -e "$@"
  else
    _run_capture_streams env SUDO_EDITOR="$_rse_ed" "$_shim" -e "$@"
  fi
}

# Replaces tty mock with a no-op for one command.
_without_tty() {
  mv "${_mockbin}/tty" "${_tmp}/tty.bak.$$"
  printf '#!/bin/sh\nexit 0\n' > "${_mockbin}/tty"
  chmod +x "${_mockbin}/tty"
  "$@"
  mv "${_tmp}/tty.bak.$$" "${_mockbin}/tty"
}

# $1 = outfile: verbatim write-back sh -c body from $_shim_src (for replay tests).
_write_wb_fragment_from_shim() {
  _out=$1
  awk '
    /^    _doas \/bin\/sh -c / { in_body=1; next }
    in_body && /^    '\'' _ \\$/ { exit }
    in_body {
      sub(/^    /, "", $0)
      print
    }
  ' "$_shim_src" > "$_out"
  [ -s "$_out" ] || {
    printf 'error: failed to extract write-back fragment from %s\n' "$_shim_src" >&2
    exit 1
  }
}

# Fails if $_wb_script lacks the shim-documented exit path (grep -F $1). $2 tags
# the error message.
_guard_wb_extract_exit_paths() {
  if ! grep -F "$1" "$_wb_script" >/dev/null 2>&1; then
    printf 'error: extracted write-back body lacks %s\n' "$2" >&2
    exit 1
  fi
}

# Replay extracted write-back fragment: stdin matches shim fd 3. Args follow
# _doas ... sh -c in doasudo.in: mv, rm, cat, stat, chmod, chown, cksum,
# _ckflg, inode, digest, owner:group, mode, wbtmp, target (cat--chown from
# mockbin). Sets _rc, _err.
# $1 stderr suffix; $2 mv; $3 sha tool; $4 digest; $5 staging; $6 target;
# $7 non-empty -> env MV_EXIT2_TARGET for exit-2 mv wrapper. Needs _wb_fd_fmt.
_run_writeback_fragment() {
  _rwbf_lbl=$1
  _rwbf_mv=$2
  _rwbf_sha=$3
  _rwbf_digest=$4
  _rwbf_wb=$5
  _rwbf_tgt=$6
  _rwbf_exit2=${7:-}
  _rwbf_rm="${_mockbin}/rm"
  _rwbf_cat="${_mockbin}/cat"
  _rwbf_stat="${_mockbin}/stat"
  _rwbf_chmod="${_mockbin}/chmod"
  _rwbf_chown="${_mockbin}/chown"
  _rwbf_err="${_tmp}/stderr.writeback_${_rwbf_lbl}"
  set -- "$_rwbf_mv" "$_rwbf_rm" "$_rwbf_cat" "$_rwbf_stat" "$_rwbf_chmod" "$_rwbf_chown" \
    "$_rwbf_sha" "" $_wb_fd_fmt "$_rwbf_digest" "0:0" "0644" "$_rwbf_wb" "$_rwbf_tgt"
  if [ -n "$_rwbf_exit2" ]; then
    set -- env MV_EXIT2_TARGET="$_rwbf_tgt" sh "$_wb_script" "$@"
  else
    set -- sh "$_wb_script" "$@"
  fi
  _rc=0
  printf 'edited content\n' | "$@" >/dev/null 2>"$_rwbf_err" || _rc=$?
  _err=$(cat "$_rwbf_err" 2>/dev/null || true)
}

# $1 EDITOR_ATTACK_MODE; $2 target; extra KEY=val for env before shim -e.
_run_editor_attack() {
  _ra_mode=$1
  _ra_file=$2
  shift 2
  _run_capture_streams env SUDO_EDITOR="${_mockbin}/editor_attack" EDITOR_ATTACK_MODE="$_ra_mode" "$@" "$_shim" -e "$_ra_file"
}

# Sets _WB_EXIT_* from the shim "# Exit codes:" table (defaults if absent).
_define_wb_exit_codes_from_shim() {
  eval "$(awk '
    /^    # Exit codes:/ { inblk=1; next }
    inblk && /^    _sh_rc=/ { exit }
    inblk && /^    #   [0-9]/ {
      line = $0
      sub(/^    #   /, "", line)
      if (match(line, /^[0-9]+/)) {
        code = substr(line, RSTART, RLENGTH)
        printf "_WB_EXIT_%s=%s\n", code, code
      }
    }
  ' "$_shim_src")"
  : "${_WB_EXIT_0:=0}"
  : "${_WB_EXIT_1:=1}"
}

# socat PTY; mock tty -> slave path; "$_shim" -e $3; on write-back prompt send
# $4 (default: y). Caller sets SUDO_EDITOR. Sets _rc, _err, _pty_prompt_count.
# $1 tmp suffix; $2 failure label; $3 target path; $4 optional answer.
_socat_answer_writeback() {
  _pty_suf=$1
  _pty_lbl=$2
  _pty_tgt=$3
  _pty_ans=${4:-y}

  _pty_link="${_tmp}/socat_pts_${_pty_suf}"
  _socat_in="${_tmp}/socat_in_${_pty_suf}"
  rm -f "$_pty_link" "$_socat_in"
  mkfifo "$_socat_in"

  _socat_out="${_tmp}/socat_out_${_pty_suf}.y"
  rm -f "$_socat_out"

  exec 3<>"$_socat_in"

  socat -d -d PTY,link="$_pty_link",raw,echo=0 - \
    >"$_socat_out" <"$_socat_in" 2>"${_tmp}/socat_stderr_${_pty_suf}.y" &
  _socat_pid=$!

  _tries=0
  while [ ! -e "$_pty_link" ] && [ "$_tries" -lt 50 ]; do
    sleep 0.05
    _tries=$((_tries+1))
  done

  _tty_slave=$(readlink "$_pty_link" 2>/dev/null || true)
  case "$_tty_slave" in
    /dev/*) ;;
    pts/*)  _tty_slave="/dev/$_tty_slave" ;;
    *)       _tty_slave="" ;;
  esac
  if [ -z "$_tty_slave" ]; then
    kill "$_socat_pid" 2>/dev/null || true
    exec 3>&-
    rm -f "$_socat_in" "$_pty_link"
    _fail_t "${_pty_lbl}: could not determine PTY slave" "link=$_pty_link"
    _rc=1
    _err=
    return 1
  fi

  mv "${_mockbin}/tty" "${_tmp}/tty.bak.${_pty_suf}"
  cat > "${_mockbin}/tty" << TTYEOF
#!/bin/sh
printf '%s\n' '${_tty_slave}'
TTYEOF
  chmod +x "${_mockbin}/tty"

  _errfile="${_tmp}/stderr_${_pty_suf}.y"
  rm -f "$_errfile"

  "$_shim" -e "$_pty_tgt" >/dev/null 2>"$_errfile" &
  _shim_pid=$!
  _sents=0

  _prompt_tries=0
  while [ "$_prompt_tries" -lt 200 ] && [ "$_sents" -eq 0 ]; do
    if grep -qF 'write back? [y/N]' "$_socat_out" 2>/dev/null; then
      printf '%s\r\n' "$_pty_ans" >&3
      _sents=1
      break
    fi
    sleep 0.05
    _prompt_tries=$((_prompt_tries+1))
  done

  if [ "$_sents" -eq 0 ]; then
    kill "$_shim_pid" 2>/dev/null || true
    kill "$_socat_pid" 2>/dev/null || true
    mv "${_tmp}/tty.bak.${_pty_suf}" "${_mockbin}/tty"
    exec 3>&-
    rm -f "$_socat_in" "$_pty_link"
    _fail_t "${_pty_lbl}: prompt not observed (timeout)" "socat_out=$_socat_out"
    _rc=1
    _err=$(cat "$_errfile" 2>/dev/null || true)
    return 1
  fi

  _wait_tries=0
  while kill -0 "$_shim_pid" 2>/dev/null && [ "$_wait_tries" -lt 200 ]; do
    sleep 0.05
    _wait_tries=$((_wait_tries+1))
  done

  if kill -0 "$_shim_pid" 2>/dev/null; then
    kill -KILL "$_shim_pid" 2>/dev/null || kill -TERM "$_shim_pid" 2>/dev/null || true
    kill "$_socat_pid" 2>/dev/null || true
    mv "${_tmp}/tty.bak.${_pty_suf}" "${_mockbin}/tty"
    exec 3>&-
    rm -f "$_socat_in" "$_pty_link"
    _fail_t "${_pty_lbl}: shim did not exit after answer injection" "PID=$_shim_pid"
    _rc=1
    _err=$(cat "$_errfile" 2>/dev/null || true)
    return 1
  fi

  if wait "$_shim_pid"; then _rc=0; else _rc=$?; fi
  _err=$(cat "$_errfile" 2>/dev/null || true)
  _pty_prompt_count=$(grep -cF 'write back? [y/N]' "$_socat_out" 2>/dev/null || printf '0')

  mv "${_tmp}/tty.bak.${_pty_suf}" "${_mockbin}/tty"
  exec 3>&-
  kill "$_socat_pid" 2>/dev/null || true
  rm -f "$_socat_in" "$_pty_link"
  return 0
}

# ---- Mock binaries (shared prelude) ---------------------------------------------------
_MOCKBIN_EDIT_SUITE=full
# shellcheck source=mock-edit-mode.sh
. "${_self_dir}/mock-edit-mode.sh"


# Minimal broker binary + metadata for bake only (broker IPC lives in broker/tests/broker-integration_test.sh).
cat > "${_mockbin}/edit-broker" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "${_mockbin}/edit-broker"

# EDIT_BROKER_METADATA for the shim: same sha:uid:gid:mode form as the Makefile.
_broker_metadata=$(_compute_metadata "${_mockbin}/edit-broker" 755 stat-ug) || {
  printf 'error: could not compute metadata for mock edit-broker\n' >&2
  exit 1
}

# ---- Build shim --------------------------------------------------------------------------

_version=$(cat "${_self_dir}/VERSION" 2>/dev/null) || _version='unknown'
_sep=$(printf '\001')
# Broker client bakes doas -u; mock doas runs as root, so use root here.
_eb_client="${_tmp}/edit-broker-client.sh"
sed \
  -e "s${_sep}@MAGIC@${_sep}${_eb_magic}${_sep}" \
  -e "s${_sep}@EDIT_BROKER_USER@${_sep}root${_sep}" \
  -e "s${_sep}@MAX_BROKER_BYTES@${_sep}${_eb_max}${_sep}" \
  -e "s${_sep}@BROKER_RESPONSE_TIMEOUT_S@${_sep}${_eb_to}${_sep}" \
  "${_repo_root}/lib/edit-broker-client.sh.in" > "$_eb_client"
_eb_client_meta=$(_compute_metadata "$_eb_client" 644 stat-ug) || {
  printf 'error: could not compute metadata for edit-broker-client.sh\n' >&2
  exit 1
}

_build_edit_test_shim "$_shim" "${_mockbin}/edit-broker" "$_broker_metadata"

# ---- Tests -------------------------------------------------------------------------------

_have_socat=0
command -v socat >/dev/null 2>&1 && _have_socat=1
if [ "$_have_socat" -eq 1 ] && [ "$_broker_kill0_usable" -eq 1 ]; then
  _pty_probe_link="${_tmp}/socat_probe_pts"
  rm -f "$_pty_probe_link"
  socat -d -d PTY,link="$_pty_probe_link",raw,echo=0 - \
    >/dev/null 2>"${_tmp}/socat_probe_stderr" &
  _pty_probe_pid=$!
  _tries=0
  while [ ! -e "$_pty_probe_link" ] && [ "$_tries" -lt 50 ]; do
    sleep 0.05
    _tries=$((_tries+1))
  done
  _tty_probe=$(readlink "$_pty_probe_link" 2>/dev/null || true)
  kill "$_pty_probe_pid" 2>/dev/null || true
  wait "$_pty_probe_pid" 2>/dev/null || true
  rm -f "$_pty_probe_link"
  case "$_tty_probe" in
    /dev/*|pts/*) ;;
    *) _have_socat=0 ;;
  esac
elif [ "$_have_socat" -eq 1 ]; then
  _have_socat=0
fi

printf '\n── Editor env: reject newline in SUDO_EDITOR (broker IPC header) ─\n'

_f="${_tmp}/wb_editor_nl_reject.txt"
printf 'original\n' > "$_f"
# $(printf '\n') alone is a bad test: POSIX strips trailing newlines from $().
_ed_nl=$(printf '%s\nX' "${_mockbin}/editor_modify")
_run_capture_streams env SUDO_EDITOR="$_ed_nl" "$_shim" -e "$_f"
_assert_exit "editor newline in path: exits 1" 1 "$_rc"
_assert_stderr_contains "editor newline in path: message" "newlines" "$_err"

printf '\n── Happy path: file content written back ───────────────────────────────────────\n'

# Mode 0644 (no x bits) exercises the umask-based mode-set path in the
# write-back body: the kernel produces the target mode as part of O_CREAT
# and chmod is not called. Regression for the mode preservation contract.
_f="${_tmp}/wb_happy.txt"
printf 'original\n' > "$_f"
chmod 0644 "$_f"
_orig_mode=$(_mode_of "$_f")
: > "$_chown_log"
_orig_uid_gid=$(_uid_gid_of "$_f")
_run_editor_mode "${_mockbin}/editor_modify" "$_f"
_assert_exit "write-back:  exits 0" 0 "$_rc"
_assert_file_content "write-back:  content" "$_f" "edited content"
_assert_file_mode "write-back:  mode preserved (umask path)" "$_f" "$_orig_mode"
# chown runs on the staging path before mv, so the logged path is $_wbtmp
# (random), not $_f. Verify owner:group was restored on some path.
if grep -qF "${_orig_uid_gid}	" "$_chown_log"; then
  _pass_t "write-back:  owner/group restored"
else
  _fail_t "write-back:  owner/group restored" "chown log: $(cat "$_chown_log")"
fi

printf '\n── Happy path: x-bit mode uses chmod fallback ──────────────────────────────────\n'

# Mode 0755 (x bits) forces the chmod fallback: umask cannot produce x bits
# through `open(O_CREAT, 0666)`, so the body runs `chmod $_mode $_wb` with
# the adjacent `[ ! -h "$_wb" ]` guard.
_f="${_tmp}/wb_happy_xbit.txt"
printf 'original\n' > "$_f"
chmod 0755 "$_f"
_orig_mode=$(_mode_of "$_f")
_run_editor_mode "${_mockbin}/editor_modify" "$_f"
_assert_exit "write-back xbit: exits 0" 0 "$_rc"
_assert_file_content "write-back xbit: content" "$_f" "edited content"
_assert_file_mode "write-back xbit: mode preserved (chmod path)" "$_f" "$_orig_mode"

printf '\n── Mtime-unchanged: no write-back ──────────────────────────────────────────────\n'

_f="${_tmp}/wb_skip.txt"
printf 'original\n' > "$_f"
_run_editor_mode "${_mockbin}/editor_noop" "$_f"
_assert_exit "mtime skip:  exits 0" 0 "$_rc"
_assert_stderr_contains "mtime skip:  unchanged notice" "unchanged" "$_err"
_assert_file_content "mtime skip:  unchanged" "$_f" "original"

printf '\n── New file: created and written ───────────────────────────────────────────────\n'

_f="${_tmp}/wb_new.txt"
[ ! -e "$_f" ] || rm -f "$_f"
: > "$_chown_log"
_run_editor_mode "${_mockbin}/editor_modify" "$_f"
_assert_exit "new file:    exits 0" 0 "$_rc"
_assert_file_content "new file:    content" "$_f" "edited content"
_assert_file_content "new file:    no owner/group restore" "$_chown_log" ""

printf '\n── New file unchanged: no write-back ───────────────────────────────────────────\n'

_f="${_tmp}/wb_new_skip.txt"
[ ! -e "$_f" ] || rm -f "$_f"
# editor_noop leaves the staged file untouched, so the target is not created.
_run_editor_mode "${_mockbin}/editor_noop" "$_f"
_assert_exit "new file skip: exits 0" 0 "$_rc"
_assert_stderr_contains "new file skip: unchanged notice" "unchanged" "$_err"
if [ ! -e "$_f" ]; then _pass_t "new file skip: target absent"
else _fail_t "new file skip: target absent" "unexpected file: $(ls -l "$_f" 2>/dev/null)"; fi

printf '\n── Multi-file: independent state per file ──────────────────────────────────────\n'

_f1="${_tmp}/wb_multi1.txt"
_f2="${_tmp}/wb_multi2.txt"
printf 'first\n'  > "$_f1"
printf 'second\n' > "$_f2"
_run_editor_mode "${_mockbin}/editor_modify" "$_f1" "$_f2"
_assert_exit "multi-file:  exits 0" 0 "$_rc"
_assert_file_content "multi-file:  file 1" "$_f1" "edited content"
_assert_file_content "multi-file:  file 2" "$_f2" "edited content"

printf '\n── Path resolution: relative paths match sudoedit(8) ───────────────────────────\n'

mkdir -p "${_tmp}/cdpath_cwd/sub" "${_tmp}/cdpath_alt/sub"
_f_cwd="${_tmp}/cdpath_cwd/sub/wb_cdpath.txt"
_f_alt="${_tmp}/cdpath_alt/sub/wb_cdpath.txt"
printf 'local\n'  > "$_f_cwd"
printf 'wrong\n' > "$_f_alt"
# Shim must ignore CDPATH when resolving relative paths to absolute form (cd -P).
_run_capture_streams env CDPATH="${_tmp}/cdpath_alt" \
  sh -c 'cd "$1" || exit 1; shift; exec "$@"' _ \
  "${_tmp}/cdpath_cwd" env SUDO_EDITOR="${_mockbin}/editor_modify" "$_shim" -e sub/wb_cdpath.txt
_assert_exit "path resolution: exits 0" 0 "$_rc"
_assert_file_content "path resolution: cwd-relative file edited" "$_f_cwd" "edited content"
_assert_file_content "path resolution: CDPATH tree unchanged" "$_f_alt" "wrong"

printf '\n── Write-back failure: non-writable target directory ───────────────────────────\n'
# Parent chmod 555 -> cannot create staging file -> inner exit 1 -> warn; target unchanged.
# Linux root ignores directory write DAC; skip when EUID 0.

if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "${_tmp}/wb_fail"
  printf 'original\n' > "${_tmp}/wb_fail/target.txt"
  chmod 555 "${_tmp}/wb_fail"
  _f="${_tmp}/wb_fail/target.txt"
  _run_editor_mode "${_mockbin}/editor_modify" "$_f"
  _assert_exit "wb-fail:     exits 1" 1 "$_rc"
  _assert_stderr_contains "wb-fail:     warns" "failed to write back" "$_err"
  _assert_file_content "wb-fail:     target unchanged" "$_f" "original"
else
  _skip_t "wb-fail: EUID 0 bypasses chmod 555 parent (cannot simulate)"
  _skip_t "wb-fail: stderr (skipped)"
  _skip_t "wb-fail: target unchanged (skipped)"
fi

printf '\n── Empty-file guard: non-interactive die path ──────────────────────────────────\n'
# editor_empty truncates; no TTY -> non-interactive empty-file die; target unchanged.

_f="${_tmp}/wb_empty_guard.txt"
printf 'original\n' > "$_f"
_without_tty _run_editor_mode "${_mockbin}/editor_empty" "$_f"
_assert_exit "empty guard: exits 1" 1 "$_rc"
_assert_stderr_contains "empty guard: message" "not writing empty file in non-interactive context" "$_err"
_assert_file_content "empty guard: target unchanged" "$_f" "original"

printf '\n── Diff-confirm: non-interactive die path ──────────────────────────────────────\n'

_f="${_tmp}/wb_diff_confirm_no_tty.txt"
printf 'original\n' > "$_f"
_without_tty _run_capture_streams env SUDO_SHIM_CONFIRM_DIFF=1 SUDO_EDITOR="${_mockbin}/editor_modify" "$_shim" -e "$_f"
_assert_exit "diff-confirm: exits 1" 1 "$_rc"
_assert_stderr_contains "diff-confirm: message" "diff confirmation enabled, but no interactive TTY is available" "$_err"
_assert_file_content "diff-confirm: target unchanged" "$_f" "original"

printf '\n── Interactive decline: _writeback_confirm returns 1 ───────────────────────────\n'
# /dev/shm file as fake TTY: prompt write, read gets EOF -> decline -> exit 0, target unchanged.

if _tty_file=$(mktemp /dev/shm/sudoedit_tty.XXXXXX 2>/dev/null); then
  mv "${_mockbin}/tty" "${_tmp}/tty.bak.interactive"
  cat > "${_mockbin}/tty" << TTYEOF
#!/bin/sh
printf '%s\n' '${_tty_file}'
TTYEOF
  chmod +x "${_mockbin}/tty"

  _f="${_tmp}/wb_decline.txt"
  printf 'original\n' > "$_f"
  _run_editor_mode "${_mockbin}/editor_empty" "$_f"
  mv "${_tmp}/tty.bak.interactive" "${_mockbin}/tty"
  rm -f "$_tty_file"

  _assert_exit "interactive decline: exits 0" 0 "$_rc"
  _assert_file_content "interactive decline: target unchanged" "$_f" "original"
else
  _skip_t "interactive decline: exits 0 (/dev/shm probe file unavailable)"
  _skip_t "interactive decline: target unchanged (/dev/shm probe file unavailable)"
fi

# ---- Editor attacks: post-editor security checks -----------------------------------------

printf '\n── Attack: swap tmpfile inode (invariant sweep) ────────────────────────────────\n'
_f="${_tmp}/wb_attack_swap_tmpfile.txt"
printf 'original\n' > "$_f"
_run_editor_attack swap_tmpfile "$_f"
_assert_exit "swap inode: exits 1" 1 "$_rc"
_assert_stderr_contains "swap inode: message" "tmpfile inode changed during editor session" "$_err"
_assert_file_content "swap inode: target unchanged" "$_f" "original"

printf '\n── Attack: tmpfile replaced with non-regular object ────────────────────────────\n'
_f="${_tmp}/wb_attack_tmpfile_non_regular.txt"
printf 'original\n' > "$_f"
_run_editor_attack tmpfile_non_regular "$_f"
_assert_exit "tmpfile non-regular: exits 1" 1 "$_rc"
# rm+mkdir changes dev:inode on POSIX; inode sweep often runs first (see swap_tmpfile).
# Type/digest arms cover defense-in-depth when inode baseline is absent.
case "$_err" in
  *"tmpfile inode changed during editor session"*)
    _pass_t "tmpfile non-regular: blocked (inode sweep)" ;;
  *"temporary file was replaced or is not a regular file"*)
    _pass_t "tmpfile non-regular: blocked (type guard)" ;;
  *"could not compute post-editor digest"*)
    _pass_t "tmpfile non-regular: blocked (digest)" ;;
  *)
    _fail_t "tmpfile non-regular: message" \
      "expected inode sweep, type guard, or digest abort; got: ${_err}" ;;
esac
_assert_file_content "tmpfile non-regular: target unchanged" "$_f" "original"

printf '\n── Attack: chmod directory (directory metadata) ────────────────────────────────\n'
_dir="${_tmp}/wb_attack_dirperm"
mkdir -p "$_dir"
chmod 0700 "$_dir"
_f="${_dir}/target.txt"
printf 'original\n' > "$_f"
_run_editor_attack chmod_dir "$_f" EDITOR_ATTACK_DIR="$_dir" EDITOR_ATTACK_DIR_MODE="0755"
_assert_exit "dir chmod: exits 1" 1 "$_rc"
_assert_stderr_contains "dir chmod: message" "directory permissions changed during editing" "$_err"
_assert_file_content "dir chmod: target unchanged" "$_f" "original"

printf '\n── Attack: replace directory inode during edit ─────────────────────────────────\n'
_dir="${_tmp}/wb_attack_dirreplace"
mkdir -p "$_dir"
_f="${_dir}/target.txt"
printf 'original\n' > "$_f"
_before_dir_inode=$(_inode_of "$_dir")
_run_editor_attack replace_dir "$_f" EDITOR_ATTACK_DIR="$_dir" EDITOR_ATTACK_TARGET_BASENAME="target.txt"
_assert_exit "dir replace: exits 1" 1 "$_rc"
_assert_stderr_contains "dir replace: message" "directory replaced during editing" "$_err"
_assert_file_content "dir replace: target unchanged" "$_f" "original"
_after_dir_inode=$(_inode_of "$_dir")
if [ "$_after_dir_inode" != "$_before_dir_inode" ]; then
  _pass_t "dir replace: parent inode changed"
else
  _fail_t "dir replace: parent inode changed" "before=$_before_dir_inode after=$_after_dir_inode"
fi

printf '\n── Attack: replace target with symlink (leaf check) ────────────────────────────\n'
_f="${_tmp}/wb_attack_symlink_target.txt"
printf 'original\n' > "$_f"
_run_editor_attack target_symlink "$_f" EDITOR_ATTACK_TARGET="$_f"
_assert_exit "target symlink: exits 1" 1 "$_rc"
_assert_stderr_contains "target symlink: message" "target became a symlink during editing" "$_err"
if [ -h "$_f" ] && [ ! -s "$_f" ]; then
  _pass_t "target symlink: target now symlink to empty (/dev/null)"
else
  _fail_t "target symlink: target unchanged type" "expected symlink to /dev/null; got: $(ls -l "$_f" 2>/dev/null || echo '<missing>')"
fi

# ---- chmod failures: seal tmpdir and metadata restore inside sh -c -----------------------

printf '\n── Attack: seal tmpdir fails (chmod 0500) ──────────────────────────────────────\n'
_f="${_tmp}/wb_attack_seal_tmpdir_fail.txt"
printf 'original\n' > "$_f"
_run_capture_streams env \
  MOCK_CHMOD_FAIL_MODE="0500" \
  SUDO_EDITOR="${_mockbin}/editor_modify" \
  "$_shim" -e "$_f"
_assert_exit "seal tmpdir fail: exits 1" 1 "$_rc"
_assert_stderr_contains "seal tmpdir fail: message" "could not seal tmpdir after editor exit" "$_err"
_assert_stderr_excludes "seal tmpdir fail: not tmpfile path" "could not seal tmpfile after editor exit" "$_err"
_assert_file_content "seal tmpdir fail: target unchanged" "$_f" "original"

printf '\n── Attack: mode op fails inside sh -c (pre-mv) ─────────────────────────────────\n'
# chmod runs on the staging path before mv. On failure, the body _fails,
# removes the staging file, and does not publish. $_f is untouched.
# Mode 0755 (x bits) forces the chmod fallback path; no-x modes use the
# umask optimization and bypass chmod entirely.
_f="${_tmp}/wb_attack_mode_op_fail.txt"
printf 'original\n' > "$_f"
chmod 0755 "$_f"
_orig_mode=$(_mode_of "$_f")
: > "$_chown_log"
_orig_uid_gid=$(_uid_gid_of "$_f")
_run_capture_streams env \
  MOCK_CHMOD_FAIL_MODE="$_orig_mode" \
  SUDO_EDITOR="${_mockbin}/editor_modify" \
  "$_shim" -e "$_f"
_assert_exit "mode op fail: exits 1" 1 "$_rc"
_assert_stderr_contains "mode op fail: message" "failed to write back" "$_err"
_assert_file_content "mode op fail: target unchanged" "$_f" "original"
_assert_file_mode "mode op fail: target mode unchanged" "$_f" "$_orig_mode"
if grep -qF "${_orig_uid_gid}	" "$_chown_log"; then
  _pass_t "mode op fail: chown ran on staging before chmod"
else
  _fail_t "mode op fail: chown expected before chmod" "$(cat "$_chown_log")"
fi

printf '\n── Attack: owner/group op fails inside sh -c (pre-mv) ──────────────────────────\n'
# chown runs on the staging path before mv. On failure, the body _fails and
# $_f is untouched.
_f="${_tmp}/wb_attack_owner_op_fail.txt"
printf 'original\n' > "$_f"
_orig_mode=$(_mode_of "$_f")
_orig_uid_gid=$(_uid_gid_of "$_f")
: > "$_chown_log"
_run_capture_streams env \
  MOCK_CHOWN_FAIL_OWNER_GROUP="$_orig_uid_gid" \
  SUDO_EDITOR="${_mockbin}/editor_modify" \
  "$_shim" -e "$_f"
_assert_exit "owner op fail: exits 1" 1 "$_rc"
_assert_stderr_contains "owner op fail: message" "failed to write back" "$_err"
_assert_file_content "owner op fail: target unchanged" "$_f" "original"
_assert_file_mode "owner op fail: target mode unchanged" "$_f" "$_orig_mode"
if grep -qF "${_orig_uid_gid}	" "$_chown_log"; then
  _pass_t "owner op fail: chown was attempted"
else
  _fail_t "owner op fail: chown expected to be attempted" "$(cat "$_chown_log")"
fi

# ---- Extracted write-back body (verbatim sh -c from shim) ---------------------------------
# Source: doasudo.in _doas /bin/sh -c '...' _ ... After _: cat ... _f.
# stdin = staged bytes (cat into held fd 5). Exit paths: shim table +
# _guard_wb_extract_exit_paths.

printf '\n── Extracted write-back body (replay shim fragment) ────────────────────────────\n'

_define_wb_exit_codes_from_shim

_wb_script="${_tmp}/writeback.extracted.sh"
_write_wb_fragment_from_shim "$_wb_script"

# Semicolon on exit 1 avoids matching exit 10.
_guard_wb_extract_exit_paths "exit ${_WB_EXIT_1};" "exit ${_WB_EXIT_1}; (sync with Exit codes table)"

# GNU -c vs BSD -f; must match shim _STAT_INODE_FLAG.
_wb_probe="${_tmp}/wb_stat_probe.txt"
printf '\n' > "$_wb_probe"
_wb_fd_fmt=$(_stat_fd_flag)

# Stub cksum: fixed digest for modeled exit 2.
_wb_sha_stub="${_mockbin}/wb_sha_stub"
cat > "$_wb_sha_stub" <<'EOF'
#!/bin/sh
printf '%s\n' 'CONST_DIGEST'
EOF
chmod +x "$_wb_sha_stub"
_wb_digest_ok='CONST_DIGEST'

if [ -z "$_wb_fd_fmt" ]; then
  _skip_t "post-mv swap detection: stat inode format unavailable"
  _skip_t "digest mismatch detection: stat inode format unavailable"
else

# --- Post-mv swap: target inode != $_iref after mv -> exit 1 ---
# Mock mv performs a real rename then simulates a racer swap at $_f: the
# body's post-mv [ stat -L "$_f" = $_iref ] detects the divergence and
# aborts without falsely reporting success. $_f is left in whatever state
# the racer produced (general UNIX property in an attacker-writable parent).

printf '\n── Post-mv swap detection (exit 1) ─────────────────────────────────────────────\n'

_f="${_tmp}/wb_post_mv_swap_target.txt"
_wb="${_tmp}/wb_post_mv_swap_staging.txt"
printf 'original\n' > "$_f"
chmod 0644 "$_f"

_mv_real=$(PATH="$_sys_path" command -v mv 2>/dev/null) || _mv_real=
[ -n "$_mv_real" ] || {
  printf 'error: mv not found for post-mv swap test\n' >&2
  exit 1
}

_mv_swap="${_mockbin}/mv_post_swap"
cat > "$_mv_swap" <<EOF
#!/bin/sh
_real_mv='${_mv_real}'
if [ "\${1:-}" = "--" ]; then shift; fi
_src=\${1:-}
_dst=\${2:-}
"\$_real_mv" -- "\$_src" "\$_dst" || exit 1
if [ -n "\${MV_EXIT2_TARGET:-}" ] && [ "\$_dst" = "\${MV_EXIT2_TARGET}" ]; then
  _bak="\${_dst}.post_swap.bak"
  "\$_real_mv" -- "\$_dst" "\$_bak" || exit 1
  printf 'attacker replacement\n' > "\$_dst" || exit 1
fi
exit 0
EOF
chmod +x "$_mv_swap"

rm -f "$_wb"
_run_writeback_fragment post_mv_swap "$_mv_swap" "$_wb_sha_stub" "$_wb_digest_ok" "$_wb" "$_f" 1

_assert_exit "post-mv swap: exits ${_WB_EXIT_1}" "${_WB_EXIT_1}" "$_rc"
_assert_file_content "post-mv swap: backup preserves edited bytes" "${_f}.post_swap.bak" "edited content"
_assert_file_content "post-mv swap: target shows racer replacement" "$_f" "attacker replacement"

# --- Digest mismatch before mv -> exit 1 ---

printf '\n── Digest mismatch detection (exit 1) ──────────────────────────────────────────\n'

_f="${_tmp}/wb_digest_mismatch_target.txt"
_wb="${_tmp}/wb_digest_mismatch_staging.txt"
printf 'original\n' > "$_f"

rm -f "$_wb"
_run_writeback_fragment digest_mismatch "${_mockbin}/mv" "$_mock_sha_tool" \
  "definitely-not-a-real-digest" "$_wb" "$_f"

_assert_exit "digest mismatch: exits ${_WB_EXIT_1}" "${_WB_EXIT_1}" "$_rc"
_assert_file_content "digest mismatch: target unchanged" "$_f" "original"

fi

# --- Regression: symlink pre-planted at $_wb must not divert write-back ---
#
# Pre-POSIX-noclobber body used `tee -- "$_wb"` guarded only by `[ ! -e ] &&
# [ ! -h ]`, so a racer replacing $_wb with a symlink between the check and
# tee caused root-follow-and-overwrite of the symlink's target. The current
# body opens fd 5 with `set -C` (O_CREAT|O_EXCL); a pre-existing symlink at
# $_wb causes open(2) to fail with EEXIST and the body exits ${_WB_EXIT_1}
# without touching the victim.
#
# This test is deterministic: the symlink is planted before the fragment
# runs, simulating a racer that has already won. No inode flag required.

printf '\n── Regression: pre-planted symlink at _wb blocks write-back ────────────────────\n'

_sym_victim="${_tmp}/symlink_regression_victim.txt"
_sym_wb="${_tmp}/symlink_regression_staging.txt"
_sym_tgt="${_tmp}/symlink_regression_target.txt"
printf 'VICTIM UNTOUCHED\n' > "$_sym_victim"
printf 'ORIGINAL TARGET\n' > "$_sym_tgt"
chmod 0644 "$_sym_tgt"

rm -f "$_sym_wb"
ln -s "$_sym_victim" "$_sym_wb"

_run_writeback_fragment symlink_preplant "${_mockbin}/mv" "$_wb_sha_stub" \
  "$_wb_digest_ok" "$_sym_wb" "$_sym_tgt"

_assert_exit "symlink preplant: exits ${_WB_EXIT_1}" "${_WB_EXIT_1}" "$_rc"
_assert_file_content "symlink preplant: victim unchanged" "$_sym_victim" "VICTIM UNTOUCHED"
_assert_file_content "symlink preplant: target unchanged" "$_sym_tgt" "ORIGINAL TARGET"

# --- Regression: permissive-parent racer plants symlink between chown and chmod ---
#
# Models the group-writable-parent attack: a racer with write access to the
# parent directory unlinks $_wb after chown succeeds and plants a symlink
# before the body's chmod fires. The pre-chmod adjacency check
# `[ ! -h "$_wb" ]` catches this in a single test-builtin syscall pair.
# Simulated by a chown wrapper that performs the planting itself; the body
# then finds $_wb is a symlink and aborts before chmod.
#
# Without the adjacency check, chmod would follow the symlink and change
# the mode of the victim file under root privilege.

if [ -z "$_wb_fd_fmt" ]; then
  _skip_t "racer between chown and chmod: stat inode format unavailable"
else

printf '\n── Regression: racer plants symlink between chown and chmod ────────────────────\n'

_racer_victim="${_tmp}/racer_between_chown_chmod_victim.txt"
_racer_wb="${_tmp}/racer_between_chown_chmod_staging.txt"
_racer_tgt="${_tmp}/racer_between_chown_chmod_target.txt"
printf 'VICTIM UNTOUCHED\n' > "$_racer_victim"
chmod 0600 "$_racer_victim"
printf 'ORIGINAL TARGET\n' > "$_racer_tgt"
chmod 0644 "$_racer_tgt"

_racer_chown="${_mockbin}/chown_plants_symlink"
cat > "$_racer_chown" <<EOF
#!/bin/sh
# chown -h -- owner path -> record, succeed, then swap \$path for a symlink
# to the victim. The body's next line is [ ! -h "\$_wb" ]; the check must fire.
_log='${_chown_log}'
if [ "\${1:-}" = "-h" ]; then shift; fi
if [ "\${1:-}" = "--" ]; then shift; fi
_owner_group=\${1:-}
_path=\${2:-}
printf '%s\t%s\n' "\${_owner_group}" "\${_path}" >> "\$_log"
rm -f -- "\$_path" || exit 1
ln -s '${_racer_victim}' "\$_path" || exit 1
exit 0
EOF
chmod +x "$_racer_chown"

# Swap in the planting chown for this test only.
mv "${_mockbin}/chown" "${_tmp}/chown.bak.racer"
cp "$_racer_chown" "${_mockbin}/chown"
chmod +x "${_mockbin}/chown"

rm -f "$_racer_wb"
_run_writeback_fragment racer_chown_chmod "${_mockbin}/mv" "$_wb_sha_stub" \
  "$_wb_digest_ok" "$_racer_wb" "$_racer_tgt"

mv "${_tmp}/chown.bak.racer" "${_mockbin}/chown"

_racer_victim_mode=$(_mode_of "$_racer_victim")

_assert_exit "racer chown/chmod: exits ${_WB_EXIT_1}" "${_WB_EXIT_1}" "$_rc"
_assert_file_content "racer chown/chmod: victim content unchanged" "$_racer_victim" "VICTIM UNTOUCHED"
if [ "$_racer_victim_mode" = "600" ]; then
  _pass_t "racer chown/chmod: victim mode unchanged (chmod blocked)"
else
  _fail_t "racer chown/chmod: victim mode changed" "expected 600, got $_racer_victim_mode"
fi
_assert_file_content "racer chown/chmod: target unchanged" "$_racer_tgt" "ORIGINAL TARGET"

fi

printf '\n── Interactive confirm: _writeback_confirm returns 0 ───────────────────────────\n'
# PTY + inject y (avoids seeding answers in a regular file). Skip without socat.

if [ "$_have_socat" -eq 1 ]; then
  printf '\n── Diff-confirm interactive accept/decline (PTY) ─────────────────────────────\n'

  export SUDO_SHIM_CONFIRM_DIFF=1
  _f="${_tmp}/wb_diff_confirm_accept.txt"
  printf 'original\n' > "$_f"
  export SUDO_EDITOR="${_mockbin}/editor_modify"
  if _socat_answer_writeback "diff_accept" "diff-confirm interactive accept" "$_f" y; then
    _assert_exit "diff-confirm interactive accept: exits 0" 0 "$_rc"
    _assert_pty_prompt_once "diff-confirm interactive accept: prompt observed once"
    _assert_file_content "diff-confirm interactive accept: target written" "$_f" "edited content"
  fi

  _f="${_tmp}/wb_diff_confirm_decline.txt"
  printf 'original\n' > "$_f"
  if _socat_answer_writeback "diff_decline" "diff-confirm interactive decline" "$_f" n; then
    _assert_exit "diff-confirm interactive decline: exits 0" 0 "$_rc"
    _assert_pty_prompt_once "diff-confirm interactive decline: prompt observed once"
    _assert_file_content "diff-confirm interactive decline: target unchanged" "$_f" "original"
  fi
  unset SUDO_SHIM_CONFIRM_DIFF
  unset SUDO_EDITOR

  _f="${_tmp}/wb_interactive_confirm_y.txt"
  printf 'original\n' > "$_f"
  export SUDO_EDITOR="${_mockbin}/editor_empty"
  if _socat_answer_writeback "empty" "interactive confirm" "$_f" y; then
    _assert_exit "interactive confirm: exits 0" 0 "$_rc"
    _assert_pty_prompt_once "interactive confirm: prompt observed once"
    if [ ! -s "$_f" ]; then
      _pass_t "interactive confirm: target now empty"
    else
      _fail_t "interactive confirm: target expected empty" "got $(ls -l "$_f" 2>/dev/null || echo '<missing>')"
    fi
  fi
  unset SUDO_EDITOR
else
  _skip_t "diff-confirm interactive accept: requires socat PTY (see Dockerfile)"
  _skip_t "diff-confirm interactive decline: requires socat PTY (see Dockerfile)"
  _skip_t "interactive confirm: requires socat PTY (see Dockerfile)"
fi

printf '\n── Editor failure + interactive confirm (mtime skip) ───────────────────────────\n'
# editor_fail -> prompt -> y; mtime unchanged -> skip write-back; target stays original.

if [ "$_have_socat" -eq 1 ]; then
  _f="${_tmp}/wb_editor_fail_interactive.txt"
  printf 'original\n' > "$_f"
  export SUDO_EDITOR="${_mockbin}/editor_fail"
  if _socat_answer_writeback "efail" "editor fail interactive" "$_f" y; then
    _assert_exit "editor fail interactive: exits 0" 0 "$_rc"
    _assert_pty_prompt_once "editor fail interactive: prompt observed once"
    _assert_stderr_contains "editor fail interactive: warns" "editor exited with status 1" "$_err"
    _assert_file_content "editor fail interactive: target unchanged" "$_f" "original"
  fi
  unset SUDO_EDITOR
else
  _skip_t "editor fail interactive: requires socat PTY (see Dockerfile)"
fi

printf '\n── Editor failure: non-zero exit, non-interactive ──────────────────────────────\n'
# No TTY -> non-interactive editor-failure die; exit 1; target unchanged.

_f="${_tmp}/wb_editor_fail.txt"
printf 'original\n' > "$_f"
_without_tty _run_editor_mode "${_mockbin}/editor_fail" "$_f"
_assert_exit "editor fail: exits 1" 1 "$_rc"
_assert_stderr_contains "editor fail: message" "editor exited with status 1" "$_err"
_assert_file_content "editor fail: target unchanged" "$_f" "original"

printf '\n── Editor failure + -n: _writeback_confirm dies unconditionally ─\n'
# -n forces die even if tty mock would set SUDO_TTY.

_f="${_tmp}/wb_editor_fail_n.txt"
printf 'original\n' > "$_f"
_run_editor_mode -n "${_mockbin}/editor_fail" "$_f"
_assert_exit "editor fail -n: exits 1" 1 "$_rc"
_assert_stderr_contains "editor fail -n: message" "editor exited with status 1" "$_err"
_assert_file_content "editor fail -n: target unchanged" "$_f" "original"

# ---- Summary -----------------------------------------------------------------------------

_tests_summary
