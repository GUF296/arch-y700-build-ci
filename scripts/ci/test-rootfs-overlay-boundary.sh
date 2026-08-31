#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

scratch=$(mktemp -d)
cleanup() {
  case $scratch in /tmp/tmp.*) rm -rf -- "$scratch" ;; esac
}
trap cleanup EXIT INT TERM

mkdir -p "$scratch/safe/etc"
ci_validate_rootfs_overlay_tree "$scratch/safe"

ln -s "$scratch/safe" "$scratch/root-link"
if (ci_validate_rootfs_overlay_tree "$scratch/root-link") >/dev/null 2>&1; then
  printf 'overlay root symlink was accepted\n' >&2
  exit 1
fi

mkdir -p "$scratch/ancestor-target/real-leaf"
ln -s "$scratch/ancestor-target" "$scratch/ancestor-link"
if (ci_validate_rootfs_overlay_tree "$scratch/ancestor-link/real-leaf") >/dev/null 2>&1; then
  printf 'overlay symlink ancestor was accepted\n' >&2
  exit 1
fi

mkfifo "$scratch/safe/fifo"
if (ci_validate_rootfs_overlay_tree "$scratch/safe") >/dev/null 2>&1; then
  printf 'overlay special file was accepted\n' >&2
  exit 1
fi
rm -f "$scratch/safe/fifo"

install -m 0644 /dev/null "$scratch/safe/hardlink-source"
ln "$scratch/safe/hardlink-source" "$scratch/safe/hardlink-copy"
if (ci_validate_rootfs_overlay_tree "$scratch/safe") >/dev/null 2>&1; then
  printf 'overlay hard-linked file was accepted\n' >&2
  exit 1
fi
rm -f "$scratch/safe/hardlink-source" "$scratch/safe/hardlink-copy"

install -m 0644 /dev/null "$scratch/safe/setuid-file"
chmod 4644 "$scratch/safe/setuid-file"
if (ci_validate_rootfs_overlay_tree "$scratch/safe") >/dev/null 2>&1; then
  printf 'overlay setuid file was accepted\n' >&2
  exit 1
fi
rm -f "$scratch/safe/setuid-file"

fake_bin="$scratch/fake-bin"
install -D -m 0755 /dev/stdin "$fake_bin/findmnt" <<'FAKE_FINDMNT'
#!/usr/bin/env bash
set -euo pipefail
case ${FAKE_FINDMNT_MODE:?} in
  root-only)
    printf '{"filesystems":[{"target":"%s"}]}\n' "$FAKE_FINDMNT_ROOT"
    ;;
  descendant)
    printf '{"filesystems":[{"target":"%s"},{"target":"%s/subtree"}]}\n' \
      "$FAKE_FINDMNT_ROOT" "$FAKE_FINDMNT_ROOT"
    ;;
  filesystem-root)
    printf '{"filesystems":[{"target":"/"},{"target":"/tmp"}]}\n'
    ;;
  malformed)
    printf 'not-json\n'
    ;;
  failure)
    exit 23
    ;;
esac
FAKE_FINDMNT
fake_mount_root="$scratch/mount root"
mkdir -p "$fake_mount_root"
relative_mounts=$(cd "$scratch" && PATH="$fake_bin:$PATH" \
  FAKE_FINDMNT_MODE=root-only FAKE_FINDMNT_ROOT="$fake_mount_root" \
  ci_mount_targets_below 'mount root')
[ "$relative_mounts" = "$fake_mount_root" ] || {
  printf 'relative mount-tree root was not canonicalized\n' >&2
  exit 1
}
filesystem_root_mounts=$(PATH="$fake_bin:$PATH" FAKE_FINDMNT_MODE=filesystem-root \
  FAKE_FINDMNT_ROOT=/ ci_mount_targets_below /)
[ "$filesystem_root_mounts" = $'/tmp\n/' ] || {
  printf 'filesystem-root mount prefix was not handled\n' >&2
  exit 1
}
if ! (PATH="$fake_bin:$PATH" FAKE_FINDMNT_MODE=root-only FAKE_FINDMNT_ROOT="$fake_mount_root" \
  ci_validate_rootfs_overlay_tree "$fake_mount_root"); then
  printf 'overlay root mountpoint was rejected\n' >&2
  exit 1
fi
for fake_mode in descendant malformed failure; do
  if (PATH="$fake_bin:$PATH" FAKE_FINDMNT_MODE="$fake_mode" FAKE_FINDMNT_ROOT="$fake_mount_root" \
    ci_validate_rootfs_overlay_tree "$fake_mount_root") >/dev/null 2>&1; then
    printf 'overlay mount enumeration fixture was accepted: %s\n' "$fake_mode" >&2
    exit 1
  fi
done

