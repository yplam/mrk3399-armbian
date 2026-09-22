# Armbian for MRK3399

Build scripts and board support for running [Armbian](https://www.armbian.com/) (Debian bookworm, minimal CLI)
on the **MRK3399**, an RK3399 board with 4 GB LPDDR4, eMMC, two USB host ports, an OTG port and 100M Ethernet.

This repo does not fork [armbian/build](https://github.com/armbian/build). It pins a known-good commit of it
and adds the board through Armbian's `userpatches` mechanism, so building an image is: clone, `make build`, flash.

| Component | Version                                                          |
| --------- | ---------------------------------------------------------------- |
| Kernel    | 6.18 (Armbian `current`, `rockchip64` family)                    |
| U-Boot    | v2026.07, mainline TPL + SPL + ATF, no Rockchip binary blobs     |
| Userspace | Debian 12 bookworm, minimal                                      |
| Console   | `ttyS2`, 1500000 8N1                                             |

> These are unofficial images (`Armbian-unofficial_*`). The MRK3399 is not an Armbian-supported board,
> so report problems here rather than on the Armbian forums.

## Hardware

| Part        | Details                                                              |
| ----------- | -------------------------------------------------------------------- |
| SoC         | Rockchip RK3399 (2× Cortex-A72 + 4× Cortex-A53)                      |
| RAM         | 4 GB LPDDR4                                                          |
| Storage     | eMMC                                                                 |
| Ethernet    | 100M, RMII, RTL8201F PHY                                             |
| USB         | 2× host ports, plus the OTG / flashing port ([USB gadget](docs/usb-gadget.md)) |
| Power       | RK808 PMIC + SYR827 / SYR828, the same power tree as the Radxa Rock Pi 4 |
| Not present | SD card slot, PCIe, HDMI, Wi-Fi                                      |


## Requirements

- An x86_64 Linux host with **Docker**, `git` and `make`. Armbian relaunches itself inside a Docker
  container, so the host distribution matters little.
- About **50 GB** of free disk space. The download and compile caches reach about 22 GB after one build.
- A reasonable network connection. The first build downloads a ~2.7 GB kernel git bundle plus the
  Debian packages and took about 75 minutes; later builds reuse the caches.
- For flashing: [`rkdeveloptool`](https://github.com/rockchip-linux/rkdeveloptool) and a USB cable to the
  board's flashing (OTG) port. See [docs/flashing.md](docs/flashing.md).
- For running: a **5 V / 3 A** power supply and a 3.3 V USB-serial adapter.

> [!WARNING]
> Don't power the board from a PC USB port. It browns out during kernel boot and just stops, with no error
> on the serial console. See [Power supply](docs/troubleshooting.md#power-supply).

## Build

```shell
git clone https://github.com/yplam/mrk3399-armbian.git mrk3399-armbian
cd mrk3399-armbian
make build
```

`make build` clones armbian/build into `build/` at the pinned commit, links `userpatches/` into it and runs
`./compile.sh mrk3399`. The image lands in `build/output/images/`:

```
Armbian-unofficial_<version>_Mrk3399_bookworm_current_<kernel>_minimal.img.xz
Armbian-unofficial_<version>_Mrk3399_bookworm_current_<kernel>_minimal.img.xz.sha
Armbian-unofficial_<version>_Mrk3399_bookworm_current_<kernel>_minimal.img.txt
```

### Make targets

| Target        | What it does                                                                         |
| ------------- | ------------------------------------------------------------------------------------ |
| `make setup`  | Clone armbian/build into `build/` at the pinned commit and link `userpatches/` in    |
| `make build`  | Build the full image (runs `setup` first)                                            |
| `make uboot`  | Build only the U-Boot package, into `build/output/debs/`                             |
| `make kernel` | Build only the kernel packages, into `build/output/debs/`                            |
| `make clean`  | Delete built images and packages; the download and compile caches are kept           |

### Options

| Variable                     | Default           | Effect                                                                                   |
| ---------------------------- | ----------------- | ---------------------------------------------------------------------------------------- |
| `DEBUG=yes`                  | `no`              | Bring-up boot environment: earlycon and `verbosity=7` in `/boot/armbianEnv.txt`. Only affects `make build`. |
| `PROXY_HOST=<ip>`            | empty             | Rewrite `127.0.0.1` in `http_proxy` / `https_proxy` so the build container can reach a host proxy |
| `REVISION=<version>`         | armbian/build's `VERSION` | Version in the image and package names; must start with a digit                   |
| `ARMBIAN_BUILD_COMMIT=<sha>` | pinned in Makefile | armbian/build commit to check out (see [Upgrading armbian/build](docs/design.md#upgrading-armbianbuild)) |

Image contents (Debian release, minimal vs. full, compression) are set in
[`userpatches/config-mrk3399.conf`](userpatches/config-mrk3399.conf). Only the defaults there have been tested.

### Proxies and mirrors

Armbian passes `http_proxy` / `https_proxy` into its build container, where `127.0.0.1` is the container
itself. Make the proxy listen on all interfaces (for example Clash's `allow-lan`) and tell the Makefile an
address the container can reach, either the host's LAN IP or the Docker bridge gateway:

```shell
export http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890
make build PROXY_HOST=172.17.0.1
```

Without a proxy in mainland China, uncomment `REGIONAL_MIRROR=china` in `userpatches/config-mrk3399.conf`.
It sends kernel, firmware and apt to TUNA, U-Boot to Gitee, other GitHub downloads to ghfast.top and ghcr.io to NJU.
When this port was built, the Gitee U-Boot mirror didn't have the `v2026.07` tag yet and the build failed there,
so a proxy is the more reliable route. Don't combine the two.

### Releases

Prebuilt images are on the [Releases](https://github.com/yplam/mrk3399-armbian/releases) page. They're built by
the [`Release image`](.github/workflows/release.yml) workflow, which is started by hand from the Actions tab. It runs
`make build` on a GitHub-hosted runner and publishes the `.img.xz`, `.sha` and `.img.txt` as a release tagged with
the UTC build date, for example `2026.09.14` (a second build that day becomes `2026.09.14.2`). The tag is passed as
`REVISION`, so it's also the version in the image name. Armbian has no cached kernel or U-Boot for this board, so
each run compiles both and takes about 2 hours. If the build fails, its logs are attached to the run as `build-logs`.

## Flash

The image is a whole-disk image for the eMMC. With the board in maskrom or loader mode:

```shell
xz -dk build/output/images/Armbian-unofficial_*_Mrk3399_*_minimal.img.xz
rkdeveloptool db rk3399_loader_v1.30.130.bin    # maskrom mode only
rkdeveloptool wl 0 build/output/images/Armbian-unofficial_*_Mrk3399_*_minimal.img
rkdeveloptool rd
```

[docs/flashing.md](docs/flashing.md) covers getting the loader file, entering maskrom or loader mode, and
updating only U-Boot.

## First boot

Connect the serial console (`ttyS2`, 1500000 8N1, for example `picocom -b 1500000 /dev/ttyUSB0`) and power the
board from a 5 V / 3 A supply. U-Boot waits 2 seconds for a key press, then boots. The root filesystem grows to
fill the eMMC, and a login prompt appears — Armbian's first-login wizard is preconfigured away, so nothing asks
for a password, a locale or a timezone.

| | |
| --- | --- |
| User | `mrk` / `mrk3399`, in `sudo` |
| Root | `root` / `mrk3399` |
| Locale, timezone | `en_US.UTF-8`, `Asia/Shanghai` |

Change them in the "Unattended first boot" block of `userpatches/config-mrk3399.conf`, or per build:

```shell
make build ARGS='MRK3399_USER=me MRK3399_USER_PASSWORD=secret MRK3399_TIMEZONE=Etc/UTC'
```

The passwords are baked into the image and written to the build log, so build your own image before putting a
board on an untrusted network. [docs/design.md](docs/design.md#unattended-first-boot) explains how it works.

## USB gadget

The OTG port — the same connector used for flashing — runs as a USB device. Plug it into a PC and you get a
network link and a login console over the one cable:

```shell
ssh root@10.55.0.1            # the board; it hands the PC 10.55.0.2 over DHCP
scp somefile root@10.55.0.1:/root/
picocom -b 115200 /dev/ttyACM0
```

CDC-NCM on Linux, macOS and Windows 11; RNDIS on older Windows. Configure it in
`/etc/default/mrk3399-usb-gadget`, or turn it off with
`systemctl disable --now mrk3399-usb-gadget`. See [docs/usb-gadget.md](docs/usb-gadget.md).

## Repository layout

```
mrk3399-armbian/
├── .github/workflows/release.yml # manual workflow: build the image and publish a release
├── Makefile                      # setup / build / uboot / kernel / clean
├── docs/
│   ├── design.md                 # how the port works, boot chain, device tree, USB, upgrading armbian/build
│   ├── flashing.md               # loader, maskrom / loader mode, rkdeveloptool
│   ├── troubleshooting.md        # power supply, silent hangs, build problems
│   ├── usb-gadget.md             # the OTG port as a USB device: network link and console
│   └── uboot-board-support.md    # optional: a dedicated U-Boot defconfig and device tree
├── userpatches/                  # linked into build/userpatches
│   ├── config-mrk3399.conf       # build parameters for ./compile.sh mrk3399
│   ├── config/boards/mrk3399.csc # board definition
│   ├── customize-image.sh        # installs the USB gadget into the image
│   ├── overlay/usb-gadget/       # the gadget script, its config, systemd unit and .network file
│   ├── bootenv/                  # /boot/armbianEnv.txt: mrk3399.txt, mrk3399-debug.txt
│   ├── extensions/               # qemu-binfmt-register.sh
│   ├── u-boot/v2026.07/dt_uboot/ # U-Boot DT override: OTG port as a gadget, for rockusb / ums
│   └── kernel/archive/rockchip64-6.18/dt/rk3399-mrk3399.dts
└── build/                        # armbian/build clone (created by make setup, git-ignored)
```

## License

[GPL-2.0](LICENSE), the same license as armbian/build. The device tree is `GPL-2.0+ OR MIT`, as stated in its SPDX header.
