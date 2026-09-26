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
grep -Fq '4.9 LSM head_addr=' "$KSU_DIR/hook/lsm_hook.c" || die "Linux 4.9 list_head LSM adapter missing"
grep -Fq 'list_for_each_entry (entry, head_49, list)' "$KSU_DIR/hook/lsm_hook.c" || die "Linux 4.9 LSM list walker missing"
grep -Fq 'list_del_rcu(&hook->list.list)' "$KSU_DIR/hook/lsm_hook.c" || die "Linux 4.9 LSM injected-entry cleanup missing"

grep -Fq '#define KSUD_PATH "/data/adb/ksud"' "$KSU_DIR/runtime/ksud.h" || die "KSUD_PATH is not /data/adb/ksud"
grep -Fq 'KERNEL_SU_RC' "$KSU_DIR/runtime/ksud_integration.c" || die "KERNEL_SU_RC bootstrap is missing"
grep -Eq '#if defined\(__aarch64__\)|#elif defined\(__aarch64__\)' "$KSU_DIR/hook/syscall_hook.h" || die "ARM64 syscall_fn_t compatibility missing"
grep -Fq 'typedef void (*syscall_fn_t)(void);' "$KSU_DIR/hook/syscall_hook.h" || die "ARM64 syscall_fn_t typedef missing"
grep -Fq '#include <linux/version.h>' "$KSU_DIR/hook/syscall_hook.h" || die "Linux version header missing from syscall hook header"
grep -Fq 'ksu_call_original_syscall' "$KSU_DIR/hook/syscall_hook.h" || die "Linux 4.9 syscall ABI shim missing"
grep -Fq '#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)' "$KSU_DIR/hook/arm64/patch_memory.c" || die "Linux 4.9 patch_memory guard missing"
grep -Eq 'pgd_t[[:space:]]+\*pgd;' "$KSU_DIR/hook/arm64/patch_memory.c" || die "Linux 4.9 patch_memory pgd walker missing"
grep -Fq 'pte_pfn(*pte)' "$KSU_DIR/hook/arm64/patch_memory.c" || die "Linux 4.9 patch_memory pte conversion missing"
grep -Fq 'memcpy(map, src, len);' "$KSU_DIR/hook/arm64/patch_memory.c" || die "Linux 4.9 patch_memory copy fallback missing"
grep -Fq '#include <linux/module.h>' "$KSU_DIR/infra/file_wrapper.c" || die "Linux 4.9 file_wrapper module API include missing"
if grep -q '__poll_t' "$KSU_DIR/infra/file_wrapper.c"; then
  die "Linux 4.9 file_wrapper still references __poll_t"
fi
if grep -q '\.f_op->iopoll\|\.ops\.iopoll' "$KSU_DIR/infra/file_wrapper.c"; then
  die "Linux 4.9 file_wrapper still references iopoll"
fi
if grep -q '\.f_op->mmap_supported_flags\|\.ops\.mmap_supported_flags' "$KSU_DIR/infra/file_wrapper.c"; then
  die "Linux 4.9 file_wrapper still references mmap_supported_flags"
fi
if grep -q '\.f_op->remap_file_range\|\.ops\.remap_file_range' "$KSU_DIR/infra/file_wrapper.c"; then
  die "Linux 4.9 file_wrapper still references remap_file_range"
fi
if grep -q '\.f_op->fadvise\|\.ops\.fadvise' "$KSU_DIR/infra/file_wrapper.c"; then
  die "Linux 4.9 file_wrapper still references fadvise"
fi
if grep -Fq 'selinux_inode(wrapper_inode)' "$KSU_DIR/infra/file_wrapper.c"; then
  die "Linux 4.9 file_wrapper still uses unavailable selinux_inode helper"
fi


test -f "$KSU_DIR/policy/app_profile.c" || die "SukiSU app_profile.c missing"
if grep -Fq 'current->seccomp.filter_count' "$KSU_DIR/policy/app_profile.c"; then
  die "Linux 4.9 app_profile still uses unavailable seccomp.filter_count"
fi
if grep -Fq 'seccomp_filter_release(fake)' "$KSU_DIR/policy/app_profile.c"; then
  die "Linux 4.9 app_profile still uses newer seccomp_filter_release"
fi
grep -Fq 'put_seccomp_filter(fake);' "$KSU_DIR/policy/app_profile.c" || die "Linux 4.9 app_profile filter release adapter missing"
test -f "$KSU_DIR/infra/seccomp_cache.c" || die "SukiSU seccomp_cache.c missing"
grep -Fq '#include <linux/refcount.h>' "$KSU_DIR/infra/seccomp_cache.c" || die "Linux 4.9 refcount header missing from seccomp_cache"
grep -Fq 'SECCOMP_ARCH_NATIVE_NR __NR_syscalls' "$KSU_DIR/infra/seccomp_cache.c" || die "Linux 4.9 native seccomp syscall-count shim missing"

test -f "$KSU_DIR/infra/su_mount_ns.c" || die "SukiSU su_mount_ns.c missing"
if grep -q '#include <uapi/linux/mount.h>' "$KSU_DIR/infra/su_mount_ns.c"; then
  die "Linux 4.9 su_mount_ns still includes unavailable uapi/linux/mount.h"
