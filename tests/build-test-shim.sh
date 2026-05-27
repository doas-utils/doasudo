#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Builds a test shim from doasudo.in with selected substitutions.

set -eu

_in=
_out=
_bindir=
_edit_broker_path=
_edit_broker_metadata=
_utils_metadata=
_version=
_shim_utils=
_edit_broker_client=
_edit_broker_client_metadata=
_drop_setuid_guard=0
_stub_edit_mode_root_guard=0
_stub_check_path_walk=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) _in="${2:-}"; shift 2 ;;
    --output) _out="${2:-}"; shift 2 ;;
    --bindir) _bindir="${2:-}"; shift 2 ;;
    --edit-broker-path) _edit_broker_path="${2:-}"; shift 2 ;;
    --edit-broker-metadata) _edit_broker_metadata="${2:-}"; shift 2 ;;
    --utils-metadata) _utils_metadata="${2:-}"; shift 2 ;;
    --version) _version="${2:-}"; shift 2 ;;
    --shim-utils) _shim_utils="${2:-}"; shift 2 ;;
    --edit-broker-client) _edit_broker_client="${2:-}"; shift 2 ;;
    --edit-broker-client-metadata) _edit_broker_client_metadata="${2:-}"; shift 2 ;;
    --drop-setuid-guard) _drop_setuid_guard=1; shift ;;
    --stub-edit-mode-root-guard) _stub_edit_mode_root_guard=1; shift ;;
    --stub-check-path-walk) _stub_check_path_walk=1; shift ;;
    *)
      printf 'error: unknown option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

_miss=
[ -n "$_in" ] || _miss=input
[ -n "$_out" ] || _miss=output
[ -n "$_bindir" ] || _miss=bindir
[ -n "$_edit_broker_path" ] || _miss=edit-broker-path
[ -n "$_edit_broker_metadata" ] || _miss=edit-broker-metadata
[ -n "$_utils_metadata" ] || _miss=utils-metadata
[ -n "$_version" ] || _miss=version
[ -n "$_shim_utils" ] || _miss=shim-utils
[ -n "$_edit_broker_client" ] || _miss=edit-broker-client
[ -n "$_edit_broker_client_metadata" ] || _miss=edit-broker-client-metadata
[ -z "${_miss:-}" ] || {
  printf 'error: --%s is required\n' "$_miss" >&2
  exit 1
}
[ -f "$_in" ] || { printf 'error: input not found: %s\n' "$_in" >&2; exit 1; }

_marker_count=$(grep -c '^# @EDIT_BROKER_METADATA@$' "$_in" || true)
[ "$_marker_count" -eq 1 ] || {
  printf 'error: expected exactly one # @EDIT_BROKER_METADATA@ marker in %s\n' "$_in" >&2
  exit 1
}

_sep=$(printf '\001')

# Broker values are single-quoted like the Makefile bake; embedded "'" would break.
_vars_file=$(mktemp "${TMPDIR:-/tmp}/edit-broker-vars.XXXXXX")
trap 'rm -f "$_vars_file"' EXIT INT HUP TERM
cat > "$_vars_file" <<EOF
_EDIT_BROKER_CLIENT='${_edit_broker_client}'
_EDIT_BROKER_CLIENT_METADATA='${_edit_broker_client_metadata}'
_EDIT_BROKER_PATH='${_edit_broker_path}'
_EDIT_BROKER_METADATA='${_edit_broker_metadata}'
EOF

set -- \
  -e "s${_sep}@BINDIR@${_sep}${_bindir}${_sep}" \
  -e "s${_sep}@UTILS_METADATA@${_sep}${_utils_metadata}${_sep}" \
  -e "s${_sep}@VERSION@${_sep}${_version}${_sep}" \
  -e "s${_sep}@SHIM_UTILS@${_sep}${_shim_utils}${_sep}" \
  -e '/^# @EDIT_BROKER_METADATA@$/{' \
  -e "  r ${_vars_file}" \
  -e '  d' \
  -e '}'

if [ "$_drop_setuid_guard" -eq 1 ]; then
  set -- "$@" -e '/\[ -u "\$_DOAS" \]/d'
fi
if [ "$_stub_edit_mode_root_guard" -eq 1 ]; then
  set -- "$@" -e '/^_edit_mode_root_guard() {$/,/^}$/c\
_edit_mode_root_guard() { :; }\
'
fi
if [ "$_stub_check_path_walk" -eq 1 ]; then
  set -- "$@" -e '/^_check_path_walk() {$/,/^}$/c\
_check_path_walk() { :; }\
'
fi

sed "$@" "$_in" > "$_out"

if grep -q '@EDIT_BROKER_METADATA@' "$_out"; then
  printf 'error: marker substitution failed in %s\n' "$_out" >&2
  rm -f "$_out"
  exit 1
fi
