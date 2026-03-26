#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

DISPLAY_NUM=29
WATCH=0
VNC_NO_AUTH=0
TIMEOUT_MIN=20
AUTO_BUILD=1
UI_MODE=0
PLUGIN=""
CLASS_NAME=""
TEST_SITE_REPO="releng/plugins/org.polarsys.capella.test.site/target/repository"
RUNTIME_ROOT="${CAPELLA_RUNTIME_ROOT:-${REPO_ROOT}/runtime/single-test-loop}"
RESULTS_BASE="${CAPELLA_RESULTS_BASE:-${REPO_ROOT}/test-results/single-test}"
WORK_BASE_ROOT="${CAPELLA_WORK_BASE_ROOT:-${REPO_ROOT}/test-workspaces/single-test}"

SAMPLES_GUARD_ENABLED=0
SAMPLES_WAS_CLEAN=0
XVNC_PID=""
VIEWER_PID=""

usage() {
  cat <<'USAGE'
Usage: scripts/run-single-test-loop.sh --plugin <id> --class <fqcn> [options]

Run one Capella testcase quickly in a cached local runtime.

Required:
  --plugin <id>           OSGi test plugin id
  --class <fqcn>          Fully-qualified testcase class name

Options:
  --ui                    Use UI test application (default: non-UI)
  --display <N>           X display number (default: 29)
  --watch                 Open local vncviewer on the isolated display
  --vnc-no-auth           Kept for compatibility (Jenkins parity is already no-auth)
  --timeout-min <N>       Timeout in minutes (default: 20)
  --test-site-repo <path> Override test update-site repository path
  --no-build              Skip auto-rebuild of test update site
  -h, --help              Show this help

Example (LicenceTest):
  scripts/run-single-test-loop.sh \
    --plugin org.polarsys.capella.test.platform.ju \
    --class org.polarsys.capella.test.platform.ju.testcases.LicenceTest \
    --ui
USAGE
}

samples_is_dirty() {
  ! git -C "${REPO_ROOT}" diff --quiet -- samples/ \
    || ! git -C "${REPO_ROOT}" diff --cached --quiet -- samples/ \
    || [[ -n "$(git -C "${REPO_ROOT}" ls-files --others --exclude-standard -- samples/)" ]]
}

snapshot_samples_state() {
  if ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi
  if [[ ! -d "${REPO_ROOT}/samples" ]]; then
    return
  fi

  SAMPLES_GUARD_ENABLED=1
  if ! samples_is_dirty; then
    SAMPLES_WAS_CLEAN=1
  fi
}

cleanup_samples_changes() {
  if [[ "${SAMPLES_GUARD_ENABLED}" -ne 1 ]]; then
    return
  fi

  if [[ "${SAMPLES_WAS_CLEAN}" -ne 1 ]]; then
    echo "Git cleanup: skipped samples/ restore (it was already dirty before test run)."
    return
  fi

  if ! samples_is_dirty; then
    echo "Git cleanup: samples/ unchanged by tests."
    return
  fi

  git -C "${REPO_ROOT}" restore --worktree --source=HEAD -- samples/
  git -C "${REPO_ROOT}" ls-files --others --exclude-standard -z -- samples/ | xargs -0 -r rm -rf --
  echo "Git cleanup: restored samples/ to pre-test state."
}

wait_for_listener() {
  local listener_pid="$1"
  local waited=0

  while kill -0 "${listener_pid}" >/dev/null 2>&1; do
    if [[ "${waited}" -ge 10 ]]; then
      echo "[WARN ] Listener still running after 10s; forcing stop"
      kill "${listener_pid}" >/dev/null 2>&1 || true
      wait "${listener_pid}" >/dev/null 2>&1 || true
      return
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

read_junit_failures_errors() {
  local xml_file="$1"
  python3 - "$xml_file" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
root = ET.parse(xml_path).getroot()

def as_int(value):
    try:
        return int(value or "0")
    except ValueError:
        return 0

failures = 0
errors = 0
for suite in root.iter("testsuite"):
    failures += as_int(suite.attrib.get("failures"))
    errors += as_int(suite.attrib.get("errors"))

print(f"{failures} {errors}")
PY
}

cleanup() {
  cleanup_samples_changes
  if [[ -n "${VIEWER_PID}" ]]; then
    kill "${VIEWER_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${XVNC_PID}" ]]; then
    kill "${XVNC_PID}" >/dev/null 2>&1 || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin)
      PLUGIN="$2"
      shift 2
      ;;
    --class)
      CLASS_NAME="$2"
      shift 2
      ;;
    --ui)
      UI_MODE=1
      shift
      ;;
    --display)
      DISPLAY_NUM="$2"
      shift 2
      ;;
    --watch)
      WATCH=1
      shift
      ;;
    --vnc-no-auth)
      VNC_NO_AUTH=1
      shift
      ;;
    --timeout-min)
      TIMEOUT_MIN="$2"
      shift 2
      ;;
    --test-site-repo)
      TEST_SITE_REPO="$2"
      shift 2
      ;;
    --no-build)
      AUTO_BUILD=0
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

