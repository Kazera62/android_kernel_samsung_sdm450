#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CPU_OC_MHZ="${CPU_OC_MHZ:-2112}"
GPU_OC_MHZ="${GPU_OC_MHZ:-700}"
CPU_OC_HZ=$((CPU_OC_MHZ * 1000000))
GPU_OC_HZ=$((GPU_OC_MHZ * 1000000))
CPU_OC_KHZ=$((CPU_OC_MHZ * 1000))
CONFIG_FILE="${OUT_CONFIG:-$ROOT/.config}"

fail(){ echo "VERIFY-FAIL: $*" >&2; exit 1; }
pass(){ echo "VERIFY-OK: $*"; }

CPUCLK="$ROOT/drivers/clk/msm/clock-cpu-8953.c"
SOC="$ROOT/arch/arm64/boot/dts/qcom/msm8953.dtsi"
GCC="$ROOT/drivers/clk/msm/clock-gcc-8953.c"
GPU="$ROOT/arch/arm64/boot/dts/qcom/msm8953-gpu.dtsi"

for f in "$CPUCLK" "$SOC" "$GCC" "$GPU"; do
    [ -f "$f" ] || fail "$f missing"
done

# The base MSM8953 clock driver may expose a ceiling above the selected OC.
max_rate=$(sed -n 's/.*\.max_rate = \([0-9][0-9]*\)UL.*/\1/p' "$CPUCLK" | head -n1)
[ -n "$max_rate" ] || fail "CPU PLL max_rate not found"
[ "$max_rate" -ge "$CPU_OC_HZ" ] || fail "CPU PLL ceiling below ${CPU_OC_MHZ}MHz"

for b in 0 2 6 7; do
    block=$(awk "/qcom,speed${b}-bin-v0-cl =/{flag=1} flag{print} flag && /;/{exit}" "$SOC")
    printf '%s\n' "$block" | grep -Eq "< *${CPU_OC_HZ} +8 *>|< *${CPU_OC_HZ} +[89] *>" \
        || fail "CPU speed-bin ${b} lacks ${CPU_OC_MHZ}MHz OC point"
done

grep -A20 'qcom,cpufreq-table =' "$SOC" | grep -q "${CPU_OC_KHZ}" \
    || fail "cpufreq table lacks ${CPU_OC_MHZ}MHz"
grep -q "F_MM( ${GPU_OC_HZ}," "$GCC" \
    || fail "GPU GCC table lacks ${GPU_OC_MHZ}MHz"
grep -A16 'qcom,gfxfreq-corner =' "$SOC" | grep -q "${GPU_OC_HZ}" \
    || fail "GPU corner map lacks ${GPU_OC_MHZ}MHz"
grep -A8 'qcom,gpu-pwrlevel@0' "$GPU" | grep -q "qcom,gpu-freq = <${GPU_OC_HZ}>;" \
    || fail "GPU Turbo pwrlevel is not ${GPU_OC_MHZ}MHz"

[ -f "$CONFIG_FILE" ] || fail "generated config missing: $CONFIG_FILE"
grep -q '^CONFIG_KSU=y$' "$CONFIG_FILE" || fail "CONFIG_KSU=y missing from generated config"
grep -q '^CONFIG_KSU_KPROBES_HOOK=y$' "$CONFIG_FILE" || fail "CONFIG_KSU_KPROBES_HOOK=y missing"
grep -q '^CONFIG_KSU_LSM_SECURITY_HOOKS=y$' "$CONFIG_FILE" || fail "CONFIG_KSU_LSM_SECURITY_HOOKS=y missing"
grep -q '^CONFIG_OVERLAY_FS=y$' "$CONFIG_FILE" || fail "CONFIG_OVERLAY_FS=y missing"
grep -q '^CONFIG_KPROBES=y$' "$CONFIG_FILE" || fail "CONFIG_KPROBES=y missing"
grep -q '^CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y$' "$CONFIG_FILE" || fail "performance optimization config missing"

[ -L "$ROOT/drivers/kernelsu" ] || fail "drivers/kernelsu symlink missing"

pass "CPU ${CPU_OC_MHZ}MHz path present in PLL + all selected speed-bin OPP tables + cpufreq"
pass "GPU ${GPU_OC_MHZ}MHz path present in GCC + corner map + KGSL powerlevel"
pass "KernelSU ${KSU_TAG:-v1.1.1} integration present"
pass "Generated config is performance-oriented and internally gated"
