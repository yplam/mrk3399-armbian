#!/bin/bash
#
# Image customization for the MRK3399 port. Armbian copies this into the image
# and runs it inside the chroot, with userpatches/overlay/ bind-mounted
# read-only at /tmp/overlay.
#
# arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP $ARCH

set -euo pipefail

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4

OVERLAY=/tmp/overlay

Main() {
	InstallUsbGadget
} # Main

# Composite USB gadget on the OTG port: a network link (CDC-NCM, with RNDIS for
# older Windows) plus a serial console. Needs dr_mode = "peripheral" on
# &usbdrd_dwc3_0, which userpatches/kernel/.../rk3399-mrk3399.dts sets.
# See docs/usb-gadget.md.
InstallUsbGadget() {
	local src="${OVERLAY}/usb-gadget"

	echo "mrk3399: installing the USB gadget files"
	install -m 0755 -D "${src}/usr/local/sbin/mrk3399-usb-gadget" /usr/local/sbin/mrk3399-usb-gadget
	install -m 0644 -D "${src}/etc/default/mrk3399-usb-gadget" /etc/default/mrk3399-usb-gadget
	install -m 0644 -D "${src}/etc/systemd/system/mrk3399-usb-gadget.service" /etc/systemd/system/mrk3399-usb-gadget.service
	install -m 0644 -D "${src}/etc/systemd/network/05-mrk3399-usb-gadget.network" /etc/systemd/network/05-mrk3399-usb-gadget.network

	# libcomposite is a module; the gadget script modprobes it, but loading it
	# early keeps /sys/class/udc populated before the unit runs.
	echo "libcomposite" > /etc/modules-load.d/mrk3399-usb-gadget.conf

	# pam_securetty refuses a root login on a tty that isn't listed here, and
	# Debian's list has no gadget serial port.
	if [ -f /etc/securetty ] && ! grep -qx "ttyGS0" /etc/securetty; then
		echo "ttyGS0" >> /etc/securetty
	fi

	systemctl enable mrk3399-usb-gadget.service
} # InstallUsbGadget

Main "$@"
