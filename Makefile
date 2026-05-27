# SPDX-License-Identifier: MIT
# See LICENSE.md. Part of doas-utils/doasudo.
#
# Makefile for doasudo
#
# Install:
#   make && doas make install         # test/build as normal user, privileged install
#   make check && doas make install   # same as above
#   make install PREFIX=/usr
#   make install DESTDIR=/tmp/pkg     # staged: no folded post-install (DESTDIR set)
#
# Default install includes the edit broker (binary, awk, contracts, staging dir),
# policy files (snippet, shipped config dir under $(DOAS_SNIPPET_DIR)/config/,
# example allowlist), and EDIT_BROKER_STAGING_DIR (0700). Broker mode is unused
# until doas policy permits it.
# EDIT_BROKER_METADATA / UTILS_METADATA bake from build-tree files at recipe time
# (not at Makefile parse). Packaging: same DESTDIR/PREFIX for one `make install`.
#
# Host post-install: folded into `make install` when DESTDIR empty and root; or
# `make post-install` / `sh packaging/post-install.sh` (packager %post, manual rerun).
#
# Broker E2E: doas make broker-e2e-setup (`make check` unless BROKER_E2E_SKIP_BUILD=1, e.g. after
#   Docker image `make check`); then make check-broker-e2e BROKER_E2E_RUN_USER=user.
#
# Installs $(DESTDIR)$(BINDIR)/sudo; sudoedit and editas symlink to it.
# Uninstall: `make uninstall` removes the same layout as `make install` (including policy files).

# This Makefile requires GNU Make (gmake on BSD). Fail fast if invoked as bmake.
ifeq ($(filter undefined,$(origin .FEATURES)),undefined)
  GMAKE := $(shell command -v gmake 2>/dev/null)
  ifneq ($(GMAKE),)
    $(error Use GNU Make: $(GMAKE) $(MAKECMDGOALS))
  else
    $(error GNU Make required; install gmake and re-run)
  endif
endif

# Passed to check-src shell recipes and recursive $(MAKE).
export MAKE

# Recipes use two spaces, not TAB (GNU Make 3.82+).
.RECIPEPREFIX := $(subst X, ,X)

# ---- Variables ---------------------------------------------------------------------------

# ---- Base install roots ------------------------------------------------------------------
PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
SBINDIR ?= $(PREFIX)/sbin

VERSION := $(shell cat VERSION)

# ---- Shim and broker paths ---------------------------------------------------------------
# Shim runtime PATH (ignores the caller's PATH). Includes sbin (doas may live
# there). Override for non-standard layouts (NixOS, pkgsrc, etc.).
SHIM_PATH ?= $(BINDIR):$(SBINDIR):/usr/bin:/usr/sbin:/bin:/sbin
# Installed helpers; broker sources shim-utils.sh too.
SHIM_LIBEXEC_DIR ?= $(PREFIX)/libexec/doasudo
SHIM_UTILS ?= $(SHIM_LIBEXEC_DIR)/shim-utils.sh
EDIT_BROKER_CLIENT ?= $(SHIM_LIBEXEC_DIR)/edit-broker-client.sh
EDIT_BROKER_PATH ?= $(SHIM_LIBEXEC_DIR)/edit-broker
EDIT_BROKER_CONTRACTS_PATH ?= $(SHIM_LIBEXEC_DIR)/edit-broker-contracts.env

# Broker staging (one mktemp file per request; not TMPDIR).
EDIT_BROKER_STAGING_DIR ?= /var/lib/doasudo/editbroker
# Editor stdio TTY (must be /dev/...). Baked into the edit broker
# (/dev/tty default; tests use broker/build-to with EDIT_BROKER_TTY=/dev/null).
EDIT_BROKER_TTY ?= /dev/tty
# Broker UNIX user; doas snippet and post-install.sh. Override to match policy.
EDIT_BROKER_USER ?= editbroker
DOAS_PERMIT_IDENTITY ?= :editas
SYSCONFDIR ?= /etc
DOAS_SNIPPET_DIR ?= $(SYSCONFDIR)/doasudo
# Broker allowlist path (baked in; not read from the environment).
BROKER_ALLOWLIST_PATH ?= $(DOAS_SNIPPET_DIR)/edit-broker.editors

