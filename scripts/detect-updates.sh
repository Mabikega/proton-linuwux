#!/usr/bin/env bash
set -euo pipefail

release_tag="${PACKAGE_RELEASE_TAG:-packages}"
patch_release=$(tr -d '[:space:]' < PATCH_RELEASE)
force_build="${FORCE_BUILD:-false}"
output_file="${GITHUB_OUTPUT:-/dev/stdout}"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

if [[ ! "$patch_release" =~ ^[1-9][0-9]*$ ]]; then
    echo "PATCH_RELEASE must contain a positive integer" >&2
    exit 1
fi

github_api() {
    local endpoint=$1
    if command -v gh >/dev/null && [[ -n "${GH_TOKEN:-}" ]]; then
        gh api "$endpoint"
    else
        curl -fsSL "https://api.github.com/$endpoint"
    fi
}

read_release() {
    local fixture=$1
    local endpoint=$2
    if [[ -n "$fixture" ]]; then
        jq -e . "$fixture"
    else
        github_api "$endpoint"
    fi
}

resolve_commit() {
    local override=$1
    local repository=$2
    local tag=$3
    if [[ -n "$override" ]]; then
        printf '%s\n' "$override"
    else
        github_api "repos/$repository/commits/$tag" | jq -er .sha
    fi
}

require_release_tag() {
    local release_json=$1
    local pattern=$2
    local project=$3
    local tag
    tag=$(jq -er .tag_name <<< "$release_json")
    if [[ ! "$tag" =~ $pattern ]]; then
        echo "Unexpected latest $project release tag: $tag" >&2
        exit 1
    fi
    printf '%s\n' "$tag"
}

package_data() {
    local id=$1
    local package_name=$2
    local pkgver=$3
    local source_tag=$4
    local source_commit=$5
    local version filename build

    version="1:$pkgver-1.$patch_release"
    filename="$package_name-${version//:/_}-x86_64.pkg.tar.zst"
    build=true
    if [[ "$force_build" != true ]] && grep -Fxq "$filename" "$work_dir/assets"; then
        build=false
    fi

    {
        echo "${id}_build=$build"
        echo "${id}_tag=$source_tag"
        echo "${id}_commit=$source_commit"
        echo "${id}_pkgver=$pkgver"
        echo "${id}_filename=$filename"
    } >> "$output_file"
}

local_package_data() {
    local id=$1
    local package_name=$2
    local pkgver=$3
    local pkgrel=$4
    local architecture=$5
    local filename build

    filename="$package_name-$pkgver-$pkgrel-$architecture.pkg.tar.zst"
    build=true
    if [[ "$force_build" != true ]] && grep -Fxq "$filename" "$work_dir/assets"; then
        build=false
    fi

    {
        echo "${id}_build=$build"
        echo "${id}_pkgver=$pkgver"
        echo "${id}_pkgrel=$pkgrel"
        echo "${id}_filename=$filename"
    } >> "$output_file"
}

ge_release=$(read_release "${GE_RELEASE_JSON_FILE:-}" \
    repos/GloriousEggroll/proton-ge-custom/releases/latest)
cachyos_release=$(read_release "${CACHYOS_RELEASE_JSON_FILE:-}" \
    repos/CachyOS/proton-cachyos/releases/latest)

ge_tag=$(require_release_tag "$ge_release" '^GE-Proton[0-9]+-[0-9]+$' GE-Proton)
slr_tag=$(require_release_tag "$cachyos_release" \
    '^cachyos-[0-9]+\.[0-9]+-[0-9]{8}-slr$' Proton-CachyOS)
native_tag="${slr_tag%-slr}-native"

ge_commit=$(resolve_commit "${GE_SOURCE_COMMIT:-}" \
    GloriousEggroll/proton-ge-custom "$ge_tag")
slr_commit=$(resolve_commit "${SLR_SOURCE_COMMIT:-}" \
    CachyOS/proton-cachyos "$slr_tag")
native_commit=$(resolve_commit "${NATIVE_SOURCE_COMMIT:-}" \
    CachyOS/proton-cachyos "$native_tag")

ge_pkgver=${ge_tag//-/_}
cachyos_pkgver=${slr_tag#cachyos-}
cachyos_pkgver=${cachyos_pkgver%-slr}
cachyos_pkgver=${cachyos_pkgver//-/.}
module_pkgver=$(tr -d '[:space:]' < kernel-module/VERSION)
module_pkgrel=$(tr -d '[:space:]' < kernel-module/RELEASE)
if [[ ! "$module_pkgver" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    echo "kernel-module/VERSION is invalid: $module_pkgver" >&2
    exit 1
fi
if [[ ! "$module_pkgrel" =~ ^[1-9][0-9]*$ ]]; then
    echo "kernel-module/RELEASE must contain a positive integer" >&2
    exit 1
fi

: > "$work_dir/assets"
if [[ -n "${EXISTING_ASSETS_FILE:-}" ]]; then
    cp "$EXISTING_ASSETS_FILE" "$work_dir/assets"
elif [[ -n "${GITHUB_REPOSITORY:-}" ]] && \
    gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" \
        --jq '.assets[].name' > "$work_dir/assets" 2>/dev/null; then
    :
fi

package_data ge proton-ge-custom-linuwux \
    "$ge_pkgver" "$ge_tag" "$ge_commit"
package_data slr proton-cachyos-slr-linuwux \
    "$cachyos_pkgver" "$slr_tag" "$slr_commit"
package_data native proton-cachyos-native-linuwux \
    "$cachyos_pkgver" "$native_tag" "$native_commit"
local_package_data module umip-limit-fix-linuwux-dkms \
    "$module_pkgver" "$module_pkgrel" any

echo "patch_release=$patch_release" >> "$output_file"
