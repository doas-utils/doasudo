#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Test driver for broker/edit-broker.sh: builds framed requests, runs the broker,
# parses stdout. Examples use stanza `[nano]` (registry profile `nano`); see
# broker/Editor Allowlist Spec.md, broker/README.md, and broker/Broker IPC Spec.md.
#
# Usage:
#   sh broker/tests/test-driver.sh
#
# Environment (optional):
#   MAKE = make program (default: make)
# The harness runs `make broker/build-to` with EDIT_BROKER_TTY=/dev/null and
# UTILS_METADATA_PATH + UTILS_METADATA_COMPUTE_MODE=stat-ug (see Makefile).

set -eu

_here=$(CDPATH="" cd -P -- "$(dirname -- "$0")" && pwd)
_repo=$(CDPATH="" cd -P -- "$(dirname -- "$0")/../.." && pwd)
# shellcheck disable=SC1091
. "$_repo/utils/metadata-utils.sh"
# shellcheck disable=SC1091
. "$_repo/tests/testlib.sh"
# shellcheck disable=SC1091
# shellcheck source=../../tests/testlib-broker.sh
. "$_repo/tests/testlib-broker.sh"
MAKE=${MAKE:-make}
_stub_src="$_here/test-stub-editor.sh"
_contracts="$_repo/config/edit-broker-contracts.env"

_tmp=$(mktemp -d "${TMPDIR:-/tmp}/broker-test-driver.XXXXXX")
_staging="$_tmp/editbroker-staging"
mkdir -m 0700 "$_staging"
# shellcheck disable=SC2317
_cleanup() { rm -rf "$_tmp"; }
trap _cleanup EXIT

fail_driver() {
  printf 'FAIL broker-test-driver: %s\n' "$1" >&2
  [ -n "${2:-}" ] && printf '%s\n' "$2" >&2
  exit 1
}

# Editor stubs under $_tmp: doas/root chown must target paths root can stat
# (FUSEFS shares are often invisible to root).
[ -r "$_stub_src" ] || fail_driver "missing stub editor: $_stub_src"
STUB="$_tmp/test-stub-editor.sh"
cp "$_stub_src" "$STUB"
chmod 0755 "$STUB"

[ -r "$_contracts" ] || fail_driver "missing contracts: $_contracts"
# shellcheck disable=SC1090
. "$_contracts"
[ -n "${MAGIC:-}" ] || fail_driver "MAGIC empty in $_contracts"

_setup_sha_tool "$_tmp" 'no checksum tool found (need sha256sum, sha256, or shasum)' >/dev/null \
  || fail_driver 'no checksum tool found (need sha256sum, sha256, or shasum)'

# Broker requires allowlist 0:0 (root-owned) and mode without group/other write (see edit-broker).
# Use numeric chown: macOS has no "root" group (wheel); broker checks 0:0 via stat.
_ROOT_UG=0:0
# The shim targets doas; harness uses only `doas -n` (non-interactive). Interactive `doas`
# would block `make check-src` with a password prompt when nopass is not configured.
# Each redirect to the allowlist recreates it as the current user, so re-apply ownership
# after every write.
_run_priv() {
  command -v doas >/dev/null 2>&1 || return 1
  doas -n true >/dev/null 2>&1 || return 1
  doas -n "$@"
}

_sync_allowlist_owner() {
  _alf=$1
  chmod 0644 "$_alf" || return 1
  [ "$(id -u)" -eq 0 ] && return 0
  _run_priv chown "$_ROOT_UG" "$_alf" || return 1
  _run_priv chmod 0644 "$_alf" || return 1
}

_sync_editor_bin_owner() {
  _bin=$1
  chmod 0755 "$_bin" || return 1
  [ "$(id -u)" -eq 0 ] && return 0
  _run_priv chown "$_ROOT_UG" "$_bin" || return 1
  _run_priv chmod 0755 "$_bin" || return 1
}

# After _sync_allowlist_owner the file is root-owned; unprivileged users cannot
# truncate it in place. Unlink from our writable tmpdir, then recreate.
_allowlist_rewrite_prep() {
  rm -f "$_allowlist"
}

printf '\n── Test driver ─────────────────────────────────────────────────────────────────\n'

_allowlist="$_tmp/edit-broker.editors"
{
  printf '%s\n' '[nano]'
  printf 'path = %s\n' "$STUB"
} >"$_allowlist"
if ! _sync_allowlist_owner "$_allowlist"; then
  printf 'SKIP broker-test-driver: need root or passwordless doas for root-owned allowlist\n'
