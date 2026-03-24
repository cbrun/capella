#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

DISPLAY_NUM=29
WATCH=0
TIMEOUT_MIN=20
AUTO_BUILD=1
UI_MODE=0
DEBUG_JVM_PORT=""
DEBUG_JVM_SUSPEND=0
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
This script is intended for fast iteration after a full no-tests rebuild has published:
  - the Capella product archive
  - the Capella test update-site

Why the rebuild matters:
  The cached runtime installs org.polarsys.capella.test.feature.feature.group from
  releng/plugins/org.polarsys.capella.test.site/target/repository. Partial Tycho builds
  of only the test site are not reliable in this repository because the feature consumes
  test plugin IUs assembled across the full reactor.

Required:
  --plugin <id>           OSGi test plugin id
  --class <fqcn>          Fully-qualified testcase class name

Options:
  --ui                    Use UI test application (default: non-UI)
  --display <N>           X display number (default: 29)
  --watch                 Open local vncviewer on the isolated display
  --timeout-min <N>       Timeout in minutes (default: 20)
  --test-site-repo <path> Override test update-site repository path
  --debug-jvm-port <N>    Enable JDWP on the PDE test JVM on the given port
  --debug-jvm-suspend     Start the PDE test JVM suspended until a debugger attaches
  --no-build              Reuse existing trusted local artifacts without rebuilding
  -h, --help              Show this help

Example (LicenceTest):
  scripts/run-single-test-loop.sh \
    --plugin org.polarsys.capella.test.platform.ju \
    --class org.polarsys.capella.test.platform.ju.testcases.LicenceTest \
    --ui

Custom testcase workflow:
  1) Trusted local artifact build once:
       scripts/prepare-product-jres.sh --java-major 21
       mvn -B -V verify -Pfull -DskipTests -Dcyclonedx.skip=true
  2) Refresh cached runtime and run one testcase:
       scripts/run-single-test-loop.sh \
         --plugin org.polarsys.capella.test.platform.ju \
         --class org.polarsys.capella.test.platform.ju.testcases.UIEnvironmentFingerprintTest \
         --ui
  3) Fast rerun without rebuilding:
       scripts/run-single-test-loop.sh \
         --plugin org.polarsys.capella.test.platform.ju \
         --class org.polarsys.capella.test.platform.ju.testcases.UIEnvironmentFingerprintTest \
         --ui --no-build

Runtime freshness proof:
  This script prints the installed runtime bundle path, the published test-site
  bundle path, both sha256 values, and whether the testcase class is present in
  both artifacts. Use that comparison before trusting any local result.
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

jar_contains_class() {
  local jar_file="$1"
  local class_name="$2"
  python3 - "$jar_file" "$class_name" <<'PY'
import sys
import zipfile

jar_path = sys.argv[1]
class_name = sys.argv[2].replace(".", "/") + ".class"

try:
    with zipfile.ZipFile(jar_path) as jar:
        print("yes" if class_name in jar.namelist() else "no")
except FileNotFoundError:
    print("missing")
except zipfile.BadZipFile:
    print("badzip")
PY
}

find_installed_plugin_jar() {
  find "${CAPELLA_HOME}" -type f -path "*/plugins/${PLUGIN}_*.jar" | sort | tail -n 1
}

refresh_test_feature() {
  local refresh_log="$1"

  set +e
  "${CAPELLA_BIN}" \
    -nosplash \
    -consoleLog \
    -application org.eclipse.equinox.p2.director \
    -repository "file:${REPO_ROOT}/${TEST_SITE_REPO}" \
    -installIU org.polarsys.capella.test.feature.feature.group \
    -destination "${CAPELLA_HOME}" \
    -bundlepool "${CAPELLA_HOME}" \
    -profile DefaultProfile \
    -profileProperties org.eclipse.update.install.features=true \
    >"${refresh_log}" 2>&1
  local refresh_rc=$?
  set -e
  return "${refresh_rc}"
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
    --timeout-min)
      TIMEOUT_MIN="$2"
      shift 2
      ;;
    --test-site-repo)
      TEST_SITE_REPO="$2"
      shift 2
      ;;
    --debug-jvm-port)
      DEBUG_JVM_PORT="$2"
      shift 2
      ;;
    --debug-jvm-suspend)
      DEBUG_JVM_SUSPEND=1
      shift
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

