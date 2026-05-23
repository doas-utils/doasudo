#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Validates argument parsing, flag rejection, and command dispatch routing.
#
# The harness uses a mock `doas` to record the final argument vector.
# Assertions verify the structural contract (flag order, environment block,
# command boundary) rather than exact values for dynamically resolved fields
# like TTY or home directories.
#
# Dispatch paths validated:
# - Normal:  doas [flags] -- /usr/bin/env -- SUDO_*=... [PS1=...] <cmd> [args...]
# - Shell:   doas [flags] -- /usr/bin/env -- SUDO_*=... -l/-c "<escaped_cmd>"
# - Edit:    doas [flags] -- cat -- <file>  (no env wrapper)
#
# Usage:
#   sh parser_test.sh [path/to/doasudo.in]     # source mode (default)
#   sh parser_test.sh --built path/to/doasudo  # built mode
#
# Constraints:
# - Built mode requires a real `doas`; skips fixtures that need compilation.
# - Edit mode (-e) tests require an unreadable host file (e.g., /etc/shadow).
#   If none exist (when running as root), relevant assertions SKIP.

set -eu

_pass=0
_fail=0
_skip=0

# ---- Locate source -----------------------------------------------------------------------

_built=
case "${1:-}" in
  --built)
    [ $# -ge 2 ] || { printf 'error: --built requires a path argument\n' >&2; exit 1; }
    _shim_built="$2"
    _built=1
    ;;
  *)
    _self_dir=$(cd "$(dirname "$0")" && pwd)
    _shim_src="${1:-${_self_dir}/doasudo.in}"
    [ -f "$_shim_src" ] || { printf 'error: shim source not found: %s\n' "$_shim_src" >&2; exit 1; }
    ;;
esac

_tests_root=$(cd "$(dirname "$0")" && pwd)
_repo_root=$(CDPATH="" cd -P -- "$_tests_root/.." && pwd)
# shellcheck source=testlib.sh
. "$_tests_root/testlib.sh"
# shellcheck source=../utils/metadata-utils.sh
. "$_repo_root/utils/metadata-utils.sh"

( [ -f "$_repo_root/lib/shim-utils.sh" ] && [ -f "$_repo_root/lib/edit-broker-client.sh" ] ) \
  || (cd "$_repo_root" && "${MAKE:-make}" $(_make_s) lib/shim-utils.sh lib/edit-broker-client.sh) \
  || {
    printf 'error: run make lib/shim-utils.sh lib/edit-broker-client.sh from %s\n' "$_repo_root" >&2
    exit 1
  }

# ---- Scratch area ------------------------------------------------------------------------

_setup_mockbin
# Dirs under $_tmp become chmod 555; restore perms so EXIT can remove the tree.
trap '_chmod_rm_tmp' EXIT

_shim="${_tmp}/sudo"
_record="${_mockbin}/last_argv"   # doas argv: one argument per line

# Writable dummy under $_tmp: used for root-invoked -e and mutual-exclusion
# cases (only need a path; unreadability not required).
_edit_dummy="${_tmp}/edit_dummy"
: > "$_edit_dummy"

# ---- Edit mode target --------------------------------------------------------------------
#
# Unreadable host file -> `_doas cat -- <file>` and a useful record. If every
# candidate is readable (typical as root), _editfile stays empty and edit-flag
# cases SKIP.

_editfile=
for _candidate in /etc/shadow /etc/gshadow /etc/doas.conf /opt/local/etc/doas.conf; do
  [ -e "$_candidate" ] && [ ! -r "$_candidate" ] && { _editfile="$_candidate"; break; }
done

# ---- Mock binaries -----------------------------------------------------------------------

# mock doas: one argv element per line, exit 0. Appends (edit mode can call
# more than once); _run_parser_shim truncates before each case.
cat > "${_mockbin}/doas" << 'EOF'
#!/bin/sh
if [ "${1:-}" = "-L" ] && [ "${DOAS_MOCK_FAIL_L:-0}" = "1" ]; then
  exit 1
fi
for _a in "$@"; do printf '%s\n' "$_a"; done >> "$(dirname "$0")/last_argv"
exit 0
EOF
chmod +x "${_mockbin}/doas"

# mock editor: no-op (mtime unchanged -> no write-back).
cat > "${_mockbin}/editor" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${_mockbin}/editor"

# Empty tmpfile after sleep: mtime must beat the pre-edit snapshot (same-second
# edits skip write-back; empty file never triggers the guard).
cat > "${_mockbin}/editor_empty" << 'EOF'
#!/bin/sh
sleep 1
: > "$1"
EOF
chmod +x "${_mockbin}/editor_empty"

