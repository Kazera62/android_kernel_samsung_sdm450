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
    for inc in ("#include <linux/slab.h>\n", "#include <linux/vmalloc.h>\n", "#include <asm/pgtable.h>\n"):
        if inc not in text:
            text = text.replace("#include <linux/fs.h>\n", "#include <linux/fs.h>\n" + inc, 1)
    compat_header.write_text(text)
    if "#include <linux/slab.h>" not in text:
        text = text.replace("#include <linux/fs.h>\n", "#include <linux/fs.h>\n#include <linux/slab.h>\n#include <linux/vmalloc.h>\n", 1)
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
# Linux 4.9 VFS compatibility for SukiSU's fd wrapper.
file_wrapper = kernel_dir / "infra" / "file_wrapper.c"
if file_wrapper.is_file():
    import re

    fw = file_wrapper.read_text()

    if "#include <linux/module.h>" not in fw:
        fw = fw.replace(
            "#include <linux/gfp.h>",
            "#include <linux/gfp.h>\n#include <linux/module.h>",
            1,
        )

    fw = fw.replace("struct inode_security_struct *wrapper_sec = selinux_inode(wrapper_inode);", "struct inode_security_struct *wrapper_sec = (struct inode_security_struct *)wrapper_inode->i_security;", 1)

    # Linux 4.9 uses unsigned int for file_operations::poll.
    fw = fw.replace(
        "static __poll_t ksu_wrapper_poll(struct file *fp, struct poll_table_struct *pts)",
        "static unsigned int ksu_wrapper_poll(struct file *fp, struct poll_table_struct *pts)",
        1,
    )

    # Linux 4.9 has no iopoll callback.
    fw = re.sub(
        r"\n#if LINUX_VERSION_CODE >= KERNEL_VERSION\(6, 1, 0\)\n"
        r"static int ksu_wrapper_iopoll.*?\n#endif\n",
        "\n",
        fw,
        count=1,
        flags=re.S,
    )
    fw = re.sub(
        r"^\s*p->ops\.iopoll\s*=.*\n",
        "",
        fw,
        count=1,
        flags=re.M,
    )

    # Linux 4.9 has neither fop_flags nor mmap_supported_flags.
    mmap_start = fw.find("#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)", fw.find("p->ops.mmap"))
    if mmap_start >= 0:
        mmap_end = fw.find("#endif", mmap_start)
        if mmap_end < 0:
            raise SystemExit("file_wrapper mmap flag compatibility block is unterminated")
        fw = fw[:mmap_start] + fw[mmap_end + len("#endif"):]
    else:
        print("[sukisu] file_wrapper mmap flag block already absent")

    # Linux 4.9 predates remap_file_range() and fadvise() file callbacks.
    remap_start = fw.find("// no REMAP_FILE_DEDUP:")
    release_marker = fw.find("static void ksu_release_file_wrapper", remap_start)
    if remap_start >= 0 and release_marker >= 0:
        fw = fw[:remap_start] + fw[release_marker:]
    else:
        print("[sukisu] file_wrapper remap/fadvise section already absent")

    # The assignments are redundant protection for source variants.
    fw = re.sub(r"^\s*p->ops\.remap_file_range\s*=.*\n", "", fw, count=1, flags=re.M)
    fw = re.sub(r"^\s*p->ops\.fadvise\s*=.*\n", "", fw, count=1, flags=re.M)

    # Upstream's pre-5.16 helper calls security_inode_init_security_anon(), which
    # does not exist in this 4.9 tree. Keep the unique-anon-inode design, but    # initialize the inode with the APIs actually present in this kernel.
    compat_start = fw.find("#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0)")
    compat_end = fw.find("#endif\n\nint ksu_install_file_wrapper", compat_start)
    if compat_start < 0 or compat_end < 0:
        raise SystemExit("file_wrapper anon_inode compatibility block boundaries not found")

    compat_block = r"""#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 16, 0)
static struct vfsmount *anon_inode_mnt __read_mostly;

static struct inode *ksu_anon_inode_make_inode(void)
{
    if (unlikely(!anon_inode_mnt))
        return ERR_PTR(-ENODEV);
    return alloc_anon_inode(anon_inode_mnt->mnt_sb);
}

static struct file *ksu_anon_inode_create_getfile_compat(
        const char *name, const struct file_operations *fops,
        void *priv, int flags, const struct inode *context_inode)
{
    struct inode *inode;
    struct dentry *dentry;
    struct path path;
    struct file *file;
    struct qstr qname = QSTR_INIT(name, strlen(name));

    (void)context_inode;

    if (fops->owner && !try_module_get(fops->owner))
        return ERR_PTR(-ENOENT);

    inode = ksu_anon_inode_make_inode();
    if (IS_ERR(inode)) {
        file = ERR_CAST(inode);
        goto err_module;
    }

    dentry = d_alloc_pseudo(anon_inode_mnt->mnt_sb, &qname);
    if (!dentry) {
        file = ERR_PTR(-ENOMEM);
        goto err_inode;
    }

    path.dentry = dentry;
    path.mnt = mntget(anon_inode_mnt);
    d_instantiate(path.dentry, inode);

    file = alloc_file(&path, flags & (O_ACCMODE | O_NONBLOCK), fops);
    if (IS_ERR(file))
        goto err_path;

    file->f_mapping = inode->i_mapping;
    file->private_data = priv;
    return file;

err_path:
    path_put(&path);
    return file;

err_inode:
    iput(inode);
err_module:
    module_put(fops->owner);
    return file;
}
#else
#define ksu_anon_inode_create_getfile_compat anon_inode_getfile_secure
#endif
"""
    fw = fw[:compat_start] + compat_block + fw[compat_end + len("#endif\n"):]

    forbidden = (
        "ksu_wrapper_iopoll",
        ".iopoll",
        "__poll_t",
        ".mmap_supported_flags",
        ".fop_flags",
        ".remap_file_range",
        ".fadvise",
        "REMAP_FILE_DEDUP",
    )
    leaked = [token for token in forbidden if token in fw]
    if leaked:
        raise SystemExit(
            "Linux 4.9 file_wrapper unsupported API remains: " + ", ".join(leaked)
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



# Linux 4.9 poll compatibility for SukiSU's event queue.
event_queue_h = kernel_dir / "infra" / "event_queue.h"
event_queue_c = kernel_dir / "infra" / "event_queue.c"
if event_queue_h.is_file() or event_queue_c.is_file():
    for path in (event_queue_h, event_queue_c):
        if not path.is_file():
            continue
        source = path.read_text()
        updated = source
        # Linux 4.9 has no __poll_t; file_operations::poll and the poll
        # wakeup masks use the classic integer poll ABI.
        updated = updated.replace("__poll_t ksu_event_queue_poll", "unsigned int ksu_event_queue_poll")
        updated = updated.replace("    __poll_t mask = 0;", "    unsigned int mask = 0;")
        updated = updated.replace("EPOLLHUP | POLLHUP", "POLLHUP")
        updated = updated.replace("EPOLLIN | EPOLLRDNORM", "POLLIN | POLLRDNORM")
        if updated != source:
            path.write_text(updated)
    print("[sukisu] Applied Linux 4.9 poll/event_queue compatibility")

# Linux 4.9 seccomp-cache compatibility.
# v4.2.0 names the native syscall bitmap with a newer helper macro and relies
# on refcount_t being visible transitively. Linux 4.9 provides both primitives
# directly, so expose them explicitly without changing cache behavior.
seccomp_cache = kernel_dir / "infra" / "seccomp_cache.c"
if seccomp_cache.is_file():
    source = seccomp_cache.read_text()
    updated = source
    if "#include <linux/refcount.h>" not in updated:
        updated = updated.replace("#include <linux/version.h>", "#include <linux/version.h>\n#include <linux/refcount.h>\n", 1)
    native_compat = """#ifndef SECCOMP_ARCH_NATIVE_NR
#define SECCOMP_ARCH_NATIVE_NR __NR_syscalls
#endif
"""
    if "SECCOMP_ARCH_NATIVE_NR __NR_syscalls" not in updated:
        include_anchor = '#include "infra/seccomp_cache.h"\n'
        if include_anchor not in updated:
            raise SystemExit("seccomp_cache.c include anchor not found")
        updated = updated.replace(include_anchor, include_anchor + "\n" + native_compat, 1)
    if updated != source:
        seccomp_cache.write_text(updated)
    print("[sukisu] Applied Linux 4.9 seccomp_cache compatibility")

# Linux 4.9 mount-namespace compatibility.
# v4.2.0 uses internal mount/unshare syscall entry points introduced later.
# Linux 4.9 exposes sys_setns/sys_unshare and do_mount instead.
su_mount_ns = kernel_dir / "infra" / "su_mount_ns.c"
if su_mount_ns.is_file():
    source = su_mount_ns.read_text()
    updated = source
    updated = updated.replace("#include <uapi/linux/mount.h>\n", "")
    updated = updated.replace("extern int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags,\n                      void *data_page);", "extern long do_mount(const char *dev_name, const char __user *dir_name, const char *type_page, unsigned long flags, void *data_page);\nextern long sys_setns(int fd, int nstype);\nextern long sys_unshare(unsigned long unshare_flags);")
    old_setns = '''extern long __arm64_sys_setns(const struct pt_regs *regs);
#elif defined(__x86_64__)
extern long __x64_sys_setns(const struct pt_regs *regs);
#endif'''
    new_setns = '''extern long sys_setns(int fd, int nstype);
#endif'''
    if old_setns in updated:
        updated = updated.replace(old_setns, new_setns, 1)
    start = updated.find("static long ksu_sys_setns(int fd, int flags)\n{")
    end = updated.find("\n}\n\n// global mode", start)
    if start < 0 or end < 0:
        raise SystemExit("SukiSU su_mount_ns ksu_sys_setns boundaries not found")
    compat_setns = '''static long ksu_sys_setns(int fd, int flags)
{
    return sys_setns(fd, flags);
}'''

    updated = updated[:start] + compat_setns + updated[end+2:]
    updated = updated.replace("int pm_ret = path_mount(NULL, &root_path, NULL, MS_PRIVATE | MS_REC, NULL);", "mm_segment_t old_fs = get_fs();\n    set_fs(KERNEL_DS);\n    int pm_ret = do_mount(NULL, (const char __user *)\"/\", NULL, MS_PRIVATE | MS_REC, NULL);\n    set_fs(old_fs);")
    updated = updated.replace("long ret = ksys_unshare(CLONE_NEWNS);", "long ret = sys_unshare(CLONE_NEWNS);")
    if updated != source:
        su_mount_ns.write_text(updated)
    print("[sukisu] Applied Linux 4.9 mount namespace compatibility")

# Linux 4.9 fsnotify compatibility for SukiSU package observer.
# The pinned v4.2.0 source uses handle_inode_event(), while Linux 4.9
# fsnotify_ops requires handle_event() with the full callback signature.
pkg_observer = kernel_dir / "manager" / "pkg_observer.c"
if pkg_observer.is_file():
    source = pkg_observer.read_text()
    updated = source

    # Find the upstream handler by signature, then locate its closing brace
    # structurally. This avoids depending on exact whitespace or the next
    # declaration's spelling.
    start = updated.find("static int ksu_handle_inode_event(")
    if start < 0:
        raise SystemExit("SukiSU pkg_observer upstream handler signature not found")

    body_start = updated.find("{", start)
    if body_start < 0:
        raise SystemExit("SukiSU pkg_observer handler opening brace not found")

    depth = 0
    body_end = -1
    in_string = False
    escape = False
    for pos in range(body_start, len(updated)):
        ch = updated[pos]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                body_end = pos + 1
                break
    if body_end < 0:
        raise SystemExit("SukiSU pkg_observer handler closing brace not found")

    handler = """static int ksu_handle_event(struct fsnotify_group *group,
                                  struct inode *inode,
                                  struct fsnotify_mark *inode_mark,
                                  struct fsnotify_mark *vfsmount_mark,
                                  u32 mask, void *data, int data_type,
                                  const unsigned char *file_name, u32 cookie)
{
    (void)group;
    (void)inode;
    (void)inode_mark;
    (void)vfsmount_mark;
    (void)data;
    (void)data_type;
    (void)cookie;

    if (!file_name)
        return 0;
    if (mask & FS_ISDIR)
        return 0;
    if (strlen((const char *)file_name) == 13 &&
        !memcmp(file_name, "packages.list", 13)) {
        pr_info("packages.list detected: %d\\n", mask);
        track_throne(false);
    }
    return 0;
}"""
    updated = updated[:start] + handler + updated[body_end:]

    old_ops = """static const struct fsnotify_ops ksu_ops = {
    .handle_inode_event = ksu_handle_inode_event,
};"""
    new_ops = """static const struct fsnotify_ops ksu_ops = {
    .handle_event = ksu_handle_event,
};"""
    if old_ops not in updated:
        if ".handle_event = ksu_handle_event" not in updated:
            raise SystemExit("SukiSU pkg_observer fsnotify_ops marker not found")
    else:
        updated = updated.replace(old_ops, new_ops, 1)

    # Linux 4.9 requires an explicit mark free callback and uses the 5-arg
    # fsnotify_add_mark() API.
    old_mark = """static int add_mark_on_inode(struct inode *inode, u32 mask, struct fsnotify_mark **out)
{
    struct fsnotify_mark *m;

    m = kzalloc(sizeof(*m), GFP_KERNEL);
    if (!m)
        return -ENOMEM;

    fsnotify_init_mark(m, g);
    m->mask = mask;

    if (fsnotify_add_inode_mark(m, inode, 0)) {
        fsnotify_put_mark(m);
        return -EINVAL;
    }
    *out = m;
    return 0;
}"""
    new_mark = """static void ksu_free_mark(struct fsnotify_mark *mark)
{
    kfree(mark);
}

static int add_mark_on_inode(struct inode *inode, u32 mask, struct fsnotify_mark **out)
{
    struct fsnotify_mark *m;
    int ret;

    m = kzalloc(sizeof(*m), GFP_KERNEL);
    if (!m)
        return -ENOMEM;

    fsnotify_init_mark(m, ksu_free_mark);
    m->mask = mask;

    ret = fsnotify_add_mark(m, g, inode, NULL, 0);
    if (ret) {
        fsnotify_destroy_mark(m, g);
        fsnotify_put_mark(m);
        return ret;
    }
    *out = m;
    return 0;
}"""
    if old_mark in updated:
        updated = updated.replace(old_mark, new_mark, 1)
    elif "fsnotify_init_mark(m, ksu_free_mark)" not in updated:
        raise SystemExit("SukiSU pkg_observer mark helper pattern not found")

    # Linux 4.9 alloc_group() takes only the ops pointer.
    old_alloc = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 0, 0)
    g = fsnotify_alloc_group(&ksu_ops, 0);
