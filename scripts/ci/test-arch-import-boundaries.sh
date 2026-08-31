#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BUILD_SCRIPT="$SCRIPT_DIR/build-arch-rootfs-image.sh"

fail() {
  printf 'Arch import boundary test failure: %s\n' "$*" >&2
  exit 1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-arch-import.XXXXXX")
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT INT TERM

# Extract only the production helpers under test.  Brace depth handles the
# command groups inside validate_arch_import_relative_path as well as the
# function's outer brace.
extract_shell_function() {
  local name=$1
  awk -v signature="$name() {" '
    function braces(line,    opens, closes) {
      opens = gsub(/\{/, "", line)
      closes = gsub(/\}/, "", line)
      depth += opens - closes
    }
    !copying && $0 == signature {
      copying = 1
      depth = 0
    }
    copying {
      print
      braces($0)
      if (depth == 0) exit
    }
  ' "$BUILD_SCRIPT"
}

ci_die() {
  printf '%s\n' "$*" >&2
  exit 1
}

expect_rejected() {
  local label=$1
  shift
  if ("$@") >"$tmp/stdout" 2>"$tmp/stderr"; then
    fail "accepted hostile input: $label"
  fi
}

expect_accepted() {
  local label=$1
  shift
  if ! ("$@") >"$tmp/stdout" 2>"$tmp/stderr"; then
    fail "rejected valid input: $label ($(tr '\n' ' ' < "$tmp/stderr"))"
  fi
}

eval "$(extract_shell_function arch_import_multilib_member_allowed)"
eval "$(extract_shell_function arch_import_source_package)"
eval "$(extract_shell_function arch_import_allowed_pacman_owner)"
eval "$(extract_shell_function imported_deb_package_name)"
eval "$(extract_shell_function verify_and_extract_imported_deb)"
eval "$(extract_shell_function write_arch_import_payload_metadata)"
eval "$(extract_shell_function write_arch_package_tree_identity)"
eval "$(extract_shell_function compute_arch_import_package_hash)"
eval "$(extract_shell_function capture_sorted_nul_command)"
eval "$(extract_shell_function extract_device_payload_dir)"
eval "$(extract_shell_function arch_import_iio_sensor_proxy_relation_lines)"
eval "$(extract_shell_function validate_arch_import_relative_path)"
eval "$(extract_shell_function camera_source_root_is_contained)"
eval "$(extract_shell_function find_camera_source_root)"
eval "$(extract_shell_function validate_camera_stack_symlink)"
eval "$(extract_shell_function camera_canonical_symlink_target)"
eval "$(extract_shell_function camera_canonical_expected_mode)"
eval "$(extract_shell_function camera_contract_add_parent_dirs)"
eval "$(extract_shell_function validate_camera_tree_against_contract)"
eval "$(extract_shell_function validate_camera_stack_stage)"

REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
work_dir="$tmp/work"
mkdir -p "$work_dir"

zstd_payload_dir="$tmp/zstd-payload"
mkdir -p "$zstd_payload_dir"
printf 'not-a-supported-stream\n' > "$zstd_payload_dir/device-overlay.tar.zst"
expect_rejected ".tar.zst device overlay without bounded decoder" \
  extract_device_payload_dir "$zstd_payload_dir"

# The builder must delegate verification and extraction to one helper
# invocation and use only the digest produced from that held fd.
fake_python_bin="$tmp/fake-python-bin"
fake_python_log="$tmp/fake-python.args"
deb_fixture="$tmp/qcom-sns-libssc_20260627.1_arm64.deb"
deb_stage="$tmp/deb-stage"
digest_fixture=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
mkdir -p "$fake_python_bin" "$deb_stage"
: > "$deb_fixture"
install -D -m 0755 /dev/stdin "$fake_python_bin/python3" <<'FAKE_PYTHON'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$FAKE_PYTHON_LOG"
printf '%s\n' "$FAKE_PYTHON_DIGEST"
FAKE_PYTHON
deb_digest=$(PATH="$fake_python_bin:$PATH" \
  FAKE_PYTHON_LOG="$fake_python_log" \
  FAKE_PYTHON_DIGEST="$digest_fixture" \
  verify_and_extract_imported_deb "$deb_fixture" "$deb_stage")
[ "$deb_digest" = "$digest_fixture" ] ||
  fail "single-fd DEB helper digest was not propagated"
mapfile -d '' -t fake_python_args < "$fake_python_log"
[ "${#fake_python_args[@]}" -eq 7 ] &&
  [ "${fake_python_args[0]}" = "$SCRIPT_DIR/verify-imported-deb.py" ] &&
  [ "${fake_python_args[1]}" = --package ] &&
  [ "${fake_python_args[2]}" = qcom-sns-libssc ] &&
  [ "${fake_python_args[3]}" = --extract ] &&
  [ "${fake_python_args[4]}" = "$deb_stage" ] &&
  [ "${fake_python_args[5]}" = --print-sha256 ] &&
  [ "${fake_python_args[6]}" = "$deb_fixture" ] ||
  fail "builder did not request one verified DEB extraction transaction"
if (PATH="$fake_python_bin:$PATH" \
    FAKE_PYTHON_LOG="$fake_python_log" \
    FAKE_PYTHON_DIGEST=not-a-digest \
    verify_and_extract_imported_deb "$deb_fixture" "$deb_stage" \
    >/dev/null 2>&1); then
  fail "builder accepted a malformed verifier digest"
fi

partial_nul_producer() {
  printf 'accepted-before-error\0'
  return 23
}
expect_rejected "partial producer failure" \
  capture_sorted_nul_command ignored_list "fixture producer" partial_nul_producer

sort_failure_bin="$tmp/sort-failure-bin"
install -D -m 0755 /dev/stdin "$sort_failure_bin/sort" <<'SORT_FAILURE'
#!/usr/bin/env bash
last=
for argument in "$@"; do
  last=$argument
done
cat -- "$last"
exit 29
SORT_FAILURE
if (PATH="$sort_failure_bin:$PATH" \
    capture_sorted_nul_command ignored_list "fixture sort" \
      printf 'accepted-before-sort-error\0') >/dev/null 2>&1; then
  fail "accepted a partial sorted list from a failing sort"
fi

capture_sorted_nul_command ordered_list "ordered fixture" \
  printf 'z-last\0a-first\0'
mapfile -d '' -t ordered_records < "$ordered_list"
rm -f -- "$ordered_list"
[ "${#ordered_records[@]}" -eq 2 ] &&
  [ "${ordered_records[0]}" = a-first ] &&
  [ "${ordered_records[1]}" = z-last ] ||
  fail "checked NUL enumeration did not retain canonical sort order"

rootfs_dir="$tmp/rootfs"
mkdir -p "$rootfs_dir/usr/lib/aarch64-linux-gnu" "$rootfs_dir/usr/bin"
ln -s usr/lib "$rootfs_dir/lib"

PACMAN_OWNER_MODE=unowned
arch_chroot() {
  if [ "${1:-}" = /usr/bin/pacman ] && [ "${2:-}" = -Qoq ]; then
    case "$PACMAN_OWNER_MODE" in
      unowned) return 1 ;;
      iio) printf 'iio-sensor-proxy\n'; return 0 ;;
      stock) printf 'stock-package\n'; return 0 ;;
      error) return 2 ;;
      *) return 3 ;;
    esac
  fi
  return 127
}