# ---- Broker wire contracts ---------------------------------------------------------------
# EDITBROKER/1 constants: broker, client, and installed file must agree.
EDIT_BROKER_CONTRACTS_ENV ?= config/edit-broker-contracts.env
# $(1) = key name in KEY=value lines.
define _contract_field
$(shell awk -F= '$$1=="$(1)"{print $$2; exit}' $(EDIT_BROKER_CONTRACTS_ENV))
endef
BROKER_CONTRACT_MAGIC := $(call _contract_field,MAGIC)
BROKER_CONTRACT_MAX_BYTES := $(call _contract_field,MAX_BROKER_BYTES)
BROKER_CONTRACT_RESPONSE_TIMEOUT := $(call _contract_field,BROKER_RESPONSE_TIMEOUT_S)
# $(1) = contract key; $(2) = $(call _contract_field,$(1)). Error if empty.
define _require_contract_val
$(if $(strip $(2)),,$(error empty or missing $(1) in $(EDIT_BROKER_CONTRACTS_ENV)))
endef
$(eval $(call _require_contract_val,MAGIC,$(BROKER_CONTRACT_MAGIC)))
$(eval $(call _require_contract_val,MAX_BROKER_BYTES,$(BROKER_CONTRACT_MAX_BYTES)))
$(eval $(call _require_contract_val,BROKER_RESPONSE_TIMEOUT_S,$(BROKER_CONTRACT_RESPONSE_TIMEOUT)))

# ---- Host post-install and E2E knobs -----------------------------------------------------
# packaging/post-install.sh (host only; optional DRY_RUN=1).
DRY_RUN ?= 0
# broker-e2e-setup.sh / check-broker-e2e.
BROKER_E2E_APPEND_DOAS_CONF ?= 0
# When 1, broker-e2e-setup.sh skips `make check` (caller already verified, e.g. image build layer).
BROKER_E2E_SKIP_BUILD ?= 0
BROKER_E2E_RUN_USER ?=
# env(1) arguments for broker/tests/broker-e2e_test.sh in check-broker-e2e.
BROKER_E2E_ENV := \
  EDIT_BROKER_PATH="$(EDIT_BROKER_PATH)" \
  SHIM="$(BINDIR)/sudo" \
  BROKER_E2E_EDITOR="$(SHIM_LIBEXEC_DIR)/e2e-append-editor.sh" \
  ALLOWLIST_PATH="$(DOAS_SNIPPET_DIR)/edit-broker.editors" \
  BROKER_E2E_TARGET=$(PREFIX)/share/doasudo/broker-e2e-seed

# ---- Baked metadata ----------------------------------------------------------------------
# EDIT_BROKER_METADATA / UTILS_METADATA: baked into the shim and broker. Format
# <sha256hex>:0:0:<mode> (root-owned expectation; mode matches install -m).
# Recursive = + override: $(shell _compute_metadata ...) runs when recipes expand,
# after prerequisites refresh sources; digest not overridable from env/CLI.
# UTILS_METADATA_PATH (default lib/shim-utils.sh) + optional UTILS_METADATA_COMPUTE_MODE=stat-ug
# for harnesses hashing a different path with live uid/gid (see utils/metadata-utils.sh).
_metadata_utils ?= $(CURDIR)/utils/metadata-utils.sh
UTILS_METADATA_PATH = $(CURDIR)/lib/shim-utils.sh
UTILS_METADATA_COMPUTE_MODE =

override UTILS_METADATA = $(shell . "$(_metadata_utils)" && _compute_metadata "$(UTILS_METADATA_PATH)" 644 $(UTILS_METADATA_COMPUTE_MODE) 2>/dev/null || true)
override EDIT_BROKER_METADATA = $(shell . "$(_metadata_utils)" && _compute_metadata "$(CURDIR)/broker/edit-broker.sh" 755 2>/dev/null || true)
override EDIT_BROKER_CLIENT_METADATA = $(shell . "$(_metadata_utils)" && _compute_metadata "$(CURDIR)/lib/edit-broker-client.sh" 644 2>/dev/null || true)

