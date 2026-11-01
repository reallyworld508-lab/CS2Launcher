#!/bin/bash
# Builds the CS2 Launcher Wine engine from CodeWeavers' published CrossOver sources (LGPL).
#
#   scripts/wine/build.sh [step ...]
#
# Steps (default: all, in this order):
#   deps       install build dependencies with Homebrew
#   fetch      download the source tarball, print and verify its sha256, unpack sources/wine
#   patch      apply scripts/wine/patches/*.patch
#   configure  configure Wine (x86_64 host, WoW64: --enable-archs=i386,x86_64)
#   make       compile
#   install    make install into the staging prefix, build the cs2l-compat shim
#   bundle     copy non-system dylibs into wine/lib and rewrite install names
#   verify     check that nothing points outside the bundle, D3DMetal hooks are present
#   smoke      wine --version, wineboot --init, wine cmd /c echo ok (64 and 32 bit)
#   package    BUILDINFO, licenses, cs2l-wine-crossover-<ver>-<build>-x86_64.tar.xz + .sha256
#
# Works on an Intel Mac (GitHub's macos-15-intel runner) and on Apple silicon, where the
# script re-executes itself under Rosetta (arch -x86_64) and needs Homebrew in /usr/local.
#
# Environment (all optional):
#   BUILD_NUMBER   build label in the file name                       (default: local)
#   WORKDIR        everything is created below this directory         (default: ./.wine-work)
#   JOBS           parallel make jobs                                 (default: logical cpus)
#   SKIP_DEPS=1    do not run brew install
#   WITH_GSTREAMER=1  build winegstreamer (default 0: no GStreamer, no media foundation codecs)
#   CX_SHA256      expected sha256 of the source tarball, empty = do not check (see below)
#   MAX_MINOS      fail `verify` if a bundled Mach-O needs a newer macOS than this (e.g. 15.0)
#
# Ideas and parts of the approach come from freequay (MIT), macos-crossover-wine-cloud-builder
# (MIT), Gcenx's macOS Wine builds and peterkmet/wine-cross. See docs/engine.md.
set -euo pipefail

# ---------------------------------------------------------------- configuration
CX_VERSION="26.3.0"
CX_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VERSION}.tar.gz"
# PINNED SOURCE HASH. This value was taken from freequay's scripts/fetch-sources.sh (an independent
# project that builds the same tarball). The `fetch` step prints the hash of what it really
# downloaded; if CodeWeavers ever re-publish the file, update this line from that output.
CX_SHA256="${CX_SHA256-ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872}"
CX_SIZE_EXPECTED=149054023

BUILD_NUMBER="${BUILD_NUMBER:-local}"
ARTIFACT="cs2l-wine-crossover-${CX_VERSION}-${BUILD_NUMBER}-x86_64"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/../.." && pwd)"
WORKDIR="${WORKDIR:-$PWD/.wine-work}"
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
DL="$WORKDIR/downloads"
SRC="$WORKDIR/src/sources/wine"
BLD="$WORKDIR/build"
STAGE="$WORKDIR/stage"
PFX="$STAGE/wine"            # install prefix == archive directory "wine"
OUT="$WORKDIR/out"
LOGS="$WORKDIR/logs"
mkdir -p "$DL" "$BLD" "$STAGE" "$OUT" "$LOGS"

WITH_GSTREAMER="${WITH_GSTREAMER:-0}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export MACOSX_DEPLOYMENT_TARGET

log()  { printf '==> %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- host / arch
# Wine for the Mac is an x86_64 program (it runs Windows x86 code and D3DMetal is x86_64 only).
if [ "$(uname -m)" = "arm64" ]; then
  /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || die "Rosetta is missing: softwareupdate --install-rosetta --agree-to-license"
  log "Apple silicon host: re-executing under Rosetta (arch -x86_64)"
  exec /usr/bin/arch -x86_64 /bin/bash "$0" "$@"
fi
[ "$(uname -m)" = "x86_64" ] || die "unsupported machine $(uname -m)"
UNDER_ROSETTA=0
[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ] && UNDER_ROSETTA=1

if [ "$UNDER_ROSETTA" = 1 ]; then
  # keep the arm64 Homebrew out of the way: only /usr/local (x86_64) is usable
  PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '^/opt/homebrew' | paste -sd: -)"
  BREW=/usr/local/bin/brew
  PATH="/usr/local/bin:/usr/local/sbin:$PATH"
else
  BREW="$(command -v brew || true)"
fi
export PATH

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1

# ccache: compiles of unchanged files are replayed from the cache that the workflow restores
export CCACHE_DIR="${CCACHE_DIR:-$WORKDIR/ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-4G}"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,locale,include_file_mtime,include_file_ctime
export CCACHE_BASEDIR="$WORKDIR"
export CCACHE_NOHASHDIR=1

