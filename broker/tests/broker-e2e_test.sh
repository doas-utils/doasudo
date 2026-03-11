#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doas-sudo-shim.
#
# broker-e2e_test.sh: host integration check with real doas(1), edit broker, baked shim.
#
# Runs as a non-root user that may invoke the broker as editbroker (see doas.conf).
#
# Prerequisites:
# - Shim installed and on PATH as `sudo` (override with SHIM=) and must be
#   doas-sudo-shim (grepped from file).
# - Broker executable at EDIT_BROKER_PATH (default below).
# - Shim was *built after* that broker was installed so EDIT_BROKER_METADATA matches.
# - doas.conf permits: permit ... as editbroker cmd <EDIT_BROKER_PATH>
#   for the invoking user (default: :editas, if unchanged).
# - Allowlist file lists BROKER_E2E_EDITOR (absolute path to e2e-append-editor.sh).
# - BROKER_E2E_TARGET: existing regular file, readable by you, whose directory
#   path passes the shim's writable-directory walk (avoid /var/lib in Docker:
#   overlays often make /var* components -w for test users). Default is under
#   PREFIX/share beside other install assets. Bootstrap once as root via
#   broker-e2e-setup.sh, or e.g.:
#     install -d /usr/local/share/doas-sudo-shim
#     umask 022
#     printf 'seed\n' > /usr/local/share/doas-sudo-shim/broker-e2e-seed
#     chown 0:0 /usr/local/share/doas-sudo-shim/broker-e2e-seed
#     chmod 644 /usr/local/share/doas-sudo-shim/broker-e2e-seed
#
# Usage:
#   sh tests/broker-e2e_test.sh
#   SHIM=/usr/local/bin/sudo BROKER_E2E_TARGET=... BROKER_E2E_EDITOR=... sh tests/broker-e2e_test.sh

set -eu

_root=$(CDPATH="" cd -P -- "$(dirname -- "$0")/.." && pwd)

die() {
	printf 'broker-e2e_test.sh: %s\n' "$1" >&2
	exit 1
}

[ "$(id -u)" -ne 0 ] || die 'run as a non-root user (edit mode is for unprivileged invokers)'

SHIM=${SHIM:-sudo}
case "$SHIM" in
/*) _shim=$SHIM ;;
*)
	_shim=$(command -v "$SHIM" 2>/dev/null) || _shim=
	[ -n "$_shim" ] || die "shim not found on PATH (set SHIM to full path): $SHIM"
	;;
esac
[ -x "$_shim" ] || die "not executable: $_shim"
grep -q 'doas-sudo-shim' "$_shim" 2>/dev/null \
	|| die "file does not look like doas-sudo-shim (wrong SHIM=?): $_shim"

EDIT_BROKER_PATH=${EDIT_BROKER_PATH:-/usr/local/libexec/doas-sudo-shim/edit-broker}
[ -x "$EDIT_BROKER_PATH" ] || die "broker not executable: $EDIT_BROKER_PATH (make install / set EDIT_BROKER_PATH)"

ALLOWLIST_PATH=${ALLOWLIST_PATH:-/etc/doas-sudo-shim/edit-broker.editors}
[ -r "$ALLOWLIST_PATH" ] || die "allowlist not readable: $ALLOWLIST_PATH"

BROKER_E2E_EDITOR=${BROKER_E2E_EDITOR:-"$_root/broker/e2e-append-editor.sh"}
[ -x "$BROKER_E2E_EDITOR" ] || die "E2E editor not executable: $BROKER_E2E_EDITOR (chmod +x or set BROKER_E2E_EDITOR)"

_allowlisted=0
while IFS= read -r _line || [ -n "$_line" ]; do
	case "$_line" in
	''|'#'*) continue ;;
	'path = '*)
		_p=${_line#path = }
		_p=${_p%% }
		[ "$_p" = "$BROKER_E2E_EDITOR" ] && {
			_allowlisted=1
			break
		}
		;;
	esac
done <"$ALLOWLIST_PATH"
[ "$_allowlisted" -eq 1 ] \
	|| die "allowlist missing editor line starting with: $BROKER_E2E_EDITOR (see $ALLOWLIST_PATH)"

BROKER_E2E_TARGET=${BROKER_E2E_TARGET:-/usr/local/share/doas-sudo-shim/broker-e2e-seed}
[ -f "$BROKER_E2E_TARGET" ] || die "target missing: $BROKER_E2E_TARGET (create per header comment as root)"
[ -r "$BROKER_E2E_TARGET" ] || die "target not readable: $BROKER_E2E_TARGET"

command -v doas >/dev/null 2>&1 || die 'doas not found on PATH'

# Prove doas permits the broker hop (nopass). Invalid MAGIC -> quick RESP_CODE=1.
_resp=$(
	printf 'MAGIC=WRONG\n' | doas -n -u editbroker -- "$EDIT_BROKER_PATH" 2>/dev/null | head -n 1
) || true
[ "$_resp" = 'RESP_CODE=1' ] \
	|| die "doas brokerSmoke failed (expected RESP_CODE=1). Got ${_resp:-'(empty)'}. Doas rule & editbroker user OK?"

export SUDO_SHIM_EDIT_BROKER=1
unset VISUAL
export SUDO_EDITOR="$BROKER_E2E_EDITOR"

if ! "$_shim" -n -e "$BROKER_E2E_TARGET"; then
	die "shim edit mode failed (exit status). stderr should mention broker/doas if misconfigured."
fi

grep -Fx 'broker-e2e-ok' "$BROKER_E2E_TARGET" >/dev/null 2>&1 \
	|| die "marker line broker-e2e-ok missing after edit (broker path or allowlist broken?)"

printf 'PASS broker_e2e_test (target=%s editor=%s)\n' "$BROKER_E2E_TARGET" "$BROKER_E2E_EDITOR"
