#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BUILD_SCRIPT="$SCRIPT_DIR/build-arch-rootfs-image.sh"
GPU_SOURCE="$SCRIPT_DIR/../../source/tb321fu-ksystemstats-adreno-freq/tb321fu_gpu.cpp"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/system-payload-policy.sh"

fail() {
  printf 'test failure: %s\n' "$*" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root="$tmp/root"
stock=/usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so

# The stock provider remains a member of ksystemstats.  It is hidden only in
# the ksystemstats user-service namespace, so a pacman upgrade can replace the
# file normally and `pacman -Qkk ksystemstats` remains clean.
dropin="$tmp/plasma-ksystemstats.service.d/90-tb321fu-gpu-provider.conf"
install -D -m 0644 /dev/stdin "$dropin" <<'GPU_DROPIN'
[Service]
InaccessiblePaths=-/usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
GPU_DROPIN
grep -Fq 'InaccessiblePaths=-/usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so' "$dropin" || \
  fail "GPU service drop-in does not hide the stock provider"
grep -Fq 'InaccessiblePaths=-/usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so' "$BUILD_SCRIPT" || \
  fail "production GPU package does not install service-level stock-provider isolation"
grep -Fq 'ci_validate_gpu_sensor_source_input_tree' "$BUILD_SCRIPT" || \
  fail "production GPU build does not validate the complete source input tree"
if grep -Fq 'disable-stock-ksystemstats-gpu' "$BUILD_SCRIPT"; then
  fail "production build still mutates a ksystemstats-owned plugin"
fi
if grep -Fq '99-tb321fu-disable-stock-ksystemstats-gpu' "$BUILD_SCRIPT"; then
  fail "production build still installs a stock-plugin pacman hook"
fi
if [ -e "$SCRIPT_DIR/payloads/tb321fu-disable-stock-ksystemstats-gpu" ] ||
   [ -e "$SCRIPT_DIR/payloads/tb321fu-ksystemstats-gpu.install" ]; then
  fail "obsolete stock-plugin mutation payload remains in the repository"
fi

# The GPU build input is intentionally a closed three-file tree.  Exercise the
# same policy against extra, linked and unsafe-metadata members before any
# compiler is allowed to consume it.
gpu_source_fixture="$tmp/gpu-source"
install -d -m 0755 "$gpu_source_fixture"
printf 'cmake_minimum_required(VERSION 3.16)\n' > "$gpu_source_fixture/CMakeLists.txt"
printf '{"providerName":"tb321fu_gpu"}\n' > "$gpu_source_fixture/metadata.json"
printf '// fixture\n' > "$gpu_source_fixture/tb321fu_gpu.cpp"
chmod 0644 "$gpu_source_fixture"/*
ci_validate_gpu_sensor_source_tree "$gpu_source_fixture"
find_failure_bin="$tmp/find-failure-bin"
install -D -m 0755 /dev/stdin "$find_failure_bin/find" <<'FIND_FAILURE'
#!/usr/bin/env bash
exit 23
FIND_FAILURE
if (PATH="$find_failure_bin:$PATH" ci_validate_gpu_sensor_source_tree "$gpu_source_fixture") \
    >/dev/null 2>&1; then
  fail "GPU source validator ignored a find failure"
fi
gpu_manifest=$(ci_gpu_sensor_source_manifest "$gpu_source_fixture") || {
  fail "GPU source manifest could not be generated"
}
[ "$(printf '%s\n' "$gpu_manifest" | awk 'NF { count++ } END { print count + 0 }')" -eq 3 ] ||
  fail "GPU source manifest must contain exactly three records"
if ! printf '%s\n' "$gpu_manifest" | awk -F '\t' '
  NF != 4 || $1 == "" || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[[:xdigit:]]{64}$/ { bad = 1 }
  END { exit bad }
'; then
  fail "GPU source manifest records are not four-column SHA-256 entries"
fi
mv "$gpu_source_fixture/metadata.json" "$gpu_source_fixture/metadata.json.missing"
if ci_gpu_sensor_source_manifest "$gpu_source_fixture" >/dev/null 2>&1; then
  fail "GPU source manifest ignored a missing required member"
fi
mv "$gpu_source_fixture/metadata.json.missing" "$gpu_source_fixture/metadata.json"
printf 'unexpected\n' > "$gpu_source_fixture/extra.txt"
if (ci_validate_gpu_sensor_source_tree "$gpu_source_fixture") >/dev/null 2>&1; then
  fail "GPU source extra member was accepted"
fi
rm -f "$gpu_source_fixture/extra.txt"
ln -s metadata.json "$gpu_source_fixture/extra-link"
if (ci_validate_gpu_sensor_source_tree "$gpu_source_fixture") >/dev/null 2>&1; then
  fail "GPU source symlink member was accepted"
fi
rm -f "$gpu_source_fixture/extra-link"
ln "$gpu_source_fixture/tb321fu_gpu.cpp" "$gpu_source_fixture/extra-hardlink"
if (ci_validate_gpu_sensor_source_tree "$gpu_source_fixture") >/dev/null 2>&1; then
  fail "GPU source hard-linked member was accepted"
fi
rm -f "$gpu_source_fixture/extra-hardlink"
chmod 0664 "$gpu_source_fixture/tb321fu_gpu.cpp"
if (ci_validate_gpu_sensor_source_tree "$gpu_source_fixture") >/dev/null 2>&1; then
  fail "GPU source unsafe mode was accepted"
fi
chmod 0644 "$gpu_source_fixture/tb321fu_gpu.cpp"

# Archive inputs may carry a harmless wrapper directory, but no payload outside
# the selected project is allowed to reach the compiler. Exercise the same
# closed-world check against a representative source/<project> layout.
gpu_wrapped_input="$tmp/gpu-wrapped-input"
gpu_wrapped_project="$gpu_wrapped_input/source/tb321fu-ksystemstats-adreno-freq"
install -d -m 0755 "$gpu_wrapped_project"
cp -a "$gpu_source_fixture"/. "$gpu_wrapped_project"/
ci_validate_gpu_sensor_source_input_tree "$gpu_wrapped_input" "$gpu_wrapped_project"
if (PATH="$find_failure_bin:$PATH" \
    ci_validate_gpu_sensor_source_input_tree "$gpu_wrapped_input" "$gpu_wrapped_project") \
    >/dev/null 2>&1; then
  fail "GPU source input validator ignored a find failure"
fi
printf 'unexpected\n' > "$gpu_wrapped_input/unexpected.txt"
if (ci_validate_gpu_sensor_source_input_tree "$gpu_wrapped_input" "$gpu_wrapped_project") >/dev/null 2>&1; then
  fail "GPU source archive extra file was accepted"
fi
rm -f "$gpu_wrapped_input/unexpected.txt"
ln -s "$gpu_wrapped_project/metadata.json" "$gpu_wrapped_input/metadata-link"
if (ci_validate_gpu_sensor_source_input_tree "$gpu_wrapped_input" "$gpu_wrapped_project") >/dev/null 2>&1; then
  fail "GPU source archive symlink was accepted"
fi
rm -f "$gpu_wrapped_input/metadata-link"
mkfifo "$gpu_wrapped_input/source/fifo"
if (ci_validate_gpu_sensor_source_input_tree "$gpu_wrapped_input" "$gpu_wrapped_project") >/dev/null 2>&1; then
  fail "GPU source archive special file was accepted"
fi
rm -f "$gpu_wrapped_input/source/fifo"
gpu_hardlink_source="$tmp/gpu-hardlink-metadata.json"
printf '{"providerName":"tb321fu_gpu"}\n' > "$gpu_hardlink_source"
rm -f "$gpu_wrapped_project/metadata.json"
ln "$gpu_hardlink_source" "$gpu_wrapped_project/metadata.json"
if (ci_validate_gpu_sensor_source_input_tree "$gpu_wrapped_input" "$gpu_wrapped_project") >/dev/null 2>&1; then
  fail "GPU source archive hard-linked file was accepted"
fi
rm -f "$gpu_wrapped_project/metadata.json"
printf '{"providerName":"tb321fu_gpu"}\n' > "$gpu_wrapped_project/metadata.json"
chmod 0644 "$gpu_wrapped_project/metadata.json"
ci_validate_gpu_sensor_source_input_tree "$gpu_wrapped_input" "$gpu_wrapped_project"

# Resolver bytes copied from the runner are a temporary chroot aid only; the
# archive/overlay resolver must be restored before the final image manifest.
prepare_line=$(grep -n '^prepare_rootfs_resolver$' "$BUILD_SCRIPT" | tail -n1 | cut -d: -f1)
restore_line=$(grep -n '^restore_rootfs_resolver$' "$BUILD_SCRIPT" | tail -n1 | cut -d: -f1)
first_mount_line=$(grep -n '^mount_chroot_runtime$' "$BUILD_SCRIPT" | head -n1 | cut -d: -f1)
final_manifest_line=$(grep -n '^ci_log "writing rootfs manifest"' "$BUILD_SCRIPT" | tail -n1 | cut -d: -f1)
[ -n "$prepare_line" ] && [ -n "$restore_line" ] && [ -n "$first_mount_line" ] &&
  [ -n "$final_manifest_line" ] || fail "resolver lifecycle markers are missing"
[ "$prepare_line" -lt "$first_mount_line" ] || fail "runner resolver is prepared after chroot mount"
[ "$restore_line" -lt "$final_manifest_line" ] || fail "archive resolver is restored after final manifest"
if grep -Fq 'cp -L /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"' "$BUILD_SCRIPT"; then
  fail "build still copies host resolver directly into final rootfs"
fi

# Execute the camera staging helpers directly from the build script. Imported
# Ubuntu camera files are excluded from the generic package, while libaperture
# is transferred byte-for-byte into the native camera package.
extract_shell_function() {
  local name=$1
  awk -v signature="$name() {" '
    $0 == signature { copying = 1 }
    copying { print }
    copying && $0 == "}" { exit }
  ' "$BUILD_SCRIPT"
}

extract_balanced_shell_function() {
  local name=$1
  awk -v signature="$name() {" '
    function brace_delta(line,    opens, closes) {
      opens = gsub(/\{/, "", line)
      closes = gsub(/\}/, "", line)
      return opens - closes
    }
    !copying && $0 == signature {
      copying = 1
      depth = 0
    }
    copying {
      print
      depth += brace_delta($0)
      if (depth == 0) exit
    }
  ' "$BUILD_SCRIPT"
}
ci_die() { fail "$*"; }
eval "$(extract_shell_function stage_arch_camera_supplement)"
eval "$(extract_shell_function remove_arch_native_camera_package_paths)"
eval "$(extract_shell_function adapt_ubuntu_multilib_paths_for_arch)"
eval "$(extract_balanced_shell_function copy_skel_to_user)"

# copy_skel_to_user must resolve numeric ownership from the target image. Use
# an image-only account name that the host NSS cannot resolve, while returning
# the current numeric IDs so the real host chown works for root and non-root
# fixture execution.
arch_chroot() {
  [ "${1:-}" = id ] && [ "${3:-}" = "$DEFAULT_USER_NAME" ] || return 127
  case "${2:-}" in
    -u) id -u ;;
    -g) id -g ;;
    *) return 127 ;;
  esac
}

# Exercise resolver save/prepare/restore behavior with each archive state. The
# host resolver is only a temporary networking aid; the original rootfs bytes
# and symlink target must be restored exactly before image finalization.
eval "$(extract_shell_function save_rootfs_resolver)"
eval "$(extract_shell_function prepare_rootfs_resolver)"
eval "$(extract_shell_function restore_rootfs_resolver)"
resolver_root="$tmp/resolver-root"
mkdir -p "$resolver_root/etc"
rootfs_dir="$resolver_root"
resolv_state="$tmp/resolv.conf.state"
resolv_saved=0
ln -s /run/systemd/resolve/stub-resolv.conf "$resolver_root/etc/resolv.conf"
save_rootfs_resolver
prepare_rootfs_resolver
[ -f "$resolver_root/etc/resolv.conf" ] && [ ! -L "$resolver_root/etc/resolv.conf" ] ||
  fail "resolver preparation did not install a regular temporary file"
restore_rootfs_resolver
[ -L "$resolver_root/etc/resolv.conf" ] &&
  [ "$(readlink "$resolver_root/etc/resolv.conf")" = /run/systemd/resolve/stub-resolv.conf ] ||
  fail "resolver symlink was not restored exactly"
rm -f "$resolver_root/etc/resolv.conf"
printf 'nameserver 9.9.9.9\n' > "$resolver_root/etc/resolv.conf"
save_rootfs_resolver
prepare_rootfs_resolver
restore_rootfs_resolver
[ -f "$resolver_root/etc/resolv.conf" ] && [ ! -L "$resolver_root/etc/resolv.conf" ] ||
  fail "resolver regular file was not restored"
grep -Fxq 'nameserver 9.9.9.9' "$resolver_root/etc/resolv.conf" ||
  fail "resolver regular-file bytes changed during temporary preparation"
rm -f "$resolver_root/etc/resolv.conf"
save_rootfs_resolver
prepare_rootfs_resolver
restore_rootfs_resolver
[ ! -e "$resolver_root/etc/resolv.conf" ] && [ ! -L "$resolver_root/etc/resolv.conf" ] ||
  fail "missing resolver was not restored as missing"
rm -f "$resolv_state" "$resolv_state.file"

# Skeleton defaults are seeds, not an update mechanism. Existing user bytes
# must remain unchanged, while missing defaults are copied only into real
# regular-file paths; symlinked homes, directories and destinations fail
# closed before any outside path can be modified.
DEFAULT_USER_NAME="tb321fu_image_$$_user"
if getent passwd "$DEFAULT_USER_NAME" >/dev/null 2>&1 ||
   getent group "$DEFAULT_USER_NAME" >/dev/null 2>&1; then
  fail "image-only skeleton fixture identity unexpectedly exists on the host"
fi
INSTALL_FCITX5_CHINESE=1
skel_root="$tmp/skel-root"
skel_home="$skel_root/home/$DEFAULT_USER_NAME"
skel_config="$skel_home/.config"
skel_source="$skel_root/etc/skel/.config"
install -D -m 0644 /dev/stdin "$skel_source/kwinrc" <<'SKEL_KWIN'
default-kwin
SKEL_KWIN
install -D -m 0644 /dev/stdin "$skel_source/plasmakeyboardrc" <<'SKEL_KEYBOARD'
default-keyboard
SKEL_KEYBOARD
install -D -m 0644 /dev/stdin "$skel_source/kwinoutputconfig.json" <<'SKEL_OUTPUT'
{}
SKEL_OUTPUT
for relative in \
  environment.d/90-fcitx5.conf \
  autostart/org.fcitx.Fcitx5.desktop \
  fcitx5/profile \
  plasma-workspace/env/fcitx5.sh; do
  install -D -m 0644 /dev/stdin "$skel_source/$relative" <<'SKEL_EXTRA'
default-value
SKEL_EXTRA
done
install -d -m 0755 "$skel_config"
printf 'user-owned-kwin\n' > "$skel_config/kwinrc"
printf 'user-owned-env\n' > "$skel_config/environment.d-placeholder"
kwin_before=$(sha256sum "$skel_config/kwinrc" | awk '{print $1}')
copy_skel_to_user "$skel_root"
[ "$(stat -c '%u:%g' -- "$skel_config")" = "$(id -u):$(id -g)" ] ||
  fail "skeleton ownership was not applied from numeric image UID/GID"
[ "$(sha256sum "$skel_config/kwinrc" | awk '{print $1}')" = "$kwin_before" ] || \
  fail "existing user skeleton bytes were overwritten"
grep -Fxq 'user-owned-kwin' "$skel_config/kwinrc" || fail "existing user skeleton content changed"
for relative in plasmakeyboardrc kwinoutputconfig.json \
  environment.d/90-fcitx5.conf autostart/org.fcitx.Fcitx5.desktop \
  fcitx5/profile plasma-workspace/env/fcitx5.sh; do
  [ -f "$skel_config/$relative" ] && [ ! -L "$skel_config/$relative" ] || \
    fail "missing skeleton default was not installed: $relative"
done

skel_outside="$tmp/skel-outside"
mkdir -p "$skel_outside"
skel_bad_home="$tmp/skel-bad-home"
mkdir -p "$skel_bad_home/home"
ln -s "$skel_outside" "$skel_bad_home/home/$DEFAULT_USER_NAME"
if (copy_skel_to_user "$skel_bad_home") >/dev/null 2>&1; then
  fail "symlinked user home was accepted"
fi

skel_bad_config="$tmp/skel-bad-config"
mkdir -p "$skel_bad_config/home/$DEFAULT_USER_NAME"
ln -s "$skel_outside" "$skel_bad_config/home/$DEFAULT_USER_NAME/.config"
if (copy_skel_to_user "$skel_bad_config") >/dev/null 2>&1; then
  fail "symlinked user .config directory was accepted"
fi

skel_bad_destination="$tmp/skel-bad-destination"
mkdir -p "$skel_bad_destination/home/$DEFAULT_USER_NAME/.config"
ln -s "$skel_outside/escape" \
  "$skel_bad_destination/home/$DEFAULT_USER_NAME/.config/kwinrc"
if (copy_skel_to_user "$skel_bad_destination") >/dev/null 2>&1; then
  fail "symlinked user destination was accepted"
fi
[ ! -e "$skel_outside/escape" ] || fail "destination symlink fixture was followed"

skel_bad_type="$tmp/skel-bad-type"
mkdir -p "$skel_bad_type/home/$DEFAULT_USER_NAME/.config/kwinrc"
if (copy_skel_to_user "$skel_bad_type") >/dev/null 2>&1; then
  fail "non-regular user destination was accepted"
fi

import_stage="$tmp/import-stage"
arch_camera_supplement_stage="$tmp/camera-supplement-stage"
install -D -m 0644 /dev/stdin \
  "$import_stage/opt/libcamera-y700/bin/cam" <<'OLD_CAMERA'
old-camera
OLD_CAMERA
install -D -m 0644 /dev/stdin \
  "$import_stage/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" <<'OLD_SPA'
old-spa
OLD_SPA
install -D -m 0644 /dev/stdin \
  "$import_stage/usr/lib/aarch64-linux-gnu/libaperture-0.so.0" <<'APERTURE'
aperture
APERTURE
ln -s libaperture-0.so.0 "$import_stage/usr/lib/aarch64-linux-gnu/libaperture-0.so"
stage_arch_camera_supplement "$import_stage"
remove_arch_native_camera_package_paths "$import_stage"
[ ! -e "$import_stage/opt/libcamera-y700" ] || fail "camera payload remained in generic import stage"
[ ! -e "$import_stage/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera" ] || \
  fail "camera SPA payload remained in generic import stage"
[ ! -e "$import_stage/usr/lib/aarch64-linux-gnu/libaperture-0.so.0" ] || \
  fail "libaperture remained in the generic import package"
[ -f "$arch_camera_supplement_stage/usr/lib/aarch64-linux-gnu/libaperture-0.so.0" ] || \
  fail "canonical imported libaperture was not staged for the camera package"

camera_stage="$tmp/camera-stage"
camera_source="$SCRIPT_DIR/../../source/tb321fu-camera-rootfs-overlay/rootfs-overlay"
cp -a "$camera_source" "$camera_stage"
cp -a "$arch_camera_supplement_stage"/. "$camera_stage"/
adapt_ubuntu_multilib_paths_for_arch "$camera_stage"
[ "$(readlink "$camera_stage/usr/lib/libaperture-0.so.0")" = \
  /usr/lib/aarch64-linux-gnu/libaperture-0.so.0 ] || fail "camera package ABI symlink is wrong"
[ "$(readlink "$camera_stage/usr/lib/libaperture-0.so")" = libaperture-0.so.0 ] || \
  fail "camera package development symlink is wrong"
[ "$(readlink "$camera_stage/usr/lib/gstreamer-1.0/libgstlibcamera.so")" = \
  /opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so ] || \
  fail "camera package GStreamer symlink is wrong"
[ -x "$camera_stage/usr/lib/tb321fu/refresh-camera-compat-paths" ] || \
  fail "camera compatibility helper is not executable"

if [ "$EUID" -eq 0 ]; then
  # A checkout can be owned by the build user.  The native package entry point
  # must normalize every camera member before makepkg records its mtree.
  find -P "$camera_stage" -exec chown --no-dereference 1000:1000 -- {} +
  ci_normalize_system_payload_ownership "$camera_stage"
  ci_assert_system_payload_root_owned "$camera_stage"

  # A package hook may repair paths after a dependency upgrade, but it must
  # retain the package's deterministic file mtimes so pacman -Qkk stays clean.
  compat_helper="$camera_stage/usr/lib/tb321fu/refresh-camera-compat-paths"
  touch -d '@123456789' -- "$compat_helper"
  printf 'stale-spa\n' > "$camera_stage/usr/lib/spa-0.2/libcamera/libspa-libcamera.so"
  rm -f -- "$camera_stage/usr/lib/gstreamer-1.0/libgstlibcamera.so"
  TB321FU_ROOT="$camera_stage" TB321FU_CAMERA_COMPAT_SOURCE_ROOT="$camera_stage" \
    "$compat_helper"
  [ "$(stat -c '%Y' -- "$camera_stage/usr/lib/spa-0.2/libcamera/libspa-libcamera.so")" = 123456789 ] || \
    fail "camera SPA repair did not preserve package mtime"
  [ "$(find "$camera_stage/usr/lib/gstreamer-1.0/libgstlibcamera.so" -prune -printf '%T@')" = 123456789.0000000000 ] || \
    fail "camera GStreamer link repair did not preserve package mtime"
fi

# Re-running the package hook on an already repaired tree must be a true
# no-op for the package payload.  In particular, a dependency upgrade hook
# must not churn inode identity, bytes, mode, ownership, timestamps, or link
# targets when the source is unchanged.
compat_helper="$camera_stage/usr/lib/tb321fu/refresh-camera-compat-paths"
compat_spa="$camera_stage/usr/lib/spa-0.2/libcamera/libspa-libcamera.so"
compat_gst="$camera_stage/usr/lib/gstreamer-1.0/libgstlibcamera.so"
compat_aperture_abi="$camera_stage/usr/lib/libaperture-0.so.0"
compat_aperture_dev="$camera_stage/usr/lib/libaperture-0.so"
snapshot_path() {
  local path=$1 kind metadata target digest
  if [ -L "$path" ]; then
    kind=l
    metadata=$(stat -c '%d:%i:%a:%u:%g:%Y:%s' -- "$path") || return 1
    target=$(readlink -- "$path") || return 1
    printf '%s\t%s\t%s\n' "$kind" "$metadata" "$target"
  elif [ -f "$path" ]; then
    kind=f
    metadata=$(stat -c '%d:%i:%a:%u:%g:%Y:%s' -- "$path") || return 1
    digest=$(sha256sum -- "$path" | awk '{print $1}') || return 1
    printf '%s\t%s\t%s\n' "$kind" "$metadata" "$digest"
  else
    return 1
  fi
}

for path in "$compat_helper" "$compat_spa" "$compat_gst" \
  "$compat_aperture_abi" "$compat_aperture_dev"; do
  [ -e "$path" ] || [ -L "$path" ] || fail "camera compatibility path missing before idempotence check: $path"
done
helper_before=$(snapshot_path "$compat_helper") || fail "cannot snapshot camera helper"
spa_before=$(snapshot_path "$compat_spa") || fail "cannot snapshot camera SPA compatibility file"
gst_before=$(snapshot_path "$compat_gst") || fail "cannot snapshot camera GStreamer compatibility link"
aperture_abi_before=$(snapshot_path "$compat_aperture_abi") || fail "cannot snapshot libaperture ABI link"
aperture_dev_before=$(snapshot_path "$compat_aperture_dev") || fail "cannot snapshot libaperture development link"

TB321FU_ROOT="$camera_stage" TB321FU_CAMERA_COMPAT_SOURCE_ROOT="$camera_stage" \
  "$compat_helper"
[ "$(snapshot_path "$compat_helper")" = "$helper_before" ] || fail "camera helper changed on repeated execution"
[ "$(snapshot_path "$compat_spa")" = "$spa_before" ] || fail "camera SPA compatibility file changed on repeated execution"
[ "$(snapshot_path "$compat_gst")" = "$gst_before" ] || fail "camera GStreamer compatibility link changed on repeated execution"
[ "$(snapshot_path "$compat_aperture_abi")" = "$aperture_abi_before" ] || fail "libaperture ABI link changed on repeated execution"
[ "$(snapshot_path "$compat_aperture_dev")" = "$aperture_dev_before" ] || fail "libaperture development link changed on repeated execution"

# Checksums are rooted at the package payload, never at a host build path.
stage="$tmp/package-stage"
plugin_rel=usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_tb321fu_gpu.so
install -D -m 0644 /dev/stdin "$stage/$plugin_rel" <<'PLUGIN'
tb321fu-provider
PLUGIN
install -d -m 0755 "$stage/usr/share/tb321fu-ksystemstats-gpu"
(
  cd "$stage"
  sha256sum "./$plugin_rel" > \
    ./usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256
)
checksum_line=$(cat "$stage/usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256")
[[ $checksum_line == *"  ./$plugin_rel" ]] || fail "GPU checksum is not package-relative"
[[ $checksum_line != *"$tmp"* ]] || fail "GPU checksum leaked its host build path"
(
  cd "$stage"
  sha256sum -c ./usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256
) >/dev/null

# Native package graph and final gates are executable policy, not comments.
grep -Fq 'tb321fu-camera-stack' "$BUILD_SCRIPT" || fail "camera native package is missing"
grep -Fq 'camera_conflicts=(gst-plugin-libcamera y700-camera-stack)' "$BUILD_SCRIPT" || \
  fail "camera conflicts are missing"
grep -Fq 'camera_replaces=(gst-plugin-libcamera y700-camera-stack)' "$BUILD_SCRIPT" || \
  fail "camera replacements are missing"
grep -Fq 'tb321fu-ksystemstats-gpu' "$BUILD_SCRIPT" || fail "GPU native package is missing"
grep -Fq 'verify_tb321fu_native_package_integrity' "$BUILD_SCRIPT" || fail "final native package gate is missing"
grep -Fq 'pacman -Qoq' "$BUILD_SCRIPT" || fail "final ownership gate is missing"
grep -Fq 'pacman -Qkk' "$BUILD_SCRIPT" || fail "final integrity gate is missing"

# Runtime telemetry discovers the devfreq class and publishes an invalid value
# while unavailable instead of reporting a misleading zero.
grep -Fq '/sys/class/devfreq' "$GPU_SOURCE" || fail "GPU devfreq discovery is missing"
grep -Fq 'm_frequency->setValue(QVariant())' "$GPU_SOURCE" || fail "GPU unavailable state is not explicit"
if grep -Fq '/sys/devices/platform/soc@0/3d00000.gpu' "$GPU_SOURCE"; then
  fail "GPU telemetry still hardcodes one platform path"
fi

printf 'ARCH_NATIVE_PACKAGE_LIFECYCLE=PASS\n'
