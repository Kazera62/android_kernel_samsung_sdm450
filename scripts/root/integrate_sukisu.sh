#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rc=$?; echo "[sukisu] ERROR: line ${BASH_LINENO[0]}: command failed: ${BASH_COMMAND} (status=${rc})" >&2; exit ${rc}' ERR

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
[[ "$SUKISU_REF" =~ ^[0-9a-f]{40}$ ]] || die "SukiSU ref is not a full 40-character SHA: $SUKISU_REF"
[[ "$SUKISU_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "SukiSU version is not a release tag: $SUKISU_VERSION"

rm -rf "$KSU_DIR"

log "Cloning SukiSU-Ultra tag: $SUKISU_VERSION"
git clone --depth=1 --single-branch --branch "$SUKISU_VERSION" "$SUKISU_REPO" "$KSU_DIR" ||
  die "git clone failed for SukiSU tag $SUKISU_VERSION"

tag_ref="$(git -C "$KSU_DIR" rev-list -n1 "$SUKISU_VERSION" 2>/dev/null || true)"
test -n "$tag_ref" || die "release tag $SUKISU_VERSION is not present in cloned repository"
log "SukiSU tag commit: $tag_ref"
test "$tag_ref" = "$SUKISU_REF" ||
  die "tag/SHA mismatch: $SUKISU_VERSION points to $tag_ref, expected $SUKISU_REF"

log "Verifying exact SukiSU commit object"
git -C "$KSU_DIR" fetch --depth=1 origin "$SUKISU_REF" ||
  die "git fetch failed for SukiSU commit $SUKISU_REF"
git -C "$KSU_DIR" cat-file -e "$SUKISU_REF^{commit}" ||
  die "SukiSU commit object is unavailable: $SUKISU_REF"
git -C "$KSU_DIR" checkout --detach "$SUKISU_REF" ||
  die "git checkout failed for SukiSU commit $SUKISU_REF"

actual_ref="$(git -C "$KSU_DIR" rev-parse HEAD)"
log "SukiSU checkout: expected=$SUKISU_REF actual=$actual_ref"
test "$actual_ref" = "$SUKISU_REF" ||
  die "SukiSU revision mismatch: expected $SUKISU_REF, got $actual_ref"

require_file() {
  local file="$1"
  local label="$2"
  test -f "$file" || die "$label missing: $file"
  log "OK: $label: $file"
}

require_file "$KSU_DIR/kernel/Kconfig" "SukiSU kernel/Kconfig"
require_file "$KSU_DIR/kernel/Makefile" "SukiSU kernel/Makefile"
require_file "$KSU_DIR/kernel/Kbuild" "SukiSU kernel/Kbuild"
require_file "$KSU_DIR/kernel/core/init.c" "SukiSU kernel/core/init.c (v4.2.0 entry point)"
require_file "$KSU_DIR/kernel/hook/syscall_hook.h" "SukiSU syscall hook header"
require_file "$KSU_DIR/kernel/hook/syscall_hook_manager.c" "SukiSU syscall hook manager"
require_file "$KSU_DIR/kernel/hook/syscall_event_bridge.c" "SukiSU syscall event bridge"
require_file "$KSU_DIR/kernel/hook/arm64/syscall_hook.c" "SukiSU ARM64 syscall hook"

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

# Linux 4.9 has no split linux/sched/*.h headers used by v4.2.0.
# Normalize the scheduler includes to the monolithic linux/sched.h API.
replaced_sched_headers = 0
for path in kernel_dir.rglob("*"):
    if path.suffix not in {".c", ".h"} or not path.is_file():
        continue
    source = path.read_text()
    updated = source
    for sched_header in ("signal.h", "task.h", "user.h", "task_stack.h"):
        updated = updated.replace(f"#include <linux/sched/{sched_header}>", "#include <linux/sched.h>")
    if updated != source:
        path.write_text(updated)
        replaced_sched_headers += 1
print(f"[sukisu] Replaced split linux/sched/*.h includes in {replaced_sched_headers} SukiSU source files")

# Linux 4.9 lacks the newer nofault string-copy helper. Keep the
# SukiSU source calling a local compatibility shim.
compat_header = kernel_dir / "kernel_compat.h"
if compat_header.is_file():
    text = compat_header.read_text()
    helper = '''
#ifndef ksu_strncpy_from_user_nofault
static inline long ksu_strncpy_from_user_nofault(char *dst,
                                                 const char __user *src,
                                                 long count)
{
    return strncpy_from_user(dst, src, count);
}
#endif

'''
    if "ksu_strncpy_from_user_nofault" not in text:
        if "#include <linux/uaccess.h>" not in text:
            text = text.replace("#include <linux/fs.h>\n", "#include <linux/fs.h>\n#include <linux/uaccess.h>\n", 1)
        marker = "#include <linux/version.h>\n"
        if marker not in text:
            raise SystemExit("SukiSU kernel_compat.h include marker not found")
        text = text.replace(marker, marker + helper, 1)
        compat_header.write_text(text)
        print("[sukisu] Added Linux 4.9 strncpy_from_user compatibility shim")

    import re
    replaced = 0
    for path in kernel_dir.rglob("*"):
        if path.suffix not in {".c", ".h"} or not path.is_file():
            continue
        source = path.read_text()
        updated = re.sub(r"(?<!ksu_)strncpy_from_user_nofault", "ksu_strncpy_from_user_nofault", source)
        if updated != source:
            path.write_text(updated)
            replaced += 1
    print(f"[sukisu] Replaced raw strncpy_from_user_nofault with 4.9 shim in {replaced} SukiSU source files")

    # The compatibility helper is defined in kernel_compat.h; make sure every
    # C translation unit that uses it actually includes that header.
    include_added = 0
    for path in kernel_dir.rglob("*.c"):
        if not path.is_file():
            continue
        source = path.read_text()
        if "ksu_strncpy_from_user_nofault(" in source and '#include "kernel_compat.h"' not in source:
            path.write_text('#include "kernel_compat.h"\n' + source)
            include_added += 1
    print(f"[sukisu] Added kernel_compat.h include to {include_added} SukiSU C sources")

# Linux 4.9 does not have copy_{to,from}_user_nofault(). Use the
# regular user-copy helpers in the compatibility layer and its consumers.
compat_text = compat_header.read_text()
old_body = '''static long ksu_copy_from_user_retry(void *to, const void __user *from,
                                     unsigned long count)
{
    long ret = copy_from_user_nofault(to, from, count);
    if (likely(!ret))
        return ret;

    // we faulted! fallback to slow path
    return copy_from_user(to, from, count);
}
'''
new_body = '''static long ksu_copy_from_user_retry(void *to, const void __user *from,
                                     unsigned long count)
{
    return copy_from_user(to, from, count);
}
'''
if old_body in compat_text:
    compat_header.write_text(compat_text.replace(old_body, new_body, 1))
    print("[sukisu] Replaced copy_from_user_nofault fallback with Linux 4.9-compatible copy_from_user")
else:
    print("[sukisu] copy_from_user retry helper already transformed or source variant differs")

replaced_usercopy_nofault = 0
for path in kernel_dir.rglob("*"):
    if path.suffix not in {".c", ".h"} or not path.is_file():
        continue
    source = path.read_text()
    updated = source.replace("copy_from_user_nofault", "copy_from_user")
    updated = updated.replace("copy_to_user_nofault", "copy_to_user")
    if updated != source:
        path.write_text(updated)
        replaced_usercopy_nofault += 1
print(f"[sukisu] Replaced raw user-copy nofault APIs in {replaced_usercopy_nofault} SukiSU source files")

# Linux 4.9 does not have ksys_close(); it still exposes sys_close().
util_header = kernel_dir / "include" / "util.h"
if util_header.is_file():
    text = util_header.read_text()
    old = "#define ksu_close_fd ksys_close"
    new = '''#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)
#define ksu_close_fd sys_close
#else
#define ksu_close_fd ksys_close
#endif'''
    if old in text and new not in text:
        text = text.replace(old, new, 1)
        util_header.write_text(text)
        print("[sukisu] Added Linux 4.9 sys_close compatibility shim")

# Linux 4.9 ARM64 syscall-table entries are direct C syscall functions, not
# pt_regs-based wrappers. SukiSU v4.2.0 calls them through the newer ABI.
syscall_hook_header = kernel_dir / "hook" / "syscall_hook.h"
if syscall_hook_header.is_file():
    text = syscall_hook_header.read_text()
    helper = '''
#if defined(__aarch64__) && LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)
typedef asmlinkage long (*ksu_legacy_raw_syscall_t)(unsigned long, unsigned long,
                                                    unsigned long, unsigned long,
                                                    unsigned long, unsigned long);

static inline long ksu_call_original_syscall(int nr, const struct pt_regs *regs)
{
    unsigned long args[6] = { 0 };
    ksu_legacy_raw_syscall_t fn;

    syscall_get_arguments(current, (struct pt_regs *)regs, 0, 6, args);
    fn = (ksu_legacy_raw_syscall_t)ksu_syscall_table[nr];

    return fn(args[0], args[1], args[2], args[3], args[4], args[5]);
}
#else
static inline long ksu_call_original_syscall(int nr, struct pt_regs *regs)
{
    return ((long (*)(const struct pt_regs *))ksu_syscall_table[nr])(regs);
}
#endif

'''
    if "ksu_call_original_syscall" not in text:
        marker = "extern syscall_fn_t *ksu_syscall_table;\n"
        if marker not in text:
            raise SystemExit("SukiSU syscall_hook.h table declaration marker not found")
        text = text.replace(marker, marker + helper, 1)
        syscall_hook_header.write_text(text)
        print("[sukisu] Added Linux 4.9 ARM64 original-syscall ABI shim")

# Replace all v4.2.0 direct calls with the compatibility helper.
replaced_calls = 0
for rel in ("feature/sucompat.c", "hook/syscall_event_bridge.c"):
    path = kernel_dir / rel
    if not path.is_file():
        continue
    source = path.read_text()
    updated = source.replace("ksu_syscall_table[orig_nr](regs)", "ksu_call_original_syscall(orig_nr, regs)")
    updated = updated.replace("ksu_syscall_table[__NR_execveat](regs)", "ksu_call_original_syscall(__NR_execveat, regs)")
    if updated != source:
        path.write_text(updated)
        replaced_calls += 1
print(f"[sukisu] Rewired legacy ARM64 syscall-table calls in {replaced_calls} SukiSU source files")

# Linux 4.9 declares strncpy_from_user() from linux/uaccess.h. The upstream
# bridge used it without including that header because newer trees pull it in
# transitively.
# Linux 4.9 VFS has a smaller struct file_operations than modern kernels.
# SukiSU's fd wrapper must only reference fields that exist in 4.9.
file_wrapper = kernel_dir / "infra" / "file_wrapper.c"
if file_wrapper.is_file():
    fw = file_wrapper.read_text()

    if "#include <linux/module.h>" not in fw:
        fw = fw.replace("#include <linux/gfp.h>", "#include <linux/gfp.h>\n#include <linux/module.h>", 1)

    # __poll_t does not exist in Linux 4.9; file_operations::poll returns
    # unsigned int there.
    fw = fw.replace(
        "static __poll_t ksu_wrapper_poll(struct file *fp, struct poll_table_struct *pts)",
        "static unsigned int ksu_wrapper_poll(struct file *fp, struct poll_table_struct *pts)",
        1,
    )

    # iopoll was added long after 4.9 and must not be referenced at all.
    iopoll_start = fw.find("#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\nstatic int ksu_wrapper_iopoll")
    iopoll_end = fw.find("#endif\n\n#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)", iopoll_start)
    if iopoll_start >= 0 and iopoll_end >= 0:
        fw = fw[:iopoll_start] + fw[iopoll_end + len("#endif\n\n"): ]
    else:
        print("[sukisu] file_wrapper iopoll block already absent or source variant differs")

    # mmap_supported_flags is not part of Linux 4.9's file_operations.
    mmap_flags = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)
    p->ops.fop_flags = fp->f_op->fop_flags;
#else
    p->ops.mmap_supported_flags = fp->f_op->mmap_supported_flags;
#endif
'''
    if mmap_flags in fw:
        fw = fw.replace(mmap_flags, "", 1)

    # remap_file_range and fadvise are newer VFS callbacks and absent from 4.9.
    remap_start = fw.find("// no REMAP_FILE_DEDUP:")
    remap_end = fw.find("static void ksu_release_file_wrapper", remap_start)
    if remap_start >= 0 and remap_end >= 0:
        fw = fw[:remap_start] + fw[remap_end:]

    fw = fw.replace(
        "    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n"
        "    p->ops.fadvise = fp->f_op->fadvise ? ksu_wrapper_fadvise : NULL;\n",
        "",
        1,
    )

    file_wrapper.write_text(fw)
    print("[sukisu] Applied Linux 4.9 VFS file_wrapper compatibility")


bridge_path = kernel_dir / "hook" / "syscall_event_bridge.c"
if bridge_path.is_file():
    bridge_text = bridge_path.read_text()
    if "#include <linux/uaccess.h>" not in bridge_text:
        bridge_path.write_text("#include <linux/uaccess.h>\n" + bridge_text)
        print("[sukisu] Added linux/uaccess.h to syscall_event_bridge.c for 4.9")

# SukiSU v4.2.0's ARM64 patcher assumes a 4-level page-table API.
# Linux 4.9 ARM64 in this kernel uses pgd -> pud -> pmd -> pte.
patch_memory = kernel_dir / "hook" / "arm64" / "patch_memory.c"
if patch_memory.is_file():
    pm = patch_memory.read_text()
    fn_start = pm.find("unsigned long phys_from_virt(unsigned long addr, int *err)")
    fn_end = pm.find("// This function appears in 5.14:", fn_start)
    if fn_start < 0 or fn_end < 0:
        raise SystemExit("SukiSU patch_memory phys_from_virt boundaries not found")
    compat_fn = r"""#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
unsigned long phys_from_virt(unsigned long addr, int *err)
{
    struct mm_struct *mm = &init_mm;
    pgd_t *pgd;
    pud_t *pud;
    pmd_t *pmd;
    pte_t *pte;

    *err = 0;

    pgd = pgd_offset(mm, addr);
    if (pgd_none(*pgd) || pgd_bad(*pgd))
        goto fail;

    pud = pud_offset(pgd, addr);
    if (pud_none(*pud) || pud_bad(*pud))
        goto fail;

    if (pud_sect(*pud))
        return ((unsigned long)pud_pfn(*pud) << PAGE_SHIFT) + (addr & ~PUD_MASK);

    pmd = pmd_offset(pud, addr);
    if (pmd_none(*pmd) || pmd_bad(*pmd))
        goto fail;

    if (pmd_sect(*pmd))
        return ((unsigned long)pmd_pfn(*pmd) << PAGE_SHIFT) + (addr & ~PMD_MASK);

    pte = pte_offset_kernel(pmd, addr);
    if (!pte || !pte_present(*pte))
        goto fail;

    return ((unsigned long)pte_pfn(*pte) << PAGE_SHIFT) + (addr & ~PAGE_MASK);

fail:
    *err = -ENOENT;
    return 0;
}
#endif
""";
    # Keep upstream implementation but close the version guard immediately
    # before the next function marker.
    pm = pm[:fn_start] + compat_fn + pm[fn_end:]
    pm = pm.replace("    ret = (int)copy_to_kernel_nofault(map, src, len);",
                    "    memcpy(map, src, len);\n    ret = 0;", 1)
    cache_start = pm.find("#if KSU_NEW_DCACHE_FLUSH")
    cache_end = pm.find("struct patch_text_info", cache_start)
    if cache_start < 0 or cache_end < 0:
        raise SystemExit("SukiSU patch_memory cache macro block not found")
    cache_block = r"""#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
#define ksu_flush_dcache(start, sz) __flush_dcache_area((void *)start, sz)
#define ksu_flush_icache(start, end) flush_icache_range(start, end)
#else
#if KSU_NEW_DCACHE_FLUSH
#define ksu_flush_dcache(start, sz)                                                                                        ({                                                                                                                         unsigned long __start = (start);                                                                                       unsigned long __end = __start + (sz);                                                                                  dcache_clean_inval_poc(__start, __end);                                                                            })
#define ksu_flush_icache(start, end) caches_clean_inval_pou
#else
#define ksu_flush_dcache(start, sz) __flush_dcache_area((void *)start, sz)
#define ksu_flush_icache(start, end) __flush_icache_range
#endif
#endif

"""
    pm = pm[:cache_start] + cache_block + pm[cache_end:]
    patch_memory.write_text(pm)
    print("[sukisu] Applied Linux 4.9 ARM64 3-level patch_memory compatibility");



# Linux 4.9 compatibility checks for the transformed tree.
import re
raw_nofault = []
for path in kernel_dir.rglob("*"):
    if path.suffix not in {".c", ".h"} or not path.is_file():
        continue
    if re.search(r"(?<!ksu_)strncpy_from_user_nofault", path.read_text()):
        raw_nofault.append(str(path))
if raw_nofault:
    raise SystemExit(f"SukiSU compatibility transform left raw strncpy_from_user_nofault: {raw_nofault}")

if "ksu_call_original_syscall" not in syscall_hook_header.read_text():
    raise SystemExit("SukiSU ARM64 syscall compatibility helper was not installed")

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
    if "#include <linux/version.h>" not in text:
        text = text.replace("#include <asm/syscall.h>\n", "#include <asm/syscall.h>\n#include <linux/version.h>\n", 1)
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

# Linux 4.9's security_hook_heads are a struct of list_head members.
# SukiSU v4.2.0's generic pre-6.12 code targets the newer hlist-based layout.
# Adapt only the pre-6.12 LSM walker/unhook path to the actual 4.9 API.
python3 - "$KSU_DIR/kernel/hook/lsm_hook.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old_start = """#else
    heads_addr = find_kernel_symbol_exact("security_hook_heads");
    if (!heads_addr) {
        pr_err("lsm_hook: failed to resolve security_hook_heads\\n");
        ret = -ENOENT;
        goto out_unlock;
    }
    unsigned long heads_size = sizeof(struct security_hook_heads);
"""
start = text.find(old_start)
if start < 0:
    raise SystemExit("4.9 LSM hook block start not found")

end_marker = """#endif
    goto out_unlock;
"""
end = text.find(end_marker, start)
if end < 0:
    raise SystemExit("4.9 LSM hook block end not found")

new_block = """#else
    struct list_head *head_49;

    heads_addr = find_kernel_symbol_exact("security_hook_heads");
    if (!heads_addr) {
        pr_err("lsm_hook: failed to resolve security_hook_heads\\n");
        ret = -ENOENT;
        goto out_unlock;
    }

    head_49 = (struct list_head *)(heads_addr + hook->head_offset);
    pr_info("4.9 LSM head_addr=0x%lx head_offset=0x%lx hook_offset=0x%lx\\n",
            (unsigned long)head_49, hook->head_offset, hook->hook_offset);

    /* Primary head: find the real SELinux/security hook entry. */
    list_for_each_entry (entry, head_49, list) {
        void **slot = (void **)((char *)entry + hook->hook_offset);
        void *current_origin = READ_ONCE(*slot);
        int j;

        for (j = 0; j < ksu_lsm_hook_count; j++) {
            if (ksu_lsm_hook_entries[j].hook->replacement == current_origin) {
                current_origin = ksu_lsm_hook_entries[j].hook->original;
                break;
            }
        }

        if (current_origin == hook->replacement) {
            ret = -EALREADY;
            goto out_unlock;
        }

        if (current_origin == target) {
            selected_entry = entry;
            selected_slot = slot;
            selected_origin = current_origin;
            pr_info("lsm_hook: found %s on 4.9 head %s origin %px\\n",
                    hook->target_name ?: "unknown",
                    hook->head_name ?: "unknown",
                    current_origin);
            break;
        }
    }

    /*
     * Some hook initializers use offset to map a target present on one
     * security head to the real head where the desired slot lives.
     * In Linux 4.9 those heads are list_head members, so pointer arithmetic
     * is done in units of struct list_head.
     */
    if (!selected_entry && hook->offset) {
        struct list_head *real_head = head_49 + hook->offset;

        list_for_each_entry (entry, real_head, list) {
            void **slot = (void **)((char *)entry + hook->hook_offset);
            void *current_origin = READ_ONCE(*slot);

            if (current_origin == hook->replacement) {
                ret = -EALREADY;
                goto out_unlock;
            }
        }

        if (!list_empty(real_head)) {
            selected_entry = list_first_entry(real_head, struct security_hook_list, list);
            selected_slot = (void **)((char *)selected_entry + hook->hook_offset);
            selected_origin = READ_ONCE(*selected_slot);
        } else {
            /*
             * The real head is empty. Reuse the embedded hook list entry.
             * KSU_LSM_HOOK_INIT already initialized hook.list.hook.member.
             */
            INIT_LIST_HEAD(&hook->list.list);
            hook->list.head = real_head;
            list_add_rcu(&hook->list.list, real_head);
            selected_entry = &hook->list;
            selected_slot = NULL;
            selected_origin = NULL;
        }
    }

    if (!selected_entry) {
        pr_err("lsm_hook: target %s not found in 4.9 head %s\\n",
               target_name, hook->head_name ?: "unknown");
        ret = -ENOENT;
        goto out_unlock;
    }

    ret = ksu_lsm_hook_track(hook);
    if (ret) {
        pr_err("lsm_hook: too many hooks to track: %d\\n", ret);
        if (selected_entry == &hook->list)
            list_del_rcu(&hook->list.list);
        goto out_unlock;
    }

    if (selected_entry != &hook->list) {
        ret = ksu_lsm_hook_patch_slot(selected_slot, hook->replacement);
        if (ret) {
            pr_err("lsm_hook: failed to patch %s on Linux 4.9\\n",
                   hook->head_name ?: "unknown");
            ret = -EFAULT;
            goto out_untrack;
        }
    }

    hook->entry = selected_entry;
    hook->original = selected_origin;
    pr_info("lsm_hook: patched %s hook slot %px from %px to %px\\n",
            hook->head_name ?: "unknown",
            selected_slot,
            selected_origin,
            hook->replacement);
#endif
"""
text = text[:start] + new_block + text[end + len("#endif\n"):]

old_unhook = """#else
    if (hook->entry == &hook->list) {
        slot = (void **)&hook->list.head->first;
        pr_info("unhook patch head->first\\n");
    } else {
        slot = (void **)((char *)hook->entry + hook->hook_offset);
        pr_info("unhook patch slot\\n");
    }
#endif
"""
new_unhook = """#else
    if (hook->entry == &hook->list) {
        list_del_rcu(&hook->list.list);
        synchronize_rcu();
        pr_info("lsm_hook: removed injected 4.9 LSM hook entry\\n");
        ksu_lsm_hook_untrack(hook);
        hook->entry = NULL;
        mutex_unlock(&ksu_lsm_hook_lock);
        return;
    }

    slot = (void **)((char *)hook->entry + hook->hook_offset);
    pr_info("lsm_hook: unhook 4.9 function slot\\n");
#endif
"""
if old_unhook not in text:
    raise SystemExit("4.9 LSM unhook block not found")
text = text.replace(old_unhook, new_unhook, 1)

path.write_text(text)
print("[sukisu] Applied explicit Linux 4.9 list_head LSM hook adapter")
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
test "$(git -C "$KSU_DIR" rev-parse HEAD)" = "$SUKISU_REF" || die "final SukiSU SHA mismatch"

grep -Fq 'config KSU' "$KSU_DIR/kernel/Kconfig" || die "KSU config entry missing"
grep -Fq 'depends on KPROBES && EXT4_FS' "$KSU_DIR/kernel/Kconfig" || die "v4.2.0 KSU dependency changed: expected KPROBES + EXT4_FS"
grep -Fq 'config KSU_MANUAL_SU' "$KSU_DIR/kernel/Kconfig" || die "KSU_MANUAL_SU config entry missing"
grep -Fq 'obj-$(CONFIG_KSU) += kernelsu.o' "$KSU_DIR/kernel/Kbuild" || die "SukiSU kernel/Kbuild missing built-in kernelsu target"
grep -Fq 'ksu_syscall_hook_init();' "$KSU_DIR/kernel/core/init.c" || die "SukiSU kernel init does not initialize syscall hook backend"
grep -Fq 'ksu_syscall_hook_manager_init();' "$KSU_DIR/kernel/core/init.c" || die "SukiSU kernel init does not initialize syscall hook manager"
grep -Fq 'register_trace_prio_sys_enter' "$KSU_DIR/kernel/hook/syscall_hook_manager.c" || die "SukiSU tracepoint syscall redirect backend not present"
grep -Fq 'ksu_dispatcher_nr' "$KSU_DIR/kernel/hook/arm64/syscall_hook.c" || die "SukiSU ARM64 dispatcher backend not present"

printf '[sukisu] STATUS release=%s commit=%s kernel=%s type=Non-GKI hook=Tracepoint-Syscall-Redirect\n' \
  "$SUKISU_VERSION" "$SUKISU_REF" "$(cd "$KSU_DIR" && git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD)"

log "SukiSU-Ultra source integrated successfully"