fi
grep -Fq 'extern long do_mount' "$KSU_DIR/infra/su_mount_ns.c" || die "Linux 4.9 do_mount adapter missing"
grep -Fq 'sys_setns(fd, flags)' "$KSU_DIR/infra/su_mount_ns.c" || die "Linux 4.9 sys_setns adapter missing"
grep -Fq 'sys_unshare(CLONE_NEWNS)' "$KSU_DIR/infra/su_mount_ns.c" || die "Linux 4.9 sys_unshare adapter missing"
grep -Fq 'set_fs(KERNEL_DS)' "$KSU_DIR/infra/su_mount_ns.c" || die "Linux 4.9 do_mount KERNEL_DS bridge missing"
if grep -q 'path_mount(' "$KSU_DIR/infra/su_mount_ns.c"; then
  die "Linux 4.9 su_mount_ns still references unavailable path_mount"
fi
if grep -q 'ksys_unshare(' "$KSU_DIR/infra/su_mount_ns.c"; then
  die "Linux 4.9 su_mount_ns still references unavailable ksys_unshare"
fi
if grep -q '__arm64_sys_setns\|__x64_sys_setns' "$KSU_DIR/infra/su_mount_ns.c"; then
  die "Linux 4.9 su_mount_ns still references newer __*_sys_setns entry points"
fi

test -f "$KSU_DIR/manager/pkg_observer.c" || die "SukiSU pkg_observer.c missing"
grep -Fq '.handle_event = ksu_handle_event' "$KSU_DIR/manager/pkg_observer.c" || die "Linux 4.9 fsnotify handle_event adapter missing"
grep -Fq 'fsnotify_init_mark(m, ksu_free_mark)' "$KSU_DIR/manager/pkg_observer.c" || die "Linux 4.9 fsnotify free_mark adapter missing"
grep -Fq 'fsnotify_add_mark(m, g, inode, NULL, 0)' "$KSU_DIR/manager/pkg_observer.c" || die "Linux 4.9 fsnotify add_mark adapter missing"
if grep -Fq 'fsnotify_add_inode_mark' "$KSU_DIR/manager/pkg_observer.c" || \
   grep -Fq 'fsnotify_init_mark(m, g)' "$KSU_DIR/manager/pkg_observer.c" || \
   grep -Fq '.handle_inode_event =' "$KSU_DIR/manager/pkg_observer.c"; then
  die "Linux 4.9 pkg_observer still references newer fsnotify API"
fi

grep -Fq 'ksu_kernel_read(struct file' "$KSU_DIR/kernel_compat.h" || die "Linux 4.9 kernel_read compatibility helper missing"
grep -Fq 'ksu_kernel_write(struct file' "$KSU_DIR/kernel_compat.h" || die "Linux 4.9 kernel_write compatibility helper missing"
grep -Fq '#define fallthrough do { } while (0)' "$KSU_DIR/kernel_compat.h" || die "Linux 4.9 fallthrough compatibility shim missing"
if grep -Fq 'return ksu_kernel_read(file' "$KSU_DIR/kernel_compat.h"; then
  die "ksu_kernel_read compatibility helper is recursive"
fi
if grep -Fq 'return ksu_kernel_write(file' "$KSU_DIR/kernel_compat.h"; then
  die "ksu_kernel_write compatibility helper is recursive"
fi
if grep -RqsE '(^|[^A-Za-z0-9_])kernel_read\\(' "$KSU_DIR" --exclude=kernel_compat.h; then
  die "raw kernel_read() call remains outside kernel_compat.h"
fi
if grep -RqsE '(^|[^A-Za-z0-9_])kernel_write\\(' "$KSU_DIR" --exclude=kernel_compat.h; then
  die "raw kernel_write() call remains outside kernel_compat.h"
fi

if grep -RqsF 'TWA_RESUME' "$KSU_DIR"; then
  die "Linux 4.9 SukiSU tree still references TWA_RESUME"
fi
grep -Fq 'task_work_add(tsk, cb, true)' "$KSU_DIR/policy/allowlist.c" || die "Linux 4.9 allowlist task_work adapter missing"
grep -Fq 'task_work_add(current, &tw->cb, true)' "$KSU_DIR/supercall/supercall.c" || die "Linux 4.9 supercall task_work adapter missing"

test -f "$KSU_DIR/infra/event_queue.h" || die "SukiSU event_queue.h missing"
test -f "$KSU_DIR/infra/event_queue.c" || die "SukiSU event_queue.c missing"
grep -Fq 'unsigned int ksu_event_queue_poll' "$KSU_DIR/infra/event_queue.h" || die "Linux 4.9 event_queue poll prototype not adapted"
grep -Fq 'unsigned int ksu_event_queue_poll' "$KSU_DIR/infra/event_queue.c" || die "Linux 4.9 event_queue poll implementation not adapted"
if grep -q '__poll_t' "$KSU_DIR/infra/event_queue.h" "$KSU_DIR/infra/event_queue.c"; then
  die "Linux 4.9 event_queue still references __poll_t"
fi
if grep -q 'EPOLLHUP\|EPOLLIN\|EPOLLRDNORM' "$KSU_DIR/infra/event_queue.c"; then
  die "Linux 4.9 event_queue still references EPOLL* wake masks"
fi


grep -Fq '#include <linux/uaccess.h>' "$KSU_DIR/hook/syscall_event_bridge.c" || die "Linux 4.9 uaccess include missing from syscall event bridge"
if grep -RqsE '#include <linux/sched/(signal|task|user|task_stack)\.h>' "$KSU_DIR"; then
  die "split linux/sched/*.h include remains in SukiSU tree"
fi
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