brew_prefix() { "$BREW" --prefix "$1"; }

# ---------------------------------------------------------------- helpers
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# macOS has no timeout(1): perl's alarm survives exec
run_timeout() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$secs" "$@"; }

# every Mach-O file below a directory (PE files and scripts are skipped)
macho_files() {
  find "$1" -type f ! -name '*.dll' ! -name '*.exe' ! -name '*.sys' ! -name '*.drv' ! -name '*.ocx' \
       ! -name '*.cpl' ! -name '*.acm' ! -name '*.ax' ! -name '*.tlb' ! -name '*.nls' ! -name '*.ttf' \
       ! -name '*.fon' ! -name '*.inf' ! -name '*.sh' ! -name '*.json' -print0 2>/dev/null |
    xargs -0 file 2>/dev/null | awk -F: '/Mach-O/ {print $1}'
}

deps_of() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }
realpath_of() { perl -MCwd=realpath -e 'print realpath(shift)' "$1"; }
# install-name leaf of a library, e.g. libfreetype.6.dylib
leaf_of() { basename "$(otool -D "$(realpath_of "$1")" | tail -1)"; }
is_system_path() { case "$1" in /usr/lib/*|/System/*|/Library/Apple/*) return 0 ;; esac; return 1; }
is_relative_ref() { case "$1" in @rpath/*|@loader_path/*|@executable_path/*) return 0 ;; esac; return 1; }
rpaths_of() { otool -l "$1" | awk '/cmd LC_RPATH/ {f=1} f && $1=="path" {print $2; f=0}'; }

# resolve a dependency reference of an *original* (Homebrew) Mach-O to a real file
resolve_dep() {
  local file="$1" dep="$2" dir rp cand
  dir="$(dirname "$file")"
  case "$dep" in
    @loader_path/*) cand="$dir/${dep#@loader_path/}"; [ -e "$cand" ] && { echo "$cand"; return 0; } ;;
    @rpath/*)
      while IFS= read -r rp; do
        case "$rp" in @loader_path*) rp="$dir${rp#@loader_path}" ;; esac
        cand="$rp/${dep#@rpath/}"; [ -e "$cand" ] && { echo "$cand"; return 0; }
      done < <(rpaths_of "$file")
      cand="$(brew_prefix_of_leaf "${dep#@rpath/}")" && [ -n "$cand" ] && { echo "$cand"; return 0; } ;;
    /*) [ -e "$dep" ] && { echo "$dep"; return 0; } ;;
  esac
  return 1
}
# last resort for odd @rpath references: search the Homebrew lib directories
brew_prefix_of_leaf() {
  local leaf="$1" p
  for p in "$(dirname "$(dirname "$BREW")")/lib" "$(dirname "$(dirname "$BREW")")/opt"/*/lib; do
    [ -e "$p/$leaf" ] && { echo "$p/$leaf"; return 0; }
  done
  return 1
}

# ================================================================== steps
step_deps() {
  [ "${SKIP_DEPS:-0}" = 1 ] && { log "SKIP_DEPS=1"; return; }
  if [ -z "$BREW" ] || [ ! -x "$BREW" ]; then
    [ "$UNDER_ROSETTA" = 1 ] || die "Homebrew not found"
    log "installing x86_64 Homebrew into /usr/local (Rosetta)"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  log "Homebrew: $("$BREW" --prefix) ($("$BREW" --version | head -1))"
  # build tools: bison/flex (macOS ships 2.3 / old), mingw-w64 (gcc: PE half of Wine, llvm-mingw
  # miscompiled kernelbase for Steam in other projects' tests), ccache, xz for the archive
  # runtime libraries that are bundled: freetype, gnutls, sdl2, molten-vk
  local pkgs="bison flex pkgconf mingw-w64 ccache xz freetype gnutls sdl2 molten-vk"
  [ "$WITH_GSTREAMER" = 1 ] && pkgs="$pkgs gstreamer gst-plugins-base"
  # shellcheck disable=SC2086
  "$BREW" install $pkgs || "$BREW" install $pkgs   # one retry: bottle downloads are flaky
  "$BREW" list --versions $pkgs
}

setup_toolchain_env() {
  local bison flex
  bison="$(brew_prefix bison)"; flex="$(brew_prefix flex)"
  PATH="$bison/bin:$flex/bin:$PATH"
  # ccache wrappers for the mingw cross compilers (configure finds them first on PATH)
  local w="$WORKDIR/ccache-bin" t real
  mkdir -p "$w"
  for t in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
    real="$(PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$w" | paste -sd: -)" command -v "$t")" || die "$t not found (brew install mingw-w64)"
    printf '#!/bin/sh\nexec ccache "%s" "$@"\n' "$real" > "$w/$t"
    chmod +x "$w/$t"
  done
  PATH="$w:$PATH"
  export PATH
  command -v ccache >/dev/null && ccache -z >/dev/null 2>&1 || true
}