stage="$tmp/stage"
mkdir -p "$stage/usr/lib/aarch64-linux-gnu" "$stage/usr/bin"
install -m 0644 /dev/null "$stage/usr/lib/aarch64-linux-gnu/libssc.so"
install -m 0644 /dev/null "$stage/usr/bin/monitor-sensor"

# A clean path and the explicitly allowed multiarch ABI members are accepted.
expect_accepted "unowned regular member" \
  validate_arch_import_relative_path usr/bin/new-member "$stage/usr/bin/monitor-sensor"
expect_accepted "allowlisted multiarch ABI" \
  validate_arch_import_relative_path usr/lib/aarch64-linux-gnu/libssc.so \
  "$stage/usr/lib/aarch64-linux-gnu/libssc.so"

# usrmerge and the closed multiarch namespace are fail-closed.
expect_rejected "payload below /lib usrmerge link" \
  validate_arch_import_relative_path lib/escape "$stage/usr/bin/monitor-sensor"
install -D -m 0644 /dev/null "$stage/usr/lib/aarch64-linux-gnu/libnot-approved.so"
expect_rejected "unallowlisted multiarch ABI" \
  validate_arch_import_relative_path usr/lib/aarch64-linux-gnu/libnot-approved.so \
  "$stage/usr/lib/aarch64-linux-gnu/libnot-approved.so"

# A pacman-owned collision is rejected unless it is the exact reviewed SNS
# replacement path and both sides are regular files.
install -D -m 0644 /dev/null "$rootfs_dir/usr/bin/stock-file"
install -D -m 0644 /dev/null "$stage/usr/bin/stock-file"
PACMAN_OWNER_MODE=stock
expect_rejected "unapproved pacman owner" \
  validate_arch_import_relative_path usr/bin/stock-file "$stage/usr/bin/stock-file"