if [[ "${DEBUG_JVM_SUSPEND}" -eq 1 && -z "${DEBUG_JVM_PORT}" ]]; then
  echo "--debug-jvm-suspend requires --debug-jvm-port."
  exit 2
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

if [[ "${AUTO_BUILD}" -eq 0 && ! -d "${TEST_SITE_REPO}" ]]; then
  echo "Test update-site repository not found: ${TEST_SITE_REPO}"
  echo "Build commands to produce it:"
  echo "  scripts/prepare-product-jres.sh --java-major 21"
  echo "  mvn -B -V verify -Pfull -DskipTests -Dcyclonedx.skip=true"
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
  echo "== Rebuild Capella artifacts required by the test runtime =="
  JRE_PREP_CMD=(scripts/prepare-product-jres.sh --java-major 21)
  BUILD_CMD=(mvn -B -V verify -Pfull -DskipTests -Dcyclonedx.skip=true)
  echo "JRE prep command: ${JRE_PREP_CMD[*]}"
  echo "Build command   : ${BUILD_CMD[*]}"
  set +e
  "${JRE_PREP_CMD[@]}"
  JRE_PREP_RC=$?
  set -e
  if [[ "${JRE_PREP_RC}" -ne 0 ]]; then
    echo
    echo "Preparing product JREs failed (exit=${JRE_PREP_RC})."
    echo "Use one of the following:"
    echo "  1) Fix the JRE staging issue, then rerun this command."
    echo "  2) Reuse existing artifacts:"
    echo "     scripts/run-single-test-loop.sh --plugin ${PLUGIN} --class ${CLASS_NAME} --no-build"
    exit "${JRE_PREP_RC}"
  fi
  set +e
  "${BUILD_CMD[@]}"
  BUILD_RC=$?
  set -e
  if [[ "${BUILD_RC}" -ne 0 ]]; then
    echo
    echo "Full no-tests rebuild failed (exit=${BUILD_RC})."
    echo "The local test runtime depends on the full Capella reactor because the test site"
    echo "consumes test feature and plugin IUs that a partial Tycho reactor does not assemble reliably."
    echo "Use one of the following:"
    echo "  1) Rerun with existing artifacts:"
    echo "     scripts/run-single-test-loop.sh --plugin ${PLUGIN} --class ${CLASS_NAME} --no-build"
    echo "  2) Rebuild trusted local artifacts manually, then rerun:"
    echo "     scripts/prepare-product-jres.sh --java-major 21"
    echo "     mvn -B -V verify -Pfull -DskipTests -Dcyclonedx.skip=true"
    exit "${BUILD_RC}"
  fi
else
  echo "== Rebuild skipped (--no-build) =="
fi

if [[ ! -d "${TEST_SITE_REPO}" ]]; then
  echo "Test update-site repository not found after build: ${TEST_SITE_REPO}"
  exit 2
fi

echo "== Refresh Capella test feature in cached runtime =="
REFRESH_LOG="${RESULT_DIR}/refresh-test-feature.log"
if ! refresh_test_feature "${REFRESH_LOG}"; then
  if grep -q "Software currently installed: Capella Tests Feature" "${REFRESH_LOG}"; then
    echo "Cached runtime contains an older Capella Tests Feature."
    echo "Re-preparing runtime from the freshly built product, then retrying refresh..."
    scripts/prepare-single-test-loop.sh \
      --test-site-repo "${TEST_SITE_REPO}" \
      --runtime-root "${RUNTIME_ROOT}"
    if ! refresh_test_feature "${REFRESH_LOG}"; then
      echo "Refreshing the cached runtime still failed after re-preparing it."
      echo "Refresh log: ${REFRESH_LOG}"
      tail -n 80 "${REFRESH_LOG}" || true
      exit 1
    fi
  else
    echo "Refreshing the cached runtime failed."
    echo "Refresh log: ${REFRESH_LOG}"
    tail -n 80 "${REFRESH_LOG}" || true
    exit 1
  fi
fi

