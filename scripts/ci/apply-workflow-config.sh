#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") CONFIG_FILE

Read KEY=value lines from CONFIG_FILE and append allowed keys to GITHUB_ENV.
Blank lines and lines starting with # are ignored.
USAGE
}

[ "${1:-}" != "--help" ] || { usage; exit 0; }
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
[ -n "${GITHUB_ENV:-}" ] || { echo 'GITHUB_ENV is not set' >&2; exit 1; }

config_file=$1
[ -f "$config_file" ] || { echo "missing config file: $config_file" >&2; exit 1; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/../lib/y700-direct-grub.sh"

# The workflow passes three different files through this helper.  Keep their
# namespaces disjoint so a boot/source override cannot silently alter rootfs
# provisioning (or vice versa).
if ! cmp -s "$config_file" <(LC_ALL=C tr -d '\000' < "$config_file"); then
  echo 'workflow config contains a NUL byte' >&2
  exit 1
fi

rootfs_allowed=' ARCH_ROOTFS_URL ARCH_ROOTFS_SHA256 ARCH_MIRROR ROOTFS_IMAGE_SIZE ROOTFS_LABEL ROOTFS_PARTLABEL HOSTNAME_NAME DEFAULT_USER_NAME DEFAULT_USER_PASSWORD ROOT_PASSWORD_MODE ROOT_PASSWORD USER_SUDO_MODE SDDM_AUTOLOGIN SDDM_AUTOLOGIN_SESSION TZ_REGION LOCALES LANG_NAME DESKTOP_PROFILE PACKAGE_LIST INSTALL_FCITX5_CHINESE INSTALL_FIREFOX INSTALL_CAMERA_APPS DEVICE_DEB_ARCHIVE DEVICE_DEB_ARCHIVE_SHA256 DEVICE_DEB_DIR SENSOR_DEB_ARCHIVE SENSOR_DEB_ARCHIVE_SHA256 SENSOR_DEB_DIR HAPTICS_DEB_ARCHIVE HAPTICS_DEB_ARCHIVE_SHA256 HAPTICS_DEB_DIR CAMERA_STACK_ARCHIVE CAMERA_STACK_ARCHIVE_SHA256 CAMERA_STACK_DIR BUILD_TB321FU_GPU_SENSOR TB321FU_GPU_SENSOR_SOURCE_ARCHIVE TB321FU_GPU_SENSOR_SOURCE_ARCHIVE_SHA256 TB321FU_GPU_SENSOR_SOURCE_DIR TB321FU_GPU_SENSOR_BUILD_JOBS OVERLAY_ARCHIVE OVERLAY_ARCHIVE_SHA256 OVERLAY_DIR KERNEL_VERSION APPLY_Y700_FIRMWARE_FIXES APPLY_Y700_AUDIO_POLICY_FIXES COMPRESS CHUNK_SIZE KEEP_RAW_IMAGE OUTPUT_DIR OUTPUT_PREFIX '
boot_allowed=' BOOT_TEMPLATE_IMAGE BOOT_TEMPLATE_IMAGE_URL BOOT_TEMPLATE_IMAGE_SHA256 BOOT_IMAGE_SIZE BOOT_FAT_BITS BOOT_FAT_LABEL BOOT_FAT_VOLUME_ID BOOT_SECTOR_SIZE BOOT_CLUSTER_SECTORS GRUB_TIMEOUT ROOT_SELECTOR ROOT_PARTLABEL ROOT_UUID ROOTARGS ROOTARGS_EXTRA STABLEARGS BOOT_COMPRESS BOOT_CHUNK_SIZE KEEP_BOOT_IMAGE Y700_DIRECT_BOOT_RESERVED_MEMORY '
source_allowed=' KERNEL_ARTIFACT_ARCHIVE KERNEL_ARTIFACT_ARCHIVE_SHA256 KERNEL_IMAGE DTB_FILE KERNEL_CONFIG BOOTAA64_EFI BOOTAA64_EFI_URL BOOTAA64_EFI_SHA256 QCOMRAMP_EFI QCOMRAMP_EFI_URL QCOMRAMP_EFI_SHA256 QCOMRAMP_CFG_NAME Y700_DIRECT_BOOT_EFI_NAME Y700_GRUB_BUILD_DIR DTB_NAME '

case "${config_file##*/}" in
  rootfs.env) config_domain=rootfs; allowed=$rootfs_allowed ;;
  boot.env) config_domain=boot; allowed=$boot_allowed ;;
  source.env) config_domain=source; allowed=$source_allowed ;;
  *)
    echo "cannot determine config domain from file name: $config_file (expected rootfs.env, boot.env, or source.env)" >&2
    exit 1
    ;;
esac

