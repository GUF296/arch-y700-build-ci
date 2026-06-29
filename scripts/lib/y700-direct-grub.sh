#!/usr/bin/env bash

# Shared GRUB helpers for the daily direct-boot payload.
# shellcheck shell=bash

Y700_GRUB_BUILD_DIR=${Y700_GRUB_BUILD_DIR:-/home/guf296/tb321fu-current/grub2-ram-partition-ab/build-arm64-efi}
Y700_DIRECT_BOOT_EFI_NAME=${Y700_DIRECT_BOOT_EFI_NAME:-QCOMRAMP.EFI}
Y700_DIRECT_BOOT_RESERVED_MEMORY=${Y700_DIRECT_BOOT_RESERVED_MEMORY:-"/reserved-memory/qdss@82800000 /reserved-memory/splash-region /reserved-memory/trust-ui-vm@f3800000 /reserved-memory/oem-vm@f7c00000"}

y700_write_direct_grub_cfg() {
	local cfg=$1
	local dtb_name=$2
	local rootargs=$3
	local stableargs=$4
	local reserved_line="qcomfdtmem disable-reserved"
	local path

	for path in $Y700_DIRECT_BOOT_RESERVED_MEMORY; do
		reserved_line="$reserved_line $path"
	done

	cat > "$cfg" <<EOF
set timeout=0
set default=0
set gfxpayload=keep

menuentry "Qualcomm direct boot (RamPartition memory)" {
    search --no-floppy --file /Image --set=root
    devicetree /dtb/$dtb_name
    qcomfdtmem source rampartition
    $reserved_line
    linuxdirect /Image $rootargs $stableargs
}
EOF
}

y700_write_outer_grub_cfg() {
	local cfg=$1
	local timeout=$2
	local direct_efi_name=$3

	cat > "$cfg" <<EOF
set timeout=$timeout
set default=0
set gfxpayload=keep

search --no-floppy --file /Image --set=root

menuentry "Continue boot" {
    search --no-floppy --file /Image --set=root
    chainloader /EFI/BOOT/$direct_efi_name
    boot
}

menuentry "Reboot" {
    reboot
}

menuentry "Power off" {
    halt
}
EOF
}

y700_build_direct_grub_efi() {
	local embedded_cfg=$1
	local out_efi=$2

	[ -x "$Y700_GRUB_BUILD_DIR/grub-mkstandalone" ] ||
		die "missing GRUB direct-boot build: $Y700_GRUB_BUILD_DIR/grub-mkstandalone"
	[ -d "$Y700_GRUB_BUILD_DIR/grub-core" ] ||
		die "missing GRUB module directory: $Y700_GRUB_BUILD_DIR/grub-core"

	"$Y700_GRUB_BUILD_DIR/grub-mkstandalone" \
		-d "$Y700_GRUB_BUILD_DIR/grub-core" \
		-O arm64-efi \
		-o "$out_efi" \
		--locales= \
		--fonts= \
		--themes= \
		--modules="normal linuxdirect fdt fat part_gpt search search_fs_file reboot halt sleep rampartition" \
		"/boot/grub/grub.cfg=$embedded_cfg"
}

y700_stage_direct_grub_payload() {
	local out_dir=$1
	local dtb_name=$2
	local timeout=$3
	local rootargs=$4
	local stableargs=$5
	local direct_cfg="$out_dir/.QCOMRAMP-grub.cfg.tmp"
	local outer_cfg="$out_dir/grub.cfg"
	local direct_efi="$out_dir/$Y700_DIRECT_BOOT_EFI_NAME"

	y700_write_direct_grub_cfg "$direct_cfg" "$dtb_name" "$rootargs" "$stableargs"
	y700_build_direct_grub_efi "$direct_cfg" "$direct_efi"
	rm -f "$direct_cfg"
	y700_write_outer_grub_cfg "$outer_cfg" "$timeout" "$Y700_DIRECT_BOOT_EFI_NAME"
}
