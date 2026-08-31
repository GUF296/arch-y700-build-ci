#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"
provenance="$SCRIPT_DIR/validate-release-input-provenance.sh"
repo_root=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)

set_approved_profile() {
  # Keep this fixture explicit so a tagged run is tested with the same closed
  # profile that the workflow writes before invoking the provenance gate.
  export RELEASE_TAG=test PRERELEASE=1
  export ARCH_ROOTFS_URL=https://ca.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
  export ARCH_ROOTFS_SHA256=42a4eeaa038994ffd31fa173256ef2f0ef511358eeb41b9ea1f8626391b9b319
  export ARCH_MIRROR='https://ca.us.mirror.archlinuxarm.org/$arch/$repo'
  export DEVICE_DEB_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-device-debs-20260624-201420-compat1.tar.gz
  export DEVICE_DEB_ARCHIVE_SHA256=047c1baccc420f1c28bf6d761cfc811dd7aeccfcbab6d03746ca01daf6cdfe04
  export SENSOR_DEB_ARCHIVE=https://github.com/GUF296/tb321fu-sensor-debs/releases/download/tb321fu-sensor-debs-20260627.1/tb321fu-sensor-debs_20260627.1_arm64.tar.gz
  export SENSOR_DEB_ARCHIVE_SHA256=62ebf6fb41730b9f52da2efc99ac5807fd41dd39d7f97dea070ba5f5ce34ab10
  export HAPTICS_DEB_ARCHIVE=https://github.com/GUF296/tb321fu-haptics-debs/releases/download/tb321fu-haptics-debs-20260627.2/tb321fu-haptics-debs_20260627.2_arm64.tar.gz
  export HAPTICS_DEB_ARCHIVE_SHA256=5a87f510ad07ba60a8a2a663a0782e6f186a56b1586d52c816425fab45b20a37
  export BOOT_TEMPLATE_IMAGE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-verified-grub-template-userdata-20260624-201420.img
  export BOOT_TEMPLATE_IMAGE_SHA256=7136020f5c736e13772980af5d22652e71281f34ce3da7b22add928a62ebd194
  export KERNEL_ARTIFACT_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-kernel-artifacts-7.1.1-g5df8e852ea72.tar.gz
  export KERNEL_ARTIFACT_ARCHIVE_SHA256=86ea0190e3a073a8ce94e1d6f74dcc3482457a0b9161c2ff968aaeb0f1147188
  export OUTPUT_PREFIX=TB321FU-archlinuxarm-plasma-aarch64 PACKAGE_LIST=
  export DESKTOP_PROFILE=standard ROOTFS_IMAGE_SIZE=20G ROOTFS_LABEL=ArchLinux
  export ROOTFS_PARTLABEL=userdata HOSTNAME_NAME=GUF296 DEFAULT_USER_NAME=GUF296
  export ROOT_PASSWORD_MODE=locked USER_SUDO_MODE=password SDDM_AUTOLOGIN=1
  export SDDM_AUTOLOGIN_SESSION=plasma TZ_REGION=Asia/Shanghai
  export LOCALES='en_US.UTF-8 zh_CN.UTF-8' LANG_NAME=zh_CN.UTF-8
  export INSTALL_FCITX5_CHINESE=1 INSTALL_FIREFOX=1 INSTALL_CAMERA_APPS=1
  export BUILD_TB321FU_GPU_SENSOR=1 TB321FU_GPU_SENSOR_BUILD_JOBS=2
  export KERNEL_VERSION=7.1.1-g5df8e852ea72 APPLY_Y700_FIRMWARE_FIXES=1
  export APPLY_Y700_AUDIO_POLICY_FIXES=1 COMPRESS=7z KEEP_RAW_IMAGE=0
  export BOOT_IMAGE_SIZE=256M BOOT_FAT_BITS=32 BOOT_FAT_LABEL=Y700GRUB
  export BOOT_FAT_VOLUME_ID=00000000 BOOT_SECTOR_SIZE=512 GRUB_TIMEOUT=3
  export Y700_DIRECT_BOOT_EFI_NAME=QCOMRAMP.EFI
  export QCOMRAMP_CFG_NAME=qcomramp.cfg DTB_NAME=sm8650-lenovo-tb321fu.dtb
  export Y700_DIRECT_BOOT_RESERVED_MEMORY='/reserved-memory/qdss@82800000 /reserved-memory/splash-region /reserved-memory/trust-ui-vm@f3800000 /reserved-memory/oem-vm@f7c00000'
  export ROOT_SELECTOR=partlabel STABLEARGS=drm_client_lib.active=none
  export BOOT_COMPRESS=7z KEEP_BOOT_IMAGE=0
  export DEFAULT_USER_PASSWORD_HASH= ROOT_PASSWORD_HASH=

  # These are intentionally empty in the approved profile.  Unsetting first
  # prevents a caller's exported development override from leaking in.
  unset DEVICE_DEB_DIR SENSOR_DEB_DIR HAPTICS_DEB_DIR CAMERA_STACK_DIR \
    TB321FU_GPU_SENSOR_SOURCE_DIR OVERLAY_DIR CAMERA_STACK_ARCHIVE \
    CAMERA_STACK_ARCHIVE_SHA256 TB321FU_GPU_SENSOR_SOURCE_ARCHIVE \
    TB321FU_GPU_SENSOR_SOURCE_ARCHIVE_SHA256 OVERLAY_ARCHIVE \
    OVERLAY_ARCHIVE_SHA256 BOOT_TEMPLATE_IMAGE_URL BOOTAA64_EFI \
    BOOTAA64_EFI_URL QCOMRAMP_EFI QCOMRAMP_EFI_URL Y700_GRUB_BUILD_DIR \
    KERNEL_IMAGE DTB_FILE KERNEL_CONFIG ROOT_UUID ROOTARGS ROOTARGS_EXTRA \
    CHUNK_SIZE BOOT_CLUSTER_SECTORS BOOT_CHUNK_SIZE
}