# Symlink required system binaries.
_sys_path="/usr/bin:/usr/sbin:/bin:/sbin"
_symlink_required_tools "$_mockbin" "$_sys_path" id awk stat cat tee mv chmod rm tty mktemp \
  || exit 1

# Mock id: stable passwd lookup. Without it, missing /etc/passwd (or getent)
# rows for the login name fail the suite before argv is recorded.
_mock_id_root() {
  rm -f "${_mockbin}/id"
  cat > "${_mockbin}/id" << 'EOF'
#!/bin/sh
case "${1:-}" in
  -ru)  printf '0\n' ;;
  -rg)  printf '0\n' ;;
  -run) printf 'root\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${_mockbin}/id"
}

_mock_id_real() {
  rm -f "${_mockbin}/id"
  cat > "${_mockbin}/id" << EOF
#!/bin/sh
PATH="$_sys_path"
export PATH
case "\${1:-}" in
  -ru)  id -ru ;;
  -rg)  id -rg ;;
  -run) id -un ;;
  -P)   shift; exec id -P "\$@" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${_mockbin}/id"
}

_mock_id_root
_setup_sha_tool "$_mockbin" "no SHA-256 checksum tool found in $_sys_path" >/dev/null \
  || exit 1

# getent mock: passwd only, /etc/passwd scan. Avoids real NSS (LDAP/SSSD)
# slowing or hanging tests.
cat > "${_mockbin}/getent" << 'EOF'
#!/bin/sh
set -eu
_subcmd="${1:-}"
_user="${2:-}"
case "$_subcmd" in
  passwd) ;;
  *) exit 2 ;;
esac
# First passwd match (colon-separated), getent-style.
awk -F: -v u="$_user" '$1==u { print; found=1; exit } END { exit found?0:1 }' /etc/passwd
EOF
chmod +x "${_mockbin}/getent"

MAKE=${MAKE:-make}
rm -f "$_repo_root/lib/shim-utils.sh"
(cd "$_repo_root" && "$MAKE" $(_make_s) lib/shim-utils.sh SHIM_PATH="${_mockbin}:${_sys_path}") \
  || { printf 'error: make lib/shim-utils.sh failed\n' >&2; exit 1; }

_utils_meta=$(_compute_metadata "$_repo_root/lib/shim-utils.sh" 644 stat-ug) || {
  printf 'error: could not compute UTILS_METADATA for lib/shim-utils.sh\n' >&2
  exit 1
}
_eb_client_meta=$(_compute_metadata "$_repo_root/lib/edit-broker-client.sh" 644 stat-ug) || {
  printf 'error: could not compute metadata for lib/edit-broker-client.sh\n' >&2
  exit 1
}

# $1=out $2=bindir $3=UTILS_METADATA $4=path/to/shim-utils.sh; rest -> build-test-shim.
_parser_build_shim() {
  _pbs_out="$1"
  _pbs_bindir="$2"
  _pbs_um="$3"
  _pbs_su="$4"
  shift 4
  _build_test_shim "$_repo_root" "$_shim_src" "$_pbs_out" "$_pbs_bindir" "$_pbs_um" \
    "$_version" "$_pbs_su" "${_repo_root}/lib/edit-broker-client.sh" "$_eb_client_meta" \
    "${_mockbin}/edit-broker" "" \
    "$@" || return
  chmod +x "$_pbs_out"
}

# ---- Build shim --------------------------------------------------------------------------

_sep=$(printf '\001')

if [ -n "$_built" ]; then
  [ -f "$_shim_built" ] || { printf 'error: built shim not found: %s\n' "$_shim_built" >&2; exit 1; }
  cp "$_shim_built" "$_shim"
  chmod +x "$_shim"
  _shim_min=
  _shim_rel=
  _relcwd=