if [[ -z "${PLUGIN}" || -z "${CLASS_NAME}" ]]; then
  echo "--plugin and --class are required."
  echo
  usage
  exit 2
fi

if [[ "${VNC_NO_AUTH}" -eq 1 ]]; then
  echo "Note: --vnc-no-auth is now a no-op (Jenkins parity already uses SecurityTypes=none)."
fi

for cmd in Xvnc timeout; do
  command -v "${cmd}" >/dev/null || {
    echo "Missing required command: ${cmd}"
    exit 2
  }
done

if [[ "${AUTO_BUILD}" -eq 1 ]]; then
  command -v mvn >/dev/null || {
    echo "Missing required command for auto-build: mvn"
    exit 2
  }
fi

if [[ ! -d "${TEST_SITE_REPO}" ]]; then
  echo "Test update-site repository not found: ${TEST_SITE_REPO}"
  echo "Build command to produce it:"
  echo "  mvn -B -V -Pfull -pl releng/plugins/org.polarsys.capella.test.site -am package -DskipTests"
  exit 2
fi

CAPELLA_HOME="${RUNTIME_ROOT}/capella"
CAPELLA_BIN="${CAPELLA_HOME}/capella"
if [[ ! -x "${CAPELLA_BIN}" ]]; then
  echo "Cached runtime not found: ${CAPELLA_BIN}"
  echo "Prepare it first:"
  echo "  scripts/prepare-single-test-loop.sh"
  exit 2
fi

snapshot_samples_state

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="${RESULTS_BASE}/${RUN_ID}"
WORK_BASE="${WORK_BASE_ROOT}/${RUN_ID}"
mkdir -p "${RESULT_DIR}" "${WORK_BASE}"
ln -sfn "${RESULT_DIR}" "${RESULTS_BASE}/latest"
ln -sfn "${WORK_BASE}" "${WORK_BASE_ROOT}/latest"

echo "== Start isolated Xvnc (Jenkins parity) =="
XVNC_LOG="${RESULT_DIR}/xvnc.log"
XVNC_ARGS=( ":${DISPLAY_NUM}" -geometry 1024x768 -depth 24 -ac -SecurityTypes none -noreset )
echo "Xvnc command: Xvnc ${XVNC_ARGS[*]}"
Xvnc "${XVNC_ARGS[@]}" >"${XVNC_LOG}" 2>&1 &
XVNC_PID=$!
trap cleanup EXIT
export DISPLAY=":${DISPLAY_NUM}"
sleep 3

if [[ "${AUTO_BUILD}" -eq 1 ]]; then
  echo "== Auto-build test update site (fast loop mode) =="
  BUILD_CMD=(mvn -B -V -Pfull -pl releng/plugins/org.polarsys.capella.test.site -am package -DskipTests)
  echo "Build command: ${BUILD_CMD[*]}"
  set +e
  "${BUILD_CMD[@]}"
  BUILD_RC=$?
  set -e
  if [[ "${BUILD_RC}" -ne 0 ]]; then
    echo
    echo "Fast auto-build failed (exit=${BUILD_RC})."
    echo "Use one of the following:"
    echo "  1) Fast rerun with existing artifacts:"
    echo "     scripts/run-single-test-loop.sh --plugin ${PLUGIN} --class ${CLASS_NAME} --no-build"
    echo "  2) Rebuild full artifacts, then rerun:"
    echo "     scripts/prepare-product-jres.sh --java-major 21"
    echo "     mvn -B -V verify -Pfull"
    exit "${BUILD_RC}"
  fi
else
  echo "== Auto-build skipped (--no-build) =="
fi

echo "== Refresh Capella test feature in cached runtime =="
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

echo "Monitor instructions:"
echo "  1) Open a new terminal"
echo "  2) Connect with: vncviewer localhost:${DISPLAY_NUM}"
echo "     (No password required; matches Jenkins Xvnc SecurityTypes=none)"
echo

