#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 SOURCE_DIRECTORY {ge|cachyos}" >&2
    exit 2
fi

source_dir=$(realpath "$1")
variant=$2
project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
patch_file="$project_dir/LinUwUx.patch"
preexisting_rejects=$(find "$source_dir" -name '*.rej' -printf '%P\n' | sort)
if [[ "$variant" == ge && -n "$preexisting_rejects" ]]; then
    allowed_preexisting_rejects=$(printf '%s\n' \
        wine/configure.ac.rej \
        wine/dlls/winegstreamer/media-converter/videoconv.c.rej \
        wine/dlls/winegstreamer/wg_parser.c.rej | sort)
    unexpected_preexisting_rejects=$(comm -23 \
        <(printf '%s\n' "$preexisting_rejects") \
        <(printf '%s\n' "$allowed_preexisting_rejects"))
    if [[ -n "$unexpected_preexisting_rejects" ]]; then
        echo "Unexpected rejects from GE-Proton's upstream preparation:" >&2
        printf '%s\n' "$unexpected_preexisting_rejects" >&2
        exit 1
    fi
fi

if ! patch --batch --forward -Np1 -d "$source_dir" -i "$patch_file"; then
    echo "LinUwUx.patch did not apply cleanly to $variant" >&2
    exit 1
fi

# These files are generated from server/protocol.def. Regenerating them avoids
# depending on the line layout of generated files in different Wine forks.
(cd "$source_dir/wine" && ./tools/make_requests)

required_checks=(
    'wine/dlls/ntdll/unix/signal_x86_64.c|TargetSysHandler'
    'wine/include/wine/server_protocol.h|REQ_set_faketime'
    'wine/server/request_handlers.h|DECL_HANDLER(set_faketime)'
    'wine/loader/wine.inf.in|12345678-1234-1234-1234-123456789012'
    'proton|PROTON_DISABLE_LSTEAMCLIENT'
)
for check in "${required_checks[@]}"; do
    file=${check%%|*}
    pattern=${check#*|}
    if ! rg --fixed-strings --quiet "$pattern" "$source_dir/$file"; then
        echo "Patched source is missing required marker: $pattern" >&2
        exit 1
    fi
done

remaining_rejects=$(find "$source_dir" -name '*.rej' -printf '%P\n' | sort)
if [[ "$remaining_rejects" != "$preexisting_rejects" ]]; then
    echo "New patch reject files remain" >&2
    exit 1
fi
