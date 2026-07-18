#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/recipe"

package_name='example-1:2.0-1-x86_64.pkg.tar.zst'
printf '%s\n' package-data > "$test_dir/recipe/$package_name"
"$project_dir/scripts/stage-package.sh" \
    "$test_dir/recipe" "$test_dir/output"

safe_name='example-1_2.0-1-x86_64.pkg.tar.zst'
test -f "$test_dir/output/$safe_name"
grep -Fxq package-data "$test_dir/output/$safe_name"
if find "$test_dir/output" -maxdepth 1 -type f -name '*:*' | grep -q .; then
    echo "Staged package filename still contains a colon" >&2
    exit 1
fi
