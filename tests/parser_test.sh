#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# The harness uses a mock `doas` to record the final argument vector.
# Assertions verify the structural contract (flag order, environment block,
# command boundary) rather than exact values for dynamically resolved fields
# like TTY or home directories.
#
# Dispatch paths validated:
# - Normal:  doas [flags] -- /usr/bin/env -- SUDO_*=... [PS1=...] <cmd> [args...]
# - Shell:   doas [flags] -- /usr/bin/env -- SUDO_*=... -l/-c "<escaped_cmd>"
#
# Usage:
#   sh parser_test.sh [path/to/doasudo.in]     # source mode (default)
#   sh parser_test.sh --built path/to/doasudo  # built mode
#
# Constraints:
# - Built mode requires a real `doas`; skips fixtures that need compilation.

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
_assert_string_contains    "VAR=value: warned"  "not supported" "$_err"
_assert_recorded_command   "VAR=value: cmd"     "${_mockbin}/doas"

_run_parser_shim "$_shim" -- FOO=bar
_assert_exit               "-- FOO=bar: exits 1"    1 "$_rc"
_assert_string_contains    "-- FOO=bar: diagnostic" "variable assignment" "$_err"

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
_assert_string_contains    "-s invalid \$SHELL: diagnostic" "invalid shell in \$SHELL" "$_err"

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
_assert_string_contains    "-s empty arg: diagnostic" "empty string" "$_err"

_nl=$(printf '\n_'); _nl="${_nl%_}"
_run_parser_shim "$_shim" -s echo "foo${_nl}bar"
_assert_exit               "-s newline arg: exits 1"     1 "$_rc"
_assert_string_contains    "-s newline arg: diagnostic"  "newline" "$_err"

printf '\n── -K / -k / -v ────────────────────────────────────────────────────────────────\n'

_run_parser_shim "$_shim" -K
_assert_exit               "-K alone: exits 0" 0 "$_rc"
_assert_record_has         "-K: doas -L called" "-L"

_run_parser_shim env DOAS_MOCK_FAIL_L=1 "$_shim" -K
_assert_exit               "-K doas -L fails: exits 1" 1 "$_rc"
_assert_string_contains    "-K doas -L fails: warning" "may not have been cleared" "$_err"

_run_parser_shim "$_shim" -K "${_mockbin}/doas"
_assert_exit               "-K with cmd: exits 1"    1 "$_rc"
_assert_string_contains    "-K with cmd: diagnostic" "may not be combined" "$_err"

_run_parser_shim "$_shim" -K -n
_assert_exit               "-K -n: exits 1" 1 "$_rc"
_run_parser_shim "$_shim" -K -u root
_assert_exit               "-K -u: exits 1" 1 "$_rc"
_run_parser_shim "$_shim" -K -k
_assert_exit               "-K -k: exits 1" 1 "$_rc"
_run_parser_shim "$_shim" -K -H
_assert_exit               "-K -H: exits 1" 1 "$_rc"
_assert_string_contains    "-K -H: diagnostic" "may not be combined" "$_err"
_assert_record_lacks       "-K -H: no doas -L" "-L"
_run_parser_shim "$_shim" -K -E
_assert_exit               "-K -E: exits 1" 1 "$_rc"
_assert_string_contains    "-K -E: diagnostic" "may not be combined" "$_err"
_assert_record_lacks       "-K -E: no doas -L" "-L"
_run_parser_shim "$_shim" -K -l
_assert_exit               "-K -l: exits 1" 1 "$_rc"
_assert_string_contains    "-K -l: diagnostic" "may not be combined" "$_err"
_assert_string_excludes    "-K -l: no list notice" "listing is not supported" "$_err"
_assert_record_lacks       "-K -l: no doas -L" "-L"
_run_parser_shim "$_shim" -l -K
_assert_exit               "-l -K: exits 1" 1 "$_rc"
_assert_string_contains    "-l -K: diagnostic" "may not be combined" "$_err"
_assert_string_excludes    "-l -K: no list notice" "listing is not supported" "$_err"
_assert_record_lacks       "-l -K: no doas -L" "-L"

