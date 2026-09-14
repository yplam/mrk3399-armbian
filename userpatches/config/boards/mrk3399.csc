# Rockchip RK3399 hexa core 4GB LPDDR4 SoC 100M ethernet eMMC 2x USB
# Out-of-tree board support from the mrk3399-armbian repo, see its docs/design.md
BOARD_NAME="MRK3399"
BOARD_VENDOR="mrk"
BOARDFAMILY="rockchip64"
BOARD_MAINTAINER=""
INTRODUCED="2024"
# U-Boot: same tag and patch dir as rockpi-4a.csc, so patch/u-boot/v2026.07 applies
BOOTBRANCH_BOARD="tag:v2026.07"
BOOTPATCHDIR="v2026.07"
# The Rock Pi 4 U-Boot (mainline TPL with LPDDR4 timings, mainline ATF) boots
# this board; both share the RK808 / SYR827 / SYR828 power tree. See
# docs/uboot-board-support.md for a dedicated defconfig.
BOOTCONFIG="rock-pi-4-rk3399_defconfig"
KERNEL_TARGET="current"
KERNEL_TEST_TARGET="current"
BOOT_FDT_FILE="rockchip/rk3399-mrk3399.dtb"
# binman builds u-boot-rockchip.bin (TPL+SPL+ATF+U-Boot) which the family writes
# at 32 KiB. rock-pi-4 has no CONFIG_ROCKCHIP_EXTERNAL_TPL, so ROCKCHIP_TPL from
# rkbin is ignored and the mainline TPL is used.
BOOT_SCENARIO="binman-atf-mainline"
BOOT_SUPPORT_SPI=no
IMAGE_PARTITION_TABLE="gpt"
# SERIALCON is left unset: the family defaults it to ttyS2 (1500000 baud).

# Set after the family config so they win over its values:
# - BOOTENV_FILE: userpatches/bootenv/mrk3399.txt -> /boot/armbianEnv.txt with
#   console=serial (no display on this board). MRK3399_DEBUG=yes selects
#   mrk3399-debug.txt instead: verbosity=7 and earlycon, so a kernel that dies
#   before the ttyS2 driver probes still prints something.
# - BOOTDELAY: the family sets 0; 2 s makes the U-Boot prompt reachable for
#   manual boot tests.
function post_family_config__mrk3399_bootenv() {
	declare -g BOOTDELAY=2
	if [[ "${MRK3399_DEBUG:-no}" == "yes" ]]; then
		display_alert "$BOARD" "debug boot environment: earlycon, verbosity=7" "info"
		declare -g BOOTENV_FILE="mrk3399-debug.txt"
	else
		declare -g BOOTENV_FILE="mrk3399.txt"
	fi
}

function post_config_uboot_target__mrk3399_uboot_config() {
	display_alert "$BOARD" "u-boot: enable USB storage and DT overlays for ${BOOTBRANCH_BOARD}" "info"
	# USB mass storage (the two USB ports are the only removable media on this board)
	run_host_command_logged scripts/config --enable CONFIG_USB_STORAGE
	# boot.scr applies overlays with 'fdt apply'
	run_host_command_logged scripts/config --enable CONFIG_OF_LIBFDT_OVERLAY
	# nothing on this board is behind PCIe or SPI flash
	run_host_command_logged scripts/config --disable CONFIG_NVME_PCI
	run_host_command_logged scripts/config --disable CONFIG_CMD_NVME
}