#else
    g = fsnotify_alloc_group(&ksu_ops);
#endif"""
    new_alloc = "g = fsnotify_alloc_group(&ksu_ops);"
    if old_alloc in updated:
        updated = updated.replace(old_alloc, new_alloc, 1)

    if updated != source:
        pkg_observer.write_text(updated)
    print("[sukisu] Applied Linux 4.9 fsnotify package-observer compatibility")
# Linux 4.9 VFS I/O compatibility.
# v4.2.0 uses the post-4.14 kernel_read()/kernel_write() pointer-offset ABI.
# Linux 4.9 keeps the older kernel_read() value-offset ABI; __kernel_write()
# already provides the pointer-offset form, so preserve SukiSU's semantics.
compat_header = kernel_dir / "kernel_compat.h"
if compat_header.is_file():
    text = compat_header.read_text()
    if "#include <linux/slab.h>" not in text:
        text = text.replace(
            "#include <linux/fs.h>\n",
            "#include <linux/fs.h>\n#include <linux/slab.h>\n#include <linux/vmalloc.h>\n",
            1,
        )
        compat_header.write_text(text)
    io_helpers = r'''
#ifndef fallthrough
#define fallthrough do { } while (0)
#endif

#ifndef ksu_kernel_read
static inline ssize_t ksu_kernel_read(struct file *file, void *buf, size_t count, loff_t *pos)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 14, 0)
    return kernel_read(file, *pos, buf, count);
#else
    return kernel_read(file, buf, count, pos);
#endif
}
#endif

#ifndef ksu_kernel_write
static inline ssize_t ksu_kernel_write(struct file *file, const void *buf, size_t count, loff_t *pos)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 14, 0)
    return __kernel_write(file, buf, count, pos);
#else
    return kernel_write(file, buf, count, pos);
#endif
}
#endif

'''
    if "ksu_kernel_read(struct file" not in text:
        anchor = "#include <linux/version.h>\n"
        if anchor not in text:
            raise SystemExit("kernel_compat.h version include anchor missing")
        text = text.replace(anchor, anchor + io_helpers, 1)
        compat_header.write_text(text)
        print("[sukisu] Added Linux 4.9 kernel_read/kernel_write compatibility helpers")

