#!/bin/sh

# SPDX-License-Identifier: MIT
# BSD prepare | test (vmactions CI; AnyVM runs test only with --test). Env: BSD_USER BSD_WORKDIR;
# BSD_SOURCE, BSD_FRESH=1, BSD_RUN (default: gmake check …).

set -eu

usage() {
  printf 'Usage: %s prepare | test  (requires BSD_USER, BSD_WORKDIR)\n' "$0" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage

_sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

_sync_source() {
  [ -n "${BSD_FRESH:-}" ] && rm -f "$1"
  [ -n "${BSD_SOURCE:-}" ] && [ "$BSD_SOURCE" != "$BSD_WORKDIR" ] || return 0

  if [ -f "$1" ]; then
    return 0
  else
    rm -rf "$BSD_WORKDIR" && mkdir -p "$BSD_WORKDIR"
  fi

  if command -v rsync >/dev/null 2>&1; then
    rsync -aq "${BSD_SOURCE}/" "${BSD_WORKDIR}/" --exclude .git
  else
    cp -a "${BSD_SOURCE}/." "${BSD_WORKDIR}/"
  fi
}

_prepare() {
  : "${BSD_USER:?}" "${BSD_WORKDIR:?}"
  _marker="${BSD_WORKDIR}/.runner-setup"
  _sync_source "$_marker"

  if command -v pw >/dev/null 2>&1; then
    export ASSUME_ALWAYS_YES=yes
    pkg install -y doas gmake socat vim
    pw usershow "$BSD_USER" >/dev/null 2>&1 || pw useradd "$BSD_USER" -m -G wheel
  else
    [ "$(uname)" = OpenBSD ] && _f="-I -z" _v="--gtk3" || _f="" _v=""
    # shellcheck disable=SC2086
    pkg_add $_f doas gmake socat "vim$_v"
    id "$BSD_USER" >/dev/null 2>&1 || useradd -m -g =uid -G wheel "$BSD_USER"
  fi
  printf '%s\n' 'permit nopass :wheel' > /etc/doas.conf
  chmod 400 /etc/doas.conf
  chown -R "$BSD_USER" "$BSD_WORKDIR"

  : > "$_marker"
}

_test() {
  : "${BSD_USER:?}" "${BSD_WORKDIR:?}"
  [ -d "$BSD_WORKDIR" ] || {
    printf '%s: not a directory: %s\n' "$0" "$BSD_WORKDIR" >&2
    exit 1
  }
  [ -f "${BSD_WORKDIR}/doasudo.in" ] || {
    printf '%s: missing doasudo.in in %s\n' "$0" "$BSD_WORKDIR" >&2
    exit 1
  }
  [ "$(uname)" = NetBSD ] && _pp=/usr/pkg/bin || _pp=/usr/local/bin
  _run_cmd=${BSD_RUN:-gmake check EDIT_BROKER_TTY=/dev/null}
  _wrap="${BSD_WORKDIR}/.runner-test-$$.sh"
  {
    printf '%s\n' '#!/bin/sh' 'set -eu'
    printf "cd '%s'\n" "$(_sq "$BSD_WORKDIR")"
    printf "export PATH='%s:'\"\${PATH:-}\"\n" "$(_sq "$_pp")"
    printf '%s\n' 'export MAKE=gmake'
    printf "exec /bin/sh -c '%s'\n" "$(_sq "$_run_cmd")"
  } > "$_wrap"
  chmod 700 "$_wrap" && chown "$BSD_USER" "$_wrap"
  su -m "$BSD_USER" -c "sh '$_wrap'"; _rc=$?
  rm -f "$_wrap"
  exit "$_rc"
}

case $1 in
  prepare) _prepare ;;
  test) _test ;;
  *) usage ;;
esac
