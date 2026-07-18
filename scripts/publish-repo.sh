#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 STAGED_DIRECTORY" >&2
    exit 2
fi

staged_dir=$(realpath "$1")
release_tag="${PACKAGE_RELEASE_TAG:-packages}"
repo_dir=$(mktemp -d)
trap 'rm -rf "$repo_dir"' EXIT

if ! gh release view "$release_tag" >/dev/null 2>&1; then
    gh release create "$release_tag" \
        --title "Patched Proton pacman repository" \
        --notes "Release assets backing the linuwux pacman repository."
fi

gh release download "$release_tag" \
    --pattern '*.pkg.tar.zst' \
    --pattern 'linuwux.db.tar.gz' \
    --pattern 'linuwux.files.tar.gz' \
    --pattern '*.lineage.txt' \
    --dir "$repo_dir" || true

cp "$staged_dir"/*.lineage.txt "$repo_dir"/

docker pull archlinux:base-devel
docker image inspect archlinux:base-devel \
    --format 'Repository container: {{index .RepoDigests 0}}'
docker run --rm \
    -v "$repo_dir:/repo" \
    -v "$staged_dir:/staged:ro" \
    archlinux:base-devel bash -euo pipefail -c '
    cd /repo
    repo-add -R linuwux.db.tar.gz /staged/*.pkg.tar.zst
'
cp "$staged_dir"/*.pkg.tar.zst "$repo_dir"/

rm -f "$repo_dir/linuwux.db" "$repo_dir/linuwux.files"
cp "$repo_dir/linuwux.db.tar.gz" "$repo_dir/linuwux.db"
cp "$repo_dir/linuwux.files.tar.gz" "$repo_dir/linuwux.files"

if [[ -n "${REPO_GPG_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$REPO_GPG_PRIVATE_KEY" | gpg --batch --import
    fingerprint=$(gpg --batch --with-colons --list-secret-keys | \
        awk -F: '$1 == "fpr" { print $10; exit }')
    if [[ -z "$fingerprint" ]]; then
        echo "No secret signing key was imported" >&2
        exit 1
    fi

    gpg --batch --armor --export "$fingerprint" > "$repo_dir/linuwux.gpg"
    while IFS= read -r -d '' file; do
        printf '%s' "${REPO_GPG_PASSPHRASE:-}" | \
            gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
                --local-user "$fingerprint" --detach-sign "$file"
    done < <(find "$repo_dir" -maxdepth 1 -type f \
        \( -name '*.pkg.tar.zst' -o -name 'linuwux.db' -o -name 'linuwux.files' \) \
        -print0)
fi

mapfile -t old_assets < <(
    gh api --paginate "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" \
        --jq '.assets[].name | select(test("(\\.pkg\\.tar\\.zst|\\.sig|\\.lineage\\.txt)$") or startswith("linuwux."))'
)
for asset in "${old_assets[@]}"; do
    gh release delete-asset "$release_tag" "$asset" --yes
done

gh release upload "$release_tag" "$repo_dir"/*
