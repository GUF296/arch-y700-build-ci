#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

# A tagged release is a closed profile.  Artifact-only runs intentionally keep
# local/source overrides for development, but they must never be able to turn
# into a public release accidentally.
readonly APPROVED_ARCH_ROOTFS_URL=https://ca.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
readonly APPROVED_ARCH_ROOTFS_SHA256=42a4eeaa038994ffd31fa173256ef2f0ef511358eeb41b9ea1f8626391b9b319
readonly APPROVED_ARCH_MIRROR='https://ca.us.mirror.archlinuxarm.org/$arch/$repo'
readonly APPROVED_DEVICE_DEB_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-device-debs-20260624-201420-compat1.tar.gz
readonly APPROVED_DEVICE_DEB_ARCHIVE_SHA256=047c1baccc420f1c28bf6d761cfc811dd7aeccfcbab6d03746ca01daf6cdfe04
readonly APPROVED_SENSOR_DEB_ARCHIVE=https://github.com/GUF296/tb321fu-sensor-debs/releases/download/tb321fu-sensor-debs-20260627.1/tb321fu-sensor-debs_20260627.1_arm64.tar.gz
readonly APPROVED_SENSOR_DEB_ARCHIVE_SHA256=62ebf6fb41730b9f52da2efc99ac5807fd41dd39d7f97dea070ba5f5ce34ab10
readonly APPROVED_HAPTICS_DEB_ARCHIVE=https://github.com/GUF296/tb321fu-haptics-debs/releases/download/tb321fu-haptics-debs-20260627.2/tb321fu-haptics-debs_20260627.2_arm64.tar.gz
readonly APPROVED_HAPTICS_DEB_ARCHIVE_SHA256=5a87f510ad07ba60a8a2a663a0782e6f186a56b1586d52c816425fab45b20a37
readonly APPROVED_BOOT_TEMPLATE_IMAGE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-verified-grub-template-userdata-20260624-201420.img
readonly APPROVED_BOOT_TEMPLATE_IMAGE_SHA256=7136020f5c736e13772980af5d22652e71281f34ce3da7b22add928a62ebd194
readonly APPROVED_KERNEL_ARTIFACT_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-kernel-artifacts-7.1.1-g5df8e852ea72.tar.gz
readonly APPROVED_KERNEL_ARTIFACT_ARCHIVE_SHA256=86ea0190e3a073a8ce94e1d6f74dcc3482457a0b9161c2ff968aaeb0f1147188
readonly APPROVED_PACKAGE_LIST=
readonly APPROVED_QCOMRAMP_CFG_NAME=qcomramp.cfg
readonly APPROVED_DTB_NAME=sm8650-lenovo-tb321fu.dtb
readonly APPROVED_Y700_DIRECT_BOOT_RESERVED_MEMORY='/reserved-memory/qdss@82800000 /reserved-memory/splash-region /reserved-memory/trust-ui-vm@f3800000 /reserved-memory/oem-vm@f7c00000'