# ---- Allowlist parser and shipped broker configs ----------------------------------------
# Profile allowlist parser (installed beside the broker; path baked into edit-broker.sh).
BROKER_ALLOWLIST_PARSER ?= $(SHIM_LIBEXEC_DIR)/allowlist-parse.awk
# Shipped broker config dir (basename per registry arm lives here); per-file metadata overrides below.
BROKER_CONFIG_DIR ?= $(DOAS_SNIPPET_DIR)/config
# Baked digest for shipped vimrc only; additional files → Makefile override + @...@ bake + registry arm.
override BROKER_CONFIG_VIMRC_METADATA = $(shell . "$(_metadata_utils)" && _compute_metadata "$(CURDIR)/config/vimrc" 644 2>/dev/null || true)

# ---- Install command defaults ------------------------------------------------------------
DESTDIR ?=
INSTALL ?= install

# ---- Symlink behavior --------------------------------------------------------------------
# ln -f for sudoedit/editas symlinks: make install OVERWRITE_SYMLINKS=1
OVERWRITE_SYMLINKS ?=
ifneq ($(OVERWRITE_SYMLINKS),$(filter 1,$(OVERWRITE_SYMLINKS)))
$(error OVERWRITE_SYMLINKS must be empty or 1)
endif
_LN_FLAGS := $(if $(OVERWRITE_SYMLINKS),-f,)

# ---- Substitution helpers ----------------------------------------------------------------
# sed(1) delimiter: ASCII SOH (0x01). Unlikely in paths; '|' appears in paths and would break sed -e.
_SEP := $(shell printf '\001')
# $(1) = placeholder name (no @); $(2) = replacement. One -e per line when recipes echo.
define _sed_entry
-e "s$(_SEP)@$(1)@$(_SEP)$(2)$(_SEP)"
endef
# $(1) = output path; $(2) = grep -E pattern for leftover @...@ placeholders.
define _verify_no_unsubst
  @grep -qE '$(2)' "$(1)" \
    && { printf 'error: substitution failed in %s\n' "$(1)" >&2; rm -f "$(1)"; exit 1; } \
    || true
endef
# broker substitutions: pipe-separated tokens (no (...) in pattern; breaks $(call)).
BROKER_SUBST_CHECK_ERE := @EDIT_BROKER_STAGING_DIR@|@ALLOWLIST_PATH@|@ALLOWLIST_PARSER@|@EDIT_BROKER_TTY@|@BINDIR@|@MAGIC@|@MAX_BROKER_BYTES@|@BROKER_CONFIG_DIR@|@BROKER_CONFIG_VIMRC_METADATA@|@SHIM_UTILS@|@UTILS_METADATA@

# ---- Build -------------------------------------------------------------------------------

lib/shim-utils.sh: lib/shim-utils.sh.in Makefile
  sed \
    $(call _sed_entry,BINDIR,$(SHIM_PATH)) \
    lib/shim-utils.sh.in > "$@"
  chmod 644 "$@"
  $(call _verify_no_unsubst,$@,@BINDIR@)

# Ad hoc shim-utils path: shim-utils/build-to SHIM_UTILS_BUILD_TO=/tmp/u.sh SHIM_PATH=...
.PHONY: shim-utils/build-to
shim-utils/build-to: lib/shim-utils.sh.in Makefile
  @test -n "$(SHIM_UTILS_BUILD_TO)" || { printf 'error: SHIM_UTILS_BUILD_TO required\n' >&2; exit 1; }
  sed \
    $(call _sed_entry,BINDIR,$(SHIM_PATH)) \
    lib/shim-utils.sh.in > "$(SHIM_UTILS_BUILD_TO)"
  chmod 644 "$(SHIM_UTILS_BUILD_TO)"
  $(call _verify_no_unsubst,$(SHIM_UTILS_BUILD_TO),@BINDIR@)

