#!/bin/sh
# shellcheck disable=SC1091,SC2015,SC2154
# Resolved paths + globals from sourced testlib helpers.

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Shim baked with SUDO_SHIM_EDIT_BROKER + mock EDITBROKER IPC (moved from edit-mode_test).
#
# Usage:
#   sh broker/tests/broker-integration_test.sh [path/to/doasudo.in]

set -eu

_pass=0
_fail=0
_skip=0

_here=$(CDPATH="" cd -P -- "$(dirname -- "$0")" && pwd)
_repo=$(CDPATH="" cd -P -- "$_here/../.." && pwd)
_tests_dir="$_repo/tests"
_shim_src="${1:-${_tests_dir}/doasudo.in}"
[ -f "$_shim_src" ] || {
  printf 'error: shim source not found: %s\n' "$_shim_src" >&2
  exit 1
}

# shellcheck source=../../tests/testlib.sh
. "$_tests_dir/testlib.sh"
# shellcheck source=../../utils/metadata-utils.sh
. "$_repo/utils/metadata-utils.sh"
# shellcheck source=../../tests/testlib-broker.sh
. "$_tests_dir/testlib-broker.sh"

_eb_contracts="$_repo/config/edit-broker-contracts.env"
[ -r "$_eb_contracts" ] || {
  printf 'error: missing %s\n' "$_eb_contracts" >&2
  exit 1
}
_eb_magic=$(_broker_get_contract_value MAGIC "$_eb_contracts")
_eb_max=$(_broker_get_contract_value MAX_BROKER_BYTES "$_eb_contracts")
_eb_to=$(_broker_get_contract_value BROKER_RESPONSE_TIMEOUT_S "$_eb_contracts")
if [ -z "$_eb_magic" ] || [ -z "$_eb_max" ] || [ -z "$_eb_to" ]; then
  printf 'error: MAGIC, MAX_BROKER_BYTES, or BROKER_RESPONSE_TIMEOUT_S missing in %s\n' "$_eb_contracts" >&2
  exit 1
fi

_tmp=
_mockbin=
_setup_mockbin
export TMPDIR="$_tmp"
trap '_chmod_rm_tmp' EXIT

_rc=0
_broker_check_kill0 || true

_shim="${_tmp}/sudo"

chmod 755 "$_mockbin"

# ---- Minimal test framework (broker matrix; _assert_* + _build_edit_test_shim from tests/testlib-broker.sh) ---

# Probe the mock broker with stdin headers; assert first response line == $2.
# $1 = label. Caller redirects stdin (typically a heredoc) to supply wire bytes.
_assert_mock_first_line() {
  _amfl_out=$(mktemp "${_tmp}/mock_probe.XXXXXX") || { _fail_t "$1" "mktemp failed"; return; }
  "${_mockbin}/edit-broker" >"$_amfl_out" 2>/dev/null || true
  _amfl_got=$(awk 'NR==1{print; exit}' "$_amfl_out")
  _assert_str_eq "$1" "$_amfl_got" "$2"
}

# $1 MOCK_EDIT_BROKER_MODE; $2 target file; $3 shim (default $_shim).
_run_broker_mode() {
  _rsbm_shim=${3:-$_shim}
  _run_capture_streams env \
    SUDO_EDITOR="${_mockbin}/editor_modify" \
    SUDO_SHIM_EDIT_BROKER=1 \
    MOCK_EDIT_BROKER_MODE="$1" \
    "$_rsbm_shim" -e "$2"
}

_assert_broker_fail_closed() {
  _abfc_lbl=$1
  _abfc_mode=$2
  _abfc_needle=$3
  _abfc_shim=${4:-$_shim}
  _abfc_file="${_tmp}/wb_broker_${_abfc_mode}.txt"

  printf 'original\n' > "$_abfc_file"
  _run_broker_mode "$_abfc_mode" "$_abfc_file" "$_abfc_shim"
  _assert_exit "${_abfc_lbl}: exits 1" 1 "$_rc"
  _assert_string_contains "${_abfc_lbl}: message" "$_abfc_needle" "$_err"
  _assert_file_content "${_abfc_lbl}: target unchanged" "$_abfc_file" "original"
}

# ---- Mock binaries (shared prelude, broker-minimal editors) -----------------------
_MOCKBIN_EDIT_SUITE=broker
# shellcheck source=../../tests/mock-edit-mode.sh
. "$_tests_dir/mock-edit-mode.sh"

