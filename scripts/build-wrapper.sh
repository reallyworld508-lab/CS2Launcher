#!/bin/bash
# Compiles wrapper/steamwebhelper-wrapper.c into the checked-in resource.
set -euo pipefail
cd "$(dirname "$0")/.."
LLVM_MINGW="${LLVM_MINGW:-$PWD/.toolchain/llvm-mingw-20261020-ucrt-macos-universal}"
CC="$LLVM_MINGW/bin/x86_64-w64-mingw32-clang"
[ -x "$CC" ] || { echo "Compiler not found: $CC (set LLVM_MINGW)" >&2; exit 1; }
OUT="Sources/CS2LauncherCore/Resources/steamwebhelper-wrapper.exe"
mkdir -p "$(dirname "$OUT")"
"$CC" -O2 -municode -mwindows -static -o "$OUT" wrapper/steamwebhelper-wrapper.c
"$LLVM_MINGW/bin/llvm-strip" "$OUT" 2>/dev/null || true
echo "Built $OUT ($(stat -f%z "$OUT") bytes)"
