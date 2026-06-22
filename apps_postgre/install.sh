#!/usr/bin/env bash
set -euo pipefail

APP_NAME="apps_postgre"
CHART_NAME="postgre"
DEFAULT_NAMESPACE="apps-postgre"
DEFAULT_RELEASE="apps-postgre"
DEFAULT_POSTGRES_USER="postgres"
DEFAULT_POSTGRES_DB="appdb"
DEFAULT_POSTGRES_PASSWORD="ChangeMe_PostgreSQL_123"
DEFAULT_SIZE="20Gi"

ACTION="help"
NAMESPACE="$DEFAULT_NAMESPACE"
RELEASE="$DEFAULT_RELEASE"
REGISTRY=""
REGISTRY_USER=""
REGISTRY_PASS=""
SKIP_IMAGE_PREPARE="false"
YES="false"
DELETE_PVC="false"
POSTGRES_USER="$DEFAULT_POSTGRES_USER"
POSTGRES_DB="$DEFAULT_POSTGRES_DB"
POSTGRES_PASSWORD="$DEFAULT_POSTGRES_PASSWORD"
STORAGE_CLASS=""
SIZE="$DEFAULT_SIZE"
VALUES_FILE=""
PULL_POLICY="IfNotPresent"

usage() {
  cat <<USAGE
${APP_NAME} offline installer

Usage:
  ./installer.run <action> [options]

Actions:
  help                         Show this help
  install                      Load/tag/push images and install or upgrade PostgreSQL
  status                       Show Helm release and Kubernetes resource status
  uninstall                    Uninstall Helm release. PVC is kept by default
  extract --to <dir>           Extract embedded payload only

Common options:
  -n, --namespace <name>        Kubernetes namespace. Default: ${DEFAULT_NAMESPACE}
  --release <name>             Helm release name. Default: ${DEFAULT_RELEASE}
  --registry <host/path>        Target registry prefix, for example sealos.hub:5000/kube4
  --registry-user <user>        Registry username
  --registry-pass <password>    Registry password
  --skip-image-prepare         Skip docker load/tag/push, but still render chart image to target registry
  --postgres-user <user>        PostgreSQL user. Default: ${DEFAULT_POSTGRES_USER}
  --postgres-password <pass>    PostgreSQL password. Default is demo-only; override in production
  --postgres-db <db>            PostgreSQL database. Default: ${DEFAULT_POSTGRES_DB}
  --storage-class <name>        StorageClass name. Empty means cluster default
  --size <size>                 PVC size. Default: ${DEFAULT_SIZE}
  --values <file>               Extra Helm values file
  --pull-policy <policy>        Image pullPolicy. Default: IfNotPresent
  --delete-pvc                  With uninstall, delete PVCs created for the release
  -y, --yes                    Non-interactive confirm

Examples:
  ./apps_postgre-installer-amd64.run install \\
    --registry sealos.hub:5000/kube4 \\
    --registry-user admin \\
    --registry-pass 'passw0rd' \\
    -n apps-postgre \\
    --postgres-password 'ChangeMe_StrongPassword' \\
    -y

  ./apps_postgre-installer-amd64.run install \\
    --registry sealos.hub:5000/kube4 \\
    --skip-image-prepare \\
    -n apps-postgre \\
    --postgres-password 'ChangeMe_StrongPassword' \\
    -y
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; }
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "required command not found: $1"; exit 1; }
}

