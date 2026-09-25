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
test -f "$KSU_DIR/kernel/core/init.c" || die "SukiSU kernel/core/init.c missing"
test -f "$KSU_DIR/kernel/Kbuild" || die "SukiSU kernel/Kbuild missing"

# SukiSU v4.2.0 includes several headers introduced after Linux 4.9.
# Keep the upstream source pinned, but apply only mechanical 4.9 compatibility
# transforms in this integration layer.

python3 - "$KSU_DIR/kernel/hook/syscall_hook.h" "$KSU_DIR/kernel/core/init.c" "$KSU_DIR/kernel" <<'PY'
from pathlib import Path
import sys

hook = Path(sys.argv[1])
init = Path(sys.argv[2])
kernel_dir = Path(sys.argv[3])

# Linux 4.9 has linux/compiler.h but not linux/compiler_types.h or
# linux/pgtable.h. Remove direct dependencies on newer split headers instead
# of maintaining a brittle list of source files.
removed_compiler_types = 0
removed_pgtable = 0
removed_task_stack = 0
untagged_rewrites = 0
for path in kernel_dir.rglob("*"):
    if path.suffix not in {".c", ".h"} or not path.is_file():
        continue
    text = path.read_text()
    new_text = text.replace("#include <linux/compiler_types.h>\n", "")
    new_text = new_text.replace("#include <linux/pgtable.h>\n", "")
    new_text = new_text.replace("#include <linux/sched/task_stack.h>\n", "")
    if new_text != text:
        if "#include <linux/compiler_types.h>\n" in text:
            removed_compiler_types += 1
        if "#include <linux/pgtable.h>\n" in text:
            removed_pgtable += 1
        if "#include <linux/sched/task_stack.h>\n" in text:
            removed_task_stack += 1
        path.write_text(new_text)
        text = new_text

    if "untagged_addr(" in text:
        new_text = new_text.replace("untagged_addr((unsigned long)*filename_user)", "(unsigned long)*filename_user")
        if new_text != text:
            path.write_text(new_text)
            untagged_rewrites += 1

print(f"[sukisu] Removed linux/compiler_types.h from {removed_compiler_types} SukiSU source files")
print(f"[sukisu] Removed linux/pgtable.h from {removed_pgtable} SukiSU source files")
print(f"[sukisu] Removed linux/sched/task_stack.h from {removed_task_stack} SukiSU source files")
print(f"[sukisu] Rewrote untagged_addr() for Linux 4.9 in {untagged_rewrites} SukiSU source files")

# Linux 4.9 arm64 exposes current_stack_pointer from asm/stack_pointer.h,
# while newer SukiSU uses current_user_stack_pointer() from task_stack.h.
sucompat = kernel_dir / "feature" / "sucompat.c"
if sucompat.is_file():
    text = sucompat.read_text()
    if "current_user_stack_pointer()" in text:
        if '#include <asm/stack_pointer.h>' not in text:
            text = '#include <asm/stack_pointer.h>\n' + text
        compat = '''
#ifndef current_user_stack_pointer
static inline unsigned long current_user_stack_pointer(void)
{
    return current_stack_pointer;
}
#endif

'''
        if compat.strip() not in text:
            insert_at = text.find('#include "arch.h"')
            if insert_at < 0:
                raise SystemExit("SukiSU sucompat.c include marker not found")
            text = text[:insert_at] + compat + text[insert_at:]
            sucompat.write_text(text)
            print(f"[sukisu] Added Linux 4.9 current_user_stack_pointer shim: {sucompat}")


# SukiSU v4.2.0 uses syscall_fn_t on ARM64, but the 4.9 arm64 headers expose
# sys_call_table as void * and do not provide the newer sys_call_ptr_t alias.
# Use a same-size generic function-pointer type for the table patcher.
text = hook.read_text()
old = '''#if defined(__x86_64__)
typedef sys_call_ptr_t syscall_fn_t;
#endif
'''
new = '''#if defined(__x86_64__)
typedef sys_call_ptr_t syscall_fn_t;
#elif defined(__aarch64__)
typedef void (*syscall_fn_t)(void);
#endif
'''
if new not in text:
    if old not in text:
        raise SystemExit("SukiSU syscall_fn_t definition pattern not found")
    text = text.replace(old, new, 1)
    hook.write_text(text)

text = init.read_text()
old = 'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);'
if old in text and '#ifdef MODULE_IMPORT_NS' not in text:
    text = text.replace(
        old,
        '#ifdef MODULE_IMPORT_NS\n' + old + '\n#endif',
        1,
    )
    init.write_text(text)

print("[sukisu] Applied Linux 4.9 ARM64 compatibility fixes")
PY

if grep -Rqs '#include <linux/sched/task_stack.h>' "$KSU_DIR"; then
  die "linux/sched/task_stack.h survived the Linux 4.9 compatibility transform"
fi

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

if ! grep -Fq 'config KSU' "$KSU_DIR/kernel/Kconfig"; then
  die "SukiSU KSU config entry missing"
fi
if ! grep -Fq 'config KSU_MANUAL_SU' "$KSU_DIR/kernel/Kconfig"; then
  die "SukiSU KSU_MANUAL_SU config entry missing"
fi

printf '[sukisu] STATUS release=%s commit=%s kernel=%s\n' \
  "$SUKISU_VERSION" "$SUKISU_REF" "$(cd "$KSU_DIR" && git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD)"

log "SukiSU-Ultra source integrated successfully"