import re
replaced_io = 0
for path in kernel_dir.rglob("*"):
    if path.suffix not in {".c", ".h"} or not path.is_file():
        continue
    if path == compat_header:
        continue
    source = path.read_text()
    updated = re.sub(r"(?<![A-Za-z0-9_])kernel_read\(", "ksu_kernel_read(", source)
    updated = re.sub(r"(?<![A-Za-z0-9_])kernel_write\(", "ksu_kernel_write(", updated)
    updated = re.sub(r"(?<![A-Za-z0-9_])kvmalloc\(", "ksu_kvmalloc(", updated)
    updated = re.sub(r"(?<![A-Za-z0-9_])kvfree\(", "ksu_kvfree(", updated)
    if updated != source:
        path.write_text(updated)
        replaced_io += 1
print(f"[sukisu] Rewired kernel_read/kernel_write calls through 4.9 helpers in {replaced_io} SukiSU source files")

# Rebuild the Linux 4.9 compatibility helper block after all global rewrites.
# This removes any previous helper block and writes exactly one canonical copy,
# making repeated CI/local execution idempotent.
compat_text = compat_header.read_text()
io_block = '''
#ifndef fallthrough
#define fallthrough do { } while (0)
#endif

#ifndef ksu_kvmalloc
static inline void *ksu_kvmalloc(size_t size, gfp_t flags)
{
    return __vmalloc(size, flags, PAGE_KERNEL);
}
#endif

#ifndef ksu_kvfree
static inline void ksu_kvfree(const void *addr)
{
    unsigned long v;

    if (!addr)
        return;

    v = (unsigned long)addr;
#ifdef CONFIG_MMU
    if (v >= VMALLOC_START && v < VMALLOC_END) {
        vfree(addr);
        return;
    }
#endif
    kfree(addr);
}
#endif

#ifndef ksu_kernel_read
static inline ssize_t ksu_kernel_read(struct file *file, void *buf, size_t count, loff_t *pos)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 14, 0)
    return kernel_read(file, *pos, buf, count);
#else
    return kernel_read(file, buf, count, pos);
#endif
}
#endif

#ifndef ksu_kernel_write
static inline ssize_t ksu_kernel_write(struct file *file, const void *buf, size_t count, loff_t *pos)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 14, 0)
    return __kernel_write(file, buf, count, pos);
#else
    return kernel_write(file, buf, count, pos);
#endif
}
#endif
'''
lines = compat_text.splitlines()