fi

# Wrappers for tests that previously relied on env vars reaching the stub under a
# clean editor environment (broker runs editors via env -i).
cat >"$_tmp/stub-append.sh" <<'EOF'
#!/bin/sh
shift $(( $# - 1 ))
printf sfx >>"$1"
exit 0
EOF
chmod +x "$_tmp/stub-append.sh"

cat >"$_tmp/stub-sleep3.sh" <<'EOF'
#!/bin/sh
# No PATH under broker env -i; use well-known sleep paths.
for _s in /bin/sleep /usr/bin/sleep; do
  if [ -x "$_s" ]; then
    exec "$_s" 3
  fi
done
exit 127
EOF
chmod +x "$_tmp/stub-sleep3.sh"

cat >"$_tmp/stub-fake-vim.sh" <<'EOFSTUBVIM'
#!/bin/sh
# Fake vim: invalid --version for broker _check_vim; benign if invoked without --version.
case "$1" in
--version)
  printf '%s\n' 'fake editor without features'
  exit 0
  ;;
esac
exit 0
EOFSTUBVIM
chmod +x "$_tmp/stub-fake-vim.sh"

# Broker requires root-owned editor paths (metadata gate); stubs must match.
_sync_editor_bins() {
  _sync_editor_bin_owner "$STUB" || return 1
  _sync_editor_bin_owner "$_tmp/stub-append.sh" || return 1
  _sync_editor_bin_owner "$_tmp/stub-sleep3.sh" || return 1
  _sync_editor_bin_owner "$_tmp/stub-fake-vim.sh" || return 1
  return 0
}
if ! _sync_editor_bins; then
  printf 'SKIP broker-test-driver: need root or passwordless doas for root-owned editor stubs\n'
fi

# Rest of harness has no skipping tests if not root.
[ "$(id -u)" -ne 0 ] && { printf '\n'; exit 0; }

_broker_config_tmp="$_tmp/broker-config"
mkdir -m 0755 "$_broker_config_tmp"
cp "$_repo/config/vimrc" "$_broker_config_tmp/vimrc"
chmod 0644 "$_broker_config_tmp/vimrc" || fail_driver "_broker_config_tmp chmod"
if [ "$(id -u)" -ne 0 ]; then
  _run_priv chown "$_ROOT_UG" "$_broker_config_tmp/vimrc" ||
    fail_driver "chown $_broker_config_tmp/vimrc $_ROOT_UG"
  _run_priv chmod 0644 "$_broker_config_tmp/vimrc" ||
    fail_driver "_broker_config_tmp chmod (second)"
fi

# Broker paths are baked at build; generate a broker with harness-local paths.
_gen="$_tmp/edit-broker.gen.sh"
_shim_path=$(dirname -- "$_SHA_TOOL")
_shim_path="${_shim_path}:/usr/bin:/bin:/usr/sbin:/sbin"
_common="$_tmp/shim-utils.harness.sh"
# shellcheck disable=SC2046
(cd "$_repo" && "$MAKE" $(_make_s) shim-utils/build-to SHIM_UTILS_BUILD_TO="$_common" SHIM_PATH="$_shim_path") \
  || fail_driver 'make shim-utils/build-to failed'
# Release bake uses 0:0 from Makefile; harness shim-utils lives under $_common with
# invoking-user ownership; Makefile hashes that path with stat-ug (see metadata-utils.sh).
# shellcheck disable=SC2046
(cd "$_repo" && "$MAKE" $(_make_s) broker/build-to \
  "BROKER_BUILD_TO=$_gen" \
  "EDIT_BROKER_STAGING_DIR=$_staging" \
  "BROKER_ALLOWLIST_PATH=$_allowlist" \
  "BROKER_ALLOWLIST_PARSER=$_repo/broker/allowlist-parse.awk" \
  "BROKER_CONFIG_DIR=$_broker_config_tmp" \
  "EDIT_BROKER_TTY=/dev/null" \
  "SHIM_PATH=$_shim_path" \
  "SHIM_UTILS=$_common" \
  "UTILS_METADATA_PATH=$_common" \
  "UTILS_METADATA_COMPUTE_MODE=stat-ug") \
  || fail_driver 'make broker/build-to failed'
BROKER="$_gen"

UTILS_METADATA_REQ=$(sed -n "s/^_SHIM_UTILS_METADATA='\\(.*\\)'$/\\1/p" "$BROKER" | head -n1)
[ -n "$UTILS_METADATA_REQ" ] || fail_driver 'could not read SHIM_UTILS_METADATA from generated broker'

# Runs one round-trip: body file -> broker -> compares response body to expect file.
# $1 = case label (for PASS line)
# $2 = path to request body bytes
# $3 = path to expected response body (cmp -s)
# Remaining args: KEY=value env assignments for the broker child.
# Optional: set EDITOR_FOR_REQUEST to an absolute path listed in $_allowlist (default: $STUB).
run_one() {
  _label="$1"
  _body_in="$2"
  _expect="$3"
  shift 3

  _req_editor=${EDITOR_FOR_REQUEST:-$STUB}

  _req_len=$(wc -c <"$_body_in" | awk '{print $1}')

  _req="$_tmp/request.$_label.bin"
  {
    printf 'MAGIC=%s\n' "$MAGIC"
    printf 'UTILS_METADATA=%s\n' "$UTILS_METADATA_REQ"
    printf '%s\n' "EDITOR=$_req_editor"
    printf '%s\n' 'PRE_DIGEST=-'
    printf '%s\n' "REQ_LEN=$_req_len"
    cat "$_body_in"
  } >"$_req"

  _resp="$_tmp/response.$_label.bin"
  _err="$_tmp/broker.$_label.err"
  if ! env "$@" sh "$BROKER" <"$_req" >"$_resp" 2>"$_err"; then
    fail_driver "$_label: broker exited non-zero" "$(cat "$_err" 2>/dev/null || true)"
  fi

  exec 3<"$_resp" || fail_driver "$_label: cannot open response"

  IFS= read -r _line1 <&3 || fail_driver "$_label: empty response"
  case "$_line1" in
  RESP_CODE=0) ;;
  RESP_CODE=*)
    fail_driver "$_label: broker error $_line1" "$(cat "$_err" 2>/dev/null || true)"
    ;;
  *)
    fail_driver "$_label: bad first line: $_line1"
    ;;
  esac

  IFS= read -r _post <&3 || fail_driver "$_label: missing POST_DIGEST"
  case "$_post" in
  POST_DIGEST=*) ;;
  *)
    fail_driver "$_label: expected POST_DIGEST line, got: $_post"
    ;;
  esac

  IFS= read -r _olen <&3 || fail_driver "$_label: missing OUT_LEN"
  case "$_olen" in
  OUT_LEN=*) _out_n="${_olen#OUT_LEN=}" ;;
  *)
    fail_driver "$_label: expected OUT_LEN line, got: $_olen"
    ;;
  esac

  case "$_out_n" in '' | *[!0-9]*)
    fail_driver "$_label: bad OUT_LEN: $_out_n"
    ;;
  esac

  _body_out="$_tmp/body.out.$_label"
  dd bs=1 count="$_out_n" <&3 >"$_body_out" 2>/dev/null \
    || fail_driver "$_label: failed to read OUT_LEN body"

  if ! cmp -s "$_expect" "$_body_out"; then
    fail_driver "$_label: body mismatch (expected vs got)"
  fi

  printf 'PASS broker-test-driver: %s\n' "$_label"
  exec 3<&-
}