_fixture_mock_edit_broker="${_here}/fixtures/ipc/mock-edit-broker.sh.in"
[ -f "$_fixture_mock_edit_broker" ] || {
  printf 'error: missing mock fixture: %s\n' "$_fixture_mock_edit_broker" >&2
  exit 1
}
awk \
  -v _sha_tool="${_mockbin}/${_SHA_KIND}" \
  -v _sha_flag="${_SHA_FLAG}" \
  -v _um="${_utils_metadata}" \
  -v _magic="${_eb_magic}" '
{
  gsub("@MOCKBIN_SHA@", _sha_tool)
  gsub("@SHA_FLAG@", _sha_flag)
  gsub("@UTILS_METADATA@", _um)
  gsub("@MAGIC@", _magic)
  print
}' "$_fixture_mock_edit_broker" > "${_mockbin}/edit-broker"
chmod 755 "${_mockbin}/edit-broker"

# EDIT_BROKER_METADATA for the shim: same sha:uid:gid:mode form as the Makefile.
_broker_metadata=$(_compute_metadata "${_mockbin}/edit-broker" 755 stat-ug) || {
  printf 'error: could not compute metadata for mock edit-broker\n' >&2
  exit 1
}

# ---- Mock fixture conformance --------------------------------------------------------
# These tests verify the mock broker enforces EDITBROKER/1 wire validation. The rest
# of the suite trusts the mock to fail-closed on the same inputs the real broker would;
# if this drifts, the integration matrix below would silently lose coverage.

printf '\n── Mock fixture: EDITBROKER/1 wire validation ──────────────────────────────────\n'

# shellcheck disable=SC2086 # _SHA_FLAG optional (tool-specific; may be empty)
_unnorm_pre=$(printf 'original\n' | "$_mock_sha_tool" $_SHA_FLAG)
_tabbed_editor=$(printf '/bin/vi\t/bin/evil')

_assert_mock_first_line "mock: unnormalized PRE_DIGEST -> RESP_CODE=1" 'RESP_CODE=1' <<EOF
MAGIC=${_eb_magic}
UTILS_METADATA=${_utils_metadata}
EDITOR=${_mockbin}/editor_modify
PRE_DIGEST=${_unnorm_pre}
REQ_LEN=0
EOF

_assert_mock_first_line "mock: tab in EDITOR -> RESP_CODE=1" 'RESP_CODE=1' <<EOF
MAGIC=${_eb_magic}
UTILS_METADATA=${_utils_metadata}
EDITOR=${_tabbed_editor}
PRE_DIGEST=-
REQ_LEN=0
EOF

# ---- Build shim --------------------------------------------------------------------------

_version=$(cat "${_tests_dir}/VERSION" 2>/dev/null) || _version='unknown'
_sep=$(printf '\001')
# Broker client bakes doas -u; mock doas runs as root, so use root here.
_eb_client="${_tmp}/edit-broker-client.sh"
sed \
  -e "s${_sep}@MAGIC@${_sep}${_eb_magic}${_sep}" \
  -e "s${_sep}@EDIT_BROKER_USER@${_sep}root${_sep}" \
  -e "s${_sep}@MAX_BROKER_BYTES@${_sep}${_eb_max}${_sep}" \
  -e "s${_sep}@BROKER_RESPONSE_TIMEOUT_S@${_sep}${_eb_to}${_sep}" \
  "${_repo}/lib/edit-broker-client.sh.in" > "$_eb_client"
_eb_client_meta=$(_compute_metadata "$_eb_client" 644 stat-ug) || {
  printf 'error: could not compute metadata for edit-broker-client.sh\n' >&2
  exit 1
}

_build_edit_test_shim "$_shim" "${_mockbin}/edit-broker" "$_broker_metadata"

# Build a shim with a derivative client (mutated by $3 sed expr).
# $1 = client output path; $2 = shim output path; $3 = sed expr to mutate client.
_make_derivative_shim() {
  sed "$3" "$_eb_client" > "$1"
  _mds_meta=$(_compute_metadata "$1" 644 stat-ug) || {
    printf 'error: could not compute metadata for %s\n' "$1" >&2
    exit 1
  }
  sed -e "s${_sep}${_eb_client}${_sep}$1${_sep}g" \
      -e "s/^_EDIT_BROKER_CLIENT_METADATA=.*/_EDIT_BROKER_CLIENT_METADATA='${_mds_meta}'/" \
      "$_shim" > "$2"
  chmod +x "$2"
}

_shim_to1="${_tmp}/sudo_to1"
_shim_max1="${_tmp}/sudo_max1"
_make_derivative_shim "${_tmp}/edit-broker-client_to1.sh" "$_shim_to1" \
  "s/^_BROKER_RESPONSE_TIMEOUT_S=.*/_BROKER_RESPONSE_TIMEOUT_S='1'/"
_make_derivative_shim "${_tmp}/edit-broker-client_max1.sh" "$_shim_max1" \
  "s/^_MAX_BROKER_BYTES=.*/_MAX_BROKER_BYTES='1'/"