lib/edit-broker-client.sh: lib/edit-broker-client.sh.in Makefile $(EDIT_BROKER_CONTRACTS_ENV)
  sed \
    $(call _sed_entry,MAGIC,$(BROKER_CONTRACT_MAGIC)) \
    $(call _sed_entry,EDIT_BROKER_USER,$(EDIT_BROKER_USER)) \
    $(call _sed_entry,MAX_BROKER_BYTES,$(BROKER_CONTRACT_MAX_BYTES)) \
    $(call _sed_entry,BROKER_RESPONSE_TIMEOUT_S,$(BROKER_CONTRACT_RESPONSE_TIMEOUT)) \
    $< > $@
  $(call _verify_no_unsubst,$@,@MAGIC@|@EDIT_BROKER_USER@|@MAX_BROKER_BYTES@|@BROKER_RESPONSE_TIMEOUT_S@)

# Bakes SHIM_PATH, broker paths, UTILS_METADATA, VERSION, etc. Remaining @...@ in
# the output fails the grep below.
#
# Makefile is a prerequisite so SHIM_PATH (and other make-vars) edits rebuild
# the binary; otherwise the target timestamp can look fresh while baked paths rot.
doasudo: doasudo.in VERSION Makefile lib/shim-utils.sh lib/edit-broker-client.sh broker/edit-broker.sh
  sed \
    $(call _sed_entry,BINDIR,$(SHIM_PATH)) \
    -e '/^# @EDIT_BROKER_METADATA@$$/c\
_EDIT_BROKER_CLIENT='\''$(EDIT_BROKER_CLIENT)'\''\
_EDIT_BROKER_CLIENT_METADATA='\''$(EDIT_BROKER_CLIENT_METADATA)'\''\
_EDIT_BROKER_PATH='\''$(EDIT_BROKER_PATH)'\''\
_EDIT_BROKER_METADATA='\''$(EDIT_BROKER_METADATA)'\''' \
    $(call _sed_entry,UTILS_METADATA,$(UTILS_METADATA)) \
    $(call _sed_entry,VERSION,$(VERSION)) \
    $(call _sed_entry,SHIM_UTILS,$(SHIM_UTILS)) \
    $< > $@
  $(call _verify_no_unsubst,$@,@BINDIR@|@UTILS_METADATA@|@VERSION@|@SHIM_UTILS@|@EDIT_BROKER_METADATA@)

# Edit broker: sed same @...@ tokens as the shim (@BINDIR@ = SHIM_PATH).
broker/edit-broker.sh: broker/edit-broker.sh.in Makefile $(EDIT_BROKER_CONTRACTS_ENV) lib/shim-utils.sh broker/allowlist-parse.awk
  sed \
    $(call _sed_entry,EDIT_BROKER_STAGING_DIR,$(EDIT_BROKER_STAGING_DIR)) \
    $(call _sed_entry,ALLOWLIST_PATH,$(BROKER_ALLOWLIST_PATH)) \
    $(call _sed_entry,EDIT_BROKER_TTY,$(EDIT_BROKER_TTY)) \
    $(call _sed_entry,BINDIR,$(SHIM_PATH)) \
    $(call _sed_entry,MAGIC,$(BROKER_CONTRACT_MAGIC)) \
    $(call _sed_entry,MAX_BROKER_BYTES,$(BROKER_CONTRACT_MAX_BYTES)) \
    $(call _sed_entry,ALLOWLIST_PARSER,$(BROKER_ALLOWLIST_PARSER)) \
    $(call _sed_entry,BROKER_CONFIG_DIR,$(BROKER_CONFIG_DIR)) \
    $(call _sed_entry,BROKER_CONFIG_VIMRC_METADATA,$(BROKER_CONFIG_VIMRC_METADATA)) \
    $(call _sed_entry,SHIM_UTILS,$(SHIM_UTILS)) \
    $(call _sed_entry,UTILS_METADATA,$(UTILS_METADATA)) \
    broker/edit-broker.sh.in > "$@"
  chmod 755 "$@"
  $(call _verify_no_unsubst,$@,$(BROKER_SUBST_CHECK_ERE))