# $1=out path, $2=body file, $3=EDITOR value, $4=PRE_DIGEST wire line value
_write_broker_request() {
  _wbr_out=$1
  _wbr_body=$2
  _wbr_editor=$3
  _wbr_pre=$4
  _wbr_len=$(wc -c <"$_wbr_body" | awk '{print $1}')
  {
    printf 'MAGIC=%s\n' "$MAGIC"
    printf 'UTILS_METADATA=%s\n' "$UTILS_METADATA_REQ"
    printf '%s\n' "EDITOR=$_wbr_editor"
    printf '%s\n' "PRE_DIGEST=$_wbr_pre"
    printf '%s\n' "REQ_LEN=$_wbr_len"
    cat "$_wbr_body"
  } >"$_wbr_out"
}

# Expect exactly RESP_CODE=1 on stdout; broker may exit non-zero.
# $1=slug, $2=request path, $3=fail message prefix,
# $4=substring stderr must contain (omit or empty to skip check).
_run_broker_expect_resp1() {
  _rr_slug=$1
  _rr_req=$2
  _rr_pfx=$3
  _rr_err_sub=${4:-}
  _rr_resp="$_tmp/response.$_rr_slug.bin"
  _rr_errf="$_tmp/broker.$_rr_slug.err"
  sh "$BROKER" <"$_rr_req" >"$_rr_resp" 2>"$_rr_errf" || true
  exec 3<"$_rr_resp" || fail_driver "$_rr_pfx: cannot open broker response"
  IFS= read -r _rr_l <&3 || fail_driver "$_rr_pfx: empty broker response"
  [ "$_rr_l" = 'RESP_CODE=1' ] || fail_driver "$_rr_pfx: expected RESP_CODE=1, got: $_rr_l"
  if IFS= read -r _rr_m <&3; then
    fail_driver "$_rr_pfx: unexpected extra broker response line: $_rr_m"
  fi
  exec 3<&-
  _rr_es=$(cat "$_rr_errf" 2>/dev/null || true)
  [ -z "$_rr_err_sub" ] && return 0
  case "$_rr_es" in
  *"${_rr_err_sub}"*) ;;
  *)
    printf 'broker stderr was:\n%s\n' "$_rr_es" >&2
    fail_driver "$_rr_pfx: stderr missing expected diagnostic"
    ;;
  esac
}

