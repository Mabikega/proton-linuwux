#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 SOURCE_DIRECTORY" >&2
    exit 2
fi

source_dir=$(realpath "$1")
if [[ ! -e "$source_dir/.git" ]]; then
    echo "Source directory is not a Git checkout: $source_dir" >&2
    exit 1
fi

for attempt in first second third fourth; do
    if git -C "$source_dir" submodule update \
        --init --filter=tree:0 --recursive; then
        exit 0
    fi
    if [[ $attempt == fourth ]]; then
        echo "Submodule checkout failed after all retries" >&2
        exit 1
    fi
    echo "Submodule checkout failed; retrying cached checkout" >&2
    sleep 10
done