else
  _version=$(cat "${_self_dir}/VERSION" 2>/dev/null) || _version='unknown'
  _bindir_std="${_mockbin}:${_sys_path}"
  _shim_utils_src="${_repo_root}/lib/shim-utils.sh"

  _parser_build_shim "$_shim" "$_bindir_std" "$_utils_meta" "$_shim_utils_src"

  _shim_edit="${_tmp}/sudo_edit"
  _parser_build_shim "$_shim_edit" "$_bindir_std" "$_utils_meta" "$_shim_utils_src" \
    --stub-edit-mode-root-guard

  _shim_edit_leaf="${_tmp}/sudo_edit_leaf"
  _parser_build_shim "$_shim_edit_leaf" "$_bindir_std" "$_utils_meta" "$_shim_utils_src" \
    --stub-edit-mode-root-guard \
    --stub-check-path-walk

  # Minimal / relative @BINDIR@ for _resolve_bin failures (source only; --built
  # SHIM_PATH is fixed). Dedicated libs match each shim's baked PATH.
  sed -e "s${_sep}@BINDIR@${_sep}${_mockbin}${_sep}" "$_repo_root/lib/shim-utils.sh.in" > "$_tmp/shim-utils.min.sh"
  _utils_meta_min=$(_compute_metadata "$_tmp/shim-utils.min.sh" 644 stat-ug) || {
    printf 'error: could not compute UTILS_METADATA for shim-utils.min.sh\n' >&2
    exit 1
  }

  _shim_min="${_tmp}/sudo_min"
  _parser_build_shim "$_shim_min" "${_mockbin}" "$_utils_meta_min" "${_tmp}/shim-utils.min.sh"

  _relcwd="${_tmp}/relcwd"
  mkdir -p "$_relcwd"
  ln -sf "${_mockbin}/doas" "${_relcwd}/doas"
  _bindir_rel=".:${_mockbin}:${_sys_path}"
  sed -e "s${_sep}@BINDIR@${_sep}${_bindir_rel}${_sep}" "$_repo_root/lib/shim-utils.sh.in" > "$_tmp/shim-utils.rel.sh"
  _utils_meta_rel=$(_compute_metadata "$_tmp/shim-utils.rel.sh" 644 stat-ug) || {
    printf 'error: could not compute UTILS_METADATA for shim-utils.rel.sh\n' >&2
    exit 1
  }

  _shim_rel="${_tmp}/sudo_rel"
  _parser_build_shim "$_shim_rel" "$_bindir_rel" "$_utils_meta_rel" "${_tmp}/shim-utils.rel.sh"
fi

# ---- Argv extraction helpers -------------------------------------------------------------
#
# One argv element per line. _run_parser_shim clears the file; normal dispatch
# is one doas call; parse the whole record, no sentinel.
#
# Edit mode: several doas calls; these helpers target the first block only.

# Flags before the first '--' line, space-joined.
_doas_flags() {
  awk '/^--$/{exit} {printf "%s%s", sep, $0; sep=" "} END{printf "\n"}' "$_record"
}

# First token after the first `--`: `/usr/bin/env` (_doas_exec) or command (_doas).
_after_dashdash() {
  awk '/^--$/{found=1; next} found{print; exit}' "$_record"
}

# After `SUDO_TTY=` on the _doas_exec path: `cmd` -> command only; `cmd_args` ->
# command plus args (space-joined). Requires `SUDO_TTY=` in the record.
_exec_after_tty() {
  grep -q '^SUDO_TTY=' "$_record" 2>/dev/null || {
    printf 'parser_test.sh: _exec_after_tty: no SUDO_TTY= in record\n' >&2
    exit 1
  }
  awk -v mode="$1" '
    /^SUDO_TTY=/        { tty=1; next }
    tty && /^PS1=/      { next }
    tty && mode=="cmd"  { print; exit }
    tty && mode=="cmd_args" { printf "%s%s", sep, $0; sep=" " }
    END { if (mode=="cmd_args") printf "\n" }
  ' "$_record"
}

# True when the record has a line exactly equal to $1.
_record_has() {
  awk -v t="$1" '$0==t{found=1; exit} END{exit found?0:1}' "$_record"
}

# Line after a lone `-c` (the `-c` string).
_c_string() {
  awk '/^-c$/{getline; print; exit}' "$_record"
}

# ---- Test framework ----------------------------------------------------------------------
# _assert_* -> pass/fail (exit, stderr, recorded argv).

_skip_src_only_msg='source-only (requires re-baked edit harness)'
_skip_built_path_msg='--built: SHIM_PATH is fixed'

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

_skip_resolve_bin() {
  _skip_t "_resolve_bin: missing id ($_skip_built_path_msg)"
  _skip_t "_resolve_bin: missing awk ($_skip_built_path_msg)"
  _skip_t "_resolve_bin: relative PATH entry ($_skip_built_path_msg)"
}

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

_assert_stderr_excludes() {
  case "$3" in
    *"${2}"*) _fail_t "${1}: stderr excludes '${2}'" "got: ${3}" ;;
    *)        _pass_t "${1}: stderr excludes '${2}'" ;;
  esac
}

_assert_doas_flags() {
  _got=$(_doas_flags)
  if [ "$_got" = "$2" ]; then _pass_t "${1}: doas flags"
  else _fail_t "${1}: doas flags" "expected '${2}', got '${_got}'"; fi
}

