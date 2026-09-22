# Design

How the MRK3399 port sits on top of armbian/build, what each file does, and what to check when changing it.

## How the build works

`make setup` clones [armbian/build](https://github.com/armbian/build) into `build/`, checks out
`ARMBIAN_BUILD_COMMIT` from the Makefile and creates the symlink `build/userpatches -> ../userpatches`.
Armbian looks in `userpatches/` for anything that isn't in its own tree, so nothing inside `build/` is modified:

| File in this repo                                                   | Used by Armbian as                                                                                   |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `userpatches/config-mrk3399.conf`                                   | build parameters; `./compile.sh mrk3399` loads `config-mrk3399.conf`                                 |
| `userpatches/config/boards/mrk3399.csc`                             | board definition, alongside the in-tree ones in `config/boards/`                                     |
| `userpatches/kernel/archive/rockchip64-6.18/dt/rk3399-mrk3399.dts`  | extra kernel device tree; the `rockchip64-6.18` patching config copies `dt/` into `arch/arm64/boot/dts/rockchip/` and adds it to the Makefile, no patch needed |
| `userpatches/bootenv/mrk3399.txt`, `mrk3399-debug.txt`              | installed as `/boot/armbianEnv.txt` (selected by `BOOTENV_FILE`)                                     |
| `userpatches/extensions/qemu-binfmt-register.sh`                    | build extension, enabled in `config-mrk3399.conf`                                                    |
| `userpatches/u-boot/v2026.07/dt_uboot/rk3399-rock-pi-4a-u-boot.dtsi` | replaces U-Boot's own file of that name; `dt_uboot/` is copied onto `arch/arm/dts/` and same-named userpatches files win |
| `userpatches/customize-image.sh`, `userpatches/overlay/`            | runs in the chroot: sets up the default account, installs the USB gadget; the overlay is bind-mounted at `/tmp/overlay` |

On every run Armbian also creates `config-example.conf`, `overlay/` and a set of empty patch directories in
`userpatches/`. Git ignores `config-example.conf` and doesn't track empty directories. `customize-image.sh` is
tracked: Armbian only copies its template in when the file is absent, and this port ships its own, which
installs the [USB gadget](usb-gadget.md) from `userpatches/overlay/usb-gadget/`. Add packages or files to the
image there, following Armbian's
[user configuration docs](https://docs.armbian.com/Developer-Guide_User-Configurations/).

`./compile.sh` relaunches inside Docker on hosts that aren't a supported Ubuntu release. `build/cache` and
`build/output` are bind-mounted from the host, so caches survive between builds and when the repo moves.

## Board configuration

`mrk3399.csc` started as a trimmed copy of the in-tree `rockpi-4a.csc`.

| Setting                                         | Why                                                                                     |
| ----------------------------------------------- | --------------------------------------------------------------------------------------- |
| `BOARDFAMILY="rockchip64"`, `KERNEL_TARGET="current"` | Armbian's mainline RK3399 family; `current` is kernel 6.18 at the pinned commit |
| `BOOTBRANCH_BOARD="tag:v2026.07"`, `BOOTPATCHDIR="v2026.07"` | Same U-Boot as `rockpi-4a.csc`, so Armbian's `patch/u-boot/v2026.07` applies |
| `BOOTCONFIG="rock-pi-4-rk3399_defconfig"`       | U-Boot built for the Rock Pi 4, see below                                               |
| `BOOT_SCENARIO="binman-atf-mainline"`           | binman packs mainline TPL + SPL + ATF + U-Boot into one `u-boot-rockchip.bin`          |
| `BOOT_FDT_FILE="rockchip/rk3399-mrk3399.dtb"`   | Written to `fdtfile` in the boot environment                                            |
| `BOOT_SUPPORT_SPI=no`, `IMAGE_PARTITION_TABLE="gpt"` | No SPI flash on the board; the rockpi-4a SPI hook isn't copied                     |
| `SERIALCON` unset                               | The family default is `ttyS2` at 1500000                                                |

**Why the Rock Pi 4 U-Boot works on this board.** Both boards have the same RK808 + SYR827 + SYR828 power tree
and USB VBUS on GPIO4_D1. Checked against `rk3399-rock-pi-4.dtsi` in kernel 6.18 and U-Boot v2026.07, every RK808
DCDC, LDO and switch has the same voltage on both boards except LDO4 (MRK3399 `vcc_sd` 1.8–3.3 V, Rock Pi 4
`vcc_sdio` fixed 3.0 V), which only feeds an SD slot the MRK3399 doesn't have. The Rock Pi 4 TPL is built with
`CONFIG_RAM_ROCKCHIP_LPDDR4=y` and `rk3399-sdram-lpddr4-100.dtsi`, which matches the board's LPDDR4 and sizes RAM
at runtime. `binman-atf-mainline` also passes the rkbin DDR blob as `ROCKCHIP_TPL`, but the rock-pi-4 defconfig
has no `CONFIG_ROCKCHIP_EXTERNAL_TPL`, so the blob is ignored and the mainline TPL is used. A dedicated U-Boot
board is optional; see [uboot-board-support.md](uboot-board-support.md).

The board file has two hooks:

- `post_family_config__mrk3399_bootenv` runs after the family config so its values win. It sets `BOOTDELAY=2`
  (the family sets 0, which makes the U-Boot prompt hard to reach) and chooses the boot environment file from
  `MRK3399_DEBUG`, which `make build DEBUG=yes` passes as `MRK3399_DEBUG=yes`.
- `post_config_uboot_target__mrk3399_uboot_config` adjusts the U-Boot `.config`: it enables `CONFIG_USB_STORAGE`
  (the USB ports are the only removable media) and `CONFIG_OF_LIBFDT_OVERLAY` (`boot.scr` applies overlays with
  `fdt apply`), and disables `CONFIG_NVME_PCI` and `CONFIG_CMD_NVME`.

## Boot chain and image layout

```
BootROM → TPL (mainline, LPDDR4 init) → SPL → ATF BL31 (mainline) → U-Boot v2026.07
        → boot.scr (Armbian boot-rockchip64.cmd) → env import /boot/armbianEnv.txt
        → Image + uInitrd + dtb/rockchip/rk3399-mrk3399.dtb → Linux 6.18
```

| Offset             | Contents                                                           |
| ------------------ | ------------------------------------------------------------------ |
| 0                  | GPT                                                                |
| 32 KiB (sector 64) | `u-boot-rockchip.bin` (TPL + SPL + ATF + U-Boot)                   |
| 16 MiB             | partition 1: ext4 root filesystem, `/boot` included                |

## Boot environment

`/boot/armbianEnv.txt` comes from `userpatches/bootenv/`:

| File                | Selected by        | Contents                                                                         |
| ------------------- | ------------------ | -------------------------------------------------------------------------------- |
| `mrk3399.txt`       | default            | `verbosity=1`, `bootlogo=false`, `console=serial`                                |
| `mrk3399-debug.txt` | `make build DEBUG=yes` | also `verbosity=7` and `extraargs=earlycon=uart8250,mmio32,0xff1a0000`       |

`console=serial` keeps the console on `ttyS2` only, since the board has no display. Armbian's `boot.scr` adds
`console=ttyS2,1500000` itself. On a running board, edit `/boot/armbianEnv.txt` directly; see
[Passing kernel arguments from the U-Boot prompt](troubleshooting.md#passing-kernel-arguments-from-the-u-boot-prompt)
for the `extraargs` / `extraboardargs` trap.

## Kernel device tree

`rk3399-mrk3399.dts` comes from the board's Home Assistant OS port (kernel 6.6). Changes for 6.18 and for
correctness:

- Removed `#include "rk3399-opp.dtsi"`. Since 6.18 the OPP tables are part of `rk3399.dtsi`
  (`rk3399-base.dtsi` + OPPs). A 6.6 kernel still needs the include.
- `compatible` is the lowercase `"mrk,mrk3399", "rockchip,rk3399"`, to avoid a dtc warning.
- `vcc5v0_host` had `enable-active-high` together with `GPIO_ACTIVE_LOW`, which contradict each other (the kernel
  follows `enable-active-high` and warns). It now uses `GPIO_ACTIVE_HIGH` consistently, plus a pinctrl for GPIO4_D1.
- `gmac` in RMII mode uses `rmii_pins` (the same pins as `rgmii_pins` plus RX_ER), and the `tx_delay` /
  `rx_delay` properties, which do nothing for RMII, are gone. stmmac still honours the legacy `snps,reset-gpio`.
- The duplicated `&u2phy0_host` / `&u2phy1_host` nodes are merged.
- `usbdrd_dwc3_0` is `dr_mode = "peripheral"` rather than the Rock Pi 4's `"host"`, so the OTG port runs as a
  USB device. See [USB and the OTG port](#usb-and-the-otg-port).
- `sdmmc`, `sdio0`, `pcie0`, `pcie_phy`, `hdmi` and `tcphy1` stay disabled because the hardware isn't there.

Known quirk: only one xHCI controller registers. `usbdrd3_1` needs `tcphy1`, which is disabled, so `dwc3_1`
defers forever. The HAOS port behaves the same. Which controllers the two type-A ports use hasn't been
confirmed; a USB 3.0 stick and `lsusb -t` will show it, and an unused `usbdrd3_1` can then be disabled.

The DTS compiles without dtc warnings.

## USB and the OTG port

The RK3399 has two USB 3.0 dual-role controllers plus four USB 2.0 host controllers. Only controller 0 can be a
USB device here, and it is also the port the BootROM enumerates on in maskrom mode (`2207:330c`):

| Node                                | Physical                      | Role                                              |
| ----------------------------------- | ----------------------------- | -------------------------------------------------- |
| `usbdrd3_0` / `usbdrd_dwc3_0`       | OTG / flashing connector      | `dr_mode = "peripheral"`: gadget, and maskrom/loader |
| `u2phy0_otg`, `tcphy0_usb3`         | the same connector            | its USB 2.0 and SuperSpeed PHYs                    |
| `usbdrd3_1` / `usbdrd_dwc3_1`       | —                             | `"host"`, but never probes: `tcphy1` is disabled   |
| `usb_host0_*`, `usb_host1_*`        | the two type-A ports          | USB 2.0 EHCI/OHCI, VBUS from `vcc5v0_host`         |

**Why the role has to be set on the controller.** `phy-rockchip-inno-usb2` reads `dr_mode` from whichever
controller references the PHY port (`of_usb_get_dr_mode_by_phy`) and, when it reads `"host"`, skips the OTG
state machine, the `otg-bvalid` / `otg-id` interrupts and the extcon device entirely. dwc3 likewise only
initialises xHCI on `"host"`, even though Armbian's kernel is `CONFIG_USB_DWC3_DUAL_ROLE=y`. So a `"host"`
controller makes gadget mode impossible no matter what the PHY nodes say.

**Why not `dr_mode = "otg"`.** The board has no Type-C CC controller (no `fusb302`, and `i2c4` / `i2c7` are
disabled) and no ID pin routed, so there is nothing to switch roles from. `dwc3_get_extcon()` would also need
an explicit `extcon = <&u2phy0>` phandle to find the PHY's extcon device, since it doesn't look there on its
own. `"peripheral"` is deterministic and needs none of that.

**U-Boot has to agree.** U-Boot builds `rock-pi-4-rk3399_defconfig` with
`CONFIG_DEFAULT_DEVICE_TREE="rockchip/rk3399-rock-pi-4a"`, whose upstream DT also sets `dr_mode = "host"` on
this controller. `dwc3_glue_bind()` binds the peripheral driver only for `"peripheral"` or `"otg"`, so with
`"host"` no UDC is registered and `rockusb 0 mmc 0` and `ums 0 mmc 0` both fail — on the one port that could
serve them. `userpatches/u-boot/v2026.07/dt_uboot/rk3399-rock-pi-4a-u-boot.dtsi` replaces U-Boot's file of the
same name (same-basename userpatches files win, see `lib/tools/common/dt_makefile_patcher.py`) and overrides
the mode there too.

**VBUS.** Nothing on this board supplies VBUS to the OTG connector — the Rock Pi 4's `vbus_typec` regulator on
GPIO1_A3 has no equivalent here, and `vcc5v0_host` only feeds `u2phy0_host` / `u2phy1_host`. In peripheral mode
that is correct: the PC supplies VBUS, and the PHY uses it for `otg-bvalid` connect detection.

The gadget that runs on top of this is in [usb-gadget.md](usb-gadget.md).

## Unattended first boot

Armbian's stock image finishes configuring itself at the first root login: `distro-agnostic.sh` creates
`/root/.not_logged_in_yet`, `/etc/profile.d/armbian-check-first-login.sh` sees it and runs
`/usr/lib/armbian/armbian-firstlogin`, which asks for a root password, a user, a shell, a locale and a timezone.
Upstream can preseed that wizard (`userpatches/firstboot.conf`, copied verbatim to `.not_logged_in_yet`), but it
still only runs once someone logs in, and its `set_timezone_and_locales()` first waits for
`systemd-networkd-wait-online` and geolocates the board over HTTP — both dead ends on a headless board with no
network.

So the port does the work at build time instead. `userpatches/config-mrk3399.conf` holds the values:

| Setting | How it is applied |
| --- | --- |
| `MRK3399_USER`, `MRK3399_USER_PASSWORD`, `MRK3399_USER_REALNAME` | Exported into the chroot; `CreateUser` in `customize-image.sh` runs `useradd` and `chpasswd` |
| `MRK3399_TIMEZONE` | `SetTimezone` in `customize-image.sh` |
| `MRK3399_ROOT_PASSWORD` | Sets `ROOTPWD`, which Armbian applies while building the rootfs |
| `MRK3399_LOCALE` | Sets `DEST_LANG`; Armbian runs `locale-gen` and `update-locale` in `rootfs-create.sh` |

`customize-image.sh` then deletes `/root/.not_logged_in_yet`, so the wizard never runs. Three details come with
that, all handled in `SkipFirstLoginWizard` and the board config:

- The build strips `+x` from `/etc/update-motd.d/*` (`distro-agnostic.sh`) and the wizard is what puts it back,
  so the script does the `chmod` — otherwise the image has no MOTD.
- The same goes for the `AcceptEnv LANG` line in `sshd_config`, which the build comments out.
- `CONSOLE_AUTOLOGIN` defaults to `yes`, which installs `--autologin root` overrides for `getty@` and
  `serial-getty@`; the wizard removes them when it finishes. The board config sets `CONSOLE_AUTOLOGIN=no`
  instead, so `ttyS2` and the gadget console `ttyGS0` show a normal login prompt.

`MRK3399_TIMEZONE` can't be handled the same way as the locale: `main-config.sh` sets `TZDATA` from the build
host's `/etc/timezone` unconditionally, after user configs are sourced, so the board config can't win.

Values can be overridden per build without editing the config — `make build ARGS='MRK3399_USER=me'` — because
`compile.sh` re-applies command-line parameters after sourcing each config file. Passwords land in the image and
in the build log either way.

## Kernel configuration

The kernel uses Armbian's `linux-rockchip64-current` config unchanged, and `KERNEL_CONFIGURE=no` keeps
menuconfig from opening. The HAOS port needed a hwrng patch and `CONFIG_HW_RANDOM_ROCKCHIP`. Armbian's 6.18
series already ships `general-cryptov1-trng.patch` with `CONFIG_CRYPTO_DEV_ROCKCHIP_TRNG=y`, so neither is
needed here.

To change the kernel config, either:

- add a `custom_kernel_config__<name>` hook to `mrk3399.csc` that appends option names to `opts_y+=(...)`,
  `opts_n+=(...)` or `opts_m+=(...)`. It's applied on top of Armbian's config and survives upgrades best; or
- replace the whole config: run `./compile.sh kernel-config BOARD=mrk3399 BRANCH=current` in `build/`, which opens
  menuconfig and saves the result as `build/output/config/linux-rockchip64-current.config`, then copy that file
  to `userpatches/config/kernel/linux-rockchip64-current.config`. Armbian uses it instead of its own config.

## Kernel source cache

Armbian doesn't clone kernel.org directly. The first build uses `oras` to download a bare linux-stable repository
bundle (~2.7 GB) from `ghcr.io/armbian/shallow/kernel-git` into `build/cache/git-bare/kernel/`. Each build then
fetches only the `linux-6.18.y` branch from `KERNELSOURCE` and checks it out as a git worktree in
`build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64/`. U-Boot works the same way under
`build/cache/git-bare/u-boot/`. `make clean` keeps these caches; deleting `build/` removes them.

## Upgrading armbian/build

1. Pick a new commit on armbian/build `main` and set `ARMBIAN_BUILD_COMMIT` in the Makefile.
2. Run `make setup`, then compare with the previous commit:
   - `config/boards/rockpi-4a.csc`: if `BOOTBRANCH_BOARD` or `BOOTPATCHDIR` changed, update them in `mrk3399.csc`.
   - `config/sources/families/include/rockchip64_common.inc`: if `current` moved to a new kernel version,
     rename `userpatches/kernel/archive/rockchip64-6.18/` to match the new `KERNELPATCHDIR`, and check the DTS
     against that kernel's `rk3399.dtsi`.
   - `lib/functions/rootfs/distro-agnostic.sh`: `BOOTENV_FILE` must still be looked up in `userpatches/bootenv/`,
     and the assumptions behind "Unattended first boot" must still hold — `ROOTPWD`, `CONSOLE_AUTOLOGIN`,
     `/root/.not_logged_in_yet` and the `chmod -x /etc/update-motd.d/*` line.
   - The build container: if `update-binfmts` works again, the qemu extension becomes unnecessary (it does no harm).
3. Run `make build`, flash, and go through the [first boot checklist](../README.md#first-boot).

## Relation to the Home Assistant OS port

The board was first supported in a Home Assistant OS (buildroot) port. For anyone coming from there:

| HAOS (buildroot)                                        | This repo                                                                |
| ------------------------------------------------------- | ------------------------------------------------------------------------ |
| U-Boot 2024.01, `rock-pi-4-rk3399_defconfig`            | U-Boot v2026.07, same defconfig                                          |
| Mainline TPL (LPDDR4) + mainline ATF, no rkbin blobs    | `BOOT_SCENARIO=binman-atf-mainline`, also mainline TPL + ATF             |
| `u-boot-rockchip.bin` at 32 KiB                         | same, the rockchip64 family default                                      |
| Kernel 6.6 + a patch adding `rk3399-mrk3399.dts`        | Kernel 6.18 + `userpatches/kernel/.../dt/rk3399-mrk3399.dts`             |
| hwrng patch + `CONFIG_HW_RANDOM_ROCKCHIP`               | not needed (`general-cryptov1-trng.patch`, `CRYPTO_DEV_ROCKCHIP_TRNG=y`) |
| Serial `ttyS2` 115200                                   | `ttyS2` 1500000 (the family default)                                     |
| A/B boot script `uboot-boot.ush`                        | Armbian's `boot-rockchip64.cmd` + `/boot/armbianEnv.txt`                 |
| `earlycon=uart8250,mmio32,0xff1a0000` in `cmdline.txt`  | only in the debug boot environment (`DEBUG=yes`)                         |
| `CONFIG_BOOTDELAY=2`                                    | `BOOTDELAY=2` in `mrk3399.csc`                                           |

Device tree fixes should go to both places. The HAOS copy keeps the `rk3399-opp.dtsi` include for kernel 6.6.
