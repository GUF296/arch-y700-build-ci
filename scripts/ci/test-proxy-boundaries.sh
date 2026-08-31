#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-proxy-boundary.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT INT TERM

expect_rejected() {
  local label=$1
  shift
  if ("$@") >/dev/null 2>&1; then
    printf 'accepted hostile proxy fixture: %s\n' "$label" >&2
    exit 1
  fi
}

expect_accepted() {
  local label=$1
  shift
  if ! ("$@") >/dev/null 2>&1; then
    printf 'rejected valid proxy fixture: %s\n' "$label" >&2
    exit 1
  fi
}

expect_accepted 'supported HTTP proxy with port' \
  ci_validate_proxy_url proxy http://172.31.64.1:7897
expect_accepted 'supported HTTPS proxy' \
  ci_validate_proxy_url proxy https://proxy.example.com:443
expect_accepted 'supported bracketed IPv6 proxy' \
  ci_validate_proxy_url proxy http://[2001:db8::1]:8080

for hostile in \
  'ftp://proxy.example.com:7897' \
  'http://user:pass@proxy.example.com:7897' \
  'http://proxy.example.com/path' \
  'http://proxy.example.com:0' \
  'http://proxy.example.com:65536' \
  'http://proxy.example.com:abc' \
  'http://proxy.example.com?x=1' \
  'http://proxy.example.com#fragment' \
  'http://proxy.example.com:7897/path' \
  'http://172.31.64.999:7897' \
  'http://proxy..example.com:7897'; do
  expect_rejected "$hostile" ci_validate_proxy_url proxy "$hostile"
done

(
  http_proxy=http://172.31.64.1:7897
  HTTP_PROXY=http://172.31.64.1:7897
  https_proxy=https://proxy.example.com:8443
  HTTPS_PROXY=https://proxy.example.com:8443
  unset CI_HTTP_PROXY CI_HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy
  export http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
  ci_configure_proxy_environment
  [ "$CI_HTTP_PROXY" = http://172.31.64.1:7897 ]
  [ "$CI_HTTPS_PROXY" = https://proxy.example.com:8443 ]
  [ -z "${http_proxy+x}" ] && [ -z "${HTTP_PROXY+x}" ]
  [ -z "${https_proxy+x}" ] && [ -z "${HTTPS_PROXY+x}" ]
)

(
  CI_HTTP_PROXY=http://172.31.64.1:7897
  CI_HTTPS_PROXY=http://172.31.64.1:7897
  unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy
  export CI_HTTP_PROXY CI_HTTPS_PROXY
  ci_configure_proxy_environment
)

expect_rejected 'disagreeing lowercase and uppercase values' bash -c \
  'http_proxy=http://172.31.64.1:7897 HTTP_PROXY=http://proxy.example.com:7897; export http_proxy HTTP_PROXY; . "$1/common.sh"; ci_configure_proxy_environment' _ "$SCRIPT_DIR"
expect_rejected 'unsupported ALL_PROXY inheritance' bash -c \
  'ALL_PROXY=http://proxy.example.com:7897; export ALL_PROXY; . "$1/common.sh"; ci_configure_proxy_environment' _ "$SCRIPT_DIR"

# Exercise the bounded numeric options through the local-copy path, which does
# not need network access but still executes the same deadline/attempt parsing.
printf 'download fixture\n' > "$tmp/source"
digest=$(sha256sum "$tmp/source" | awk '{print $1}')
(
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy
  CI_DOWNLOAD_MAX_ATTEMPTS=8 CI_DOWNLOAD_DEADLINE_SECONDS=10 \
    ci_download "$tmp/source" "$tmp/output" "sha256:$digest"
)
cmp -s "$tmp/source" "$tmp/output"

printf 'PROXY_BOUNDARY_FIXTURES=PASS\n'