INSTALLED_PLUGIN_JAR="$(find_installed_plugin_jar || true)"
INSTALLED_PLUGIN_SHA="missing"
INSTALLED_PLUGIN_HAS_CLASS="missing"
REPO_PLUGIN_JAR="$(find "${TEST_SITE_REPO}/plugins" -maxdepth 1 -type f -name "${PLUGIN}_*.jar" | sort | tail -n 1 || true)"
REPO_PLUGIN_SHA="missing"
REPO_PLUGIN_HAS_CLASS="missing"
if [[ -n "${INSTALLED_PLUGIN_JAR}" ]]; then
  INSTALLED_PLUGIN_SHA="$(sha256sum "${INSTALLED_PLUGIN_JAR}" | awk '{print $1}')"
  INSTALLED_PLUGIN_HAS_CLASS="$(jar_contains_class "${INSTALLED_PLUGIN_JAR}" "${CLASS_NAME}")"
fi
if [[ -n "${REPO_PLUGIN_JAR}" ]]; then
  REPO_PLUGIN_SHA="$(sha256sum "${REPO_PLUGIN_JAR}" | awk '{print $1}')"
  REPO_PLUGIN_HAS_CLASS="$(jar_contains_class "${REPO_PLUGIN_JAR}" "${CLASS_NAME}")"
fi
RUNTIME_MATCH_STATUS="mismatch"
if [[ -n "${INSTALLED_PLUGIN_JAR}" && -n "${REPO_PLUGIN_JAR}" && "${INSTALLED_PLUGIN_SHA}" == "${REPO_PLUGIN_SHA}" ]]; then
  RUNTIME_MATCH_STATUS="match"
fi

echo "Installed runtime bundle : ${INSTALLED_PLUGIN_JAR:-MISSING}"
echo "Installed runtime sha256 : ${INSTALLED_PLUGIN_SHA}"
echo "Installed class present  : ${INSTALLED_PLUGIN_HAS_CLASS}"
echo "Published test-site jar  : ${REPO_PLUGIN_JAR:-MISSING}"
echo "Published test-site sha  : ${REPO_PLUGIN_SHA}"
echo "Published class present  : ${REPO_PLUGIN_HAS_CLASS}"
echo "Runtime/test-site match  : ${RUNTIME_MATCH_STATUS}"

echo "Monitor instructions:"
echo "  1) Open a new terminal"
echo "  2) Connect with: vncviewer localhost:${DISPLAY_NUM}"
echo "     (No password required; matches Jenkins Xvnc SecurityTypes=none)"
if [[ -n "${DEBUG_JVM_PORT}" ]]; then
  echo "  3) Attach a JVM debugger to localhost:${DEBUG_JVM_PORT}"
  echo "     JDWP suspend         : $([[ \"${DEBUG_JVM_SUSPEND}\" -eq 1 ]] && echo yes || echo no)"
fi
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
TEST_VMARGS=()
if [[ -n "${DEBUG_JVM_PORT}" ]]; then
  SUSPEND_FLAG="n"
  if [[ "${DEBUG_JVM_SUSPEND}" -eq 1 ]]; then
    SUSPEND_FLAG="y"
  fi
  TEST_VMARGS=(-vmargs "-agentlib:jdwp=transport=dt_socket,server=y,suspend=${SUSPEND_FLAG},address=*:${DEBUG_JVM_PORT}")
fi
timeout "${TIMEOUT_MIN}m" "${CAPELLA_BIN}" \
  -nosplash \
  -consoleLog \
  -application "${APP_ID}" \
  -port "${PORT}" \
  -testpluginname "${PLUGIN}" \
  -classname "${CLASS_NAME}" \
  -data "${TEST_WS}" \
  -clean \
  "${TEST_VMARGS[@]}" \
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
EXECUTION_ISSUE=""
EXECUTION_HINT=""
if [[ -f "${XML_FILE}" ]]; then
  read -r XML_FAILURES XML_ERRORS < <(read_junit_failures_errors "${XML_FILE}")
  if [[ "${XML_FAILURES}" -gt 0 || "${XML_ERRORS}" -gt 0 ]]; then
    STATUS="FAIL"
    if [[ "${RC}" -eq 0 ]]; then
      RC=1
    fi
  fi
  if ! grep -q '<testcase ' "${XML_FILE}"; then
    EXECUTION_ISSUE="No testcase was recorded in ${XML_FILE}"
  fi
