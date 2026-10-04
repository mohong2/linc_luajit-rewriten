#!/usr/bin/env bash
#
# Build the prebuilt LuaJIT static library for one or more targets.
#
#   tools/build_luajit.sh --list
#   tools/build_luajit.sh --check
#   tools/build_luajit.sh linux-x64 android-arm64
#
# Every target writes straight to the path project/Build.xml links, and the result
# is then re-read by tools/lib_arch.py and rejected unless it actually carries the
# CPU(s) it claims. A prebuilt for the wrong CPU usually still links, so trusting
# it is how a bad archive reaches a device and faults there.
#
# windows-* needs a real Visual Studio environment, so it is a separate entry point
# (tools/build_luajit_msvc.bat) that these targets forward to when cmd.exe is here.
#
# Environment:
#   LUAJIT_REF          LuaJIT commit to build           (default: pinned 2.1 release)
#   LUAJIT_URL          upstream repository
#   LUAJIT_SRC          checkout directory               (default: <repo>/.luajit-src)
#   JOBS                parallel make jobs               (default: CPU count)
#   ANDROID_NDK_ROOT    NDK root                         (android-* only)
#   ANDROID_API         NDK API level                    (default: 21)
#   ANDROID_NDK_HOST_TAG  NDK prebuilt tag, e.g. linux-x86_64 (default: autodetect)
#   MACOS_X64_MIN       x86_64 deployment target         (default: 10.9)
#   MACOS_ARM64_MIN     arm64 deployment target          (default: 11.0)
#   IOS_MIN             iOS device minimum               (default: 12.0)
#   IOS_SIM_MIN         iOS simulator minimum            (default: 13.0)
#   LINUX_ARM64_CC      cross prefix for linux-arm64     (default: aarch64-linux-gnu-)
#   LINUX_ARMV7_CC      cross prefix for linux-armv7     (default: arm-linux-gnueabihf-)
#   MINGW_X64_CC        cross prefix for mingw-x64       (default: x86_64-w64-mingw32-)
#   MINGW_X86_CC        cross prefix for mingw-x86       (default: i686-w64-mingw32-)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="${LUAJIT_REF:-97813fb924edf822455f91a5fbbdfdb349e5984f}"
URL="${LUAJIT_URL:-https://github.com/LuaJIT/LuaJIT.git}"
SRC="${LUAJIT_SRC:-$ROOT/.luajit-src}"
TMP="$ROOT/dist/.work"
# The Microsoft Store ships a python3.exe shim that is not an interpreter: it exits
# non-zero instead of running anything, so probe an interpreter before trusting a name.
find_python() {
  local candidate
  for candidate in python3 python py; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
PY="$(find_python || true)"

if [ -n "${JOBS:-}" ]; then
  JOBS="$JOBS"
elif command -v nproc >/dev/null 2>&1; then
  JOBS="$(nproc)"
elif command -v sysctl >/dev/null 2>&1; then
  JOBS="$(sysctl -n hw.ncpu)"
else
  JOBS=4
fi

# target | output (relative to the repository root) | required architecture(s) | builder
TABLE="\
linux-x64|project/luajit/lib/Linux/libluajit-x86_64.a|x86_64|linux-native
linux-x86|project/luajit/lib/Linux/libluajit-x86.a|x86|linux-native
linux-arm64|project/luajit/lib/Linux/libluajit-arm64.a|arm64|linux-cross
linux-armv7|project/luajit/lib/Linux/libluajit-armv7.a|armv7|linux-cross
mingw-x64|project/luajit/lib/MinGW/libluajit-x86_64.a|x86_64|mingw
mingw-x86|project/luajit/lib/MinGW/libluajit-x86.a|x86|mingw
android-arm64|project/luajit/lib/Android/libluajit-arm64.a|arm64|android
android-armv7|project/luajit/lib/Android/libluajit-armv7.a|armv7|android
android-x86|project/luajit/lib/Android/libluajit-x86.a|x86|android
android-x86_64|project/luajit/lib/Android/libluajit-x86_64.a|x86_64|android
macos-64|project/luajit/lib/MacOS/libluajit-64.a|x86_64 arm64|macos
ios-arm64|project/luajit/lib/iPhone/libluajit-arm64.a|arm64|ios
ios-sim|project/luajit/lib/iPhone/libluajit-x86_64.a|x86_64 arm64|ios
windows-x64|project/luajit/lib/Windows/lua51-x86_64.lib|x86_64|msvc
windows-x86|project/luajit/lib/Windows/lua51-x86.lib|x86|msvc"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

row_of() { printf '%s\n' "$TABLE" | awk -F'|' -v t="$1" 'NF >= 4 && $1 == t { print; exit }'; }
all_targets() { printf '%s\n' "$TABLE" | awk -F'|' 'NF >= 4 && $1 != "" { print $1 }'; }

usage() {
  cat <<'USAGE'
usage: tools/build_luajit.sh [--list | --check [--allow-missing] | <target> ...]

  --list             show the target -> output mapping
  --check            verify the libraries already in the tree, build nothing;
                     a wrong architecture is always fatal
  --allow-missing    with --check: report absent files but do not fail on them
  <target>           build one or more targets (see --list)
USAGE
}

# LuaJIT's own "clean" target silently did nothing on the Apple runners. That is not
# cosmetic: the second slice of a universal build then reuses the first slice's
# objects, both slices come out as the same architecture, and lipo refuses them. So
# remove the products directly and prove they are gone.
clean_tree() {
  clean_tree
  rm -rf "$SRC"/src/*.o "$SRC"/src/*.a "$SRC"/src/*.so "$SRC"/src/*.d \
         "$SRC"/src/luajit "$SRC"/src/host/*.o "$SRC"/src/host/*.d "$SRC"/src/host/buildvm
  if [ -e "$SRC/src/luajit" ] || ls "$SRC"/src/*.o >/dev/null 2>&1; then
    die "could not clean $SRC/src; the next slice would silently reuse these objects"
  fi
}

# LuaJIT's own buildvm must be compiled with the pointer width of the target, or the
# generated interpreter does not match and the library faults at run time.
need_host_cc_bits() {
  local bits="$1" probe="$TMP/hostcc-$1"
  mkdir -p "$TMP"
  printf 'int main(void) { return 0; }\n' > "$probe.c"
  if ! gcc "-m$bits" "$probe.c" -o "$probe" >/dev/null 2>&1; then
    die "host gcc cannot compile -m$bits; 32-bit targets need gcc-multilib so LuaJIT builds a matching 32-bit buildvm"
  fi
}

fetch() {
  if [ ! -d "$SRC/.git" ]; then
    say "cloning LuaJIT into $SRC"
    git clone --quiet "$URL" "$SRC"
  fi
  git -C "$SRC" fetch --quiet origin
  git -C "$SRC" checkout --quiet "$REF"
  clean_tree
}

android_toolchain_bin() {
  local prebuilt="$1/toolchains/llvm/prebuilt" tag candidate
  if [ -n "${ANDROID_NDK_HOST_TAG:-}" ]; then
    tag="$ANDROID_NDK_HOST_TAG"
  else
    for candidate in linux-x86_64 darwin-x86_64 darwin-arm64 windows-x86_64; do
      if [ -d "$prebuilt/$candidate/bin" ]; then tag="$candidate"; break; fi
    done
  fi
  [ -n "${tag:-}" ] || die "no NDK llvm prebuilt under $prebuilt; set ANDROID_NDK_HOST_TAG"
  printf '%s\n' "$prebuilt/$tag/bin"
}

b_linux_native() {
  fetch
  if [ "$1" = linux-x86 ]; then
    need_host_cc_bits 32
    make -C "$SRC" -j"$JOBS" CC="gcc -m32" BUILDMODE=static
  else
    make -C "$SRC" -j"$JOBS" BUILDMODE=static
  fi
}

b_linux_cross() {
  local prefix flags hostbits=64
  case "$1" in
  linux-arm64) prefix="${LINUX_ARM64_CC:-aarch64-linux-gnu-}" ;;
  linux-armv7) prefix="${LINUX_ARMV7_CC:-arm-linux-gnueabihf-}"; flags="-march=armv7-a -mfloat-abi=hard"; hostbits=32 ;;
  *) die "b_linux_cross called for $1" ;;
  esac
  command -v "${prefix}gcc" >/dev/null 2>&1 || die "cross compiler not found: ${prefix}gcc"
  [ "$hostbits" = 32 ] && need_host_cc_bits 32
  fetch
  make -C "$SRC" -j"$JOBS" \
    HOST_CC="gcc -m$hostbits" \
    CROSS="$prefix" TARGET_SYS=Linux TARGET_LD="${prefix}gcc" \
    TARGET_FLAGS="${flags:-}" \
    BUILDMODE=static
}

b_mingw() {
  local prefix hostbits=64
  case "$1" in
  mingw-x64) prefix="${MINGW_X64_CC:-x86_64-w64-mingw32-}" ;;
  mingw-x86) prefix="${MINGW_X86_CC:-i686-w64-mingw32-}"; hostbits=32 ;;
  *) die "b_mingw called for $1" ;;
  esac
  fetch
  if command -v "${prefix}gcc" >/dev/null 2>&1; then
    [ "$hostbits" = 32 ] && need_host_cc_bits 32
    make -C "$SRC" -j"$JOBS" HOST_CC="gcc -m$hostbits" CROSS="$prefix" TARGET_SYS=Windows BUILDMODE=static
  elif uname -s | grep -qi -e mingw -e msys -e cygwin; then
    # A native MSYS/Cygwin make is already an x86_64 Windows toolchain; there is no
    # 32-bit flavour of it, so mingw-x86 has to come from a cross prefix.
    [ "$1" = mingw-x64 ] || die "native MSYS cannot build $1; install ${prefix}gcc"
    make -C "$SRC" -j"$JOBS" BUILDMODE=static
  else
    die "no mingw cross compiler (${prefix}gcc) and not running under MSYS/Cygwin"
  fi
}

b_android() {
  [ -n "${ANDROID_NDK_ROOT:-}" ] || die "ANDROID_NDK_ROOT is required for android-*"
  local bin abi_prefix clang_prefix hostbits
  bin="$(android_toolchain_bin "$ANDROID_NDK_ROOT")"
  case "$1" in
  android-arm64)  abi_prefix="aarch64-linux-android-";   clang_prefix="aarch64-linux-android";   hostbits=64 ;;
  android-armv7)  abi_prefix="armv7a-linux-androideabi-"; clang_prefix="armv7a-linux-androideabi"; hostbits=32 ;;
  android-x86)    abi_prefix="i686-linux-android-";      clang_prefix="i686-linux-android";      hostbits=32 ;;
  android-x86_64) abi_prefix="x86_64-linux-android-";    clang_prefix="x86_64-linux-android";    hostbits=64 ;;
  *) die "b_android called for $1" ;;
  esac
  local cc="$bin/${clang_prefix}${ANDROID_API:-21}-clang"
  [ -x "$cc" ] || die "no NDK compiler at $cc"
  [ -x "$bin/llvm-ar" ] || die "no llvm-ar at $bin"
  [ -x "$bin/llvm-strip" ] || die "no llvm-strip at $bin"
  [ "$hostbits" = 32 ] && need_host_cc_bits 32

  fetch
  # CC=clang is only a fallback; the NDK API-level wrappers below are what actually
  # compile and link the target, so the target is implied and TARGET_SYS stays Linux.
  # LuaJIT's own TARGET_SYS=Android path expects the pre-r19 NDK layout (NDKVER,
  # NDKP, NDKF, a separate standalone toolchain) and no longer matches the NDK.
  make -C "$SRC" -j"$JOBS" \
    HOST_CC="gcc -m$hostbits" \
    CC=clang CROSS="$bin/$abi_prefix" \
    STATIC_CC="$cc" DYNAMIC_CC="$cc -fPIC" \
    TARGET_SYS=Linux TARGET_LD="$cc" \
    TARGET_LDFLAGS="-fuse-ld=lld" \
    TARGET_AR="$bin/llvm-ar rcus" \
    TARGET_STRIP="$bin/llvm-strip" \
    BUILDMODE=static
}

b_macos() {
  need lipo
  need clang
  local x86_min="${MACOS_X64_MIN:-10.9}" arm_min="${MACOS_ARM64_MIN:-11.0}"
  fetch
  mkdir -p "$TMP"
  say "macOS x86_64 slice (deployment target $x86_min)"
  MACOSX_DEPLOYMENT_TARGET="$x86_min" make -C "$SRC" -j"$JOBS" TARGET_FLAGS="-arch x86_64" BUILDMODE=static
  cp "$SRC/src/libluajit.a" "$TMP/macos-x86_64.a"
  say "macOS arm64 slice (deployment target $arm_min)"
  clean_tree
  MACOSX_DEPLOYMENT_TARGET="$arm_min" make -C "$SRC" -j"$JOBS" TARGET_FLAGS="-arch arm64" BUILDMODE=static
  cp "$SRC/src/libluajit.a" "$TMP/macos-arm64.a"
  # Build.xml points both HXCPP_M64 and HXCPP_ARM64 at MacOS/libluajit-64.a, so the
  # single archive has to satisfy both, which is what a universal archive gives us.
  say "combining the two slices into one universal archive"
  lipo -create -output "$SRC/src/libluajit.a" "$TMP/macos-x86_64.a" "$TMP/macos-arm64.a"
}

b_ios() {
  need xcrun
  need lipo
  local device_sdk sim_sdk cc_dir
  device_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
  sim_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  cc_dir="$(dirname "$(xcrun --sdk iphoneos --find clang)")"
  fetch
  mkdir -p "$TMP"
  if [ "$1" = ios-arm64 ]; then
    say "iOS device arm64 (minimum ${IOS_MIN:-12.0})"
    make -C "$SRC" -j"$JOBS" CC=clang CROSS="$cc_dir/" TARGET_SYS=iOS \
      TARGET_FLAGS="-arch arm64 -isysroot $device_sdk -miphoneos-version-min=${IOS_MIN:-12.0}" \
      BUILDMODE=static
    return
  fi
  local arch
  for arch in x86_64 arm64; do
    say "iOS simulator $arch (minimum ${IOS_SIM_MIN:-13.0})"
    clean_tree
    make -C "$SRC" -j"$JOBS" CC=clang CROSS="$cc_dir/" TARGET_SYS=iOS \
      TARGET_FLAGS="-arch $arch -isysroot $sim_sdk -mios-simulator-version-min=${IOS_SIM_MIN:-13.0}" \
      BUILDMODE=static
    cp "$SRC/src/libluajit.a" "$TMP/ios-sim-$arch.a"
  done
  # One universal simulator archive covers Intel and Apple Silicon hosts alike.
  say "combining the two simulator slices"
  lipo -create -output "$SRC/src/libluajit.a" "$TMP/ios-sim-x86_64.a" "$TMP/ios-sim-arm64.a"
}

b_msvc() {
  local bits="x64"
  [ "$1" = windows-x86 ] && bits="x86"
  local bat="$ROOT/tools/build_luajit_msvc.bat"
  [ -f "$bat" ] || die "missing $bat"
  command -v cmd.exe >/dev/null 2>&1 || die "windows-* needs Visual Studio; run tools\\build_luajit_msvc.bat $bits on Windows"
  local win="$bat"
  if command -v cygpath >/dev/null 2>&1; then win="$(cygpath -w "$bat")"; fi
  say "forwarding to build_luajit_msvc.bat $bits"
  # MSYS rewrites a leading /c into a Windows path, which turns cmd.exe interactive
  # and silently builds nothing, so argument conversion is switched off for this call.
  MSYS2_ARG_CONV_EXCL='*' cmd.exe /c "$win" "$bits"
}

# Takes a repository-relative path and runs from the repository root, because a
# Windows interpreter cannot be handed an MSYS-style absolute path.
verify() {
  local file="$1" expects="$2" want
  local args=()
  if [ -z "$PY" ]; then
    warn "no working python found; skipping the architecture check"
    return 0
  fi
  for want in $expects; do args+=(--expect "$want"); done
  ( cd "$ROOT" && "$PY" tools/lib_arch.py "${args[@]}" "$file" )
}

# Provenance for one artifact. The path is recorded repository-relative so the file
# means the same thing on every runner.
manifest() {
  local target="$1" rel="$2" expects="$3" builder="$4" file="$ROOT/$2" digest size
  mkdir -p "$ROOT/dist"
  digest="$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$file" | cut -d' ' -f1)"
  size="$(wc -c < "$file" | tr -d ' ')"
  {
    printf 'target=%s\n' "$target"
    printf 'file=%s\n' "$rel"
    printf 'arch=%s\n' "$expects"
    printf 'bytes=%s\n' "$size"
    printf 'sha256=%s\n' "$digest"
    printf 'luajit_ref=%s\n' "$REF"
    printf 'builder=%s\n' "$builder"
    printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if command -v gcc >/dev/null 2>&1; then printf 'host_cc=%s\n' "$(gcc --version | head -n1)"; fi
  } > "$ROOT/dist/$target.txt"
}

build_one() {
  local target="$1" row out expects builder
  row="$(row_of "$target")"
  [ -n "$row" ] || die "unknown target: $target (try --list)"
  out="$(printf '%s' "$row" | cut -d'|' -f2)"
  expects="$(printf '%s' "$row" | cut -d'|' -f3)"
  builder="$(printf '%s' "$row" | cut -d'|' -f4)"

  say "$target -> $out [$expects]"
  mkdir -p "$ROOT/dist" "$TMP"

  case "$builder" in
  linux-native) b_linux_native "$target" ;;
  linux-cross)  b_linux_cross "$target" ;;
  mingw)        b_mingw "$target" ;;
  android)      b_android "$target" ;;
  macos)        b_macos "$target" ;;
  ios)          b_ios "$target" ;;
  msvc)         b_msvc "$target" ;;
  *) die "no builder named $builder" ;;
  esac

  if [ "$builder" != "msvc" ]; then
    [ -f "$SRC/src/libluajit.a" ] || die "$target produced no libluajit.a"
    mkdir -p "$(dirname "$ROOT/$out")"
    cp "$SRC/src/libluajit.a" "$ROOT/$out"
  fi
  [ -f "$ROOT/$out" ] || die "$target produced no $out"

  verify "$out" "$expects"
  manifest "$target" "$out" "$expects" "$builder"
  say "done: $target"
}

check_all() {
  local target row out expects missing=0 bad=0 allow_missing="${1:-}"
  for target in $(all_targets); do
    row="$(row_of "$target")"
    out="$(printf '%s' "$row" | cut -d'|' -f2)"
    expects="$(printf '%s' "$row" | cut -d'|' -f3)"
    if [ ! -f "$ROOT/$out" ]; then
      printf 'missing  %-14s %s\n' "$target" "$out"
      missing=$((missing + 1))
      continue
    fi
    if ! verify "$out" "$expects" >/dev/null 2>&1; then
      printf 'wrong    %-14s %s (want %s)\n' "$target" "$out" "$expects"
      bad=$((bad + 1))
    fi
  done
  printf '\n%d missing, %d with the wrong architecture\n' "$missing" "$bad"
  if [ "$bad" != 0 ]; then
    return 1
  fi
  if [ "$allow_missing" = "--allow-missing" ]; then
    return 0
  fi
  [ "$missing" = 0 ]
}

print_list() {
  local target row out expects builder
  printf '%-14s %-8s %-20s %s\n' TARGET ARCH BUILDER OUTPUT
  for target in $(all_targets); do
    row="$(row_of "$target")"
    out="$(printf '%s' "$row" | cut -d'|' -f2)"
    expects="$(printf '%s' "$row" | cut -d'|' -f3)"
    builder="$(printf '%s' "$row" | cut -d'|' -f4)"
    printf '%-14s %-8s %-20s %s\n' "$target" "$expects" "$builder" "$out"
  done
}

case "${1:-}" in
--list | -l)
  print_list
  ;;
--check)
  check_all "${2:-}"
  ;;
--all)
  for target in $(all_targets); do build_one "$target"; done
  ;;
"" | -h | --help)
  usage
  exit 2
  ;;
*)
  for target in "$@"; do build_one "$target"; done
  ;;
esac