_assert_routed_via_env() {
  _got=$(_after_dashdash)
  if [ "$_got" = "/usr/bin/env" ]; then _pass_t "${1}: routed via /usr/bin/env"
  else _fail_t "${1}: routed via /usr/bin/env" "got: ${_got}"; fi
}

_assert_recorded_command() {
  _got=$(_exec_after_tty cmd)
  if [ "$_got" = "$2" ]; then _pass_t "${1}: command"
  else _fail_t "${1}: command" "expected '${2}', got '${_got}'"; fi
}

_assert_recorded_cmd_args() {
  _got=$(_exec_after_tty cmd_args)
  if [ "$_got" = "$2" ]; then _pass_t "${1}: cmd+args"
  else _fail_t "${1}: cmd+args" "expected '${2}', got '${_got}'"; fi
}

# Requires SUDO_* lines; optional `$2` adds `PS1=<value>` (SUDO_PS1). Mock doas
# records the full env argv (including PS1= when the shim sets it).
_assert_recorded_sudo_vars() {
  for _v in SUDO_UID SUDO_GID SUDO_USER SUDO_HOME SUDO_TTY; do
    if grep -q "^${_v}=" "$_record"
    then _pass_t "${1}: ${_v} present"
    else _fail_t "${1}: ${_v} present" "not found in record"
    fi
  done
  if [ -n "${2:-}" ]; then
    if awk -v v="$2" '$0=="PS1="v{found=1} END{exit found?0:1}' "$_record"; then
      _pass_t "${1}: PS1 passthrough (SUDO_PS1)"
    else
      _fail_t "${1}: PS1 passthrough (SUDO_PS1)" "expected PS1=${2}, not found in record"
    fi
  fi
}

_assert_record_has() {
  if _record_has "$2"; then _pass_t "${1}: record has '$2'"
  else _fail_t "${1}: record has '$2'" "not found in record"; fi
}

_assert_record_lacks() {
  if _record_has "$2"; then _fail_t "${1}" "unexpected '$2' in record"
  else _pass_t "${1}"; fi
}

# $1 = tool basename under ${_mockbin} (restored after run).
_assert_missing_tool() {
  mv "${_mockbin}/$1" "${_tmp}/$1.bak"
  _run_capture_streams "$_shim_min" "${_mockbin}/doas"
  mv "${_tmp}/$1.bak" "${_mockbin}/$1"
  _amt_lbl="_resolve_bin: missing $1 (minimal PATH)"
  _assert_exit "$_amt_lbl" 1 "$_rc"
  _assert_stderr_contains "$_amt_lbl" "$1 not found in SHIM_PATH" "$_err"
}

# $1 label; $2 expected exit; rest -> argv for main shim.
_run_shim_expect() {
  _rse_lbl="$1"; _rse_x="$2"; shift 2
  _rc=0; "$_shim" "$@" >/dev/null 2>&1 || _rc=$?
  _assert_exit "$_rse_lbl" "$_rse_x" "$_rc"
}

# Truncate record; run shim with SUDO_EDITOR. Stderr via temp file (not $())
# so $? stays visible. Mock doas is non-interactive.
_run_parser_shim() {
  : > "$_record"
  _run_capture_streams env SUDO_EDITOR="${_mockbin}/editor" "$@"
}

# ---- Tests -------------------------------------------------------------------------------

printf '\n── Pre-parse short-circuits ────────────────────────────────────────────────────\n'

_run_shim_expect "--help" 0 --help
_run_shim_expect "-h" 0 -h
_run_shim_expect "--version" 0 --version
_run_shim_expect "-V" 0 -V

printf '\n── No arguments ────────────────────────────────────────────────────────────────\n'

_run_shim_expect "no args" 1

printf '\n── Normal dispatch: doas flags ─────────────────────────────────────────────────\n'
#
# _doas_exec: doas [flags] -- /usr/bin/env -- SUDO_* ... cmd [args]

_root_home=$(awk -F: '$1=="root"{print $6; exit}' /etc/passwd 2>/dev/null)
[ -n "${_root_home:-}" ] || _root_home=/root

_run_parser_shim "$_shim" "${_mockbin}/doas"
_assert_exit               "no flags"           0  "$_rc"
_assert_doas_flags         "no flags"           ""
_assert_routed_via_env     "no flags"
_assert_recorded_sudo_vars "no flags"
_assert_recorded_command   "no flags"           "${_mockbin}/doas"

