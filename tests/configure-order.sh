#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/make" "$test_dir/src"
cat > "$test_dir/make/rules-configure.mk" <<'MAKE'
define create-rules-configure
$(2)_CONFIGURE_DEPS = $$($(2)_SRC)/configure
$$(OBJ)/.$(1)-$(3)-configure: $$($(2)_CONFIGURE_DEPS)
	@test -x $$($(2)_SRC)/configure
	@touch $$@
endef
MAKE
cat > "$test_dir/Makefile" <<'MAKE'
.SECONDEXPANSION:
OBJ := $(CURDIR)
LIBRARY_SRC := $(CURDIR)/src
all: $(OBJ)/.library-x86_64-configure
include make/rules-configure.mk
$(eval $(call create-rules-configure,library,LIBRARY,x86_64))
$(LIBRARY_SRC)/configure:
	@printf '%s\n' '#!/bin/sh' 'exit 0' > $@
	@chmod +x $@
MAKE
patch --batch --forward --fuzz=0 -Np1 -d "$test_dir" \
    -i "$project_dir/patches/configure-order.patch"
make --no-print-directory -j2 -C "$test_dir"
test -f "$test_dir/.library-x86_64-configure"