_restore_allowlist_nano_stub() {
  _allowlist_rewrite_prep
  {
    printf '%s\n' '[nano]'
    printf 'path = %s\n' "$STUB"
  } >"$_allowlist"
  _sync_allowlist_owner "$_allowlist" || fail_driver "$1"
}

# ---- Case 1: NUL in body (remainder-only path in broker read/write: 3 % 4096) ------------
_body_nul="$_tmp/body.nul.bin"
printf 'a\0b' >"$_body_nul"
run_one 'NUL body round-trip' "$_body_nul" "$_body_nul"

# ---- Case 2: 4097 bytes; exercises full 4096-byte blocks + remainder in broker -----------
_body_big="$_tmp/body.4097.bin"
if ! dd if=/dev/zero bs=4097 count=1 2>/dev/null >"$_body_big"; then
  awk 'BEGIN{for(i=1;i<=4097;i++)printf "x"}' >"$_body_big"
fi
run_one '4097-byte body (block+remainder)' "$_body_big" "$_body_big"

# ---- Case 3: stub-append changes file; expect request + suffix ---------------------------
_body_base="$_tmp/body.base.bin"
printf 'editme' >"$_body_base"
_expect_append="$_tmp/expect.append.bin"
printf 'editmesfx' >"$_expect_append"
  _allowlist_rewrite_prep
  {
    printf '%s\n' '[nano]'
    printf 'path = %s\n' "$_tmp/stub-append.sh"
  } >"$_allowlist"
  _sync_allowlist_owner "$_allowlist" \
    || fail_driver 'stub-append: could not set allowlist root ownership'
  EDITOR_FOR_REQUEST="$_tmp/stub-append.sh" run_one 'stub-append body change' "$_body_base" "$_expect_append"
  unset EDITOR_FOR_REQUEST
  _restore_allowlist_nano_stub 'stub-append restore: could not set allowlist root ownership'

# ---- Case 4: error path invariant (RESP_CODE != 0) ---------------------------------------
_body_err="$_tmp/body.err.bin"
printf 'x' >"$_body_err"

_write_broker_request "$_tmp/request.err.unknown-editor.bin" "$_body_err" '/nonexistent/editor' '-'
_run_broker_expect_resp1 'unknown-editor' "$_tmp/request.err.unknown-editor.bin" 'unknown editor'
printf 'PASS broker-test-driver: error path (unknown editor)\n'

# ---- Case 4b: unknown PROFILE (allowlist stanza parses; broker registry rejects) ---------
_body_nvim_prof="$_tmp/body.nvim-prof.bin"
printf 'x' >"$_body_nvim_prof"

_allowlist_rewrite_prep
{
  printf '%s\n' '[nvim]'
  printf 'path = %s\n' "$STUB"
} >"$_allowlist"
_sync_allowlist_owner "$_allowlist" \
  || fail_driver 'unknown PROFILE: could not set allowlist root ownership'

_write_broker_request "$_tmp/request.err.nvim-profile.bin" "$_body_nvim_prof" "$STUB" '-'
_run_broker_expect_resp1 'nvim-profile' "$_tmp/request.err.nvim-profile.bin" 'unknown PROFILE' \
  'unknown editor profile'
printf 'PASS broker-test-driver: registry rejects unknown allowlist PROFILE ([nvim])\n'
_restore_allowlist_nano_stub 'unknown PROFILE restore: could not set allowlist root ownership'

# ---- Case 4c: vim runtime identity (_check_vim rejects fake --version) --------------------
_fake_vim="$_tmp/stub-fake-vim.sh"
_body_vimc="$_tmp/body.fake-vim-check.bin"
printf 'z' >"$_body_vimc"

