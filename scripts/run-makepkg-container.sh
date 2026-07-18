#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: $0 IMAGE RECIPE_DIR MAKEPKG_MODE [EXTRA_PACKAGE ...]" >&2
    exit 2
fi

image=$1
recipe_dir=$(realpath "$2")
makepkg_mode=$3
shift 3
host_uid=$(id -u)

docker pull "$image"
container_digest=$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')
echo "Build container: $container_digest"
printf '%s\n' "$container_digest" > "$recipe_dir/.linuwux-container-digest"

extra_packages=("$@")
extra_packages_quoted=
if [[ ${#extra_packages[@]} -gt 0 ]]; then
    extra_packages_quoted=$(printf ' %q' "${extra_packages[@]}")
fi

docker run --rm --privileged \
    -e MAKEFLAGS="-j$(nproc)" \
    -v "$recipe_dir:/work" \
    "$image" \
    bash -euo pipefail -c "
        pacman -Syu --needed --noconfirm base-devel sudo${extra_packages_quoted}
        useradd --create-home --uid $host_uid builder
        printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\\n' > /etc/sudoers.d/builder
        chown -R builder:builder /work
        runuser -u builder -- bash -lc \
            'cd /work && makepkg $makepkg_mode --noconfirm --cleanbuild --clean'
    "
