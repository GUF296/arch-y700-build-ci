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

ci_download() {
  local src=$1
  local dst=$2
  case "$src" in
    http://*|https://*)
      ci_require_cmd curl
      curl -fL --retry 3 --retry-delay 2 -o "$dst" "$src"
      ;;
    '')
      ci_die "empty download source for $dst"
      ;;
    *)
      cp -a "$src" "$dst"
      ;;
  esac
}

ci_extract_archive() {
  local archive=$1
  local dest=$2
  mkdir -p "$dest"

  case "$archive" in
    *.tar.gz|*.tgz) tar -C "$dest" -xzf "$archive"; return ;;
    *.tar.xz) tar -C "$dest" -xJf "$archive"; return ;;
    *.tar.zst) tar -C "$dest" --zstd -xf "$archive"; return ;;
    *.tar) tar -C "$dest" -xf "$archive"; return ;;
    *.zip) ci_require_cmd unzip; unzip -q "$archive" -d "$dest"; return ;;
    *.7z|*.7z.001) ci_require_cmd 7z; 7z x "$archive" -o"$dest" >/dev/null; return ;;
  esac

  # Download URLs often land in extensionless temp files; detect by content.
  if tar -tf "$archive" >/dev/null 2>&1; then
    tar -C "$dest" -xf "$archive"
    return
  fi

  if command -v 7z >/dev/null 2>&1 && 7z l "$archive" >/dev/null 2>&1; then
    7z x "$archive" -o"$dest" >/dev/null
    return
  fi

  ci_die "unsupported archive format: $archive"
}