emit_env() {
  local key=$1
  local value=$2
  local random delim attempt
  delim=''
  for attempt in 1 2 3 4 5 6 7 8; do
    random=$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]') || {
      echo "unable to generate a workflow delimiter for $key" >&2
      return 1
    }
    [[ $random =~ ^[[:xdigit:]]{64}$ ]] || continue
    delim="TB321FU_ENV_${key}_${random}"
    [[ $value != *"$delim"* ]] || { delim=''; continue; }
    break
  done
  [ -n "$delim" ] || {
    echo "workflow value contains every generated delimiter for $key" >&2
    return 1
  }
  {
    printf '%s<<%s\n' "$key" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >> "$env_stage"
}

config_keys=()
config_values=()
declare -A config_key_indexes=()

while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in
    ''|'#'*) continue ;;
  esac
  case "$line" in
    *=*) ;;
    *) echo "invalid config line, expected KEY=value: $line" >&2; exit 1 ;;
  esac
  key=${line%%=*}
  value=${line#*=}
  case "$key" in
    *[!A-Z0-9_]*) echo "invalid config key: $key" >&2; exit 1 ;;
  esac
  case "$key" in
    DEFAULT_USER_PASSWORD|ROOT_PASSWORD|DEFAULT_USER_PASSWORD_HASH|ROOT_PASSWORD_HASH)
      echo "password values/hashes must come from repository secrets, not config files: $key" >&2
      exit 1
      ;;
  esac

  case "$allowed" in
    *" $key "*) ;;
    *) echo "config key is not allowed in $config_domain config: $key" >&2; exit 1 ;;
  esac

  case "$key" in
    ARCH_ROOTFS_URL|DEVICE_DEB_ARCHIVE|SENSOR_DEB_ARCHIVE|HAPTICS_DEB_ARCHIVE|CAMERA_STACK_ARCHIVE|TB321FU_GPU_SENSOR_SOURCE_ARCHIVE|OVERLAY_ARCHIVE|BOOT_TEMPLATE_IMAGE|BOOT_TEMPLATE_IMAGE_URL|KERNEL_ARTIFACT_ARCHIVE|BOOTAA64_EFI_URL|QCOMRAMP_EFI_URL)
      if [ -n "$value" ]; then
        case "$value" in
          https://*) ci_validate_https_url "$key" "$value" ;;
          http://*) echo "$key must use HTTPS" >&2; exit 1 ;;
          *) [ -f "$value" ] && [ ! -L "$value" ] || { echo "$key local source is not a regular non-symlink file: $value" >&2; exit 1; } ;;
        esac
      fi
      ;;
    ARCH_ROOTFS_SHA256|DEVICE_DEB_ARCHIVE_SHA256|SENSOR_DEB_ARCHIVE_SHA256|HAPTICS_DEB_ARCHIVE_SHA256|CAMERA_STACK_ARCHIVE_SHA256|TB321FU_GPU_SENSOR_SOURCE_ARCHIVE_SHA256|OVERLAY_ARCHIVE_SHA256|BOOT_TEMPLATE_IMAGE_SHA256|KERNEL_ARTIFACT_ARCHIVE_SHA256|BOOTAA64_EFI_SHA256|QCOMRAMP_EFI_SHA256)
      [ -z "$value" ] || ci_validate_sha256 "$key" "$value"
      ;;
    ARCH_MIRROR) [ -z "$value" ] || ci_validate_arch_mirror "$value" ;;
    ROOTFS_IMAGE_SIZE) ci_validate_rootfs_image_size "$value" ;;
    ROOTFS_LABEL) ci_validate_ext4_label ROOTFS_LABEL "$value" ;;
    ROOTFS_PARTLABEL) ci_validate_partlabel "$value" ;;
    HOSTNAME_NAME) ci_validate_hostname "$value" ;;
    DEFAULT_USER_NAME) ci_validate_account_name "$value" ;;
    TZ_REGION) ci_validate_timezone "$value" ;;
    LANG_NAME) ci_validate_locale_name LANG_NAME "$value" ;;
    LOCALES) ci_validate_locales "$value" ;;
    SDDM_AUTOLOGIN|INSTALL_FCITX5_CHINESE|INSTALL_FIREFOX|INSTALL_CAMERA_APPS|BUILD_TB321FU_GPU_SENSOR|APPLY_Y700_FIRMWARE_FIXES|APPLY_Y700_AUDIO_POLICY_FIXES|KEEP_RAW_IMAGE)
      ci_validate_bool_value "$key" "$value"
      ;;
    TB321FU_GPU_SENSOR_BUILD_JOBS)
      value=$(ci_normalize_decimal_int "$key" "$value")
      (( value >= 1 && value <= 64 )) || { echo "$key must be between 1 and 64" >&2; exit 1; }
      ;;
    ROOT_SELECTOR) case "$value" in partlabel|uuid|raw) ;; *) echo "unsupported ROOT_SELECTOR=$value" >&2; exit 1 ;; esac ;;
    BOOT_FAT_VOLUME_ID) [[ "$value" =~ ^[A-Fa-f0-9]{8}$ ]] || { echo 'BOOT_FAT_VOLUME_ID must contain exactly eight hexadecimal characters' >&2; exit 1; } ;;
    GRUB_TIMEOUT) y700_validate_timeout "$value" || exit 1 ;;
    BOOT_FAT_BITS) [[ "$value" =~ ^(12|16|32)$ ]] || { echo "invalid BOOT_FAT_BITS=$value" >&2; exit 1; } ;;
    BOOT_FAT_LABEL) [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,10}$ ]] || { echo "invalid BOOT_FAT_LABEL=$value" >&2; exit 1; } ;;
    BOOT_SECTOR_SIZE) [[ "$value" =~ ^(512|1024|2048|4096)$ ]] || { echo "invalid BOOT_SECTOR_SIZE=$value" >&2; exit 1; } ;;
    BOOT_CLUSTER_SECTORS) [ -z "$value" ] || { [[ "$value" =~ ^[1-9][0-9]{0,2}$ ]] && (( value <= 128 )) || { echo "invalid BOOT_CLUSTER_SECTORS=$value" >&2; exit 1; }; } ;;
    COMPRESS|BOOT_COMPRESS) case "$value" in none|zstd|xz|7z) ;; *) echo "unsupported $key=$value" >&2; exit 1 ;; esac ;;
    KERNEL_VERSION) [[ -z "$value" || "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || { echo "unsafe KERNEL_VERSION=$value" >&2; exit 1; } ;;
    QCOMRAMP_CFG_NAME) y700_validate_cfg_name "$value" || exit 1 ;;
    Y700_DIRECT_BOOT_EFI_NAME) y700_validate_efi_name "$value" || exit 1 ;;
    Y700_DIRECT_BOOT_RESERVED_MEMORY)
      Y700_DIRECT_BOOT_RESERVED_MEMORY=$value y700_reserved_memory_line >/dev/null || exit 1
      ;;
    DTB_NAME) y700_validate_dtb_name "$value" || exit 1 ;;
    KERNEL_IMAGE|DTB_FILE|KERNEL_CONFIG|BOOTAA64_EFI|QCOMRAMP_EFI)
      [ -f "$value" ] && [ ! -L "$value" ] || {
        echo "$key must be an existing regular non-symlink file: $value" >&2
        exit 1
      }
      ;;
  esac

  # Built-in defaults, advanced overrides and UI values are concatenated in
  # that order.  Resolve duplicates before exporting to make precedence clear.
  if [ -n "${config_key_indexes[$key]+x}" ]; then
    config_values["${config_key_indexes[$key]}"]=$value
  else
    config_key_indexes[$key]=${#config_keys[@]}
    config_keys+=("$key")
    config_values+=("$value")
  fi
done < "$config_file"

if [ "$config_domain" = boot ]; then
  final_template= final_template_url=
  for index in "${!config_keys[@]}"; do
    case "${config_keys[index]}" in
      BOOT_TEMPLATE_IMAGE) final_template=${config_values[index]} ;;
      BOOT_TEMPLATE_IMAGE_URL) final_template_url=${config_values[index]} ;;
    esac
  done
  if [ -n "$final_template" ] && [ -n "$final_template_url" ]; then
    echo 'boot config accepts only one of BOOT_TEMPLATE_IMAGE and BOOT_TEMPLATE_IMAGE_URL' >&2
    exit 1
  fi
