#!/usr/bin/env bash
set -euo pipefail

ci_log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

ci_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

ci_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || ci_die "required command not found: $1"
}

ci_bool() {
  case "${1:-}" in
    1|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

ci_abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd -P)" "$1" ;;
  esac
}

ci_validate_no_symlink_ancestors() {
  local path=${1:?path is required} label=${2:-path} current

  current=$(ci_abs_path "$path") || return 1
  while :; do
    [ ! -L "$current" ] || {
      printf 'error: %s contains a symlink component: %s\n' "$label" "$current" >&2
      return 1
    }
    [ "$current" = / ] && break
    current=${current%/*}
    [ -n "$current" ] || current=/
  done
}

ci_validate_output_prefix() {
  local value=$1
  [[ ${#value} -le 64 && $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    ci_die "invalid OUTPUT_PREFIX (1-64 characters; letters, digits, dot, underscore and hyphen only): $value"
}

ci_validate_output_dir() {
  local value=$1 component
  local -a components=()
  [[ -n "$value" && ${#value} -le 256 && "$value" != *$'\n'* && "$value" != *$'\r'* ]] ||
    ci_die "invalid OUTPUT_DIR: $value"
  [[ "$value" != /* ]] || ci_die "OUTPUT_DIR must be relative to the repository: $value"
  IFS=/ read -r -a components <<< "$value"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. &&
       "$component" =~ ^[A-Za-z0-9._-]+$ ]] ||
      ci_die "invalid OUTPUT_DIR component: $component"
  done
}

ci_validate_sha256() {
  local label=$1 value=$2
  [[ "$value" =~ ^[A-Fa-f0-9]{64}$ ]] ||
    ci_die "$label must be a 64-character SHA-256 digest"
}

ci_validate_https_url() {
  local label=$1 value=$2 host path
  [[ -n "$value" && ${#value} -le 2048 && "$value" != *$'\n'* && "$value" != *$'\r'* &&
     "$value" != *'"'* && "$value" != *"'"* && "$value" != *';'* &&
     "$value" != *'?'* && "$value" != *'#'* && "$value" != *'\\'* ]] ||
    ci_die "$label must be a simple HTTPS URL"
  [[ "$value" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]{0,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~:/@%+,-]*)?$ ]] ||
    ci_die "$label must be a simple HTTPS URL"
  host=${value#https://}
  host=${host%%/*}
  [[ "$host" != *..* && "$host" != .* && "$host" != *. && "$host" != *:* ]] ||
    ci_die "$label has an invalid host"
  path=${value#https://$host}
  [[ "$path" != *//* ]] || ci_die "$label has an invalid path"
}

ci_validate_arch_mirror() {
  local value=$1 host path prefix component
  [[ -n "$value" && ${#value} -le 512 && "$value" != *$'\n'* && "$value" != *$'\r'* &&
     "$value" != *'"'* && "$value" != *"'"* && "$value" != *';'* &&
     "$value" != *'?'* && "$value" != *'#'* && "$value" != *'\\'* ]] ||
    ci_die "ARCH_MIRROR must be a simple HTTPS Arch mirror URL"
  # Keep the pacman placeholders literal while restricting every preceding
  # path component to URL-safe bytes.  In particular, spaces, shell/config
  # punctuation, encoded separators, and dot-navigation components must not
  # reach pacman's mirrorlist parser.
  [[ "$value" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]{0,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~:@+,-]+)*/\$arch/\$repo$ ]] ||
    ci_die "ARCH_MIRROR must end in /\$arch/\$repo and use HTTPS"
  host=${value#https://}
  host=${host%%/*}
  [[ "$host" != *..* && "$host" != .* && "$host" != *. && "$host" != *:* ]] ||
    ci_die "ARCH_MIRROR has an invalid host"
  path=${value#https://$host}
  prefix=${path%/\$arch/\$repo}
  if [ -n "$prefix" ]; then
    IFS=/ read -r -a components <<< "${prefix#/}"
    for component in "${components[@]}"; do
      [[ "$component" != . && "$component" != .. ]] ||
        ci_die "ARCH_MIRROR contains a relative path component"
    done
  fi
}

ci_validate_rootfs_image_size() {
  ci_validate_image_size ROOTFS_IMAGE_SIZE "$1" 1024 131072
}

ci_validate_image_size() {
  local label=$1 value=$2 min_mib=$3 max_mib=$4 number suffix mib
  [[ "$value" =~ ^([1-9][0-9]{0,6})([MGT])$ ]] ||
    ci_die "$label must be an integer size with M, G or T suffix: $value"
  number=${BASH_REMATCH[1]}
  suffix=${BASH_REMATCH[2]}
  case "$suffix" in
    M) mib=$number ;;
    G) (( number <= 131072 )) || ci_die "$label is too large: $value"; mib=$((number * 1024)) ;;
    T) (( number <= 128 )) || ci_die "$label is too large: $value"; mib=$((number * 1024 * 1024)) ;;
  esac
  (( mib >= min_mib && mib <= max_mib )) ||
    ci_die "$label is outside ${min_mib}MiB..${max_mib}MiB: $value"
}

ci_validate_ext4_label() {
  local label=$1 value=$2
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,15}$ ]] ||
    ci_die "$label must be 1-16 ASCII label characters"
}

ci_validate_partlabel() {
  local value=$1
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,35}$ ]] ||
    ci_die "ROOTFS_PARTLABEL must be 1-36 ASCII label characters"
}

ci_validate_hostname() {
  local value=$1
  [[ ${#value} -le 63 && "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] ||
    ci_die "HOSTNAME_NAME must be a single RFC-compatible hostname label"
}

ci_validate_account_name() {
  local value=$1
  [[ ${#value} -le 32 && "$value" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ ]] ||
    ci_die "DEFAULT_USER_NAME must be a safe Linux account name"
  case "$value" in
    root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|systemd-*|messagebus|_apt)
      ci_die "DEFAULT_USER_NAME is reserved: $value" ;;
  esac
}

ci_validate_locale_name() {
  local label=$1 value=$2
  [[ ${#value} -le 64 && "$value" =~ ^(C|POSIX|[A-Za-z0-9][A-Za-z0-9_.@+-]*)$ ]] ||
    ci_die "$label contains an invalid locale name: $value"
}

ci_validate_locales() {
  local raw=$1 locale
  local -a values=()
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* && "$raw" != *$'\t'* ]] ||
    ci_die "LOCALES must be a whitespace-separated list without control whitespace"
  read -r -a values <<< "$raw"
  [ "${#values[@]}" -gt 0 ] || ci_die "LOCALES must not be empty"
  for locale in "${values[@]}"; do
    ci_validate_locale_name LOCALES "$locale"
  done
}

ci_validate_timezone() {
  local value=$1
  [[ ${#value} -le 128 && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9][A-Za-z0-9._+-]*)*$ ]] ||
    ci_die "TZ_REGION must be a safe zoneinfo relative path"
  [[ "$value" != *../* && "$value" != */.. && "$value" != */./* && "$value" != */. ]] ||
    ci_die "TZ_REGION contains a relative path component"
}

