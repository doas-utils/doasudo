# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Path-only allowlist: [name] stanzas and path = lines only.
#
# Usage:
#   awk -f allowlist-parse.awk /path/to/edit-broker.editors
#     Validate only; exit 0 / 1.
#   awk -v DUMP=1 -f allowlist-parse.awk /path/to/edit-broker.editors
#     Lint / debug: canonical dump on stdout; optional test -x stderr warnings.
#   EDITOR_REQ=/abs/path awk -f allowlist-parse.awk /path/to/edit-broker.editors
#     Query: print EXEC line then PROFILE canonical name for first matching stanza.
#     Exit 1 = malformed; exit 2 = valid file but EDITOR_REQ not listed.
#     EDITOR_REQ takes precedence over DUMP; query mode skips test -x checks.

BEGIN {
  fatal = 0
  within_stanza = 0
  seen_stanza = 0
  name = ""
  npath = 0
  entry_match = 0
  entry_exec_path = ""
  editor = ENVIRON["EDITOR_REQ"]
  editor_id = ""
  query_done = 0
}

function die(msg) {
  print "allowlist-parse: " msg > "/dev/stderr"
  fatal = 1
  exit 1
}

function warn(msg) {
  print "allowlist-parse: warning: " msg > "/dev/stderr"
}

function trim(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
}

function is_abs_path(p) {
  return (substr(p, 1, 1) == "/")
}

function sh_quote(s, r) {
  r = s
  gsub(/'/, "'\\''", r)
  return "'" r "'"
}

function check_executable(p) {
  cmd = "test -x " sh_quote(p) " 2>/dev/null"
  rc = system(cmd)
  if (rc != 0) warn("path not executable (yet?): " p)
}

function normalize_header(n) {
  if (n == "vi") return "vim"
  return n
}

function flush_stanza(i) {
  if (!within_stanza) return
  if (npath < 1) die("stanza [" name "]: at least one path = is required")

  if (editor != "" && entry_match && !query_done) {
    query_done = 1
    print "EXEC", entry_exec_path
    print "PROFILE", editor_id
  }

  if (DUMP && editor == "") {
    print "STANZA", editor_id
    print "EXEC", paths[1]
    for (i = 2; i <= npath; i++) print "ALIAS", paths[i]
    print "ENDSTANZA"
  }

  within_stanza = 0
  name = ""
  editor_id = ""
  for (i = 1; i <= npath; i++) delete paths[i]
  npath = 0
  entry_match = 0
  entry_exec_path = ""
}

{
  line = trim($0)
  if (line == "" || line ~ /^#/) next

  if (line ~ /^\[[a-z][a-z0-9_-]*\]$/) {
    flush_stanza()
    name = substr(line, 2, length(line) - 2)
    editor_id = normalize_header(name)
    within_stanza = 1
    seen_stanza = 1
    next
  }

  if (!within_stanza)
    die("line before first editor stanza: " line)

  if (line ~ /^[ \t]*(flags|env|config)[ \t]*=/)
    die("allowlist: \"flags\", \"env\", and \"config\" are removed; only path = allowed (stanza [" name "])")

  if (line !~ /^[ \t]*path[ \t]*=/)
    die("unknown key (expected path = ... only): " line)

  match(line, /^[ \t]*path[ \t]*=/)
  val = substr(line, RSTART + RLENGTH)
  val = trim(val)

  if (val == "") die("empty path value in stanza [" name "]")
  if (!is_abs_path(val)) die("path must be absolute in stanza [" name "]: " val)
  if (val in global_path) die("duplicate path across stanzas: " val)
  global_path[val] = 1
  npath++
  paths[npath] = val
  if (editor != "" && val == editor) {
    entry_match = 1
    entry_exec_path = val
  }
  if (DUMP) check_executable(val)
  next
}

END {
  if (fatal) exit 1

  if (!seen_stanza) die("no editor stanza in file")

  flush_stanza()

  if (editor != "") {
    if (!query_done) {
      print "allowlist-parse: editor not in allowlist: " editor > "/dev/stderr"
      exit 2
    }
  }

  exit 0
}