install -D -m 0644 /dev/null "$rootfs_dir/usr/libexec/iio-sensor-proxy"
install -D -m 0644 /dev/null "$stage/usr/libexec/iio-sensor-proxy"
PACMAN_OWNER_MODE=iio
expect_accepted "exact iio-sensor-proxy replacement" \
  validate_arch_import_relative_path usr/libexec/iio-sensor-proxy \
  "$stage/usr/libexec/iio-sensor-proxy" \
  deb:qcom-sns-iio-sensor-proxy_20260627.1_arm64.deb:abc123

expect_rejected "iio path spoofed by another source package" \
  validate_arch_import_relative_path usr/libexec/iio-sensor-proxy \
  "$stage/usr/libexec/iio-sensor-proxy" \
  deb:tb321fu-sensors_20260627.1_arm64.deb:abc123

PACMAN_OWNER_MODE=error
expect_rejected "pacman ownership query failure" \
  validate_arch_import_relative_path usr/libexec/iio-sensor-proxy \
  "$stage/usr/libexec/iio-sensor-proxy" \
  deb:qcom-sns-iio-sensor-proxy_20260627.1_arm64.deb:abc123

ln -s fixture "$stage/usr/libexec/iio-sensor-proxy-link"
install -D -m 0644 /dev/null "$rootfs_dir/usr/libexec/iio-sensor-proxy-link"
PACMAN_OWNER_MODE=iio
expect_rejected "symlink replacing pacman-owned file" \
  validate_arch_import_relative_path usr/libexec/iio-sensor-proxy-link \
  "$stage/usr/libexec/iio-sensor-proxy-link" \
  deb:qcom-sns-iio-sensor-proxy_20260627.1_arm64.deb:abc123

ln -s /tmp "$rootfs_dir/usr/bin/unowned-link"
install -D -m 0644 /dev/null "$stage/usr/bin/unowned-link"
PACMAN_OWNER_MODE=unowned
expect_rejected "symlink replacing unowned rootfs path" \
  validate_arch_import_relative_path usr/bin/unowned-link "$stage/usr/bin/unowned-link"

install -D -m 0644 /dev/null "$rootfs_dir/usr/bin/unowned-regular"
ln -s fixture "$stage/usr/bin/unowned-regular"
expect_rejected "symlink replacing unowned regular file" \
  validate_arch_import_relative_path usr/bin/unowned-regular "$stage/usr/bin/unowned-regular"

# The aggregate package may replace Arch's stock iio-sensor-proxy only when
# the exact reviewed source and all seven replacement files are present.
iio_stage="$tmp/iio-relations"
iio_sources="$tmp/iio-sources.tsv"
mkdir -p "$iio_stage"
printf 'source_id\n' > "$iio_sources"
empty_iio_relations=$(arch_import_iio_sensor_proxy_relation_lines "$iio_stage" "$iio_sources")
[ "$empty_iio_relations" = $'provides=()\nconflicts=()\nreplaces=()' ] ||
  fail "sensor-absent import unexpectedly replaces the stock proxy"
for relative in \
  usr/bin/monitor-sensor \
  usr/libexec/iio-sensor-proxy \
  usr/lib/systemd/system/iio-sensor-proxy.service \
  usr/lib/udev/rules.d/80-iio-sensor-proxy.rules \
  usr/share/dbus-1/system-services/net.hadess.SensorProxy.service \
  usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf \
  usr/share/polkit-1/actions/net.hadess.SensorProxy.policy; do
  install -D -m 0644 /dev/null "$iio_stage/$relative"
done
printf '%s\n' \
  'deb:qcom-sns-iio-sensor-proxy_20260627.1_arm64.deb:b010a9a783629c4e0fd4c404b1a34e14258fab8a674d0499d553d361cb59a843' \
  >> "$iio_sources"
full_iio_relations=$(arch_import_iio_sensor_proxy_relation_lines "$iio_stage" "$iio_sources")
[ "$full_iio_relations" = $'provides=(\x27iio-sensor-proxy\x27)\nconflicts=(\x27iio-sensor-proxy\x27)\nreplaces=(\x27iio-sensor-proxy\x27)' ] ||
  fail "sensor-present import did not declare the complete ownership transfer"
rm -f "$iio_stage/usr/bin/monitor-sensor"
expect_rejected "partial iio-sensor-proxy transfer closure" \
  arch_import_iio_sensor_proxy_relation_lines "$iio_stage" "$iio_sources"