# SUDO_PS1 -> child PS1= in the env block.
_run_parser_shim env SUDO_PS1=my_ps1_prompt "$_shim" "${_mockbin}/doas"
_assert_exit               "SUDO_PS1 passthrough" 0 "$_rc"
_assert_recorded_sudo_vars "SUDO_PS1 passthrough" "my_ps1_prompt"
_run_parser_shim env SUDO_PS1='my ps1 prompt' "$_shim" "${_mockbin}/doas"
_assert_exit               "SUDO_PS1 with spaces passthrough" 0 "$_rc"
_assert_recorded_sudo_vars "SUDO_PS1 with spaces passthrough" "my ps1 prompt"

_run_parser_shim "$_shim" -n "${_mockbin}/doas"
_assert_doas_flags         "-n"                 "-n"
_assert_routed_via_env     "-n"
_assert_recorded_command   "-n"                 "${_mockbin}/doas"

_run_parser_shim "$_shim" -u root "${_mockbin}/doas"
_assert_doas_flags         "-u root"            "-u root"
_assert_routed_via_env     "-u root"
_assert_recorded_command   "-u root"            "${_mockbin}/doas"

_run_parser_shim "$_shim" -n -u root "${_mockbin}/doas"
_assert_doas_flags         "-n -u root"         "-n -u root"

_run_parser_shim "$_shim" --non-interactive "${_mockbin}/doas"
_assert_doas_flags         "--non-interactive"  "-n"

_run_parser_shim "$_shim" --user=root "${_mockbin}/doas"
_assert_doas_flags         "--user=root"        "-u root"

_run_parser_shim "$_shim" --user root "${_mockbin}/doas"
_assert_doas_flags         "--user root"        "-u root"

printf '\n── -H / --set-home ─────────────────────────────────────────────────────────────\n'

_run_parser_shim env HOME="${_tmp}/caller-home" "$_shim" -H "${_mockbin}/doas"
_assert_exit               "-H: exits 0"           0 "$_rc"
_assert_record_has         "-H: sets HOME"         "HOME=${_root_home}"
_assert_recorded_command   "-H: command"           "${_mockbin}/doas"

_run_parser_shim env HOME="${_tmp}/caller-home" "$_shim" --set-home "${_mockbin}/doas"
_assert_exit               "--set-home: exits 0"   0 "$_rc"
_assert_record_has         "--set-home: sets HOME" "HOME=${_root_home}"
_assert_recorded_command   "--set-home: command"   "${_mockbin}/doas"

printf '\n── Normal dispatch: command and arguments ──────────────────────────────────────\n'

_run_parser_shim "$_shim" "${_mockbin}/doas" arg1 arg2
_assert_recorded_cmd_args  "cmd with args"      "${_mockbin}/doas arg1 arg2"

_run_parser_shim "$_shim" -- "${_mockbin}/doas" arg1
_assert_doas_flags         "-- stops opts"      ""
_assert_recorded_cmd_args  "-- cmd args"        "${_mockbin}/doas arg1"

_run_parser_shim "$_shim" FOO=bar "${_mockbin}/doas"
_assert_exit               "VAR=value: exits 0" 0   "$_rc"
_assert_stderr_contains    "VAR=value: warned"  "not supported" "$_err"
_assert_recorded_command   "VAR=value: cmd"     "${_mockbin}/doas"

_run_parser_shim "$_shim" -- FOO=bar
_assert_exit               "-- FOO=bar: exits 1"    1 "$_rc"
_assert_stderr_contains    "-- FOO=bar: diagnostic" "variable assignment" "$_err"

printf '\n── Short bundles ───────────────────────────────────────────────────────────────\n'

_run_parser_shim "$_shim" -nu root "${_mockbin}/doas"
_assert_doas_flags         "-nu root"           "-n -u root"

_run_parser_shim "$_shim" -uroot "${_mockbin}/doas"
_assert_doas_flags         "-uroot bundled"     "-u root"

_run_shim_expect "-nV (bundled -V)" 0 -nV

printf '\n── -i dispatch ─────────────────────────────────────────────────────────────────\n'
#
# _exec_login_shell -> _doas_exec: passwd shell, always `-l`; with cmd:
# `-l -c "cd -- HOME && <escaped>"`.

_run_parser_shim "$_shim" -i
_assert_exit               "-i no cmd: exits 0"   0 "$_rc"
_assert_routed_via_env     "-i no cmd"
_assert_record_has         "-i no cmd: -l present" "-l"

_run_parser_shim "$_shim" -i echo hello
_assert_exit               "-i with cmd: exits 0" 0 "$_rc"
_assert_routed_via_env     "-i with cmd"
_assert_record_has         "-i with cmd: -l present" "-l"
_assert_record_has         "-i with cmd: -c present" "-c"
_cs=$(_c_string)
case "$_cs" in *"cd -- "*) _pass_t "-i with cmd: -c string has cd" ;;
               *)          _fail_t "-i with cmd: -c string has cd" "got: $_cs" ;; esac
