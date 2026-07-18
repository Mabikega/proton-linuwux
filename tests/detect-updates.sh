#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

printf '%s\n' '{"tag_name":"GE-Proton11-1"}' > "$test_dir/ge.json"
printf '%s\n' '{"tag_name":"cachyos-11.0-20260702-slr"}' \
    > "$test_dir/cachyos.json"
printf '%s\n' \
    'proton-cachyos-slr-linuwux-1_11.0.20260702-1.1-x86_64.pkg.tar.zst' \
    'umip-limit-fix-linuwux-dkms-1.0.0-1-any.pkg.tar.zst' \
    > "$test_dir/assets"

(
    cd "$project_dir"
    GE_RELEASE_JSON_FILE="$test_dir/ge.json" \
    CACHYOS_RELEASE_JSON_FILE="$test_dir/cachyos.json" \
    GE_SOURCE_COMMIT=1111111111111111111111111111111111111111 \
    SLR_SOURCE_COMMIT=2222222222222222222222222222222222222222 \
    NATIVE_SOURCE_COMMIT=3333333333333333333333333333333333333333 \
    EXISTING_ASSETS_FILE="$test_dir/assets" \
    GITHUB_OUTPUT="$test_dir/output" \
        scripts/detect-updates.sh
)

assert_output() {
    local expected=$1
    if ! grep -Fxq "$expected" "$test_dir/output"; then
        echo "Missing detection output: $expected" >&2
        exit 1
    fi
}

assert_output ge_build=true
assert_output ge_tag=GE-Proton11-1
assert_output ge_pkgver=GE_Proton11_1
assert_output ge_filename=proton-ge-custom-linuwux-1_GE_Proton11_1-1.1-x86_64.pkg.tar.zst
assert_output slr_build=false
assert_output slr_tag=cachyos-11.0-20260702-slr
assert_output slr_pkgver=11.0.20260702
assert_output native_build=true
assert_output native_tag=cachyos-11.0-20260702-native
assert_output native_filename=proton-cachyos-native-linuwux-1_11.0.20260702-1.1-x86_64.pkg.tar.zst
assert_output module_build=false
assert_output module_pkgver=1.0.0
assert_output module_pkgrel=1
assert_output module_filename=umip-limit-fix-linuwux-dkms-1.0.0-1-any.pkg.tar.zst
assert_output patch_release=1