step_fetch() {
  local tgz="$DL/crossover-sources-${CX_VERSION}.tar.gz" got size
  if [ ! -f "$tgz" ]; then
    log "downloading $CX_URL"
    curl -fL --retry 5 --retry-delay 10 --retry-all-errors --progress-bar -o "$tgz.part" "$CX_URL"
    mv "$tgz.part" "$tgz"
  fi
  size="$(stat -f %z "$tgz")"; got="$(sha256_of "$tgz")"
  echo "SOURCE_URL=$CX_URL"
  echo "SOURCE_SIZE=$size"
  echo "SOURCE_SHA256=$got"
  [ "$size" = "$CX_SIZE_EXPECTED" ] || warn "tarball is $size bytes, expected $CX_SIZE_EXPECTED"
  if [ -n "$CX_SHA256" ] && [ "$got" != "$CX_SHA256" ]; then
    die "sha256 mismatch for $tgz: got $got, pinned $CX_SHA256 (update CX_SHA256 in scripts/wine/build.sh if CodeWeavers re-published it)"
  fi
  [ -n "$CX_SHA256" ] || warn "CX_SHA256 is empty: source tarball not pinned (hash above)"
  printf '%s' "$got" > "$WORKDIR/source.sha256"
  if [ ! -f "$SRC/configure" ]; then
    log "unpacking sources/wine"
    rm -rf "$WORKDIR/src"; mkdir -p "$WORKDIR/src"
    tar -xzf "$tgz" -C "$WORKDIR/src" sources/wine
  fi
  [ -f "$SRC/configure" ] || die "sources/wine/configure missing after unpack"
  [ -f "$SRC/dlls/winemac.drv/d3dmetal.c" ] || die "CrossOver D3DMetal hooks (dlls/winemac.drv/d3dmetal.c) missing in the sources"
  grep -q 'CX_APPLEGPTK_LIBD3DSHARED_PATH' "$SRC/dlls/ntdll/unix/loader.c" || die "libd3dshared support missing in ntdll"
}