case "$_cs" in *"echo"*)   _pass_t "-i with cmd: -c string has command" ;;
               *)          _fail_t "-i with cmd: -c string has command" "got: $_cs" ;; esac

printf '\n── -s dispatch ─────────────────────────────────────────────────────────────────\n'
#
# `-s`: `$SHELL` from env, no `-l`; with cmd: `-c "<escaped>"`.

_run_parser_shim "$_shim" -s
_assert_exit               "-s no cmd: exits 0"   0 "$_rc"
_assert_routed_via_env     "-s no cmd"
_assert_record_lacks       "-s no cmd: no -l" "-l"

_run_parser_shim "$_shim" -s echo hello
_assert_exit               "-s with cmd: exits 0" 0 "$_rc"
_assert_record_has         "-s with cmd: -c present" "-c"
_cs=$(_c_string)
case "$_cs" in *"echo"*) _pass_t "-s with cmd: -c string has command" ;;
               *)        _fail_t "-s with cmd: -c string has command" "got: $_cs" ;; esac

_run_parser_shim env SHELL=not/absolute "$_shim" -s
_assert_exit               "-s invalid \$SHELL: exits 1"    1 "$_rc"
_assert_stderr_contains    "-s invalid \$SHELL: diagnostic" "invalid shell in \$SHELL" "$_err"

printf '\n── Shell escaping in -i/-s ─────────────────────────────────────────────────────\n'

_run_parser_shim "$_shim" -s echo 'foo;bar'
_cs=$(_c_string)
case "$_cs" in *'foo\;bar'*) _pass_t "-s: semicolon escaped" ;;
               *)            _fail_t "-s: semicolon escaped" "got: $_cs" ;; esac

_run_parser_shim "$_shim" -s echo 'foo bar'
_cs=$(_c_string)
case "$_cs" in *'foo\ bar'*) _pass_t "-s: space escaped" ;;
               *)            _fail_t "-s: space escaped" "got: $_cs" ;; esac

_run_parser_shim "$_shim" -s echo '$HOME'
_cs=$(_c_string)
case "$_cs" in *'$HOME'*) _pass_t "-s: dollar unescaped (shell_mode)" ;;
               *)         _fail_t "-s: dollar unescaped (shell_mode)" "got: $_cs" ;; esac

_run_parser_shim "$_shim" -s echo ''
_assert_exit               "-s empty arg: exits 1"    1 "$_rc"
_assert_stderr_contains    "-s empty arg: diagnostic" "empty string" "$_err"

_nl=$(printf '\n_'); _nl="${_nl%_}"
_run_parser_shim "$_shim" -s echo "foo${_nl}bar"
_assert_exit               "-s newline arg: exits 1"     1 "$_rc"
_assert_stderr_contains    "-s newline arg: diagnostic"  "newline" "$_err"

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

printf '\n── Post-parse mutual exclusion ─────────────────────────────────────────────────\n'

_run_parser_shim "$_shim" -i -s "${_mockbin}/doas"
_assert_exit               "-i -s: exits 1"  1 "$_rc"
_assert_stderr_contains    "-i -s: diagnostic" "may not specify" "$_err"

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

printf '\n── -K / -k / -v ────────────────────────────────────────────────────────────────\n'

_run_parser_shim "$_shim" -K
_assert_exit               "-K alone: exits 0" 0 "$_rc"
_assert_record_has         "-K: doas -L called" "-L"

_run_parser_shim env DOAS_MOCK_FAIL_L=1 "$_shim" -K
_assert_exit               "-K doas -L fails: exits 1" 1 "$_rc"
_assert_stderr_contains    "-K doas -L fails: warning" "may not have been cleared" "$_err"

_run_parser_shim "$_shim" -K "${_mockbin}/doas"
_assert_exit               "-K with cmd: exits 1"    1 "$_rc"
_assert_stderr_contains    "-K with cmd: diagnostic" "may not be combined" "$_err"