# Ad hoc broker path: broker/build-to BROKER_BUILD_TO=/tmp/b.sh plus overrides
# (EDIT_BROKER_STAGING_DIR, BROKER_ALLOWLIST_PATH, ...). MAGIC/limits from Makefile.
.PHONY: broker/build-to
broker/build-to: broker/edit-broker.sh.in Makefile
  @test -n "$(BROKER_BUILD_TO)" || { printf 'error: BROKER_BUILD_TO required\n' >&2; exit 1; }
  sed \
    $(call _sed_entry,EDIT_BROKER_STAGING_DIR,$(EDIT_BROKER_STAGING_DIR)) \
    $(call _sed_entry,ALLOWLIST_PATH,$(BROKER_ALLOWLIST_PATH)) \
    $(call _sed_entry,EDIT_BROKER_TTY,$(EDIT_BROKER_TTY)) \
    $(call _sed_entry,BINDIR,$(SHIM_PATH)) \
    $(call _sed_entry,MAGIC,$(BROKER_CONTRACT_MAGIC)) \
    $(call _sed_entry,MAX_BROKER_BYTES,$(BROKER_CONTRACT_MAX_BYTES)) \
    $(call _sed_entry,ALLOWLIST_PARSER,$(BROKER_ALLOWLIST_PARSER)) \
    $(call _sed_entry,BROKER_CONFIG_DIR,$(BROKER_CONFIG_DIR)) \
    $(call _sed_entry,BROKER_CONFIG_VIMRC_METADATA,$(BROKER_CONFIG_VIMRC_METADATA)) \
    $(call _sed_entry,SHIM_UTILS,$(SHIM_UTILS)) \
    $(call _sed_entry,UTILS_METADATA,$(UTILS_METADATA)) \
    broker/edit-broker.sh.in > "$(BROKER_BUILD_TO)"
  chmod 755 "$(BROKER_BUILD_TO)"
  $(call _verify_no_unsubst,$(BROKER_BUILD_TO),$(BROKER_SUBST_CHECK_ERE))

# ---- Install -----------------------------------------------------------------------------

# Default EDIT_BROKER_SRC is generated broker/edit-broker.sh; override to ship another binary.
EDIT_BROKER_SRC ?= broker/edit-broker.sh
EDIT_BROKER_CONTRACTS_SRC ?= config/edit-broker-contracts.env

