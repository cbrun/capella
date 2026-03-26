#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

DISPLAY_NUM=99
WATCH=0
SMOKE=0
TIMEOUT_MIN=60
VNC_NO_AUTH=0
PRODUCT_TAR=""
TEST_SITE_REPO=""
RUNTIME_DIR="${REPO_ROOT}/runtime"
RESULT_DIR="${REPO_ROOT}/test-results"
WORK_BASE="${REPO_ROOT}/test-workspaces"
SAMPLES_GUARD_ENABLED=0
SAMPLES_WAS_CLEAN=0

usage() {
  cat <<'EOF'
Usage: scripts/run-ui-tests-local.sh [options]

Run Capella UI/non-UI test suites locally on an isolated Xvnc display
to match the GitHub self-hosted workflow behavior.

Options:
  --display <N>           X display number (default: 99)
  --watch                 Open local VNC viewer on the isolated display
  --smoke                 Run a reduced subset instead of the full suite
  --vnc-no-auth           Start Xvnc with SecurityTypes=None (localhost only)
  --timeout-min <N>       Per-suite timeout in minutes (default: 60)
  --product-tar <path>    Override Linux product tarball path
  --test-site-repo <path> Override test update-site repository path
  -h, --help              Show this help

Expected build outputs (default resolution):
  releng/plugins/org.polarsys.capella.rcp.product/target/products/capella-*-linux-gtk-x86_64.tar.gz
  releng/plugins/org.polarsys.capella.test.site/target/repository
EOF
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --display)
      DISPLAY_NUM="$2"
      shift 2
      ;;
    --watch)
      WATCH=1
      shift
      ;;
    --smoke)
      SMOKE=1
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

for cmd in Xvnc tar timeout; do
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

[[ -f "${PRODUCT_TAR}" ]] || {
  echo "Linux product tarball not found."
  echo "Expected pattern: releng/plugins/org.polarsys.capella.rcp.product/target/products/capella-*-linux-gtk-x86_64.tar.gz"
  echo
  echo "Build command to produce archives:"
  echo "  mvn -B -V verify -Pfull"
  echo
  echo "If you need a clean rebuild first:"
  echo "  mvn -B -V clean verify -Pfull"
  exit 2
}

[[ -d "${TEST_SITE_REPO}" ]] || {
  echo "Test update-site repository not found: ${TEST_SITE_REPO}"
  exit 2
}

snapshot_samples_state

echo "== Environment =="
echo "Repo root: ${REPO_ROOT}"
echo "Product tar: ${PRODUCT_TAR}"
echo "Test repo  : ${TEST_SITE_REPO}"
echo "Display    : :${DISPLAY_NUM} (isolated from your desktop)"
echo "Smoke mode : ${SMOKE}"
echo "Timeout    : ${TIMEOUT_MIN} minutes per suite"
echo "VNC no auth: ${VNC_NO_AUTH}"
echo

rm -rf "${RUNTIME_DIR}" "${RESULT_DIR}" "${WORK_BASE}"
mkdir -p "${RUNTIME_DIR}" "${RESULT_DIR}" "${WORK_BASE}"

echo "== Unpack product =="
tar -xzf "${PRODUCT_TAR}" -C "${RUNTIME_DIR}"
CAPELLA_HOME="${RUNTIME_DIR}/capella"
CAPELLA_BIN="${CAPELLA_HOME}/capella"
[[ -x "${CAPELLA_BIN}" ]] || {
  echo "Capella binary not found after unpack: ${CAPELLA_BIN}"
  exit 2
}

echo "== Install Capella test feature =="
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

echo "== Start isolated Xvnc =="
XVNC_LOG="${RESULT_DIR}/xvnc.log"
XVNC_ARGS=( ":${DISPLAY_NUM}" -geometry 1920x1080 -depth 24 -nolisten tcp -localhost )
if [[ "${VNC_NO_AUTH}" -eq 1 ]]; then
  XVNC_ARGS+=( -SecurityTypes None )
