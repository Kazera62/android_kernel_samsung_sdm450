#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEFCONFIG="${DEFCONFIG:-a11q_open_defconfig}"
OUT="${OUT:-$ROOT/out-kazera-oc}"
JOBS="${JOBS:-$(nproc)}"
CPU_OC_MHZ="${CPU_OC_MHZ:-2400}"
GPU_OC_MHZ="${GPU_OC_MHZ:-800}"
KSU_TAG="${KSU_TAG:-v1.1.1}"
BUILD_HOST="${BUILD_HOST:-Kazera-Builder}"
BUILD_USER="${BUILD_USER:-Kazera}"
LOCALVERSION="${LOCALVERSION:--Kazera-OC-${CPU_OC_MHZ}G-${GPU_OC_MHZ}M}"

CLANG_BIN="${CLANG_BIN:-$ROOT/toolchain/llvm-arm-toolchain-ship-10.0/bin}"
GCC64_BIN="${GCC64_BIN:-$ROOT/toolchain/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/bin}"
GCC32_BIN="${GCC32_BIN:-$ROOT/toolchain/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9/bin}"
DTC_EXT="${DTC_EXT:-$ROOT/tools/dtc}"

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }
[ -x "$CLANG_BIN/clang" ] || { echo "missing clang: $CLANG_BIN/clang" >&2; exit 1; }
[ -x "$GCC64_BIN/aarch64-linux-android-gcc" ] || { echo "missing AArch64 GCC 4.9" >&2; exit 1; }
[ -x "$DTC_EXT" ] || { echo "missing DTC: $DTC_EXT" >&2; exit 1; }
need_cmd git
need_cmd python3

cd "$ROOT"

# Fresh out-of-tree build; never erase or rewrite the git worktree.
rm -rf "$OUT"
mkdir -p "$OUT"

./scripts/kazera_oc_apply.sh "$ROOT"
./scripts/setup_kernelsu_next.sh

export ARCH=arm64
export CROSS_COMPILE="$GCC64_BIN/aarch64-linux-android-"
export CROSS_COMPILE_ARM32="$GCC32_BIN/arm-linux-androideabi-"
export CLANG_TRIPLE=aarch64-linux-gnu-
export DTC_EXT
export CONFIG_BUILD_ARM64_DT_OVERLAY=y
export KBUILD_BUILD_HOST="$BUILD_HOST"
export KBUILD_BUILD_USER="$BUILD_USER"

COMMON=(O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" CC="$CLANG_BIN/clang" HOSTCC="$CLANG_BIN/clang" HOSTCXX="$CLANG_BIN/clang++" HOSTLD="$CLANG_BIN/ld.lld" LD="$GCC64_BIN/aarch64-linux-android-ld" AR="$CLANG_BIN/llvm-ar" NM="$CLANG_BIN/llvm-nm" OBJCOPY="$CLANG_BIN/llvm-objcopy" OBJDUMP="$CLANG_BIN/llvm-objdump" STRIP="$CLANG_BIN/llvm-strip" CLANG_TRIPLE="$CLANG_TRIPLE" DTC_EXT="$DTC_EXT" CONFIG_BUILD_ARM64_DT_OVERLAY=y)

make "${COMMON[@]}" "$DEFCONFIG"

python3 - "$OUT/.config" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
vals={
    'CONFIG_LOCALVERSION': '"-Kazera-OC-%sG-%sM"' % (__import__('os').environ.get('CPU_OC_MHZ','2400'), __import__('os').environ.get('GPU_OC_MHZ','800')),
    'CONFIG_DEFAULT_HOSTNAME': '"Kazera-Builder"',
    'CONFIG_KPROBES': 'y',
    'CONFIG_KSU': 'y',
    'CONFIG_KSU_KPROBES_HOOK': 'y',
    'CONFIG_KSU_LSM_SECURITY_HOOKS': 'y',
    'CONFIG_OVERLAY_FS': 'y',
    'CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE': 'y',
}
lines=s.splitlines()
seen=set()
out=[]
for line in lines:
    key=line.split('=',1)[0] if '=' in line else ''
    if key in vals:
        out.append(f'{key}={vals[key]}'); seen.add(key)
    else:
        out.append(line)
for key,val in vals.items():
    if key not in seen:
        out.append(f'{key}={val}')
p.write_text('\n'.join(out)+'\n')
PY

make "${COMMON[@]}" olddefconfig

# Verify the source gates and generated configuration before the expensive build.
OUT_CONFIG="$OUT/.config" ./scripts/kazera_oc_verify.sh

make "${COMMON[@]}" -j"$JOBS"

VMLINUX="$OUT/vmlinux"
IMAGE=""
for candidate in "$OUT/arch/arm64/boot/Image.gz-dtb" "$OUT/arch/arm64/boot/Image.gz" "$OUT/arch/arm64/boot/Image"; do
    if [ -f "$candidate" ]; then IMAGE="$candidate"; break; fi
done
[ -n "$IMAGE" ] || { echo "kernel Image not found" >&2; exit 1; }
[ -f "$VMLINUX" ] || { echo "vmlinux not found" >&2; exit 1; }

printf '\nBuild complete.\n'
printf 'Kernel image: %s\n' "$IMAGE"
printf 'vmlinux:      %s\n' "$VMLINUX"
printf 'Config:       %s\n' "$OUT_CONFIG"
printf 'KSU tag:      %s\n' "$KSU_TAG"
printf 'CPU OC:       %s MHz\n' "$CPU_OC_MHZ"
printf 'GPU OC:       %s MHz\n' "$GPU_OC_MHZ"
printf 'Host:         %s\n' "$BUILD_HOST"
printf 'User:         %s\n' "$BUILD_USER"
