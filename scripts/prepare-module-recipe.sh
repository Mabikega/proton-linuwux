#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 MODULE_SOURCE_DIRECTORY RECIPE_DIRECTORY" >&2
    exit 2
fi

source_dir=$(realpath "$1")
mkdir -p "$2"
recipe_dir=$(realpath "$2")
version=$(tr -d '[:space:]' < "$source_dir/VERSION")
release=$(tr -d '[:space:]' < "$source_dir/RELEASE")
template="$source_dir/PKGBUILD.template"

if [[ ! "$version" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    echo "kernel-module/VERSION is invalid: $version" >&2
    exit 1
fi
if [[ ! "$release" =~ ^[1-9][0-9]*$ ]]; then
    echo "kernel-module/RELEASE must contain a positive integer" >&2
    exit 1
fi

dkms_version=$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"$/\1/p' \
    "$source_dir/dkms.conf")
module_version=$(sed -n 's/^MODULE_VERSION("\([^"]*\)");$/\1/p' \
    "$source_dir/umip_limit_fix_linuwux_main.c")
if [[ "$dkms_version" != "$version" || "$module_version" != "$version" ]]; then
    echo "VERSION, dkms.conf, and MODULE_VERSION must match" >&2
    exit 1
fi

files=(
    Makefile
    dkms.conf
    umip_ibt_thunks_linuwux.S
    umip_limit_fix_linuwux_main.c
)
for file in "${files[@]}"; do
    if [[ ! -f "$source_dir/$file" ]]; then
        echo "Missing module source file: $file" >&2
        exit 1
    fi
    cp "$source_dir/$file" "$recipe_dir/$file"
done
cp "$template" "$recipe_dir/PKGBUILD"

replace_token() {
    local token=$1
    local value=$2
    sed -i "s|@$token@|$value|g" "$recipe_dir/PKGBUILD"
}

file_sha256() {
    sha256sum "$source_dir/$1" | awk '{print $1}'
}

replace_token VERSION "$version"
replace_token RELEASE "$release"
replace_token URL \
    "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}"
replace_token MAKEFILE_SHA256 "$(file_sha256 Makefile)"
replace_token DKMS_SHA256 "$(file_sha256 dkms.conf)"
replace_token THUNKS_SHA256 "$(file_sha256 umip_ibt_thunks_linuwux.S)"
replace_token MODULE_SHA256 "$(file_sha256 umip_limit_fix_linuwux_main.c)"
