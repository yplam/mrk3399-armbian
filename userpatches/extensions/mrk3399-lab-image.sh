# MRK3399 k8s lab image layout: a read-only squashfs root instead of
# Armbian's single ext4 partition. See "Image layout" in docs/k8s-lab.md.
#
#   offset 32 KiB   u-boot-rockchip.bin (written by Armbian, copied over)
#   p1 mrk-boot     ext4, MRK3399_BOOT_MIB     kernel, initrd, dtbs, boot.scr, armbianEnv.txt
#   p2 mrk-config   vfat, MRK3399_CONFIG_MIB   node.conf, authorized_keys; kept across reset and upgrade
#   p3 mrk-root     squashfs in a MRK3399_ROOT_MIB partition, sized for future images too
#   p4 mrk-data     created on the node at first boot, fills the eMMC (not in the image)
#
# Armbian still builds its usual ext4 image. While the finished rootfs is
# mounted (pre_umount_final_image) this stages /boot and packs the rest into a
# squashfs; once it's unmounted (post_umount_final_image) the raw image is
# replaced by one with the layout above. The partitions are built as files
# (mkfs.ext4 -d, mkfs.vfat + mtools) and copied in, so no loop devices are
# needed beyond Armbian's own.
#
# The boot and root partition images, the bootloader and a manifest also go
# to output/images/<version>.upgrade/, which U-Boot's run mrk_upgrade and
# run mrk_upgrade_uboot fetch over TFTP.

# Sizes in MiB. The config partition's position (right after boot) is what
# make node-image and U-Boot's upgrade commands (mmc 0:2) rely on; don't
# reorder the partitions.
declare -g MRK3399_BOOT_MIB="${MRK3399_BOOT_MIB:-256}"
declare -g MRK3399_CONFIG_MIB="${MRK3399_CONFIG_MIB:-32}"
declare -g MRK3399_ROOT_MIB="${MRK3399_ROOT_MIB:-2048}"
# Armbian's rockchip64 offset: GPT, then U-Boot from 32 KiB up to 16 MiB.
declare -g MRK3399_FIRST_PART_MIB=16
# run mrk_upgrade downloads root.squashfs and unzips boot.ext4 into RAM
# buffers of these sizes (mrk_root_max and mrk_boot_max in U-Boot's
# mrk3399.env).
declare -g MRK3399_UPGRADE_ROOT_MAX=$((2 * 1024 * 1024 * 1024))
declare -g MRK3399_UPGRADE_BOOT_MAX=$((256 * 1024 * 1024))

function add_host_dependencies__mrk3399_lab_image() {
	EXTRA_BUILD_DEPS+=("squashfs-tools" "mtools")
}

# The initramfs script (overlay/lab/rootfs/etc/initramfs-tools/scripts/
# local-bottom/mrk3399-lab) is a busybox sh script; a minimal image doesn't
# have busybox, and then the initramfs only gets klibc's few tools.
function extension_prepare_config__mrk3399_lab_image() {
	add_packages_to_image busybox
}