_run_parser_shim "$_shim" -K -n
_assert_exit               "-K -n: exits 1" 1 "$_rc"
_run_parser_shim "$_shim" -K -u root
_assert_exit               "-K -u: exits 1" 1 "$_rc"
_run_parser_shim "$_shim" -K -k
_assert_exit               "-K -k: exits 1" 1 "$_rc"
_run_parser_shim "$_shim" -K -H
_assert_exit               "-K -H: exits 1" 1 "$_rc"
_assert_stderr_contains    "-K -H: diagnostic" "may not be combined" "$_err"
_assert_record_lacks       "-K -H: no doas -L" "-L"
_run_parser_shim "$_shim" -K -E
_assert_exit               "-K -E: exits 1" 1 "$_rc"
_assert_stderr_contains    "-K -E: diagnostic" "may not be combined" "$_err"
_assert_record_lacks       "-K -E: no doas -L" "-L"
_run_parser_shim "$_shim" -K -l
_assert_exit               "-K -l: exits 1" 1 "$_rc"
_assert_stderr_contains    "-K -l: diagnostic" "may not be combined" "$_err"
_assert_stderr_excludes    "-K -l: no list notice" "listing is not supported" "$_err"
_assert_record_lacks       "-K -l: no doas -L" "-L"
_run_parser_shim "$_shim" -l -K
_assert_exit               "-l -K: exits 1" 1 "$_rc"
_assert_stderr_contains    "-l -K: diagnostic" "may not be combined" "$_err"
_assert_stderr_excludes    "-l -K: no list notice" "listing is not supported" "$_err"
_assert_record_lacks       "-l -K: no doas -L" "-L"

_run_parser_shim "$_shim" -k
_assert_exit               "-k alone: exits 0" 0 "$_rc"
_assert_record_has         "-k alone: doas -L called" "-L"

_run_parser_shim env DOAS_MOCK_FAIL_L=1 "$_shim" -k
_assert_exit               "-k doas -L fails: exits 1" 1 "$_rc"
_assert_stderr_contains    "-k doas -L fails: warning" "may not have been cleared" "$_err"

_run_parser_shim "$_shim" -k "${_mockbin}/doas"
_assert_exit               "-k with cmd: exits 0"  0 "$_rc"
_assert_doas_flags         "-k with cmd: no flags" ""
_assert_routed_via_env     "-k with cmd"
_assert_recorded_command   "-k with cmd: command"  "${_mockbin}/doas"

_run_parser_shim "$_shim" -k -i
_assert_exit               "-k -i: exits 0" 0 "$_rc"
_assert_record_has         "-k -i: -i dispatch fired (-l present)" "-l"

_run_parser_shim "$_shim" -v
_assert_exit               "-v: exits 1"    1 "$_rc"
_assert_stderr_contains    "-v: diagnostic" "not supported" "$_err"

printf '\n── -l / --list listing notice ──────────────────────────────────────────────────\n'

# `-l` / `--list` -> _print_list_notice; stderr must share these substrings.
_listing_sub='listing is not supported'
_listing_hint='doas.conf'

_run_parser_shim "$_shim" -l
_assert_exit               "-l alone: exits 0" 0 "$_rc"
_assert_stderr_contains    "-l alone: listing diagnostic" "$_listing_sub" "$_err"
_assert_stderr_contains    "-l alone: doas.conf hint" "$_listing_hint" "$_err"

_run_parser_shim "$_shim" --list
_assert_exit               "--list alone: exits 0" 0 "$_rc"
_assert_stderr_contains    "--list alone: listing diagnostic" "$_listing_sub" "$_err"
_assert_stderr_contains    "--list alone: doas.conf hint" "$_listing_hint" "$_err"

_run_parser_shim "$_shim" -l "${_mockbin}/doas"
_assert_exit               "-l with cmd: exits 1" 1 "$_rc"
_assert_stderr_contains    "-l with cmd: listing diagnostic" "$_listing_sub" "$_err"

_run_parser_shim "$_shim" --list "${_mockbin}/doas"
_assert_exit               "--list with cmd: exits 1" 1 "$_rc"
_assert_stderr_contains    "--list with cmd: listing diagnostic" "$_listing_sub" "$_err"

printf '\n── --host warning paths ────────────────────────────────────────────────────────\n'

_run_parser_shim "$_shim" --host localhost "${_mockbin}/doas"
_assert_exit               "--host localhost: exits 0" 0 "$_rc"
_assert_stderr_contains    "--host localhost: warned"  "not supported" "$_err"
_assert_recorded_command   "--host localhost: cmd runs" "${_mockbin}/doas"

_run_parser_shim "$_shim" --host=localhost "${_mockbin}/doas"
_assert_exit               "--host=localhost: exits 0" 0 "$_rc"
_assert_stderr_contains    "--host=localhost: warned"  "not supported" "$_err"
_assert_recorded_command   "--host=localhost: cmd runs" "${_mockbin}/doas"

printf '\n── getent fallback path ────────────────────────────────────────────────────────\n'

