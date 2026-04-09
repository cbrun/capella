#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

IMAGE_TAG="capella-ui-tests-ubuntu2404:local"
DOCKERFILE_PATH="scripts/docker/ubuntu2404-ui-tests.Dockerfile"
REBUILD_IMAGE=0
DISPLAY_NUM=29

usage() {
  cat <<'EOF'
Usage: scripts/run-ui-tests-ubuntu2404.sh [docker-options] [-- <args passed to local script>]

Run scripts/run-ui-tests-local.sh inside the Ubuntu 24.04 parity image used for UI test diagnosis.

Docker options:
  --image-tag <tag>      Docker image tag (default: capella-ui-tests-ubuntu2404:local)
  --dockerfile <path>    Dockerfile path (default: scripts/docker/ubuntu2404-ui-tests.Dockerfile)
  --rebuild-image        Force rebuild of the Docker image
  -h, --help             Show this help

Forwarded args (after --) are passed to scripts/run-ui-tests-local.sh.
Common forwarded args:
  --scope full|focused-failures
  --product-tar <path>
  --test-site-repo <path>
  --timeout-min <N>
  --display <N>

Examples:
  scripts/run-ui-tests-ubuntu2404.sh -- --scope focused-failures --timeout-min 60
  scripts/run-ui-tests-ubuntu2404.sh -- --scope full --product-tar artifacts/capella-product-linux-x86_64/capella-linux-x86_64.tar.gz --test-site-repo artifacts/capella-update-sites/releng/plugins/org.polarsys.capella.test.site/target/repository
EOF
}

declare -a FORWARDED_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-tag)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --dockerfile)
      DOCKERFILE_PATH="$2"
      shift 2
      ;;
    --rebuild-image)
      REBUILD_IMAGE=1
      shift
      ;;
    --)
      shift
      FORWARDED_ARGS=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

for ((i=0; i<${#FORWARDED_ARGS[@]}; i++)); do
  if [[ "${FORWARDED_ARGS[$i]}" == "--display" ]] && [[ $((i + 1)) -lt ${#FORWARDED_ARGS[@]} ]]; then
    DISPLAY_NUM="${FORWARDED_ARGS[$((i + 1))]}"
  fi
done

VNC_PORT=$((5900 + DISPLAY_NUM))

command -v docker >/dev/null 2>&1 || {
  echo "Missing required command: docker"
  exit 2
}

docker info >/dev/null 2>&1 || {
  echo "Docker daemon is not reachable."
  exit 2
}

[[ -f "${DOCKERFILE_PATH}" ]] || {
  echo "Dockerfile not found: ${DOCKERFILE_PATH}"
  exit 2
}

if [[ "${REBUILD_IMAGE}" -eq 1 ]] || ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "== Building Docker image =="
  echo "Image tag   : ${IMAGE_TAG}"
  echo "Dockerfile  : ${DOCKERFILE_PATH}"
  docker build -t "${IMAGE_TAG}" -f "${DOCKERFILE_PATH}" .
fi

echo "== Ubuntu 24.04 UI parity run =="
echo "Repo root   : ${REPO_ROOT}"
echo "Image tag   : ${IMAGE_TAG}"
echo "Forwarded   : ${FORWARDED_ARGS[*]:-(none)}"
echo "VNC monitor : vncviewer localhost:${DISPLAY_NUM} (TCP ${VNC_PORT})"
echo

docker run --rm -t \
  --user "$(id -u):$(id -g)" \
  --shm-size=2g \
  -p "127.0.0.1:${VNC_PORT}:${VNC_PORT}" \
  -e LANG="en_US.UTF-8" \
  -e JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-}" \
  -v "${REPO_ROOT}:/workspace/capella" \
  -w /workspace/capella \
  "${IMAGE_TAG}" \
  bash -lc '
    set -euo pipefail
    echo "Container OS  : $(grep -E "^PRETTY_NAME=" /etc/os-release | cut -d= -f2-)"
    echo "fc-match sans : $(fc-match sans)"
    echo "fc-match serif: $(fc-match serif)"
    echo "fc-match mono : $(fc-match monospace)"
    echo
    scripts/run-ui-tests-local.sh "$@"
  ' _ "${FORWARDED_ARGS[@]}"
