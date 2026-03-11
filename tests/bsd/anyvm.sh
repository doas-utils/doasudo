#!/bin/sh

# SPDX-License-Identifier: MIT
#
# AnyVM wrapper to run tests/bsd/runner.sh inside BSD VMs.
#
# Environment:
#   ANYVM_IMAGE, ANYVM_CACHE, ANYVM_DATA, ANYVM_SYNC, ANYVM_WORKDIR, ANYVM_KVM,
#   ANYVM_FRESH, ANYVM_NO_LOCK, ANYVM_SSH_HOST, ANYVM_SSH_PORT, TEST_USER.

set -eu

usage() {
  cat <<'EOF' >&2
Usage:
  sh tests/bsd/anyvm.sh <freebsd|openbsd|netbsd|dragonflybsd>
  sh tests/bsd/anyvm.sh --test <os|all>
  sh tests/bsd/anyvm.sh --cmd <string> <os|all>

Interactive: AnyVM ssh to root, then su -l <user> && cd /tmp/src
  ssh -i ~/.anyvm/ssh/anyvm-<os> -p PORT root@HOST
EOF
  exit 2
}

_home=${HOME:-/tmp}
_here=$(CDPATH="" cd -P -- "$(dirname -- "$0")" && pwd)
_repo=$(CDPATH="" cd -P -- "$_here/../.." && pwd)

_CACHE_MNT=/usr/local/anyvm-cache
_MNT=/mnt/host
_SSH_MNT=/mnt/anyvm-ssh
_RUNNER=${_MNT}/tests/bsd/runner.sh

ANYVM_IMAGE=${ANYVM_IMAGE:-anyvm}
ANYVM_CACHE=${ANYVM_CACHE:-${_home}/.anyvm/cache}

_fail() {
  printf '%s: %s\n' "$0" "$1" >&2
  exit 2
}

_sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

_has_qcow() {
  find "$@" -name '*.qcow2' 2>/dev/null | read -r _
}

_setup_image() {
  if docker image inspect "$ANYVM_IMAGE" >/dev/null 2>&1 \
    && docker run --rm --entrypoint test "$ANYVM_IMAGE" -s /anyvm.org/entrypoint-wrapper.sh >/dev/null 2>&1; then
    return 0
  fi
  printf '==> building %s\n' "$ANYVM_IMAGE"
  docker build -f "${_here}/AnyVM.Dockerfile" -t "$ANYVM_IMAGE" "${_here}"
}

_setup_ssh() {
  mkdir -p "${_home}/.anyvm/ssh"
  chmod 700 "${_home}/.anyvm/ssh"
  if [ ! -f "$_key" ]; then
    ssh-keygen -t ed25519 -f "$_key" -N "" -C "anyvm-${_os}" </dev/null
    chmod 600 "$_key" "${_key}.pub"
  fi

  _copy_ssh=
  if [ -n "$_fresh" ]; then
    _pub="${_SSH_MNT}/anyvm-${_os}.pub"
    _copy_ssh="mkdir -p /root/.ssh &&"
    _copy_ssh="${_copy_ssh} chmod 700 /root/.ssh &&"
    _copy_ssh="${_copy_ssh} cat ${_pub} >> /root/.ssh/authorized_keys &&"
    _copy_ssh="${_copy_ssh} chmod 600 /root/.ssh/authorized_keys; "
  fi
}