# Remove every previously injected helper block from the first fallthrough
# guard through the end of the ksu_kernel_write guard.
start = next((i for i, line in enumerate(lines) if line.strip() == "#ifndef fallthrough"), -1)
if start >= 0:
    write_start = next((i for i in range(start, len(lines)) if lines[i].strip() == "#ifndef ksu_kernel_write"), -1)
    if write_start < 0:
        raise SystemExit("kernel_compat.h write helper block not found")
    end = -1
    count = 0
    for i in range(write_start + 1, len(lines)):
        if lines[i].strip() == "#endif":
            count += 1
            if count == 2:
                end = i + 1
                break
    if end < 0:
        raise SystemExit("kernel_compat.h write helper block end not found")
    lines = lines[:start] + lines[end:]

# Insert the canonical block after the standard kernel_compat includes.
insert = next((i for i, line in enumerate(lines) if line.strip() == "#include <linux/version.h>"), -1)
if insert < 0:
    raise SystemExit("kernel_compat.h version include marker missing")
lines = lines[:insert + 1] + ["", ""] + io_block.splitlines() + [""] + lines[insert + 1:]
compat_text = "\n".join(lines) + "\n"
compat_header.write_text(compat_text)

if compat_text.count("#ifndef ksu_kvmalloc") != 1:
    raise SystemExit("kernel_compat.h ksu_kvmalloc helper is not unique")
if compat_text.count("#ifndef ksu_kvfree") != 1:
    raise SystemExit("kernel_compat.h ksu_kvfree helper is not unique")
if "return ksu_kernel_read(file" in compat_text or "return ksu_kernel_write(file" in compat_text:
    raise SystemExit("Linux 4.9 kernel_compat I/O helper is recursive after normalization")
if "is_vmalloc_addr(" in compat_text:
    raise SystemExit("Linux 4.9 kernel_compat must not depend on unavailable is_vmalloc_addr")
print("[sukisu] Normalized Linux 4.9 compatibility helper block")

# Linux 4.9 app_profile seccomp compatibility.
# Linux 4.9 has no seccomp.filter_count field and uses put_seccomp_filter()
# to drop a task's filter reference.
app_profile = kernel_dir / "policy" / "app_profile.c"
if app_profile.is_file():
    source = app_profile.read_text()
    updated = source.replace(
        "void seccomp_filter_release(struct task_struct *tsk);",
        "void put_seccomp_filter(struct task_struct *tsk);",
        1,
    )
    updated = updated.replace(
        "    atomic_set(&current->seccomp.filter_count, 0);\n",
        "",
        1,
    )
    updated = updated.replace(
        "    seccomp_filter_release(fake);",
        "    put_seccomp_filter(fake);",
        1,
    )
    if "current->seccomp.filter_count" in updated:
        raise SystemExit("SukiSU app_profile still references unavailable Linux 4.9 seccomp.filter_count")
    if "seccomp_filter_release(fake)" in updated:
        raise SystemExit("SukiSU app_profile still references newer seccomp_filter_release")
    if "put_seccomp_filter(fake);" not in updated:
        raise SystemExit("SukiSU app_profile Linux 4.9 filter release adapter missing")
    if updated != source:
        app_profile.write_text(updated)
    print("[sukisu] Applied Linux 4.9 app_profile seccomp compatibility")

# Ensure every translation unit using the I/O helpers includes the compatibility header.
for path in kernel_dir.rglob("*.c"):
    if not path.is_file():
        continue
    source = path.read_text()
    if ("ksu_kernel_read(" in source or "ksu_kernel_write(" in source or
        "ksu_kvmalloc(" in source or "ksu_kvfree(" in source) and '#include "kernel_compat.h"' not in source:
        path.write_text('#include "kernel_compat.h"\n' + source)

# Linux 4.9 task_work compatibility.
# Linux 4.9 task_work_add() takes a bool notify argument; SukiSU's TWA_RESUME
# means requesting resume notification, which maps to true on this kernel.
replaced_twa = 0
for rel in ("policy/allowlist.c", "supercall/supercall.c"):
    path = kernel_dir / rel
    if not path.is_file():
        continue
    source = path.read_text()
    updated = source.replace("TWA_RESUME", "true")
    if updated != source:
        path.write_text(updated)
        replaced_twa += 1
print(f"[sukisu] Replaced TWA_RESUME with Linux 4.9 task_work notify=true in {replaced_twa} SukiSU source files")

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


# Linux 4.9 SELinux compatibility.
# The pinned SukiSU source targets newer LSM wrappers and the selinux_state
# object. Vendor Linux 4.9 exposes SELinux credentials as cred->security,
# uses security_context_to_sid()/security_sid_to_context(), and stores the
# enforcing/enabled state in selinux_enforcing/selinux_enabled.
selinux_src = kernel_dir / "selinux" / "selinux.c"
if selinux_src.is_file():
    source = selinux_src.read_text()
    updated = source
    compat = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
extern int selinux_enforcing;
extern int selinux_enabled;

static inline struct task_security_struct *ksu_selinux_cred(const struct cred *cred)
{
    return cred ? (struct task_security_struct *)cred->security : NULL;
}

static inline int ksu_security_secctx_to_secid(const char *context, u32 len, u32 *sid)
{
    return security_context_to_sid(context, len, sid, GFP_KERNEL);
}

static inline int ksu_security_secid_to_secctx(u32 sid, char **context, u32 *len)
{
    return security_sid_to_context(sid, context, len);
}

static inline void ksu_security_release_secctx(char *context, u32 len)
{
    (void)len;
    kfree(context);
}
#endif

