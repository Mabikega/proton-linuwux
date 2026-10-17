#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/recipe" "$test_dir/dist"
printf '%s\n' '#!/usr/bin/env python3' > "$test_dir/dist/proton"
tar -C "$test_dir" -cJf "$test_dir/recipe/redist.tar.xz" dist

for variant in native ge slr; do
    "$project_dir/scripts/prepare-binary-recipe.sh" \
        "$test_dir/recipe" redist.tar.xz 1 "proton-$variant-linuwux" \
        test_version "Test Proton" "$variant"
    (
        source "$test_dir/recipe/PKGBUILD"
        if [[ "$variant" == native ]]; then
            for dependency in "${depends[@]}" "${optdepends[@]}"; do
                if [[ "$dependency" == lib32-* ]]; then
                    echo "WoW64 native package requires a 32-bit host library" >&2
                    exit 1
                fi
            done
            grep -Fxq 'user_settings = {"PROTON_USE_WOW64": "1"}' \
                "$test_dir/recipe/user_settings.py"
        elif grep -Fq PROTON_USE_WOW64 "$test_dir/recipe/user_settings.py"; then
            echo "Native WoW64 setting leaked into another variant" >&2
            exit 1
        fi
    )
done
