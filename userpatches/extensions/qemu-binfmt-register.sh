# Armbian's Debian trixie build container ships qemu-user with systemd-style
# /usr/lib/binfmt.d/*.conf files and no /usr/share/binfmts entries, so the
# framework's `update-binfmts --enable qemu-*` fails. On a host without its
# own qemu handlers (e.g. Manjaro without qemu-user-static-binfmt) the
# following `arch-test arm64` then aborts the build.
#
# Register the handlers straight from binfmt.d (flag F: the kernel opens the
# static qemu binary at registration time, so the handler keeps working for
# every chroot the build enters). This runs from host_dependencies_ready,
# which the framework calls before prepare_host_binfmt_qemu.

function host_dependencies_ready__register_qemu_binfmt_from_binfmt_d() {
	local name conf
	for name in qemu-arm qemu-aarch64 qemu-riscv64 qemu-loongarch64; do
		[[ -e "/proc/sys/fs/binfmt_misc/${name}" ]] && continue
		conf="/usr/lib/binfmt.d/${name}.conf"
		[[ -f "${conf}" ]] || continue
		if ! mountpoint -q /proc/sys/fs/binfmt_misc/; then
			mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc/ || {
				display_alert "qemu-binfmt-register" "cannot mount binfmt_misc, leaving it to the framework" "wrn"
				return 0
			}
		fi
		display_alert "qemu-binfmt-register" "registering ${name} from ${conf}" "info"
		if ! cat "${conf}" > /proc/sys/fs/binfmt_misc/register 2> /dev/null; then
			# "File exists": already registered on the host (e.g. by a previous build)
			[[ -e "/proc/sys/fs/binfmt_misc/${name}" ]] ||
				display_alert "qemu-binfmt-register" "registering ${name} failed" "wrn"
		fi
	done
	return 0
}
