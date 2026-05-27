#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Shared scaffolding for parser-focused shell tests. Sourced by
# tests/parser_test.sh and tests/edit-mode-parser_test.sh; not executed
# directly. Source tests/testlib.sh first (_pass_t / _fail_t /
# _run_capture_streams), then this file.

# shellcheck shell=sh disable=SC2154

[ -z "${_testlib_parser_loaded:-}" ] || return 0
_testlib_parser_loaded=1

# ---- Mock id helpers ---------------------------------------------------

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

# ---- Shared globals (initialized by _parser_setup) ---------------------
#
# _repo, _tmp, _mockbin, _sys_path, _version, _utils_meta,
# _eb_client_meta, _shim_utils_src, _bindir_std, _sep, _edit_dummy,
# _editfile, _built, _shim_src, _shim, _record

# Parses CLI args ($1=doasudo.in path, optional --built flag), sources
# testlib.sh dependencies, creates mock env, builds base _shim and
# auxiliary shims (_shim_min, _shim_rel). Idempotent per process.
#
# Usage: _parser_setup "$@"
_parser_setup() {
  _here=$(CDPATH="" cd -P -- "$(dirname -- "$0")" && pwd)
  _repo=$(CDPATH="" cd -P -- "$_here/.." && pwd)

  # shellcheck source=../utils/metadata-utils.sh disable=SC1091
  . "$_here/../utils/metadata-utils.sh"

  _built=
  case "${1:-}" in
    --built)
      [ $# -ge 2 ] || { printf 'error: --built requires a path argument\n' >&2; exit 1; }
      _shim_built="$2"
      _built=1
      ;;
    *)
      _shim_src="${1:-${_here}/doasudo.in}"
      [ -f "$_shim_src" ] || { printf 'error: shim source not found: %s\n' "$_shim_src" >&2; exit 1; }
      ;;
  esac

  # shellcheck disable=SC2046,SC2235 # subshell: cd must not leak from _parser_setup
  [ -f "$_repo/lib/edit-broker-client.sh" ] \
    || (cd "$_repo" && "${MAKE:-make}" $(_make_s) lib/edit-broker-client.sh) \
    || {
      printf 'error: run make lib/edit-broker-client.sh from %s\n' "$_repo" >&2
      exit 1
    }

  _setup_mockbin
  trap '_chmod_rm_tmp' EXIT

  # shellcheck disable=SC2154 # _tmp from _setup_mockbin (testlib.sh)
  _shim="${_tmp}/sudo"
  _record="${_mockbin}/last_argv"

  _edit_dummy="${_tmp}/edit_dummy"
  : > "$_edit_dummy"

  # Unreadable host file for -e tests; empty if none found (typical as root).
  _editfile=
  for _candidate in /etc/shadow /etc/gshadow /etc/doas.conf /opt/local/etc/doas.conf; do
    [ -e "$_candidate" ] && [ ! -r "$_candidate" ] && { _editfile="$_candidate"; break; }
  done

  # Mock doas: record argv one element per line, exit 0.
  cat > "${_mockbin}/doas" << 'EOF'
#!/bin/sh
if [ "${1:-}" = "-L" ] && [ "${DOAS_MOCK_FAIL_L:-0}" = "1" ]; then
  exit 1
fi
for _a in "$@"; do printf '%s\n' "$_a"; done >> "$(dirname "$0")/last_argv"
exit 0
EOF
  chmod +x "${_mockbin}/doas"

  # Mock editor: no-op (mtime unchanged -> no write-back).
  cat > "${_mockbin}/editor" << 'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "${_mockbin}/editor"

  # Stub broker path + metadata for shim bake (parser tests never run broker IPC).
  cat > "${_mockbin}/edit-broker" << 'EOF'
#!/bin/sh
exit 0
EOF
  chmod 755 "${_mockbin}/edit-broker"
  _eb_broker_meta=$(_compute_metadata "${_mockbin}/edit-broker" 755 stat-ug) || {
    printf 'error: could not compute metadata for mock edit-broker\n' >&2
    exit 1
  }

  # Mock editor_empty: truncates file after a delay (triggers write-back).
  cat > "${_mockbin}/editor_empty" << 'EOF'