"""
    if compat.strip() not in updated:
        insert_at = updated.find('#include "ksu.h"')
        if insert_at < 0:
            insert_at = updated.find('#include "klog.h"')
        if insert_at < 0:
            raise SystemExit("SukiSU selinux.c include insertion marker not found")
        updated = updated[:insert_at] + compat + updated[insert_at:]

    updated = updated.replace(
        "tsec = selinux_cred(cred);",
        "tsec = ksu_selinux_cred(cred);",
    )
    updated = updated.replace(
        "const struct task_security_struct *tsec = selinux_cred(cred);",
        "const struct task_security_struct *tsec = ksu_selinux_cred(cred);",
    )
    updated = updated.replace(
        "error = security_secctx_to_secid(domain, strlen(domain), &sid);",
        "error = ksu_security_secctx_to_secid(domain, strlen(domain), &sid);",
    )
    updated = updated.replace(
        "err = security_secctx_to_secid(KERNEL_SU_CONTEXT, strlen(KERNEL_SU_CONTEXT), &cached_su_sid);",
        "err = ksu_security_secctx_to_secid(KERNEL_SU_CONTEXT, strlen(KERNEL_SU_CONTEXT), &cached_su_sid);",
    )
    for name in ["ZYGOTE_CONTEXT", "INIT_CONTEXT", "KSU_FILE_CONTEXT"]:
        updated = updated.replace(
            "err = security_secctx_to_secid(" + name + ",",
            "err = ksu_security_secctx_to_secid(" + name + ",",
        )
    updated = updated.replace(
        "security_secid_to_secctx(tsec->sid, &ctx);",
        "ksu_security_secid_to_secctx(tsec->sid, &ctx);",
    )
    updated = updated.replace(
        "return security_secid_to_secctx(secid, &cp->context, &cp->len);",
        "return ksu_security_secid_to_secctx(secid, &cp->context, &cp->len);",
    )
    updated = updated.replace(
        "security_release_secctx(cp->context, cp->len);",
        "ksu_security_release_secctx(cp->context, cp->len);",
    )
    updated = updated.replace(
        "security_release_secctx(cp.context, cp.len);",
        "ksu_security_release_secctx(cp.context, cp.len);",
    )
    updated = updated.replace(
        "    selinux_state.enforcing = enforce;",
        "    selinux_enforcing = enforce ? 1 : 0;",
    )
    updated = updated.replace(
        "    if (selinux_state.disabled) {",
        "    if (!selinux_enabled) {",
    )
    updated = updated.replace(
        "    return selinux_state.enforcing;",
        "    return selinux_enforcing;",
    )

    # Remove stale newer LSM wrapper spellings only from call sites, never
    # from our compatibility helper declarations.
    if "selinux_state." in updated:
        raise SystemExit("SukiSU SELinux transform still references selinux_state")
    if re.search(r"(?<!ksu_)\bselinux_cred\s*\(", updated):
        raise SystemExit("SukiSU SELinux transform still references newer selinux_cred")
    if re.search(r"(?<!ksu_)\bsecurity_secctx_to_secid\s*\(", updated):
        raise SystemExit("SukiSU SELinux transform still references newer security_secctx_to_secid")
    if re.search(r"(?<!ksu_)\bsecurity_secid_to_secctx\s*\(", updated):
        raise SystemExit("SukiSU SELinux transform still references newer security_secid_to_secctx")
    if re.search(r"(?<!ksu_)\bsecurity_release_secctx\s*\(", updated):
        raise SystemExit("SukiSU SELinux transform still references newer security_release_secctx")
    if "ksu_selinux_cred(" not in updated:
        raise SystemExit("SukiSU SELinux credential adapter missing")
    if "ksu_security_secctx_to_secid(" not in updated:
        raise SystemExit("SukiSU SELinux context-to-SID adapter missing")
    if "ksu_security_secid_to_secctx(" not in updated:
        raise SystemExit("SukiSU SELinux SID-to-context adapter missing")
    if "ksu_security_release_secctx(" not in updated:
        raise SystemExit("SukiSU SELinux release-context adapter missing")
    if updated != source:
        selinux_src.write_text(updated)
    print("[sukisu] Applied Linux 4.9 SELinux compatibility")

# Linux 4.9 SELinux policydb compatibility.
# Linux 4.9 has no struct selinux_policy/selinux_state. Use a local wrapper
# around policydb for duplication, then submit the modified binary through
# security_load_policy(), which owns the real policy swap and SID table.
sepolicy_h = kernel_dir / "selinux" / "sepolicy.h"
if sepolicy_h.is_file():
    text = sepolicy_h.read_text()
    if "struct selinux_policy {" not in text:
        if "#include <linux/version.h>" not in text:
            marker = "#include <linux/types.h>\n"
            if marker not in text:
                raise SystemExit("SukiSU sepolicy.h linux/types include marker not found")
            text = text.replace(marker, marker + "#include <linux/version.h>\n", 1)
        marker = '#include "ss/policydb.h"\n'
        if marker not in text:
            raise SystemExit("SukiSU sepolicy.h policydb include marker not found")
        compat = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
struct selinux_policy {
    struct policydb policydb;
};
#endif

"""
        text = text.replace(marker, marker + compat, 1)
        sepolicy_h.write_text(text)

sepolicy_c = kernel_dir / "selinux" / "sepolicy.c"
if sepolicy_c.is_file():
    text = sepolicy_c.read_text()
    if '#include "security.h"' not in text:
        text = '#include "security.h"\n' + text
    start = text.find("void ksu_destroy_sepolicy(struct selinux_policy *pol)")
    if start < 0:
        raise SystemExit("SukiSU sepolicy.c policy wrapper functions not found")
    compat_start = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)

void ksu_destroy_sepolicy(struct selinux_policy *pol)
{
    if (!pol)
        return;
    policydb_destroy(&pol->policydb);
    kfree(pol);
}

struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol)
{
    int ret;
    size_t len;
    struct policydb *source;
    struct selinux_policy *new_pol;
    void *data;
    struct policy_file fp;

    if old_pol:
        source = &old_pol->policydb
        len = source->len
        if not len:
            return ERR_PTR(-EINVAL)

        data = vmalloc(len)
        if not data:
            return ERR_PTR(-ENOMEM)

        fp.data = data
        fp.len = len
        ret = policydb_write(source, &fp)
        if ret:
            vfree(data)
            return ERR_PTR(ret)
    else:
        ret = security_read_policy(&data, &len)
        if ret:
            return ERR_PTR(ret)
        if not data or not len:
            if data:
                vfree(data)
            return ERR_PTR(-EINVAL)

    new_pol = kzalloc(sizeof(*new_pol), GFP_KERNEL);
    if (!new_pol) {
        vfree(data);
        return ERR_PTR(-ENOMEM);
    }

    fp.data = data;
    fp.len = len;
    ret = policydb_read(&new_pol->policydb, &fp);
    vfree(data);
    if (ret) {
        kfree(new_pol);
        return ERR_PTR(ret);
    }

    new_pol->policydb.len = len;
    return new_pol;
}

