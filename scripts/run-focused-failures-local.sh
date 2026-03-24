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
MAXIMIZE_WORKBENCH=0
LEGACY_DESKTOP_SETUP=0
EXPLICIT_PLUGIN=""
EXPLICIT_MODE=""

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
  --plugin <id>         Plugin id to use for custom --only classes
  --ui                  Run custom --only classes in UI mode
  --non-ui              Run custom --only classes in non-UI mode
  --no-build            Skip rebuild of test site for all runs
  --display <N>         X display number passed to run-single-test-loop (default: 29)
  --watch               Open local VNC viewer while running UI tests
  --vnc-no-auth         Start Xvnc with SecurityTypes=None (localhost only)
  --maximize-workbench  Start metacity and maximize workbench windows during UI runs
  --legacy-desktop-setup  Apply xrandr/xsetroot/vncconfig/xhost/metacity setup during UI runs
  --timeout-min <N>     Per-test timeout in minutes (default: 20)
  -h, --help            Show this help

Examples:
  Default focused set, rebuilding once:
    scripts/run-focused-failures-local.sh

  Fast rerun of one known testcase:
    scripts/run-focused-failures-local.sh \
      --only org.polarsys.capella.test.navigator.ju.DefaultLayout \
      --no-build

  Arbitrary UI testcase after a full no-tests rebuild:
    scripts/run-focused-failures-local.sh \
      --only org.polarsys.capella.test.platform.ju.testcases.UIEnvironmentFingerprintTest \
      --plugin org.polarsys.capella.test.platform.ju \
      --ui --no-build
EOF
}

declare -a ONLY_CLASSES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      ONLY_CLASSES+=("$2")
      shift 2
      ;;
    --plugin)
      EXPLICIT_PLUGIN="$2"
      shift 2
      ;;
    --ui)
      EXPLICIT_MODE="ui"
      shift
      ;;
    --non-ui)
      EXPLICIT_MODE="non-ui"
      shift
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
    --maximize-workbench)
      MAXIMIZE_WORKBENCH=1
      shift
      ;;
    --legacy-desktop-setup)
      LEGACY_DESKTOP_SETUP=1
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
    if [[ -z "${EXPLICIT_PLUGIN}" || -z "${EXPLICIT_MODE}" ]]; then
      echo "Unsupported class in --only: ${class_name}"
      echo "For custom classes, provide both --plugin and --ui/--non-ui."
      echo "Known classes:"
      printf '  - %s\n' "${!TEST_PLUGIN[@]}" | sort
      exit 2
    fi
  fi
done

if [[ ${#ONLY_CLASSES[@]} -eq 0 ]] && [[ -n "${EXPLICIT_PLUGIN}${EXPLICIT_MODE}" ]]; then
  echo "--plugin and --ui/--non-ui are only valid together with --only."
  exit 2
fi

for class_name in "${TEST_CLASSES[@]}"; do
  if [[ -z "${TEST_PLUGIN[$class_name]:-}" ]]; then
    TEST_PLUGIN["$class_name"]="${EXPLICIT_PLUGIN}"
    TEST_MODE["$class_name"]="${EXPLICIT_MODE}"
  fi
  if [[ -z "${TEST_PLUGIN[$class_name]:-}" || -z "${TEST_MODE[$class_name]:-}" ]]; then
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
  if [[ "${MAXIMIZE_WORKBENCH}" -eq 1 ]]; then
    cmd+=(--maximize-workbench)
  fi
  if [[ "${LEGACY_DESKTOP_SETUP}" -eq 1 ]]; then
    cmd+=(--legacy-desktop-setup)
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
