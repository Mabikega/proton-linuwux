#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
source_dir="$test_dir/source"
fake_bin="$test_dir/bin"

# Generated protocol headers drift between upstream releases. Patch only the
# protocol definition and let make_requests produce the headers for that tree.
if grep -E '^\+\+\+ .*wine/(include/wine/server_protocol|server/request_handlers)\.h' \
    "$project_dir/LinUwUx.patch"; then
    echo "Local patch must not edit generated protocol headers" >&2
    exit 1
fi

mkdir -p \
    "$fake_bin" \
    "$source_dir/wine/dlls/ntdll/unix" \
    "$source_dir/wine/include/wine" \
    "$source_dir/wine/loader" \
    "$source_dir/wine/server" \
    "$source_dir/wine/tools"

printf '%s\n' 'TargetSysHandler' \
    > "$source_dir/wine/dlls/ntdll/unix/signal_x86_64.c"
printf '%s\n' 'Old upstream protocol header' \
    > "$source_dir/wine/include/wine/server_protocol.h"
printf '%s\n' 'Old upstream request handlers' \
    > "$source_dir/wine/server/request_handlers.h"
printf '%s\n' '12345678-1234-1234-1234-123456789012' \
    > "$source_dir/wine/loader/wine.inf.in"
printf '%s\n' 'PROTON_DISABLE_LSTEAMCLIENT' > "$source_dir/proton"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fake_bin/patch"
printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$fake_bin/rg"
printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ ${TEST_SKIP_PROTOCOL:-false} == true ]]; then exit 0; fi' \
    'printf "%s\n" REQ_set_faketime > include/wine/server_protocol.h' \
    'printf "%s\n" "DECL_HANDLER(set_faketime)" > server/request_handlers.h' \
    > "$source_dir/wine/tools/make_requests"
chmod +x "$fake_bin/patch" "$fake_bin/rg" \
    "$source_dir/wine/tools/make_requests"

PATH="$fake_bin:/usr/bin:/bin" \
    "$project_dir/scripts/apply-linuwux-patch.sh" "$source_dir" cachyos

grep -Fxq 'REQ_set_faketime' "$source_dir/wine/include/wine/server_protocol.h"
grep -Fxq 'DECL_HANDLER(set_faketime)' "$source_dir/wine/server/request_handlers.h"

: > "$source_dir/wine/include/wine/server_protocol.h"
if TEST_SKIP_PROTOCOL=true PATH="$fake_bin:/usr/bin:/bin" \
    "$project_dir/scripts/apply-linuwux-patch.sh" "$source_dir" cachyos \
    > "$test_dir/stdout" 2> "$test_dir/stderr"; then
    echo "Patch verification accepted a missing protocol marker" >&2
    exit 1
fi
grep -Fq 'Patched source is missing required marker: REQ_set_faketime' \
    "$test_dir/stderr"

: > "$source_dir/wine/dlls/ntdll/unix/signal_x86_64.c"
if PATH="$fake_bin:/usr/bin:/bin" \
    "$project_dir/scripts/apply-linuwux-patch.sh" "$source_dir" cachyos \
    > "$test_dir/stdout" 2> "$test_dir/stderr"; then
    echo "Patch verification accepted a missing marker" >&2
    exit 1
fi
grep -Fq 'Patched source is missing required marker: TargetSysHandler' \
    "$test_dir/stderr"
