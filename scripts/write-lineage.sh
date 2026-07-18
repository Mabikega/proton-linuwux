#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 6 ]]; then
    echo "usage: $0 OUTPUT PACKAGE SOURCE_TAG SOURCE_COMMIT [CONTAINER_FILE] [INPUT_CHECKSUMS_FILE]" >&2
    exit 2
fi

output=$1
package=$2
source_tag=$3
source_commit=$4
container_file=${5:-}
input_checksums_file=${6:-}

{
    echo "package=$package"
    echo "source_tag=$source_tag"
    echo "source_commit=$source_commit"
    echo "patch_sha256=$(sha256sum LinUwUx.patch | awk '{print $1}')"
    echo "patch_release=$(tr -d '[:space:]' < PATCH_RELEASE)"
    echo "repository=${GITHUB_REPOSITORY:-local}"
    echo "workflow_run=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-local}"
    if [[ -n "$container_file" ]]; then
        echo "build_container=$(< "$container_file")"
    fi
    if [[ -n "$input_checksums_file" ]]; then
        sed 's/^/input_sha256=/' "$input_checksums_file"
    fi
} > "$output"
