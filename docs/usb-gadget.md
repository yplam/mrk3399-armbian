# USB gadget on the OTG port

The board's OTG connector — the one the BootROM uses for maskrom mode — runs as a **USB device** under
Linux. Plug it into a PC and you get a network link and a login console over the one cable, without
the serial adapter and without the 100M Ethernet port.

```
PC                                          MRK3399
  |                                            |
  |--- CDC-NCM / RNDIS ---> 10.55.0.1  usb0 ---|   ssh, scp, sftp, rsync
  |--- CDC-ACM --------------> /dev/ttyGS0 ----|   login console
```

## Why it's this port

The RK3399 has two USB 3.0 dual-role controllers. Controller 1 (`usbdrd3_1`) needs `tcphy1`, which is
disabled on this board, so it never finishes probing. That leaves controller 0 (`usbdrd3_0` /
`usbdrd_dwc3_0`, with `u2phy0_otg` for USB 2.0 and `tcphy0_usb3` for SuperSpeed) — which is also the port
the BootROM enumerates on in maskrom mode, as `2207:330c`. The two type-A ports are on
`usb_host0_*` / `usb_host1_*` and are unaffected by any of this.

## Using it

The board is **10.55.0.1**. It runs a one-lease DHCP server that hands the PC **10.55.0.2**, so from the
PC, once the cable is in:

```shell
ssh root@10.55.0.1
scp somefile root@10.55.0.1:/root/
rsync -a ./dir/ root@10.55.0.1:/srv/dir/
sshfs root@10.55.0.1:/ /mnt/mrk3399      # if you'd rather browse it
```

And the console, on the same cable:

```shell
picocom -b 115200 /dev/ttyACM0     # the baud rate is ignored on a gadget serial port
```

