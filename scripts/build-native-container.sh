#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 SOURCE_DIRECTORY OUTPUT_DIRECTORY ARCHIVE_NAME" >&2
    exit 2
fi

source_dir=$(realpath "$1")
mkdir -p "$2"
output_dir=$(realpath "$2")
archive_name=$3
image="${NATIVE_BUILD_IMAGE:-cachyos/cachyos:latest}"

if [[ "$archive_name" == */* || "$archive_name" != *.tar.xz ]]; then
    echo "ARCHIVE_NAME must be a plain .tar.xz filename" >&2
    exit 1
fi
if [[ ! -x "$source_dir/configure.sh" || ! -d "$source_dir/wine" ]]; then
    echo "The source directory is not a prepared Proton-CachyOS checkout" >&2
    exit 1
fi

docker pull "$image"
container_digest=$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')
printf '%s\n' "$container_digest" > "$output_dir/.linuwux-container-digest"

docker run --rm --privileged \
    -e ARCHIVE_NAME="$archive_name" \
    -e MAKEFLAGS="-j$(nproc)" \
    -v "$source_dir:/source" \
    -v "$output_dir:/output" \
    "$image" bash -euo pipefail -c '
        packages=(
            base-devel sudo afdko alsa-lib clang cmake ccache ffmpeg fontforge
            giflib git glib2-devel glslang gnutls gtk3 libgphoto2 libpulse
            libva libxcomposite libxinerama libxxf86vm lld mesa mesa-libgl
            meson mingw-w64-gcc mingw-w64-tools nasm opencl-headers
            opencl-icd-loader pcsclite perl perl-json rsync rust python-pefile
            python-setuptools-scm samba unixodbc v4l-utils vulkan-headers
            vulkan-icd-loader wayland-protocols wget xorg-util-macros attr
            cabextract desktop-file-utils fontconfig flac freetype2 libgcc
            gettext glib2 glibc libgudev libnsl libpcap libunwind libvpx
            libwebp libx11 libxcursor libxext libxkbcommon libxml2 libxi
            libxrandr mpg123 pipewire python python-six speex speexdsp atk
            cairo curl dbus-glib freeglut gdk-pixbuf2 glu lcms2 libcaca
            libcanberra dbus libdrm libice libibus libnm libusb libvdpau
            libvorbis libxft libxmu libxrender libxtst nspr openal pango
            sdl2-compat librsvg libsm libtheora unzip wayland xz
        )
        sed -i \
            "s/^ParallelDownloads[[:space:]]*=.*/ParallelDownloads = 5/" \
            /etc/pacman.conf
        for attempt in first second third fourth; do
            if pacman -Syu --needed --noconfirm --disable-download-timeout \
                "${packages[@]}"; then
                break
            fi
            if [[ $attempt == fourth ]]; then
                echo "Package installation failed after all retries" >&2
                exit 1
            fi
            echo "Package installation failed; retrying cached transaction" >&2
            sleep 10
        done

        # The checkout is owned by the GitHub runner user but this container
        # runs as root. Allow Git metadata reads only for the mounted checkout
        # and its checked-out submodules so upstream version generation works.
        while IFS= read -r -d "" git_entry; do
            git config --global --add safe.directory "${git_entry%/.git}"
        done < <(find /source -name .git \
            \( -type f -o -type d \) -print0)

        mkdir -p /source/build/wrappers
        for architecture in i686 x86_64; do
            if [[ $architecture == i686 ]]; then
                gcc_flag=-m32
                ld_flag=-melf_i386
                as_flag=--32
                strip_flag=elf32-i386
            else
                gcc_flag=-m64
                ld_flag=-melf_x86_64
                as_flag=--64
                strip_flag=elf64-x86-64
            fi
            for tool in ar ranlib nm; do
                ln -sf "/usr/bin/gcc-$tool" \
                    "/source/build/wrappers/$architecture-pc-linux-gnu-$tool"
            done
            for tool in gcc g++; do
                printf "#!/usr/bin/bash\nccache /usr/bin/%s %s \"\$@\"\n" \
                    "$tool" "$gcc_flag" > \
                    "/source/build/wrappers/$architecture-pc-linux-gnu-$tool"
                chmod 755 "/source/build/wrappers/$architecture-pc-linux-gnu-$tool"
            done
            printf "#!/usr/bin/bash\n/usr/bin/ld %s \"\$@\"\n" "$ld_flag" > \
                "/source/build/wrappers/$architecture-pc-linux-gnu-ld"
            printf "#!/usr/bin/bash\n/usr/bin/as %s \"\$@\"\n" "$as_flag" > \
                "/source/build/wrappers/$architecture-pc-linux-gnu-as"
            printf "#!/usr/bin/bash\n/usr/bin/strip -F %s \"\$@\"\n" "$strip_flag" > \
                "/source/build/wrappers/$architecture-pc-linux-gnu-strip"
            chmod 755 /source/build/wrappers/*
        done

        export PATH="/source/build/wrappers:$PATH"
        export CFLAGS="-O3 -march=nocona -mtune=core-avx2"
        export CXXFLAGS="$CFLAGS"
        export RUSTFLAGS="-C opt-level=3 -C target-cpu=nocona"
        export LDFLAGS="-Wl,-O1,--sort-common,--as-needed"
        export RUSTUP_TOOLCHAIN=stable
        export CARGO_HOME=/source/.cargo
        cargo fetch --locked \
            --manifest-path /source/gst-plugins-rs/Cargo.toml
        cd /source/build
        ROOTLESS_CONTAINER= ../configure.sh \
            --container-engine=none \
            --proton-sdk-image= \
            --build-name=proton-cachyos-native-linuwux \
            --enable-wow64 \
            --without-steamrt-depends \
            --without-tts
        SUBJOBS=$(nproc) make -j1 dist
        tar -C /source/build -cJf "/output/$ARCHIVE_NAME" dist
    '

test -s "$output_dir/$archive_name"

# The tagged upstream Makefile selects and downloads these inputs. Record the
# exact files received so the published lineage remains reproducible.
for pattern in 'wine-gecko-*.tar.xz' 'wine-mono-*.tar.xz' 'xalia-*.zip'; do
    if ! compgen -G "$source_dir/contrib/$pattern" >/dev/null; then
        echo "Upstream build did not provide expected contrib input: $pattern" >&2
        exit 1
    fi
done
(
    cd "$source_dir"
    find contrib -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum
) > "$output_dir/.linuwux-inputs.sha256"
test -s "$output_dir/.linuwux-inputs.sha256"
