#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEFCONFIG="${DEFCONFIG:-a11q_open_defconfig}"
OUT="${OUT:-$ROOT/out-kazera-oc}"
CLANG="${CLANG:-0}"
JOBS="${JOBS:-$(nproc)}"

cd "$ROOT"

./scripts/kazera_oc_apply.sh "$ROOT"

make O="$OUT" ARCH=arm64 mrproper
make O="$OUT" ARCH=arm64 "$DEFCONFIG"

if [ "$CLANG" = "1" ]; then
    : "${CLANG_TRIPLE:=aarch64-linux-gnu-}"
    make O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 CLANG_TRIPLE="$CLANG_TRIPLE" -j"$JOBS"
else
    make O="$OUT" ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-android-}" -j"$JOBS"
fi

echo
printf '%s\n' "Build output: $OUT/arch/arm64/boot/Image.gz-dtb"
[ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ] || true