On Linux the interface shows up as something like `enp0s20u1` or `usb0` and NetworkManager picks up the
DHCP lease on its own. On Windows 11 the CDC-NCM driver is built in; Windows 10 and older get RNDIS
instead (see [Host support](#host-support)). On macOS, CDC-NCM works out of the box.

This is a plain point-to-point link: no default route and no DNS server are handed out, on purpose. The
PC keeps using its normal network for everything outside `10.55.0.0/29`.

## What's installed

| Path                                               | What it is                                                     |
| -------------------------------------------------- | --------------------------------------------------------------- |
| `/usr/local/sbin/mrk3399-usb-gadget`               | builds and tears down the configfs gadget                       |
| `/etc/default/mrk3399-usb-gadget`                  | which functions to expose, IDs, MACs                            |
| `/etc/systemd/system/mrk3399-usb-gadget.service`   | runs the script at boot; enabled by default                     |
| `/etc/systemd/network/05-mrk3399-usb-gadget.network` | addresses `usb0` and serves DHCP to the PC                    |
| `/etc/modules-load.d/mrk3399-usb-gadget.conf`      | loads `libcomposite` early                                      |

They're installed from `userpatches/overlay/usb-gadget/` by `userpatches/customize-image.sh`.

## Configuring it

Edit `/etc/default/mrk3399-usb-gadget` and `systemctl restart mrk3399-usb-gadget`. To turn the gadget
off without changing the device tree:

```shell
sudo systemctl disable --now mrk3399-usb-gadget
```

To change the addresses, edit `/etc/systemd/network/05-mrk3399-usb-gadget.network` and
`systemctl restart systemd-networkd`. `PoolOffset=2 PoolSize=1` means the single DHCP lease offered is
the subnet base plus two, so a `10.55.0.1/29` board address pairs with a `10.55.0.2` PC address.

Armbian renders the wired interfaces from Netplan (`/etc/netplan/10-dhcp-all-interfaces.yaml`) whose
matches are `e*`, `lan*` and `wan*`. `usb0` matches none of them, so the two don't collide.

## Adding functions

The script builds two configurations with configfs, so adding a function is a matter of creating its
directory and symlinking it into a config. Everything below is already in the kernel as a module
(`CONFIG_USB_F_MASS_STORAGE`, `CONFIG_USB_F_FS`, …) — no kernel rebuild needed.

**Mass storage**, for drag-and-drop without networking. Back it with a file, never the root filesystem:
the host gets block-level access, so the board must not have it mounted read-write at the same time.

```shell
fallocate -l 2G /var/lib/usb-share.img
mkfs.vfat /var/lib/usb-share.img
```

then in the script, alongside the other functions:

```shell
mkdir -p functions/mass_storage.0
printf '%s' /var/lib/usb-share.img > functions/mass_storage.0/lun.0/file
printf '%s' 1 > functions/mass_storage.0/lun.0/removable
ln -s ../../functions/mass_storage.0 configs/c.1/mass_storage.0
```

**adb** would need `adbd` on the board. Debian bookworm ships the host-side `adb` and `fastboot` but no
`adbd` package, so it would have to be built and vendored into the image. `ssh`, `scp` and `rsync` over
the link above cover what `adb shell`, `adb push` and `adb pull` do.

## Host support

| Host                     | Uses                          | Notes                                              |
| ------------------------ | ----------------------------- | -------------------------------------------------- |
| Linux                    | CDC-NCM (configuration 1)     | `cdc_ncm` is in every mainstream kernel            |
| macOS                    | CDC-NCM (configuration 1)     | built in                                           |
| Windows 11               | CDC-NCM (configuration 1)     | built in since 21H2                                |
| Windows 10 and older     | RNDIS (configuration 2)       | selected by the MS OS descriptors the script sets  |

Hosts pick the first configuration unless told otherwise, which is why CDC is `c.1`. Windows asks the
device for Microsoft OS descriptors; the script answers with a pointer to `c.2` and the `RNDIS` /
`5162001` compatible IDs, so Windows loads its own RNDIS driver and selects that configuration. Set
`USB_GADGET_RNDIS=no` if you never use Windows and would rather present a single configuration.

## In U-Boot

The same port serves `rockusb` and `ums` from the U-Boot prompt, which is what
[loader mode](flashing.md#getting-into-maskrom-or-loader-mode) uses:

```
=> rockusb 0 mmc 0       # board appears to rkdeveloptool in Loader mode
=> ums 0 mmc 0           # board appears as a USB disk (the whole eMMC)
```

This needs `dr_mode` to not be `"host"` in U-Boot's device tree too, which
`userpatches/u-boot/v2026.07/dt_uboot/rk3399-rock-pi-4a-u-boot.dtsi` takes care of. See
[Design](design.md#usb-and-the-otg-port).

> [!WARNING]
> `ums 0 mmc 0` exports the running system's eMMC as a raw disk. Writing to it from the PC while U-Boot
> holds it is fine — nothing else is running — but don't resume booting afterwards without a reset.

## Troubleshooting

**`systemctl status mrk3399-usb-gadget` says no UDC appeared.** The device tree is still building the
port as a host. Check it on the board:

```shell
ls /sys/class/udc                                             # expect: fe800000.usb
fdtget /boot/dtb/rockchip/rk3399-mrk3399.dtb /usb@fe800000/usb@fe800000 dr_mode
```

If that prints `host`, the running kernel is from before this change — reflash, or at least reinstall
the `linux-dtb-current-rockchip64` package.

**The gadget binds but the PC sees nothing.** The PC supplies VBUS on this port; a charge-only cable has
no data pairs. Try another cable first. `dmesg | grep dwc3` on the board should show the gadget
registering, and the `otg-bvalid` interrupt firing when the cable goes in.

**The link is up but `usb0` has no address.** `networkctl status usb0` shows whether the `.network` file
matched. If the interface came up under a different name, adjust the `[Match] Name=` in
`/etc/systemd/network/05-mrk3399-usb-gadget.network`.

**No login prompt on `/dev/ttyACM0`.** `systemctl status serial-getty@ttyGS0` on the board. Root logins
need `ttyGS0` in `/etc/securetty`, which the image adds; a non-root user works regardless.