for relative in dev proc sys run; do
  candidate="$scratch/reject-$relative"
  mkdir -p "$candidate/$relative"
  if (ci_validate_rootfs_overlay_tree "$candidate") >/dev/null 2>&1; then
    printf 'runtime overlay path was accepted: %s\n' "$relative" >&2
    exit 1
  fi
done

mkdir -p "$scratch/reject-link"
ln -s /run "$scratch/reject-link/run"
if (ci_validate_rootfs_overlay_tree "$scratch/reject-link") >/dev/null 2>&1; then
  printf 'runtime overlay symlink was accepted\n' >&2
  exit 1
fi

mkdir -p "$scratch/reject-absolute/etc"
ln -s /etc "$scratch/reject-absolute/etc/host-etc"
if (ci_validate_rootfs_overlay_tree "$scratch/reject-absolute") >/dev/null 2>&1; then
  printf 'absolute overlay symlink was accepted\n' >&2
  exit 1
fi

mkdir -p "$scratch/reject-escape/etc"
ln -s ../../outside "$scratch/reject-escape/etc/host-outside"
if (ci_validate_rootfs_overlay_tree "$scratch/reject-escape") >/dev/null 2>&1; then
  printf 'escaping relative overlay symlink was accepted\n' >&2
  exit 1
fi

mkdir -p "$scratch/contained/lib" "$scratch/contained/etc/systemd/system/multi-user.target.wants"
touch "$scratch/contained/lib/libcontained.so.1"
ln -s libcontained.so.1 "$scratch/contained/lib/libcontained.so"
ln -s ../contained.service \
  "$scratch/contained/etc/systemd/system/multi-user.target.wants/contained.service"
ci_validate_rootfs_overlay_tree "$scratch/contained"

case $(basename -- "$SCRIPT_DIR/../../..") in
  ubuntu) rootfs_script="$SCRIPT_DIR/build-rootfs-image.sh" ;;
  arch) rootfs_script="$SCRIPT_DIR/build-arch-rootfs-image.sh" ;;
  *) rootfs_script=$(find "$SCRIPT_DIR" -maxdepth 1 -type f -name 'build*rootfs-image.sh' -print -quit) ;;
esac
[ -f "$rootfs_script" ]

! grep -Fq 'ci_extract_archive "$tmp_overlay" "$rootfs_dir"' "$rootfs_script"

camera_source=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)/source/tb321fu-camera-rootfs-overlay/source/libcamera-source.cpp.clean-minimal-daily
if [ -f "$camera_source" ]; then
  grep -Fq 'struct spa_fraction rate = { 30, 1 };' "$camera_source"
  grep -Fq 'buffers[i]->n_datas > planes.size()' "$camera_source"
  grep -Fq 'buffers[i]->datas[j].chunk == nullptr' "$camera_source"
  grep -Fq 'd[j].fd = planes[j].fd.get();' "$camera_source"
  grep -Fq 'size < sizeof(struct spa_io_sequence)' "$camera_source"
  grep -Fq 'if ((res = process_control' "$camera_source"
  if grep -Fq 'numbers: %d is greater than plane number' "$camera_source"; then
    echo 'camera source still contains the unsafe extra-data fallback' >&2
    exit 1
  fi
fi

unmount_line=$(grep -n '^unmount_chroot_runtime$' "$rootfs_script" | tail -n1 | cut -d: -f1)
apply_line=$(grep -n 'applying staged overlay archive' "$rootfs_script" | tail -n1 | cut -d: -f1)
[ -n "$unmount_line" ] && [ -n "$apply_line" ] && [ "$unmount_line" -lt "$apply_line" ]
grep -Fq 'rsync -aHAX --one-file-system --numeric-ids -- "$overlay_stage"/ "$rootfs_dir"/' "$rootfs_script"
grep -Fq 'rsync -aHAX --one-file-system --numeric-ids -- "$OVERLAY_DIR"/ "$rootfs_dir"/' "$rootfs_script"
stage_recheck_line=$(grep -n 'ci_validate_rootfs_overlay_tree "$overlay_stage"' "$rootfs_script" | tail -n1 | cut -d: -f1)
stage_copy_line=$(grep -n 'rsync .*"$overlay_stage"/' "$rootfs_script" | tail -n1 | cut -d: -f1)
dir_recheck_line=$(grep -n 'ci_validate_rootfs_overlay_tree "$OVERLAY_DIR"' "$rootfs_script" | tail -n1 | cut -d: -f1)
dir_copy_line=$(grep -n 'rsync .*"$OVERLAY_DIR"/' "$rootfs_script" | tail -n1 | cut -d: -f1)
[ -n "$stage_recheck_line" ] && [ -n "$stage_copy_line" ] &&
  [ "$stage_recheck_line" -lt "$stage_copy_line" ]
[ -n "$dir_recheck_line" ] && [ -n "$dir_copy_line" ] &&
  [ "$dir_recheck_line" -lt "$dir_copy_line" ]

printf 'rootfs overlay mount boundary: PASS\n'
