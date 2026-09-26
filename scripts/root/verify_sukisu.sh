#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_ROOT="${1:-$(pwd)}"
SUKISU_REF="${2:-85eb4a95b8a61d756ecf53b9c5785e48e1b15039}"

KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd)"
KSU_DIR="$KERNEL_ROOT/KernelSU/kernel"

die() { echo "[sukisu] VERIFY ERROR: $*" >&2; exit 1; }
ok() { echo "[sukisu] VERIFY OK: $*"; }

[[ "$SUKISU_REF" =~ ^[0-9a-f]{40}$ ]] || die "expected a full 40-character SukiSU SHA"
test -L "$KERNEL_ROOT/drivers/kernelsu" || die "drivers/kernelsu is not a symlink"
test "$(readlink "$KERNEL_ROOT/drivers/kernelsu")" = "../KernelSU/kernel" || die "unexpected kernelsu symlink: $(readlink "$KERNEL_ROOT/drivers/kernelsu")"
test -d "$KSU_DIR" || die "KernelSU/kernel missing"
test "$(git -C "$KERNEL_ROOT/KernelSU" rev-parse HEAD)" = "$SUKISU_REF" || die "SukiSU final SHA mismatch"
test -f "$KERNEL_ROOT/drivers/Makefile" || die "drivers/Makefile missing"
test -f "$KERNEL_ROOT/drivers/Kconfig" || die "drivers/Kconfig missing"
test -f "$KSU_DIR/Kconfig" || die "SukiSU kernel/Kconfig missing"
test -f "$KSU_DIR/Makefile" || die "SukiSU kernel/Makefile missing"
test -f "$KSU_DIR/Kbuild" || die "SukiSU kernel/Kbuild missing"
test -f "$KSU_DIR/core/init.c" || die "SukiSU kernel/core/init.c missing (v4.2.0 layout)"
test -f "$KSU_DIR/hook/syscall_hook.h" || die "SukiSU syscall hook header missing"
test -f "$KSU_DIR/hook/syscall_hook_manager.c" || die "SukiSU syscall hook manager missing"
test -f "$KSU_DIR/hook/syscall_event_bridge.c" || die "SukiSU syscall event bridge missing"
test -f "$KSU_DIR/hook/arm64/syscall_hook.c" || die "SukiSU ARM64 syscall hook missing"

grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_ROOT/drivers/Makefile" || die "drivers/Makefile entry missing"
grep -Fq 'source "drivers/kernelsu/Kconfig"' "$KERNEL_ROOT/drivers/Kconfig" || die "drivers/Kconfig entry missing"
grep -Fq 'config KSU' "$KSU_DIR/Kconfig" || die "KSU config missing"
grep -Fq 'depends on KPROBES && EXT4_FS' "$KSU_DIR/Kconfig" || die "v4.2.0 KSU dependency changed"
grep -Fq 'config KSU_MANUAL_SU' "$KSU_DIR/Kconfig" || die "SukiSU manual-su config missing"
grep -Fq 'obj-$(CONFIG_KSU) += kernelsu.o' "$KSU_DIR/Kbuild" || die "SukiSU Kbuild target missing"
grep -Fq 'ksu_syscall_hook_init();' "$KSU_DIR/core/init.c" || die "syscall hook init is not called"
grep -Fq 'ksu_syscall_hook_manager_init();' "$KSU_DIR/core/init.c" || die "syscall hook manager init is not called"
grep -Fq 'register_trace_prio_sys_enter' "$KSU_DIR/hook/syscall_hook_manager.c" || die "tracepoint syscall redirect backend missing"
grep -Fq 'ksu_dispatcher_nr' "$KSU_DIR/hook/arm64/syscall_hook.c" || die "ARM64 dispatcher backend missing"
grep -Fq '#define KSUD_PATH "/data/adb/ksud"' "$KSU_DIR/runtime/ksud.h" || die "KSUD_PATH is not /data/adb/ksud"
grep -Fq 'KERNEL_SU_RC' "$KSU_DIR/runtime/ksud_integration.c" || die "KERNEL_SU_RC bootstrap is missing"
grep -Fq '#elif defined(__aarch64__)' "$KSU_DIR/hook/syscall_hook.h" || die "ARM64 syscall_fn_t compatibility missing"
grep -Fq 'typedef void (*syscall_fn_t)(void);' "$KSU_DIR/hook/syscall_hook.h" || die "ARM64 syscall_fn_t typedef missing"
grep -Fq 'ksu_call_original_syscall' "$KSU_DIR/hook/syscall_hook.h" || die "Linux 4.9 syscall ABI shim missing"
grep -Fq 'ksu_strncpy_from_user_nofault' "$KSU_DIR/kernel_compat.h" || die "Linux 4.9 strncpy compatibility shim missing"
python3 - "$KSU_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path in root.rglob("*.c"):
    text = path.read_text()
    if "ksu_strncpy_from_user_nofault(" in text and '#include "kernel_compat.h"' not in text:
        raise SystemExit(f"kernel_compat.h missing from {path}")
PY
grep -Fq '#define ksu_close_fd sys_close' "$KSU_DIR/include/util.h" || die "Linux 4.9 sys_close compatibility shim missing"
python3 - "$KSU_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path in root.rglob("*"):
    if path.suffix not in {".c", ".h"} or not path.is_file():
        continue
    text = path.read_text()
    if "copy_from_user_nofault" in text or "copy_to_user_nofault" in text:
        raise SystemExit(f"raw user-copy nofault API remains: {path}")
PY
python3 - "$KSU_DIR" <<'PY'
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
raw = []
for path in root.rglob("*"):
    if path.suffix not in {".c", ".h"} or not path.is_file():
        continue
    if re.search(r"(?<!ksu_)strncpy_from_user_nofault", path.read_text()):
        raw.append(str(path))
if raw:
    raise SystemExit("raw strncpy_from_user_nofault remains: " + ", ".join(raw))
PY
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

ok "SukiSU-Ultra v4.2.0 source is pinned"
ok "kernel integration: drivers/kernelsu -> ../KernelSU/kernel"
ok "hook backend: Tracepoint Syscall Redirect + ARM64 syscall-table dispatcher"
ok "bootstrap path: KERNEL_SU_RC -> /data/adb/ksud"
ok "Linux 4.9 compatibility transforms verified"