step_patch() {
  local p n=0 marker="$WORKDIR/.patched"
  for p in "$SELF"/patches/*.patch; do
    [ -e "$p" ] || continue
    n=$((n + 1))
    if grep -qxF "$(basename "$p") $(sha256_of "$p")" "$marker" 2>/dev/null; then continue; fi
    log "applying $(basename "$p")"
    patch -d "$SRC" -p1 --no-backup-if-mismatch --quiet < "$p"
    echo "$(basename "$p") $(sha256_of "$p")" >> "$marker"
  done
  log "$n patch file(s) in scripts/wine/patches"
}

soname_of() { # brew formula, library glob -> install-name leaf (libfreetype.6.dylib)
  local f="$1" lib="$2" p id
  p="$(brew_prefix "$f")/lib/$lib"
  [ -e "$p" ] || die "$p not found"
  id="$(otool -D "$p" | tail -1)"
  basename "$id"
}

step_configure() {
  setup_toolchain_env
  local ft gn sdl
  ft="$(soname_of freetype libfreetype.dylib)"
  gn="$(soname_of gnutls libgnutls.dylib)"
  sdl="$(soname_of sdl2 libSDL2.dylib)"
  local mvk
  mvk="$(brew_prefix molten-vk)/lib/libMoltenVK.dylib"; [ -e "$mvk" ] || die "libMoltenVK.dylib not found"

  # Wine dlopen()s these libraries by name. Giving the names as @rpath/... makes dlopen use the
  # rpaths of the calling Wine library, which `bundle` points at wine/lib. So a bundled copy is
  # found and a Homebrew copy never is.
  local pc=""
  for f in freetype gnutls sdl2 libpng zlib; do
    pc="$(brew_prefix "$f")/lib/pkgconfig:$pc"
  done
  export PKG_CONFIG_PATH="$pc${PKG_CONFIG_PATH:-}"
  export ac_cv_lib_soname_freetype="@rpath/$ft"
  export ac_cv_lib_soname_gnutls="@rpath/$gn"
  export ac_cv_lib_soname_SDL2="@rpath/$sdl"
  export ac_cv_lib_soname_vulkan=""                    # no libvulkan: MoltenVK directly
  export ac_cv_lib_soname_MoltenVK="@rpath/libMoltenVK.dylib"
  # pipe2 exists only in the newest SDKs; ntdll would call it without an availability check
  export ac_cv_func_pipe2=no

  local gst_flag="--without-gstreamer"
  [ "$WITH_GSTREAMER" = 1 ] && gst_flag="--with-gstreamer"

  CONFIGURE_FLAGS=(
    --prefix="$PFX"
    --enable-archs=i386,x86_64
    --disable-tests
    --disable-option-checking
    --with-mingw
    --without-x --without-wayland
    --with-coreaudio --with-cups
    --with-freetype --with-gnutls --with-sdl --with-vulkan
    "$gst_flag"
    --without-opengl
    --without-alsa --without-capi --without-dbus --without-ffmpeg --without-fontconfig
    --without-gettext --without-gettextpo --without-gphoto --without-gssapi --without-hwloc
    --without-inotify --without-krb5 --without-netapi --without-oss --without-opencl
    --without-pcap --without-pcsclite --without-pulse --without-sane --without-udev
    --without-unwind --without-usb --without-v4l2
  )
  local cflags="-O2 -Wno-implicit-function-declaration -Wno-deprecated-declarations -Wno-format"
  local ldflags="-Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../.. -Wl,-rpath,@loader_path/../lib"
  printf '%s\n' "${CONFIGURE_FLAGS[@]}" > "$WORKDIR/configure.flags"
  printf 'CC=ccache clang\nCFLAGS=%s\nCROSSCFLAGS=-O2\nLDFLAGS=%s\nSONAMES=%s %s %s MoltenVK\n' \
    "$cflags" "$ldflags" "$ft" "$gn" "$sdl" >> "$WORKDIR/configure.flags"

  mkdir -p "$BLD"; cd "$BLD"
  log "configure ($(clang --version | head -1); SDK $(xcrun --show-sdk-version))"
  if ! CC="ccache clang" CXX="ccache clang++" OBJC="ccache clang" \
       CFLAGS="$cflags" CROSSCFLAGS="-O2" LDFLAGS="$ldflags" \
       "$SRC/configure" "${CONFIGURE_FLAGS[@]}" > "$LOGS/configure.log" 2>&1; then
    tail -n 80 "$LOGS/configure.log"; die "configure failed (full log in the uploaded artifact: logs/configure.log)"
  fi
  grep -E '^configure: (WARNING|error)' "$LOGS/configure.log" || true
  # configure only warns about missing optional libraries; fail on the ones the engine must have
  local need
  for need in SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBSDL2 SONAME_LIBVULKAN; do
    grep -q "^#define $need " include/config.h || { grep -i "${need#SONAME_LIB}" "$LOGS/configure.log" | tail -n 20; die "configure did not enable $need"; }
  done
  grep -q 'x86_64-w64-mingw32' Makefile || die "mingw x86_64 PE cross compiler not configured"
  grep -q 'i686-w64-mingw32' Makefile || die "mingw i686 PE cross compiler not configured"
  grep -q '^#define HAVE_PIPE2' include/config.h && die "HAVE_PIPE2 got defined"
  log "configure ok"
}

step_make() {
  setup_toolchain_env
  cd "$BLD"
  log "make -j$JOBS ($(date +%H:%M))"
  set +e
  make -j"$JOBS" 2>&1 | tee "$LOGS/make.log" | awk 'NR % 1500 == 0 { printf "[make] %d lines\n", NR; fflush() }'
  local rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    grep -nE ' error:|Error [0-9]+$|\*\*\* ' "$LOGS/make.log" | head -n 40 || true
    tail -n 60 "$LOGS/make.log"
    die "make failed (see logs/make.log)"
  fi
  command -v ccache >/dev/null && ccache -s || true
  nm -gU "$BLD/dlls/winemac.drv/winemac.so" 2>/dev/null | grep -c '_macdrv_functions' >/dev/null \
    || warn "winemac.so does not export macdrv_functions yet (checked again in verify)"
}

step_install() {
  setup_toolchain_env
  cd "$BLD"
  rm -rf "$PFX"
  log "make install -> $PFX"
  make install > "$LOGS/install.log" 2>&1 || { tail -n 60 "$LOGS/install.log"; die "make install failed"; }
  # runtime only: no headers, man pages or development tools
  rm -rf "$PFX/include" "$PFX/share/man"
  local t
  for t in widl winegcc wineg++ winecpp winebuild wrc wmc winemaker winedump function_grep.pl; do rm -f "$PFX/bin/$t"; done

  log "stripping debug info from PE files"
  find "$PFX/lib/wine/x86_64-windows" -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' -o -name '*.ax' -o -name '*.acm' -o -name '*.cpl' -o -name '*.ocx' \) \
       -exec x86_64-w64-mingw32-strip --strip-debug {} + 2>/dev/null || true
  find "$PFX/lib/wine/i386-windows" -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' -o -name '*.ax' -o -name '*.acm' -o -name '*.cpl' -o -name '*.ocx' \) \
       -exec i686-w64-mingw32-strip --strip-debug {} + 2>/dev/null || true

  log "building cs2l-compat (cxcompatdb.so replacement)"
  clang -arch x86_64 -O2 -Wall -dynamiclib -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
        -install_name @rpath/cxcompatdb.so -o "$PFX/lib/wine/x86_64-unix/cxcompatdb.so" \
        "$SELF/compat/cxcompatdb.c"
  mkdir -p "$PFX/share/cs2l"
  cp "$SELF/compat/cxcompatdb.c" "$PFX/share/cs2l/cxcompatdb.c"

  for f in bin/wine bin/wineserver lib/wine/x86_64-unix/ntdll.so lib/wine/x86_64-unix/winemac.so \
           lib/wine/x86_64-windows/ntdll.dll lib/wine/i386-windows/ntdll.dll; do
    [ -e "$PFX/$f" ] || die "expected file missing after install: $f"
  done
}

# copy one library (and, recursively, what it needs) into wine/lib
declare -a BUNDLED_SRC=()
bundle_lib() { # path to the original library
  local real leaf dest dep depreal
  real="$(realpath_of "$1")"
  leaf="$(leaf_of "$real")"
  dest="$PFX/lib/$leaf"
  [ -e "$dest" ] && return 0
  mkdir -p "$PFX/lib"
  cp "$real" "$dest"; chmod u+w "$dest"
  BUNDLED_SRC+=("$real")
  install_name_tool -id "@rpath/$leaf" "$dest" 2>/dev/null
  for dep in $(deps_of "$dest"); do
    is_system_path "$dep" && continue
    [ "$dep" = "@rpath/$leaf" ] && continue
    depreal="$(resolve_dep "$real" "$dep")" || die "cannot resolve $dep needed by $real"
    bundle_lib "$depreal"
    install_name_tool -change "$dep" "@loader_path/$(leaf_of "$depreal")" "$dest"
  done
}

step_bundle() {
  log "bundling non-system dylibs into wine/lib"
  mkdir -p "$PFX/lib"
  # 1. libraries that Wine's own binaries link to (usually none) and the ones it dlopen()s
  local f dep leaf depreal
  while IFS= read -r f; do
    for dep in $(deps_of "$f"); do
      is_system_path "$dep" && continue
      is_relative_ref "$dep" && continue
      case "$dep" in "$PFX"/*) continue ;; esac
      depreal="$(resolve_dep "$f" "$dep")" || die "cannot resolve $dep needed by $f"
      bundle_lib "$depreal"
      leaf="$(leaf_of "$depreal")"
      install_name_tool -change "$dep" "@rpath/$leaf" "$f"
    done
  done < <(macho_files "$PFX")

  local roots=(
    "$(brew_prefix freetype)/lib/libfreetype.dylib"
    "$(brew_prefix gnutls)/lib/libgnutls.dylib"
    "$(brew_prefix sdl2)/lib/libSDL2.dylib"
    "$(brew_prefix molten-vk)/lib/libMoltenVK.dylib"
  )
  [ "$WITH_GSTREAMER" = 1 ] && roots+=("$(brew_prefix gstreamer)/lib/libgstreamer-1.0.dylib" "$(brew_prefix gst-plugins-base)/lib/libgstaudio-1.0.dylib")
  for f in "${roots[@]}"; do [ -e "$f" ] || die "$f not found"; bundle_lib "$f"; done

  # 2. every Wine Mach-O finds wine/lib through an rpath
  while IFS= read -r f; do
    case "$f" in
      "$PFX"/bin/*)                    install_name_tool -add_rpath @loader_path/../lib "$f" 2>/dev/null || true ;;
      "$PFX"/lib/wine/*-unix/*)        install_name_tool -add_rpath @loader_path/../.. "$f" 2>/dev/null || true ;;
    esac
  done < <(macho_files "$PFX")

  # 3. licenses of what was copied (Homebrew keeps them in the keg root)
  local lic="$STAGE/third-party-licenses" keg name
  rm -rf "$lic"; mkdir -p "$lic"
  for f in "${BUNDLED_SRC[@]}"; do
    keg="$f"
    case "$f" in
      */Cellar/*) keg="${f%%/Cellar/*}/Cellar/$(echo "${f#*/Cellar/}" | cut -d/ -f1)/$(echo "${f#*/Cellar/}" | cut -d/ -f2)"; name="$(echo "${f#*/Cellar/}" | cut -d/ -f1)" ;;
      *) continue ;;
    esac
    mkdir -p "$lic/$name"
    find "$keg" -maxdepth 2 -type f \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'AUTHORS' \) \
         -exec cp {} "$lic/$name/" \; 2>/dev/null || true
    printf '%s\n' "$f" >> "$lic/$name/SOURCE-LIBRARY.txt"
  done

  # 4. install_name_tool invalidated the signatures: sign everything ad hoc again
  log "ad-hoc signing"
  while IFS= read -r f; do codesign --force --sign - --timestamp=none "$f" >/dev/null 2>&1 || warn "codesign failed for $f"; done < <(macho_files "$PFX")
  ls -la "$PFX/lib" | head -60
}

