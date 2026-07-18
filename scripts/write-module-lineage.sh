#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 OUTPUT MODULE_SOURCE_DIRECTORY CONTAINER_FILE" >&2
    exit 2
fi

output=$1
source_dir=$(realpath "$2")
container_file=$3
version=$(tr -d '[:space:]' < "$source_dir/VERSION")
release=$(tr -d '[:space:]' < "$source_dir/RELEASE")

{
    echo "package=umip-limit-fix-linuwux-dkms"
    echo "module=umip_limit_fix_linuwux"
    echo "version=$version-$release"
    echo "source_commit=${GITHUB_SHA:-local}"
    echo "repository=${GITHUB_REPOSITORY:-local}"
    echo "workflow_run=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-local}"
    echo "build_container=$(< "$container_file")"
    while IFS= read -r -d '' file; do
        relative_file=${file#"$source_dir/"}
        echo "source_sha256=$(sha256sum "$file" | awk '{print $1}')  $relative_file"
    done < <(find "$source_dir" -maxdepth 1 -type f \
        \( -name Makefile -o -name dkms.conf \
           -o -name 'umip_ibt_thunks_linuwux.S' \
           -o -name 'umip_limit_fix_linuwux_main.c' \) \
        -print0 | sort -z)
} > "$output"