.PHONY: install
install: doasudo $(if $(subst broker/edit-broker.sh,,$(EDIT_BROKER_SRC)),,broker/edit-broker.sh)
  @( PATH="$(SHIM_PATH)"; command -v doas >/dev/null 2>&1 ) \
    || printf 'warning: doas not found in SHIM_PATH=%s\n' "$(SHIM_PATH)" >&2
  $(INSTALL) -d $(DESTDIR)$(SHIM_LIBEXEC_DIR)
  $(INSTALL) -m 644 lib/shim-utils.sh $(DESTDIR)$(SHIM_UTILS)
  $(INSTALL) -m 644 lib/edit-broker-client.sh $(DESTDIR)$(EDIT_BROKER_CLIENT)
  $(INSTALL) -d $(DESTDIR)$(BINDIR)
  $(INSTALL) -m 755 doasudo $(DESTDIR)$(BINDIR)/sudo
  @cmp -s doasudo $(DESTDIR)$(BINDIR)/sudo \
    || { printf 'error: installed binary differs from built binary\n' >&2; exit 1; }
  # Relative link target: sudo -> same dir's sudo (BINDIR).
  ln -s $(_LN_FLAGS) sudo $(DESTDIR)$(BINDIR)/sudoedit
  ln -s $(_LN_FLAGS) sudo $(DESTDIR)$(BINDIR)/editas
  @test -f "$(EDIT_BROKER_SRC)" \
    || { printf 'error: EDIT_BROKER_SRC not found: %s\n' "$(EDIT_BROKER_SRC)" >&2; exit 1; }
  @test -f "$(EDIT_BROKER_CONTRACTS_SRC)" \
    || { printf 'error: EDIT_BROKER_CONTRACTS_SRC not found: %s\n' "$(EDIT_BROKER_CONTRACTS_SRC)" >&2; exit 1; }
  $(INSTALL) -d $(DESTDIR)$(dir $(EDIT_BROKER_PATH))
  $(INSTALL) -d $(DESTDIR)$(dir $(EDIT_BROKER_CONTRACTS_PATH))
  $(INSTALL) -m 755 "$(EDIT_BROKER_SRC)" $(DESTDIR)$(EDIT_BROKER_PATH)
  $(INSTALL) -m 644 broker/allowlist-parse.awk $(DESTDIR)$(BROKER_ALLOWLIST_PARSER)
  $(INSTALL) -m 644 "$(EDIT_BROKER_CONTRACTS_SRC)" $(DESTDIR)$(EDIT_BROKER_CONTRACTS_PATH)
  $(INSTALL) -d $(DESTDIR)$(EDIT_BROKER_STAGING_DIR)
  chmod 0700 $(DESTDIR)$(EDIT_BROKER_STAGING_DIR)
  $(INSTALL) -d $(DESTDIR)$(DOAS_SNIPPET_DIR)
  $(INSTALL) -d $(DESTDIR)$(BROKER_CONFIG_DIR)
  $(INSTALL) -d $(DESTDIR)$(PREFIX)/share/doasudo
  sed \
    $(call _sed_entry,EDIT_BROKER_PATH,$(EDIT_BROKER_PATH)) \
    $(call _sed_entry,EDIT_BROKER_USER,$(EDIT_BROKER_USER)) \
    $(call _sed_entry,DOAS_PERMIT_IDENTITY,$(DOAS_PERMIT_IDENTITY)) \
    config/edit-broker.doas.conf.in > $(DESTDIR)$(DOAS_SNIPPET_DIR)/doas-snippet.conf
  chmod 644 $(DESTDIR)$(DOAS_SNIPPET_DIR)/doas-snippet.conf
  $(INSTALL) -m 644 config/edit-broker.editors.example \
    $(DESTDIR)$(PREFIX)/share/doasudo/
  $(INSTALL) -m 755 "$(CURDIR)/packaging/post-install.sh" \
    $(DESTDIR)$(PREFIX)/share/doasudo/post-install.sh
  $(INSTALL) -m 644 config/vimrc $(DESTDIR)$(BROKER_CONFIG_DIR)/vimrc
  $(INSTALL) -d $(DESTDIR)$(dir $(BROKER_ALLOWLIST_PATH))
  @if [ ! -f "$(DESTDIR)$(BROKER_ALLOWLIST_PATH)" ]; then \
    $(INSTALL) -m 644 "$(CURDIR)/config/edit-broker.editors.example" "$(DESTDIR)$(BROKER_ALLOWLIST_PATH)"; \
  fi
  @if [ -z "$(strip $(DESTDIR))" ] && [ $$(id -u) -eq 0 ]; then \
    $(MAKE) post-install; \
  fi

.PHONY: post-install
post-install:
  @if [ -n "$(DESTDIR)" ]; then \
    printf 'error: post-install requires empty DESTDIR\n' >&2; \
    exit 1; \
  fi
  @{ \
    DRY_RUN="$(DRY_RUN)" \
    EDIT_BROKER_USER="$(EDIT_BROKER_USER)" \
    EDIT_BROKER_STAGING_DIR="$(EDIT_BROKER_STAGING_DIR)" \
    DOAS_SNIPPET_DIR="$(DOAS_SNIPPET_DIR)" \
    sh "$(CURDIR)/packaging/post-install.sh"; \
  }

# broker/tests/broker-e2e-setup.sh (as root): broker, shim, fixtures, optional doas include, broker user.
# Then check-broker-e2e as a non-root user permitted by DOAS_PERMIT_IDENTITY.
#   sudo make broker-e2e-setup
#   sudo make broker-e2e-setup BROKER_E2E_APPEND_DOAS_CONF=1
#   make check-broker-e2e BROKER_E2E_RUN_USER=user
.PHONY: broker-e2e-setup
broker-e2e-setup:
  @if [ -n "$(DESTDIR)" ]; then \
    printf 'error: broker-e2e-setup requires empty DESTDIR\n' >&2; \
    exit 1; \
  fi
  @{ \
    PREFIX="$(PREFIX)" \
    BINDIR="$(BINDIR)" \
    EDIT_BROKER_PATH="$(EDIT_BROKER_PATH)" \
    DOAS_SNIPPET_DIR="$(DOAS_SNIPPET_DIR)" \
    BROKER_E2E_APPEND_DOAS_CONF="$(BROKER_E2E_APPEND_DOAS_CONF)" \
    BROKER_E2E_SKIP_BUILD="$(BROKER_E2E_SKIP_BUILD)" \
    sh broker/tests/broker-e2e-setup.sh; \
  }

