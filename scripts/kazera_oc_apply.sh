#!/bin/sh
set -eu

ROOT=${1:-.}
CPUCLK="$ROOT/drivers/clk/msm/clock-cpu-8953.c"
GCC="$ROOT/drivers/clk/msm/clock-gcc-8953.c"
SOC="$ROOT/arch/arm64/boot/dts/qcom/msm8953.dtsi"
GPU="$ROOT/arch/arm64/boot/dts/qcom/msm8953-gpu.dtsi"

for f in "$CPUCLK" "$GCC" "$SOC" "$GPU"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

python3 - "$CPUCLK" "$GCC" "$SOC" "$GPU" <<'PY'
from pathlib import Path
import sys

cpuclk, gcc, soc, gpu = map(Path, sys.argv[1:])


def replace_once(path: Path, old: str, new: str) -> None:
    s = path.read_text()
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{path}: expected 1 match, got {n}: {old!r}")
    path.write_text(s.replace(old, new, 1))

# CPU PLL: expose 2.4 GHz as the software ceiling. The existing PLL/VDD
# framework already carries a 2.4 GHz FMAX entry; the old hard ceiling was
# 2.208 GHz.
replace_once(
    cpuclk,
    '\t.max_rate = 2208000000UL,',
    '\t.max_rate = 2400000000UL,',
)

# Highest performance speed-bin: extend CPU and CCI OPP/FMAX lists using the
# existing top (Turbo) corner. Lower bins remain unchanged and therefore do
# not receive the OC.
replace_once(
    soc,
    '''\t\tqcom,speed7-bin-v0-cl =\n\t\t\t<          0 0>,\n\t\t\t<  652800000 1>,\n\t\t\t< 1036800000 2>,\n\t\t\t< 1401600000 3>,\n\t\t\t< 1689600000 4>,\n\t\t\t< 1804800000 5>,\n\t\t\t< 1958400000 6>,\n\t\t\t< 2016000000 7>,\n\t\t\t< 2150400000 8>,\n\t\t\t< 2208000000 9>;''',
    '''\t\tqcom,speed7-bin-v0-cl =\n\t\t\t<          0 0>,\n\t\t\t<  652800000 1>,\n\t\t\t< 1036800000 2>,\n\t\t\t< 1401600000 3>,\n\t\t\t< 1689600000 4>,\n\t\t\t< 1804800000 5>,\n\t\t\t< 1958400000 6>,\n\t\t\t< 2016000000 7>,\n\t\t\t< 2150400000 8>,\n\t\t\t< 2208000000 9>,\n\t\t\t< 2304000000 9>,\n\t\t\t< 2400000000 9>;''',
)

replace_once(
    soc,
    '''\t\tqcom,speed7-bin-v0-cci =\n\t\t\t<          0 0>,\n\t\t\t<  261120000 1>,\n\t\t\t<  414720000 2>,\n\t\t\t<  560640000 3>,\n\t\t\t<  675840000 4>,\n\t\t\t<  721920000 5>,\n\t\t\t<  783360000 6>,\n\t\t\t<  806400000 7>,\n\t\t\t<  860160000 8>,\n\t\t\t<  883200000 9>;''',
    '''\t\tqcom,speed7-bin-v0-cci =\n\t\t\t<          0 0>,\n\t\t\t<  261120000 1>,\n\t\t\t<  414720000 2>,\n\t\t\t<  560640000 3>,\n\t\t\t<  675840000 4>,\n\t\t\t<  721920000 5>,\n\t\t\t<  783360000 6>,\n\t\t\t<  806400000 7>,\n\t\t\t<  860160000 8>,\n\t\t\t<  883200000 9>,\n\t\t\t<  921600000 9>,\n\t\t\t<  960000000 9>;''',
)

replace_once(
    soc,
    '''\t\tqcom,cpufreq-table =\n\t\t\t <  652800 >,\n\t\t\t < 1036800 >,\n\t\t\t < 1401600 >,\n\t\t\t < 1689600 >,\n\t\t\t < 1804800 >,\n\t\t\t < 1958400 >,\n\t\t\t < 2016000 >,\n\t\t\t < 2150400 >,\n\t\t\t < 2208000 >;''',
    '''\t\tqcom,cpufreq-table =\n\t\t\t <  652800 >,\n\t\t\t < 1036800 >,\n\t\t\t < 1401600 >,\n\t\t\t < 1689600 >,\n\t\t\t < 1804800 >,\n\t\t\t < 1958400 >,\n\t\t\t < 2016000 >,\n\t\t\t < 2150400 >,\n\t\t\t < 2208000 >,\n\t\t\t < 2304000 >,\n\t\t\t < 2400000 >;''',
)

# GPU GCC corner map: extend the top Turbo corner to 700 and 800 MHz.
replace_once(
    soc,
    '''\t\tqcom,gfxfreq-corner =\n\t\t\t <         0   0 >,\n\t\t\t < 133330000   1 >,  /* Min SVS   */\n\t\t\t < 216000000   2 >,  /* Low SVS   */\n\t\t\t < 320000000   3 >,  /* SVS       */\n\t\t\t < 400000000   4 >,  /* SVS Plus  */\n\t\t\t < 510000000   5 >,  /* NOM       */\n\t\t\t < 560000000   6 >,  /* Nom Plus  */\n\t\t\t < 650000000   7 >;  /* Turbo     */''',
    '''\t\tqcom,gfxfreq-corner =\n\t\t\t <         0   0 >,\n\t\t\t < 133330000   1 >,  /* Min SVS   */\n\t\t\t < 216000000   2 >,  /* Low SVS   */\n\t\t\t < 320000000   3 >,  /* SVS       */\n\t\t\t < 400000000   4 >,  /* SVS Plus  */\n\t\t\t < 510000000   5 >,  /* NOM       */\n\t\t\t < 560000000   6 >,  /* Nom Plus  */\n\t\t\t < 650000000   7 >,  /* Turbo     */\n\t\t\t < 700000000   7 >,\n\t\t\t < 800000000   7 >;''',
)

# CPU bandwidth floor/ceiling tables are intentionally left untouched. The
# OC CPU frequencies continue to use the highest existing bandwidth vote.

# GPU clock source: 700 MHz = 1.4 GHz PLL, 800 MHz = 1.6 GHz PLL. gpll3 in
# this tree is already configured for dynamic operation up to 2 GHz.
replace_once(
    gcc,
    '\tF_MM( 650000000,    1300000000,               gpll3,    1,    0,     0),\n\n\tF_END',
    '\tF_MM( 650000000,    1300000000,               gpll3,    1,    0,     0),\n\tF_MM( 700000000,    1400000000,               gpll3,    1,    0,     0),\n\tF_MM( 800000000,    1600000000,               gpll3,    1,    0,     0),\n\n\tF_END',
)

# GPU power level 0 is the maximum selectable level.
replace_once(
    gpu,
    '''\t\t\t/* TURBO */\n\t\t\tqcom,gpu-pwrlevel@0 {\n\t\t\t\treg = <0>;\n\t\t\t\tqcom,gpu-freq = <650000000>;''',
    '''\t\t\t/* TURBO / OC */\n\t\t\tqcom,gpu-pwrlevel@0 {\n\t\t\t\treg = <0>;\n\t\t\t\tqcom,gpu-freq = <800000000>;''',
)

print('Kazera OC patch applied: CPU 2.4 GHz / GPU 800 MHz')
PY