#else
""";
    if "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)" not in text[start:start+200]:
        rest_start = text.find("    policydb_destroy(&pol->policydb);", start)
        if rest_start < 0:
            raise SystemExit("SukiSU sepolicy.c destroy body anchor not found")
        text = text[:start] + compat_start + text[rest_start:]
        end_marker = "    return ERR_PTR(ret);\n}"
        # The modern implementation closes at the first return ERR_PTR block after its function.
        modern_end = text.find(end_marker, text.find("struct selinux_policy *ksu_dup_sepolicy", start))
        if modern_end < 0:
            raise SystemExit("SukiSU sepolicy.c modern duplicate function end not found")
        modern_end += len(end_marker)
        text = text[:modern_end] + "\n#endif\n" + text[modern_end:]
    sepolicy_c.write_text(text)

rules = kernel_dir / "selinux" / "rules.c"
if rules.is_file():
    text = rules.read_text()
    state_start = text.find("static void reset_avc_cache()")
    batch_marker = "#define KSU_SEPOLICY_MAX_BATCH_SIZE"
    batch_pos = text.find(batch_marker)
    if state_start < 0 or batch_pos < 0:
        raise SystemExit("SukiSU rules.c policy-state block boundaries not found")

    compat_rules = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
static int ksu_install_sepolicy_49(struct policydb *db)
{
    void *data;
    struct policy_file fp;
    size_t len;
    int ret;

    if (!db || !db->len)
        return -EINVAL;

    len = db->len;
    data = vmalloc(len);
    if (!data)
        return -ENOMEM;

    fp.data = data;
    fp.len = len;
    ret = policydb_write(db, &fp);
    if (ret) {
        vfree(data);
        return ret;
    }

    ret = security_load_policy(data, len);
    vfree(data);
    return ret;
}

void apply_kernelsu_rules(void)
{
    struct selinux_policy *pol;
    struct policydb *db;
    int ret;

    if (!getenforce())
        pr_info("SELinux permissive or disabled, applying KernelSU rules on 4.9\\n");

    if (!backup_sepolicy) {
        backup_sepolicy = ksu_dup_sepolicy(NULL);
        if (IS_ERR(backup_sepolicy)) {
            pr_warn("failed to backup Linux 4.9 sepolicy: %ld\\n", PTR_ERR(backup_sepolicy));
            backup_sepolicy = NULL;
        }
    }

    pol = ksu_dup_sepolicy(NULL);
    if (IS_ERR(pol)) {
        pr_err("failed to duplicate Linux 4.9 sepolicy: %ld\\n", PTR_ERR(pol));
        return;
    }
    db = &pol->policydb;

    ksu_type(db, KERNEL_SU_DOMAIN, "domain");
    ksu_permissive(db, KERNEL_SU_DOMAIN);
    ksu_typeattribute(db, KERNEL_SU_DOMAIN, "mlstrustedsubject");
    ksu_typeattribute(db, KERNEL_SU_DOMAIN, "netdomain");
    ksu_typeattribute(db, KERNEL_SU_DOMAIN, "bluetoothdomain");

    ksu_type(db, KERNEL_SU_FILE, "file_type");
    ksu_typeattribute(db, KERNEL_SU_FILE, "mlstrustedobject");
    ksu_allow(db, "domain", KERNEL_SU_FILE, ALL, ALL);
    ksu_allow(db, KERNEL_SU_DOMAIN, ALL, ALL, ALL);

    if (db->policyvers >= POLICYDB_VERSION_XPERMS_IOCTL) {
        ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "blk_file", ALL);
        ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "fifo_file", ALL);
        ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "chr_file", ALL);
        ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "file", ALL);
    }

    ksu_allow(db, "init", KERNEL_SU_DOMAIN, ALL, ALL);
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "read");
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "read");
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "process", "getattr");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "process", "sigchld");

    ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "read");
    ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "getattr");

    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fd", "use");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "write");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "read");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "open");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "getattr");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "read");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "write");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "connectto");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getopt");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getattr");

    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "execute");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "getattr");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "map");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "read");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "write");

    ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "read");
    ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "process", "getattr");

    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "binder", ALL);
    ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "getpgid");
    ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "sigkill");

    ret = ksu_install_sepolicy_49(db);
    ksu_destroy_sepolicy(pol);
    if (ret)
        pr_err("failed to install Linux 4.9 KernelSU SELinux policy: %d\\n", ret);
    else
        pr_info("installed Linux 4.9 KernelSU SELinux policy\\n");
}
#else
"""

    # Replace only the old policy-state section; retain the command definitions below.
    text = text[:state_start] + compat_rules + text[batch_pos:]

    # Replace the final handle_sepolicy function with a 4.9 implementation.
    handle_start = text.find("int handle_sepolicy(void __user *user_data, u64 data_len)")
    if handle_start < 0:
        raise SystemExit("SukiSU rules.c handle_sepolicy function not found")
    body_start = text.find("{", handle_start)
    if body_start < 0:
        raise SystemExit("SukiSU rules.c handle_sepolicy opening brace not found")
    depth = 0
    body_end = -1
    in_string = False
    escape = False
    for pos in range(body_start, len(text)):
        ch = text[pos]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                body_end = pos + 1
                break
    if body_end < 0:
        raise SystemExit("SukiSU rules.c handle_sepolicy closing brace not found")

    old_handle = text[handle_start:body_end]
    compat_handle = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
static int handle_sepolicy_49(void __user *user_data, u64 data_len)
{
    struct selinux_policy *pol;
    struct policydb *db;
    struct sepol_batch_cursor cursor;
    u8 *payload;
    int ret = 0;
    int success_cmd_count = 0;
    u32 cmd_index = 0;

    if (!user_data || !data_len)
        return -EINVAL;
    if (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE)
        return -E2BIG;

    payload = vmalloc((size_t)data_len);
    if (!payload)
        return -ENOMEM;

    if (copy_from_user(payload, user_data, (size_t)data_len)) {
        vfree(payload);
        return -EFAULT;
    }

    pol = ksu_dup_sepolicy(NULL);
    if (IS_ERR(pol)) {
        vfree(payload);
        return PTR_ERR(pol);
    }
    db = &pol->policydb;

    cursor.cur = payload;
    cursor.end = payload + (size_t)data_len;

    while (cursor.cur < cursor.end) {
        struct sepol_data header;
        const char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 };
        int expected_argc;
        u32 arg_index;

        ret = sepol_read_cmd_header(&cursor, &header);
        if (ret < 0)
            goto out_drop;

        expected_argc = sepol_expected_argc(header.cmd);
        if (expected_argc < 0 || expected_argc > KSU_SEPOLICY_MAX_ARGS) {
            ret = -EINVAL;
            goto out_drop;
        }

        for (arg_index = 0; arg_index < (u32)expected_argc; arg_index++) {
            ret = sepol_read_string(&cursor, &args[arg_index]);
            if (ret < 0)
                goto out_drop;
        }

        ret = apply_one_sepolicy_cmd(db, &header, args);
        if (ret == 0)
            success_cmd_count++;
        else
            pr_err("sepol: cmd #%u failed, cmd=%u subcmd=%u\\n",
                   cmd_index, header.cmd, header.subcmd);
        cmd_index++;
    }

    if (success_cmd_count == 0) {
        ret = -EINVAL;
        goto out_drop;
    }

    ret = ksu_install_sepolicy_49(db);
    if (ret < 0)
        goto out_drop;

    ksu_destroy_sepolicy(pol);
    vfree(payload);
    return success_cmd_count;