fi
Xvnc "${XVNC_ARGS[@]}" >"${XVNC_LOG}" 2>&1 &
XVNC_PID=$!
VIEWER_PID=""
cleanup() {
  cleanup_samples_changes
  if [[ -n "${VIEWER_PID}" ]]; then
    kill "${VIEWER_PID}" >/dev/null 2>&1 || true
  fi
  kill "${XVNC_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
export DISPLAY=":${DISPLAY_NUM}"
sleep 3

echo "Monitor instructions:"
echo "  1) Open a new terminal"
echo "  2) Connect with: vncviewer localhost:${DISPLAY_NUM}"
if [[ "${VNC_NO_AUTH}" -eq 1 ]]; then
  echo "     (No password required; connection is localhost-only)"
else
  echo "     (Password/auth may be requested by your local TigerVNC defaults)"
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

declare -a PASSED=()
declare -a FAILED=()
declare -a TIMED_OUT=()
PORT_BASE=25000
CASE_INDEX=0

run_case() {
  local mode="$1"
  local bucket="$2"
  local plugin="$3"
  local class_name="$4"

  local app_id="org.eclipse.pde.junit.runtime.uitestapplication"
  if [[ "${mode}" == "nonui" ]]; then
    app_id="org.eclipse.pde.junit.runtime.coretestapplication"
  fi

  local workdir="${WORK_BASE}/${bucket}"
  local logfile="${RESULT_DIR}/${bucket}__${class_name}.log"
  local listener_log="${RESULT_DIR}/${bucket}__${class_name}__listener.log"
  local listener_ws="${WORK_BASE}/listener-${bucket}-${CASE_INDEX}"
  local port=$((PORT_BASE + CASE_INDEX))
  CASE_INDEX=$((CASE_INDEX + 1))
  mkdir -p "${workdir}"
  mkdir -p "${listener_ws}"

  echo "[START] ${bucket} :: ${class_name}"

  "${CAPELLA_BIN}" \
    -nosplash \
    -consoleLog \
    -data "${listener_ws}" \
    -application org.polarsys.capella.test.run.application \
    -port "${port}" \
    -title "${bucket} :: ${class_name}" \
    >"${listener_log}" 2>&1 &
  local listener_pid=$!
  sleep 2
  if ! kill -0 "${listener_pid}" >/dev/null 2>&1; then
    echo "[FAIL ] ${bucket} :: ${class_name} (listener did not start)"
    FAILED+=("${bucket}|${plugin}|${class_name}|${logfile}|listener-start-failure")
    return
  fi

  set +e
  timeout "${TIMEOUT_MIN}m" "${CAPELLA_BIN}" \
    -nosplash \
    -consoleLog \
    -application "${app_id}" \
    -port "${port}" \
    -testpluginname "${plugin}" \
    -classname "${class_name}" \
    -data "${workdir}" \
    -clean \
    >"${logfile}" 2>&1
  local rc=$?
  set -e
  kill "${listener_pid}" >/dev/null 2>&1 || true

  if [[ ${rc} -eq 0 ]]; then
    echo "[PASS ] ${bucket} :: ${class_name}"
    PASSED+=("${bucket}|${plugin}|${class_name}|${logfile}|${listener_log}")
  elif [[ ${rc} -eq 124 ]]; then
    echo "[TIME ] ${bucket} :: ${class_name}"
    TIMED_OUT+=("${bucket}|${plugin}|${class_name}|${logfile}|${listener_log}")
  else
    echo "[FAIL ] ${bucket} :: ${class_name} (exit=${rc})"
    FAILED+=("${bucket}|${plugin}|${class_name}|${logfile}|${rc}|${listener_log}")
  fi
}

run_suite_set() {
  local mode="$1"
  local bucket="$2"
  local plugin="$3"
  local class_name="$4"
  run_case "${mode}" "${bucket}" "${plugin}" "${class_name}"
}

if [[ "${SMOKE}" -eq 1 ]]; then
  run_suite_set ui ModelQueriesValidation org.polarsys.capella.test.suites.ju org.polarsys.capella.test.business.queries.ju.testSuites.main.BusinessQueryTestSuite
  run_suite_set ui Views org.polarsys.capella.test.suites.ju org.polarsys.capella.test.model.ju.testsuites.main.ModelTestSuite
  run_suite_set nonui NotUINavigator org.polarsys.capella.test.suites.ju org.polarsys.capella.test.navigator.ju.testsuites.main.NavigatorTestSuite
else
  run_suite_set ui ModelQueriesValidation org.polarsys.capella.test.suites.ju org.polarsys.capella.test.business.queries.ju.testSuites.main.BusinessQueryTestSuite
  run_suite_set ui ModelQueriesValidation org.polarsys.capella.test.suites.ju org.polarsys.capella.test.semantic.queries.ju.testsuites.SemanticQueriesTestSuite
  run_suite_set ui ModelQueriesValidation org.polarsys.capella.test.suites.ju org.polarsys.capella.test.validation.rules.ju.testsuites.main.ValidationRulesTestSuite
  run_suite_set ui LibRecTransition org.polarsys.capella.test.suites.ju org.polarsys.capella.test.libraries.ju.testsuites.main.LibrariesTestSuite
  run_suite_set ui LibRecTransition org.polarsys.capella.test.suites.ju org.polarsys.capella.test.libraries.ui.ju.testsuites.main.LibrariesUITestSuite
  run_suite_set ui LibRecTransition org.polarsys.capella.test.suites.ju org.polarsys.capella.test.recrpl.ju.testsuites.main.RecRplTestSuite
  run_suite_set ui LibRecTransition org.polarsys.capella.test.suites.ju org.polarsys.capella.test.transition.ju.testsuites.main.TransitionTestSuite
  run_suite_set ui LibRecTransition org.polarsys.capella.test.suites.ju org.polarsys.capella.test.re.updateconnections.ju.UpdateConnectionsTestSuite
  run_suite_set ui DiagramTools1 org.polarsys.capella.test.suites.ju org.polarsys.capella.test.diagram.tools.ju.testsuites.main.DiagramToolsStep1TestSuite
  run_suite_set ui DiagramTools2 org.polarsys.capella.test.suites.ju org.polarsys.capella.test.diagram.tools.ju.testsuites.main.DiagramToolsStep2TestSuite
  run_suite_set ui DiagramMiscFilters org.polarsys.capella.test.suites.ju org.polarsys.capella.test.diagram.misc.ju.testsuites.DiagramMiscTestSuite
  run_suite_set ui DiagramMiscFilters org.polarsys.capella.test.suites.ju org.polarsys.capella.test.diagram.filters.ju.testsuites.DiagramFiltersTestSuite
  run_suite_set ui DiagramMiscFilters org.polarsys.capella.test.suites.ju org.polarsys.capella.test.table.ju.testsuite.TableTestSuite
  run_suite_set ui Fragmentation org.polarsys.capella.test.suites.ju org.polarsys.capella.test.fragmentation.ju.testsuites.FragmentationTestSuite
  run_suite_set ui Odesign org.polarsys.capella.test.suites.ju org.polarsys.capella.test.odesign.ju.maintestsuite.ODesignTestSuite
  run_suite_set ui Views org.polarsys.capella.test.suites.ju org.polarsys.capella.test.model.ju.testsuites.main.ModelTestSuite
  run_suite_set ui Views org.polarsys.capella.test.suites.ju org.polarsys.capella.test.massactions.ju.testsuites.MassActionsTestSuite
  run_suite_set ui Views org.polarsys.capella.test.suites.ju org.polarsys.capella.test.platform.ju.testsuites.PlatformTestSuite
  run_suite_set ui Views org.polarsys.capella.test.suites.ju org.polarsys.capella.test.richtext.ju.testsuites.RichtextTestSuite
  run_suite_set ui Views org.polarsys.capella.test.suites.ju org.polarsys.capella.test.fastlinker.ju.testsuites.FastLinkerTestsSuite
  run_suite_set ui Views org.polarsys.capella.test.suites.ju org.polarsys.capella.test.explorer.activity.ju.testsuites.ActivityExplorerTestsSuite
  run_suite_set ui Views org.polarsys.capella.test.suites.ju org.polarsys.capella.test.progressmonitoring.ju.testsuites.SetProgressTestSuite
  run_suite_set ui Views org.polarsys.capella.test.suites.ju org.polarsys.capella.test.navigator.ju.testsuites.main.NavigatorUITestSuite
  run_suite_set ui Views org.polarsys.capella.test.suites.ju org.polarsys.capella.test.semantic.ui.ju.testsuites.SemanticUITestSuite
  run_suite_set ui MigrationCommandLine org.polarsys.capella.test.suites.ju org.polarsys.capella.test.migration.ju.testsuites.main.MigrationTestSuite
  run_suite_set ui MigrationCommandLine org.polarsys.capella.test.suites.ju org.polarsys.capella.test.diagram.layout.ju.testsuites.LayoutTestSuite
  run_suite_set ui MigrationCommandLine org.polarsys.capella.test.suites.ju org.polarsys.capella.test.commandline.ju.testsuites.CommandLineTestSuite
  run_suite_set ui Benchmark org.polarsys.capella.test.suites.ju org.polarsys.capella.test.benchmarks.ju.suites.AllBenchmarksTestSuite
  run_suite_set ui Detach org.polarsys.capella.test.suites.ju org.polarsys.capella.test.model.ju.testsuites.partial.DetachTestSuite
  run_suite_set ui Documentation org.polarsys.capella.test.doc.ju org.polarsys.capella.test.doc.ju.testsuites.DocTestSuite
  run_suite_set nonui NotUINavigator org.polarsys.capella.test.suites.ju org.polarsys.capella.test.navigator.ju.testsuites.main.NavigatorTestSuite
fi

total=$(( ${#PASSED[@]} + ${#FAILED[@]} + ${#TIMED_OUT[@]} ))

echo
echo "============================================================"
echo "UI TEST SUMMARY"
echo "============================================================"
echo "Total suites executed : ${total}"
echo "Passed               : ${#PASSED[@]}"
echo "Failed               : ${#FAILED[@]}"
echo "Timed out            : ${#TIMED_OUT[@]}"
echo "Logs directory       : ${RESULT_DIR}"
echo "Xvnc log             : ${XVNC_LOG}"
echo "============================================================"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo
  echo "Failed suites:"
  for entry in "${FAILED[@]}"; do
    IFS='|' read -r bucket plugin class_name logfile rc listener_log <<<"${entry}"
    echo "  - ${bucket} :: ${class_name} (plugin=${plugin}, exit=${rc})"
    echo "    test log    : ${logfile}"
    echo "    listener log: ${listener_log}"
  done
fi

if [[ ${#TIMED_OUT[@]} -gt 0 ]]; then
  echo
  echo "Timed-out suites:"
  for entry in "${TIMED_OUT[@]}"; do
    IFS='|' read -r bucket plugin class_name logfile listener_log <<<"${entry}"
    echo "  - ${bucket} :: ${class_name}"
    echo "    test log    : ${logfile}"
    echo "    listener log: ${listener_log}"
  done
fi

echo
echo "Quick inspection commands:"
echo "  ls -1 ${RESULT_DIR}"
echo "  tail -n 200 ${XVNC_LOG}"
echo "  rg -n \"FAIL|ERROR|Exception\" ${RESULT_DIR}/*.log"

if [[ ${#FAILED[@]} -gt 0 || ${#TIMED_OUT[@]} -gt 0 ]]; then
  exit 1
fi

exit 0