mv "${_mockbin}/getent" "${_tmp}/getent.bak"
_run_parser_shim "$_shim" "${_mockbin}/doas"
_assert_exit               "no getent: exits 0"         0 "$_rc"
_assert_routed_via_env     "no getent: routed via env"
_assert_recorded_sudo_vars "no getent: SUDO_* present"
_assert_recorded_command   "no getent: command"         "${_mockbin}/doas"
mv "${_tmp}/getent.bak" "${_mockbin}/getent"

printf '\n── _resolve_bin failures ───────────────────────────────────────────────────────\n'

if [ -z "$_built" ]; then
  _assert_missing_tool id
  _assert_missing_tool awk

  _rel_doas=$(cd "$_relcwd" && PATH=".:${_mockbin}:${_sys_path}" command -v doas 2>/dev/null || true)
  case "$_rel_doas" in
    /*)
      _skip_t "_resolve_bin: doas relative PATH entry (shell resolves '.' to absolute path)"
      ;;
    *)
      _run_capture_streams sh -c 'cd "$1" && "$2" "$3"' _ "$_relcwd" "$_shim_rel" "${_mockbin}/doas"
      _assert_exit               "_resolve_bin: doas relative PATH entry" 1 "$_rc"
      _assert_stderr_contains    "_resolve_bin: doas relative PATH entry"   "doas not found in SHIM_PATH" "$_err"
      ;;
  esac
else
  _skip_resolve_bin
fi

printf '\n── Warned-and-ignored options ──────────────────────────────────────────────────\n'

for _opt in \
  "-A" "-S" "-E" \
  "--preserve-env" "--preserve-env=LIST" \
  "--askpass" "--stdin" \
  "--chdir=/tmp" "--chroot=/tmp" \
  "-R /tmp" "-D /tmp"
do
  _run_parser_shim "$_shim" $_opt "${_mockbin}/doas"
  _assert_exit               "$_opt: exits 0"  0 "$_rc"
  _assert_stderr_contains    "$_opt: warned"   "not supported" "$_err"
  _assert_recorded_command   "$_opt: cmd runs" "${_mockbin}/doas"
done

printf '\n── Silently ignored options ────────────────────────────────────────────────────\n'

for _opt in \
  -B -P -N "--bell" "--preserve-groups" "--no-update" \
  "-p prompt" "-C 3" "-T 10" "-U root" "-r role" "-t type" \
  "--prompt=p" "--close-from=3" "--command-timeout=10" \
  "--role=r" "--type=t" "--other-user=root"
do
  _run_parser_shim "$_shim" $_opt "${_mockbin}/doas"
  _assert_exit               "$_opt: exits 0"    0 "$_rc"
  _assert_stderr_excludes    "$_opt: no warning" "warning" "$_err"
  _assert_recorded_command   "$_opt: cmd runs"   "${_mockbin}/doas"
done

printf '\n── Fatal options ───────────────────────────────────────────────────────────────\n'

for _opt in -b -g "--background" "--group=wheel"; do
  _run_parser_shim "$_shim" $_opt "${_mockbin}/doas"
  _assert_exit               "$_opt: exits 1" 1 "$_rc"
done

_run_parser_shim "$_shim" -u '#1000' "${_mockbin}/doas"
_assert_exit               "-u #UID: exits 1"    1 "$_rc"
_assert_stderr_contains    "-u #UID: diagnostic" "not supported" "$_err"

_run_parser_shim "$_shim" --frobnicate "${_mockbin}/doas"
_assert_exit               "unknown long opt: exits 1" 1 "$_rc"
_assert_stderr_contains    "unknown long opt"          "unknown option" "$_err"

_run_parser_shim "$_shim" -Z "${_mockbin}/doas"
_assert_exit               "unknown short opt: exits 1" 1 "$_rc"
_assert_stderr_contains    "unknown short opt"          "unknown option" "$_err"

printf '\n── Missing arguments for value-taking options ──────────────────────────────────\n'

for _opt in \
  "--user" "-u" "--chdir" "--chroot" \
  "--prompt" "--close-from" "--command-timeout" \
  "--role" "--type" "--other-user" "--host" \
  "-p" "-C" "-T" "-U" "-r" "-t" "-R" "-D"
do
  _rc=0; "$_shim" "$_opt" >/dev/null 2>&1 || _rc=$?
  [ "$_rc" -ne 0 ] && _pass_t "$_opt missing arg: exits non-zero" \
    || _fail_t "$_opt missing arg: exits non-zero" "got exit 0"
done

# ---- Summary -----------------------------------------------------------------------------

_tests_summary
