# Kazera SDM450 OC

Target branch: `kazera-oc-2.4-800`

This branch adds a software-visible OC path to the MSM8953/SDM450 clock stack rather than changing DTS alone.

## Changes

- CPU PLL software ceiling: 2.208 GHz -> 2.400 GHz.
- `speed7-bin-v0-cl`: adds 2.304 and 2.400 GHz at the existing highest voltage corner.
- `qcom,cpufreq-table`: adds 2.304 and 2.400 GHz so the msm cpufreq driver can actually request the frequencies.
- CCI speed7 table: adds 921.6 and 960 MHz using the existing top corner.
- GPU clock source table: adds 700 and 800 MHz entries from gpll3.
- GPU frequency/corner map: adds 700 and 800 MHz at the existing Turbo corner.
- GPU Turbo powerlevel 0: 650 -> 800 MHz.

## Why the DTS-only change did not work

The CPU path has multiple gates: the cpufreq table, the CPU clock driver's PLL maximum, and the speed-bin/VDD OPP table. The GPU path similarly has both the KGSL power-level table and the GCC GPU clock source table.

## Build

```bash
export DEFCONFIG=a11q_open_defconfig
export JOBS=$(nproc)
./scripts/build_kazera_oc.sh
```

For Clang builds:

```bash
export DEFCONFIG=a11q_open_defconfig
export CLANG=1
./scripts/build_kazera_oc.sh
```

## Validation on device

After installing a test kernel, verify the exposed limits and the actual running frequency through the device's cpufreq/devfreq interfaces. A listed frequency is not proof of silicon stability: the real maximum still depends on the specific SoC, PMIC, thermal solution, firmware, and board.

Do not remove the existing thermal mitigation. The goal is to expose a controlled higher operating point while keeping the normal protection path intact.
