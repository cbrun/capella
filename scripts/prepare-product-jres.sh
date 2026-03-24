#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

JAVA_MAJOR=17
CLEAN=0

usage() {
  cat <<'EOF'
Usage: scripts/prepare-product-jres.sh [options]

Prepare product-packaging JRE folders expected by:
  releng/plugins/org.polarsys.capella.rcp.product/pom.xml

This creates/fills:
  linuxJRE/jre
  linux-aarch64JRE/jre
  macJRE/jre
  mac-aarch64JRE/jre
  winJRE/jre

Options:
  --java-major <N>  Temurin major version to download (default: 17)
  --clean           Remove existing JRE staging folders before download
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --java-major)
      JAVA_MAJOR="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
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

for cmd in curl tar unzip find cp; do
  command -v "$cmd" >/dev/null || {
    echo "Missing required command: $cmd"
    exit 2
  }
done

if [[ "${CLEAN}" -eq 1 ]]; then
  rm -rf winJRE linuxJRE linux-aarch64JRE macJRE mac-aarch64JRE
fi

mkdir -p winJRE/jre linuxJRE/jre linux-aarch64JRE/jre macJRE/jre mac-aarch64JRE/jre

TMP_BASE="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_BASE}"
}
trap cleanup EXIT

fetch_jre_tar() {
  local os="$1" arch="$2" outdir="$3"
  local url="https://api.adoptium.net/v3/binary/latest/${JAVA_MAJOR}/ga/${os}/${arch}/jre/hotspot/normal/eclipse?project=jdk"
  local tarball="${TMP_BASE}/${os}-${arch}.tar.gz"

  echo "[JRE] Download ${os}/${arch} from Adoptium"
  curl -fL "${url}" -o "${tarball}"
  rm -rf "${outdir:?}"/*
  tar -xzf "${tarball}" -C "${outdir}" --strip-components=1
}

fetch_jre_zip() {
  local os="$1" arch="$2" outdir="$3"
  local url="https://api.adoptium.net/v3/binary/latest/${JAVA_MAJOR}/ga/${os}/${arch}/jre/hotspot/normal/eclipse?project=jdk"
  local zipfile="${TMP_BASE}/${os}-${arch}.zip"
  local unpack="${TMP_BASE}/${os}-${arch}-unpacked"

  echo "[JRE] Download ${os}/${arch} from Adoptium"
  curl -fL "${url}" -o "${zipfile}"
  rm -rf "${unpack}"
  unzip -q "${zipfile}" -d "${unpack}"
  local top
  top="$(find "${unpack}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "${top}" ]] || {
    echo "Unable to locate unpacked top-level JRE directory for ${os}/${arch}"
    exit 1
  }
  rm -rf "${outdir:?}"/*
  cp -a "${top}"/* "${outdir}/"
}

fetch_jre_tar linux x64 linuxJRE/jre
fetch_jre_tar linux aarch64 linux-aarch64JRE/jre
fetch_jre_tar mac x64 macJRE/jre
fetch_jre_tar mac aarch64 mac-aarch64JRE/jre
fetch_jre_zip windows x64 winJRE/jre

test -x linuxJRE/jre/bin/java
test -x linux-aarch64JRE/jre/bin/java
test -x macJRE/jre/Contents/Home/bin/java
test -x mac-aarch64JRE/jre/Contents/Home/bin/java
test -f winJRE/jre/bin/java.exe

echo
echo "Prepared product-packaging JRE folders successfully."
echo "Next build command:"
echo "  mvn -B -V verify -Pfull"
