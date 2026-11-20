#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
BUILD_SCRIPT="$SCRIPT_DIR/build-arch-rootfs-image.sh"
. "$SCRIPT_DIR/common.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-arch-camera-remediation.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
work_dir="$tmp/work"
rootfs_dir="$tmp/rootfs"
arch_camera_supplement_stage="$tmp/no-supplement"
mkdir -p "$work_dir"

extract_function() {
  awk -v signature="$1() {" '
    !copying && $0 == signature {copying=1; depth=0}
    copying {print; line=$0; depth+=gsub(/\{/,"",line); line=$0; depth-=gsub(/\}/,"",line); if(depth==0)exit}
  ' "$BUILD_SCRIPT"
}
for function in camera_source_root_is_contained find_camera_source_root \
  validate_camera_stack_symlink camera_canonical_symlink_target camera_canonical_expected_mode \
  camera_contract_add_parent_dirs validate_camera_tree_against_contract validate_camera_stack_stage \
  apply_tb321fu_camera_stack verify_tb321fu_camera_loader verify_tb321fu_native_package_integrity; do
  definition=$(extract_function "$function")
  [ -n "$definition" ] || ci_die "missing test entry point: $function"
  eval "$definition"
done

# Stub only the later rootfs/pacman side effects. Actual production profile
# materialization, receipt parsing, source binding and closed-tree checks run.
remove_legacy_camera_payload() { :; }
adapt_ubuntu_multilib_paths_for_arch() { printf '%s\n' "$1" >"$tmp/adapted"; }
install_arch_native_stage_package() {
  [ "$1" = tb321fu-camera-stack ] || ci_die "wrong native package"
  [ "$(cat "$tmp/adapted")" = "$3" ] || ci_die "native adaptation was skipped"
  local -n dependencies=$4
  for dependency in libelf libevent libglvnd glib2 systemd-libs; do
    [[ " ${dependencies[*]} " == *" $dependency "* ]] || ci_die "missing direct runtime dependency: $dependency"
  done
  python3 -I -B - "$SCRIPT_DIR" "$3" "$expected_kind" <<'PY'
import importlib.util, pathlib, sys
scripts, stage = map(pathlib.Path, sys.argv[1:3])
spec=importlib.util.spec_from_file_location('native_profile', scripts/'camera-remediation-profile.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
baseline,_=m.overlay.parse_manifest(m.BASE/'OVERLAY-MANIFEST.tsv')
expected=m.validate(m.snapshot(m.PROFILE))[2] if sys.argv[3]=='remediation' else baseline
actual,_=m.overlay.inspect_tree(stage)
extra='etc/ld.so.conf.d/y700-device.conf'
assert actual.keys()==expected.keys()|{extra}
assert all(actual[name]==record for name,record in expected.items())
assert (stage/extra).read_text()=='/opt/libcamera-y700/lib/aarch64-linux-gnu\n/usr/lib/aarch64-linux-gnu\n'
PY
  printf '%s\n' "$expected_kind" >>"$tmp/packaged"
}
CAMERA_STACK_ARCHIVE=
CAMERA_STACK_ARCHIVE_SHA256=
CAMERA_STACK_DIR=
expected_kind=remediation
apply_tb321fu_camera_stack
[ "$camera_stack_source_kind" = repository-remediation ] || ci_die "default camera path used baseline"
[[ $camera_stack_profile_sha256 =~ ^[0-9a-f]{64}$ ]] || ci_die "profile receipt omitted"
[[ $camera_stack_producer_package_sha256 =~ ^[0-9a-f]{64}$ ]] || ci_die "producer package receipt omitted"

CAMERA_STACK_DIR="$REPO_ROOT/source/tb321fu-camera-rootfs-overlay"
expected_kind=baseline
apply_tb321fu_camera_stack
[ "$camera_stack_source_kind" = baseline-override ] || ci_die "explicit historical override was not retained"
[ -z "$camera_stack_profile_sha256" ] || ci_die "historical override claimed remediation evidence"
[ "$(wc -l <"$tmp/packaged")" -eq 2 ] || ci_die "native staging cases did not both run"

BUILD_TB321FU_GPU_SENSOR=0
loader_mode=valid
arch_chroot() {
  if [ "$1" = /usr/bin/pacman ]; then
    case "$2" in
      -Q) return 1 ;;
      -Qkk) return 0 ;;
      -Qoq) printf '%s\n' tb321fu-camera-stack; return 0 ;;
    esac
  fi
  [[ "$*" == '/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /lib/ld-linux-aarch64.so.1 --list --library-path '* ]] ||
    ci_die "loader check attempted an unexpected command"
  printf '%s\n' "${!#}" >>"$tmp/loader-calls"
  case "$loader_mode" in
    valid) printf 'libcamera.so.0.7 => /opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7 (0x123)\n' ;;
    foreign) printf 'libcamera.so.0.7 => /usr/lib/libcamera.so.0.7 (0x123)\n' ;;
    missing) printf 'libgcc_s.so.1: version GCC_4.5.0 not found\n' ;;
    empty) : ;;
    failure) return 1 ;;
  esac
}
verify_tb321fu_native_package_integrity
[ "$(wc -l <"$tmp/loader-calls")" -eq 7 ] || ci_die "native integrity gate did not check all camera objects"
for loader_mode in foreign missing empty failure; do
  if (verify_tb321fu_native_package_integrity) >"$tmp/out" 2>"$tmp/err"; then
    ci_die "accepted incompatible target loader result: $loader_mode"
  fi
done
printf 'ARCH_CAMERA_REMEDIATION_INTEGRATION=PASS\n'
