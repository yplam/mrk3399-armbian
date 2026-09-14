# Troubleshooting

Most of this comes from the first bring-up of the board in September 2026. Start with the power supply:
it caused every "hang" seen so far.

- [Power supply](#power-supply)
- [No output after `Starting kernel ...`](#no-output-after-starting-kernel-)
- [Passing kernel arguments from the U-Boot prompt](#passing-kernel-arguments-from-the-u-boot-prompt)
- [Finding where a silent hang happens](#finding-where-a-silent-hang-happens)
- [Build problems](#build-problems)

## Power supply

**Use a 5 V supply rated 3 A.** RK3399 + 4 GB LPDDR4 + eMMC + two USB host ports need at least 2 A, with
headroom for peaks. A PC USB port supplies 0.5 A (USB 2.0) to 0.9 A (USB 3.0), and charging ports about 1.5 A.
Powering the board from a serial adapter doesn't work either.

What an undersized supply looks like: the kernel boots for a few seconds, then the serial console stops,
sometimes in the middle of a line. There's no oops, no panic and no reboot. The RK808 PMIC cuts power on
undervoltage and doesn't restart the board. It happens when the load goes up, so the stopping point moves
between boots. During bring-up the board stopped once when USB VBUS and the Ethernet PHY came up (about 2.3 s)
and once after `systemd-udevd` started loading modules in the initramfs. The same image booted to the login
prompt as soon as a 5 V / 3 A supply was used.

**A hang that stops in a different place on each boot, with no error, is almost always power.** Rule it out
before debugging software.

## No output after `Starting kernel ...`

The default image doesn't pass `earlycon`, so a kernel that dies before the `ttyS2` driver probes prints nothing.
Get the early log in one of two ways:

- Rebuild with the bring-up boot environment:

  ```shell
  make build DEBUG=yes
  ```

  This installs `userpatches/bootenv/mrk3399-debug.txt` as `/boot/armbianEnv.txt`
  (`verbosity=7`, `extraargs=earlycon=uart8250,mmio32,0xff1a0000`).

- Or pass the arguments once from the U-Boot prompt, as described in the next section:

  ```
  => setenv extraboardargs "earlycon=uart8250,mmio32,0xff1a0000 ignore_loglevel"
  => run bootcmd
  ```

## Passing kernel arguments from the U-Boot prompt

Press any key during the 2 second boot delay to get the `=>` prompt. Armbian's `boot.scr` builds `bootargs`
from `${extraargs}` and then `${extraboardargs}`, **but it runs `env import` on `/boot/armbianEnv.txt` first.**
A `setenv extraargs ...` at the prompt is therefore overwritten whenever that file sets `extraargs`, and the
debug boot environment does. Use `extraboardargs`, which the file doesn't set:

```
=> setenv extraboardargs "ignore_loglevel initcall_debug"
=> run bootcmd
```

After boot, check `/proc/cmdline` to confirm the arguments actually made it.

## Finding where a silent hang happens

Rule out [power](#power-supply) first. Then:

1. **Capture the whole log** with `picocom -b 1500000 --logfile boot.log /dev/ttyUSB0` (or `minicom -C`), so a
   half line really is where the output stopped and not a copy-paste artifact.
2. **Watch the status LED.** The heartbeat trigger starts about 1.8 s into boot. If the heartbeat stops, the CPU
   is hung or the board lost power. If it keeps going, only the console died.
3. **Read the last lines**:
   - Nothing after `Starting kernel ...`, not even with earlycon: the kernel never ran or never got the
     device tree. Suspect the U-Boot handoff (load addresses, memory node, initrd location) and try
     [swapping U-Boot](#swapping-u-boot).
   - Stops near `regulator`, `rk808` or `io-domain`: check the regulator constraints in
     `rk3399-mrk3399.dts`. The U-Boot device tree isn't the suspect: the Rock Pi 4 tree U-Boot uses matches
     this board's RK808 voltages except LDO4, which only feeds an SD slot the board doesn't have.
   - Stops near `cpufreq`, `dmc` or `thermal`: isolate with `cpufreq.off=1` in `extraboardargs`.

Then isolate from the U-Boot prompt, one step at a time.

### Keep unused clocks and power domains on

The late initcalls turn off clocks and power domains that no driver claimed. If the board still uses one of
them, the bus hangs silently.

```
=> setenv extraboardargs "ignore_loglevel initcall_debug clk_ignore_unused pd_ignore_unused"
=> run bootcmd
```

It's in effect when the kernel prints `clk: Not disabling unused clocks` and
`genpd: Not disabling unused power domains`.

- If it boots now, drop one of the two arguments to see which one matters. Then look in
  `/sys/kernel/debug/clk/clk_summary` for the clock that was left on, and either add the missing `clocks` or
  `power-domains` to the device tree, or keep the argument in `extraargs`.
- If it still hangs, `initcall_debug` prints `calling xxx` and `initcall xxx returned`. The last `calling`
  line without a matching `returned` is where it hangs.

### Boot with the Rock Pi 4A device tree

The same `linux-dtb` package ships it:

```
=> setenv fdtfile rockchip/rk3399-rock-pi-4a.dtb
=> run bootcmd
```

If this gets further, the problem is in how `rk3399-mrk3399.dts` differs from the Rock Pi 4A: the RMII gmac,
the disabled sdmmc / sdio / hdmi / pcie / i2c nodes, and the power tree. With that tree Ethernet and USB power
may not work, but that doesn't matter for this test.

### Disable devices in the loaded device tree

Load the files by hand and turn off nodes before booting. For example, all four USB 2.0 host controllers:

```
=> load mmc 0:1 ${kernel_addr_r} /boot/Image
=> load mmc 0:1 ${fdt_addr_r} /boot/dtb/rockchip/rk3399-mrk3399.dtb
=> load mmc 0:1 ${ramdisk_addr_r} /boot/uInitrd
=> fdt addr ${fdt_addr_r}
=> fdt resize 8192
=> fdt set /usb@fe380000 status disabled
=> fdt set /usb@fe3a0000 status disabled
=> fdt set /usb@fe3c0000 status disabled
=> fdt set /usb@fe3e0000 status disabled
=> setenv bootargs "root=/dev/mmcblk0p1 rootwait console=ttyS2,1500000 earlycon=uart8250,mmio32,0xff1a0000 ignore_loglevel initcall_debug"
=> booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
```

Do the same with `/usb@fe800000` (dwc3_0) or `/ethernet@fe300000`. To test without the initramfs, use
`booti ${kernel_addr_r} - ${fdt_addr_r}`.

### Swapping U-Boot

Keep the same kernel, device tree and initramfs, but use a U-Boot already known to boot this board, for example
the U-Boot 2024.01 `u-boot-rockchip.bin` from the Home Assistant OS port. That tells a U-Boot handoff problem
apart from a kernel or device tree problem. The first partition of the Armbian image starts at 16 MiB, so a
bootloader written at 32 KiB fits:

```shell
xz -dk Armbian-unofficial_*_Mrk3399_*.img.xz
dd if=u-boot-rockchip.bin of=Armbian-unofficial_*_Mrk3399_*.img bs=1K seek=32 conv=notrunc
rkdeveloptool wl 0 Armbian-unofficial_*_Mrk3399_*.img
```

Or write only the bootloader, as in [Updating only U-Boot](flashing.md#updating-only-u-boot).

A U-Boot from elsewhere won't know Armbian's boot script conventions and may use a different baud rate (the
HAOS U-Boot uses 115200). Boot by hand:

```
=> load mmc 0:1 ${kernel_addr_r} /boot/Image
=> load mmc 0:1 ${fdt_addr_r} /boot/dtb/rockchip/rk3399-mrk3399.dtb
=> load mmc 0:1 ${ramdisk_addr_r} /boot/uInitrd
=> setenv bootargs "root=/dev/mmcblk0p1 rootwait earlycon=uart8250,mmio32,0xff1a0000 console=ttyS2,115200 ignore_loglevel"
=> booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
```

If that boots, the problem is on the U-Boot v2026.07 side. If it still hangs, it's the kernel or the device tree.

## Build problems

### `update-binfmts` fails, then `arch-test arm64` aborts the build

Armbian's Debian trixie build container registers qemu-user through `/usr/lib/binfmt.d/*.conf` and has no
`/usr/share/binfmts` entries, so the framework's `update-binfmts --enable qemu-aarch64` fails. On a host that
doesn't register qemu handlers itself (for example Manjaro without `qemu-user-static-binfmt`), `arch-test arm64`
then stops the build.

`userpatches/extensions/qemu-binfmt-register.sh` handles this and is enabled in `config-mrk3399.conf`. From the
`host_dependencies_ready` hook it writes the binfmt.d entries straight into `/proc/sys/fs/binfmt_misc/register`,
with flag `F`. The registration also applies to the host until reboot. If the host already has `qemu-aarch64`
registered, the extension does nothing.

### Downloads fail inside the container although the host has a proxy

The proxy is probably bound to `127.0.0.1`. See [Proxies and mirrors](../README.md#proxies-and-mirrors).

### The kernel source download is slow or keeps failing

The first build downloads a ~2.7 GB bare linux-stable repository from `ghcr.io/armbian/shallow/kernel-git`
(about 5 minutes at 100 Mbps; failed downloads are retried). With little bandwidth, add `KERNEL_GIT=shallow`
to `userpatches/config-mrk3399.conf`. That downloads a ~300 MB shallow repository containing only 6.18, which
has to be downloaded again when the kernel version changes. See also
[Kernel source cache](design.md#kernel-source-cache).

### U-Boot fetch fails with `REGIONAL_MIRROR=china`

The Gitee mirror didn't have the `v2026.07` tag yet. Use a proxy instead, or wait for the mirror to catch up.
