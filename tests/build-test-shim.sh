#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doas-sudo-shim.
#
# Builds a test shim from doas-sudo-shim.in with selected substitutions.

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

[ -n "$_in" ] || { printf 'error: --input is required\n' >&2; exit 1; }
[ -n "$_out" ] || { printf 'error: --output is required\n' >&2; exit 1; }
[ -n "$_bindir" ] || { printf 'error: --bindir is required\n' >&2; exit 1; }
[ -n "$_edit_broker_path" ] || { printf 'error: --edit-broker-path is required\n' >&2; exit 1; }
[ -n "$_utils_metadata" ] || { printf 'error: --utils-metadata is required\n' >&2; exit 1; }
[ -n "$_version" ] || { printf 'error: --version is required\n' >&2; exit 1; }
[ -n "$_shim_utils" ] || { printf 'error: --shim-utils is required\n' >&2; exit 1; }
[ -n "$_edit_broker_client" ] || { printf 'error: --edit-broker-client is required\n' >&2; exit 1; }
[ -n "$_edit_broker_client_metadata" ] || { printf 'error: --edit-broker-client-metadata is required\n' >&2; exit 1; }
[ -f "$_in" ] || { printf 'error: input not found: %s\n' "$_in" >&2; exit 1; }

_sep=$(printf '\001')

set -- \
  -e "s${_sep}@BINDIR@${_sep}${_bindir}${_sep}" \
  -e "s${_sep}@EDIT_BROKER_PATH@${_sep}${_edit_broker_path}${_sep}" \
  -e "s${_sep}@EDIT_BROKER_METADATA@${_sep}${_edit_broker_metadata}${_sep}" \
  -e "s${_sep}@UTILS_METADATA@${_sep}${_utils_metadata}${_sep}" \
  -e "s${_sep}@VERSION@${_sep}${_version}${_sep}" \
  -e "s${_sep}@SHIM_UTILS@${_sep}${_shim_utils}${_sep}" \
  -e "s${_sep}@EDIT_BROKER_CLIENT@${_sep}${_edit_broker_client}${_sep}" \
  -e "s${_sep}@EDIT_BROKER_CLIENT_METADATA@${_sep}${_edit_broker_client_metadata}${_sep}"

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
