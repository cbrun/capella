#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

PRODUCT_TAR=""
TEST_SITE_REPO=""
RUNTIME_ROOT="${REPO_ROOT}/runtime/single-test-loop"

usage() {
  cat <<'USAGE'
Usage: scripts/prepare-single-test-loop.sh [options]

Prepare a cached Capella runtime to iterate quickly on a single UI/non-UI testcase.

Options:
  --product-tar <path>    Override Linux product tarball path
  --test-site-repo <path> Override test update-site repository path
  -h, --help              Show this help

Default inputs:
  releng/plugins/org.polarsys.capella.rcp.product/target/products/capella-*-linux-gtk-x86_64.tar.gz
  releng/plugins/org.polarsys.capella.test.site/target/repository
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product-tar)
      PRODUCT_TAR="$2"
      shift 2
      ;;
    --test-site-repo)
      TEST_SITE_REPO="$2"
      shift 2
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

for cmd in tar find; do
  command -v "$cmd" >/dev/null || {
    echo "Missing required command: $cmd"
    exit 2
  }
done

if [[ -z "${PRODUCT_TAR}" ]]; then
  PRODUCT_TAR="$(find releng/plugins/org.polarsys.capella.rcp.product/target/products \
    -maxdepth 1 -type f -name 'capella-*-linux-gtk-x86_64.tar.gz' | sort | tail -n 1 || true)"
fi

if [[ -z "${TEST_SITE_REPO}" ]]; then
  TEST_SITE_REPO="releng/plugins/org.polarsys.capella.test.site/target/repository"
fi

if [[ ! -f "${PRODUCT_TAR}" ]]; then
  echo "Linux product tarball not found."
  echo "Expected pattern: releng/plugins/org.polarsys.capella.rcp.product/target/products/capella-*-linux-gtk-x86_64.tar.gz"
  echo
  echo "Commands to produce product archives:"
  echo "  scripts/prepare-product-jres.sh --java-major 21"
  echo "  mvn -B -V verify -Pfull"
  echo
  echo "If you need a clean rebuild first:"
  echo "  mvn -B -V clean verify -Pfull"
  exit 2
fi

if [[ ! -d "${TEST_SITE_REPO}" ]]; then
  echo "Test update-site repository not found: ${TEST_SITE_REPO}"
  echo
  echo "Build command to produce it quickly:"
  echo "  mvn -B -V -Pfull -pl releng/plugins/org.polarsys.capella.test.site -am package -DskipTests"
  exit 2
fi

echo "== Prepare Single-Test Loop Runtime =="
echo "Repo root      : ${REPO_ROOT}"
echo "Product tar    : ${PRODUCT_TAR}"
echo "Test site repo : ${TEST_SITE_REPO}"
echo "Runtime root   : ${RUNTIME_ROOT}"
echo

rm -rf "${RUNTIME_ROOT}"
mkdir -p "${RUNTIME_ROOT}"

echo "== Unpack Linux product =="
tar -xzf "${PRODUCT_TAR}" -C "${RUNTIME_ROOT}"
CAPELLA_HOME="${RUNTIME_ROOT}/capella"
CAPELLA_BIN="${CAPELLA_HOME}/capella"

if [[ ! -x "${CAPELLA_BIN}" ]]; then
  echo "Capella binary not found after unpack: ${CAPELLA_BIN}"
  exit 2
fi

echo "== Install Capella test feature in cached runtime =="
"${CAPELLA_BIN}" \
  -nosplash \
  -consoleLog \
  -application org.eclipse.equinox.p2.director \
  -repository "file:${REPO_ROOT}/${TEST_SITE_REPO}" \
  -installIU org.polarsys.capella.test.feature.feature.group \
  -destination "${CAPELLA_HOME}" \
  -bundlepool "${CAPELLA_HOME}" \
  -profile DefaultProfile \
  -profileProperties org.eclipse.update.install.features=true

echo
echo "Prepared cached runtime successfully."
echo "Next step (LicenceTest example):"
echo "  scripts/run-single-test-loop.sh --plugin org.polarsys.capella.test.platform.ju --class org.polarsys.capella.test.platform.ju.testcases.LicenceTest --ui"
echo
echo "To monitor UI execution on isolated desktop:"
echo "  scripts/run-single-test-loop.sh --plugin org.polarsys.capella.test.platform.ju --class org.polarsys.capella.test.platform.ju.testcases.LicenceTest --ui --watch --vnc-no-auth"