# Camera input is an exact copy of the reviewed repository overlay.  The
# checksum file plus fixed symlink/mode contract rejects unknown ordinary
# members before the tree is turned into a native Arch package.
camera="$tmp/camera"
mkdir -p "$camera"
cp -a "$REPO_ROOT/source/tb321fu-camera-rootfs-overlay/rootfs-overlay"/. "$camera"/
expect_accepted "canonical camera stage" validate_camera_stack_stage "$camera"

# The five symlinks below are the complete link set in the tested Ubuntu
# camera overlay: four relative libcamera SONAME links and one fixed absolute
# GStreamer compatibility link.  Their resolved targets must remain regular
# files inside the stage.
camera_links="$tmp/camera-links"
cp -a "$camera"/. "$camera_links"/
expect_accepted "canonical camera symlinks" validate_camera_stack_stage "$camera_links"

# Keep the repository's actual tested overlay covered as well as the minimal
# synthetic contract above; this catches accidental drift in link names or
# targets without invoking a rootfs build.
camera_repo="$tmp/camera-repository"
cp -a "$SCRIPT_DIR/../../source/tb321fu-camera-rootfs-overlay/rootfs-overlay"/. "$camera_repo"/
expect_accepted "repository camera overlay" validate_camera_stack_stage "$camera_repo"

camera_bad="$tmp/camera-bad-link"
cp -a "$camera_links"/. "$camera_bad"/
ln -s ../../../../etc/passwd "$camera_bad/opt/libcamera-y700/unsafe-link"
expect_rejected "camera path-traversing symlink" validate_camera_stack_stage "$camera_bad"

camera_bad="$tmp/camera-bad-absolute-link"
cp -a "$camera_links"/. "$camera_bad"/
ln -s /etc/passwd "$camera_bad/opt/libcamera-y700/unsafe-link"
expect_rejected "camera arbitrary absolute symlink" validate_camera_stack_stage "$camera_bad"

camera_bad="$tmp/camera-bad-contained-link"
cp -a "$camera_links"/. "$camera_bad"/
ln -s libcamera.so.0.7.1 "$camera_bad/opt/libcamera-y700/lib/aarch64-linux-gnu/unexpected.so"
expect_rejected "camera unapproved contained symlink" validate_camera_stack_stage "$camera_bad"

camera_bad="$tmp/camera-bad-root-mode"
cp -a "$camera_links"/. "$camera_bad"/
chmod 0777 "$camera_bad"
expect_rejected "camera non-canonical root mode" validate_camera_stack_stage "$camera_bad"

# A marker reachable only through a symlink outside the archive/input root
# must not be selected and copied by the later rsync step.
camera_input="$tmp/camera-input"
camera_outside="$tmp/camera-outside"
mkdir -p "$camera_input" "$camera_outside/rootfs-overlay/opt/libcamera-y700" \
  "$camera_outside/rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera"
install -m 0644 /dev/null \
  "$camera_outside/rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so"
ln -s "$camera_outside/rootfs-overlay" "$camera_input/rootfs-overlay"
expect_rejected "camera source root escaping input" find_camera_source_root "$camera_input"

mkdir -p "$camera/lib"
expect_rejected "camera top-level /lib" validate_camera_stack_stage "$camera"
rm -rf -- "$camera/lib"

mkdir -p "$camera/etc"
install -m 0644 /dev/null "$camera/etc/evil"
expect_rejected "camera unknown etc file" validate_camera_stack_stage "$camera"
rm -f -- "$camera/etc/evil"

mkdir -p "$camera/usr/bin"
install -m 0755 /dev/null "$camera/usr/bin/evil"
expect_rejected "camera unknown usr bin file" validate_camera_stack_stage "$camera"
rm -f -- "$camera/usr/bin/evil"

mkdir -p "$camera/var"
install -m 0644 /dev/null "$camera/var/evil"
expect_rejected "camera unknown var file" validate_camera_stack_stage "$camera"
rm -rf -- "$camera/var"

mkdir -p "$camera/opt/unknown"
install -m 0644 /dev/null "$camera/opt/unknown/evil"
expect_rejected "camera unknown opt file" validate_camera_stack_stage "$camera"
rm -rf -- "$camera/opt/unknown"

install -D -m 0644 /dev/null "$camera/usr/lib/aarch64-linux-gnu/libunexpected.so"
expect_rejected "camera unallowlisted multiarch file" validate_camera_stack_stage "$camera"
rm -f -- "$camera/usr/lib/aarch64-linux-gnu/libunexpected.so"

mkfifo "$camera/opt/libcamera-y700/unsupported-fifo"
expect_rejected "camera FIFO" validate_camera_stack_stage "$camera"
rm -f -- "$camera/opt/libcamera-y700/unsupported-fifo"