ci_validate_session_name() {
  local value=$1
  [[ ${#value} -le 128 && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(\.desktop)?$ ]] ||
    ci_die "SDDM_AUTOLOGIN_SESSION must be a safe desktop session name"
}

ci_validate_nonnegative_int() {
  local label=$1 value=$2
  [[ "$value" =~ ^[0-9]{1,6}$ ]] || ci_die "$label must be a non-negative decimal integer"
}

ci_normalize_decimal_int() {
  local label=$1 value=$2

  ci_validate_nonnegative_int "$label" "$value"
  # Strip leading zeroes before any arithmetic expansion. Bash otherwise
  # interprets a numeric literal such as 08 as an invalid octal value.
  while [ "${#value}" -gt 1 ] && [ "${value:0:1}" = 0 ]; do
    value=${value#0}
  done
  printf '%s\n' "$value"
}

ci_validate_bool_value() {
  local label=$1 value=$2
  case "$value" in
    0|1|yes|no|true|false|on|off) ;;
    *) ci_die "$label must be a boolean value" ;;
  esac
}

ci_validate_proxy_url() {
  local label=$1 value=$2 scheme rest host port octet
  local -a octets=()
  [[ -n "$value" && ${#value} -le 256 && "$value" != *$'\n'* && "$value" != *$'\r'* &&
     "$value" != *$'\t'* && "$value" != *'@'* && "$value" != *'?'* && "$value" != *'#'* &&
     "$value" != *'%'* && "$value" != *'\\'* ]] ||
    ci_die "$label is not a supported HTTP(S) proxy URL"
  case "$value" in
    http://*) scheme=http; rest=${value#http://} ;;
    https://*) scheme=https; rest=${value#https://} ;;
    *) ci_die "$label must use http:// or https://" ;;
  esac
  [[ -n "$rest" && "$rest" != */* ]] ||
    ci_die "$label must be http(s)://host[:port] without a path"
  if [[ "$rest" == \[*\]* ]]; then
    host=${rest%%\]*}
    host=${host#\[}
    port=${rest#*\]}
    [[ "$host" =~ ^[0-9A-Fa-f:.]+$ && "$host" == *:* && "$port" != *'['* ]] ||
      ci_die "$label has an invalid bracketed host"
    if [ -n "$port" ]; then
      [[ "$port" == :[0-9]* ]] || ci_die "$label has an invalid port"
      port=${port#:}
    fi
  else
    if [[ "$rest" == *:* ]]; then
      host=${rest%:*}
      port=${rest##*:}
    else
      host=$rest
      port=
    fi
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
      ci_die "$label has an invalid host"
    [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] ||
      ci_die "$label has an invalid host"
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
      IFS=. read -r -a octets <<< "$host"
      [ "${#octets[@]}" -eq 4 ] || ci_die "$label has an invalid IPv4 host"
      for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || ci_die "$label has an invalid IPv4 host"
        (( 10#$octet <= 255 )) || ci_die "$label has an invalid IPv4 host"
      done
    fi
  fi
  if [ -n "$port" ]; then
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || ci_die "$label has an invalid port"
    (( 10#$port >= 1 && 10#$port <= 65535 )) || ci_die "$label has an invalid port"
  fi
  printf '%s\n' "$value"
}

ci_configure_proxy_environment() {
  local explicit_http explicit_https lower_http upper_http lower_https upper_https
  local normalized_http normalized_https
  explicit_http=${CI_HTTP_PROXY:-}
  explicit_https=${CI_HTTPS_PROXY:-}
  lower_http=${http_proxy:-}
  upper_http=${HTTP_PROXY:-}
  lower_https=${https_proxy:-}
  upper_https=${HTTPS_PROXY:-}

  if [ -n "$explicit_http" ]; then
    normalized_http=$(ci_validate_proxy_url CI_HTTP_PROXY "$explicit_http")
  else
    [ -z "$lower_http" ] || [ -z "$upper_http" ] || [ "$lower_http" = "$upper_http" ] ||
      ci_die 'http_proxy and HTTP_PROXY disagree'
    if [ -n "${lower_http:-$upper_http}" ]; then
      normalized_http=$(ci_validate_proxy_url http_proxy "${lower_http:-$upper_http}")
    else
      normalized_http=
    fi
  fi
  if [ -n "$explicit_https" ]; then
    normalized_https=$(ci_validate_proxy_url CI_HTTPS_PROXY "$explicit_https")
  else
    [ -z "$lower_https" ] || [ -z "$upper_https" ] || [ "$lower_https" = "$upper_https" ] ||
      ci_die 'https_proxy and HTTPS_PROXY disagree'
    if [ -n "${lower_https:-$upper_https}" ]; then
      normalized_https=$(ci_validate_proxy_url https_proxy "${lower_https:-$upper_https}")
    else
      normalized_https=
    fi
  fi

  # ALL_PROXY and NO_PROXY are intentionally not inherited.  They can silently
  # redirect a download or make curl bypass the reviewed proxy policy.
  [ -z "${ALL_PROXY:-}" ] && [ -z "${all_proxy:-}" ] ||
    ci_die 'ALL_PROXY/all_proxy is unsupported; use CI_HTTP_PROXY or CI_HTTPS_PROXY'
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy
  CI_HTTP_PROXY=$normalized_http
  CI_HTTPS_PROXY=$normalized_https
  export CI_HTTP_PROXY CI_HTTPS_PROXY
}

ci_validate_download_source() {
  local label=$1 source=$2 digest=${3:-}
  case "$source" in
    https://*)
      ci_validate_https_url "$label" "$source"
      [ -n "$digest" ] || ci_die "$label requires an explicit SHA-256 digest"
      ci_validate_sha256 "${label}_SHA256" "$digest"
      ;;
    http://*) ci_die "$label must use HTTPS" ;;
    '')
      [ -z "$digest" ] || ci_die "${label}_SHA256 is set without $label"
      ;;
    *)
      [[ "$source" != *$'\n'* && "$source" != *$'\r'* ]] ||
        ci_die "$label local path contains control characters"
      [ -f "$source" ] && [ ! -L "$source" ] ||
        ci_die "$label local source is not a regular non-symlink file: $source"
      [ -z "$digest" ] || ci_validate_sha256 "${label}_SHA256" "$digest"
      ;;
  esac
}

ci_normalize_package_list() {
  local raw=${1-} line token
  local -a line_tokens=()
  while IFS= read -r line || [ -n "$line" ]; do
    line_tokens=()
    read -r -a line_tokens <<< "$line"
    for token in "${line_tokens[@]}"; do
      [[ ${#token} -le 128 && $token =~ ^[A-Za-z0-9][A-Za-z0-9+.:_@=-]*$ ]] ||
        ci_die "invalid package token: $token"
      printf '%s\n' "$token"
    done
  done <<< "$raw"
}

ci_resolve_path_for_comparison() {
  local path=$1 parent
  if [ -e "$path" ] || [ -L "$path" ]; then
    realpath -e -- "$path"
    return
  fi
  parent=$(realpath -e -- "$(dirname -- "$path")")
  printf '%s/%s\n' "$parent" "$(basename -- "$path")"
}

ci_require_distinct_paths() {
  local -a labels=() paths=() resolved=()
  local label path i j
  [ "$#" -ge 4 ] && [ $(( $# % 2 )) -eq 0 ] ||
    ci_die "ci_require_distinct_paths expects LABEL PATH pairs"
  while [ "$#" -gt 0 ]; do
    label=$1
    path=$2
    labels+=("$label")
    paths+=("$path")
    resolved+=("$(ci_resolve_path_for_comparison "$path")")
    shift 2
  done
  for ((i = 0; i < ${#paths[@]}; i++)); do
    for ((j = i + 1; j < ${#paths[@]}; j++)); do
      if [ "${resolved[i]}" = "${resolved[j]}" ] ||
         { [ -e "${paths[i]}" ] && [ -e "${paths[j]}" ] && [ "${paths[i]}" -ef "${paths[j]}" ]; }; then
        ci_die "${labels[i]} and ${labels[j]} must refer to distinct paths"
      fi
    done
  done
}

ci_source_date_epoch() {
  local epoch=${SOURCE_DATE_EPOCH:-0}
  [[ $epoch =~ ^[0-9]{1,10}$ ]] ||
    ci_die "SOURCE_DATE_EPOCH must be a decimal Unix timestamp: $epoch"
  printf '%s\n' "$epoch"
}

ci_iso8601_timestamp() {
  local epoch
  epoch=$(ci_source_date_epoch)
  date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

ci_normalize_fat_tree() {
  local root=$1
  local epoch
  [ -d "$root" ] || ci_die "FAT payload tree not found: $root"
  epoch=$(ci_source_date_epoch)
  if [ "$epoch" -lt 315532800 ]; then
    epoch=315532800
  fi
  find "$root" -xdev -exec touch -h -d "@$epoch" {} +
}

ci_e2fsck_repair() {
  local target=$1 rc
  if e2fsck -f -y -- "$target"; then
    rc=0
  else
    rc=$?
  fi
  case $rc in
    0|1) return 0 ;;
    *) ci_die "e2fsck failed for $target with status $rc" ;;
  esac
}

ci_mount_targets_below() {
  local root=$1
  ci_require_cmd findmnt
  ci_require_cmd python3
  root=$(realpath -e -- "$root") || {
    printf 'error: cannot resolve mount-tree root: %s\n' "$root" >&2
    return 1
  }
  python3 - "$root" <<'PY'
import json
import subprocess
import sys

root = sys.argv[1]
prefix = "/" if root == "/" else root.rstrip("/") + "/"
try:
    result = subprocess.run(
        ["findmnt", "--json", "--list", "--output", "TARGET"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
except OSError as exc:
    print(f"error: cannot execute findmnt: {exc}", file=sys.stderr)
    raise SystemExit(1)
if result.returncode:
    if result.stderr:
        sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)
try:
    payload = json.loads(result.stdout)
except (json.JSONDecodeError, UnicodeError) as exc:
    print(f"error: invalid findmnt JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)
records = payload.get("filesystems")
if not isinstance(records, list):
    print("error: findmnt JSON has no filesystem list", file=sys.stderr)
    raise SystemExit(1)
targets = []
for record in records:
    if not isinstance(record, dict) or not isinstance(record.get("target"), str):
        print("error: findmnt JSON contains an invalid target", file=sys.stderr)
        raise SystemExit(1)
    target = record["target"]
    if "\n" in target or "\r" in target:
        print("error: mount target contains a line break", file=sys.stderr)
        raise SystemExit(1)
    if target == root or target.startswith(prefix):
        targets.append(target)
for target in sorted(targets, key=lambda item: (len(item), item), reverse=True):
    print(target)
PY
}

ci_unmount_tree() {
  local root=$1 target mounts failed=0
  mounts=$(ci_mount_targets_below "$root") || {
    printf 'error: failed to enumerate mounts below %s\n' "$root" >&2
    return 1
  }
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    if ! umount -- "$target"; then
      printf 'error: failed to unmount %s\n' "$target" >&2
      failed=1
    fi
  done <<< "$mounts"
  [ "$failed" -eq 0 ] || return 1
  mounts=$(ci_mount_targets_below "$root") || {
    printf 'error: failed to verify mounts below %s\n' "$root" >&2
    return 1
  }
  [ -z "$mounts" ] || {
    printf 'error: mounts remain below %s\n' "$root" >&2
    return 1
  }
}

ci_validate_rootfs_overlay_tree() {
  local root=$1 relative link target resolved_target mount_target
  local mounts special hardlinked privileged newline_path links
  ci_validate_no_symlink_ancestors "$root" 'rootfs overlay' ||
    ci_die "rootfs overlay path contains a symlink component: $root"
  [ ! -L "$root" ] || ci_die "rootfs overlay root must not be a symlink: $root"
  [ -d "$root" ] || ci_die "rootfs overlay is not a directory: $root"
  root=$(realpath -e -- "$root") || ci_die "cannot resolve rootfs overlay: $root"
  [ ! -L "$root" ] || ci_die "rootfs overlay root resolved to a symlink: $root"
  mounts=$(ci_mount_targets_below "$root") ||
    ci_die "cannot enumerate mountpoints below rootfs overlay: $root"
  while IFS= read -r mount_target; do
    [ -n "$mount_target" ] || continue
    [ "$mount_target" = "$root" ] && continue
    ci_die "rootfs overlay contains a nested mountpoint: $mount_target"
  done <<< "$mounts"
  special=$(find -P "$root" -xdev \
    \( -type b -o -type c -o -type p -o -type s \) -print -quit) ||
    ci_die "cannot scan rootfs overlay for special files: $root"
  [ -z "$special" ] || ci_die "rootfs overlay contains an unsupported special file: $special"
  hardlinked=$(find -P "$root" -xdev -type f -links +1 -print -quit) ||
    ci_die "cannot scan rootfs overlay for hard links: $root"
  [ -z "$hardlinked" ] || ci_die "rootfs overlay contains a hard-linked regular file: $hardlinked"
  privileged=$(find -P "$root" -xdev \( -type f -o -type d \) -perm /6000 -print -quit) ||
    ci_die "cannot scan rootfs overlay for privileged modes: $root"
  [ -z "$privileged" ] || ci_die "rootfs overlay contains a setuid/setgid member: $privileged"
  for relative in dev proc sys run; do
    if [ -e "$root/$relative" ] || [ -L "$root/$relative" ]; then
      ci_die "rootfs overlay must not contain runtime path: $relative"
    fi
  done
  newline_path=$(find -P "$root" -xdev -name $'*\n*' -print -quit) ||
    ci_die "cannot scan rootfs overlay member names: $root"
  [ -z "$newline_path" ] || ci_die "rootfs overlay member contains a line break: $newline_path"
  links=$(find -P "$root" -xdev -type l -print) ||
    ci_die "cannot scan rootfs overlay symlinks: $root"
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    target=$(readlink -- "$link") || ci_die "cannot read rootfs overlay symlink: $link"
    case "$target" in
      /*) ci_die "rootfs overlay symlink must not use an absolute target: $link" ;;
    esac
    resolved_target=$(realpath -m -- "$(dirname -- "$link")/$target")
    case "$resolved_target" in
      "$root"|"$root"/*) ;;
      *) ci_die "rootfs overlay symlink escapes overlay root: $link" ;;
    esac
  done <<< "$links"
}

ci_validate_gpu_sensor_source_tree() {
  local root=$1 path member extra metadata mode uid gid

  [ -d "$root" ] && [ ! -L "$root" ] ||
    ci_die "GPU sensor source root must be a real directory: $root"
  root=$(realpath -e -- "$root") || ci_die "cannot resolve GPU sensor source root: $root"
  for member in CMakeLists.txt metadata.json tb321fu_gpu.cpp; do
    path="$root/$member"
    [ -f "$path" ] && [ ! -L "$path" ] ||
      ci_die "GPU sensor source member is not a regular file: $member"
    [ "$(stat -c '%h' -- "$path")" = 1 ] ||
      ci_die "GPU sensor source member is hard-linked: $member"
    [ "$(stat -c '%s' -- "$path")" -le 4194304 ] ||
      ci_die "GPU sensor source member exceeds size limit: $member"
    mode=$(stat -c '%a' -- "$path")
    case "$mode" in
      644) ;;
      *) ci_die "GPU sensor source member has an unsafe mode: $member ($mode)" ;;
    esac
    uid=$(stat -c '%u' -- "$path")
    gid=$(stat -c '%g' -- "$path")
    case "$uid" in 0|"$(id -u)"|"${SUDO_UID:-}") ;; *) ci_die "GPU sensor source member has an unsafe owner: $member" ;; esac
    case "$gid" in 0|"$(id -g)"|"${SUDO_GID:-}") ;; *) ci_die "GPU sensor source member has an unsafe group: $member" ;; esac
    [ -r "$path" ] || ci_die "GPU sensor source member is not readable: $member"
  done
  extra=$(find -P "$root" -mindepth 1 -maxdepth 1 \
    ! -name CMakeLists.txt ! -name metadata.json ! -name tb321fu_gpu.cpp \
    -print -quit) || ci_die "cannot enumerate GPU sensor source members: $root"
  [ -z "$extra" ] || ci_die "GPU sensor source contains an unexpected member: $extra"
  python3 - "$root/metadata.json" <<'PY' >/dev/null ||
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
if value != {"providerName": "tb321fu_gpu"}:
    raise SystemExit(1)
PY
    ci_die "GPU sensor source metadata is not the reviewed provider descriptor"
}

ci_validate_gpu_sensor_source_input_tree() {
  local input=$1 source_root=$2 input_real source_real path expected
  local newline_path input_listing

  [ -d "$input" ] && [ ! -L "$input" ] ||
    ci_die "GPU sensor source input must be a real directory: $input"
  input_real=$(realpath -e -- "$input") || ci_die "cannot resolve GPU sensor source input: $input"
  source_real=$(realpath -e -- "$source_root") || ci_die "cannot resolve GPU sensor source root: $source_root"
  case "$source_real" in
    "$input_real"|"$input_real"/*) ;;
    *) ci_die "GPU sensor source root escapes its input: $source_root" ;;
  esac

  # The compiler must receive one exact three-file project.  Wrapper
  # directories (for example a GitHub archive's top-level directory and
  # `source/`) may exist, but every non-directory member outside the selected
  # project and every directory that is not an ancestor of it is rejected.
  newline_path=$(find -P "$input_real" -xdev -mindepth 1 -name $'*\n*' -print -quit) ||
    ci_die "cannot scan GPU sensor source input member names: $input_real"
  [ -z "$newline_path" ] || ci_die "GPU sensor source input member contains a line break: $newline_path"
  input_listing=$(find -P "$input_real" -xdev -mindepth 1 -print) ||
    ci_die "cannot enumerate GPU sensor source input: $input_real"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -L "$path" ]; then
      ci_die "GPU sensor source input contains a symlink: $path"
    fi
    if [ -d "$path" ]; then
      case "$source_real" in
        "$path"|"$path"/*) ;;
        *) ci_die "GPU sensor source input contains an unexpected directory: $path" ;;
      esac
      continue
    fi
    [ -f "$path" ] || ci_die "GPU sensor source input contains an unsupported member: $path"
    case "$path" in
      "$source_real/CMakeLists.txt"|"$source_real/metadata.json"|"$source_real/tb321fu_gpu.cpp") ;;
      *) ci_die "GPU sensor source input contains an unexpected file: $path" ;;
    esac
    [ "$(stat -c '%h' -- "$path")" = 1 ] ||
      ci_die "GPU sensor source input contains a hard-linked file: $path"
  done <<< "$input_listing"

  for expected in CMakeLists.txt metadata.json tb321fu_gpu.cpp; do
    [ -f "$source_real/$expected" ] && [ ! -L "$source_real/$expected" ] ||
      ci_die "GPU sensor source project is missing: $expected"
  done
}

ci_gpu_sensor_source_manifest() {
  local root=$1 member path mode size digest_line digest
  for member in CMakeLists.txt metadata.json tb321fu_gpu.cpp; do
    path="$root/$member"
    mode=$(stat -c '%a' -- "$path") || return 1
    size=$(stat -c '%s' -- "$path") || return 1
    digest_line=$(sha256sum -- "$path") || return 1
    digest=${digest_line%% *}
    printf '%s\t%s\t%s\t%s\n' "$member" "$mode" "$size" "$digest"
  done
}

ci_safe_rmtree() {
  local candidate=$1 parent=$2 prefix=$3 resolved resolved_parent
  local candidate_state parent_state final_candidate_state final_parent_state mounts

  # Validate the lexical namespace before resolving anything. Resolving first
  # would make an attacker-controlled parent symlink look like the expected
  # directory and bind cleanup to the replacement tree.
  ci_validate_no_symlink_ancestors "$parent" cleanup-parent || return 1
  ci_validate_no_symlink_ancestors "$candidate" cleanup-candidate || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || {
    printf 'error: cleanup parent must be a real directory: %s\n' "$parent" >&2
    return 1
  }
  if [ ! -e "$candidate" ]; then
    [ ! -L "$candidate" ] || {
      printf 'error: refusing cleanup of a dangling symlink: %s\n' "$candidate" >&2
      return 1
    }
    return 0
  fi
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || {
    printf 'error: cleanup candidate must be a real directory: %s\n' "$candidate" >&2
    return 1
  }
  candidate_state=$(stat -c '%d:%i:%f:%u:%g:%h' -- "$candidate") || {
    printf 'error: cannot inspect cleanup candidate: %s\n' "$candidate" >&2
    return 1
  }
  parent_state=$(stat -c '%d:%i:%f:%u:%g:%h' -- "$parent") || {
    printf 'error: cannot inspect cleanup parent: %s\n' "$parent" >&2
    return 1
  }
  resolved=$(realpath -e -- "$candidate") || {
    printf 'error: cannot canonicalize cleanup candidate: %s\n' "$candidate" >&2
    return 1
  }
  resolved_parent=$(realpath -e -- "$parent") || {
    printf 'error: cannot canonicalize cleanup parent: %s\n' "$parent" >&2
    return 1
  }
  [ "$(dirname -- "$resolved")" = "$resolved_parent" ] || {
    printf 'error: refusing cleanup outside expected parent: %s\n' "$resolved" >&2
    return 1
  }
  case $(basename -- "$resolved") in
    "$prefix"*) ;;
    *)
      printf 'error: refusing cleanup with unexpected basename: %s\n' "$resolved" >&2
      return 1
      ;;
  esac
  mounts=$(ci_mount_targets_below "$resolved") || {
    printf 'error: refusing cleanup because mount inspection failed: %s\n' "$resolved" >&2
    return 1
  }
  [ -z "$mounts" ] || {
    printf 'error: refusing to delete a tree containing active mounts: %s\n' "$resolved" >&2
    return 1
  }
  ci_validate_no_symlink_ancestors "$parent" cleanup-parent || return 1
  ci_validate_no_symlink_ancestors "$candidate" cleanup-candidate || return 1
  final_candidate_state=$(stat -c '%d:%i:%f:%u:%g:%h' -- "$candidate") || {
    printf 'error: cleanup candidate disappeared during validation: %s\n' "$candidate" >&2
    return 1
  }
  final_parent_state=$(stat -c '%d:%i:%f:%u:%g:%h' -- "$parent") || {
    printf 'error: cleanup parent disappeared during validation: %s\n' "$parent" >&2
    return 1
  }
  [ "$final_candidate_state" = "$candidate_state" ] &&
    [ "$final_parent_state" = "$parent_state" ] &&
    [ -d "$candidate" ] && [ ! -L "$candidate" ] || {
      printf 'error: cleanup namespace changed during validation: %s\n' "$candidate" >&2
      return 1
    }
  # Remove the validated directory entry, not its canonical target. If the leaf
  # is exchanged for a symlink after the final lstat, rm removes only that link.
  rm -rf --one-file-system -- "$candidate"
}

ci_verify_download() {
  local file=$1 verifier=$2 expected actual
  local -a primary_fingerprints=()
  case $verifier in
    sha256:*) expected=${verifier#sha256:} ;;
    [[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]*) expected=$verifier ;;
    openpgp-fpr:*)
      expected=${verifier#openpgp-fpr:}
      [[ $expected =~ ^[A-Fa-f0-9]{40}$ ]] || ci_die "invalid OpenPGP fingerprint: $expected"
      ci_require_cmd gpg
      mapfile -t primary_fingerprints < <(
        gpg --batch --quiet --show-keys --with-colons "$file" 2>/dev/null |
          awk -F: '
            $1 == "pub" { want_primary_fpr=1; next }
            $1 == "sub" { want_primary_fpr=0; next }
            $1 == "fpr" && want_primary_fpr { print toupper($10); want_primary_fpr=0 }
          '
      )
      [ "${#primary_fingerprints[@]}" -eq 1 ] ||
        ci_die "OpenPGP input must contain exactly one primary key: $file"
      [ "${primary_fingerprints[0]}" = "${expected^^}" ] ||
        ci_die "OpenPGP fingerprint mismatch for $file"
      return
      ;;
    *) ci_die "unsupported or missing download verifier for $file" ;;
  esac
  [[ $expected =~ ^[A-Fa-f0-9]{64}$ ]] || ci_die "invalid SHA-256 verifier: $expected"
  actual=$(sha256sum "$file" | awk '{print $1}')
  [ "$actual" = "${expected,,}" ] || ci_die "SHA-256 mismatch for $file: expected ${expected,,}, got $actual"
}

ci_download_matches_verifier() {
  local file=$1 verifier=$2

  # A pinned SHA commits to every expected byte.  OpenPGP verification can
  # intentionally accept a parseable key export, so it is not safe to use it
  # as an early transport-completion test.
  [[ $verifier != openpgp-fpr:* ]] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  (ci_verify_download "$file" "$verifier") >/dev/null 2>&1
}

ci_download() {
  local src=$1
  local dst=$2
  local verifier=${3:-}
  local tmp
  local attempt=1
  local max_attempts=${CI_DOWNLOAD_MAX_ATTEMPTS:-8}
  local deadline_seconds=${CI_DOWNLOAD_DEADLINE_SECONDS:-5400}
  local deadline_at remaining attempt_timeout proxy
  local resume_reset=0
  local curl_rc
  local -a curl_proxy_args=()

  [[ "$max_attempts" =~ ^[1-9][0-9]{0,2}$ ]] ||
    ci_die "CI_DOWNLOAD_MAX_ATTEMPTS must be 1..32"
  [[ "$deadline_seconds" =~ ^[1-9][0-9]{1,5}$ ]] ||
    ci_die "CI_DOWNLOAD_DEADLINE_SECONDS must be 10..86400"
  # Bash treats a leading zero as octal in arithmetic contexts.  Normalize
  # validated decimal text before the range checks and deadline arithmetic so
  # values such as 08 cannot trigger an arithmetic error or become eight.
  max_attempts=$((10#$max_attempts))
  deadline_seconds=$((10#$deadline_seconds))
  (( max_attempts <= 32 )) || ci_die "CI_DOWNLOAD_MAX_ATTEMPTS must be 1..32"
  (( deadline_seconds >= 10 && deadline_seconds <= 86400 )) ||
    ci_die "CI_DOWNLOAD_DEADLINE_SECONDS must be 10..86400"
  # Capture and validate inherited proxy variables once at the boundary.  The
  # function also removes ambient variants so curl cannot pick a different
  # route on a later retry.
  ci_configure_proxy_environment
  deadline_at=$((SECONDS + deadline_seconds))

  local dst_dir dst_name
  dst_dir=$(dirname -- "$dst")
  dst_name=$(basename -- "$dst")
  [ -d "$dst_dir" ] || ci_die "download destination directory is missing: $dst_dir"
  [ ! -L "$dst_dir" ] || ci_die "download destination directory is a symlink: $dst_dir"
  tmp=$(mktemp "$dst_dir/.${dst_name}.part.XXXXXX") ||
    ci_die "cannot create private download temporary file: $dst"
  case "$src" in
    https://*)
      [ -n "$verifier" ] || ci_die "remote download requires an explicit SHA-256 or OpenPGP fingerprint: $src"
      ci_require_cmd "${CI_CURL_BIN:-curl}"
      while :; do
        remaining=$((deadline_at - SECONDS))
        [ "$remaining" -gt 0 ] || {
          rm -f -- "$tmp"
          ci_die "download deadline exceeded: $src"
        }
        attempt_timeout=$remaining
        [ "$attempt_timeout" -gt 900 ] && attempt_timeout=900
        proxy=${CI_HTTPS_PROXY:-${CI_HTTP_PROXY:-}}
        curl_proxy_args=(--noproxy '*')
        if [ -n "$proxy" ]; then
          curl_proxy_args=(--proxy "$proxy")
        fi
        if "${CI_CURL_BIN:-curl}" \
          --disable \
          --proto '=https' \
          --proto-redir '=https' \
          --tlsv1.2 \
          --http1.1 \
          --fail \
          --location \
          --connect-timeout 30 \
          --max-time "$attempt_timeout" \
          --speed-limit 1024 \
          --speed-time 300 \
          --continue-at - \
          "${curl_proxy_args[@]}" \
          --output "$tmp" \
          "$src"; then
          break
        else
          curl_rc=$?
        fi

        if [ -s "$tmp" ] && ci_download_matches_verifier "$tmp" "$verifier"; then
          ci_log "HTTPS download completed before curl exit $curl_rc: $src"
          break
        fi
        if [ "$curl_rc" -eq 33 ] && [ -s "$tmp" ] && [ "$resume_reset" -eq 0 ]; then
          rm -f -- "$tmp"
          resume_reset=1
          ci_log "server rejected HTTPS resume; retrying once from byte zero: $src"
        fi
        if [ "$attempt" -ge "$max_attempts" ]; then
          rm -f -- "$tmp"
          ci_die "download failed after $max_attempts attempts or deadline: $src"
        fi
        attempt=$((attempt + 1))
        ci_log "retrying HTTPS download ($attempt/$max_attempts) after curl exit $curl_rc: $src"
      done
      ;;
    http://*)
      ci_die "refusing insecure HTTP download: $src"
      ;;
    '')
      ci_die "empty download source for $dst"
      ;;
    *)
      [ -f "$src" ] && [ ! -L "$src" ] ||
        ci_die "local download source is not a regular file: $src"
      cp --reflink=auto -- "$src" "$tmp"
      ;;
  esac
  if [ -n "$verifier" ]; then
    if ! (ci_verify_download "$tmp" "$verifier"); then
      rm -f -- "$tmp"
      ci_die "download verification failed: $src"
    fi
  fi
  mv -f -- "$tmp" "$dst"
}

ci_extract_archive() {
  local archive=$1
  local dest=$2
  local helper
  helper=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/safe-extract-archive.py
  ci_require_cmd python3
  [ -f "$archive" ] || ci_die "archive not found: $archive"
  python3 "$helper" "$archive" "$dest" || ci_die "safe archive extraction failed: $archive"
}