out_drop:
    ksu_destroy_sepolicy(pol);
    vfree(payload);
    return ret < 0 ? ret : -EINVAL;
}

int handle_sepolicy(void __user *user_data, u64 data_len)
{
    return handle_sepolicy_49(user_data, data_len);
}
#else
"""
    text = text[:handle_start] + compat_handle + text[body_end:]
    # Close both dedicated Linux 4.9 conditional regions:
    # the policy-state branch and the handle_sepolicy branch.
    trailing = text.rstrip()
    text = trailing + "\n#endif\n#endif\n"

    rules.write_text(text)
    print("[sukisu] Applied deep Linux 4.9 SELinux policydb compatibility")

# Linux 4.9 SELinux sepolicy internal-structure compatibility.
# Vendor 4.9 uses flex_array for avtab/type arrays and the old
# filename_trans { stype, ttype, tclass, name } representation.
sepolicy = kernel_dir / "selinux" / "sepolicy.c"
if sepolicy.is_file():
    source = sepolicy.read_text()
    updated = source

    # Linux 4.9 avtab.htable is a flex_array of node pointers.
    avtab_helpers = """
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
#define KSU_AVTAB_HEAD(a, i) flex_array_get_ptr((a)->htable, (i))
static inline void ksu_avtab_set_head(struct avtab *a, unsigned int i,
                                      struct avtab_node *node)
{
    if (flex_array_put_ptr(a->htable, i, node, GFP_KERNEL | __GFP_ZERO))
        BUG();
}
#define KSU_AVTAB_FOR_EACH_HEAD(a, i, cur) \
    for ((i) = 0; (i) < (a)->nslot; ++(i)) \
        for ((cur) = KSU_AVTAB_HEAD((a), (i)); (cur); (cur) = (cur)->next)
#endif
"""
    if avtab_helpers.strip() not in updated:
        insert_at = updated.find("#define avtab_for_each")
        if insert_at < 0:
            raise SystemExit("SukiSU sepolicy avtab macro insertion marker not found")
        line_end = updated.find("\n", insert_at)
        updated = updated[:line_end + 1] + avtab_helpers + updated[line_end + 1:]

    updated = updated.replace(
        "for (n = db->te_avtab.htable[i]; n; prev = n, n = n->next) {",
        "for (n = KSU_AVTAB_HEAD(&db->te_avtab, i); n; prev = n, n = n->next) {",
    )
    updated = updated.replace(
        "db->te_avtab.htable[i] = n->next;",
        "ksu_avtab_set_head(&db->te_avtab, i, n->next);",
    )
    updated = updated.replace(
        "removed.htable[0] = n;",
        "ksu_avtab_set_head(&removed, 0, n);",
    )

    # Extract and replace add_filename_trans() with a native Linux 4.9 path,
    # retaining the original implementation behind #else for newer kernels.
    def replace_function(text, signature, replacement):
        # Prototypes and the real definition share the same signature text.
        # Always select the last occurrence so the definition is transformed.
        start = text.rfind(signature)
        if start < 0:
            raise SystemExit("function signature not found: " + signature)
        brace = text.find("{", start)
        if brace < 0:
            raise SystemExit("function opening brace not found: " + signature)
        depth = 0
        in_string = False
        escape = False
        end = -1
        for pos in range(brace, len(text)):
            ch = text[pos]
            if in_string:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == '"':
                    in_string = False
                continue
            if ch == '"':
                in_string = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = pos + 1
                    break
        if end < 0:
            raise SystemExit("function closing brace not found: " + signature)
        original = text[start:end]
        if "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)" in original:
            return text, False
        wrapped = replacement.replace("__ORIGINAL_FUNCTION__", original)
        return text[:start] + wrapped + text[end:], True

    old_filename = """static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c,
                               const char *d, const char *o)"""
    new_filename = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c,
                               const char *d, const char *o)
{
    struct type_datum *src, *tgt, *def;
    struct class_datum *cls;
    struct filename_trans key;
    struct filename_trans *new_key;
    struct filename_trans_datum *datum;

    src = symtab_search(&db->p_types, s);
    tgt = symtab_search(&db->p_types, t);
    cls = symtab_search(&db->p_classes, c);
    def = symtab_search(&db->p_types, d);
    if (!src || !tgt || !cls || !def)
        return false;

    key.stype = src->value;
    key.ttype = tgt->value;
    key.tclass = cls->value;
    key.name = o;

    datum = hashtab_search(db->filename_trans, &key);
    if (datum) {
        datum->otype = def->value;
        return true;
    }

    new_key = kzalloc(sizeof(*new_key), GFP_KERNEL);
    if (!new_key)
        return false;
    new_key->stype = key.stype;
    new_key->ttype = key.ttype;
    new_key->tclass = key.tclass;
    new_key->name = kstrdup(o, GFP_KERNEL);
    if (!new_key->name) {
        kfree(new_key);
        return false;
    }

    datum = kzalloc(sizeof(*datum), GFP_KERNEL);
    if (!datum) {
        kfree(new_key->name);
        kfree(new_key);
        return false;
    }
    datum->otype = def->value;

    if (hashtab_insert(db->filename_trans, new_key, datum)) {
        kfree((char *)new_key->name);
        kfree(new_key);
        kfree(datum);
        return false;
    }

    if (ebitmap_set_bit(&db->filename_trans_ttypes, tgt->value, 1)) {
        pr_warn("failed to mark filename transition target type %u\n", tgt->value);
    }

    return true;
}
#else
__ORIGINAL_FUNCTION__
#endif"""
    updated, filename_changed = replace_function(updated, old_filename, new_filename)

    # Replace add_type() for Linux 4.9. Newer kernels keep the existing
    # pointer arrays; 4.9 stores these in flex_array objects.
    old_add_type = """static bool add_type(struct policydb *db, const char *type_name, bool attr)"""
    new_add_type = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