# Imported-release metadata is finalized from the exact staged tree. The
# source provenance file must be covered, while the manifest must not contain
# a checksum for itself; both bytes must also influence the native package
# identity independently of the temporary workspace path.
manifest_stage="$tmp/import-manifest-stage"
manifest_source="$tmp/import-sources.tsv"
manifest_tmp="$tmp/import-payload.sha256"
install -D -m 0644 /dev/stdin "$manifest_stage/usr/bin/imported-tool" <<'PAYLOAD'
payload
PAYLOAD
install -D -m 0644 /dev/stdin "$manifest_stage/usr/share/tb321fu/stale-file" <<'STALE'
stale
STALE
printf 'source_id\ndeb:qcom-sns-iio-sensor-proxy_20260627.1_arm64.deb:abc123\n' > "$manifest_source"
# A stale prior manifest must be replaced, not accidentally included in its
# own checksum list.
install -D -m 0644 /dev/stdin \
  "$manifest_stage/usr/share/tb321fu/imported-release-payload.sha256" <<'OLDMANIFEST'
deadbeef  ./old-entry
OLDMANIFEST
write_arch_import_payload_metadata "$manifest_stage" "$manifest_source" "$manifest_tmp"
manifest_path="$manifest_stage/usr/share/tb321fu/imported-release-payload.sha256"
source_path="$manifest_stage/usr/share/tb321fu/imported-release-sources.tsv"
[ -f "$manifest_path" ] && [ ! -L "$manifest_path" ] || fail "final import manifest is missing"
[ -f "$source_path" ] && [ ! -L "$source_path" ] || fail "final import source metadata is missing"
cmp -s "$manifest_source" "$source_path" || fail "source provenance bytes changed during finalization"
(cd "$manifest_stage" && sha256sum -c ./usr/share/tb321fu/imported-release-payload.sha256) >/dev/null || \
  fail "final import manifest does not verify staged payload"
grep -Fq './usr/share/tb321fu/imported-release-sources.tsv' "$manifest_path" || \
  fail "final import manifest omits source provenance"
if grep -Fq './usr/share/tb321fu/imported-release-payload.sha256' "$manifest_path"; then
  fail "final import manifest recursively references itself"
fi
hash_before=$(compute_arch_import_package_hash "$manifest_stage" "$manifest_path" "$source_path")
identity_lines="$tmp/package-identity.txt"
write_arch_package_tree_identity "$manifest_stage" | tr '\0' '\n' > "$identity_lines"
awk -F '\t' '$6 == "." { found = 1; if ($5 != "0") exit 2 } END { if (!found) exit 3 }' \
  "$identity_lines" || fail "package identity did not normalize directory size"

# Rebuild the same payload below a directory with deliberately different inode
# allocation history. Its content identity and package version must match.
manifest_clone="$tmp/import-manifest-clone"
mkdir -p "$manifest_clone"
for ((i=0; i<4096; i++)); do
  : > "$manifest_clone/.directory-churn-$i"
done
rm -f "$manifest_clone"/.directory-churn-*
cp -a "$manifest_stage"/. "$manifest_clone"/
[ "$(stat -c '%s' "$manifest_clone")" != "$(stat -c '%s' "$manifest_stage")" ] ||
  fail "directory rebuild fixture did not create distinct inode allocation"
hash_clone=$(compute_arch_import_package_hash \
  "$manifest_clone" \
  "$manifest_clone/usr/share/tb321fu/imported-release-payload.sha256" \
  "$manifest_clone/usr/share/tb321fu/imported-release-sources.tsv")
[ "$hash_clone" = "$hash_before" ] ||
  fail "identical package trees rebuilt in different directories have different identities"
printf 'payload-mutated\n' > "$manifest_stage/usr/bin/imported-tool"
hash_payload=$(compute_arch_import_package_hash "$manifest_stage" "$manifest_path" "$source_path")
[ "$hash_before" != "$hash_payload" ] || fail "payload content did not change package identity"
printf 'source_id\nchanged-source\n' > "$source_path"
hash_source=$(compute_arch_import_package_hash "$manifest_stage" "$manifest_path" "$source_path")
[ "$hash_payload" != "$hash_source" ] || fail "source provenance content did not change package identity"
# Temporary files are outside the package tree and are not left as payload
# members; the final tree retains only the two intended metadata files.
[ ! -e "$manifest_stage/$manifest_tmp" ] || fail "temporary manifest leaked into staged tree"

printf 'ARCH_IMPORT_BOUNDARY_FIXTURES=PASS\n'
