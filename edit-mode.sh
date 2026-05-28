# ---- Edit-mode helpers -------------------------------------------------------------------
# Embedded into doasudo at build time when EDIT_MODE=1 (the default)

# Snippets for sudo -h default arm; doasudo.in declares empty defaults.
_EDIT_HELP_USAGE=$(cat <<'EOF'
  sudo -e [-n] [-u <user>] <file> [<file>...]
  sudoedit [-kKNn] [-u <user>] <file> [<file>...]
EOF
)
_EDIT_HELP_INVOCATION_NOTE=$(cat <<'EOF'

When invoked as 'sudoedit' or 'editas', implies -e and uses the invocation name
in diagnostics. 'editas' mirrors doas naming ("edit as [user]"); 'sudoedit' is
provided for sudo compatibility.
EOF
)
_EDIT_HELP_OPTION=$(cat <<EOF
  -e, --edit             Edit files via \$SUDO_EDITOR/\$VISUAL/\$EDITOR
                         (single absolute path only; see 'sudoedit --help').
EOF
)
_EDIT_HELP_NOTES=$(cat <<'EOF'

  -e/--edit and sudoedit
    Edit mode requires a broad, non-cmd-scoped doas rule.
    Restrictive cmd-scoped rules are not supported; granting edit mode
    under one requires adding unrestricted shell access; use doas
    directly with a narrowly scoped editor rule instead.
    Edit mode is not supported when invoked by root; edit the file
    directly instead.
EOF
)

