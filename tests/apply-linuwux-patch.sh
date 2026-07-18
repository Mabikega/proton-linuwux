#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
source_dir="$test_dir/source"
fake_bin="$test_dir/bin"

mkdir -p \
    "$fake_bin" \
    "$source_dir/wine/dlls/ntdll/unix" \
    "$source_dir/wine/include/wine" \
    "$source_dir/wine/loader" \
    "$source_dir/wine/server" \
    "$source_dir/wine/tools"

printf '%s\n' 'TargetSysHandler' \
    > "$source_dir/wine/dlls/ntdll/unix/signal_x86_64.c"
printf '%s\n' 'REQ_set_faketime' \
    > "$source_dir/wine/include/wine/server_protocol.h"
printf '%s\n' 'DECL_HANDLER(set_faketime)' \
    > "$source_dir/wine/server/request_handlers.h"
printf '%s\n' '12345678-1234-1234-1234-123456789012' \
    > "$source_dir/wine/loader/wine.inf.in"
printf '%s\n' 'PROTON_DISABLE_LSTEAMCLIENT' > "$source_dir/proton"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fake_bin/patch"
printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$fake_bin/rg"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
    > "$source_dir/wine/tools/make_requests"
chmod +x "$fake_bin/patch" "$fake_bin/rg" \
    "$source_dir/wine/tools/make_requests"

PATH="$fake_bin:/usr/bin:/bin" \
    "$project_dir/scripts/apply-linuwux-patch.sh" "$source_dir" cachyos

: > "$source_dir/wine/include/wine/server_protocol.h"
if PATH="$fake_bin:/usr/bin:/bin" \
    "$project_dir/scripts/apply-linuwux-patch.sh" "$source_dir" cachyos \
    > "$test_dir/stdout" 2> "$test_dir/stderr"; then
    echo "Patch verification accepted a missing marker" >&2
    exit 1
fi
grep -Fq 'Patched source is missing required marker: REQ_set_faketime' \
    "$test_dir/stderr"
