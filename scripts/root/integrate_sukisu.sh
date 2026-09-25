#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_ROOT="${1:-$(pwd)}"
SUKISU_REPO="${2:-https://github.com/SukiSU-Ultra/SukiSU-Ultra.git}"
SUKISU_VERSION="${SUKISU_VERSION:-v4.2.0}"
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
test -n "$SUKISU_REF" || die "SukiSU ref is empty"

rm -rf "$KSU_DIR"

log "Cloning SukiSU-Ultra release: $SUKISU_VERSION"
git clone --depth=1 --single-branch --branch "$SUKISU_VERSION" "$SUKISU_REPO" "$KSU_DIR"

log "Verifying exact SukiSU commit"
git -C "$KSU_DIR" fetch --depth=1 origin "$SUKISU_REF"
git -C "$KSU_DIR" checkout --detach "$SUKISU_REF"

actual_ref="$(git -C "$KSU_DIR" rev-parse HEAD)"
log "SukiSU checkout: expected=$SUKISU_REF actual=$actual_ref"
test "$actual_ref" = "$SUKISU_REF" ||
  die "SukiSU revision mismatch: expected $SUKISU_REF, got $actual_ref"

test -f "$KSU_DIR/kernel/Kconfig" || die "SukiSU kernel/Kconfig missing"
test -f "$KSU_DIR/kernel/Makefile" || die "SukiSU kernel/Makefile missing"
test -f "$KSU_DIR/kernel/ksu.c" || die "SukiSU kernel/ksu.c missing"
test -f "$KSU_DIR/kernel/core/init.c" || die "SukiSU kernel/core/init.c missing"

log "Removing previous drivers/kernelsu integration if present"
rm -rf "$DRIVER_DIR/kernelsu"
ln -s ../KernelSU/kernel "$DRIVER_DIR/kernelsu"

grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' "$DRIVER_MAKEFILE" ||
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRIVER_MAKEFILE"

grep -Fq 'source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG" ||
  sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG"

test -L "$DRIVER_DIR/kernelsu"
test "$(readlink "$DRIVER_DIR/kernelsu")" = "../KernelSU/kernel"

log "Verifying integrated source"
test "$(git -C "$KSU_DIR" rev-parse HEAD)" = "$SUKISU_REF"
test -f "$KSU_DIR/kernel/Kconfig"
test -f "$KSU_DIR/kernel/Makefile"
test -f "$KSU_DIR/kernel/ksu.c"

if ! grep -Fq 'config KSU' "$KSU_DIR/kernel/Kconfig"; then
  die "SukiSU KSU config entry missing"
fi
if ! grep -Fq 'config KSU_MANUAL_SU' "$KSU_DIR/kernel/Kconfig"; then
  die "SukiSU KSU_MANUAL_SU config entry missing"
fi

printf '[sukisu] STATUS release=%s commit=%s kernel=%s\n' \
  "$SUKISU_VERSION" "$SUKISU_REF" "$(cd "$KSU_DIR" && git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD)"

log "SukiSU-Ultra source integrated successfully"