confirm() {
  if [[ "$YES" == "true" ]]; then
    return 0
  fi
  read -r -p "$1 [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    ACTION="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        NAMESPACE="${2:-}"
        shift 2
        ;;
      --release)
        RELEASE="${2:-}"
        shift 2
        ;;
      --registry)
        REGISTRY="${2:-}"
        shift 2
        ;;
      --registry-user)
        REGISTRY_USER="${2:-}"
        shift 2
        ;;
      --registry-pass)
        REGISTRY_PASS="${2:-}"
        shift 2
        ;;
      --skip-image-prepare)
        SKIP_IMAGE_PREPARE="true"
        shift
        ;;
      --postgres-user)
        POSTGRES_USER="${2:-}"
        shift 2
        ;;
      --postgres-password)
        POSTGRES_PASSWORD="${2:-}"
        shift 2
        ;;
      --postgres-db)
        POSTGRES_DB="${2:-}"
        shift 2
        ;;
      --storage-class)
        STORAGE_CLASS="${2:-}"
        shift 2
        ;;
      --size)
        SIZE="${2:-}"
        shift 2
        ;;
      --values)
        VALUES_FILE="${2:-}"
        shift 2
        ;;
      --pull-policy)
        PULL_POLICY="${2:-}"
        shift 2
        ;;
      --delete-pvc)
        DELETE_PVC="true"
        shift
        ;;
      --to)
        EXTRACT_TO="${2:-}"
        shift 2
        ;;
      -y|--yes)
        YES="true"
        shift
        ;;
      -h|--help)
        ACTION="help"
        shift
        ;;
      *)
        err "unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

extract_payload() {
  local dest="$1"
  local self="${BASH_SOURCE[0]}"
  local marker="__PAYLOAD_BELOW__"
  local offset

  mkdir -p "$dest"
  offset="$(awk -v marker="$marker" '
    BEGIN { offset = 0; found = 0 }
    {
      offset += length($0) + 1
      if ($0 == marker) { print offset; found = 1; exit }
    }
    END { if (found == 0) exit 2 }
  ' "$self")" || {
    err "payload marker not found. This script must be executed from generated .run installer"
    exit 1
  }

  dd if="$self" bs=1 skip="$offset" status=none | tar -xzf - -C "$dest"
}

with_payload() {
  local tmp
  tmp="$(mktemp -d -t ${APP_NAME}.XXXXXX)"
  trap 'rm -rf "$tmp"' EXIT
  extract_payload "$tmp"
  PAYLOAD_DIR="$tmp"
}

normalize_registry() {
  local r="$1"
  r="${r#http://}"
  r="${r#https://}"
  r="${r%/}"
  echo "$r"
}

split_image_repo() {
  local image="$1"
  echo "${image%:*}"
}

split_image_tag() {
  local image="$1"
  echo "${image##*:}"
}

first_image_target() {
  awk -F '\t' 'NF >= 4 { print $4; exit }' "$PAYLOAD_DIR/images/image-index.tsv"
}

source_image_ref() {
  awk -F '\t' 'NF >= 4 { print $3; exit }' "$PAYLOAD_DIR/images/image-index.tsv"
}

prepare_images() {
  need_cmd docker
  [[ -f "$PAYLOAD_DIR/images/image-index.tsv" ]] || { err "image-index.tsv not found"; exit 1; }

  local registry
  registry="$(normalize_registry "$REGISTRY")"
  if [[ -z "$registry" ]]; then
    log "--registry not set, images will only be loaded locally and chart uses source image"
  fi

  if [[ -n "$registry" && -n "$REGISTRY_USER" ]]; then
    log "docker login $registry"
    printf '%s' "$REGISTRY_PASS" | docker login "$registry" -u "$REGISTRY_USER" --password-stdin
  fi

  while IFS=$'\t' read -r source archive load_ref target; do
    [[ -n "${source:-}" ]] || continue
    log "docker load $archive"
    docker load -i "$PAYLOAD_DIR/$archive"

    if [[ -n "$registry" ]]; then
      local target_ref="${registry}/${target}"
      log "docker tag $load_ref -> $target_ref"
      docker tag "$load_ref" "$target_ref"
      log "docker push $target_ref"
      docker push "$target_ref"
    fi
  done < "$PAYLOAD_DIR/images/image-index.tsv"
}

