#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 RECIPE_DIRECTORY OUTPUT_DIRECTORY" >&2
    exit 2
fi

recipe_dir=$(realpath "$1")
mkdir -p "$2"
output_dir=$(realpath "$2")
package=

shopt -s nullglob
for candidate in "$recipe_dir"/*.pkg.tar.zst; do
    if [[ -n "$package" ]]; then
        echo "Recipe directory contains more than one package" >&2
        exit 1
    fi
    package=$candidate
done
if [[ -z "$package" ]]; then
    echo "Recipe directory does not contain a package" >&2
    exit 1
fi

filename=${package##*/}
safe_filename=${filename//:/_}
cp "$package" "$output_dir/$safe_filename"
