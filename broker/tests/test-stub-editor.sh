#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Stub editor for broker/tests/test-driver.sh: exits successfully without modifying
# the file by default. Headless harnesses bake EDIT_BROKER_TTY=/dev/null into the broker.
#
# Optional:
# - STUB_APPEND: append this string to the staging file ($1) before exit
#   (tests digest / body change without a real editor).

if [ -n "${STUB_APPEND:-}" ]; then
  printf '%s' "$STUB_APPEND" >>"$1"
fi
if [ -n "${STUB_SLEEP:-}" ]; then
  for _s in /bin/sleep /usr/bin/sleep; do
    if [ -x "$_s" ]; then
      "$_s" "$STUB_SLEEP"
      break
    fi
  done
fi
exit 0
