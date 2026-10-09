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
: "${MRK3399_K8S_VERSION:?not set, see the Kubernetes block in userpatches/config-mrk3399.conf}"
: "${MRK3399_K8S_APT_URL:?not set, see the Kubernetes block in userpatches/config-mrk3399.conf}"
: "${MRK3399_DOCKER_APT_URL:?not set, see the Kubernetes block in userpatches/config-mrk3399.conf}"

Main() {
	CreateUser
	SetTimezone
	InstallUsbGadget
	InstallKubernetes
	DisableSwap
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

# A kubeadm-ready node: containerd with the systemd cgroup driver, kubeadm,
# kubelet and kubectl from pkgs.k8s.io, and the kernel modules and sysctls
# kubeadm's preflight wants. No cluster is configured; kubelet restarts in a
# loop until kubeadm init or join gives it a config, as on any kubeadm node.
InstallKubernetes() {
	local src="${OVERLAY}/k8s"
	local k8s_repo="${MRK3399_K8S_APT_URL}/v${MRK3399_K8S_VERSION}/deb/"
	local arch codename

	arch=$(dpkg --print-architecture)
	codename=$(. /etc/os-release && echo "${VERSION_CODENAME}")

	echo "mrk3399: installing containerd and Kubernetes v${MRK3399_K8S_VERSION}"

	# Both keys are ASCII-armoured; apt reads .asc keyrings directly, so
	# gnupg doesn't have to be in the image.
	install -d -m 0755 /etc/apt/keyrings
	curl -fsSL "${MRK3399_K8S_APT_URL}/v${MRK3399_K8S_VERSION}/deb/Release.key" \
		-o /etc/apt/keyrings/kubernetes.asc
	curl -fsSL "${MRK3399_DOCKER_APT_URL}/gpg" -o /etc/apt/keyrings/docker.asc
	echo "deb [signed-by=/etc/apt/keyrings/kubernetes.asc] ${k8s_repo} /" \
		> /etc/apt/sources.list.d/kubernetes.list
	echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] ${MRK3399_DOCKER_APT_URL} ${codename} stable" \
		> /etc/apt/sources.list.d/docker.list

	apt-get update
	# conntrack, socat, ethtool: kubeadm preflight. ipset: kube-proxy in
	# IPVS mode and most CNIs' network policy.
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		containerd.io kubelet kubeadm kubectl kubernetes-cni cri-tools \
		iptables conntrack socat ethtool ipset
	apt-mark hold kubelet kubeadm kubectl

	local installed
	installed=$(dpkg-query -W -f='${Version}' kubeadm)
	case "${installed}" in
		"${MRK3399_K8S_VERSION}".*) ;;
		*)
			echo "mrk3399: kubeadm ${installed} is not from the v${MRK3399_K8S_VERSION} line" >&2
			exit 1
			;;
	esac

	# containerd.io ships a config.toml with the CRI plugin disabled (it's
	# packaged for Docker). Replace it with the full default and switch runc
	# to the systemd cgroup driver, which kubelet uses by default.
	containerd config default > /etc/containerd/config.toml
	if ! grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
		echo "mrk3399: no SystemdCgroup setting in containerd's default config, check its format" >&2
		exit 1
	fi
	sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

	install -m 0644 -D "${src}/etc/modules-load.d/mrk3399-k8s.conf" /etc/modules-load.d/mrk3399-k8s.conf
	install -m 0644 -D "${src}/etc/sysctl.d/90-mrk3399-k8s.conf" /etc/sysctl.d/90-mrk3399-k8s.conf
	install -m 0644 -D "${src}/etc/crictl.yaml" /etc/crictl.yaml
	install -m 0644 -D "${src}/etc/systemd/system/kubelet.service.d/10-mrk3399-time-sync.conf" \
		/etc/systemd/system/kubelet.service.d/10-mrk3399-time-sync.conf

	# Hold time-sync.target until timesyncd has a real time, so kubelet
	# (ordered after it) doesn't start with a 1970 or stale clock.
	systemctl enable systemd-time-wait-sync.service
	systemctl enable containerd.service kubelet.service

	echo "mrk3399: installed kubeadm ${installed}, containerd $(dpkg-query -W -f='${Version}' containerd.io)"
} # InstallKubernetes

# kubelet refuses to start while swap is on (failSwapOn defaults to true).
# Armbian's only swap is the zram device armbian-zram-config sets up; keep the
# service, which also provides the zram /var/log for armbian-ramlog, and turn
# off just its swap.
DisableSwap() {
	local conf=/etc/default/armbian-zram-config

	echo "mrk3399: disabling zram swap"
	# The BSP postinst normally put it in place already. A file holding only
	# SWAP=false would also turn the service off (ENABLED defaults to false).
	if [ ! -f "${conf}" ] && [ -f "${conf}.dpkg-dist" ]; then
		cp "${conf}.dpkg-dist" "${conf}"
	fi
	if [ -f "${conf}" ] && grep -Eq '^[[:blank:]]*#?[[:blank:]]*SWAP=' "${conf}"; then
		sed -Ei 's/^[[:blank:]]*#?[[:blank:]]*SWAP=.*/SWAP=false/' "${conf}"
	else
		echo "SWAP=false" >> "${conf}"
	fi
} # DisableSwap

Main "$@"
