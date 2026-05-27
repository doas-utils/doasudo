# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Shared mockbin prelude for sudoedit harnesses. SOURCED, not executed.
#
# Preconditions: _repo _mockbin _tmp; tests/testlib.sh + utils/metadata-utils.sh sourced.
# Control: _MOCKBIN_EDIT_SUITE — full | broker (default: full).
#   full  — editors + less/more (edit-mode_test.sh)
#   broker — editor_modify only + core tools (broker-integration_test.sh)

# shellcheck shell=sh disable=SC2154
# _repo _mockbin _tmp set by sourcing harness.

: "${_MOCKBIN_EDIT_SUITE:=full}"

case "$_MOCKBIN_EDIT_SUITE" in
full|broker) ;;
*)
  printf 'error: MOCKBIN_EDIT_SUITE must be full or broker (got %s)\n' "$_MOCKBIN_EDIT_SUITE" >&2
  exit 1
  ;;
esac

_sys_path="/usr/bin:/usr/sbin:/bin:/sbin"

# Strip flags; skip --; exec remainder (matches _doas ... -- cmd).
cat > "${_mockbin}/doas" << 'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    *)  shift ;;
  esac
done
exec "$@"
EOF
chmod +x "${_mockbin}/doas"

# editor_modify: sleep 1s (coarse mtime), then overwrite.
cat > "${_mockbin}/editor_modify" << 'EOF'
#!/bin/sh
sleep 1
printf 'edited content\n' > "$1"
EOF
chmod +x "${_mockbin}/editor_modify"

if [ "$_MOCKBIN_EDIT_SUITE" = "full" ]; then
  cat > "${_mockbin}/editor_noop" << 'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "${_mockbin}/editor_noop"

  cat > "${_mockbin}/editor_empty" << 'EOF'
#!/bin/sh
sleep 1
: > "$1"
EOF
  chmod +x "${_mockbin}/editor_empty"

  cat > "${_mockbin}/editor_fail" << 'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "${_mockbin}/editor_fail"

  cat > "${_mockbin}/editor_attack" << 'EOF'
#!/bin/sh
_tmpfile=$1

_write_edited() {
  printf 'edited content\n' > "$_tmpfile"
}

sleep 1

case "${EDITOR_ATTACK_MODE:-none}" in
  swap_tmpfile)
    printf 'edited content\n' > "${_tmpfile}.new" && mv "${_tmpfile}.new" "$_tmpfile"
    ;;

  chmod_dir)
    _write_edited
    : "${EDITOR_ATTACK_DIR:?}"
    : "${EDITOR_ATTACK_DIR_MODE:?}"
    chmod "${EDITOR_ATTACK_DIR_MODE}" "${EDITOR_ATTACK_DIR}"
    ;;

  target_symlink)
    _write_edited
    : "${EDITOR_ATTACK_TARGET:?}"
    rm -f "${EDITOR_ATTACK_TARGET}"
    ln -sf /dev/null "${EDITOR_ATTACK_TARGET}"
    ;;

  remove_tmpfile)
    rm -f "$_tmpfile"
    ;;

  tmpfile_non_regular)
    rm -f "$_tmpfile"
    mkdir "$_tmpfile"
    ;;

  replace_dir)
    _write_edited
    : "${EDITOR_ATTACK_DIR:?}"
    : "${EDITOR_ATTACK_TARGET_BASENAME:?}"
    _att_new="${EDITOR_ATTACK_DIR}.attnew.$$"
    mkdir -p "$_att_new"
    printf 'original\n' > "${_att_new}/${EDITOR_ATTACK_TARGET_BASENAME}"
    rm -rf "${EDITOR_ATTACK_DIR}"
    mv "$_att_new" "${EDITOR_ATTACK_DIR}"
    ;;

  none|*)
    _write_edited
    ;;
esac
EOF
  chmod +x "${_mockbin}/editor_attack"
fi

_symlink_required_tools "$_mockbin" "$_sys_path" id awk stat cat mv chmod rm tty mktemp \
  || exit 1