_run_parser_shim "$_shim" -k
_assert_exit               "-k alone: exits 0" 0 "$_rc"
_assert_record_has         "-k alone: doas -L called" "-L"

_run_parser_shim env DOAS_MOCK_FAIL_L=1 "$_shim" -k
_assert_exit               "-k doas -L fails: exits 1" 1 "$_rc"
_assert_string_contains    "-k doas -L fails: warning" "may not have been cleared" "$_err"

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
_assert_string_contains    "-v: diagnostic" "not supported" "$_err"

printf '\n── -l / --list listing notice ──────────────────────────────────────────────────\n'

# `-l` / `--list` -> _print_list_notice; stderr must share these substrings.
_listing_sub='listing is not supported'
_listing_hint='doas.conf'

_run_parser_shim "$_shim" -l
_assert_exit               "-l alone: exits 0" 0 "$_rc"
_assert_string_contains    "-l alone: listing diagnostic" "$_listing_sub" "$_err"
_assert_string_contains    "-l alone: doas.conf hint" "$_listing_hint" "$_err"

_run_parser_shim "$_shim" --list
_assert_exit               "--list alone: exits 0" 0 "$_rc"
_assert_string_contains    "--list alone: listing diagnostic" "$_listing_sub" "$_err"
_assert_string_contains    "--list alone: doas.conf hint" "$_listing_hint" "$_err"

_run_parser_shim "$_shim" -l "${_mockbin}/doas"
_assert_exit               "-l with cmd: exits 1" 1 "$_rc"
_assert_string_contains    "-l with cmd: listing diagnostic" "$_listing_sub" "$_err"

_run_parser_shim "$_shim" --list "${_mockbin}/doas"
_assert_exit               "--list with cmd: exits 1" 1 "$_rc"
_assert_string_contains    "--list with cmd: listing diagnostic" "$_listing_sub" "$_err"

printf '\n── --host warning paths ────────────────────────────────────────────────────────\n'

_run_parser_shim "$_shim" --host localhost "${_mockbin}/doas"
_assert_exit               "--host localhost: exits 0" 0 "$_rc"
_assert_string_contains    "--host localhost: warned"  "not supported" "$_err"
_assert_recorded_command   "--host localhost: cmd runs" "${_mockbin}/doas"

_run_parser_shim "$_shim" --host=localhost "${_mockbin}/doas"
_assert_exit               "--host=localhost: exits 0" 0 "$_rc"
_assert_string_contains    "--host=localhost: warned"  "not supported" "$_err"
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
      _assert_string_contains    "_resolve_bin: doas relative PATH entry"   "doas not found in SHIM_PATH" "$_err"
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
  _assert_string_contains    "$_opt: warned"   "not supported" "$_err"
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
  _assert_string_excludes    "$_opt: no warning" "warning" "$_err"
  _assert_recorded_command   "$_opt: cmd runs"   "${_mockbin}/doas"
done

printf '\n── Post-parse mutual exclusion ─────────────────────────────────────────────────\n'

_run_parser_shim "$_shim" -i -s "${_mockbin}/doas"
_assert_exit               "-i -s: exits 1"  1 "$_rc"
_assert_string_contains    "-i -s: diagnostic" "may not specify" "$_err"

printf '\n── Fatal options ───────────────────────────────────────────────────────────────\n'

for _opt in -b -g "--background" "--group=wheel"; do
  _run_parser_shim "$_shim" $_opt "${_mockbin}/doas"
  _assert_exit               "$_opt: exits 1" 1 "$_rc"
done

_run_parser_shim "$_shim" -u '#1000' "${_mockbin}/doas"
_assert_exit               "-u #UID: exits 1"    1 "$_rc"
_assert_string_contains    "-u #UID: diagnostic" "not supported" "$_err"

_run_parser_shim "$_shim" --frobnicate "${_mockbin}/doas"
_assert_exit               "unknown long opt: exits 1" 1 "$_rc"
_assert_string_contains    "unknown long opt"          "unknown option" "$_err"

_run_parser_shim "$_shim" -Z "${_mockbin}/doas"
_assert_exit               "unknown short opt: exits 1" 1 "$_rc"
_assert_string_contains    "unknown short opt"          "unknown option" "$_err"

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
