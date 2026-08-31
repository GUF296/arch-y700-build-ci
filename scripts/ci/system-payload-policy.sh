#!/usr/bin/env bash

# This file is sourced by CI build scripts after common.sh.

ci_payload_file_mode() {
  local relative=${1#/}

  case "/$relative" in
    /DEBIAN/preinst|/DEBIAN/postinst|/DEBIAN/prerm|/DEBIAN/postrm|/DEBIAN/config|\
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/libexec/*|\
    /usr/local/bin/*|/usr/local/sbin/*|/usr/local/libexec/*|\
    /opt/libcamera-y700/bin/*|/opt/libcamera-y700/libexec/*)
      printf '0755\n'
      ;;
    *)
      printf '0644\n'
      ;;
  esac
}

ci_assert_no_hardlinked_system_payload() {
  local root=$1 hardlinked

  [ -d "$root" ] && [ ! -L "$root" ] || ci_die "system payload tree is not a real directory: $root"
  # A hard-linked regular file may share its inode with a path outside this
  # tree.  Chown/chmod would then mutate that unrelated path as a side effect,
  # so native package stages must be closed under inode ownership.
  hardlinked=$(find -P "$root" -xdev -type f -links +1 -print -quit)
  [ -z "$hardlinked" ] || ci_die "system payload contains a hard-linked regular file: $hardlinked"
}

ci_normalize_system_payload_modes() {
  local root=$1 path relative expected

  ci_assert_no_hardlinked_system_payload "$root"
  find "$root" -xdev -type d -exec chmod 0755 {} +
  while IFS= read -r -d '' path; do
    relative=${path#"$root"/}
    expected=$(ci_payload_file_mode "$relative")
    chmod "$expected" "$path"
  done < <(find "$root" -xdev -type f -print0)
}

ci_normalize_system_payload_ownership() {
  local root=$1

  [ "$EUID" -eq 0 ] || ci_die "system payload ownership normalization requires root"
  ci_assert_no_hardlinked_system_payload "$root"
  # Native package payloads must be root-owned.  Do not follow symlinks while
  # changing ownership; a staged link must never grant access to its target.
  find -P "$root" -xdev -exec chown --no-dereference 0:0 -- {} +
}

ci_lstat_owner() {
  local path=$1 owner

  # find -P -printf reports the ownership of the directory entry itself,
  # including a symlink inode; it never follows the link to its target.
  owner=$(find -P "$path" -maxdepth 0 -printf '%U:%G') ||
    ci_die "cannot inspect system payload ownership: $path"
  [ -n "$owner" ] || ci_die "system payload ownership inspection was empty: $path"
  printf '%s\n' "$owner"
}

ci_assert_system_payload_root_owned() {
  local root=$1 path owner

  ci_assert_no_hardlinked_system_payload "$root"
  while IFS= read -r -d '' path; do
    owner=$(ci_lstat_owner "$path")
    [ "$owner" = 0:0 ] || ci_die "system payload member is not root-owned ($owner): $path"
  done < <(find -P "$root" -xdev -print0)
}

ci_assert_normalized_system_payload_modes() {
  local root=$1 path relative expected actual

  ci_assert_no_hardlinked_system_payload "$root"
  while IFS= read -r -d '' path; do
    actual=$(stat -c '%a' "$path")
    [ "$actual" = 755 ] || ci_die "system payload directory has mode $actual, expected 755: $path"
  done < <(find "$root" -xdev -type d -print0)
  while IFS= read -r -d '' path; do
    relative=${path#"$root"/}
    expected=$(ci_payload_file_mode "$relative")
    actual=$(stat -c '%a' "$path")
    [ "$actual" = "${expected#0}" ] || \
      ci_die "system payload file has mode $actual, expected ${expected#0}: $path"
  done < <(find "$root" -xdev -type f -print0)
}

ci_assert_privileged_payload_security() {
  local root=$1 required path writable
  shift

  [ -d "$root" ] || ci_die "rootfs tree not found: $root"
  for path in "$root/etc" "$root/usr" "$root/opt" "$root/bin" "$root/sbin" "$root/lib"; do
    [ -e "$path" ] || continue
    writable=$(find "$path" -xdev \( -type f -o -type d \) -perm /0022 -print -quit)
    [ -z "$writable" ] || ci_die "group/world-writable privileged payload member: $writable"
  done

  for required in "$@"; do
    required=${required#/}
    [ -f "$root/$required" ] || ci_die "required payload executable is missing: /$required"
    [ -x "$root/$required" ] || ci_die "required payload file is not executable: /$required"
  done
}