helm_install() {
  need_cmd helm
  need_cmd kubectl

  local chart="$PAYLOAD_DIR/charts/${CHART_NAME}"
  [[ -d "$chart" ]] || { err "chart not found: $chart"; exit 1; }

  local target source image_ref image_repo image_tag registry
  target="$(first_image_target)"
  source="$(source_image_ref)"
  registry="$(normalize_registry "$REGISTRY")"

  if [[ -n "$registry" ]]; then
    image_ref="${registry}/${target}"
  else
    image_ref="$source"
  fi

  image_repo="$(split_image_repo "$image_ref")"
  image_tag="$(split_image_tag "$image_ref")"

  local args=(
    upgrade --install "$RELEASE" "$chart"
    --namespace "$NAMESPACE"
    --create-namespace
    --set "image.repository=${image_repo}"
    --set "image.tag=${image_tag}"
    --set "image.pullPolicy=${PULL_POLICY}"
    --set "auth.username=${POSTGRES_USER}"
    --set "auth.password=${POSTGRES_PASSWORD}"
    --set "auth.database=${POSTGRES_DB}"
    --set "persistence.size=${SIZE}"
  )

  if [[ -n "$STORAGE_CLASS" ]]; then
    args+=(--set "persistence.storageClass=${STORAGE_CLASS}")
  fi

  if [[ -n "$VALUES_FILE" ]]; then
    [[ -f "$VALUES_FILE" ]] || { err "values file not found: $VALUES_FILE"; exit 1; }
    args+=(--values "$VALUES_FILE")
  fi

  log "helm ${args[*]}"
  helm "${args[@]}"

  log "waiting for rollout"
  kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout=300s || true
}

action_install() {
  with_payload
  need_cmd kubectl
  need_cmd helm

  if [[ "$POSTGRES_PASSWORD" == "$DEFAULT_POSTGRES_PASSWORD" ]]; then
    log "WARN: using demo default PostgreSQL password. Use --postgres-password in production."
  fi

  cat <<INFO
About to deploy ${APP_NAME}:
  release:   ${RELEASE}
  namespace: ${NAMESPACE}
  registry:  ${REGISTRY:-<source image>}
  database:  ${POSTGRES_DB}
  pvc size:  ${SIZE}
INFO

  confirm "Continue?" || { log "cancelled"; exit 0; }

  if [[ "$SKIP_IMAGE_PREPARE" == "true" ]]; then
    log "skip image load/tag/push"
  else
    prepare_images
  fi

  helm_install
  action_status
}

action_status() {
  need_cmd kubectl
  if command -v helm >/dev/null 2>&1; then
    helm status "$RELEASE" -n "$NAMESPACE" || true
  fi
  kubectl get pods,svc,statefulset,pvc,secret -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" -o wide || true
}

action_uninstall() {
  need_cmd helm
  need_cmd kubectl
  cat <<INFO
About to uninstall ${APP_NAME}:
  release:   ${RELEASE}
  namespace: ${NAMESPACE}
  deletePVC: ${DELETE_PVC}
INFO
  confirm "Continue?" || { log "cancelled"; exit 0; }

  helm uninstall "$RELEASE" -n "$NAMESPACE" || true

  if [[ "$DELETE_PVC" == "true" ]]; then
    log "delete PVCs for release $RELEASE"
    kubectl delete pvc -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" --ignore-not-found=true
  else
    log "PVCs are kept. Use --delete-pvc to remove data explicitly."
  fi
}

action_extract() {
  local to="${EXTRACT_TO:-}"
  [[ -n "$to" ]] || { err "extract requires --to <dir>"; exit 1; }
  extract_payload "$to"
  log "payload extracted to $to"
}

main() {
  parse_args "$@"
  case "$ACTION" in
    help|-h|--help) usage ;;
    install) action_install ;;
    status) action_status ;;
    uninstall) action_uninstall ;;
    extract) action_extract ;;
    *)
      err "unknown action: $ACTION"
      usage
      exit 1
      ;;
  esac
}

main "$@"