if [ "$_MOCKBIN_EDIT_SUITE" = "full" ]; then
  cat > "${_mockbin}/less" <<'EOF'
#!/bin/sh
exec /bin/cat "$@"
EOF
  chmod +x "${_mockbin}/less"
  cat > "${_mockbin}/more" <<'EOF'
#!/bin/sh
exec /bin/cat "$@"
EOF
  chmod +x "${_mockbin}/more"
fi

_sys_chmod=$(PATH="$_sys_path" command -v chmod 2>/dev/null) || _sys_chmod=
if [ -z "$_sys_chmod" ]; then
  printf 'error: chmod not found in %s\n' "$_sys_path" >&2
  exit 1
fi

rm -f "${_mockbin}/chmod"
cat > "${_mockbin}/chmod" <<EOF
#!/bin/sh
_real_chmod='${_sys_chmod}'

_mode=\${1:-}
_path=\${2:-}
[ "\${_mode}" = "--" ] && { _mode=\${2:-}; _path=\${3:-}; }

if [ -n "\${MOCK_CHMOD_FAIL_MODE:-}" ] && [ "\${_mode:-}" = "\${MOCK_CHMOD_FAIL_MODE:-}" ]; then
  if [ -z "\${MOCK_CHMOD_FAIL_PATH:-}" ] || [ "\${_path:-}" = "\${MOCK_CHMOD_FAIL_PATH:-}" ]; then
    exit 1
  fi
fi

exec "\${_real_chmod}" "\$@"
EOF
chmod +x "${_mockbin}/chmod"

_chown_log="${_tmp}/chown.log"
: > "$_chown_log"
rm -f "${_mockbin}/chown"
cat > "${_mockbin}/chown" <<EOF
#!/bin/sh
_log='${_chown_log}'

if [ "\${1:-}" = "-h" ]; then shift; fi
if [ "\${1:-}" = "--" ]; then shift; fi
_owner_group=\${1:-}
_path=\${2:-}

printf '%s\t%s\n' "\${_owner_group}" "\${_path}" >> "\$_log"

if [ -n "\${MOCK_CHOWN_FAIL_OWNER_GROUP:-}" ] && [ "\${_owner_group:-}" = "\${MOCK_CHOWN_FAIL_OWNER_GROUP:-}" ]; then
  if [ -z "\${MOCK_CHOWN_FAIL_PATH:-}" ] || [ "\${_path:-}" = "\${MOCK_CHOWN_FAIL_PATH:-}" ]; then
    exit 1
  fi
fi

exit 0
EOF
chmod +x "${_mockbin}/chown"

rm -f "${_mockbin}/id"
cat > "${_mockbin}/id" << 'EOF'
#!/bin/sh
case "${1:-}" in
  -ru)  printf '0\n' ;;
  -rg)  printf '0\n' ;;
  -run) printf 'root\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${_mockbin}/id"

_setup_sha_tool "$_mockbin" "no SHA-256 checksum tool found in $_sys_path" >/dev/null \
  || exit 1
_mock_sha_tool="${_mockbin}/${_SHA_KIND}"

MAKE=${MAKE:-make}
rm -f "${_repo}/lib/shim-utils.sh"
# shellcheck disable=SC2046
(cd "$_repo" && "$MAKE" $(_make_s) lib/shim-utils.sh lib/edit-broker-client.sh SHIM_PATH="${_mockbin}:${_sys_path}") \
  || { printf 'error: make lib/shim-utils.sh lib/edit-broker-client.sh failed\n' >&2; exit 1; }

_utils_utils_path="${_repo}/lib/shim-utils.sh"
_utils_metadata=$(_compute_metadata "$_utils_utils_path" 644 stat-ug) || {
  printf 'error: could not compute metadata for lib/shim-utils.sh\n' >&2
  exit 1
}

cat > "${_mockbin}/getent" << 'EOF'
#!/bin/sh
set -eu
case "${1:-}" in
  passwd) ;;
  *) exit 2 ;;
esac
awk -F: -v u="$2" '$1==u { print; found=1; exit } END { exit found?0:1 }' /etc/passwd
EOF
chmod +x "${_mockbin}/getent"