# Runs on the image rootfs right before Armbian builds the initramfs, so the
# lab hook and local-bottom script end up in it.
function pre_update_initramfs__mrk3399_lab_image() {
	local src="${USERPATCHES_PATH}/overlay/lab/rootfs"

	display_alert "mrk3399-lab-image" "preparing the rootfs for a read-only squashfs root" "info"

	# initramfs hook and script, mrk-node-config, mrk-reset. Owned by root and
	# not group/other-writable whoever owns the checkout and whatever its
	# umask; existing directories (/etc, ...) keep their modes. Everything
	# created below gets explicit modes for the same reason.
	run_host_command_logged "tar -C ${src} -cf - --owner=0 --group=0 --mode=go-w . | tar -C ${MOUNT} -xf - --no-overwrite-dir"
	install -d -m 0755 "${MOUNT}/etc/mrk3399"
	echo "DEFAULT_USER=${MRK3399_USER}" > "${MOUNT}/etc/mrk3399/lab.conf"
	chmod 0644 "${MOUNT}/etc/mrk3399/lab.conf"
	install -d -m 0755 "${MOUNT}/etc/systemd/system/sysinit.target.wants"
	ln -sf /etc/systemd/system/mrk-node-config.service \
		"${MOUNT}/etc/systemd/system/sysinit.target.wants/mrk-node-config.service"

	# The initramfs writes each node's machine-id from the config partition.
	# Should that fail, an empty file makes systemd generate one rather than
	# every node using the one baked into the image.
	: > "${MOUNT}/etc/machine-id"
	# Host keys would be the same on every node; mrk-node-config generates
	# them per node and keeps them on the config partition.
	rm -f "${MOUNT}"/etc/ssh/ssh_host_*
	# armbian-firstrun disables itself after one run. On an overlay root that
	# state is wiped by every reset, and each rerun replaces the host keys
	# mrk-node-config just restored. Nothing else it does applies here
	# (random MACs into the read-only armbianEnv.txt, Allwinner Wi-Fi).
	ln -sf /dev/null "${MOUNT}/etc/systemd/system/armbian-firstrun.service"
	# Armbian grows the root partition and filesystem on first boot. Neither
	# applies to a squashfs in a fixed-size partition.
	ln -sf /dev/null "${MOUNT}/etc/systemd/system/armbian-resize-filesystem.service"
	rm -f "${MOUNT}/root/.rootfs_resize"

	# The root is mounted by the initramfs; Armbian's UUID= entries for the
	# ext4 root (and /boot, if any) don't exist in this layout. /boot is
	# read-only: kernel updates come with a new image, not apt. The config and
	# data partitions are mounted by the initramfs under /run/mrk; /config
	# and the Kubernetes state directories are bind mounts from there.
	# containerd's overlayfs snapshotter can't use a directory on an overlay
	# root, and etcd wants its fsyncs on a real filesystem.
	sed -i -E '/^[^#[:space:]]+[[:space:]]+\/(boot)?[[:space:]]/d' "${MOUNT}/etc/fstab"
	cat <<- EOF >> "${MOUNT}/etc/fstab"
		PARTLABEL=mrk-boot /boot ext4 ro,nodev,nosuid,noexec 0 2
		/run/mrk/config /config none bind,nofail 0 0
		/run/mrk/data/containerd /var/lib/containerd none bind 0 0
		/run/mrk/data/kubelet /var/lib/kubelet none bind 0 0
		/run/mrk/data/etcd /var/lib/etcd none bind 0 0
	EOF
	install -d -m 0755 "${MOUNT}/config" "${MOUNT}/var/lib/containerd" "${MOUNT}/var/lib/kubelet"
	install -d -m 0700 "${MOUNT}/var/lib/etcd"
}

function pre_umount_final_image__mrk3399_lab_image() {
	local stage="${DESTIMG}/mrk3399-lab"

	run_host_command_logged rm -rf "${stage}"
	run_host_command_logged mkdir -p "${stage}/boot"

	# boot.scr builds root=${rootdev} rootfstype=${rootfstype} from this.
	sed -i -e '/^rootdev=/d' -e '/^rootfstype=/d' "${MOUNT}/boot/armbianEnv.txt"
	cat <<- EOF >> "${MOUNT}/boot/armbianEnv.txt"
		rootdev=PARTLABEL=mrk-root
		rootfstype=squashfs
	EOF

	# /boot goes into its own partition. The "boot -> ." link keeps paths of
	# the form /boot/... working from the partition root, as Armbian does for
	# its separate-/boot layouts.
	run_host_command_logged cp -a "${MOUNT}/boot/." "${stage}/boot/"
	[[ -e "${stage}/boot/boot" ]] || ln -s . "${stage}/boot/boot"

	display_alert "mrk3399-lab-image" "creating the squashfs root (zstd)" "info"
	# run_host_command_logged re-joins its arguments for bash -c, so the
	# exclude patterns need a second level of quoting to reach mksquashfs
	# unexpanded.
	run_host_command_logged mksquashfs "${MOUNT}" "${stage}/root.squashfs" \
		-noappend -one-file-system -xattrs -comp zstd -Xcompression-level 19 \
		-wildcards -e "'boot/*'" "'lost+found'" -quiet

	local root_bytes max_bytes
	root_bytes=$(stat -c %s "${stage}/root.squashfs")
	max_bytes=$((MRK3399_ROOT_MIB * 1024 * 1024))
	display_alert "mrk3399-lab-image" "squashfs root: $((root_bytes / 1024 / 1024)) MiB of ${MRK3399_ROOT_MIB} MiB" "info"
	if ((root_bytes > max_bytes)); then
		exit_with_error "mrk3399-lab-image: the squashfs root (${root_bytes} bytes) doesn't fit MRK3399_ROOT_MIB=${MRK3399_ROOT_MIB}"
	fi
	if ((root_bytes > MRK3399_UPGRADE_ROOT_MAX)); then
		exit_with_error "mrk3399-lab-image: the squashfs root (${root_bytes} bytes) is larger than run mrk_upgrade's RAM buffer (${MRK3399_UPGRADE_ROOT_MAX} bytes)"
	fi
}

