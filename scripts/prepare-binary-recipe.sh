#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 7 ]]; then
    echo "usage: $0 RECIPE_DIR ARCHIVE PATCH_RELEASE OUTPUT_PACKAGE PKGVER DISPLAY_NAME {ge|slr|native}" >&2
    exit 2
fi

recipe_dir=$1
archive=$2
patch_release=$3
output_package=$4
pkgver=$5
display_name=$6
variant=$7
project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
template="$project_dir/packaging/binary/PKGBUILD.template"

if [[ ! "$patch_release" =~ ^[1-9][0-9]*$ ]]; then
    echo "PATCH_RELEASE must contain a positive integer" >&2
    exit 1
fi
if [[ ! "$output_package" =~ ^[a-z0-9@._+-]+$ ]]; then
    echo "Invalid package name: $output_package" >&2
    exit 1
fi
if [[ ! "$pkgver" =~ ^[a-zA-Z0-9._+]+$ ]]; then
    echo "Invalid package version: $pkgver" >&2
    exit 1
fi
if [[ "$variant" != ge && "$variant" != slr && "$variant" != native ]]; then
    echo "Invalid package variant: $variant" >&2
    exit 1
fi
if [[ "$archive" == */* || ! -f "$recipe_dir/$archive" ]]; then
    echo "Archive must be a file directly inside the recipe directory" >&2
    exit 1
fi

archive_sha256=$(sha256sum "$recipe_dir/$archive" | awk '{print $1}')
mkdir -p "$recipe_dir"
cp "$template" "$recipe_dir/PKGBUILD"

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

replace_token() {
    local token=$1
    local value
    value=$(escape_sed_replacement "$2")
    sed -i "s|@$token@|$value|g" "$recipe_dir/PKGBUILD"
}

replace_token PKGNAME "$output_package"
replace_token PKGVER "$pkgver"
replace_token PKGREL "1.$patch_release"
replace_token ARCHIVE "$archive"
replace_token ARCHIVE_SHA256 "$archive_sha256"
replace_token VARIANT "$variant"

printf '%s\n' \
    '"compatibilitytools"' \
    '{' \
    '  "compat_tools"' \
    '  {' \
    "    \"$output_package\"" \
    '    {' \
    '      "install_path" "."' \
    "      \"display_name\" \"$display_name\"" \
    '      "from_oslist"  "windows"' \
    '      "to_oslist"    "linux"' \
    '    }' \
    '  }' \
    '}' > "$recipe_dir/compatibilitytool.vdf"
printf '%s\n' '# Local Proton settings. This file is preserved during upgrades.' \
    > "$recipe_dir/user_settings.py"
printf '%s\n' ntsync > "$recipe_dir/ntsync.conf"

replace_token VDF_SHA256 \
    "$(sha256sum "$recipe_dir/compatibilitytool.vdf" | awk '{print $1}')"
replace_token SETTINGS_SHA256 \
    "$(sha256sum "$recipe_dir/user_settings.py" | awk '{print $1}')"
replace_token NTSYNC_SHA256 \
    "$(sha256sum "$recipe_dir/ntsync.conf" | awk '{print $1}')"