step_verify() {
  log "verifying bundle"
  local f dep leaf bad=0 minos maxminos="0.0"
  # 1. nothing may point at the build machine
  while IFS= read -r f; do
    for dep in $(deps_of "$f"); do
      case "$dep" in
        /usr/local/*|/opt/homebrew/*|/Users/*|/private/*|"$WORKDIR"/*|/Library/Frameworks/*) echo "BAD: $f -> $dep"; bad=1 ;;
        @rpath/*|@loader_path/*|@executable_path/*)
          leaf="${dep##*/}"
          [ -n "$(find "$PFX" -name "$leaf" -print -quit)" ] || [ "$leaf" = "$(basename "$f")" ] || { echo "BAD: $f needs missing $dep"; bad=1; } ;;
      esac
    done
    for dep in $(rpaths_of "$f"); do
      case "$dep" in /usr/local/*|/opt/homebrew/*|/Users/*|"$WORKDIR"/*) echo "BAD: rpath $dep in $f"; bad=1 ;; esac
    done
    minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/ {b=1} b && $1=="minos" {print $2; exit}')"
    [ -z "$minos" ] && minos="$(otool -l "$f" | awk '/LC_VERSION_MIN_MACOSX/ {b=1} b && $1=="version" {print $2; exit}')"
    if [ -n "$minos" ] && [ "$(printf '%s\n%s\n' "$maxminos" "$minos" | sort -t. -k1,1n -k2,2n | tail -1)" = "$minos" ]; then maxminos="$minos"; MAXMINOS_FILE="$f"; fi
  done < <(macho_files "$PFX")
  [ "$bad" = 0 ] || die "bundle points outside itself (see BAD lines)"
  log "highest minimum macOS among Mach-O files: $maxminos (${MAXMINOS_FILE:-?})"
  echo "$maxminos" > "$WORKDIR/minos.txt"
  if [ -n "${MAX_MINOS:-}" ] && [ "$(printf '%s\n%s\n' "$MAX_MINOS" "$maxminos" | sort -t. -k1,1n -k2,2n | tail -1)" != "$MAX_MINOS" ]; then
    die "needs macOS $maxminos but MAX_MINOS=$MAX_MINOS"
  fi
  # 2. architecture
  for f in bin/wine bin/wineserver lib/wine/x86_64-unix/ntdll.so; do
    file "$PFX/$f" | grep -c x86_64 >/dev/null || die "$f is not x86_64"
  done
  # 3. WoW64 layout
  for f in lib/wine/x86_64-unix/ntdll.so lib/wine/x86_64-windows/ntdll.dll lib/wine/i386-windows/ntdll.dll \
           lib/wine/x86_64-windows/kernel32.dll lib/wine/i386-windows/kernel32.dll lib/wine/x86_64-windows/d3d11.dll \
           lib/wine/x86_64-windows/dxgi.dll lib/wine/x86_64-windows/d3d12.dll lib/wine/x86_64-unix/winemac.so \
           lib/wine/x86_64-unix/win32u.so lib/wine/x86_64-unix/cxcompatdb.so share/wine/wine.inf share/wine/nls/locale.nls; do
    [ -e "$PFX/$f" ] || die "missing $f"
  done
  # 4. CrossOver's D3DMetal code paths are compiled in
  nm -gU "$PFX/lib/wine/x86_64-unix/winemac.so" | grep -c '_macdrv_functions' >/dev/null || die "winemac.so does not export macdrv_functions (D3DMetal hook table)"
  nm -gU "$PFX/lib/wine/x86_64-unix/ntdll.so" | grep -c '_prepend_dll_path' >/dev/null || die "ntdll.so does not export prepend_dll_path"
  strings -a "$PFX/lib/wine/x86_64-unix/ntdll.so" | grep -c 'CX_APPLEGPTK_LIBD3DSHARED_PATH' >/dev/null || die "ntdll.so does not know CX_APPLEGPTK_LIBD3DSHARED_PATH"
  strings -a "$PFX/lib/wine/x86_64-unix/ntdll.so" | grep -c 'cxcompatdb.so' >/dev/null || die "ntdll.so does not load cxcompatdb.so"
  strings -a "$PFX/lib/wine/x86_64-unix/win32u.so" | grep -c 'CX_ACTIVE_GRAPHICS_BACKEND' >/dev/null || die "win32u.so does not know CX_ACTIVE_GRAPHICS_BACKEND"
  # 5. dlopen targets exist
  for f in lib/libfreetype.6.dylib lib/libgnutls.30.dylib lib/libMoltenVK.dylib; do
    [ -e "$PFX/$f" ] || die "bundled $f missing"
  done
  ls "$PFX"/lib/libSDL2*.dylib >/dev/null || die "bundled SDL2 missing"
  log "verify ok"
}

step_smoke() {
  log "smoke test"
  local w="$PFX/bin/wine" tmp pfx out
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cs2l-smoke.XXXXXX")"
  pfx="$tmp/prefix"
  # a clean environment, as the launcher would give it (no Homebrew, no CX_* variables)
  smoke_env() {
    env -i HOME="$tmp/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$tmp" \
        WINEPREFIX="$pfx" WINEDLLPATH="$PFX/lib/wine/x86_64-windows:$PFX/lib/wine/i386-windows:$PFX/lib/wine" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=d" \
        DYLD_FALLBACK_LIBRARY_PATH="$PFX/lib:/usr/lib" "$@"
  }
  mkdir -p "$tmp/home"
  out="$(smoke_env "$w" --version)"; echo "wine --version: $out"
  case "$out" in wine-*) ;; *) die "unexpected wine --version output: $out" ;; esac

  log "wineboot --init (timeout 300 s)"
  if ! run_timeout 300 env -i HOME="$tmp/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$tmp" WINEPREFIX="$pfx" WINEDLLPATH="$PFX/lib/wine/x86_64-windows:$PFX/lib/wine/i386-windows:$PFX/lib/wine" WINEDEBUG=err+all,fixme-all \
       WINEDLLOVERRIDES="mscoree,mshtml=d" DYLD_FALLBACK_LIBRARY_PATH="$PFX/lib:/usr/lib" "$w" wineboot --init > "$LOGS/wineboot.log" 2>&1; then
    tail -n 60 "$LOGS/wineboot.log" || true
    smoke_env "$PFX/bin/wineserver" -k >/dev/null 2>&1 || true
    die "wineboot --init failed or timed out"
  fi
  smoke_env "$PFX/bin/wineserver" -w || true
  [ -f "$pfx/system.reg" ] || die "prefix was not created"
  [ -f "$pfx/drive_c/windows/system32/kernel32.dll" ] || die "system32 not populated"
  [ -f "$pfx/drive_c/windows/syswow64/kernel32.dll" ] || die "syswow64 not populated (WoW64 prefix expected)"

  out="$(run_timeout 120 env -i HOME="$tmp/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$tmp" WINEPREFIX="$pfx" WINEDLLPATH="$PFX/lib/wine/x86_64-windows:$PFX/lib/wine/i386-windows:$PFX/lib/wine" WINEDEBUG=-all \
        DYLD_FALLBACK_LIBRARY_PATH="$PFX/lib:/usr/lib" "$w" cmd /c echo ok 2>&1 | tr -d '\r')" || true
  echo "wine cmd /c echo ok -> [$out]"
  printf '%s\n' "$out" | grep -qx 'ok' || die "cmd /c echo ok printed [$out]"

  out="$(run_timeout 120 env -i HOME="$tmp/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$tmp" WINEPREFIX="$pfx" WINEDLLPATH="$PFX/lib/wine/x86_64-windows:$PFX/lib/wine/i386-windows:$PFX/lib/wine" WINEDEBUG=-all \
        DYLD_FALLBACK_LIBRARY_PATH="$PFX/lib:/usr/lib" "$w" 'C:\windows\syswow64\cmd.exe' /c echo ok32 2>&1 | tr -d '\r')" || true
  echo "32-bit cmd -> [$out]"
  printf '%s\n' "$out" | grep -qx 'ok32' || die "32-bit (WoW64) cmd printed [$out]"

  # cs2l-compat shim: a fake GPTK folder is enough, the shim only checks that the files exist
  local fake="$tmp/gptk"
  mkdir -p "$fake/wine/x86_64-windows" "$fake/wine/x86_64-unix" "$fake/external"
  : > "$fake/wine/x86_64-windows/d3d11.dll"; : > "$fake/wine/x86_64-unix/d3d11.so"; : > "$fake/external/libd3dshared.dylib"
  out="$(run_timeout 120 env -i HOME="$tmp/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$tmp" WINEPREFIX="$pfx" WINEDLLPATH="$PFX/lib/wine/x86_64-windows:$PFX/lib/wine/i386-windows:$PFX/lib/wine" WINEDEBUG=-all \
        DYLD_FALLBACK_LIBRARY_PATH="$PFX/lib:/usr/lib" CX_GRAPHICS_BACKEND=d3dmetal CS2L_D3DMETAL_DIR="$fake" CS2L_COMPAT_DEBUG=1 \
        "$w" cmd /c echo shim 2>&1 | tr -d '\r')" || true
  echo "$out" | grep -q 'cs2l-compat: active backend: d3dmetal' || { echo "$out"; die "cs2l-compat shim did not activate d3dmetal"; }
  log "cs2l-compat shim ok"

  smoke_env "$PFX/bin/wineserver" -k >/dev/null 2>&1 || true
  rm -rf "$tmp"
  log "smoke ok"
}

step_package() {
  log "packaging $ARTIFACT"
  local commit date bi="$WORKDIR/BUILDINFO" root="$WORKDIR/pack/$ARTIFACT" minos
  commit="${GITHUB_SHA:-$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)}"
  date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  minos="$(cat "$WORKDIR/minos.txt" 2>/dev/null || echo unknown)"
  {
    echo "name=$ARTIFACT"
    echo "engine=CS2 Launcher Wine engine (CodeWeavers CrossOver $CX_VERSION sources, LGPL)"
    echo "build=$BUILD_NUMBER"
    echo "built_at=$date"
    echo "launcher_repo_commit=$commit"
    echo "source_url=$CX_URL"
    echo "source_sha256=$(cat "$WORKDIR/source.sha256" 2>/dev/null)"
    echo "source_tree=sources/wine (Wine with CodeWeavers' changes, written offer: the URL above)"
    echo "patches=$(ls "$SELF"/patches/*.patch 2>/dev/null | xargs -n1 basename 2>/dev/null | paste -sd, -)"
    echo "arch=x86_64 (Rosetta 2), WoW64 (i386 + x86_64 PE)"
    echo "min_macos_of_bundle=$minos"
    echo "d3dmetal=hooks compiled in (winemac macdrv_functions, ntdll libd3dshared); Apple's D3DMetal NOT included"
    echo "gstreamer=$WITH_GSTREAMER"
    echo "runner=$(sw_vers -productName) $(sw_vers -productVersion) $(uname -m); Xcode $(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}'); SDK $(xcrun --show-sdk-version 2>/dev/null)"
    echo "clang=$(clang --version | head -1)"
    echo "mingw=$(x86_64-w64-mingw32-gcc --version 2>/dev/null | head -1)"
    echo "homebrew_packages=$("$BREW" list --versions freetype gnutls sdl2 molten-vk 2>/dev/null | tr '\n' ';')"
    echo "configure_flags:"
    sed 's/^/  /' "$WORKDIR/configure.flags"
  } > "$bi"

  rm -rf "$WORKDIR/pack"; mkdir -p "$root"
  # ditto keeps symlinks and permissions
  ditto "$PFX" "$root/wine"
  cp "$bi" "$root/BUILDINFO"
  cp "$SRC/COPYING.LIB" "$root/COPYING.LIB" 2>/dev/null || warn "COPYING.LIB not in sources"
  [ -f "$SRC/LICENSE" ] && cp "$SRC/LICENSE" "$root/LICENSE"
  [ -f "$SRC/AUTHORS" ] && cp "$SRC/AUTHORS" "$root/AUTHORS"
  [ -d "$STAGE/third-party-licenses" ] && ditto "$STAGE/third-party-licenses" "$root/THIRD-PARTY-LICENSES"
  cat > "$root/README.txt" <<EOF
CS2 Launcher Wine engine, built from CodeWeavers' published CrossOver $CX_VERSION sources.
Wine is LGPL-2.1-or-later (COPYING.LIB). Source: $CX_URL
Build recipe: scripts/wine/build.sh in the CS2 Launcher repository. See BUILDINFO.
Apple's D3DMetal (Game Porting Toolkit) is not part of this archive.
EOF

  mkdir -p "$OUT"
  rm -f "$OUT/$ARTIFACT.tar.xz" "$OUT/$ARTIFACT.tar.xz.sha256"
  # top level inside the archive: BUILDINFO, licenses and wine/
  ( cd "$root" && COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --no-xattrs -cf - . | xz -T0 -6 > "$OUT/$ARTIFACT.tar.xz" )
  ( cd "$OUT" && shasum -a 256 "$ARTIFACT.tar.xz" > "$ARTIFACT.tar.xz.sha256" )
  cp "$bi" "$OUT/$ARTIFACT.BUILDINFO"
  ls -la "$OUT"; cat "$OUT/$ARTIFACT.tar.xz.sha256"
  # the archive must unpack on its own and still be self-contained
  local chk="$WORKDIR/unpack-check"; rm -rf "$chk"; mkdir -p "$chk"
  tar -xJf "$OUT/$ARTIFACT.tar.xz" -C "$chk"
  [ -x "$chk/wine/bin/wine" ] || die "archive does not contain wine/bin/wine"
  [ -f "$chk/BUILDINFO" ] || die "archive does not contain BUILDINFO"
  rm -rf "$chk"
}

# ---------------------------------------------------------------- main
STEPS=("$@")
[ ${#STEPS[@]} -gt 0 ] || STEPS=(deps fetch patch configure make install bundle verify smoke package)
for s in "${STEPS[@]}"; do
  case "$s" in
    deps|fetch|patch|configure|make|install|bundle|verify|smoke|package) "step_$s" ;;
    all) ;;
    *) die "unknown step $s" ;;
  esac
done
log "done: $(date -u +%H:%M:%SZ)"
