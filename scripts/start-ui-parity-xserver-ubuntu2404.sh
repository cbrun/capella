#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

IMAGE_TAG="capella-ui-tests-ubuntu2404:local"
DOCKERFILE_PATH="scripts/docker/ubuntu2404-ui-tests.Dockerfile"
REBUILD_IMAGE=0
DISPLAY_NUM=29
WATCH=0
VIEWER_PID=""
FONT_MISMATCH=0

font_family() {
  fc-match -f '%{family[0]}\n' "$1" 2>/dev/null || true
}

check_font_alias() {
  local query="$1"
  local expected="$2"
  local actual
  actual="$(font_family "${query}")"

  if [[ -z "${actual}" ]]; then
    echo "Host font   : ${query} => <unresolved> (expected ${expected})"
    FONT_MISMATCH=1
    return
  fi

  echo "Host font   : ${query} => ${actual} (expected ${expected})"
  if [[ "${actual}" != "${expected}" ]]; then
    FONT_MISMATCH=1
  fi
}

print_font_alignment_help() {
  cat <<'EOF'

Host fontconfig does not match the Ubuntu 24.04 parity image.
DISPLAY forwarding only reuses the container X server; the launched Eclipse JVM
still uses host-side fontconfig and fonts. If a UI test is sensitive to text
metrics or icon fallbacks, align the host font stack first.

Suggested commands on Debian/Ubuntu:
  sudo apt-get update
  sudo apt-get install -y fontconfig fonts-dejavu-core
  mkdir -p ~/.config/fontconfig/conf.d
  cat > ~/.config/fontconfig/conf.d/99-capella-ui-parity.conf <<'XML'
  <?xml version="1.0"?>
  <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
  <fontconfig>
    <match target="pattern">
      <test qual="any" name="family">
        <string>Segoe UI</string>
      </test>
      <edit name="family" mode="assign" binding="strong">
        <string>DejaVu Sans</string>
      </edit>
    </match>
    <match target="pattern">
      <test qual="any" name="family">
        <string>Teen</string>
      </test>
      <edit name="family" mode="assign" binding="strong">
        <string>DejaVu Sans</string>
      </edit>
    </match>
    <alias>
      <family>sans-serif</family>
      <prefer>
        <family>DejaVu Sans</family>
      </prefer>
    </alias>
    <alias>
      <family>serif</family>
      <prefer>
        <family>DejaVu Serif</family>
      </prefer>
    </alias>
    <alias>
      <family>monospace</family>
      <prefer>
        <family>DejaVu Sans Mono</family>
      </prefer>
    </alias>
  </fontconfig>
  XML
  fc-cache -f

Re-run this script afterwards and make sure the host checks resolve to:
  sans       => DejaVu Sans
  serif      => DejaVu Serif
  monospace  => DejaVu Sans Mono
  Segoe UI   => DejaVu Sans
  Teen       => DejaVu Sans
EOF
}

stop_conflicting_containers() {
  local line
  local -a ids=()
  local -a summaries=()

  while IFS=$'\t' read -r id name ports; do
    [[ -n "${id}" ]] || continue
    if [[ "${ports}" == *"127.0.0.1:${VNC_PORT}->"* ]] || [[ "${ports}" == *"127.0.0.1:${X11_PORT}->"* ]]; then
      ids+=("${id}")
      summaries+=("${name:-${id}} :: ${ports}")
    fi
  done < <(docker ps --format '{{.ID}}\t{{.Names}}\t{{.Ports}}')

  if [[ "${#ids[@]}" -eq 0 ]]; then
    return
  fi

  echo "== Stop stale Docker port owners =="
  printf '%s\n' "${summaries[@]}"
  docker stop "${ids[@]}" >/dev/null
  echo
}

ensure_host_ports_are_free() {
  if ss -ltn "( sport = :${VNC_PORT} or sport = :${X11_PORT} )" | grep -q LISTEN; then
    echo "Ports ${VNC_PORT} or ${X11_PORT} are still in use after Docker cleanup."
    echo "Check the remaining listeners with:"
    echo "  ss -ltnp '( sport = :${VNC_PORT} or sport = :${X11_PORT} )'"
    exit 2
  fi
}

