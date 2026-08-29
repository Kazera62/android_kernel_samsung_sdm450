#!/bin/sh
set -eu

ROOT=${1:-.}
CPU_OC_MHZ=${CPU_OC_MHZ:-2400}
GPU_OC_MHZ=${GPU_OC_MHZ:-800}
CPU_OC_HZ=$((${CPU_OC_MHZ} * 1000000))
GPU_OC_HZ=$((${GPU_OC_MHZ} * 1000000))

CPUCLK="$ROOT/drivers/clk/msm/clock-cpu-8953.c"
GCC="$ROOT/drivers/clk/msm/clock-gcc-8953.c"
SOC="$ROOT/arch/arm64/boot/dts/qcom/msm8953.dtsi"
GPU="$ROOT/arch/arm64/boot/dts/qcom/msm8953-gpu.dtsi"

for f in "$CPUCLK" "$GCC" "$SOC" "$GPU"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

python3 - "$CPUCLK" "$GCC" "$SOC" "$GPU" "$CPU_OC_HZ" "$GPU_OC_HZ" <<'PY'
from pathlib import Path
import re
import sys

cpuclk, gcc, soc, gpu = map(Path, sys.argv[1:5])
cpu_hz = int(sys.argv[5])
gpu_hz = int(sys.argv[6])


def replace_once(path, old, new):
    s = path.read_text()
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{path}: expected exactly one match, got {n}: {old!r}")
    path.write_text(s.replace(old, new, 1))


def add_freq_to_pair_table(path, prop, freq, corner=9):
    s = path.read_text()
    pat = re.compile(r'(^\\s*' + re.escape(prop) + r'\\s*=\\n)(.*?)(;)', re.M | re.S)
    m = pat.search(s)
    if not m:
        raise SystemExit(f"{path}: missing {prop}")
    body = m.group(2)
    if re.search(rf'<\\s*{freq}\\s+\\d+\\s*>', body):
        return False
    # Keep the source table sorted and use the existing highest corner for the OC level.
    pairs = re.findall(r'<\\s*(\\d+)\\s+(\\d+)\\s*>', body)
    if not pairs:
        raise SystemExit(f"{path}: {prop} contains no pairs")
    max_freq = max(int(f) for f, _ in pairs)
    indent = '\\t\\t\\t'
    if max_freq >= freq:
        return False
    new_body = body.rstrip() + f',\\n{indent}< {freq:>10} {corner}>'
    path.write_text(s[:m.start(2)] + new_body + m.group(3) + s[m.end(3):])
    return True

# CPU PLL ceiling. The tree already exposes an SVS FMAX mapping at 2.4 GHz;
# the old software ceiling was 2.208 GHz, which made higher OPPs unreachable.
s = cpuclk.read_text()
s2 = s.replace('\\t.max_rate = 2208000000UL,', f'\\t.max_rate = {cpu_hz}UL,')
if s2 != s:
    cpuclk.write_text(s2)

# Extend every SDM450 speed-bin table present in this common DTSI. This avoids
# silently depending on a particular eFuse speed bin.
for bin_id in ('0', '2', '6', '7'):
    add_freq_to_pair_table(soc, f'qcom,speed{bin_id}-bin-v0-cl', cpu_hz, 9)

# CCI follows CPU rate; add a proportional high-end point for the top bin.
cci_hz = (cpu_hz * 10) // 25
add_freq_to_pair_table(soc, 'qcom,speed7-bin-v0-cci', cci_hz, 9)

# Add OC frequencies to the common cpufreq table in kHz.
s = soc.read_text()
if f'< {cpu_hz // 1000} >' not in s:
    marker = '\\t\\t\\t < 2208000 >;'
    if marker in s:
        soc.write_text(s.replace(marker,
            '\\t\\t\\t < 2208000 >,\\n\\t\\t\\t < ' + str((cpu_hz - 96000000) // 1000) + ' >,\\n\\t\\t\\t < ' + str(cpu_hz // 1000) + ' >;', 1))
    else:
        raise SystemExit(f"{soc}: cpufreq table marker not found")

# GPU GCC source table. Refuse to invent a different parent; the existing gpll3
# source is used for the 650 MHz Turbo point.
gcc_text = gcc.read_text()
if f'F_MM( {gpu_hz}' not in gcc_text:
    marker = '\\tF_MM( 650000000,    1300000000,               gpll3,    1,    0,     0),'
    if marker not in gcc_text:
        raise SystemExit(f"{gcc}: 650MHz gpll3 entry not found")
    pll_rate = gpu_hz * 2
    gcc_text = gcc_text.replace(marker,
        marker + f'\\n\\tF_MM( {gpu_hz},    {pll_rate},               gpll3,    1,    0,     0),', 1)
    gcc.write_text(gcc_text)

# GPU corner map in the same common DTSI.
s = soc.read_text()
if f'< {gpu_hz} 7 >' not in s and f'< {gpu_hz}   7 >' not in s:
    marker = '\\t\\t\\t < 650000000   7 >;  /* Turbo     */'
    if marker not in s:
        raise SystemExit(f"{soc}: GPU Turbo corner marker not found")
    soc.write_text(s.replace(marker,
        '\\t\\t\\t < 650000000   7 >,  /* Turbo     */\\n\\t\\t\\t < ' + str(gpu_hz) + '   7 >;', 1))

# KGSL powerlevel 0 is the actual top GPU operating point.
s = gpu.read_text()
if f'qcom,gpu-freq = <{gpu_hz}>;' not in s:
    s2 = re.sub(r'(qcom,gpu-pwrlevel@0\\s*\\{\\s*reg\\s*=\\s*<0>;\\s*qcom,gpu-freq\\s*=\\s*)<650000000>;',
                rf'\\1<{gpu_hz}>;', s, count=1, flags=re.S)
    if s2 == s:
        raise SystemExit(f"{gpu}: Turbo pwrlevel 0 marker not found")
    gpu.write_text(s2)

print(f'KAZERA_OC_APPLIED CPU={cpu_hz}Hz GPU={gpu_hz}Hz CCI={cci_hz}Hz')
PY
