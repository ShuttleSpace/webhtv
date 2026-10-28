#!/bin/bash -e

. ../../include/path.sh

build=_build$ndk_suffix

check_iconv_files() {
	for file in "$prefix_dir/include/iconv.h" "$prefix_dir/lib/libiconv.a" "$prefix_dir/lib/libcharset.a"; do
		if [ ! -f "$file" ]; then
			echo "Missing libiconv file: $file" >&2
			exit 1
		fi
	done
}

patch_mpv_iconv_dependency() {
	python3 - "$prefix_dir" <<'PY'
from pathlib import Path
import sys

prefix = sys.argv[1]
path = Path("meson.build")
lines = path.read_text(encoding="utf-8").splitlines()
replacement = (
    "iconv = declare_dependency("
    f"compile_args: ['-I{prefix}/include'], "
    f"link_args: ['{prefix}/lib/libiconv.a', "
    f"'{prefix}/lib/libcharset.a'])"
)
matches = [
    index for index, line in enumerate(lines)
    if line == "iconv = dependency('iconv', required: get_option('iconv'))"
    or (line.startswith("iconv = declare_dependency(") and "libiconv.a" in line)
]
if len(matches) != 1:
    raise SystemExit(f"unexpected mpv iconv dependency layout: {len(matches)} matches")
lines[matches[0]] = replacement
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf "$build"
	exit 0
else
	exit 255
fi

# NOTE: We intentionally do NOT ship a fake vulkan.pc here.
#
# Android 6.0 (API 23) has no Vulkan loader (libvulkan.so is only present in the
# NDK sysroot at API 26+). mpv's meson treats the vulkan dependency as OPTIONAL:
# even with -Dvulkan=disabled it runs `dependency('vulkan', required: vulkan_opt)`
# and, if a vulkan.pc exists, finds it and ALSO finds the NDK's bundled
# vulkan/vulkan_core.h header, which makes `features['vulkan']` true and links
# -lvulkan into libmpv -> the link fails on API 23 ("unable to find library
# -lvulkan"). By not providing vulkan.pc we let the dependency stay "not found",
# so no vulkan code is compiled or linked. Vulkan headers are supplied by the NDK
# sysroot itself, so libplacebo/ffmpeg header consumers still compile fine.

mkdir -p "$prefix_dir"/lib/pkgconfig

unset CC CXX

check_iconv_files
patch_mpv_iconv_dependency

meson setup "$build" --cross-file "$prefix_dir"/crossfile.txt \
	--default-library shared \
	-Diconv=enabled -Duchardet=enabled \
	-Dlibarchive=enabled -Ddvdnav=enabled \
	-Dlua=enabled -Dvulkan=disabled \
	-Dlibcurl="${WEBHTV_MPV_LIBCURL:-auto}" \
	-Dlibbluray=enabled -Drubberband=enabled \
	-Dlibmpv=true -Dcplayer=false \
	-Dmanpage-build=disabled

ninja -C "$build" -j"$cores"
if [ -f "$build/libmpv.a" ]; then
	echo >&2 "Meson produced a static libmpv, forcing rebuild."
	"$0" clean
	exec "$0" build
fi
DESTDIR="$prefix_dir" ninja -C "$build" install