if [[ "${WATCH}" -eq 1 ]]; then
  if command -v vncviewer >/dev/null; then
    vncviewer "localhost:${DISPLAY_NUM}" >/dev/null 2>&1 &
    VIEWER_PID=$!
    echo "VNC viewer started on localhost:${DISPLAY_NUM}"
  else
    echo "Requested --watch, but no vncviewer found. Continuing headless."
  fi
fi

MODE_LABEL="nonui"
APP_ID="org.eclipse.pde.junit.runtime.coretestapplication"
if [[ "${UI_MODE}" -eq 1 ]]; then
  MODE_LABEL="ui"
  APP_ID="org.eclipse.pde.junit.runtime.uitestapplication"
fi

PORT=$((25000 + RANDOM % 2000))
SUITE_ID="single__${CLASS_NAME}"
SUITE_ID="$(echo "${SUITE_ID}" | tr -c '[:alnum:]_.-' '_')"
LOG_FILE="${RESULT_DIR}/${SUITE_ID}.log"
LISTENER_LOG="${RESULT_DIR}/${SUITE_ID}__listener.log"
LISTENER_WS="${WORK_BASE}/listener"
TEST_WS="${WORK_BASE}/test"
mkdir -p "${LISTENER_WS}" "${TEST_WS}"

echo "[START] ${PLUGIN} :: ${CLASS_NAME} (${MODE_LABEL})"
(
  cd "${RESULT_DIR}"
  "${CAPELLA_BIN}" \
    -nosplash \
    -consoleLog \
    -data "${LISTENER_WS}" \
    -application org.polarsys.capella.test.run.application \
    -port "${PORT}" \
    -title "${SUITE_ID}" \
    >"${LISTENER_LOG}" 2>&1
) &
LISTENER_PID=$!
sleep 2
if ! kill -0 "${LISTENER_PID}" >/dev/null 2>&1; then
  echo "[FAIL ] Listener did not start"
  echo
  echo "SINGLE TEST SUMMARY: FAIL"
  echo "Testcase     : ${CLASS_NAME}"
  echo "Plugin       : ${PLUGIN}"
  echo "Mode         : ${MODE_LABEL}"
  echo "Results dir  : ${RESULT_DIR}"
  echo "Listener log : ${LISTENER_LOG}"
  exit 1
fi

set +e
timeout "${TIMEOUT_MIN}m" "${CAPELLA_BIN}" \
  -nosplash \
  -consoleLog \
  -application "${APP_ID}" \
  -port "${PORT}" \
  -testpluginname "${PLUGIN}" \
  -classname "${CLASS_NAME}" \
  -data "${TEST_WS}" \
  -clean \
  >"${LOG_FILE}" 2>&1
RC=$?
set -e

wait_for_listener "${LISTENER_PID}"

STATUS="PASS"
if [[ "${RC}" -eq 124 ]]; then
  STATUS="TIMEOUT"
elif [[ "${RC}" -ne 0 ]]; then
  STATUS="FAIL"
fi

XML_FILE="${RESULT_DIR}/${SUITE_ID}.xml"
XML_FAILURES=0
XML_ERRORS=0
if [[ -f "${XML_FILE}" ]]; then
  read -r XML_FAILURES XML_ERRORS < <(read_junit_failures_errors "${XML_FILE}")
  if [[ "${XML_FAILURES}" -gt 0 || "${XML_ERRORS}" -gt 0 ]]; then
    STATUS="FAIL"
    if [[ "${RC}" -eq 0 ]]; then
      RC=1
    fi
  fi
else
  echo "[WARN ] JUnit XML not found: ${XML_FILE}"
fi

echo
echo "============================================================"
echo "SINGLE TEST SUMMARY"
echo "============================================================"
echo "Status       : ${STATUS}"
echo "Exit code    : ${RC}"
echo "Plugin       : ${PLUGIN}"
echo "Testcase     : ${CLASS_NAME}"
echo "Mode         : ${MODE_LABEL}"
echo "Results dir  : ${RESULT_DIR}"
echo "Test log     : ${LOG_FILE}"
echo "Listener log : ${LISTENER_LOG}"
echo "JUnit XML    : ${XML_FILE}"
echo "XML failures : ${XML_FAILURES}"
echo "XML errors   : ${XML_ERRORS}"
echo "Xvnc log     : ${XVNC_LOG}"
echo "============================================================"
echo "Quick inspection commands:"
echo "  tail -n 200 ${LOG_FILE}"
echo "  tail -n 200 ${LISTENER_LOG}"
echo "  rg -n \"FAIL|ERROR|Exception\" ${RESULT_DIR}/*.log"

if [[ "${RC}" -ne 0 ]]; then
  exit "${RC}"
fi

exit 0
