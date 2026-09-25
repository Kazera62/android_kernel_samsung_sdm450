#!/usr/bin/env bash
set -euo pipefail

KERNEL_ROOT="${1:-$(pwd)}"
SUKISU_REPO="${2:-https://github.com/SukiSU-Ultra/SukiSU-Ultra.git}"
SUKISU_REF="${3:-85eb4a95b8a61d756ecf53b9c5785e48e1b15039}"

KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd)"
DRIVER_DIR="$KERNEL_ROOT/drivers"
DRIVER_MAKEFILE="$DRIVER_DIR/Makefile"
DRIVER_KCONFIG="$DRIVER_DIR/Kconfig"
KSU_DIR="$KERNEL_ROOT/KernelSU"

die() { echo "[sukisu] ERROR: $*" >&2; exit 1; }
log() { echo "[sukisu] $*"; }

test -d "$DRIVER_DIR" || die "drivers/ directory not found"
test -f "$DRIVER_MAKEFILE" || die "drivers/Makefile not found"
test -f "$DRIVER_KCONFIG" || die "drivers/Kconfig not found"

rm -rf "$KSU_DIR"
git clone --depth=1 "$SUKISU_REPO" "$KSU_DIR"
git -C "$KSU_DIR" fetch --depth=1 origin "$SUKISU_REF"
git -C "$KSU_DIR" checkout --detach "$SUKISU_REF"

test "$(git -C "$KSU_DIR" rev-parse HEAD)" = "$SUKISU_REF"
test -f "$KSU_DIR/kernel/Kconfig"
test -f "$KSU_DIR/kernel/Makefile"
test -f "$KSU_DIR/kernel/ksu.c"

rm -f "$DRIVER_DIR/kernelsu"
ln -s ../KernelSU/kernel "$DRIVER_DIR/kernelsu"

grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' "$DRIVER_MAKEFILE" ||
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRIVER_MAKEFILE"

grep -Fq 'source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG" ||
  sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG"

test -L "$DRIVER_DIR/kernelsu"
test "$(readlink "$DRIVER_DIR/kernelsu")" = "../KernelSU/kernel"
test "$(git -C "$KSU_DIR" rev-parse HEAD)" = "$SUKISU_REF"

git -C "$KSU_DIR" status --short
log "SukiSU-Ultra source integrated"
log "release=v4.2.0"
log "commit=$SUKISU_REF"