#!/bin/sh
sleep 1
: > "$1"
EOF
  chmod +x "${_mockbin}/editor_empty"

  _sys_path="/usr/bin:/usr/sbin:/bin:/sbin"
  _symlink_required_tools "$_mockbin" "$_sys_path" id awk stat cat tee mv chmod rm tty mktemp \
    || exit 1

  _mock_id_root

  _setup_sha_tool "$_mockbin" "no SHA-256 checksum tool found in $_sys_path" >/dev/null \
    || exit 1

  cat > "${_mockbin}/getent" << 'EOF'
#!/bin/sh
set -eu
_subcmd="${1:-}"
_user="${2:-}"
case "$_subcmd" in
  passwd) ;;
  *) exit 2 ;;
esac
awk -F: -v u="$_user" '$1==u { print; found=1; exit } END { exit found?0:1 }' /etc/passwd
EOF
  chmod +x "${_mockbin}/getent"

  MAKE=${MAKE:-make}
  rm -f "$_repo/lib/shim-utils.sh"
  # shellcheck disable=SC2046
  (cd "$_repo" && "$MAKE" $(_make_s) lib/shim-utils.sh SHIM_PATH="${_mockbin}:${_sys_path}") \
    || { printf 'error: make lib/shim-utils.sh failed\n' >&2; exit 1; }

  _utils_meta=$(_compute_metadata "$_repo/lib/shim-utils.sh" 644 stat-ug) || {
    printf 'error: could not compute UTILS_METADATA for lib/shim-utils.sh\n' >&2
    exit 1
  }
  _eb_client_meta=$(_compute_metadata "$_repo/lib/edit-broker-client.sh" 644 stat-ug) || {
    printf 'error: could not compute metadata for lib/edit-broker-client.sh\n' >&2
    exit 1
  }

  _sep=$(printf '\001')
  _bindir_std="${_mockbin}:${_sys_path}"
  _shim_utils_src="${_repo}/lib/shim-utils.sh"
  _version=$(cat "${_here}/VERSION" 2>/dev/null) || _version='unknown'

  if [ -n "$_built" ]; then
    [ -f "$_shim_built" ] || { printf 'error: built shim not found: %s\n' "$_shim_built" >&2; exit 1; }
    cp "$_shim_built" "$_shim"
    chmod +x "$_shim"
    _shim_min=
    _shim_rel=
    _relcwd=
  else
    _parser_build_shim "$_shim" "$_bindir_std" "$_utils_meta" "$_shim_utils_src"

    sed -e "s${_sep}@BINDIR@${_sep}${_mockbin}${_sep}" "$_repo/lib/shim-utils.sh.in" > "$_tmp/shim-utils.min.sh"
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
    sed -e "s${_sep}@BINDIR@${_sep}${_bindir_rel}${_sep}" "$_repo/lib/shim-utils.sh.in" > "$_tmp/shim-utils.rel.sh"
    _utils_meta_rel=$(_compute_metadata "$_tmp/shim-utils.rel.sh" 644 stat-ug) || {
      printf 'error: could not compute UTILS_METADATA for shim-utils.rel.sh\n' >&2
      exit 1
    }
    _shim_rel="${_tmp}/sudo_rel"
    _parser_build_shim "$_shim_rel" "$_bindir_rel" "$_utils_meta_rel" "${_tmp}/shim-utils.rel.sh"
  fi
}

# $1=out $2=bindir $3=UTILS_METADATA $4=path/to/shim-utils.sh; rest -> build-test-shim.
_parser_build_shim() {
  _pbs_out="$1"
  _pbs_bindir="$2"
  _pbs_um="$3"
  _pbs_su="$4"
  shift 4
  _build_test_shim "$_repo" "$_shim_src" "$_pbs_out" "$_pbs_bindir" "$_pbs_um" \
    "$_version" "$_pbs_su" "${_repo}/lib/edit-broker-client.sh" "$_eb_client_meta" \
    "${_mockbin}/edit-broker" "${_eb_broker_meta}" \
    "$@" || return
  chmod +x "$_pbs_out"
}

# ---- Argv extraction helpers -------------------------------------------

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
    printf 'parser_test: _exec_after_tty: no SUDO_TTY= in record\n' >&2
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

# ---- Assertion helpers -------------------------------------------------

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

# Requires SUDO_* lines; optional $2 adds PS1=<value> check (SUDO_PS1).
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

# Truncate record; run shim with SUDO_EDITOR. Stderr via temp file so $? stays visible.
_run_parser_shim() {
  : > "$_record"
  _run_capture_streams env SUDO_EDITOR="${_mockbin}/editor" "$@"
}
