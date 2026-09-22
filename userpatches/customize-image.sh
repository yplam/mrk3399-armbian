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

# Set in userpatches/config-mrk3399.conf, which exports them into this chroot.
# Fail loudly rather than silently building an image with no account in it.
: "${MRK3399_USER:?not set, see the unattended first boot block in userpatches/config-mrk3399.conf}"
: "${MRK3399_USER_PASSWORD:?not set, see the unattended first boot block in userpatches/config-mrk3399.conf}"
: "${MRK3399_USER_REALNAME:?not set, see the unattended first boot block in userpatches/config-mrk3399.conf}"
: "${MRK3399_TIMEZONE:?not set, see the unattended first boot block in userpatches/config-mrk3399.conf}"

Main() {
	CreateUser
	SetTimezone
	InstallUsbGadget
	SkipFirstLoginWizard
} # Main

# Everything Armbian's first-login wizard would ask for, done at build time.
# See docs/design.md, "Unattended first boot".

# Mirrors add_user() in /usr/lib/armbian/armbian-firstlogin without the
# prompts: useradd rather than adduser (adduser is optional on minimal
# images), the same supplementary groups, then the password.
CreateUser() {
	local user="${MRK3399_USER}" group

	echo "mrk3399: creating the ${user} account"
	useradd --create-home --home-dir "/home/${user}" --shell /bin/bash \
		--comment "${MRK3399_USER_REALNAME}" --user-group "${user}"
	echo "${user}:${MRK3399_USER_PASSWORD}" | chpasswd

	for group in sudo netdev audio video disk tty users games dialout plugdev \
		input bluetooth systemd-journal ssh render; do
		# A minimal image doesn't have all of them.
		if getent group "${group}" > /dev/null; then
			usermod -aG "${group}" "${user}"
		fi
	done
} # CreateUser

# The rootfs was built with the build host's timezone (main-config.sh reads
# /etc/timezone and overwrites TZDATA, so the board config can't set it).
SetTimezone() {
	local tz="${MRK3399_TIMEZONE}"

	if [ ! -f "/usr/share/zoneinfo/${tz}" ]; then
		echo "mrk3399: MRK3399_TIMEZONE=${tz} is not a known timezone" >&2
		exit 1
	fi

	echo "mrk3399: setting the timezone to ${tz}"
	echo "${tz}" > /etc/timezone
	ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
	dpkg-reconfigure -f noninteractive tzdata > /dev/null 2>&1
} # SetTimezone

# /root/.not_logged_in_yet makes /etc/profile.d/armbian-check-first-login.sh
# run the wizard at the first root login. Everything it configures is already
# in place, so drop the marker -- along with the two side effects nothing else
# performs: the build strips +x from the motd scripts and comments out the
# sshd AcceptEnv line, and the wizard is what restores both.
SkipFirstLoginWizard() {
	echo "mrk3399: disabling the Armbian first-login wizard"
	chmod +x /etc/update-motd.d/*
	if [ -f /etc/ssh/sshd_config ]; then
		sed -Ei '/^[[:blank:]]*#[[:blank:]]*AcceptEnv[[:blank:]]+LANG/ s/^[[:blank:]]*#[[:blank:]]*//' \
			/etc/ssh/sshd_config
	fi
	rm -f /root/.not_logged_in_yet
} # SkipFirstLoginWizard

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
