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
Usage: scripts/run-focused-failures-ubuntu2404.sh [options] [-- <args passed to local script>]

Run focused failing testcases in an Ubuntu 24.04 Docker container to match Jenkins/GitHub-hosted environment.
VNC monitoring is enabled by default on localhost.

Options:
  --image-tag <tag>      Docker image tag (default: capella-ui-tests-ubuntu2404:local)
  --dockerfile <path>    Dockerfile path (default: scripts/docker/ubuntu2404-ui-tests.Dockerfile)
  --rebuild-image        Force rebuild of the Docker image
  -h, --help             Show this help

Any arguments after "--" are forwarded to:
  scripts/run-focused-failures-local.sh

Examples:
  scripts/run-focused-failures-ubuntu2404.sh -- --no-build
  scripts/run-focused-failures-ubuntu2404.sh --rebuild-image -- --only org.polarsys.capella.test.navigator.ju.DefaultLayout --no-build
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

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing required command: docker"
  exit 2
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable."
  echo "Start Docker, then retry:"
  echo "  scripts/run-focused-failures-ubuntu2404.sh -- --no-build"
  exit 2
fi

if [[ ! -f "${DOCKERFILE_PATH}" ]]; then
  echo "Dockerfile not found: ${DOCKERFILE_PATH}"
  exit 2
fi

if [[ "${REBUILD_IMAGE}" -eq 1 ]] || ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "== Building Docker image =="
  echo "Image tag   : ${IMAGE_TAG}"
  echo "Dockerfile  : ${DOCKERFILE_PATH}"
  docker build -t "${IMAGE_TAG}" -f "${DOCKERFILE_PATH}" .
fi

echo "== Ubuntu 24.04 parity run =="
echo "Repo root   : ${REPO_ROOT}"
echo "Image tag   : ${IMAGE_TAG}"
echo "Forwarded   : ${FORWARDED_ARGS[*]:-(none)}"
echo "VNC monitor : vncviewer localhost:${DISPLAY_NUM} (TCP ${VNC_PORT})"
echo
echo "To watch test execution:"
echo "  vncviewer localhost:${DISPLAY_NUM}"
echo

docker run --rm -t \
  --shm-size=2g \
  -p "127.0.0.1:${VNC_PORT}:${VNC_PORT}" \
  -e MAVEN_OPTS="${MAVEN_OPTS:--Xmx2g}" \
  -e GDK_SCALE=1 \
  -e GDK_DPI_SCALE=1 \
  -e CAPELLA_RUNTIME_ROOT="/workspace/capella/runtime/single-test-loop-ubuntu2404" \
  -e CAPELLA_RESULTS_BASE="/workspace/capella/test-results/single-test-ubuntu2404" \
  -e CAPELLA_WORK_BASE_ROOT="/workspace/capella/test-workspaces/single-test-ubuntu2404" \
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
    if [[ ! -x "${CAPELLA_RUNTIME_ROOT}/capella/capella" ]]; then
      if [[ -x "/workspace/capella/runtime/single-test-loop/capella/capella" ]]; then
        echo "Preparing isolated Docker runtime from existing local runtime..."
        mkdir -p "${CAPELLA_RUNTIME_ROOT}"
        cp -a /workspace/capella/runtime/single-test-loop/. "${CAPELLA_RUNTIME_ROOT}/"
      else
        echo "Missing cached runtime:"
        echo "  ${CAPELLA_RUNTIME_ROOT}/capella/capella"
        echo "Prepare it first on host with:"
        echo "  scripts/prepare-single-test-loop.sh"
        exit 2
      fi
    fi
    scripts/run-focused-failures-local.sh "$@"
  ' _ "${FORWARDED_ARGS[@]}"
