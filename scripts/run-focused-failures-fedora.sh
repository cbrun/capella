#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

IMAGE_TAG="capella-ui-tests-fedora39:local"
DOCKERFILE_PATH="scripts/docker/fedora-ui-tests.Dockerfile"
REBUILD_IMAGE=0
DISPLAY_NUM=29

usage() {
  cat <<'USAGE'
Usage: scripts/run-focused-failures-fedora.sh [options] [-- <args passed to local script>]

Run focused failing testcases in a Fedora 39 Docker container to approximate the Jenkins Fedora-family environment.
VNC monitoring is enabled by default on localhost.
This wrapper reuses the same cached runtime and test update-site as the local launcher.
Run a full no-tests rebuild first when you need newly compiled test bundles to appear in Docker.

Options:
  --image-tag <tag>      Docker image tag (default: capella-ui-tests-fedora39:local)
  --dockerfile <path>    Dockerfile path (default: scripts/docker/fedora-ui-tests.Dockerfile)
  --rebuild-image        Force rebuild of the Docker image
  -h, --help             Show this help

Any arguments after "--" are forwarded to:
  scripts/run-focused-failures-local.sh

Examples:
  scripts/run-focused-failures-fedora.sh -- --no-build
  scripts/run-focused-failures-fedora.sh --rebuild-image -- --only org.polarsys.capella.test.navigator.ju.DefaultLayout --no-build
  scripts/run-focused-failures-fedora.sh -- --only org.polarsys.capella.test.platform.ju.testcases.UIEnvironmentFingerprintTest --plugin org.polarsys.capella.test.platform.ju --ui
USAGE
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
  echo "  scripts/run-focused-failures-fedora.sh -- --no-build"
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

echo "== Fedora 39 parity run =="
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
  -e LANG="en_US.UTF-8" \
  -e CAPELLA_RUNTIME_ROOT="/workspace/capella/runtime/single-test-loop-fedora39" \
  -e CAPELLA_RESULTS_BASE="/workspace/capella/test-results/single-test-fedora39" \
  -e CAPELLA_WORK_BASE_ROOT="/workspace/capella/test-workspaces/single-test-fedora39" \
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