_run_os() {
  _os=$1
  _uid=$(id -u)
  _gid=$(id -g)
  _key="${_home}/.anyvm/ssh/anyvm-${_os}"
  _user=${TEST_USER:-user}
  _host=${ANYVM_SSH_HOST:-127.0.0.1}
  _port=${ANYVM_SSH_PORT:-10022}
  _data=${ANYVM_DATA:-"${_home}/.anyvm/data"}
  _data_os="${_data}/${_os}"
  _cache_os="${ANYVM_CACHE:?}/${_os}"
  _workdir=${ANYVM_WORKDIR:-/tmp/src}

  _fresh=
  if [ -n "${ANYVM_FRESH:-}" ]; then
    rm -rf "$_cache_os" "$_data_os" "$_key" "${_key}.pub"
    _fresh=1
  elif ! _has_qcow "$_data_os" "$_cache_os"; then
    _fresh=1
  fi
  mkdir -p "$ANYVM_CACHE" "$_data"
  _setup_ssh

  printf '==> AnyVM os=%s mode=%s user=%s\n' "$_os" "$_mode" "$_user"

  _ge="BSD_USER='$(_sq "$_user")' BSD_WORKDIR='$(_sq "$_workdir")' BSD_SOURCE='$(_sq "$_MNT")'"
  [ -n "$_fresh" ] && _ge="${_ge} BSD_FRESH=1"
  [ "$_mode" = cmd ] && _ge="${_ge} BSD_RUN='$(_sq "$_cmd")'"
  _run="${_ge} sh ${_RUNNER}"

  _docker_args=
  _guest=
  case "$_mode" in
    interactive)
      _docker_args="-it -p ${_port}:10022"
      printf '==> ssh -i %s -p %s root@%s\n' "$_key" "$_port" "$_host"
      printf '    su -l %s && cd %s\n\n' "$_user" "$_workdir"
      [ -n "$_fresh" ] && _guest="${_copy_ssh}${_run} prepare"
      ;;
    *)
      _guest="${_copy_ssh}${_run} prepare && ${_run} test"
      ;;
  esac

  _kvm=
  [ "${ANYVM_KVM:-0}" = 1 ] && [ -e /dev/kvm ] && _kvm="--device /dev/kvm:/dev/kvm"

  if [ -z "${ANYVM_NO_LOCK:-}" ]; then
    _lockfile="${_home}/.anyvm/lock/${_os}"
    mkdir -p "${_home}/.anyvm/lock"
    set -- flock -n "$_lockfile"
  else
    set --
  fi

  set -- "$@" docker run --rm $_docker_args $_kvm \
    -e "ANYVM_HOST_UID=${_uid}" \
    -e "ANYVM_HOST_GID=${_gid}" \
    -v "$_repo:${_MNT}" \
    -v "${_home}/.anyvm/ssh:${_SSH_MNT}:ro" \
    -v "$ANYVM_CACHE:${_CACHE_MNT}" \
    -v "$_data:/data" \
    "$ANYVM_IMAGE" \
    --cache-dir "${_CACHE_MNT}" \
    --remote-vnc off \
    --os "$_os" \
    --sync "${ANYVM_SYNC:-sshfs}" \
    --ssh-port "$_port"
  [ -n "$_guest" ] && set -- "$@" -- /bin/sh -ec "$_guest"

  _dc=0
  "$@" || _dc=$?  # run docker container

  if [ "$_mode" = interactive ] && [ -n "$_fresh" ] && [ "$_dc" -eq 0 ]; then
    exec ssh -t -i "$_key" -p "$_port" root@"$_host" exec su -l "$_user"
  fi

  [ -n "${ANYVM_NO_LOCK:-}" ] && return "$_dc"
  [ "$_dc" -eq 0 ] && return 0
  flock -n "$_lockfile" true 2>/dev/null && return "$_dc"
  _fail "another AnyVM ${_os} is running (lock: ${_lockfile})"
}

# --- main ---
_mode=interactive
_cmd=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --test|--cmd)
      [ "$_mode" = interactive ] || _fail 'only one of --test or --cmd'
      if [ "$1" = --test ]; then _mode='test'; else _mode=cmd; fi
      shift
      [ "$_mode" = cmd ] || continue
      [ $# -ge 1 ] || _fail '--cmd needs argument'
      _cmd=$1
      shift
      ;;
    *) break ;;
  esac
done

OS=${1:-}
[ -n "$OS" ] || usage

shift
[ $# -eq 0 ] || _fail 'extra arguments after OS'

case "$OS" in
  all) set -- freebsd openbsd netbsd dragonflybsd ;;
  freebsd|openbsd|netbsd|dragonflybsd) set -- "$OS" ;;
  *) usage ;;
esac

if [ "$_mode" = interactive ] && [ "$OS" = all ]; then
  _fail 'interactive mode does not support all (use --test all)'
fi

_setup_image || exit 1

_ec=0
for _os in "$@"; do
  _run_os "$_os" || _ec=1
done
exit "$_ec"
