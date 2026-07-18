#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

cd "$project_dir"
scripts/prepare-module-recipe.sh kernel-module "$test_dir/recipe"
bash -n "$test_dir/recipe/PKGBUILD"
version=$(tr -d '[:space:]' < kernel-module/VERSION)
release=$(tr -d '[:space:]' < kernel-module/RELEASE)

required_lines=(
    'pkgname=umip-limit-fix-linuwux-dkms'
    "pkgver=$version"
    "pkgrel=$release"
    'provides=()'
    'conflicts=()'
    'replaces=()'
    '    umip_ibt_thunks_linuwux.S'
    '    umip_limit_fix_linuwux_main.c'
)
for line in "${required_lines[@]}"; do
    grep -Fxq "$line" "$test_dir/recipe/PKGBUILD"
done

if rg -q '@[A-Z0-9_]+@|umip_limit_fix\.(ko|o)|umip-limit-fix-dkms' \
    "$test_dir/recipe"; then
    echo "Generated module recipe contains an unresolved or old identity" >&2
    exit 1
fi

rg -q '^obj-m \+= umip_limit_fix_linuwux\.o$' "$test_dir/recipe/Makefile"
rg -q '^PACKAGE_NAME="umip-limit-fix-linuwux"$' "$test_dir/recipe/dkms.conf"
rg -q '^BUILT_MODULE_NAME\[0\]="umip_limit_fix_linuwux"$' \
    "$test_dir/recipe/dkms.conf"