printf '\n── Broker path: success / fail-closed ──────────────────────────────────────────\n'

_f="${_tmp}/wb_broker_success.txt"
printf 'original\n' > "$_f"
_run_broker_mode success "$_f"
_assert_exit "broker success: exits 0" 0 "$_rc"
_assert_file_content "broker success: target content" "$_f" "broker edited content"

_f="${_tmp}/wb_broker_noop.txt"
printf 'original\n' > "$_f"
_run_broker_mode passthrough "$_f"
_assert_exit "broker noop: exits 0" 0 "$_rc"
_assert_string_contains "broker noop: unchanged notice" "unchanged" "$_err"
_assert_file_content "broker noop: target unchanged" "$_f" "original"

_f="${_tmp}/wb_broker_failclosed.txt"
printf 'original\n' > "$_f"
_run_broker_mode error "$_f"
_assert_exit "broker fail-closed: exits 1" 1 "$_rc"
_assert_string_contains "broker fail-closed: message" "broker path failed" "$_err"
_assert_file_content "broker fail-closed: target unchanged" "$_f" "original"

_broker_bad_dir="${_tmp}/broker_insecure"
mkdir -p "$_broker_bad_dir"
cat "${_mockbin}/edit-broker" > "${_broker_bad_dir}/edit-broker"
chmod 755 "${_broker_bad_dir}/edit-broker"
chmod 0777 "$_broker_bad_dir"
_f="${_tmp}/wb_broker_insecure_path.txt"
printf 'original\n' > "$_f"
# Re-bake with an intentionally insecure broker directory; metadata matches the copy.
_shim_insecure="${_tmp}/sudo_insecure"
_broker_metadata_bad=$(_compute_metadata "${_broker_bad_dir}/edit-broker" 755 stat-ug) || {
  printf 'error: could not compute metadata for insecure-path broker\n' >&2
  exit 1
}
_build_edit_test_shim "$_shim_insecure" "${_broker_bad_dir}/edit-broker" "$_broker_metadata_bad"

# Append to the broker after the bake so the live file no longer matches metadata.
printf '\n# tamper after bake\n' >> "${_broker_bad_dir}/edit-broker"

_run_broker_mode success "$_f" "$_shim_insecure"
_assert_exit "broker metadata mismatch: exits 1" 1 "$_rc"
_assert_string_contains "broker metadata mismatch: message" "broker binary metadata mismatch" "$_err"
_assert_file_content "broker metadata mismatch: target unchanged" "$_f" "original"

_assert_broker_fail_closed "broker missing RESP_CODE" missing_resp_code "invalid broker response prefix"
_assert_broker_fail_closed "broker missing POST_DIGEST" missing_post_digest "malformed POST_DIGEST"
_assert_broker_fail_closed "broker POST_DIGEST=-" post_digest_dash "write-back skipped"
_assert_broker_fail_closed "broker POST_DIGEST=- truncated body" post_digest_dash_trunc "broker response body truncated"
_assert_broker_fail_closed "broker bad OUT_LEN" bad_out_len "non-decimal OUT_LEN"
_assert_broker_fail_closed "broker wrong field order" wrong_order "malformed POST_DIGEST"
_assert_broker_fail_closed "broker duplicate POST_DIGEST" duplicate_post_digest "malformed OUT_LEN"
_assert_broker_fail_closed "broker bad RESP_CODE" bad_resp_code "non-decimal RESP_CODE"
_assert_broker_fail_closed "broker out-of-range RESP_CODE" out_of_range_resp_code "out-of-range RESP_CODE"
_assert_broker_fail_closed "broker bad POST_DIGEST" bad_post_digest "invalid POST_DIGEST format"
_assert_broker_fail_closed "broker oversized OUT_LEN" oversized_out_len "OUT_LEN exceeds MAX_BROKER_BYTES"
_assert_broker_fail_closed "broker trailing bytes" trailing_bytes "unexpected trailing data"

_f="${_tmp}/wb_broker_timeout.txt"
printf 'original\n' > "$_f"
_run_broker_mode timeout "$_f" "$_shim_to1"
_assert_exit "broker timeout: exits 1" 1 "$_rc"
if [ "$_broker_kill0_usable" -eq 1 ]; then
  _assert_string_contains "broker timeout: message" "broker response timed out" "$_err"
else
  _skip_t "broker timeout: message (kill -0 unavailable in sandbox)"
fi
_assert_file_content "broker timeout: target unchanged" "$_f" "original"

_assert_broker_fail_closed \
  "broker oversized REQ_LEN" oversized_req_len \
  "request size exceeds MAX_BROKER_BYTES" "$_shim_max1"

_tests_summary