function post_umount_final_image__mrk3399_lab_image() {
	local stage="${DESTIMG}/mrk3399-lab"
	local armbian_img="${SDCARD}.raw"
	local img="${stage}/image.raw"
	local config_src="${USERPATCHES_PATH}/overlay/lab/config"
	local boot_start=${MRK3399_FIRST_PART_MIB}
	local config_start=$((boot_start + MRK3399_BOOT_MIB))
	local root_start=$((config_start + MRK3399_CONFIG_MIB))
	# 1 MiB at the end for the backup GPT.
	local total=$((root_start + MRK3399_ROOT_MIB + 1))

	display_alert "mrk3399-lab-image" "building the boot and config partitions" "info"
	run_host_command_logged mkfs.ext4 -q -F -m 0 -O ^orphan_file -L mrk-boot \
		-d "${stage}/boot" "${stage}/boot.ext4" "${MRK3399_BOOT_MIB}M"
	# boot.ext4 is the whole partition, so this is MRK3399_BOOT_MIB.
	local boot_bytes
	boot_bytes=$(stat -c %s "${stage}/boot.ext4")
	if ((boot_bytes > MRK3399_UPGRADE_BOOT_MAX)); then
		exit_with_error "mrk3399-lab-image: the boot image (${boot_bytes} bytes, MRK3399_BOOT_MIB=${MRK3399_BOOT_MIB}) is larger than run mrk_upgrade's RAM buffer (${MRK3399_UPGRADE_BOOT_MAX} bytes)"
	fi

	run_host_command_logged rm -f "${stage}/config.vfat"
	run_host_command_logged mkfs.vfat -n MRKCONFIG -C "${stage}/config.vfat" $((MRK3399_CONFIG_MIB * 1024))
	run_host_command_logged MTOOLS_SKIP_CHECK=1 mcopy -i "${stage}/config.vfat" \
		"${config_src}/node.conf" "${config_src}/authorized_keys" "${config_src}/README.txt" ::/

	display_alert "mrk3399-lab-image" "assembling the image: boot ${MRK3399_BOOT_MIB}M, config ${MRK3399_CONFIG_MIB}M, root ${MRK3399_ROOT_MIB}M" "info"
	run_host_command_logged rm -f "${img}"
	run_host_command_logged truncate -s "${total}M" "${img}"

	# Partition type GUIDs: generic Linux data for boot and root (not the
	# "root-arm64" type, which systemd-gpt-auto-generator would act on), and
	# Microsoft basic data for config so desktop OSes mount it when the image
	# is opened there.
	sfdisk --quiet "${img}" <<- EOF
		label: gpt
		start=${boot_start}MiB, size=${MRK3399_BOOT_MIB}MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="mrk-boot"
		start=${config_start}MiB, size=${MRK3399_CONFIG_MIB}MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="mrk-config"
		start=${root_start}MiB, size=${MRK3399_ROOT_MIB}MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="mrk-root"
	EOF

	# Bootloader area: everything between the primary GPT and the first
	# partition, as Armbian wrote it (u-boot-rockchip.bin at 32 KiB).
	run_host_command_logged dd if="${armbian_img}" of="${img}" bs=32K skip=1 seek=1 \
		count=$(((boot_start * 1024 - 32) / 32)) conv=notrunc,sparse status=none
	run_host_command_logged dd if="${stage}/boot.ext4" of="${img}" bs=1M seek="${boot_start}" conv=notrunc,sparse status=none
	run_host_command_logged dd if="${stage}/config.vfat" of="${img}" bs=1M seek="${config_start}" conv=notrunc,sparse status=none
	run_host_command_logged dd if="${stage}/root.squashfs" of="${img}" bs=1M seek="${root_start}" conv=notrunc,sparse status=none

	run_host_command_logged sfdisk --list "${img}"

	# Network upgrade files: what U-Boot's upgrade commands fetch over TFTP,
	# under the names mrk3399.env gives them. See "Build output" in
	# docs/k8s-lab.md.
	local upgrade="${DESTIMG}/${version}.upgrade"
	run_host_command_logged mkdir -p "${upgrade}"
	run_host_command_logged cp "${stage}/boot.ext4" "${stage}/root.squashfs" "${upgrade}/"
	# The bootloader as built, from the same U-Boot package Armbian wrote
	# into the image (write_uboot_to_loop_image).
	run_host_command_logged dpkg -x "${DEB_STORAGE}/${image_artifacts_debs_reversioned["uboot"]}" "${stage}/uboot-deb"
	local uboot_bin
	uboot_bin=$(find "${stage}/uboot-deb" -name u-boot-rockchip.bin -print -quit)
	[[ -n "${uboot_bin}" ]] || exit_with_error "mrk3399-lab-image: no u-boot-rockchip.bin in the U-Boot package"
	# It goes from 32 KiB up to the first partition.
	local uboot_bytes uboot_max_bytes
	uboot_bytes=$(stat -c %s "${uboot_bin}")
	uboot_max_bytes=$((MRK3399_FIRST_PART_MIB * 1024 * 1024 - 32 * 1024))
	if ((uboot_bytes > uboot_max_bytes)); then
		exit_with_error "mrk3399-lab-image: u-boot-rockchip.bin (${uboot_bytes} bytes) doesn't fit before the first partition (${uboot_max_bytes} bytes)"
	fi
	run_host_command_logged cp "${uboot_bin}" "${upgrade}/u-boot-rockchip.bin"
	mrk3399_lab_write_manifest "${upgrade}"
	# boot.ext4 is mostly empty space. gzip, not zstd: U-Boot's unzip only
	# reads gzip.
	run_host_command_logged gzip -9 -n "${upgrade}/boot.ext4"
	# Armbian moves it with plain mv, which can't replace the non-empty
	# directory left by an earlier build of the same version.
	run_host_command_logged rm -rf "${FINALDEST:?}/${version}.upgrade"

	# Hand the new image to Armbian, which moves, checksums and compresses it.
	run_host_command_logged mv -f "${img}" "${armbian_img}"
	run_host_command_logged rm -rf "${stage}"
}

# The upgrade manifest: KEY=value lines, read by U-Boot's env import -t.
# <NAME>_SIZE and <NAME>_SHA256 are of the data as it is written to the eMMC
# (boot.ext4 before gzip, which U-Boot checks after unzip). Sizes are hex
# with 0x, as U-Boot's itest and setexpr read them. The file names are fixed
# in U-Boot's environment, so they are not listed. Called before boot.ext4
# is compressed.
function mrk3399_lab_write_manifest() {
	local dir="$1" entry key file
	{
		echo "# MRK3399 upgrade manifest, written by the build. See docs/k8s-lab.md."
		echo "VERSION=${version}"
		for entry in BOOT:boot.ext4 ROOT:root.squashfs UBOOT:u-boot-rockchip.bin; do
			key="${entry%%:*}" file="${entry#*:}"
			printf '%s_SIZE=0x%x\n' "${key}" "$(stat -c %s "${dir}/${file}")"
			echo "${key}_SHA256=$(sha256sum "${dir}/${file}" | cut -d' ' -f1)"
		done
	} > "${dir}/manifest"
	run_host_command_logged cat "${dir}/manifest"
}
