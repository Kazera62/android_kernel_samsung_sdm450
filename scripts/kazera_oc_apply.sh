#!/bin/sh
set -eu

ROOT=${1:-.}
CPU_OC_MHZ=${CPU_OC_MHZ:-2112}
GPU_OC_MHZ=${GPU_OC_MHZ:-700}
CPU_OC_HZ=$((${CPU_OC_MHZ} * 1000000))
CPU_OC_KHZ=$((${CPU_OC_MHZ} * 1000))
GPU_OC_HZ=$((${GPU_OC_MHZ} * 1000000))

CPUCLK="$ROOT/drivers/clk/msm/clock-cpu-8953.c"
GCC="$ROOT/drivers/clk/msm/clock-gcc-8953.c"
SOC="$ROOT/arch/arm64/boot/dts/qcom/msm8953.dtsi"
GPU="$ROOT/arch/arm64/boot/dts/qcom/msm8953-gpu.dtsi"

for f in "$CPUCLK" "$GCC" "$SOC" "$GPU"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

python3 - "$CPUCLK" "$GCC" "$SOC" "$GPU" "$CPU_OC_HZ" "$CPU_OC_KHZ" "$GPU_OC_HZ" <<'PY'
from pathlib import Path
import re
import sys

cpuclk, gcc, soc, gpu = map(Path, sys.argv[1:5])
cpu_hz = int(sys.argv[5])
cpu_khz = int(sys.argv[6])
gpu_hz = int(sys.argv[7])

if cpu_hz < 1900000000 or cpu_hz > 2300000000:
    raise SystemExit(f"CPU_OC_MHZ outside supported patch range: {cpu_hz // 1000000}")
if gpu_hz < 650000000 or gpu_hz > 750000000:
    raise SystemExit(f"GPU_OC_MHZ outside supported patch range: {gpu_hz // 1000000}")


def replace_once(path, old, new):
    s = path.read_text()
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{path}: expected exactly one match, got {n}: {old!r}")
    path.write_text(s.replace(old, new, 1))


def update_fmax_table(path, prop, freq, corner=8):
    s = path.read_text()
    pat = re.compile(
        r'(?m)^(\\s*' + re.escape(prop) + r'\\s*=\\s*\\n)(.*?)(;)',
        re.S,
    )
    m = pat.search(s)
    if not m:
        raise SystemExit(f"{path}: missing {prop}")
    body = m.group(2)
    pairs = [(int(f), int(c)) for f, c in re.findall(r'<\\s*(\\d+)\\s+(\\d+)\\s*>', body)]
    if not pairs:
        raise SystemExit(f"{path}: {prop} contains no frequency/corner pairs")
    if any(f == freq for f, _ in pairs):
        return
    last = pairs[-1][0]
    if freq < last:
        raise SystemExit(f"{path}: {prop} is descending; refusing to insert {freq}")
    body = body.rstrip()
    if not body.endswith(','):
        body += ','
    body += f'\\n\\t\\t\\t< {freq} {corner} >'
    path.write_text(s[:m.start(2)] + body + m.group(3) + s[m.end(3):])


def update_cpufreq_table(path, freq_khz):
    s = path.read_text()
    pat = re.compile(r'(qcom,cpufreq-table\\s*=\\s*\\n)(.*?)(;)', re.S)
    m = pat.search(s)
    if not m:
        raise SystemExit(f"{path}: qcom,cpufreq-table not found")
    body = m.group(2)
    freqs = [int(x) for x in re.findall(r'<\\s*(\\d+)\\s*>', body)]
    if freq_khz in freqs:
        return
    freqs.append(freq_khz)
    freqs = sorted(set(freqs))
    indent = '\\t\\t\\t'
    new_body = ',\\n'.join(f'{indent}< {f} >' for f in freqs)
    path.write_text(s[:m.start(2)] + '\\n' + new_body + m.group(3) + s[m.end(3):])


# Keep the silicon driver's global ceiling at least as high as the selected OC.
s = cpuclk.read_text()
m = re.search(r'(\\.max_rate\\s*=\\s*)(\\d+)(UL\\s*,)', s)
if not m:
    raise SystemExit(f"{cpuclk}: .max_rate not found")
current_max = int(m.group(2))
if current_max < cpu_hz:
    cpuclk.write_text(s[:m.start(2)] + str(cpu_hz) + s[m.end(2):])

# The SDM450/MSM8953 driver selects one speed-bin table using efuse data.
# Add the OC point to every known bin so the build does not depend on an
# assumed chip bin. Corner 8 is the next power corner above the common
# SDM450/MSM8953 operating range and is intentionally below the 2.4 GHz hack.
for bin_id in ('0', '2', '6', '7'):
    update_fmax_table(soc, f'qcom,speed{bin_id}-bin-v0-cl', cpu_hz, 8)

# Match the CCI to 40% of CPU clock, rounded to the nearest 19.2 MHz step.
cci_hz = ((cpu_hz * 2 + 5 * 19200000) // (10 * 19200000)) * (10 * 19200000) // 10
for bin_id in ('0', '2', '6', '7'):
    update_fmax_table(soc, f'qcom,speed{bin_id}-bin-v0-cci', cci_hz, 8)

update_cpufreq_table(soc, cpu_khz)

# GPU GCC source table. gpll3 is already used for the 650 MHz Turbo point;
# the OC keeps that same parent and raises the generated PLL rate only.
gcc_text = gcc.read_text()
if f'F_MM( {gpu_hz},' not in gcc_text:
    marker = '\\tF_MM( 650000000,    1300000000,               gpll3,    1,    0,     0),'
    if marker not in gcc_text:
        raise SystemExit(f"{gcc}: 650MHz gpll3 entry not found")
    gcc_text = gcc_text.replace(
        marker,
        marker + f'\\n\\tF_MM( {gpu_hz},    {gpu_hz * 2},               gpll3,    1,    0,     0),',
        1,
    )
    gcc.write_text(gcc_text)

# Keep the OC on the Turbo voltage corner instead of inventing a new PMIC
# voltage. This is deliberate: frequency is raised, but the patch does not
# bypass Qualcomm/Samsung voltage safety limits.
s = soc.read_text()
if f'< {gpu_hz} 7 >' not in s and f'< {gpu_hz}   7 >' not in s:
    marker = '\\t\\t\\t < 650000000   7 >;  /* Turbo     */'
    if marker not in s:
        raise SystemExit(f"{soc}: GPU Turbo corner marker not found")
    s = s.replace(
        marker,
        '\\t\\t\\t < 650000000   7 >,  /* Turbo     */\\n' +
        f'\\t\\t\\t < {gpu_hz}   7 >;',
        1,
    )
    soc.write_text(s)

# KGSL powerlevel 0 is the runtime Turbo operating point.
s = gpu.read_text()
if f'qcom,gpu-freq = <{gpu_hz}>;' not in s:
    s2 = re.sub(
        r'(qcom,gpu-pwrlevel@0\\s*\\{\\s*reg\\s*=\\s*<0>;\\s*qcom,gpu-freq\\s*=\\s*)<650000000>;',
        rf'\\1<{gpu_hz}>;',
        s,
        count=1,
        flags=re.S,
    )
    if s2 == s:
        raise SystemExit(f"{gpu}: Turbo pwrlevel 0 marker not found")
    gpu.write_text(s2)

print(f'KAZERA_OC_APPLIED CPU={cpu_hz}Hz GPU={gpu_hz}Hz CCI={cci_hz}Hz')
PY