static struct flex_array *ksu_clone_ptr_flex_array(struct flex_array *old,
                                                   unsigned int old_count,
                                                   unsigned int new_count)
{
    struct flex_array *newfa;
    unsigned int i;

    newfa = flex_array_alloc(sizeof(void *), new_count,
                             GFP_KERNEL | __GFP_ZERO);
    if (!newfa)
        return NULL;
    if (flex_array_prealloc(newfa, 0, new_count,
                            GFP_KERNEL | __GFP_ZERO)) {
        flex_array_free(newfa);
        return NULL;
    }

    for (i = 0; i < old_count; ++i) {
        void *p = flex_array_get_ptr(old, i);
        if (p && flex_array_put_ptr(newfa, i, p,
                                    GFP_KERNEL | __GFP_ZERO)) {
            flex_array_free(newfa);
            return NULL;
        }
    }
    return newfa;
}

static struct flex_array *ksu_clone_ebitmap_flex_array(struct flex_array *old,
                                                       unsigned int old_count,
                                                       unsigned int new_count)
{
    struct flex_array *newfa;
    unsigned int i;

    newfa = flex_array_alloc(sizeof(struct ebitmap), new_count,
                             GFP_KERNEL | __GFP_ZERO);
    if (!newfa)
        return NULL;
    if (flex_array_prealloc(newfa, 0, new_count,
                            GFP_KERNEL | __GFP_ZERO)) {
        flex_array_free(newfa);
        return NULL;
    }

    for (i = 0; i < old_count; ++i) {
        struct ebitmap *src = flex_array_get(old, i);
        struct ebitmap *dst = flex_array_get(newfa, i);
        if (!src || !dst || ebitmap_cpy(dst, src)) {
            unsigned int j;
            for (j = 0; j <= i && j < old_count; ++j) {
                struct ebitmap *tmp = flex_array_get(newfa, j);
                if (tmp)
                    ebitmap_destroy(tmp);
            }
            flex_array_free(newfa);
            return NULL;
        }
    }
    return newfa;
}

static void ksu_destroy_ebitmap_flex_array(struct flex_array *fa,
                                           unsigned int count)
{
    unsigned int i;
    if (!fa)
        return;
    for (i = 0; i < count; ++i) {
        struct ebitmap *e = flex_array_get(fa, i);
        if (e)
            ebitmap_destroy(e);
    }
    flex_array_free(fa);
}

static bool add_type(struct policydb *db, const char *type_name, bool attr)
{
    struct type_datum *type;
    char *key;
    unsigned int old_count, value;
    struct flex_array *new_attrs, *new_types, *new_names;
    struct flex_array *old_attrs, *old_types, *old_names;

    if (symtab_search(&db->p_types, type_name))
        return true;

    old_count = db->p_types.nprim;
    value = old_count + 1;

    type = kzalloc(sizeof(*type), GFP_KERNEL);
    if (!type)
        return false;
    type->primary = 1;
    type->value = value;
    type->attribute = attr;

    key = kstrdup(type_name, GFP_KERNEL);
    if (!key) {
        kfree(type);
        return false;
    }

    old_attrs = db->type_attr_map_array;
    old_types = db->type_val_to_struct_array;
    old_names = db->sym_val_to_name[SYM_TYPES];

    new_attrs = ksu_clone_ebitmap_flex_array(old_attrs, old_count, value);
    new_types = ksu_clone_ptr_flex_array(old_types, old_count, value);
    new_names = ksu_clone_ptr_flex_array(old_names, old_count, value);
    if (!new_attrs || !new_types || !new_names) {
        if (new_attrs)
            ksu_destroy_ebitmap_flex_array(new_attrs, value);
        if (new_types)
            flex_array_free(new_types);
        if (new_names)
            flex_array_free(new_names);
        kfree(key);
        kfree(type);
        return false;
    }

    if (symtab_insert(&db->p_types, key, type)) {
        ksu_destroy_ebitmap_flex_array(new_attrs, value);
        flex_array_free(new_types);
        flex_array_free(new_names);
        kfree(key);
        kfree(type);
        return false;
    }

    db->type_attr_map_array = new_attrs;
    db->type_val_to_struct_array = new_types;
    db->sym_val_to_name[SYM_TYPES] = new_names;
    db->p_types.nprim = value;

    {
        struct ebitmap *new_attr = flex_array_get(new_attrs, value - 1);
        if (!new_attr)
            return false;
        ebitmap_init(new_attr);
        if (ebitmap_set_bit(new_attr, value - 1, 1))
            return false;
    }

    if (flex_array_put_ptr(new_types, value - 1, type,
                           GFP_KERNEL | __GFP_ZERO))
        return false;
    if (flex_array_put_ptr(new_names, value - 1, key,
                           GFP_KERNEL | __GFP_ZERO))
        return false;

    {
        unsigned int i;
        for (i = 0; i < db->p_roles.nprim; ++i) {
            ebitmap_set_bit(&db->role_val_to_struct[i]->types,
                            value - 1, 1);
        }
    }

    ksu_destroy_ebitmap_flex_array(old_attrs, old_count);
    flex_array_free(old_types);
    flex_array_free(old_names);
    return true;
}
#else
__ORIGINAL_FUNCTION__
#endif"""
    updated, add_type_changed = replace_function(updated, old_add_type, new_add_type)

    # Patch direct newer array member accesses in helpers that are shared
    # between old and new kernels.
    if "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)" in updated:
        updated = updated.replace(
            "struct ebitmap *sattr = &db->type_attr_map_array[type->value - 1];",
            """struct ebitmap *sattr =
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
        (struct ebitmap *)flex_array_get(db->type_attr_map_array, type->value - 1);
#else
        &db->type_attr_map_array[type->value - 1];
#endif""",
        )
    print(f"[sukisu] sepolicy 4.9 transforms: filename={filename_changed} add_type={add_type_changed}")
    sepolicy.write_text(updated)
    print("[sukisu] Applied Linux 4.9 SELinux sepolicy internal-structure compatibility")
# SukiSU v4.2.0 uses syscall_fn_t on ARM64.
# Linux 4.9 ARM64 sys_call_table entries use the legacy:
#     long handler(const struct pt_regs *)
# function signature.
text = hook.read_text()
arm64_typedef = """#if defined(__aarch64__)
typedef long (*syscall_fn_t)(const struct pt_regs *);
#endif
"""
if arm64_typedef not in text:
    # Remove a previous standalone ARM64 typedef, if present, before replacing it.
    text = re.sub(
        r"#if defined\(__aarch64__\)\ntypedef void \(\*syscall_fn_t\)\(void\);\n#endif\n",
        "",
        text,
        count=1,
    )
    text = arm64_typedef + text
if "#include <linux/version.h>" not in text:
    text = "#include <linux/version.h>\n" + text
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