else
  echo "[WARN ] JUnit XML not found: ${XML_FILE}"
  EXECUTION_ISSUE="JUnit XML not found"
fi

if grep -Eq "Class not found ${CLASS_NAME}|ClassNotFoundException: ${CLASS_NAME}" "${LOG_FILE}"; then
  EXECUTION_ISSUE="Test class could not be loaded"
  REPO_PLUGIN_JAR="$(find "${TEST_SITE_REPO}/plugins" -maxdepth 1 -type f -name "${PLUGIN}_*.jar" | sort | tail -n 1 || true)"
  LOCAL_PLUGIN_JAR="$(find "tests/plugins/${PLUGIN}/target" -maxdepth 1 -type f -name "${PLUGIN}-*.jar" | sort | tail -n 1 || true)"
  if [[ -n "${REPO_PLUGIN_JAR}" ]]; then
    REPO_HAS_CLASS="$(jar_contains_class "${REPO_PLUGIN_JAR}" "${CLASS_NAME}")"
  else
    REPO_HAS_CLASS="missing"
  fi
  if [[ -n "${LOCAL_PLUGIN_JAR}" ]]; then
    LOCAL_HAS_CLASS="$(jar_contains_class "${LOCAL_PLUGIN_JAR}" "${CLASS_NAME}")"
  else
    LOCAL_HAS_CLASS="missing"
  fi

  if [[ "${REPO_HAS_CLASS}" == "no" && "${LOCAL_HAS_CLASS}" == "yes" ]]; then
    EXECUTION_HINT="Published test repository is stale for ${PLUGIN}; rerun the full rebuild so ${TEST_SITE_REPO} includes ${CLASS_NAME}."
  elif [[ "${REPO_HAS_CLASS}" == "no" ]]; then
    EXECUTION_HINT="Published test repository for ${PLUGIN} does not contain ${CLASS_NAME}."
  fi
fi

if [[ -n "${EXECUTION_ISSUE}" ]]; then
  STATUS="FAIL"
  if [[ "${RC}" -eq 0 ]]; then
    RC=1
  fi
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
echo "Runtime jar  : ${INSTALLED_PLUGIN_JAR:-MISSING}"
echo "Runtime sha  : ${INSTALLED_PLUGIN_SHA}"
echo "Runtime class: ${INSTALLED_PLUGIN_HAS_CLASS}"
echo "Test-site jar: ${REPO_PLUGIN_JAR:-MISSING}"
echo "Test-site sha: ${REPO_PLUGIN_SHA}"
echo "Test-site cls: ${REPO_PLUGIN_HAS_CLASS}"
echo "Artifact sync: ${RUNTIME_MATCH_STATUS}"
if [[ -n "${DEBUG_JVM_PORT}" ]]; then
  echo "JDWP port    : ${DEBUG_JVM_PORT}"
  echo "JDWP suspend : $([[ \"${DEBUG_JVM_SUSPEND}\" -eq 1 ]] && echo yes || echo no)"
fi
echo "XML failures : ${XML_FAILURES}"
echo "XML errors   : ${XML_ERRORS}"
if [[ -n "${EXECUTION_ISSUE}" ]]; then
  echo "Execution    : ${EXECUTION_ISSUE}"
fi
if [[ -n "${EXECUTION_HINT}" ]]; then
  echo "Hint         : ${EXECUTION_HINT}"
fi
echo "Xvnc log     : ${XVNC_LOG}"
echo "============================================================"
echo "Quick inspection commands:"
echo "  tail -n 200 ${LOG_FILE}"
echo "  tail -n 200 ${LISTENER_LOG}"
if command -v rg >/dev/null 2>&1; then
  echo "  rg -n \"FAIL|ERROR|Exception\" ${RESULT_DIR}/*.log"
else
  echo "  grep -nE \"FAIL|ERROR|Exception\" ${RESULT_DIR}/*.log"
fi

if [[ "${RC}" -ne 0 ]]; then
  exit "${RC}"
fi

exit 0