fi

if [ "$config_domain" = source ]; then
  final_bootaa64= final_bootaa64_url= final_qcomramp= final_qcomramp_url=
  for index in "${!config_keys[@]}"; do
    case "${config_keys[index]}" in
      BOOTAA64_EFI) final_bootaa64=${config_values[index]} ;;
      BOOTAA64_EFI_URL) final_bootaa64_url=${config_values[index]} ;;
      QCOMRAMP_EFI) final_qcomramp=${config_values[index]} ;;
      QCOMRAMP_EFI_URL) final_qcomramp_url=${config_values[index]} ;;
    esac
  done
  if [ -n "$final_bootaa64" ] && [ -n "$final_bootaa64_url" ]; then
    echo 'source config accepts only one of BOOTAA64_EFI and BOOTAA64_EFI_URL' >&2
    exit 1
  fi
  if [ -n "$final_qcomramp" ] && [ -n "$final_qcomramp_url" ]; then
    echo 'source config accepts only one of QCOMRAMP_EFI and QCOMRAMP_EFI_URL' >&2
    exit 1
  fi
fi

env_stage=$(mktemp "${GITHUB_ENV}.tmp.XXXXXX") || {
  echo 'unable to create private workflow environment staging file' >&2
  exit 1
}
trap 'rm -f -- "${env_stage:-}"' EXIT
for index in "${!config_keys[@]}"; do
  emit_env "${config_keys[index]}" "${config_values[index]}"
done
cat "$env_stage" >> "$GITHUB_ENV"
rm -f -- "$env_stage"
env_stage=
