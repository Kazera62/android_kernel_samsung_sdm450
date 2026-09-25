#!/usr/bin/env bash
set -euo pipefail

KERNEL_ROOT="${1:-$(pwd)}"
SUKISU_REF="${2:-85eb4a95b8a61d756ecf53b9c5785e48e1b15039}"

KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd)"
KSU_DIR="$KERNEL_ROOT/KernelSU/kernel"

die() { echo "[sukisu] VERIFY ERROR: $*" >&2; exit 1; }
ok() { echo "[sukisu] VERIFY OK: $*"; }

test -L "$KERNEL_ROOT/drivers/kernelsu" || die "drivers/kernelsu is not a symlink"
test "$(readlink "$KERNEL_ROOT/drivers/kernelsu")" = "../KernelSU/kernel" || die "unexpected kernelsu symlink"
test -d "$KSU_DIR" || die "KernelSU/kernel missing"
test "$(git -C "$KERNEL_ROOT/KernelSU" rev-parse HEAD)" = "$SUKISU_REF" || die "SukiSU ref mismatch"
test -f "$KSU_DIR/Kconfig"
test -f "$KSU_DIR/Makefile"
test -f "$KSU_DIR/core/init.c"
test -f "$KSU_DIR/Kbuild"

grep -Fq 'config KSU' "$KSU_DIR/Kconfig" || die "KSU config missing"
grep -Fq 'depends on KPROBES && EXT4_FS' "$KSU_DIR/Kconfig" || die "this SukiSU release requires KPROBES + EXT4_FS"
grep -Fq 'config KSU_MANUAL_SU' "$KSU_DIR/Kconfig" || die "SukiSU manual-su config missing"
grep -Fq '#elif defined(__aarch64__)' "$KSU_DIR/hook/syscall_hook.h" || die "ARM64 syscall_fn_t compatibility missing"
grep -Fq 'typedef void (*syscall_fn_t)(void);' "$KSU_DIR/hook/syscall_hook.h" || die "ARM64 syscall_fn_t typedef missing"
grep -Fq '#ifdef MODULE_IMPORT_NS' "$KSU_DIR/core/init.c" || die "MODULE_IMPORT_NS 4.9 compatibility guard missing"
if grep -RqsF '#include <linux/pgtable.h>' "$KSU_DIR"; then
  die "SukiSU still references linux/pgtable.h after Linux 4.9 compatibility pass"
fi
if grep -RqsF 'untagged_addr((unsigned long)*filename_user)' "$KSU_DIR"; then
  die "SukiSU still uses the unavailable 4.9 untagged_addr() form"
fi
if grep -RqsF '#include <linux/compiler_types.h>' "$KSU_DIR"; then
  die "SukiSU still references linux/compiler_types.h after Linux 4.9 compatibility pass"
fi

ok "SukiSU-Ultra v4.2.0 source is pinned and integrated with Linux 4.9 compatibility"
