#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_ROOT="${1:-$(pwd)}"
KSU_DIR="$KERNEL_ROOT/KernelSU/kernel"

die() {
  echo "[sukisu-4.9-audit] ERROR: $*" >&2
  exit 1
}

ok() {
  echo "[sukisu-4.9-audit] OK: $*"
}

test -f "$KERNEL_ROOT/Makefile" || die "kernel Makefile missing"
test -f "$KERNEL_ROOT/include/trace/events/syscalls.h" || die "syscall tracepoint header missing"
test -f "$KERNEL_ROOT/arch/arm64/kernel/entry.S" || die "ARM64 syscall entry missing"
test -f "$KSU_DIR/hook/syscall_hook_manager.c" || die "SukiSU syscall hook manager missing"
test -f "$KSU_DIR/hook/arm64/syscall_hook.c" || die "SukiSU ARM64 syscall hook missing"
test -f "$KSU_DIR/runtime/ksud_integration.c" || die "SukiSU ksud integration missing"

grep -Eq '^VERSION = 4$' "$KERNEL_ROOT/Makefile" || die "kernel VERSION is not 4"
grep -Eq '^PATCHLEVEL = 9$' "$KERNEL_ROOT/Makefile" || die "kernel PATCHLEVEL is not 9"
ok "kernel version is Linux 4.9"

grep -Fq 'TP_PROTO(struct pt_regs *regs, long id)' "$KERNEL_ROOT/include/trace/events/syscalls.h" || die "Linux 4.9 sys_enter tracepoint signature differs"
grep -Fq 'syscall_get_arguments(current, regs, 0, 6' "$KERNEL_ROOT/include/trace/events/syscalls.h" || die "sys_enter tracepoint does not expose syscall arguments as expected"
grep -Fq 'syscall_trace_enter' "$KERNEL_ROOT/arch/arm64/kernel/entry.S" || die "ARM64 entry.S lacks syscall trace-enter path"
grep -Fq 'ldr	x16, [stbl, scno, lsl #3]' "$KERNEL_ROOT/arch/arm64/kernel/entry.S" || die "ARM64 entry.S syscall-table dispatch pattern changed"
ok "Linux 4.9 ARM64 syscall ABI matches the pinned SukiSU tracepoint-dispatch design"

grep -Fq 'register_trace_prio_sys_enter' "$KSU_DIR/hook/syscall_hook_manager.c" || die "SukiSU tracepoint redirect registration missing"
grep -Fq 'ksu_dispatcher_nr' "$KSU_DIR/hook/arm64/syscall_hook.c" || die "SukiSU ARM64 dispatcher slot missing"
grep -Fq 'ksu_syscall_table_hook' "$KSU_DIR/hook/arm64/syscall_hook.c" || die "SukiSU syscall-table patcher missing"
ok "SukiSU runtime hook backend is Tracepoint Syscall Redirect + ARM64 dispatcher"

grep -Fq 'exec u:r:' "$KSU_DIR/runtime/ksud_integration.c" || die "KERNEL_SU_RC SELinux exec rule missing"
grep -Fq 'KERNEL_SU_DOMAIN' "$KSU_DIR/runtime/ksud_integration.c" || die "KernelSU SELinux domain missing"
grep -Fq '#define KSUD_PATH "/data/adb/ksud"' "$KSU_DIR/runtime/ksud.h" || die "KSUD_PATH is not /data/adb/ksud"
grep -Fq 'post-fs-data' "$KSU_DIR/runtime/ksud_integration.c" || die "post-fs-data stage missing"
grep -Fq 'boot-completed' "$KSU_DIR/runtime/ksud_integration.c" || die "boot-completed stage missing"
ok "ksud bootstrap chain is present"

# v4.2.0's pinned source does not select the old CONFIG_KSU_MANUAL_HOOK
# mechanism. Do not add direct syscall/VFS edits to fs/ as part of this
# integration unless a future pinned SukiSU revision explicitly requires it.
if grep -Rqs 'CONFIG_KSU_MANUAL_HOOK' "$KSU_DIR"; then
  die "unexpected CONFIG_KSU_MANUAL_HOOK in pinned v4.2.0 source"
fi
ok "no legacy CONFIG_KSU_MANUAL_HOOK integration is being injected"

echo "[sukisu-4.9-audit] PASS"
