#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TAG="${KSU_TAG:-v1.1.1}"
KSU_DIR="$ROOT/KernelSU-Next"
DRIVER_DIR="$ROOT/drivers"

[ -d "$DRIVER_DIR" ] || { echo "drivers/ missing" >&2; exit 1; }

if [ ! -d "$KSU_DIR/.git" ]; then
    git clone --depth=1 --branch "$TAG" https://github.com/KernelSU-Next/KernelSU-Next "$KSU_DIR"
else
    git -C "$KSU_DIR" fetch --depth=1 origin tag "$TAG"
    git -C "$KSU_DIR" checkout -f "$TAG"
fi

ln -sfn "$(realpath --relative-to="$DRIVER_DIR" "$KSU_DIR/kernel")" "$DRIVER_DIR/kernelsu"

# KernelSU-Next v1.1.1 legacy integration.
if ! grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$DRIVER_DIR/Makefile"; then
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRIVER_DIR/Makefile"
fi
if ! grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"; then
    printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$DRIVER_DIR/Kconfig"
fi

printf '%s\n' "KernelSU-Next pinned: $TAG"