# Real doas + broker test. If uid 0, set BROKER_E2E_RUN_USER to a permitted non-root user.
.PHONY: check-broker-e2e
check-broker-e2e:
  @if [ -n "$(DESTDIR)" ]; then printf 'error: check-broker-e2e requires empty DESTDIR\n' >&2; exit 1; fi
  @_uid=$$(id -u); _script="$(CURDIR)/broker/tests/broker-e2e_test.sh"; \
  if [ "$$_uid" -eq 0 ]; then \
    [ -n "$(BROKER_E2E_RUN_USER)" ] \
      || { printf 'error: running as root: set BROKER_E2E_RUN_USER to a non-root user allowed by DOAS_PERMIT_IDENTITY\n' >&2; exit 1; }; \
    sudo -u "$(BROKER_E2E_RUN_USER)" env $(BROKER_E2E_ENV) sh "$$_script"; \
  else \
    env $(BROKER_E2E_ENV) sh "$$_script"; \
  fi

# ---- Check -------------------------------------------------------------------------------

.DEFAULT_GOAL := check

# Tests on .in and generated libs (no doasudo binary build first).
# Order: shim core (flags/parser/edit-mode), broker-contracts + allowlist + vim-profile,
# broker-integration (EDITBROKER matrix), broker test-driver, then stale-metadata
# last (removes doasudo after repair check).
.PHONY: check-src
check-src: lib/shim-utils.sh lib/edit-broker-client.sh broker/edit-broker.sh
  @printf '\n'
  sh tests/doas-flags-parity_test.sh doasudo.in
  sh tests/parser_test.sh doasudo.in
  sh tests/edit-mode-parser_test.sh doasudo.in
  sh tests/edit-mode_test.sh doasudo.in
  sh broker/tests/broker-contracts_test.sh
  sh broker/tests/allowlist-parse_test.sh
  sh broker/tests/vim-profile_test.sh
  sh broker/tests/broker-integration_test.sh doasudo.in
  sh broker/tests/test-driver.sh
  sh tests/stale-metadata_test.sh

# check-src runs tests that rebuild lib/shim-utils.sh with a mock SHIM_PATH; release
# shim must bake UTILS_METADATA from the tree-default lib. Rebuild lib + shim after tests.
# Suite still runs on doasudo.in (not the binary) for flag/parser/edit cases.
# MAKE_VERBOSITY: matches tests/testlib.sh _make_s; silent unless VERBOSE=1.
MAKE_VERBOSITY = $(if $(filter 1,$(VERBOSE)),,-s)
.PHONY: check
check: check-src
  +$(MAKE) $(MAKE_VERBOSITY) -B lib/shim-utils.sh doasudo

# Edit-mode tests only (sleep-heavy mtime cases). Targeted dev rerun.
.PHONY: check-edit-mode check-writeback
check-edit-mode check-writeback:
  sh tests/edit-mode_test.sh doasudo.in

.PHONY: check-broker-contracts
check-broker-contracts:
  sh broker/tests/broker-contracts_test.sh

# shellcheck(1) then full test + bake (needs shellcheck on PATH).
.PHONY: check-all
check-all: shellcheck check

# ---- Lint --------------------------------------------------------------------------------

