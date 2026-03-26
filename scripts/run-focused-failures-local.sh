#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

NO_BUILD=0
DISPLAY_NUM=29
WATCH=0
VNC_NO_AUTH=0
TIMEOUT_MIN=20

usage() {
  cat <<'EOF'
Usage: scripts/run-focused-failures-local.sh [options] [--only <fqcn> ...]

Run the current focused failing testcases without launching the full suite.
By default it runs these classes:
  - org.polarsys.capella.test.platform.ju.testcases.InvalidPreferencesInitializer
  - org.polarsys.capella.test.migration.ju.testcases.basic.SysmodelMigrationLayout
  - org.polarsys.capella.test.navigator.ju.DefaultLayout
  - org.polarsys.capella.test.navigator.ju.CreateElement
  - org.polarsys.capella.test.transition.ju.testcases.options.IncrementalModeTest

Options:
  --only <fqcn>         Restrict execution to one class (repeatable)
  --no-build            Skip rebuild of test site for all runs
  --display <N>         X display number passed to run-single-test-loop (default: 29)
  --watch               Open local VNC viewer while running UI tests
  --vnc-no-auth         Start Xvnc with SecurityTypes=None (localhost only)
  --timeout-min <N>     Per-test timeout in minutes (default: 20)
  -h, --help            Show this help
EOF
}

declare -a ONLY_CLASSES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      ONLY_CLASSES+=("$2")
      shift 2
      ;;
    --no-build)
      NO_BUILD=1
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

declare -A TEST_PLUGIN=(
  ["org.polarsys.capella.test.platform.ju.testcases.InvalidPreferencesInitializer"]="org.polarsys.capella.test.platform.ju"
  ["org.polarsys.capella.test.migration.ju.testcases.basic.SysmodelMigrationLayout"]="org.polarsys.capella.test.suites.ju"
  ["org.polarsys.capella.test.navigator.ju.DefaultLayout"]="org.polarsys.capella.test.suites.ju"
  ["org.polarsys.capella.test.navigator.ju.CreateElement"]="org.polarsys.capella.test.suites.ju"
  ["org.polarsys.capella.test.transition.ju.testcases.options.IncrementalModeTest"]="org.polarsys.capella.test.suites.ju"
)

declare -A TEST_MODE=(
  ["org.polarsys.capella.test.platform.ju.testcases.InvalidPreferencesInitializer"]="ui"
  ["org.polarsys.capella.test.migration.ju.testcases.basic.SysmodelMigrationLayout"]="ui"
  ["org.polarsys.capella.test.navigator.ju.DefaultLayout"]="ui"
  ["org.polarsys.capella.test.navigator.ju.CreateElement"]="ui"
  ["org.polarsys.capella.test.transition.ju.testcases.options.IncrementalModeTest"]="ui"
)

declare -a TEST_CLASSES=(
  "org.polarsys.capella.test.platform.ju.testcases.InvalidPreferencesInitializer"
  "org.polarsys.capella.test.migration.ju.testcases.basic.SysmodelMigrationLayout"
  "org.polarsys.capella.test.navigator.ju.DefaultLayout"
  "org.polarsys.capella.test.navigator.ju.CreateElement"
  "org.polarsys.capella.test.transition.ju.testcases.options.IncrementalModeTest"
)

if [[ ${#ONLY_CLASSES[@]} -gt 0 ]]; then
  TEST_CLASSES=("${ONLY_CLASSES[@]}")
fi

for class_name in "${TEST_CLASSES[@]}"; do
  if [[ -z "${TEST_PLUGIN[$class_name]:-}" ]]; then
    echo "Unsupported class in --only: ${class_name}"
    echo "Known classes:"
    printf '  - %s\n' "${!TEST_PLUGIN[@]}" | sort
    exit 2
  fi
done

declare -a PASSED=()
declare -a FAILED=()

for i in "${!TEST_CLASSES[@]}"; do
  class_name="${TEST_CLASSES[$i]}"
  plugin="${TEST_PLUGIN[$class_name]}"
  mode="${TEST_MODE[$class_name]}"

  cmd=(scripts/run-single-test-loop.sh
    --plugin "${plugin}"
    --class "${class_name}"
    --display "${DISPLAY_NUM}"
    --timeout-min "${TIMEOUT_MIN}"
  )
  if [[ "${mode}" == "ui" ]]; then
    cmd+=(--ui)
  fi
  if [[ "${WATCH}" -eq 1 ]]; then
    cmd+=(--watch)
  fi
  if [[ "${VNC_NO_AUTH}" -eq 1 ]]; then
    cmd+=(--vnc-no-auth)
  fi
  if [[ "${NO_BUILD}" -eq 1 || "${i}" -gt 0 ]]; then
    cmd+=(--no-build)
  fi

  echo
  echo "================================================================"
  echo "Running ${class_name}"
  echo "Plugin: ${plugin} | Mode: ${mode}"
  echo "Command: ${cmd[*]}"
  echo "================================================================"

  if "${cmd[@]}"; then
    PASSED+=("${class_name}")
  else
    FAILED+=("${class_name}")
  fi
done

echo
echo "================ Focused Failures Summary ================"
echo "Passed: ${#PASSED[@]}"
for c in "${PASSED[@]}"; do
  echo "  [PASS] ${c}"
done
echo "Failed: ${#FAILED[@]}"
for c in "${FAILED[@]}"; do
  echo "  [FAIL] ${c}"
done
echo "=========================================================="

if [[ "${#FAILED[@]}" -gt 0 ]]; then
  exit 1
fi