run_approved_profile() {
  set_approved_profile
  bash "$provenance"
}

run_profile_override() {
  local name=$1 value=$2
  set_approved_profile
  printf -v "$name" '%s' "$value"
  export "$name"
  bash "$provenance"
}

# Development artifact runs remain a no-op for the release-only gate.
env -i PATH=/usr/bin:/bin RELEASE_TAG= PRERELEASE=0 bash "$provenance"

set +e
approved_output=$(run_approved_profile 2>&1)
approved_status=$?
set -e
[ "$approved_status" -ne 0 ] || {
  echo 'accepted a tagged Arch profile without a content-locked package closure' >&2
  exit 1
}
grep -Fq -- 'tagged Arch releases are disabled until a content-locked repository/package closure is supplied' <<< "$approved_output" || {
  echo 'tagged Arch release did not fail at the explicit rolling-closure boundary' >&2
  printf '%s\n' "$approved_output" >&2
  exit 1
}

for fixture in \
  'PACKAGE_LIST linux' \
  'QCOMRAMP_CFG_NAME other.cfg' \
  'DTB_NAME other.dtb' \
  'Y700_DIRECT_BOOT_RESERVED_MEMORY /reserved-memory/qdss@82800000'; do
  fixture_name=${fixture%% *}
  fixture_value=${fixture#* }
  if run_profile_override "$fixture_name" "$fixture_value" >/dev/null 2>&1; then
    echo "accepted hostile tagged profile override: $fixture_name" >&2
    exit 1
  fi
done

if env -i PATH=/usr/bin:/bin RELEASE_TAG=test PRERELEASE=0 bash "$provenance" >/dev/null 2>&1; then
  echo 'accepted a non-prerelease tagged build' >&2
  exit 1
fi

for hostile in \
  'http://mirror.example/$arch/$repo' \
  'https://mirror.example/$arch/$repo?redirect=1' \
  'https://user:pass@mirror.example/$arch/$repo' \
  'https://mirror.example/$arch/$repo;touch'; do
  if (ci_validate_arch_mirror "$hostile") >/dev/null 2>&1; then
    echo "accepted hostile Arch mirror: $hostile" >&2
    exit 1
  fi
done

ci_validate_arch_mirror 'https://ca.us.mirror.archlinuxarm.org/$arch/$repo'
ci_validate_image_size ROOTFS_IMAGE_SIZE 20G 1024 131072
ci_validate_image_size BOOT_IMAGE_SIZE 256M 16 131072
ci_validate_ext4_label ROOTFS_LABEL ArchLinux
ci_validate_hostname GUF296
ci_validate_account_name GUF296
ci_validate_timezone Asia/Shanghai
ci_validate_locale_name LANG_NAME zh_CN.UTF-8
ci_validate_locales 'en_US.UTF-8 zh_CN.UTF-8'
ci_validate_session_name plasma

for check in \
  'ci_validate_rootfs_image_size 0M' \
  'ci_validate_ext4_label ROOTFS_LABEL ../escape' \
  'ci_validate_hostname bad.name' \
  'ci_validate_account_name root' \
  'ci_validate_timezone ../etc' \
  'ci_validate_locale_name LANG_NAME "en_US.UTF-8;touch"' \
  'ci_validate_session_name "plasma;touch"'; do
  if (eval "$check") >/dev/null 2>&1; then
    echo "accepted hostile validator fixture: $check" >&2
    exit 1
  fi
done

workflow="$repo_root/.github/workflows/build-rootfs-and-grub.yml"
config="$repo_root/scripts/ci/apply-workflow-config.sh"
grep -Fq 'bash scripts/ci/validate-release-input-provenance.sh' "$workflow"
grep -Fq 'BOOT_FAT_VOLUME_ID' "$workflow"
grep -Fq 'GRUB_TIMEOUT' "$workflow"
grep -Fq 'Y700_GRUB_BUILD_DIR' "$workflow"
grep -Fq 'tagged Arch releases are disabled until a content-locked repository/package closure is supplied' "$workflow"
grep -Fq 'artifact-only output' "$workflow"
grep -Fq 'Arch Linux ARM is a rolling distribution' "$repo_root/README.md"
grep -Fq 'byte-for-byte reproducible or publishable Arch release' "$repo_root/README.md"
if grep -Fq 'GRUB_BUILD_ARCHIVE' "$workflow" "$config" "$repo_root/scripts/ci/build-grub-image.sh" "$repo_root/README.md" "$repo_root/scripts/ci/validate-release-input-provenance.sh"; then
  echo 'dead GRUB_BUILD_ARCHIVE interface remains' >&2
  exit 1
fi

echo 'RELEASE_INPUT_PROVENANCE_FIXTURES=PASS'
