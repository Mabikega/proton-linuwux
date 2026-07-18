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
            base-devel sudo afdko alsa-lib lib32-alsa-lib clang cmake ccache
            ffmpeg fontforge giflib lib32-giflib git glib2-devel glslang
            gnutls lib32-gnutls gtk3 lib32-gtk3 libgphoto2 libpulse
            lib32-libpulse libva lib32-libva libxcomposite
            lib32-libxcomposite libxinerama lib32-libxinerama libxxf86vm
            lib32-libxxf86vm lld mesa lib32-mesa mesa-libgl lib32-mesa-libgl
            meson mingw-w64-gcc mingw-w64-tools nasm opencl-headers
            opencl-icd-loader lib32-opencl-icd-loader pcsclite lib32-pcsclite
            perl perl-json rsync rust lib32-rust-libs python-pefile
            python-setuptools-scm samba unixodbc v4l-utils lib32-v4l-utils
            vulkan-headers vulkan-icd-loader lib32-vulkan-icd-loader
            wayland-protocols wget xorg-util-macros attr lib32-attr cabextract
            desktop-file-utils fontconfig lib32-fontconfig flac lib32-flac
            freetype2 lib32-freetype2 libgcc lib32-gcc-libs gettext
            lib32-gettext glib2 lib32-glib2 glibc lib32-glibc libgudev
            lib32-libgudev libnsl lib32-libnsl libpcap lib32-libpcap
            libunwind lib32-libunwind libvpx lib32-libvpx libwebp
            lib32-libwebp libx11 lib32-libx11 libxcursor lib32-libxcursor
            libxext lib32-libxext libxkbcommon lib32-libxkbcommon libxml2
            lib32-libxml2 libxi lib32-libxi libxrandr lib32-libxrandr mpg123
            lib32-mpg123 pipewire lib32-pipewire python python-six speex
            lib32-speex speexdsp lib32-speexdsp atk lib32-atk cairo
            lib32-cairo curl lib32-curl dbus-glib lib32-dbus-glib freeglut
            lib32-freeglut gdk-pixbuf2 lib32-gdk-pixbuf2 glu lib32-glu lcms2
            lib32-lcms2 libcaca lib32-libcaca libcanberra lib32-libcanberra
            dbus lib32-dbus libdrm lib32-libdrm libice lib32-libice libibus
            libnm lib32-libnm libusb lib32-libusb libvdpau lib32-libvdpau
            libvorbis lib32-libvorbis libxft lib32-libxft libxmu lib32-libxmu
            libxrender lib32-libxrender libxtst lib32-libxtst nspr lib32-nspr
            openal lib32-openal pango lib32-pango sdl2-compat
            lib32-sdl2-compat librsvg libsm lib32-libsm libtheora
            lib32-libtheora unzip wayland lib32-wayland xz lib32-xz
        )
        pacman -Syu --needed --noconfirm "${packages[@]}"

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