usage() {
  cat <<'USAGE'
Usage: validate-release-input-provenance.sh

With RELEASE_TAG set, validate the complete Arch release input profile.
Without RELEASE_TAG, return success so artifact-only development remains flexible.
USAGE
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

RELEASE_TAG=${RELEASE_TAG:-}
[ -n "$RELEASE_TAG" ] || exit 0
[[ "$RELEASE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
  ci_die 'release tag has unsafe characters'
[ "${PRERELEASE:-0}" = 1 ] || ci_die 'tagged Arch releases must set prerelease=true'

require_value() {
  local label=$1 actual=$2 expected=$3
  [ "$actual" = "$expected" ] || ci_die "tagged release requires the approved $label"
}

require_empty() {
  local label=$1 actual=$2
  [ -z "$actual" ] || ci_die "tagged release does not accept $label overrides"
}

require_url_digest() {
  local label=$1 url=$2 digest=$3 expected_url=$4 expected_digest=$5
  ci_validate_https_url "$label" "$url"
  ci_validate_sha256 "${label}_SHA256" "$digest"
  require_value "$label" "$url" "$expected_url"
  require_value "${label}_SHA256" "$digest" "$expected_digest"
}

require_url_digest ARCH_ROOTFS_URL \
  "${ARCH_ROOTFS_URL:-}" "${ARCH_ROOTFS_SHA256:-}" \
  "$APPROVED_ARCH_ROOTFS_URL" "$APPROVED_ARCH_ROOTFS_SHA256"
require_value ARCH_MIRROR "${ARCH_MIRROR:-}" "$APPROVED_ARCH_MIRROR"
require_url_digest DEVICE_DEB_ARCHIVE \
  "${DEVICE_DEB_ARCHIVE:-}" "${DEVICE_DEB_ARCHIVE_SHA256:-}" \
  "$APPROVED_DEVICE_DEB_ARCHIVE" "$APPROVED_DEVICE_DEB_ARCHIVE_SHA256"
require_url_digest SENSOR_DEB_ARCHIVE \
  "${SENSOR_DEB_ARCHIVE:-}" "${SENSOR_DEB_ARCHIVE_SHA256:-}" \
  "$APPROVED_SENSOR_DEB_ARCHIVE" "$APPROVED_SENSOR_DEB_ARCHIVE_SHA256"
require_url_digest HAPTICS_DEB_ARCHIVE \
  "${HAPTICS_DEB_ARCHIVE:-}" "${HAPTICS_DEB_ARCHIVE_SHA256:-}" \
  "$APPROVED_HAPTICS_DEB_ARCHIVE" "$APPROVED_HAPTICS_DEB_ARCHIVE_SHA256"
require_url_digest BOOT_TEMPLATE_IMAGE \
  "${BOOT_TEMPLATE_IMAGE:-}" "${BOOT_TEMPLATE_IMAGE_SHA256:-}" \
  "$APPROVED_BOOT_TEMPLATE_IMAGE" "$APPROVED_BOOT_TEMPLATE_IMAGE_SHA256"
require_url_digest KERNEL_ARTIFACT_ARCHIVE \
  "${KERNEL_ARTIFACT_ARCHIVE:-}" "${KERNEL_ARTIFACT_ARCHIVE_SHA256:-}" \
  "$APPROVED_KERNEL_ARTIFACT_ARCHIVE" "$APPROVED_KERNEL_ARTIFACT_ARCHIVE_SHA256"

for pair in \
  'DEVICE_DEB_DIR' 'SENSOR_DEB_DIR' 'HAPTICS_DEB_DIR' \
  'CAMERA_STACK_DIR' 'TB321FU_GPU_SENSOR_SOURCE_DIR' 'OVERLAY_DIR' \
  'CAMERA_STACK_ARCHIVE' 'CAMERA_STACK_ARCHIVE_SHA256' \
  'TB321FU_GPU_SENSOR_SOURCE_ARCHIVE' 'TB321FU_GPU_SENSOR_SOURCE_ARCHIVE_SHA256' \
  'OVERLAY_ARCHIVE' 'OVERLAY_ARCHIVE_SHA256' \
  'BOOT_TEMPLATE_IMAGE_URL' 'BOOTAA64_EFI' 'BOOTAA64_EFI_URL' \
  'QCOMRAMP_EFI' 'QCOMRAMP_EFI_URL' 'Y700_GRUB_BUILD_DIR' \
  'KERNEL_IMAGE' 'DTB_FILE' 'KERNEL_CONFIG' 'ROOT_UUID' 'ROOTARGS' 'ROOTARGS_EXTRA'; do
  require_empty "$pair" "${!pair:-}"
done

require_value OUTPUT_PREFIX "${OUTPUT_PREFIX:-}" TB321FU-archlinuxarm-plasma-aarch64
require_value PACKAGE_LIST "${PACKAGE_LIST:-}" "$APPROVED_PACKAGE_LIST"
require_value DESKTOP_PROFILE "${DESKTOP_PROFILE:-}" standard
require_value ROOTFS_IMAGE_SIZE "${ROOTFS_IMAGE_SIZE:-}" 20G
require_value ROOTFS_LABEL "${ROOTFS_LABEL:-}" ArchLinux
require_value ROOTFS_PARTLABEL "${ROOTFS_PARTLABEL:-}" userdata
require_value HOSTNAME_NAME "${HOSTNAME_NAME:-}" GUF296
require_value DEFAULT_USER_NAME "${DEFAULT_USER_NAME:-}" GUF296
require_value ROOT_PASSWORD_MODE "${ROOT_PASSWORD_MODE:-}" locked
require_value USER_SUDO_MODE "${USER_SUDO_MODE:-}" password
require_value SDDM_AUTOLOGIN "${SDDM_AUTOLOGIN:-}" 1
require_value SDDM_AUTOLOGIN_SESSION "${SDDM_AUTOLOGIN_SESSION:-}" plasma
require_value TZ_REGION "${TZ_REGION:-}" Asia/Shanghai
require_value LOCALES "${LOCALES:-}" 'en_US.UTF-8 zh_CN.UTF-8'
require_value LANG_NAME "${LANG_NAME:-}" zh_CN.UTF-8
require_value INSTALL_FCITX5_CHINESE "${INSTALL_FCITX5_CHINESE:-}" 1
require_value INSTALL_FIREFOX "${INSTALL_FIREFOX:-}" 1
require_value INSTALL_CAMERA_APPS "${INSTALL_CAMERA_APPS:-}" 1
require_value BUILD_TB321FU_GPU_SENSOR "${BUILD_TB321FU_GPU_SENSOR:-}" 1
require_value TB321FU_GPU_SENSOR_BUILD_JOBS "${TB321FU_GPU_SENSOR_BUILD_JOBS:-}" 2
require_value KERNEL_VERSION "${KERNEL_VERSION:-}" 7.1.1-g5df8e852ea72
require_value APPLY_Y700_FIRMWARE_FIXES "${APPLY_Y700_FIRMWARE_FIXES:-}" 1
require_value APPLY_Y700_AUDIO_POLICY_FIXES "${APPLY_Y700_AUDIO_POLICY_FIXES:-}" 1
require_value COMPRESS "${COMPRESS:-}" 7z
require_empty CHUNK_SIZE "${CHUNK_SIZE:-}"
require_value KEEP_RAW_IMAGE "${KEEP_RAW_IMAGE:-}" 0
require_value BOOT_IMAGE_SIZE "${BOOT_IMAGE_SIZE:-}" 256M
require_value BOOT_FAT_BITS "${BOOT_FAT_BITS:-}" 32
require_value BOOT_FAT_LABEL "${BOOT_FAT_LABEL:-}" Y700GRUB
require_value BOOT_FAT_VOLUME_ID "${BOOT_FAT_VOLUME_ID:-}" 00000000
require_value BOOT_SECTOR_SIZE "${BOOT_SECTOR_SIZE:-}" 512
require_empty BOOT_CLUSTER_SECTORS "${BOOT_CLUSTER_SECTORS:-}"
require_value GRUB_TIMEOUT "${GRUB_TIMEOUT:-}" 3
require_value Y700_DIRECT_BOOT_EFI_NAME "${Y700_DIRECT_BOOT_EFI_NAME:-}" QCOMRAMP.EFI
require_value QCOMRAMP_CFG_NAME "${QCOMRAMP_CFG_NAME:-}" "$APPROVED_QCOMRAMP_CFG_NAME"
require_value DTB_NAME "${DTB_NAME:-}" "$APPROVED_DTB_NAME"
require_value Y700_DIRECT_BOOT_RESERVED_MEMORY "${Y700_DIRECT_BOOT_RESERVED_MEMORY:-}" "$APPROVED_Y700_DIRECT_BOOT_RESERVED_MEMORY"
require_value ROOT_SELECTOR "${ROOT_SELECTOR:-}" partlabel
require_value STABLEARGS "${STABLEARGS:-}" drm_client_lib.active=none
require_value BOOT_COMPRESS "${BOOT_COMPRESS:-}" 7z
require_empty BOOT_CHUNK_SIZE "${BOOT_CHUNK_SIZE:-}"
require_value KEEP_BOOT_IMAGE "${KEEP_BOOT_IMAGE:-}" 0

# Secrets may be empty (the build then creates locked accounts), but a release
# profile must never carry plaintext or shell/control syntax in their place.
for secret_name in DEFAULT_USER_PASSWORD_HASH ROOT_PASSWORD_HASH; do
  secret_value=${!secret_name:-}
  [[ ${#secret_value} -le 512 && "$secret_value" != *$'\n'* && "$secret_value" != *$'\r'* &&
     "$secret_value" != *' '* && "$secret_value" != *';'* && "$secret_value" != *'|'* &&
     "$secret_value" != *'`'* && "$secret_value" != *'"'* && "$secret_value" != *"'"* ]] ||
    ci_die "$secret_name contains unsafe material"
done

# Arch Linux ARM is a rolling distribution.  The currently available public
# mirror profile exposes neither a dated repository snapshot nor a complete,
# digest-locked package/dependency closure.  A base rootfs SHA and HTTPS
# mirror therefore cannot make a tagged image reproducible.  Keep rolling
# builds available as artifact-only diagnostics, but fail before any release
# publisher can create a public tag until a verified closure implementation is
# supplied and reviewed.
ci_die 'tagged Arch releases are disabled until a content-locked repository/package closure is supplied; leave RELEASE_TAG empty for artifact-only rolling builds'

printf 'RELEASE_INPUT_PROVENANCE=PASS\n'
