# Flashing

The image is a whole-disk image for the eMMC: GPT, `u-boot-rockchip.bin` at 32 KiB and the root filesystem from
16 MiB. It's written over USB with `rkdeveloptool` while the RK3399 is in **maskrom** or **loader** mode.

## Tools

- **rkdeveloptool**: use your distribution's package if it has one, or build it from
  [rockchip-linux/rkdeveloptool](https://github.com/rockchip-linux/rkdeveloptool). Without udev rules for
  Rockchip USB devices (`2207:*`), run it as root.
- **A USB loader**, needed only in maskrom mode. rkbin doesn't ship a ready-made RK3399 loader, but generates one:

  ```shell
  git clone --depth 1 https://github.com/rockchip-linux/rkbin.git
  cd rkbin
  tools/boot_merger RKBOOT/RK3399MINIALL.ini    # writes rk3399_loader_v1.30.130.bin
  ```

  This port was flashed with the older `rk3399_loader_v1.22.119.bin`. The loader only runs over USB during
  flashing and doesn't end up on the eMMC, so the version shouldn't matter, but v1.30 hasn't been tried on this board.

## Getting into maskrom or loader mode

Check with `rkdeveloptool ld`. It prints `Maskrom` or `Loader`.

| Board state                          | How                                                                                     |
| ------------------------------------ | --------------------------------------------------------------------------------------- |
| Empty or erased eMMC                 | Connect the flashing USB port and power on. The BootROM finds no bootloader and enters maskrom. |
| Any image with U-Boot v2026.07 (this one) or another U-Boot with `CONFIG_CMD_ROCKUSB` | Stop at the U-Boot prompt and run `rockusb 0 mmc 0`. The board appears in **loader** mode; skip `db`. |
| U-Boot works but has no `rockusb`    | At the U-Boot prompt run `mmc erase 0 10000` then `reset`. This erases the bootloader area, so the next boot enters maskrom. |

The last method wipes the bootloader: the board won't boot again until it's reflashed.

## Writing the image

```shell
xz -dk build/output/images/Armbian-unofficial_*_Mrk3399_*_minimal.img.xz

rkdeveloptool ld
rkdeveloptool db rk3399_loader_v1.30.130.bin    # maskrom mode only
rkdeveloptool wl 0 build/output/images/Armbian-unofficial_*_Mrk3399_*_minimal.img
rkdeveloptool rd                                # reset and boot
```

`wl 0` writes from sector 0, so the partition table, bootloader and root filesystem are all replaced. On first
boot Armbian grows the root partition to fill the eMMC. Until then the kernel reports
`GPT: Alternate GPT header not at the end of the disk`, which is expected.

To check the image against its checksum first: `sha256sum -c Armbian-unofficial_*.img.xz.sha` in
`build/output/images/`.

## Updating only U-Boot

When iterating on U-Boot, there's no need to rewrite the whole image. `make uboot` builds the
`linux-u-boot-mrk3399-current_*.deb` package in `build/output/debs/`. Extract `u-boot-rockchip.bin` from it and
write it at sector 64 (32 KiB):

```shell
cd build/output/debs
deb=$(ls -t linux-u-boot-mrk3399-current_*.deb | head -1)    # newest build
mkdir -p uboot && cd uboot
ar x "../$deb"
tar -xf data.tar* ./usr/lib/linux-u-boot-current-mrk3399/u-boot-rockchip.bin

rkdeveloptool wl 64 usr/lib/linux-u-boot-current-mrk3399/u-boot-rockchip.bin
rkdeveloptool rd
```

On a running board, copy the deb over and let its install script write the bootloader to the eMMC
(`/dev/mmcblk0`, the only MMC device on this board):

```shell
sudo apt install ./linux-u-boot-mrk3399-current_*.deb
sudo bash -c 'source /usr/lib/u-boot/platform_install.sh && write_uboot_platform "$DIR" /dev/mmcblk0'
sync
```

`write_uboot_platform` runs `dd if=$DIR/u-boot-rockchip.bin of=/dev/mmcblk0 bs=32k seek=1 conv=notrunc`.
A bad bootloader leaves the board unbootable until it's reflashed from maskrom, so try new U-Boot builds over USB first.
