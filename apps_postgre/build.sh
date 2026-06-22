#!/usr/bin/env bash
set -euo pipefail

APP_NAME="apps_postgre"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="amd64"
VERSION="${APP_VERSION:-$(date +%Y%m%d%H%M%S)}"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/.build"
IMAGE_JSON="${ROOT_DIR}/images/image.json"

usage() {
  cat <<USAGE
Usage: bash build.sh --arch <amd64|arm64|all>

Environment:
  APP_VERSION       Override package version. Default: timestamp.
  SKIP_DOCKER_PULL  Set to 1 to skip docker pull/save. Mostly for script syntax checks only.

Examples:
  bash build.sh --arch amd64
  bash build.sh --arch arm64
  bash build.sh --arch all
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] required command not found: $1" >&2
    exit 1
  }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch)
        ARCH="${2:-}"
        shift 2
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        echo "[ERROR] unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  case "$ARCH" in
    amd64|arm64|all) ;;
    *)
      echo "[ERROR] --arch must be amd64, arm64 or all" >&2
      exit 1
      ;;
  esac
}

safe_name() {
  echo "$1" | sed -E 's#^[^/]+/##; s#[/:@]#_#g; s#[^A-Za-z0-9_.-]#_#g'
}

check_inputs() {
  need_cmd jq
  need_cmd tar
  need_cmd gzip
  need_cmd sha256sum

  if [[ "${SKIP_DOCKER_PULL:-0}" != "1" ]]; then
    need_cmd docker
  fi

  [[ -f "${ROOT_DIR}/install.sh" ]] || { echo "[ERROR] install.sh not found" >&2; exit 1; }
  [[ -f "${IMAGE_JSON}" ]] || { echo "[ERROR] images/image.json not found" >&2; exit 1; }
  [[ -d "${ROOT_DIR}/charts/postgre" ]] || { echo "[ERROR] charts/postgre not found" >&2; exit 1; }

  bash -n "${ROOT_DIR}/install.sh"
  jq empty "${IMAGE_JSON}"
}

prepare_payload() {
  local arch="$1"
  local payload_dir="$2"
  local platform="linux/${arch}"

  rm -rf "$payload_dir"
  mkdir -p "$payload_dir/images/tars" "$payload_dir/charts"

  cp "${ROOT_DIR}/install.sh" "$payload_dir/install.sh"
  cp "${IMAGE_JSON}" "$payload_dir/images/image.json"
  cp -a "${ROOT_DIR}/charts/postgre" "$payload_dir/charts/postgre"

  : > "$payload_dir/images/image-index.tsv"

  local count
  count="$(jq 'length' "${IMAGE_JSON}")"
  if [[ "$count" -eq 0 ]]; then
    echo "[ERROR] images/image.json is empty" >&2
    exit 1
  fi

  for i in $(seq 0 $((count - 1))); do
    local source target name archive platforms
    source="$(jq -r ".[$i].source" "${IMAGE_JSON}")"
    target="$(jq -r ".[$i].target" "${IMAGE_JSON}")"
    name="$(jq -r ".[$i].name // \"image-$i\"" "${IMAGE_JSON}")"
    platforms="$(jq -r ".[$i].platforms // [] | join(\",\")" "${IMAGE_JSON}")"

    if [[ -z "$source" || "$source" == "null" || -z "$target" || "$target" == "null" ]]; then
      echo "[ERROR] invalid image entry index=$i, source/target required" >&2
      exit 1
    fi

    if [[ -n "$platforms" ]] && ! jq -e --arg p "$platform" --argjson idx "$i" '.[$idx].platforms | index($p)' "${IMAGE_JSON}" >/dev/null; then
      echo "[ERROR] image $name does not support platform $platform" >&2
      exit 1
    fi

    archive="$(safe_name "${target}")-${arch}.tar"
    echo "[IMAGE] ${platform} pull ${source}"

    if [[ "${SKIP_DOCKER_PULL:-0}" == "1" ]]; then
      echo "[WARN] SKIP_DOCKER_PULL=1, create empty placeholder archive for ${source}"
      tar -cf "$payload_dir/images/tars/$archive" --files-from /dev/null
    else
      docker pull --platform "$platform" "$source"
      docker save -o "$payload_dir/images/tars/$archive" "$source"
    fi

    printf '%s\t%s\t%s\t%s\n' "$source" "images/tars/$archive" "$source" "$target" >> "$payload_dir/images/image-index.tsv"
  done
}

build_one() {
  local arch="$1"
  local work_dir="${BUILD_DIR}/${arch}"
  local payload_dir="${work_dir}/payload"
  local payload_tar="${work_dir}/payload.tar.gz"
  local out="${DIST_DIR}/${APP_NAME}-installer-${arch}.run"

  echo "[BUILD] arch=${arch} version=${VERSION}"
  prepare_payload "$arch" "$payload_dir"

  mkdir -p "$DIST_DIR" "$work_dir"
  tar -C "$payload_dir" -czf "$payload_tar" .

  cp "${ROOT_DIR}/install.sh" "$out"
  printf '\n__PAYLOAD_BELOW__\n' >> "$out"
  cat "$payload_tar" >> "$out"
  chmod +x "$out"

  sha256sum "$out" > "${out}.sha256"

  if [[ "$(grep -a -c '^__PAYLOAD_BELOW__$' "$out")" != "1" ]]; then
    echo "[ERROR] installer marker count is not 1: $out" >&2
    exit 1
  fi

  echo "[DONE] $out"
  echo "[DONE] ${out}.sha256"
}

main() {
  parse_args "$@"
  check_inputs
  rm -rf "$BUILD_DIR"
  mkdir -p "$DIST_DIR"

  if [[ "$ARCH" == "all" ]]; then
    build_one amd64
    build_one arm64
  else
    build_one "$ARCH"
  fi
}

main "$@"
