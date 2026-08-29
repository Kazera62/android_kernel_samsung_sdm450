#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEFCONFIG="${DEFCONFIG:-a11q_open_defconfig}"
OUT="${OUT:-$ROOT/out-kazera-oc}"
CLANG="${CLANG:-0}"
JOBS="${JOBS:-$(nproc)}"
KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:--Kazera-OC-2.4G-800M}"
KERNEL_HOSTNAME="${KERNEL_HOSTNAME:-Kazera-Builder}"
KBUILD_USER="${KBUILD_USER:-Kazera}"

cd "$ROOT"

./scripts/kazera_oc_apply.sh "$ROOT"

make O="$OUT" ARCH=arm64 mrproper
make O="$OUT" ARCH=arm64 "$DEFCONFIG"

# Stamp a deterministic kernel identity after defconfig generation.
# scripts/config exists in this kernel tree and edits only O=.config.
./scripts/config --file "$OUT/.config" \
    --set-str CONFIG_LOCALVERSION "$KERNEL_LOCALVERSION" \
    --set-str CONFIG_DEFAULT_HOSTNAME "$KERNEL_HOSTNAME"

make O="$OUT" ARCH=arm64 olddefconfig

export KBUILD_BUILD_USER="$KBUILD_USER"
export KBUILD_BUILD_HOST="$KERNEL_HOSTNAME"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-2026-08-29 00:00:00 +0000}"

BASE_MAKE=(make O="$OUT" ARCH=arm64)

if [ "$CLANG" = "1" ]; then
    : "${CLANG_TRIPLE:=aarch64-linux-gnu-}"
    "${BASE_MAKE[@]}" LLVM=1 LLVM_IAS=1 CLANG_TRIPLE="$CLANG_TRIPLE" -j"$JOBS"
else
    "${BASE_MAKE[@]}" CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-android-}" -j"$JOBS"
fi

echo
echo "Kernel identity: $KERNEL_LOCALVERSION"
echo "Build host:      $KERNEL_HOSTNAME"
echo "Build user:      $KBUILD_USER"
echo "Build output:    $OUT/arch/arm64/boot/Image.gz-dtb"
[ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ] || { echo "ERROR: Image.gz-dtb was not produced" >&2; exit 1; }