_edit_mode_help() {
  cat <<EOF
Usage:
  ${0##*/} [-kKNn] [-u <user>] <file> [<file>...]
  ${0##*/} [-h | -V]

Edit files as another user using doas(1).
Equivalent to: sudo -e ...

Options:
  -u <user>, --user      Edit as <user> (username only; #UID not supported)
  -n, --non-interactive  Fail rather than prompt
  -K, --remove-timestamp Run 'doas -L', then exit
  -k, --reset-timestamp  Run 'doas -L', then exit (without a command)
  -h, --help             Show this help
  -V, --version          Show version

Editor precedence:
  \$SUDO_EDITOR, \$VISUAL, \$EDITOR, vi

  \$SUDO_EDITOR (and \$VISUAL/\$EDITOR) must be a single absolute path
  (no spaces, tabs, or flags). Use a wrapper script for editor options.
  Example: SUDO_EDITOR=/usr/local/bin/my-editor where the script contains:
    #!/bin/sh
    exec /usr/bin/vim -u NONE "\$@"

Edit-mode environment:
  SUDO_SHIM_CONFIRM_DIFF=1
    Show a unified diff and require confirmation before each write-back.
    Without an interactive TTY (or with -n), edit mode exits.
  SUDO_SHIM_EDIT_BROKER=1
    Enable the optional doas-based edit broker path.

The editor runs as the invoking user (not root). Temporary files are created
  in a directory owned by the invoking user and removed on exit. If root
  invokes edit mode, the shim exits; edit any file directly instead.

Restrictions:
  Symbolic links may not be edited.
  Files in a user-writable directory may not be edited.
  Device files may not be edited.

doas.conf requirement:
  Edit mode requires a broad, non-cmd-scoped doas rule, for example:
    permit :wheel

  Restrictive cmd-scoped rules are not supported; granting edit mode
  under one requires adding unrestricted shell access; use doas
  directly with a narrowly scoped editor rule instead.
EOF
}

edit_mode_info() { printf '%s: %s\n' "$_edit_cmd" "$*" >&2; }
edit_mode_die()  { printf '%s: %s\n' "$_edit_cmd" "$*" >&2; exit 1; }
edit_mode_tty_info() {
  if [ -n "$SUDO_TTY" ]; then
    printf '%s: %s\n' "$_edit_cmd" "$*" >"$SUDO_TTY"
  fi
}

# Non-exec variant of _doas_exec for edit mode, where the script must
# continue after each call. Omits SUDO_* (cat needs none).
# Must stay in sync with _doas_exec (see doas-flags-parity_test.sh).
#
# sudo(8) re-raises the signal that killed the child so the caller sees
# WIFSIGNALED. _doas_exec inherits this via exec. _doas cannot: the shell
# reduces signal death to a non-zero $?.
_doas() {
  if [ -n "$_user" ]; then
    "$_DOAS" ${flag_n:+"-n"} -u "$_user" -- "$@"
  else
    "$_DOAS" ${flag_n:+"-n"} -- "$@"
  fi
}

# Rejects root-invoked edit mode. The shim's edit path is for unprivileged
# users; root should edit files directly.
_edit_mode_root_guard() {
  if [ "$SUDO_UID" -eq 0 ]; then
    edit_mode_die "edit mode is not supported when invoked by root; edit the file directly"
  fi
}

# Walks every path component of directory $1, checking for symlinks and
# user-writable entries. On failure dies with $3 (symlink) or $4 (writable),
# appending "(edits preserved in $5)" when $5 is provided and setting
# _keep_tmpdir=1. $2 is the target file path, used in the writable message.
# When $1 is `/`, there are no components to walk; the target symlink check
# below covers the leaf.
_check_path_walk() {
  _cpw_walk="${1#/}"; _cpw_cur="/"
  _cpw_preserve="${5:+ (edits preserved in $5)}"
  while [ -n "$_cpw_walk" ]; do
    _cpw_comp="${_cpw_walk%%/*}"
    [ "$_cpw_walk" = "$_cpw_comp" ] && _cpw_walk= || _cpw_walk="${_cpw_walk#*/}"
    _cpw_cur="${_cpw_cur%/}/${_cpw_comp}"
    if [ -h "$_cpw_cur" ]; then
      [ -n "${5:-}" ] && _keep_tmpdir=1
      edit_mode_die "$3: $_cpw_cur (target: $2)${_cpw_preserve}"
    fi
    if [ -w "$_cpw_cur" ]; then
      [ -n "${5:-}" ] && _keep_tmpdir=1
      edit_mode_die "$4: $2${_cpw_preserve}"
    fi
  done
}

# $1 path, $2 edit_mode_die message. On failure closes fd 4 (tmpfile pin) then dies.
_check_regular_file() {
  if [ ! -h "$1" ] && [ -f "$1" ]; then
    return 0
  fi
  exec 4>&- 2>/dev/null || true
  edit_mode_die "$2"
}

# Restores tmpdir permissions and removes or preserves it.
#
# $1='on_fail': when _keep_tmpdir is non-zero, preserves the directory and
#   sets _writeback_failed=1; otherwise removes it. Absent or empty:
#   removes unconditionally.
#
# Reads: $_tmpdir, $_tmpdir_base, $_keep_tmpdir.
# Writes: $_tmpdir, $_writeback_failed.
_cleanup_tmpdir() {
  "$_CHMOD" -- 0700 "$_tmpdir" 2>/dev/null || true
  if [ "${1:-}" = "on_fail" ] && [ "$_keep_tmpdir" != "0" ]; then
    _writeback_failed=1
  else
    if [ -n "$_tmpdir" ]; then
      "$_RM" -rf "$_tmpdir"
    fi
  fi
  _tmpdir=
}

# Abandons write-back for the current file and advances to the next.
# $1='on_fail': sets _keep_tmpdir=1 and calls _cleanup_tmpdir on_fail,
#   leaving the tmpdir on disk for inspection and recording a write-back
#   failure. Mirrors the on_fail argument of _cleanup_tmpdir.
#   Absent or empty: clears _keep_tmpdir and calls _cleanup_tmpdir
#   unconditionally (clean discard; mtime-unchanged or user declined).
#
# Clearing _keep_tmpdir (to 0) in the clean path is required: the empty-file
# guard sets _keep_tmpdir=1 before calling _writeback_confirm so that
# a die() in non-interactive context causes the EXIT trap to preserve the
# tmpdir. When the user interactively declines instead, the tmpdir is
# cleanly removed by _cleanup_tmpdir and there is nothing left to
# preserve; leaving _keep_tmpdir=1 would cause the EXIT trap to return 1
# even though the session succeeded.
#
# The caller must follow this with 'continue' to advance the loop; keeping
# the continue at the call site makes the loop-control effect visible.
#
# Writes: _writeback_phase, _active_wbtmp, _keep_tmpdir.
_skip_writeback() {
  _writeback_phase=0; _active_wbtmp=
  if [ "${1:-}" = on_fail ]; then
    _keep_tmpdir=1
    _cleanup_tmpdir on_fail
  else
    _keep_tmpdir=0
    _cleanup_tmpdir
  fi
}

# Dies unless a TTY is available and -n is not set.
# $1: optional die message in non-interactive context.
_require_interactive_confirm() {
  [ -n "$SUDO_TTY" ] && [ -z "$flag_n" ] && return 0
  edit_mode_die "${1:-interactive confirmation required in non-interactive context}"
}

# Prompts the user for confirmation before an irreversible write-back action.
# $1: prompt message shown to the user (no trailing punctuation or newline).
# $2: optional die message for non-interactive context. Defaults to "$1 in
#     non-interactive context" when absent.
# $3: optional internal flag ("prechecked") to skip the
#     interactive precondition check when the caller has already enforced it.
#
# Returns 0 if the user confirms ('y'/'Y'), 1 if they decline.
# Dies when no TTY is available or -n is set: silently skipping an
# irreversible action in non-interactive context is the wrong default.
#
# Reads: $SUDO_TTY, $flag_n, $_edit_cmd (session-static; not listed in
# Reads/Writes header by convention).
_writeback_confirm() {
  [ "${3:-}" = "prechecked" ] || \
    _require_interactive_confirm "${2:-${1} in non-interactive context}"
  printf '%s: %s -- write back? [y/N] ' "$_edit_cmd" "$1" >"$SUDO_TTY"
  read -r _wbc_answer <"$SUDO_TTY" || _wbc_answer=
  case "$_wbc_answer" in
    [yY]*) return 0 ;;
    *)     return 1 ;;
  esac
}

# Shows a unified diff to $SUDO_TTY when available.
# $1: original target path.
# $2: staged edited path.
_show_diff_to_tty() {
  _sdt_old="$1"
  _sdt_new="$2"

  [ -n "$_DIFF" ] || {
    printf '%s: warning: no diff tool found (tried colordiff, diff)\n' "$_edit_cmd" >"$SUDO_TTY"
    return 0
  }

  [ -e "$_sdt_old" ] || _sdt_old=/dev/null

  if [ -n "$_PAGER" ]; then
    _diff "$_sdt_old" "$_sdt_new" | "$_PAGER" >"$SUDO_TTY" 2>/dev/null \
      || _diff "$_sdt_old" "$_sdt_new" >"$SUDO_TTY" 2>/dev/null \
      || true
  else
    _diff "$_sdt_old" "$_sdt_new" >"$SUDO_TTY" 2>/dev/null || true
  fi
}

# Optional diff-review gate before write-back.
# Returns 0 to continue, 1 when the user declines.
# Dies in non-interactive mode when enabled.
_confirm_writeback_with_diff() {
  _cwd_orig="$1"
  _cwd_new="$2"

  [ "${SUDO_SHIM_CONFIRM_DIFF:-0}" = "1" ] || return 0

  _require_interactive_confirm "diff confirmation enabled, but no interactive TTY is available"

  printf '%s: review changes for %s\n' "$_edit_cmd" "$_cwd_orig" >"$SUDO_TTY"
  _show_diff_to_tty "$_cwd_orig" "$_cwd_new"
  _writeback_confirm \
    "apply the above changes to '${_cwd_orig}'" \
    '' \
    prechecked
}

# Compares pre-editor directory metadata snapshot against the current state.
# $1: snapshot captured before the editor ran ('-' = stat failed at capture).
# $2: directory path.
# $3: target file path, used in diagnostic messages.
# $4: tmpdir path, used in diagnostic messages.
# Writes: _keep_tmpdir.
#
# Decision table (expected: inode should be the same, ctime can differ):
#   inode differs                    ->  directory replaced; hard abort.
#   mtime same,    mode differs      ->  chmod detected; hard abort.
#   mtime same,    mode same         ->  chown/xattr/ACL/SELinux; warn, continue.
#   mtime differs, mode same         ->  entry change only; proceed silently.
#   mtime differs, mode differs      ->  entry + permission change; hard abort.
#   mtime unavailable, mode differs  ->  degenerate fallback; hard abort.
#   mtime unavailable, mode same     ->  degenerate fallback; warn, continue.
#
# Field extraction from a 5-field tuple device:inode:ctime:mtime:mode:
#   device:inode  ${t%:*:*:*}
#   mtime         t2=${t%:*}; ${t2##*:}
#   mode          ${t##*:}
_check_metadata_state() {
  _cds_baseline="$1"
  _cds_dir="$2"
  _cds_f="$3"
  _cds_tmpdir="$4"

  [ "$_cds_baseline" = '-' ] && return 0

  _cds_current=$(_get_dir_meta "$_cds_dir") || {
    edit_mode_info "could not re-stat directory after editing; writable-dir re-check will run"
    return 0
  }

  [ "$_cds_current" = "$_cds_baseline" ] && return 0

  _cds_inode_baseline="${_cds_baseline%:*:*:*}"
  _cds_inode_current="${_cds_current%:*:*:*}"

  if [ "$_cds_inode_current" != "$_cds_inode_baseline" ]; then
    _keep_tmpdir=1
    edit_mode_die "directory replaced during editing (bind-mount or swap): $_cds_f (edits preserved in $_cds_tmpdir)"
  fi

  _cds_mtime_baseline="${_cds_baseline%:*}"
  _cds_mtime_baseline="${_cds_mtime_baseline##*:}"

  _cds_mtime_current="${_cds_current%:*}"
  _cds_mtime_current="${_cds_mtime_current##*:}"

  _cds_mode_baseline="${_cds_baseline##*:}"
  _cds_mode_current="${_cds_current##*:}"

  _cds_mode_changed() {
    [ "$_cds_mode_baseline" != '-' ] && [ "$_cds_mode_current" != '-' ] &&
    [ "$_cds_mode_current" != "$_cds_mode_baseline" ]
  }

  if [ "$_cds_mtime_baseline" != '-' ] && [ "$_cds_mtime_current" != '-' ]; then
    if [ "$_cds_mtime_current" = "$_cds_mtime_baseline" ]; then
      if _cds_mode_changed; then
        _keep_tmpdir=1
        edit_mode_die "directory permissions changed during editing: $_cds_f (edits preserved in $_cds_tmpdir)"
      else
        edit_mode_info "directory metadata changed during editing (chown/xattr/ACL likely); proceeding with write-back for '$_cds_f'"
      fi
    elif _cds_mode_changed; then
      _keep_tmpdir=1
      edit_mode_die "directory permissions changed during editing: $_cds_f (edits preserved in $_cds_tmpdir)"
    fi
  else
    if _cds_mode_changed; then
      _keep_tmpdir=1
      edit_mode_die "directory permissions changed during editing: $_cds_f (edits preserved in $_cds_tmpdir)"
    else
      edit_mode_info "directory ctime changed during editing (cause unknown; mtime unavailable); proceeding with write-back for '$_cds_f'"
    fi
  fi
}

_run_edit_mode() {
  _edit_cmd=${0##*/}
# Rejects -i and -s only when real edit mode is active.
# (_edit_cmd is a diagnostic label, not a proxy for flag_e.)
  [ -z "${flag_i:-}" ] || edit_mode_die "-i/--login is not valid in edit mode"
  [ -z "${flag_s:-}" ] || edit_mode_die "-s/--shell is not valid in edit mode"
  [ -z "${flag_H:-}" ] || edit_mode_die "-H/--set-home is not valid in edit mode"
  [ $# -gt 0 ] || die "-e/--edit requires at least one file argument"
  _edit_mode_root_guard

  # ---- Binary resolution ([boundary])-----------------------------------------------------
  #
  # Resolve all binaries here so a keepenv-poisoned PATH cannot substitute
  # a trojan at exec time. A poisoned stat could supply an attacker-chosen
  # mode directly to a privileged chmod.

  # dd, rm, mktemp, awk, wc: same resolution as the edit broker (shim-utils.sh).
  _resolve_edit_mode_tools || edit_mode_die 'shared utils missing from SHIM_PATH (dd, rm, mktemp, wc, cat)'

  # Edit-mode only (not used by the broker).
  _MV=$(_resolve_bin mv) || edit_mode_die 'mv not found in SHIM_PATH'
  _CHMOD=$(_resolve_bin chmod) || edit_mode_die 'chmod not found in SHIM_PATH'
  _CHOWN=$(_resolve_bin chown) || edit_mode_die 'chown not found in SHIM_PATH'
  _SLEEP=$(_resolve_bin sleep) || edit_mode_die 'sleep not found in SHIM_PATH'

  _DIFF=$(_resolve_bin colordiff optional)
  _DIFF_COLOR_FLAG=
  if [ -z "$_DIFF" ]; then
    _DIFF=$(_resolve_bin diff optional)
    if [ -n "$_DIFF" ] && "$_DIFF" --color=auto -u -- /dev/null /dev/null >/dev/null 2>&1; then
      _DIFF_COLOR_FLAG='--color=auto'
    fi
  fi
  _PAGER=$(_resolve_bin less optional)
  [ -n "$_PAGER" ] || _PAGER=$(_resolve_bin more optional)

  # shellcheck disable=SC2086,SC2317,SC2329
  _diff() { "$_DIFF" $_DIFF_COLOR_FLAG -u -- "$1" "$2" 2>/dev/null; }

  # Temp files hold privileged content; enforce a strict umask.
  umask 077

  # ---- Editor resolution -----------------------------------------------------------------

  _editor="${SUDO_EDITOR:-${VISUAL:-${EDITOR:-}}}"
  if [ -z "$_editor" ]; then
    _editor=$(_resolve_bin vi) || edit_mode_die "no editor found (SUDO_EDITOR/VISUAL/EDITOR unset and vi not in PATH)"
  fi
  # Single path only; no flags. Reject NL so broker IPC header cannot splice.
  case "$_editor" in
    *"${_TAB}"* | *"${_NL}"* | *\ *)
      edit_mode_die "SUDO_EDITOR/VISUAL/EDITOR must be a single path (no spaces, tabs, or newlines, no flags); use a wrapper script for options." ;;
    /*) ;;
    *)
      edit_mode_die "SUDO_EDITOR/VISUAL/EDITOR must be an absolute path, got: '${_editor}'" ;;
  esac
  [ -x "$_editor" ] || edit_mode_die "editor not found or not executable: '${_editor}'"

  _use_edit_broker="${SUDO_SHIM_EDIT_BROKER:-0}"
  if [ "$_use_edit_broker" = "1" ]; then
    _is_abs_path "$_EDIT_BROKER_PATH" || edit_mode_die "broker path must be absolute: '$_EDIT_BROKER_PATH'"
    _check_meta_str "$_EDIT_BROKER_METADATA" || edit_mode_die "broker metadata unset or invalid (expected '<sha256hex>:<uid>:<gid>:<mode>')"
    _check_file_meta "$_EDIT_BROKER_PATH" "$_EDIT_BROKER_METADATA" || edit_mode_die "broker binary metadata mismatch"

    [ -r "$_EDIT_BROKER_CLIENT" ] || edit_mode_die "missing ${_EDIT_BROKER_CLIENT} (incomplete installation)"
    _check_meta_str "$_EDIT_BROKER_CLIENT_METADATA" || edit_mode_die "broker client metadata unset or invalid (expected '<sha256hex>:<uid>:<gid>:<mode>')"
    _check_file_meta "$_EDIT_BROKER_CLIENT" "$_EDIT_BROKER_CLIENT_METADATA" || edit_mode_die "broker client metadata mismatch"
    # shellcheck disable=SC1090
    . "$_EDIT_BROKER_CLIENT"
  elif [ "$_use_edit_broker" != "0" ]; then
    edit_mode_die "SUDO_SHIM_EDIT_BROKER must be 0 or 1"
  fi

  # ---- Per-file state (all scalars; reset at top of each iteration) ----------------------
  _tmpdir=; _tmpfile=; _active_wbtmp=
  _digest_pre_editor='-'; _digest_post_editor=
  _tmpfile_unchanged=0
  _keep_tmpdir=0; _writeback_phase=0; _tmpdir_base=

  # Cumulative exit status: set to 1 when any file write-back fails.
  _writeback_failed=0

  # ---- EXIT trap -------------------------------------------------------------------------
  #
  # Registered once before the loop. All variables it references are scalars
  # that always reflect the current iteration's state. _tmpdir is cleared at
  # the end of each successful iteration, making the trap a no-op on normal
  # exits. Preserved tmpdirs (_keep_tmpdir=1) are also cleared; they remain
  # on disk and need no further trap handling.
  #
  # Two guards cover orthogonal failure windows:
  #
  # _writeback_phase=1 (signal kill mid-check, before sh -c):
  #   A kill inside a post-editor security check may arrive before that check
  #   sets _keep_tmpdir=1. Without this guard the trap would see
  #   _keep_tmpdir=0 and silently remove the tmpdir, losing the user's edits.
  #   _active_wbtmp is still empty here (sh -c has not run), so no
  #   root-owned file exists yet.
  #
  # _active_wbtmp (signal kill mid sh -c):
  #   A kill while sh -c runs means the *) cleanup arm never executed.
  #   The trap can only warn; it cannot invoke doas rm from a trap handler.
  #   A root-owned _wbtmp may remain on disk and must be removed by an
  #   administrator. SIGKILL cannot be trapped, so this gap is irreducible.

  # shellcheck disable=SC2317,SC2329
  _edit_mode_exit_cleanup() {
    if [ -n "${_active_wbtmp:-}" ] && [ -e "$_active_wbtmp" ]; then
      printf "%s: write-back interrupted; temporary file left behind: '%s'; please remove it manually\n" \
        "${_edit_cmd}" "$_active_wbtmp" >&2
    fi
    if [ "${_writeback_phase:-0}" = "1" ] && [ "${_keep_tmpdir:-0}" = "0" ]; then
      _keep_tmpdir=1
      printf "%s: interrupted during write-back; edits preserved in %s\n" \
        "${_edit_cmd}" "${_tmpdir}" >&2
    fi
    if [ -d "${_tmpdir:-}" ]; then
      "$_CHMOD" -- 0700 "$_tmpdir" 2>/dev/null || true
    fi
    [ "${_keep_tmpdir:-0}" = "1" ] && exit 1
    if [ -n "$_tmpdir" ]; then
      "$_RM" -rf "$_tmpdir"
    fi
  }

  trap '_edit_mode_exit_cleanup' EXIT
  trap 'exit 1' HUP INT TERM QUIT

  # ---- Main loop -------------------------------------------------------------------------

  for _f in "$@"; do

    # Reset per-file scalars; prevent state leaks between files.
    _tmpdir=; _tmpfile=; _active_wbtmp=
    _digest_pre_editor='-'; _digest_post_editor=
    _tmpfile_unchanged=0
    _keep_tmpdir=0; _writeback_phase=0; _tmpdir_base=

    # ---- Filename validation -------------------------------------------------------------

    case "$_f" in
      '')
        edit_mode_die "empty filename is not valid" ;;
      *"${_TAB}"* | *"${_NL}"*)
        # Tab or newline corrupts the path-component walk.
        edit_mode_die "filename contains tab or newline, cannot process safely: '$_f'" ;;
    esac

    # ---- Absolutize via cd -P ------------------------------------------------------------
    #
    # Resolves relative paths and .. components so the writable-directory
    # check sees the real parent. The filename component is left unchanged;
    # [ -h ] checks it below. %/ on _abs_dir prevents //foo.

    case "$_f" in
      */*) _fdir="${_f%/*}"; _fdir="${_fdir:-/}" ;;
      *) _fdir="." ;;
    esac
    # cd must not resolve via CDPATH; matches sudoedit(8).
    _abs_dir=$(CDPATH="" cd -P -- "$_fdir" 2>/dev/null && pwd -P) \
      || edit_mode_die "cannot resolve directory for: $_f"
    _f="${_abs_dir%/}/${_f##*/}"

    # ---- Device file check ---------------------------------------------------------------

    if [ -b "$_f" ] || [ -c "$_f" ]; then
      edit_mode_die "device special files may not be edited: $_f"
    fi

    # ---- Writable-directory / intermediate-symlink walk ----------------------------------
    #
    # Covers every path component: a symlink swap at any level requires write
    # access to that component's parent. A [ -h ] check on each component
    # catches any symlink placed there in the race window after cd -P.
    # Skipped when _f is directly under /.
    _dir="${_f%/*}"; _dir="${_dir:-/}"
    _check_path_walk "$_dir" "$_f" \
      "symlink in path component (possible swap attack)" \
      "editing files in a writable directory is not permitted"

    # ---- Symlink check on target ---------------------------------------------------------

    [ -h "$_f" ] && edit_mode_die "editing symbolic links is not permitted: $_f"

    # ---- Basename / trailing-slash check -------------------------------------------------

    case "$_f" in
      */) edit_mode_die "not a regular file: $_f" ;;
    esac
    _base="${_f##*/}"
    [ -n "$_base" ] || edit_mode_die "internal error: empty basename for path: $_f"

    # ---- Create tmpdir -------------------------------------------------------------------
    #
    # TMPDIR is user-controlled; mktemp rejects non-writable values.
    # Tab or newline in the path corrupts path-component walks.

    _tmpdir=$("$_MKTEMP" -d "${TMPDIR:-/tmp}/sudoedit.XXXXXX") \
      || edit_mode_die "no writable temporary directory found"
    case "$_tmpdir" in
      *"${_TAB}"* | *"${_NL}"*)
        "$_RM" -rf "$_tmpdir" || true
        edit_mode_die "TMPDIR produces a path containing tab or newline; aborting" ;;
    esac
    _tmpdir_base="${_tmpdir##*/}"
    _tmpfile="${_tmpdir}/${_base}"

    # ---- Held-fd construction ([fd-anchor], [seal-verify]) -------------------------------
    #
    # The workspace ($_tmpdir) is 0700 invoker-owned, limiting cross-UID influence.
    # The shim must still ensure that same-UID processes cannot subvert the
    # shim's privileged operations in this window (fd 4, chmod, privileged
    # reads) to write unintended content or targets.
    #
    # `set -C; command exec 4> "$_tmpfile"` atomically creates the file
    # (O_CREAT|O_EXCL|O_WRONLY|O_TRUNC). Fd 4 pins the inode until released.
    # Pre-planted files or symlinks fail with EEXIST.
    #
    # Note: `set -C` stays active through the rest of edit_mode; no `>` redirect
    # on a regular file exists downstream, and the shell exits at loop end.
    #
    # `command` strips exec's special-builtin status so a redirection failure
    # returns to the shell instead of terminating dash. Errors are not silenced
    # (2>/dev/null) because doing so on an `exec` permanently breaks stderr for
    # all later diagnostic functions.
    #
    # Apply `chmod 0400` via `/dev/fd/4` when supported to lock the inode the
    # fd refers to. Otherwise, fall back to the irreducible minimum: adjacent
    # `test` and path `chmod`. Post-chmod inode checks verify the fallback; the
    # only residual risk here is a same-UID self-DoS on the tmpfile.
    #
    # Once $_tmpfile is sealed, unprivileged reads use `exec 3<` to read via an
    # open fd rather than a path in argv. Privileged reads use a single
    # `_doas /bin/sh -c` so the check, open, and read stay entirely within
    # one process, avoiding external path argv.

    set -C
    command exec 4> "$_tmpfile" \
      || edit_mode_die "tmpfile already exists or creation failed: $_tmpfile"
    _pre_dev_inode=$(_get_dev_inode "$_tmpfile") || {
      exec 4>&-
      edit_mode_die "could not stat tmpfile after create: $_tmpfile"
    }
    _pre_fd_inode=$(_get_fd_inode /dev/fd/4)
    case $_pre_fd_inode in
      -) ;;
      *:*) _pre_dev_inode=$_pre_fd_inode ;;
      *) [ "${_pre_dev_inode##*:}" = "$_pre_fd_inode" ] || _pre_fd_inode=- ;;
    esac
    if [ "$_pre_fd_inode" = '-' ]; then
      _check_regular_file "$_tmpfile" "tmpfile is not a regular file before seal: $_tmpfile"
      "$_CHMOD" -- 0400 "$_tmpfile" 2>/dev/null || {
        exec 4>&-
        edit_mode_die "could not seal tmpfile at 0400: $_tmpfile"
      }
    else
      "$_CHMOD" -- 0400 /dev/fd/4 2>/dev/null || {
        exec 4>&-
        edit_mode_die "could not seal tmpfile at 0400 via fd: $_tmpfile"
      }
    fi
    _post_dev_inode=$(_get_dev_inode "$_tmpfile") || {
      exec 4>&-
      edit_mode_die "could not stat tmpfile after seal: $_tmpfile"
    }
    [ "$_post_dev_inode" = "$_pre_dev_inode" ] || {
      exec 4>&-
      edit_mode_die "tmpfile inode changed between create and seal: $_tmpfile"
    }
    if [ -e "$_f" ]; then
      _check_regular_file "$_f" "not a regular file: $_f"
      if [ -r "$_f" ]; then
        command exec 3< "$_f" || { exec 4>&-; edit_mode_die "failed to read existing file $_f"; }
        "$_CAT" <&3 >&4 || { exec 3<&-; exec 4>&-; edit_mode_die "failed to read existing file $_f"; }
        exec 3<&-
      else
        edit_mode_tty_info "reading restricted file '$_f'"
        # shellcheck disable=SC2016
        _doas /bin/sh -c '
          _cat=$1; shift
          _f=$1
          [ ! -h "$_f" ] && [ -f "$_f" ] || exit 1
          command exec 3< "$_f" || exit 1
          exec "$_cat" <&3
        ' _ "$_CAT" "$_f" >&4
      fi || {
        exec 4>&-
        edit_mode_die "failed to read existing file $_f"
      }
    fi
    exec 4>&-

    # ---- Pre-editor digest baseline ------------------------------------------------------
    #
    # Captured at mode 0400 with no write fds open, the strongest available
    # guarantee. SHA-256 tool output (sha256sum/sha256/shasum -a 256) is stored in full;
    # the byte count strengthens the comparison at no extra cost.
    # On failure the sentinel '-' is stored; the pre-editor check skips it.
    # New files get a baseline too: any write before the editor is detected.

    _digest_pre_editor=$(_digest "$_tmpfile") || _digest_pre_editor='-'

    # ---- Capture pre-editor state --------------------------------------------------------

    _mtime=$(_get_mtime "$_tmpfile")

    # device:inode of the tmpfile at creation, compared in the invariant sweep.
    _tmpfile_inode=$(_get_dev_inode "$_tmpfile") || _tmpfile_inode='-'

    # device:inode:ctime:mtime:mode of the leaf parent directory, captured
    # atomically. All five fields are compared at write-back by parameter
    # expansion; see the directory check below.
    _dir_meta=$(_get_dir_meta "$_dir") || _dir_meta='-'

    # Capture original owner:group and mode before the editor runs.
    _orig_owner_group=
    _orig_mode=
    if [ -e "$_f" ]; then
      # shellcheck disable=SC2086
      _orig_ugm=$(_get_ugm "$_f") || _orig_ugm=
      _orig_owner_group="${_orig_ugm%:*}"
      [ "$_orig_owner_group" != "$_orig_ugm" ] || _orig_owner_group=
      _orig_mode="${_orig_ugm##*:}"
      [ "$_orig_mode" != "$_orig_ugm" ] || _orig_mode=
    fi
    case "$_orig_owner_group" in
      ''|*[!0-9:]*|*:*:*)
        if [ -n "$_orig_owner_group" ]; then
          edit_mode_info "unrecognized owner/group '${_orig_owner_group}' for '${_f}'; owner/group will not be restored"
        fi
        _orig_owner_group= ;;
    esac

    # Original mode of $_f, for write-back chmod.
    if _is_octal "$_orig_mode"; then
      # Strip setuid (4000), setgid (2000), and sticky (1000) bits.
      # The invoking user has modified the file content, so the
      # original elevated-privilege bits can no longer be assumed safe.
      _orig_mode=$(printf '%o' "$(( 0${_orig_mode} & 0777 ))")
    elif [ -n "$_orig_mode" ]; then
      edit_mode_info "unrecognized mode '${_orig_mode}' for '${_f}'; file written at mode 0600"
      _orig_mode=
    fi

    # ---- Pre-editor content check --------------------------------------------------------
    #
    # Compares the current digest against the baseline captured at 0400, no write
    # fds. Both run while the file is sealed; no write window exists between them.
    # A mismatch is a hard abort: modified content would be written back as
    # root without the user having reviewed it.

    if [ "$_digest_pre_editor" != '-' ]; then
      _pec_digest_now=$(_digest "$_tmpfile") || {
        edit_mode_info "could not checksum tmpfile before editor launch: '$_tmpfile'; proceeding"
        _digest_pre_editor='-'
      }
      if [ "$_digest_pre_editor" != '-' ] && [ "$_pec_digest_now" != "$_digest_pre_editor" ]; then
        edit_mode_die "tmpfile content changed before editor launched: '$_tmpfile' (source: '$_f')"
      fi
    fi

    # ---- Restore 0600 for the editor -----------------------------------------------------
    #
    # Deferred until after the pre-editor check; moving it earlier opens the
    # write window the check is designed to close. The irreducible residual is
    # between this chmod and the editor exec (unavoidable in portable shell).

    "$_CHMOD" -- 0600 "$_tmpfile" \
      || edit_mode_die "could not restore mode on tmpfile: $_tmpfile"

    # ---- Invoke editor -------------------------------------------------------------------

    _editor_rc=0
    if [ "$_use_edit_broker" = "1" ]; then
      if _run_edit_broker "$_tmpfile"; then
        # Broker output can be written within the same timestamp granularity as
        # the pre-editor snapshot; prevents file changed but same mtime checks
        # from suppressing broker write-back.
        _mtime='-'
      else
        _keep_tmpdir=1
        edit_mode_die "broker path failed for '${_f}' (edited copy preserved in ${_tmpdir})"
      fi
    else
      "$_editor" "$_tmpfile" || _editor_rc=$?
      _digest_post_editor=$(_digest "$_tmpfile") || _digest_post_editor=
    fi

    # ---- Post-editor hardening ([seal-verify], [path-trust]) -----------------------------
    #
    # Capture a digest snapshot immediately at editor return, then seal with
    # chmod 0400/0500. The digest is passed to the privileged write-back body,
    # which re-digests the staged write-back file and aborts before mv on
    # mismatch.
    #
    # chmod 0400/0500 is a hard barrier for other UIDs and narrows the
    # same-UID race surface. Owners can chmod back, so correctness still depends
    # on the post-seal inode/type/path checks and digest verify-before-mv.
    # Both seals remain required: without 0400, in-place overwrite stays easy;
    # without 0500, unlink+recreate weakens inode continuity checks.
    if [ -z "$_digest_post_editor" ]; then
      edit_mode_info "could not compute post-editor digest for '${_f}'; write-back skipped for '${_f}' (edited copy in ${_tmpdir}: integrity unverified)"
      _skip_writeback on_fail
      continue
    fi

    "$_CHMOD" -- 0400 "$_tmpfile" 2>/dev/null || {
      edit_mode_info "could not seal tmpfile after editor exit; write-back skipped for '${_f}' (edited copy in ${_tmpdir}: integrity unverified)"
      _skip_writeback on_fail
      continue
    }
    "$_CHMOD" -- 0500 "$_tmpdir" 2>/dev/null || {
      edit_mode_info "could not seal tmpdir after editor exit; write-back skipped for '${_f}' (edited copy in ${_tmpdir}: integrity unverified)"
      _skip_writeback on_fail
      continue
    }
    if [ "$_editor_rc" -ne 0 ]; then
      edit_mode_info "editor exited with status ${_editor_rc}"
      # No _keep_tmpdir=1 bracket and no $2 die-message here, unlike the
      # empty-file guard. When the editor exits non-zero the user may not
      # have made any edits at all (crash before first write); preserving
      # the tmpdir on every non-interactive editor failure would be noisy
      # and the content is untrustworthy. The empty-file case is different:
      # the editor ran to completion and produced a deliberate empty edit,
      # which is worth preserving. The asymmetry is intentional.
      _writeback_confirm "editor exited with status ${_editor_rc}" || {
        _skip_writeback
        continue
      }
    fi

    # Set _writeback_phase=1 before the post-editor security checks so a
    # signal kill mid-check preserves the tmpdir via the EXIT trap even
    # if _keep_tmpdir has not yet been set. Each hard-aborting check sets
    # _keep_tmpdir=1 before dying, so the guard matters only in the narrow
    # kill window inside the check itself.
    # Exception: _skip_writeback (called from the empty-file and editor-failure
    # paths above) resets _writeback_phase=0 before returning; those paths
    # hold no edits worth preserving and the guard is not needed.
    _writeback_phase=1

    # $$ in _wbtmp avoids collisions across concurrent sessions and aids
    # diagnostics if the file is left behind. Predictability is not
    # exploitable: pre-creating it requires write access to _dir, which
    # _check_path_walk already refuses.
    _wbtmp="${_dir}/.${_tmpdir_base}.${$}"

    # Set _active_wbtmp before the sh -c so the EXIT trap can warn if a
    # signal kill arrives while sh -c is running and a root-owned _wbtmp
    # may have been created but not yet renamed or removed. Cleared before
    # the write-back case is evaluated; after sh -c returns, _wbtmp either
    # no longer exists (mv renamed it for exits 0/2/3; rm attempted for
    # exit 1) or the *) arm handles it directly.
    _active_wbtmp="$_wbtmp"

    # ---- Invariant sweep ([seal-verify]) -------------------------------------------------
    #
    # Re-stat the tmpfile and compare device:inode to the baseline captured
    # at creation. Any replacement during the editor session is caught before
    # any privileged operation runs. The sweep runs after the seal, so a
    # passing record cannot be further substituted.
    #
    # _tmpfile_inode is '-' only when stat failed at capture. If re-stat fails,
    # we abort write-back for this file and preserve the tmpdir.

    if [ "$_tmpfile_inode" != '-' ]; then
      _current_inode=$(_get_dev_inode "$_tmpfile") || {
        edit_mode_info "could not re-stat tmpfile after seal; inode check skipped, write-back skipped for '${_f}' (edits preserved in ${_tmpdir})"
        _skip_writeback on_fail
        continue
      }
      if [ "$_current_inode" != "$_tmpfile_inode" ]; then
        edit_mode_info "tmpfile inode changed during editor session (possible swap attack): '${_tmpfile}'; write-back skipped for '${_f}' (edits may be lost; tmpdir preserved for inspection: ${_tmpdir})"
        _skip_writeback on_fail
        continue
      fi
    fi

    # ---- Write-back ----------------------------------------------------------------------

    # Symlink re-check: the user may have swapped the target during editing.
    # The writable-directory check eliminates this for the leaf parent.
    # _keep_tmpdir=1 preserves edits; die exits and the EXIT trap cleans up.
    if [ -h "$_f" ]; then
      _keep_tmpdir=1
      edit_mode_die "target became a symlink during editing: $_f (edits preserved in $_tmpdir)"
    fi

    # Directory metadata check.
    _check_metadata_state "$_dir_meta" "$_dir" "$_f" "$_tmpdir"

    # Writable-dir re-check: fallback when directory stat failed at capture,
    # and a second guard for bind-mount races the metadata check may miss.
    # Catches any symlink planted since the pre-edit walk.
    _check_path_walk "$_dir" "$_f" \
      "symlink appeared in path component during editing" \
      "directory became user-writable during editing" \
      "$_tmpdir"

    # Skip write-back and report if the editor did not modify the file. An
    # editor that modifies and reverts within one second does not trigger
    # write-back; this matches sudo(8).
    _after_mtime=$(_get_mtime "$_tmpfile")
    if [ "$_tmpfile_unchanged" = "1" ] || { [ "$_mtime" != "-" ] && [ "$_mtime" = "$_after_mtime" ]; }; then
      edit_mode_info "'$_f' unchanged"
      _skip_writeback
      continue
    fi

    # Empty-file guard: intentional truncation is always achievable via an
    # external privileged command; accidental truncation may be irreversible.
    # _writeback_confirm prompts when a TTY is available and -n is not set,
    # and dies in non-interactive context.
    #
    # _keep_tmpdir is set before the call so that if _writeback_confirm dies
    # (non-interactive path) the EXIT trap preserves the tmpdir. The editor
    # ran to completion and produced an empty file; a deliberate edit the
    # user never got to confirm. Discarding it silently on exit would lose it.
    # On the interactive decline path _skip_writeback resets _keep_tmpdir,
    # so no tmpdir is left behind there.
    if [ -f "$_tmpfile" ] && [ ! -s "$_tmpfile" ] && { [ ! -e "$_f" ] || [ -s "$_f" ]; }; then
      _keep_tmpdir=1
      _writeback_confirm \
        "'${_f}' is now empty" \
        "not writing empty file in non-interactive context: '${_f}' (edited copy preserved in ${_tmpdir})" || {
        _skip_writeback
        continue
      }
      _keep_tmpdir=0
    fi

    _confirm_writeback_with_diff "$_f" "$_tmpfile" || {
      _skip_writeback
      continue
    }

    # ---- Pre-write-back tmpfile guard and fd pinning ([fd-anchor], [seal-verify]) --------
    #
    # Before opening fd 3, verify $_tmpfile is a regular file and not a symlink.
    # Because [ -f ] is true for symlinks pointing to regular files, [ -h ] is
    # required to catch path swaps.
    #
    # Open $_tmpfile as fd 3 after the seal and sweep. Redirecting stdin from
    # fd 3 (`<&3`) pins the data source before doas runs. While doas closes
    # file descriptors 3 and above, stdin (fd 0) remains open and inode-bound,
    # allowing privileged sh -c to read without a path.

    if [ ! -f "$_tmpfile" ] || [ -h "$_tmpfile" ]; then
      edit_mode_info "temporary file was replaced or is not a regular file: '${_tmpfile}'; skipping write-back for '${_f}' (edits lost; tmpdir preserved for inspection: ${_tmpdir})"
      _skip_writeback on_fail
      continue
    fi

    exec 3< "$_tmpfile"

    # ---- Privileged write-back ([fd-anchor], [seal-verify], [boundary]) ------------------
    #
    # Defends against races in dirname($_f) including unlink, symlink-swaps,
    # and inode reuse. Layers (a)-(e) execute within a privileged `sh -c`.
    #
    # (a) `set -C; command exec 5> "$_wb"` (O_CREAT|O_EXCL) ensures pre-existing
    #     paths fail with EEXIST. `command` prevents redirection errors from
    #     exiting the shell; fd 5 pins the inode for all subsequent operations.
    #
    # (b) `_ref=$(stat -L /dev/fd/5)` retrieves the inode from the open file
    #     description, not the path, preventing swap-poisoning. Without /dev/fd
    #     support, path `stat -L "$_wb"` falls back after a `[ ! -h ]` check.
    #
    # (c) fd 5 remains open until the final post-mv check. Immediately before
    #     mv, `stat -L "$_wb"` must still match $_ref (and the digest). Since
    #     unlink+recreate yields a new inode, this detects interference before
    #     the rename(2) atomic swap.
    #
    # (d) `chown -h` on $_wb is symlink-safe. For non-executable modes, umask is
    #     set before O_CREAT so the mode is correct at creation. For the x-bit,
    #     `chmod /dev/fd/5` is preferred; otherwise, a `[ ! -h ]` check and path
    #     chmod are used as fallback. Path chmod follows symlinks, so for it to
    #     be safe `_dir` needs to be writable only by the target-user (e.g. root).
    #
    # (e) Post-mv `stat -L = $_ref` and `[ ! -h "$_f" ]` confirm path identity
    #     at the target. Failures abort before cleanup; the shim does not
    #     restore $_f because parent-writable paths are already replaceable
    #     without the shim.
    #
    # Exit codes: 0 (success), 1 (on failure, we attempt to rm $_wb).
    edit_mode_tty_info "writing back '$_f'"

    _sh_rc=0
    # Inner sh -c reads $1.. from argv; outer sh must not expand them.
    # shellcheck disable=SC2016
    _doas /bin/sh -c '
      _mv=$1;    shift  # mv(1) absolute path
      _rm=$1;    shift  # rm(1) absolute path
      _cat=$1;   shift  # cat(1) absolute path
      _stat=$1;  shift  # stat(1) absolute path
      _chmod=$1; shift  # chmod(1) absolute path
      _chown=$1; shift  # chown(1) absolute path
      _cksum=$1; shift  # checksum binary absolute path
      _ckflg=$1; shift  # "-a 256" for shasum; empty otherwise (used unquoted)
      _stflg=$1; shift  # stat flag
      _stfmt=$1; shift  # stat format
      _dpre=$1;  shift  # editor-return digest (captured before post-editor seal)
      _owng=$1;  shift  # original uid:gid, or empty for new files
      _mode=$1;  shift  # original file mode, or empty for new files
      _wb=$1;    shift  # write-back temp path
      _f=$1             # target file path

      _fail() { exec 5>&- 2>/dev/null; "$_rm" -f -- "$_wb" 2>/dev/null; exit 1; }

      _st() { "$_stat" "$_stflg" "%d:%i" "$1" 2>/dev/null; }
      _stfd() { "$_stat" -L "$_stflg" "$_stfmt" "$1" 2>/dev/null || printf "%s" "-"; }

      _check_path() { [ ! -h "$1" ] && [ "$(_st "$1")" = "$_ref" ] || _fail; }

      if [ -n "$_mode" ] && [ "$((0$_mode & 0111))" = "0" ]; then
        umask "$(printf '%04o' $((0666 & ~0$_mode)))"
        _mode=
      else
        umask 0177
      fi

      set -C
      command exec 5> "$_wb" 2>/dev/null || _fail
      _ref=$(_st "$_wb") || _fail
      _reffd=$(_stfd /dev/fd/5)
      case "$_reffd" in
        -) ;;
        *:*) [ "$_ref" = "$_reffd" ] || _reffd=- ;;
        *) [ "${_ref##*:}" = "$_reffd" ] || _reffd=- ;;
      esac

      "$_cat" >&5 || _fail

      if [ "$_reffd" = '-' ]; then
        _check_path "$_wb"
        [ -z "$_owng" ] || "$_chown" -h -- "$_owng" "$_wb" || _fail
        _check_path "$_wb"
        [ -z "$_mode" ] || "$_chmod" -- "$_mode" "$_wb" || _fail
      else
        [ -z "$_owng" ] || "$_chown" -- "$_owng" /dev/fd/5 || _fail
        [ -z "$_mode" ] || "$_chmod" -- "$_mode" /dev/fd/5 || _fail
      fi

      _check_path "$_wb"
      [ -n "$_dpre" ] && [ "$("$_cksum" $_ckflg < "$_wb" 2>/dev/null)" = "$_dpre" ] || _fail
      _check_path "$_wb"
      "$_mv" -- "$_wb" "$_f" || _fail
      _check_path "$_f"
      exec 5>&-
    ' _ \
    "$_MV" "$_RM" "$_CAT" "$_STAT" "$_CHMOD" "$_CHOWN" "$_CKSUM" \
    "${_CKSUM_FLAG:-}" "$_STAT_FLAG" "$_STAT_FD_FMT" \
    "$_digest_post_editor" \
    "$_orig_owner_group" \
    "$_orig_mode" \
    "$_wbtmp" "$_f" \
    <&3 || _sh_rc=$?
    exec 3<&-

    # sh -c has returned; on exit 0 $_wbtmp was renamed, on exit 1 rm was
    # attempted inside, and the *) arm handles any other case directly. Disarm
    # the EXIT trap's _active_wbtmp guard now.
    _active_wbtmp=
    case "$_sh_rc" in
      0) ;;
      1)
        edit_mode_info "failed to write back '$_f'; edited copy preserved at: $_tmpfile"
        _keep_tmpdir=1 ;;
      *)
        # Unexpected exit, likely a signal kill mid-flight. The sh -c body
        # may not have reached its own rm; attempt cleanup via a fresh doas call.
        _doas "$_RM" -f -- "$_wbtmp" 2>/dev/null \
          || edit_mode_info "could not remove temporary file '$_wbtmp'"
        edit_mode_info "unexpected exit status ${_sh_rc} from write-back sh -c for '$_f'"
        _keep_tmpdir=1 ;;
    esac

    # _tmpdir is cleared so the EXIT trap is a no-op for this iteration.
    # Preserved tmpdirs (_keep_tmpdir=1) are left on disk; _tmpdir is
    # cleared there too so the trap does not attempt to remove them.
    _writeback_phase=0
    _cleanup_tmpdir on_fail

  done  # for _f in "$@"

  exit "$_writeback_failed"
}