_allowlist_rewrite_prep
{
  printf '%s\n' '[vim]'
  printf 'path = %s\n' "$_fake_vim"
} >"$_allowlist"
_sync_allowlist_owner "$_allowlist" \
  || fail_driver 'fake vim: could not set allowlist root ownership'

_write_broker_request "$_tmp/request.fake-vim-runtime.bin" "$_body_vimc" "$_fake_vim" '-'
_run_broker_expect_resp1 'fake-vim-runtime' "$_tmp/request.fake-vim-runtime.bin" \
  'fake vim' 'editor runtime check failed'
printf 'PASS broker-test-driver: broker rejects vim that fails runtime check\n'
_restore_allowlist_nano_stub 'fake vim restore: could not set allowlist root ownership'

# ---- Case 5: error path invalid PRE_DIGEST wire ------------------------------------------
_body_pre_err="$_tmp/body.pre-err.bin"
printf 'x' >"$_body_pre_err"
_write_broker_request "$_tmp/request.pre-digest.bad.bin" "$_body_pre_err" "$STUB" 'not-valid-hex'
_run_broker_expect_resp1 'pre-digest-bad' "$_tmp/request.pre-digest.bad.bin" 'bad PRE_DIGEST'
printf 'PASS broker-test-driver: error path (invalid PRE_DIGEST wire)\n'

# ---- Case 6: per-TTY session lock (fail-fast; no blocking wait) --------------------------
# Broker stale-lock recovery uses kill -0 on the pid file. Sandboxes that deny
# kill -0 for children make a live holder look dead: the second broker would
# steal the lock and succeed (false negative). Same probe pattern as
# tests/edit-mode_test.sh.
_broker_check_kill0 || true

if [ "${_broker_kill0_usable:-0}" -eq 0 ]; then
  printf 'SKIP broker-test-driver: per-TTY session lock (kill -0 probe failed)\n'
else
  # Both brokers use EDIT_BROKER_TTY=/dev/null, so _resolve_real_tty falls
  # back to the baked path and the slug is "null". Lock path:
  # $_staging/.edit-broker-lock-null
  _session_lock="$_staging/.edit-broker-lock-null"
  _body_lock="$_tmp/body.lock1.bin"
  printf 'z' >"$_body_lock"
  _allowlist_rewrite_prep
  {
    printf '%s\n' '[nano]'
    printf 'path = %s\n' "$_tmp/stub-sleep3.sh"
    printf '%s\n' '[red]'
    printf 'path = %s\n' "$STUB"
  } >"$_allowlist"
  _sync_allowlist_owner "$_allowlist" \
    || fail_driver 'lock test: could not set allowlist root ownership'
  _req_bg="$_tmp/request.lock-bg.bin"
  _write_broker_request "$_req_bg" "$_body_lock" "$_tmp/stub-sleep3.sh" '-'
  _resp_bg="$_tmp/response.lock-bg.bin"
  # Hold lock ~3s; second broker must fail immediately (after headers) without waiting.
  sh "$BROKER" <"$_req_bg" >"$_resp_bg" 2>/dev/null &
  _bg_pid=$!

  _lock_wait=0
  while [ ! -f "$_session_lock/pid" ]; do
    _lock_wait=$((_lock_wait + 1))
    [ "$_lock_wait" -le 30 ] \
      || fail_driver 'lock test: timed out waiting for first broker to acquire session lock'
    sleep 1
  done

  _req2="$_tmp/request.lock-second.bin"
  _resp2="$_tmp/response.lock-second.bin"
  _err2="$_tmp/broker.lock-second.err"
  _write_broker_request "$_req2" "$_body_lock" "$STUB" '-'
  sh "$BROKER" <"$_req2" >"$_resp2" 2>"$_err2" || true

  exec 3<"$_resp2" || fail_driver "lock busy: cannot open response"
  IFS= read -r _lr <&3 || fail_driver "lock busy: empty response"
  [ "$_lr" = 'RESP_CODE=1' ] || fail_driver "lock busy: expected RESP_CODE=1, got: $_lr"
  case "$(cat "$_err2" 2>/dev/null || true)" in
  *'TTY session lock busy'*) ;;
  '') ;;
  *)
    fail_driver "lock busy: unexpected stderr for lock-busy case"
    ;;
  esac
  exec 3<&-

  wait "$_bg_pid" 2>/dev/null || true
  printf 'PASS broker-test-driver: per-TTY session lock fail-fast\n'
fi

printf '\n'
