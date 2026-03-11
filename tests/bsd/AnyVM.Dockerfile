# syntax=docker/dockerfile:1
# Wrapper around upstream AnyVM: chown /data to host uid on bind mounts.

FROM ghcr.io/anyvm-org/anyvm

RUN printf '%s\n' \
  '#!/bin/sh' \
  '# SPDX-License-Identifier: MIT' \
  'set -eu' \
  '' \
  'UPSTREAM=/anyvm.org/entrypoint.sh' \
  '' \
  '_setup_data() {' \
  '  if [ -z "${ANYVM_HOST_UID:-}" ] || [ -z "${ANYVM_HOST_GID:-}" ]; then' \
  '    return 0' \
  '  fi' \
  '  if [ -d /data ]; then' \
  '    chown -R "${ANYVM_HOST_UID}:${ANYVM_HOST_GID}" /data 2>/dev/null || true' \
  '    chmod 700 /data 2>/dev/null || true' \
  '    find /data -type d ! -perm 700 -exec chmod 700 {} + 2>/dev/null || true' \
  '    find /data -name '"'"'*-host.id_rsa'"'"' -exec chmod 600 {} + 2>/dev/null || true' \
  '  fi' \
  '}' \
  '' \
  '_setup_kvm() {' \
  '  if [ -z "${ANYVM_HOST_UID:-}" ] || [ -z "${ANYVM_HOST_GID:-}" ]; then' \
  '    return 0' \
  '  fi' \
  '  if [ -e /dev/kvm ]; then' \
  '    chown "${ANYVM_HOST_UID}:${ANYVM_HOST_GID}" /dev/kvm 2>/dev/null || true' \
  '  fi' \
  '}' \
  '' \
  "trap '_setup_data' EXIT INT TERM" \
  '' \
  '_setup_data' \
  '_setup_kvm' \
  '' \
  'if [ ! -x "$UPSTREAM" ]; then' \
  '  echo "entrypoint-wrapper: missing $UPSTREAM" >&2' \
  '  exit 1' \
  'fi' \
  '' \
  'exec "$UPSTREAM" "$@"' \
  > /anyvm.org/entrypoint-wrapper.sh && chmod +x /anyvm.org/entrypoint-wrapper.sh

ENTRYPOINT ["/anyvm.org/entrypoint-wrapper.sh"]