usage() {
  cat <<'EOF'
Usage: scripts/start-ui-parity-xserver-ubuntu2404.sh [options]

Start only the Ubuntu 24.04 parity Xvnc display inside Docker and forward it
to the host. This lets a locally launched Eclipse UI test draw on the same
container-managed X server while still using the host JVM.

Options:
  --display <N>          X display number (default: 29)
  --image-tag <tag>      Docker image tag (default: capella-ui-tests-ubuntu2404:local)
  --dockerfile <path>    Dockerfile path (default: scripts/docker/ubuntu2404-ui-tests.Dockerfile)
  --rebuild-image        Force rebuild of the Docker image
  --watch                Open a host-side VNC viewer on the forwarded display
  -h, --help             Show this help

In Eclipse, set the launched test environment variable to:
  DISPLAY=127.0.0.1:<display>.0

Then monitor the display with:
  vncviewer localhost:<display>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --display)
      DISPLAY_NUM="$2"
      shift 2
      ;;
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
    --watch)
      WATCH=1
      shift
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

VNC_PORT=$((5900 + DISPLAY_NUM))
X11_PORT=$((6000 + DISPLAY_NUM))

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

stop_conflicting_containers
ensure_host_ports_are_free

echo "== Host font parity check =="
if command -v fc-match >/dev/null 2>&1; then
  check_font_alias "sans" "DejaVu Sans"
  check_font_alias "serif" "DejaVu Serif"
  check_font_alias "monospace" "DejaVu Sans Mono"
  check_font_alias "Segoe UI" "DejaVu Sans"
  check_font_alias "Teen" "DejaVu Sans"
  if [[ "${FONT_MISMATCH}" -eq 1 ]]; then
    print_font_alignment_help
  fi
else
  echo "Host font   : fc-match not found; cannot compare host fontconfig with the parity container."
  print_font_alignment_help
fi
echo

cleanup() {
  if [[ -n "${VIEWER_PID}" ]]; then
    kill "${VIEWER_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "${WATCH}" -eq 1 ]]; then
  if command -v vncviewer >/dev/null 2>&1; then
    (
      sleep 3
      exec vncviewer "localhost:${DISPLAY_NUM}" >/dev/null 2>&1
    ) &
    VIEWER_PID=$!
  else
    echo "Requested --watch, but no host-side vncviewer was found. Continuing headless."
  fi
fi

echo "== Ubuntu 24.04 parity X server =="
echo "Repo root   : ${REPO_ROOT}"
echo "Image tag   : ${IMAGE_TAG}"
echo "Display     : :${DISPLAY_NUM}"
echo "Host X11    : localhost:${DISPLAY_NUM} (TCP ${X11_PORT})"
echo "Host VNC    : localhost:${DISPLAY_NUM} (TCP ${VNC_PORT})"
echo
echo "Use this in Eclipse:"
echo "  DISPLAY=127.0.0.1:${DISPLAY_NUM}.0"
echo
echo "Keep this command running while the test is active."
echo

docker run --rm -t \
  --user "$(id -u):$(id -g)" \
  --shm-size=2g \
  -p "127.0.0.1:${VNC_PORT}:${VNC_PORT}" \
  -p "127.0.0.1:${X11_PORT}:${X11_PORT}" \
  -e LANG="en_US.UTF-8" \
  -w /workspace/capella \
  "${IMAGE_TAG}" \
  bash -lc '
    set -euo pipefail
    XVNC_ARGS=( ":${0}" -geometry 1024x768 -depth 24 -ac -SecurityTypes none -noreset -listen tcp )
    echo "Container OS  : $(grep -E "^PRETTY_NAME=" /etc/os-release | cut -d= -f2-)"
    echo "fc-match sans : $(fc-match sans)"
    echo "fc-match serif: $(fc-match serif)"
    echo "fc-match mono : $(fc-match monospace)"
    echo "Xvnc command  : Xvnc ${XVNC_ARGS[*]}"
    echo
    Xvnc "${XVNC_ARGS[@]}"
  ' "${DISPLAY_NUM}"
