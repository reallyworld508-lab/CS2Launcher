# Wine engine

The launcher runs Windows games with its own Wine build, made from the sources CodeWeavers
publish for CrossOver (Wine plus CodeWeavers' changes, LGPL-2.1-or-later). No CrossOver
license or CrossOver installation is needed. Apple's D3DMetal is **not** part of the engine:
the user takes it from Apple's Game Porting Toolkit (GPTK) and the launcher points the engine
at it.

This document has two parts: how the engine is built, and the exact runtime contract the
launcher relies on (environment variables, directory layout, DLL lookup).

## 1. What is built

| | |
|---|---|
| Source | `https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz`, 149,054,023 bytes, only `sources/wine` is used |
| Source sha256 | `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872` (pinned as `CX_SHA256` in `scripts/wine/build.sh`; taken from the freequay project, confirmed or corrected by the first CI run, which prints the real hash) |
| Host | x86_64 (runs under Rosetta 2 on Apple silicon). D3DMetal is x86_64 only, and CrossOver's D3DMetal hooks are compiled only for `__APPLE__ && __x86_64__` |
| Mode | new WoW64: `--enable-archs=i386,x86_64`, one `wine` binary runs 32 and 64 bit programs |
| PE compiler | Homebrew `mingw-w64` (gcc) |
| Artifact | `cs2l-wine-crossover-26.3.0-<build>-x86_64.tar.xz` + `.sha256` |

Archive layout:

```
BUILDINFO                      source URL + sha256, launcher commit, date, configure flags, toolchain
COPYING.LIB LICENSE AUTHORS    Wine's license files
THIRD-PARTY-LICENSES/<lib>/    licenses of the bundled dylibs
README.txt
wine/
  bin/            wine, wine-preloader, wineserver, wineboot, ...
  lib/            bundled dylibs (libfreetype, libgnutls + deps, libSDL2, libMoltenVK), install names @rpath/<leaf>
  lib/wine/x86_64-unix/   ntdll.so win32u.so winemac.so ... and cxcompatdb.so (see 2.3)
  lib/wine/x86_64-windows/
  lib/wine/i386-windows/
  share/wine/     nls, fonts, wine.inf
  share/cs2l/cxcompatdb.c  source of the shim in lib/wine/x86_64-unix/cxcompatdb.so
```

The tree is relocatable: Wine finds `lib/wine` from the path of `bin/wine`. Unpack it anywhere.
Every Mach-O is ad-hoc signed again after the install names were rewritten. If the archive is
fetched in a way that adds the quarantine attribute, run `xattr -dr com.apple.quarantine <dir>`.

### Building

CI: `.github/workflows/build-wine.yml`, started by hand (inputs: build number, runner,
optional release tag) or by pushing a tag `wine-<build>`, for example `wine-1`. A tag build
publishes a GitHub release with the tarball and its `.sha256`.

Locally (Intel Mac, or Apple silicon with Rosetta and Homebrew in `/usr/local`):

```
BUILD_NUMBER=dev scripts/wine/build.sh            # all steps, output in .wine-work/out
scripts/wine/build.sh make install bundle verify  # single steps
```

Steps: `deps fetch patch configure make install bundle verify smoke package`. Patches for the
CrossOver sources go in `scripts/wine/patches/*.patch` (none are needed so far).

### Runner

`macos-15-intel` (x86_64, native). GitHub still offers Intel images (`macos-15-intel`,
`macos-26-intel`), so the whole build, including the helper tools Wine runs while building
(`widl`, `winebuild`, `wrc`) and the smoke test, runs natively without Rosetta, and Homebrew
lives in `/usr/local` with x86_64 bottles. Intel images are on their way out; the fallback is
`macos-26` (Apple silicon), where `build.sh` re-executes itself under `arch -x86_64` and
needs an x86_64 Homebrew in `/usr/local` (it installs one if missing). That path is slower
(everything runs translated) and is the less tested one.

### Dependencies (Homebrew)

Build: `bison flex pkgconf mingw-w64 ccache xz`. Libraries that are bundled because Wine
`dlopen`s them: `freetype gnutls sdl2 molten-vk` (and their dependencies: nettle, gmp,
libtasn1, p11-kit, libunistring, libidn2, libpng, ... copied recursively). GStreamer is off
by default (`WITH_GSTREAMER=1` / workflow input to build `winegstreamer`; the GStreamer plugins
are then **not** bundled).

### Configure flags

```
--enable-archs=i386,x86_64 --disable-tests --disable-option-checking --with-mingw
--without-x --without-wayland --with-coreaudio --with-cups
--with-freetype --with-gnutls --with-sdl --with-vulkan --without-gstreamer --without-opengl
--without-alsa --without-capi --without-dbus --without-ffmpeg --without-fontconfig
--without-gettext --without-gettextpo --without-gphoto --without-gssapi --without-hwloc
--without-inotify --without-krb5 --without-netapi --without-oss --without-opencl
--without-pcap --without-pcsclite --without-pulse --without-sane --without-udev
--without-unwind --without-usb --without-v4l2
CC="ccache clang" CFLAGS="-O2 ..." CROSSCFLAGS="-O2" LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../.. -Wl,-rpath,@loader_path/../lib"
ac_cv_func_pipe2=no   ac_cv_lib_soname_freetype=@rpath/libfreetype.6.dylib
ac_cv_lib_soname_gnutls=@rpath/libgnutls.30.dylib   ac_cv_lib_soname_SDL2=@rpath/libSDL2-2.0.0.dylib
ac_cv_lib_soname_vulkan=   ac_cv_lib_soname_MoltenVK=@rpath/libMoltenVK.dylib
```

`--without-opengl` only drops EGL (X11/Wayland); OpenGL on the Mac goes through winemac.drv
with CGL and is always built. The `@rpath/` sonames make Wine's `dlopen` use the rpaths of
the calling Wine library (`bundle` adds `@loader_path/../..`, i.e. `wine/lib`), so a bundled
copy is found and a Homebrew copy never is.

## 2. Runtime contract (D3DMetal)

Everything here was read from the CrossOver 26.3.0 sources and checked against an installed
CrossOver 26.3 (`/Applications/CrossOver.app/Contents/SharedSupport/CrossOver`), which is the
reference for the layout.

### 2.1 What CrossOver's Wine contains (open source, built here)

* `dlls/winemac.drv/d3dmetal.c`, `d3dmetal_objc.m`: winemac.so exports the data symbol
  `macdrv_functions` (a table of 24 function pointers that Apple's D3DMetal looks up in the
  process: window data, Metal view/layer, registry, monitor and window functions). Guarded by
  `__APPLE__ && __x86_64__`. `build.sh verify` checks the symbol with `nm`.
* `dlls/ntdll/unix/loader.c`, "CW HACK 22434": if `CX_APPLEGPTK_LIBD3DSHARED_PATH` is set (and
  macOS is 14 Sonoma or later) ntdll `dlopen`s that file when the first PE module is mapped and
  registers every PE image as a *non-native code region* with it (needed so D3DMetal can run
  next to Rosetta). The variable is read once, lazily, in `pe_module_loaded`. Unset means no
  registration, and D3DMetal then misbehaves under Rosetta.
* `dlls/win32u/d3dkmt.c`, "CW HACK 24905": with `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` the
  D3DKMT query `KMTQAITYPE_WDDM_2_7_CAPS` reports hardware scheduling (`HwSch*` = 1), which
  D3D12 games probe.
* `dlls/win32u/vulkan.c`, "CW HACK 25909": `CX_LIBVULKAN` selects the Vulkan library, honoured
  only when `CX_ACTIVE_GRAPHICS_BACKEND=wined3d`.
* `dlls/ntdll/unix/loader.c`, "CW Hack 24067": ntdll exports `prepend_dll_path(const char*)`
  (puts a directory in front of every other DLL search directory) and, at the end of process
  start-up, `dlopen`s `<directory of ntdll.so>/cxcompatdb.so` if it exists.

### 2.2 What is closed and not used

CrossOver's `bin/wine` is a Perl script and `lib/wine/x86_64-unix/cxcompatdb.so` is a closed,
CrossOver-only binary ("Only licensed for use with CrossOver"). Together they do four jobs:
read `CX_GRAPHICS_BACKEND` (set as a bottle environment variable, e.g. `"CX_GRAPHICS_BACKEND" =
"d3dmetal"` in `cxbottle.conf`), set `CX_ACTIVE_GRAPHICS_BACKEND`, call `prepend_dll_path()` with
`$CX_ROOT/lib64/apple_gptk/wine` (or `lib/dxvk`, `lib/dxmt`), and export
`CX_APPLEGPTK_LIBD3DSHARED_PATH=$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib`. Neither
file is used or shipped. The engine contains its own replacement for the second job (2.3), and
the launcher does the rest (2.5).

Not present in the open sources, so not in the engine: `winemetal.dll` (DXMT's PE half), the
compatibility database, DXVK/DXMT binaries. They can be supplied later through
`CS2L_DXVK_DIR` / `CS2L_DXMT_DIR` / `CS2L_PRIORITY_DLLPATH`.

### 2.3 `cxcompatdb.so`: the engine's own shim

`scripts/wine/compat/cxcompatdb.c` (installed as `wine/share/cs2l/cxcompatdb.c` and built into
`lib/wine/x86_64-unix/cxcompatdb.so`) is a few dozen lines, independent of CodeWeavers' file.
ntdll loads it in every Wine process; its constructor reads:

| Variable | Meaning |
|---|---|
| `CX_GRAPHICS_BACKEND` | `wined3d` (default, also when unset), `d3dmetal`, `dxvk`, `dxmt` |
| `CS2L_D3DMETAL_DIR` | the GPTK `redist/lib` folder: contains `wine/` and `external/` |
| `CS2L_DXVK_DIR`, `CS2L_DXMT_DIR` | folder with `x86_64-windows/` (+ `x86_64-unix/`) of that backend |
| `CS2L_PRIORITY_DLLPATH` | extra directories, `:` separated, put in front of Wine's own (first entry first) |
| `CS2L_COMPAT_DEBUG=1` | print the decision to stderr (`cs2l-compat: ...`) |

For `d3dmetal` it requires `CS2L_D3DMETAL_DIR` to contain `wine/x86_64-windows/d3d11.dll`,
`wine/x86_64-unix/d3d11.so` and `external/libd3dshared.dylib`; then it calls
`prepend_dll_path("<dir>/wine")`. If something is missing it falls back to `wined3d`. Finally it
sets `CX_ACTIVE_GRAPHICS_BACKEND` to the backend actually in use (`d3dmetal`/`dxvk`/`dxmt`/
`wined3d`). The setting is per process and inherited by child processes, and every Wine process
repeats it, so it is consistent for a whole game session. `build.sh smoke` runs a command
with a fake GPTK folder and checks the `active backend: d3dmetal` line.

Why `prepend_dll_path` and not `WINEDLLPATH`: ntdll's default search order is Wine's own
`lib/wine` first, then the `WINEDLLPATH` entries. A `WINEDLLPATH` entry therefore never
overrides the engine's own `d3d11.dll`/`dxgi.dll`. `prepend_dll_path` puts the directory first.
For every search directory `P`, ntdll tries `P/x86_64-windows/<name>.dll` for the PE image and
`P/x86_64-unix/<name>.so` for its Unix half, so the directory must be `.../wine`, the parent of
both. A 32-bit process looks in `P/i386-windows`, which GPTK does not have, so 32-bit programs
keep Wine's own Direct3D (D3DMetal is 64-bit only).

### 2.4 Layout the engine expects for D3DMetal

The user gets Apple's "Evaluation environment for Windows games" (Game Porting Toolkit) disk
image and copies the **contents of its `redist/lib`** folder to a place the launcher owns, for
example `~/Library/Application Support/<launcher>/gptk/`. It must keep this shape (this is
also exactly CrossOver 26.3's `lib64/apple_gptk`):

```
<gptk>/external/D3DMetal.framework
<gptk>/external/libd3dshared.dylib          (install name @rpath/libd3dshared.dylib, LC_RPATH @loader_path)
<gptk>/wine/x86_64-windows/d3d11.dll  d3d12.dll  dxgi.dll  (d3d10.dll, nvapi64.dll, atidxx64.dll, nvngx*.dll when present)
<gptk>/wine/x86_64-unix/d3d11.so  d3d12.so  dxgi.so ...    (symlinks to ../../external/libd3dshared.dylib)
```

Copy with `ditto`/`cp -R` so the symlinks and the `D3DMetal.framework` bundle stay intact; do
not flatten them. The PE files are Wine *builtin* DLLs (the string `Wine builtin DLL` at offset
0x40) and only work as builtins: a builtin gets its Unix half from `x86_64-unix` next to its PE
directory, which is why the directory is put on the DLL path instead of copying DLLs into
prefixes. libd3dshared depends only on system libraries (libc++, Foundation, CoreGraphics,
libobjc, libSystem) and reaches Wine through the process (`macdrv_functions`, ntdll), so the
GPTK needs no copy of Wine's `.so` files. Check a new GPTK release once with
`otool -L external/libd3dshared.dylib`: a dependency on `@rpath/ntdll.so`, `win32u.so` or
`winemac.so` would mean those need to be linked next to it.

Prefix side (verified on a CrossOver 26.3 bottle): the prefix's `system32` holds `d3d11.dll`,
`d3d12.dll`, `dxgi.dll` as copies of the engine's builtin (marked, so Wine loads the builtin
from the DLL path, which now resolves to GPTK's), and 1032-byte files starting with
`Wine placeholder DLL` for `nvapi64.dll`, `atidxx64.dll`, `nvngx.dll`. Wine only loads a
GPTK-only builtin if the prefix has such a placeholder, so after `wineboot` the launcher should,
for each of `nvapi64.dll atidxx64.dll nvngx.dll` that exists in `<gptk>/wine/x86_64-windows`
and not in `system32`, copy GPTK's file (it is builtin-marked and works as its own placeholder)
into `drive_c/windows/system32`. This is only for NVIDIA/AMD API emulation and is not needed
for plain D3D11/D3D12.

### 2.5 What the launcher must set, per launch

```
E=<engine>/wine                         # the unpacked "wine" directory
G=<gptk>                                # contains external/ and wine/

WINEPREFIX=<prefix>
CX_GRAPHICS_BACKEND=d3dmetal            # or wined3d (default) / dxvk / dxmt
CS2L_D3DMETAL_DIR=$G
CX_APPLEGPTK_LIBD3DSHARED_PATH=$G/external/libd3dshared.dylib   # set BEFORE the first wine process
ROSETTA_ADVERTISE_AVX=1                 # CrossOver sets this unless the user chose otherwise
DOTNET_EnableWriteXorExecute=0          # CrossOver sets this: .NET 7/8 under Rosetta
WINEMSYNC=1                             # optional: msync. wineserver and all clients must agree
DYLD_FALLBACK_LIBRARY_PATH=$E/lib:/usr/lib   # belt and braces; the rpaths already point at $E/lib
WINEDEBUG=-all                          # unless debugging
exec $E/bin/wine <program.exe>
```

Notes:

* `CX_APPLEGPTK_LIBD3DSHARED_PATH` must be in the environment of the *first* process: ntdll reads
  it once, when the first PE module is mapped, which can happen before `cxcompatdb.so` is loaded,
  so the shim does not try to supply it. CrossOver sets it unconditionally, "regardless of whether
  D3DMetal is enabled"; do the same (only if the file exists).
* `CX_ACTIVE_GRAPHICS_BACKEND` is set by the shim. Do not set it by hand unless the shim is
  bypassed; if both exist the shim's value wins.
* `WINEDLLPATH` is **required**: `<engine>/wine/lib/wine/x86_64-windows:<engine>/wine/lib/wine/i386-windows:<engine>/wine/lib/wine`
  (the same value CrossOver's Perl wrapper sets). Without it the CrossOver loader fails with
  `could not load kernel32.dll, status c0000135`. D3DMetal still wins because the shim uses
  `prepend_dll_path`, which goes before `WINEDLLPATH`.
* No `WINELOADER`, `WINEWRAPPER` or `CX_ROOT` is needed (those belong to the Perl wrapper;
  `CX_ROOT` is only used for the Dock icon). Do not set `WINEDLLOVERRIDES` for d3d11,
  d3d12 or dxgi: the builtin lookup is what selects D3DMetal. To get Wine's own Direct3D back,
  set `CX_GRAPHICS_BACKEND=wined3d` (or leave it unset).
* Metal HUD: `MTL_HUD_ENABLED=1`. MoltenVK (wined3d/vkd3d path, not D3DMetal): bundled copy,
  found through the `@rpath` soname.
* Rosetta must be installed. D3DMetal needs macOS 14 or later (non-native code regions).
* One prefix can be started with any backend; switching is only the environment above.
* Debugging: `CS2L_COMPAT_DEBUG=1` prints the shim's decision; `WINEDEBUG=+loaddll` shows which
  `d3d11.dll` was loaded and from which directory (it must be `<gptk>/wine/x86_64-windows`).

Licensing: Apple's GPTK/D3DMetal stays under Apple's license; the launcher must not bundle or
download it on the user's behalf beyond what that license allows. The engine contains none of it.

## 3. Expected problems and limits

* **First CI run may fail** in configure or make (new compiler/SDK, flags, Homebrew formula
  names); `logs/configure.log`, `logs/make.log` and `config.log` are uploaded on failure.
  Fixes go to `scripts/wine/patches/` or `build.sh`.
* **Minimum macOS.** Bundled Homebrew dylibs are built for the runner's macOS (15), so the
  bundle needs macOS 15 or newer. `verify` prints the highest `minos` found and `MAX_MINOS`
  can enforce a limit. Lower needs libraries built from source (as freequay does).
* **MoltenVK.** The Homebrew build is the stock one. freequay reports crashes of wined3d on
  stock MoltenVK and uses CodeWeavers' copy (`sources/moltenvk`, built with Xcode). This does
  not touch the D3DMetal path.
* **Smoke test on a headless runner.** `wineboot --init` starts `explorer.exe` and the Mac
  driver; it needs a window-server session. GitHub's macOS runners have one; if the step hangs,
  look at the timeout message first.
* **Rosetta fallback runner** (`macos-26`) is slower and less tested.
* **Intel runner lifetime.** Apple ended Intel Macs; GitHub's Intel images will be removed. The
  Rosetta path is the plan B.
* **PE toolchain.** gcc-based mingw-w64 is used on purpose: another project measured that a
  `kernelbase.dll` built with llvm-mingw broke Steam's login, with gcc it worked.
* **32-bit.** `wine` handles 32-bit programs through WoW64; the 32-bit Direct3D path is Wine's
  own (no D3DMetal). `ac_cv_func_pipe2=no` keeps binaries from a new SDK loadable on older macOS.
* **Windows "not on screen" while testing.** Wine windows (and those of any Cocoa app started
  from a non-GUI parent such as a script or an agent shell) are ordered in on the first desktop
  Space, not on the Space that is active. If the active Space is another app's full-screen
  Space, `kCGWindowIsOnscreen` is 0 and nothing is visible, although the window is complete
  (`screencapture -l <window id>` captures it). This is not an engine defect: CrossOver's own
  `wineloader` behaves the same. Verify from a regular desktop Space.
* **Reproducibility.** Homebrew versions are recorded in `BUILDINFO` but not pinned.

## 4. Credits and licenses

* CodeWeavers, Inc. and the Wine project: the sources (LGPL-2.1-or-later). "CrossOver" is a
  trademark of CodeWeavers; this project is not affiliated with or supported by CodeWeavers or
  Apple. If you want a supported product, buy CrossOver.
* Approach and parts of the recipe were learned from, and adapted with credit, from:
  [zienert/freequay](https://github.com/zienert/freequay) (MIT; builds the same 26.3.0 tarball
  as x86_64 WoW64, `ac_cv_func_pipe2`, headerpad, `--without-opengl` note),
  [GabLeRoux/macos-crossover-wine-cloud-builder](https://github.com/GabLeRoux/macos-crossover-wine-cloud-builder)
  (MIT; GitHub Actions structure, `ac_cv_lib_soname_MoltenVK`),
  [peterkmet/wine-cross](https://github.com/peterkmet/wine-cross) (MIT) and
  [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds) (the
  `wine/{bin,lib,share}` layout; only consulted as references, nothing taken from them), and
  [dappermint/winecx-gptk](https://github.com/dappermint/winecx-gptk) (gcc-mingw finding,
  ccache settings, ffmpeg/gstreamer configure checks). No code was copied from projects that
  have no license; the shim and `build.sh` are written for this repository.
* The source tarball is downloaded from CodeWeavers' server at build time and is not
  redistributed by this repository; the release archive contains compiled code, so
  `BUILDINFO` names the exact source URL and sha256 (LGPL source offer).