# POSIX sh: doasudo.in, lib/, broker/, packaging/, tests as listed below.
# CI: .github/workflows/ci.yml.
.PHONY: shellcheck
shellcheck: broker/edit-broker.sh lib/shim-utils.sh lib/edit-broker-client.sh
  shellcheck -s sh lib/shim-utils.sh
  shellcheck -s sh lib/edit-broker-client.sh
  shellcheck -s sh -x doasudo.in
  shellcheck -s sh packaging/post-install.sh
  shellcheck -s sh utils/metadata-utils.sh
  shellcheck -s sh tests/testlib.sh
  shellcheck -s sh tests/testlib-parser.sh
  shellcheck -s sh tests/testlib-broker.sh
  shellcheck -s sh tests/mock-edit-mode.sh
  shellcheck -s sh tests/bsd/anyvm.sh
  shellcheck -s sh tests/bsd/runner.sh
  shellcheck -s sh -x tests/parser_test.sh
  shellcheck -s sh -x tests/edit-mode-parser_test.sh
  shellcheck -s sh tests/stale-metadata_test.sh
  cd "$(CURDIR)/broker" && shellcheck -s sh -x edit-broker.sh
  shellcheck -s sh -x broker/tests/test-driver.sh
  shellcheck -s sh -x broker/tests/test-stub-editor.sh
  shellcheck -s sh broker/tests/fixtures/ipc/mock-edit-broker.sh.in
  shellcheck -s sh -x broker/tests/broker-contracts_test.sh
  shellcheck -s sh -x broker/tests/allowlist-parse_test.sh
  shellcheck -s sh -x broker/tests/broker-integration_test.sh
  shellcheck -s sh -x broker/tests/vim-profile_test.sh
  shellcheck -s sh -x broker/tests/broker-e2e_test.sh
  shellcheck -s sh broker/tests/e2e-append-editor.sh
  shellcheck -s sh broker/tests/broker-e2e-setup.sh

# ---- Uninstall ---------------------------------------------------------------------------

# Symmetric to install: BINDIR first (verify shim), then broker payload, policy, libexec.
.PHONY: uninstall
uninstall:
  @for f in $(DESTDIR)$(BINDIR)/editas $(DESTDIR)$(BINDIR)/sudoedit $(DESTDIR)$(BINDIR)/sudo; do \
    [ -e "$$f" ] || continue; \
    grep -qF 'doasudo' "$$f" 2>/dev/null \
      || { printf 'error: %s does not appear to be the doasudo; not removing\n' "$$f" >&2; exit 1; }; \
    rm -f "$$f"; \
  done
  rm -f $(DESTDIR)$(EDIT_BROKER_PATH)
  rm -f $(DESTDIR)$(BROKER_ALLOWLIST_PARSER)
  rm -f $(DESTDIR)$(EDIT_BROKER_CONTRACTS_PATH)
  rm -rf "$(DESTDIR)$(EDIT_BROKER_STAGING_DIR)"
  @d="$(DESTDIR)$(dir $(EDIT_BROKER_STAGING_DIR))"; d=$${d%/}; rmdir "$$d" 2>/dev/null || true
  @rmdir "$(DESTDIR)$(dir $(EDIT_BROKER_CONTRACTS_PATH))" 2>/dev/null || true
  @rmdir "$(DESTDIR)$(dir $(EDIT_BROKER_PATH))" 2>/dev/null || true
  rm -f $(DESTDIR)$(DOAS_SNIPPET_DIR)/doas-snippet.conf
  rm -rf "$(DESTDIR)$(BROKER_CONFIG_DIR)"
  rm -f $(DESTDIR)$(PREFIX)/share/doasudo/edit-broker.editors.example
  rm -f $(DESTDIR)$(PREFIX)/share/doasudo/post-install.sh
  @rmdir "$(DESTDIR)$(PREFIX)/share/doasudo" 2>/dev/null || true
  @rmdir "$(DESTDIR)$(DOAS_SNIPPET_DIR)" 2>/dev/null || true
  rm -f $(DESTDIR)$(SHIM_UTILS) $(DESTDIR)$(EDIT_BROKER_CLIENT)
  @rmdir "$(DESTDIR)$(SHIM_LIBEXEC_DIR)" 2>/dev/null || true
  @rmdir "$(DESTDIR)$(dir $(SHIM_LIBEXEC_DIR))" 2>/dev/null || true
  @rmdir "$(DESTDIR)$(BINDIR)" 2>/dev/null || true

# ---- Clean -------------------------------------------------------------------------------

.PHONY: clean
clean:
  rm -f doasudo broker/edit-broker.sh lib/shim-utils.sh lib/edit-broker-client.sh
