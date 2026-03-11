#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doas-sudo-shim.
#
# Non-interactive "editor" for broker end-to-end tests. The edit broker
# attaches the real controlling tty (see broker/edit-broker.sh); this script
# ignores stdin and only mutates the staging file path in $1.
#
# Listed in the broker allowlist with `path =` this script (example: `[nano]`).
# Default file: /etc/doas-sudo-shim/edit-broker.editors.
#
# Broker passes profile argv before the staged path (e.g. nano: --restricted …),
# so the edit target is the last argument, not $1.

set -eu
[ "$#" -ge 1 ] || exit 1
while [ "$#" -gt 1 ]; do shift; done
printf '%s\n' 'broker-e2e-ok' >>"$1"
