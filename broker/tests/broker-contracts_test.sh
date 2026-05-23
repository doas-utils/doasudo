#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Contract drift check for shared shim/broker constants and wire fixtures.

set -eu

_root=$(CDPATH="" cd -P -- "$(dirname -- "$0")/../.." && pwd)
_cfg="$_root/config/edit-broker-contracts.env"
_broker="$_root/broker/edit-broker.sh"
_doc="$_root/broker/Broker IPC Spec.md"
_fx_req="$_root/broker/tests/fixtures/ipc/request.success.headers"
_fx_rsp_ok="$_root/broker/tests/fixtures/ipc/response.success.headers"
_fx_rsp_err="$_root/broker/tests/fixtures/ipc/response.error.headers"

[ -r "$_cfg" ] || { printf 'missing config: %s\n' "$_cfg" >&2; exit 1; }
# shellcheck disable=SC1091
. "$_root/tests/testlib-broker.sh"
MAGIC=$(_broker_get_contract_value MAGIC "$_cfg")
MAX_BROKER_BYTES=$(_broker_get_contract_value MAX_BROKER_BYTES "$_cfg")
BROKER_RESPONSE_TIMEOUT_S=$(_broker_get_contract_value BROKER_RESPONSE_TIMEOUT_S "$_cfg")

fail() {
  printf 'FAIL broker_contracts_test: %s\n' "$1" >&2
  exit 1
}

[ -n "${MAGIC:-}" ] || fail 'MAGIC missing from contracts file'
[ -n "${MAX_BROKER_BYTES:-}" ] || fail 'MAX_BROKER_BYTES missing from contracts file'
[ -n "${BROKER_RESPONSE_TIMEOUT_S:-}" ] || fail 'BROKER_RESPONSE_TIMEOUT_S missing from contracts file'

_expect_req_order="$(cat <<EOF
MAGIC=$MAGIC
UTILS_METADATA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:0:0:644
EDITOR=/usr/bin/vi
PRE_DIGEST=-
REQ_LEN=3
EOF
)"
_have_req_order=$(cat "$_fx_req")
[ "$_have_req_order" = "$_expect_req_order" ] || fail 'request fixture order/content drifted'

_first_rsp_ok=$(awk 'NR==1{print; exit}' "$_fx_rsp_ok")
_first_rsp_err=$(awk 'NR==1{print; exit}' "$_fx_rsp_err")
[ "$_first_rsp_ok" = 'RESP_CODE=0' ] || fail 'response.success first line must be RESP_CODE=0'
[ "$_first_rsp_err" = 'RESP_CODE=1' ] || fail 'response.error first line must be RESP_CODE=1'

awk -v m="$MAGIC" 'index($0, "`MAGIC=" m "`"){found=1} END{exit found?0:1}' "$_doc" \
  || fail "doc does not describe MAGIC=$MAGIC"

awk 'index($0, "`UTILS_METADATA`"){found=1} END{exit found?0:1}' "$_doc" \
  || fail "doc does not describe UTILS_METADATA"

_broker_magic=$(sed -n "s/^_MAGIC='\\(.*\\)'$/\\1/p" "$_broker" | head -n1)
[ -n "$_broker_magic" ] || fail 'broker MAGIC assignment not found (expected baked single-quoted MAGIC= line)'
[ "$_broker_magic" = "$MAGIC" ] \
  || fail "broker MAGIC ($_broker_magic) != contracts ($MAGIC)"

_broker_max=$(sed -n "s/^_MAX_BROKER_BYTES='\([^']*\)'$/\1/p" "$_broker" | head -n1)
[ -n "$_broker_max" ] || _broker_max=$(sed -n 's/^_MAX_BROKER_BYTES=//p' "$_broker" | head -n1)
[ "$_broker_max" = "$MAX_BROKER_BYTES" ] \
  || fail "broker MAX_BROKER_BYTES ($_broker_max) != contracts ($MAX_BROKER_BYTES)"

grep -q "^_ALLOWLIST_PARSER=" "$_broker" \
  || fail 'broker missing _ALLOWLIST_PARSER assignment'
grep -q "^_BROKER_CONFIG_DIR=" "$_broker" \
  || fail 'broker missing _BROKER_CONFIG_DIR assignment'
grep -q "^_BROKER_CONFIG_VIMRC_METADATA=" "$_broker" \
  || fail 'broker missing _BROKER_CONFIG_VIMRC_METADATA assignment'
grep -q '_MAX_FIXED_ARGS' "$_broker" \
  && fail 'broker should not reference removed MAX_FIXED_ARGS'

awk 'index($0, "BROKER_RESPONSE_TIMEOUT_S"){found=1} END{exit found?0:1}' "$_doc" \
  || fail "doc does not mention BROKER_RESPONSE_TIMEOUT_S"
awk -v n="$BROKER_RESPONSE_TIMEOUT_S" 'index($0, n){found=1} END{exit found?0:1}' "$_doc" \
  || fail "doc does not mention BROKER_RESPONSE_TIMEOUT_S value from contracts"

_client="$_root/lib/edit-broker-client.sh"
if [ -f "$_client" ]; then
  grep -Fq "_MAGIC='$MAGIC'" "$_client" \
    || fail "built edit-broker-client.sh missing _MAGIC='$MAGIC' (run: make lib/edit-broker-client.sh)"
  grep -Fq "_MAX_BROKER_BYTES='$MAX_BROKER_BYTES'" "$_client" \
    || fail "built edit-broker-client.sh _MAX_BROKER_BYTES != contracts (run: make lib/edit-broker-client.sh)"
  grep -Fq "_BROKER_RESPONSE_TIMEOUT_S='$BROKER_RESPONSE_TIMEOUT_S'" "$_client" \
    || fail "built edit-broker-client.sh timeout != contracts (run: make lib/edit-broker-client.sh)"
  grep -q '@EDIT_BROKER_USER@' "$_client" \
    && fail "built edit-broker-client.sh has unsubstituted @EDIT_BROKER_USER@ (run: make lib/edit-broker-client.sh)"
  grep -q '@MAX_BROKER_BYTES@' "$_client" \
    && fail "built edit-broker-client.sh has unsubstituted @MAX_BROKER_BYTES@ (run: make lib/edit-broker-client.sh)"
  grep -q '@BROKER_RESPONSE_TIMEOUT_S@' "$_client" \
    && fail "built edit-broker-client.sh has unsubstituted @BROKER_RESPONSE_TIMEOUT_S@ (run: make lib/edit-broker-client.sh)"
fi

printf '\nPASS broker_contracts_test\n\n'
