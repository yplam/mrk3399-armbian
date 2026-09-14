# Dedicated U-Boot board support (optional)

> Not implemented yet. This is the plan for when a Rock Pi 4 dependency becomes a problem.

U-Boot is currently built from `rock-pi-4-rk3399_defconfig` with the Rock Pi 4 device tree. That's electrically
safe on the MRK3399 (see [Why the Rock Pi 4 U-Boot works on this board](design.md#board-configuration)). The only
differences are HDMI, PCIe, NVMe and SPI flash support that U-Boot initialises or probes for hardware the MRK3399
doesn't have. Dropping them takes a dedicated U-Boot board.

Armbian's `patch/u-boot/v2026.07/0000.patching_config.yaml` copies the `defconfig/`, `dt_upstream_rockchip/` and
`dt_uboot/` directories into the U-Boot tree. The same directories under `userpatches/u-boot/v2026.07/` are merged
in, so no patch file is needed.

## Steps

1. `userpatches/u-boot/v2026.07/defconfig/mrk3399-rk3399_defconfig`: copy `rock-pi-4-rk3399_defconfig` from the
   U-Boot v2026.07 tree, set `CONFIG_DEFAULT_DEVICE_TREE="rockchip/rk3399-mrk3399"`, and remove the HDMI / video,
   PCIe, NVMe and SPI flash options. Keep the `CONFIG_RAM_ROCKCHIP_LPDDR4=y` / TPL options unchanged.
2. `userpatches/u-boot/v2026.07/dt_upstream_rockchip/rk3399-mrk3399.dts`: a copy of the kernel device tree from
   `userpatches/kernel/archive/rockchip64-6.18/dt/`.
3. `userpatches/u-boot/v2026.07/dt_uboot/rk3399-mrk3399-u-boot.dtsi`: include `rk3399-u-boot.dtsi` and
   `rk3399-sdram-lpddr4-100.dtsi`, and set `u-boot,spl-boot-order = "same-as-spl", &sdhci;` in `/chosen`
   (eMMC is the only boot medium).
4. In `userpatches/config/boards/mrk3399.csc`, set `BOOTCONFIG="mrk3399-rk3399_defconfig"`. Keep the
   `post_config_uboot_target__` hook, or fold its options into the new defconfig.

## Testing

1. `make uboot`, then write only the bootloader as in
   [Updating only U-Boot](flashing.md#updating-only-u-boot). Keep a working `u-boot-rockchip.bin` around. If the
   new one doesn't come up, enter maskrom (erased or broken bootloader means the BootROM falls back to maskrom)
   and write the old one back.
2. On the serial console, check that the TPL still reports 4 GB of LPDDR4, that U-Boot's `mmc list` shows the eMMC,
   and that `Boot script loaded from mmc 0` appears.
3. Once it boots, run `make build` and go through the [first boot checklist](../README.md#first-boot).
