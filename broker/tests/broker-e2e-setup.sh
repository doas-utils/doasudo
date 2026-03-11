#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doas-sudo-shim.
#
# Root-only setup for broker e2e: `make` (unless BROKER_E2E_SKIP_BUILD=1),
# `make install` (live install folds post-install), shim links, e2e editor,
# allowlist, seed file under PREFIX/share (not /var/lib: Docker overlays can make
# /var* path components user-writable and trip the shim's edit-mode walk), optional
# append permit lines to /etc/doas.conf.
#
# Environment (passed by make broker-e2e-setup):
#   PREFIX, BINDIR, EDIT_BROKER_PATH, DOAS_SNIPPET_DIR
#   BROKER_E2E_APPEND_DOAS_CONF: if 1, append permit lines from
#     doas-snippet.conf into /etc/doas.conf when not already present (opt-in).
#   BROKER_E2E_SKIP_BUILD: if 1, skip `make` (caller already ran it, e.g. as non-root).

set -eu

[ "$(id -u)" -eq 0 ] || {
	printf 'broker-e2e-setup.sh: must run as root\n' >&2
	exit 1
}

: "${PREFIX:=/usr/local}"
: "${BINDIR:=${PREFIX}/bin}"
: "${EDIT_BROKER_PATH:=${PREFIX}/libexec/doas-sudo-shim/edit-broker}"
: "${DOAS_SNIPPET_DIR:=/etc/doas-sudo-shim}"
: "${BROKER_E2E_APPEND_DOAS_CONF:=0}"
: "${BROKER_E2E_SKIP_BUILD:=0}"

_repo=$(CDPATH="" cd -P -- "$(dirname -- "$0")/../.." && pwd)
cd "$_repo"
_make="${MAKE:-make}"

_install_shim_links() {
	install -d "${BINDIR}"
	install -m 755 doas-sudo-shim "${BINDIR}/sudo"
	ln -sf sudo "${BINDIR}/sudoedit"
	ln -sf sudo "${BINDIR}/editas"
}

if [ "$BROKER_E2E_SKIP_BUILD" != 1 ]; then
	"${_make}"
fi
"${_make}" install
_install_shim_links

_e2e_editor="${PREFIX}/libexec/doas-sudo-shim/e2e-append-editor.sh"
install -d "$(dirname -- "$_e2e_editor")"
install -m 755 "$_repo/broker/tests/e2e-append-editor.sh" "$_e2e_editor"

_allow="${DOAS_SNIPPET_DIR}/edit-broker.editors"
install -d "$DOAS_SNIPPET_DIR"
# E2E allowlist: broker needs only this editor path for broker-e2e_test.sh.
{
	printf '%s\n' '[nano]'
	printf 'path = %s\n' "$_e2e_editor"
} >"$_allow"
chmod 644 "$_allow"

_e2e_seed="${PREFIX}/share/doas-sudo-shim/broker-e2e-seed"
install -d "${PREFIX}/share/doas-sudo-shim"
umask 022
printf 'seed\n' > "$_e2e_seed"
chown 0:0 "$_e2e_seed"
chmod 644 "$_e2e_seed"

if [ "$BROKER_E2E_APPEND_DOAS_CONF" = "1" ]; then
	if [ ! -f /etc/doas.conf ]; then
		printf 'broker-e2e-setup: /etc/doas.conf missing; create it before appending policy\n' >&2
	else
		_snip="${DOAS_SNIPPET_DIR}/doas-snippet.conf"
		if [ ! -r "$_snip" ]; then
			printf 'broker-e2e-setup: snippet not readable: %s\n' "$_snip" >&2
			exit 1
		fi
		_added=0
		while IFS= read -r _line || [ -n "$_line" ]; do
			case "$_line" in
			''|'#'*) continue ;;
			esac
			if ! grep -qF "$_line" /etc/doas.conf 2>/dev/null; then
				if [ "$_added" -eq 0 ]; then
					printf '\n# doas-sudo-shim broker E2E\n' >> /etc/doas.conf
					_added=1
				fi
				printf '%s\n' "$_line" >> /etc/doas.conf
			fi
		done <"$_snip"
		chmod 400 /etc/doas.conf 2>/dev/null || true
	fi
else
	printf 'broker-e2e-setup: merge %s/doas-snippet.conf into doas.conf (or rerun with BROKER_E2E_APPEND_DOAS_CONF=1)\n' "$DOAS_SNIPPET_DIR" >&2
fi

printf 'broker-e2e-setup: done. Run as a non-root user allowed by DOAS_PERMIT_IDENTITY, e.g.:\n  make check-broker-e2e BROKER_E2E_RUN_USER=youruser\n' >&2
