#!/bin/sh

# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doas-sudo-shim.
#
# Creates a dedicated unprivileged broker user and initializes the restricted
# staging directory with 0700 permissions.
#
# Execute this directly on the target host (`make post-install` or
# `sudo sh packaging/post-install.sh`). Do not run this during a staged
# `DESTDIR` build, as it mutates host state.
#
# Configuration variables (defaults match the Makefile):
# - DRY_RUN=1:                Prints actions without modifying the system.
# - EDIT_BROKER_USER:         Dedicated user for the broker (default: editbroker).
# - EDIT_BROKER_STAGING_DIR:  Broker scratch space (default: /var/lib/doas-sudo-shim/editbroker).
# - DOAS_SNIPPET_DIR:         Directory for doas rules (default: /etc/doas-sudo-shim).

set -eu

: "${DRY_RUN:=0}"
: "${EDIT_BROKER_USER:=editbroker}"
: "${EDIT_BROKER_STAGING_DIR:=/var/lib/doas-sudo-shim/editbroker}"
: "${DOAS_SNIPPET_DIR:=/etc/doas-sudo-shim}"

snippet="${DOAS_SNIPPET_DIR}/doas-snippet.conf"

log() {
  printf '%s\n' "$*"
}

_user_exists() {
  u=$1
  if command -v getent >/dev/null 2>&1; then
    getent passwd "$u" >/dev/null 2>&1 && return 0
    return 1
  fi
  id -u "$u" >/dev/null 2>&1
}

_create_editbroker_user() {
  u=$1
  if _user_exists "$u"; then
    log "user already exists: $u"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would create system user: $u"
    return 0
  fi
  os=$(uname -s)
  case "$os" in
    Linux)
      if command -v useradd >/dev/null 2>&1; then
        useradd -r -s /sbin/nologin -d /nonexistent -c 'doas-sudo-shim edit broker' "$u"
      elif command -v adduser >/dev/null 2>&1; then
        adduser -D -H -h /nonexistent -s /sbin/nologin "$u"
      else
        printf 'error: user creation failed; create system user %s manually\n' "$u" >&2
        return 1
      fi
      ;;
    FreeBSD|DragonFly)
      pw useradd "$u" -n "$u" -N -s /usr/sbin/nologin -d /nonexistent \
        -c 'doas-sudo-shim edit broker'
      ;;
    OpenBSD|NetBSD)
      if command -v useradd >/dev/null 2>&1; then
        useradd -s /sbin/nologin -d /nonexistent -c 'doas-sudo-shim edit broker' "$u"
      else
        printf 'error: user creation failed; create system user %s manually\n' "$u" >&2
        return 1
      fi
      ;;
    Darwin)
      sysadminctl -addUser "$u" -homeDirectory /nonexistent -shell /usr/bin/false || {
        printf 'error: user creation failed; create system user %s manually\n' "$u" >&2
        return 1
      }
      ;;
    *)
      if command -v useradd >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -d /nonexistent -c 'doas-sudo-shim edit broker' "$u" || {
          printf 'error: user creation failed; create system user %s manually\n' "$u" >&2
          return 1
        }
      else
        printf 'error: unsupported OS (%s); create system user %s manually\n' "$os" "$u" >&2
        return 1
      fi
      ;;
  esac
}

if [ "$(id -u)" -eq 0 ] 2>/dev/null; then
  _create_editbroker_user "$EDIT_BROKER_USER" || exit 1
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would chmod 0700 and chown ${EDIT_BROKER_USER} ${EDIT_BROKER_STAGING_DIR}"
  else
    mkdir -p "$EDIT_BROKER_STAGING_DIR"
    chmod 0700 "$EDIT_BROKER_STAGING_DIR"
    if _user_exists "$EDIT_BROKER_USER"; then
      chown "$EDIT_BROKER_USER:$EDIT_BROKER_USER" "$EDIT_BROKER_STAGING_DIR"
    fi
  fi
else
  log "post-install.sh: not root; skipped user creation and staging chown (re-run as root for broker writes)"
fi

if [ -f "$snippet" ]; then
  log "Merge permit line(s) from $snippet into /etc/doas.conf"
else
  printf 'post-install.sh: snippet not found (install packages first): %s\n' "$snippet" >&2
fi
