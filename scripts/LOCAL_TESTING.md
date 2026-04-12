# Local Testing Guide

This repository has a few different local test workflows. The right script depends on whether you want to:

- run the UI suite on the host,
- run the same suite inside an Ubuntu Docker image,
- iterate quickly on one testcase,
- or launch a test from Eclipse while reusing the Ubuntu Docker X server.

## 1. Build the local test artifacts once

Most workflows below expect these artifacts to exist:

- a Linux product tarball,
- the Capella test update-site.

Prepare them with:

```bash
scripts/prepare-product-jres.sh --java-major 21
mvn -B -V verify -Pfull -DskipTests -Dcyclonedx.skip=true
```

If you need a completely fresh rebuild:

```bash
scripts/prepare-product-jres.sh --java-major 21 --clean
mvn -B -V clean verify -Pfull -DskipTests -Dcyclonedx.skip=true
```

## 2. Choose the right script

### Run the local UI suite on your host

Use [scripts/run-ui-tests-local.sh](/home/cedric/src/capella-cbrun/capella/scripts/run-ui-tests-local.sh:22).

Focused failures:

```bash
scripts/run-ui-tests-local.sh --scope focused-failures
```

Full suite:

```bash
scripts/run-ui-tests-local.sh --scope full
```

Open a VNC viewer automatically:

```bash
scripts/run-ui-tests-local.sh --scope focused-failures --watch
```

Useful options:

- `--display <N>` changes the X/VNC display number. `29` maps to `vncviewer localhost:29`.
- `--timeout-min <N>` changes the per-suite timeout.
- `--product-tar <path>` and `--test-site-repo <path>` let you point to non-default artifacts.

Output locations:

- `runtime/ui-tests-local`
- `test-results/ui-tests-local`
- `test-workspaces/ui-tests-local`

### Run the UI suite inside Ubuntu Docker

Use [scripts/run-ui-tests-ubuntu2404.sh](/home/cedric/src/capella-cbrun/capella/scripts/run-ui-tests-ubuntu2404.sh:46).

Focused failures:

```bash
scripts/run-ui-tests-ubuntu2404.sh -- --scope focused-failures --timeout-min 60
```

Full suite:

```bash
scripts/run-ui-tests-ubuntu2404.sh -- --scope full --timeout-min 60
```

Monitor the container display with:

```bash
vncviewer localhost:29
```

Notes:

- Forwarded test options go after `--`.
- The wrapper publishes VNC on `5900 + display`, so display `29` uses TCP `5929`.
- If you need a different display, pass it through:

```bash
scripts/run-ui-tests-ubuntu2404.sh -- --display 30 --scope focused-failures
vncviewer localhost:30
```

The Docker wrapper now stops stale Docker containers that already own the VNC port before starting. If the port is still busy afterwards, check for a non-Docker listener with:

```bash
ss -ltnp '( sport = :5929 )'
```

### Iterate quickly on one testcase

Use [scripts/prepare-single-test-loop.sh](/home/cedric/src/capella-cbrun/capella/scripts/prepare-single-test-loop.sh:14) once, then [scripts/run-single-test-loop.sh](/home/cedric/src/capella-cbrun/capella/scripts/run-single-test-loop.sh:29) for reruns.

Prepare the cached runtime:

```bash
scripts/prepare-single-test-loop.sh
```

Run one UI testcase:

```bash
scripts/run-single-test-loop.sh \
  --plugin org.polarsys.capella.test.platform.ju \
  --class org.polarsys.capella.test.platform.ju.testcases.LicenceTest \
  --ui
```

Run one UI testcase and watch it:

```bash
scripts/run-single-test-loop.sh \
  --plugin org.polarsys.capella.test.platform.ju \
  --class org.polarsys.capella.test.platform.ju.testcases.LicenceTest \
  --ui \
  --watch
```

Fast rerun without rebuilding:

```bash
scripts/run-single-test-loop.sh \
  --plugin org.polarsys.capella.test.platform.ju \
  --class org.polarsys.capella.test.platform.ju.testcases.LicenceTest \
  --ui \
  --no-build
```

Useful options:

- `--debug-jvm-port <N>` enables JDWP on the PDE test JVM.
- `--debug-jvm-suspend` starts that JVM suspended.
- `--display <N>` changes the X/VNC display number.

Output locations:

- `runtime/single-test-loop`
- `test-results/single-test/latest`
- `test-workspaces/single-test/latest`

### Launch from Eclipse, but draw on the Ubuntu Docker display

Use [scripts/start-ui-parity-xserver-ubuntu2404.sh](/home/cedric/src/capella-cbrun/capella/scripts/start-ui-parity-xserver-ubuntu2404.sh:135).

Start the Ubuntu parity X server:

```bash
scripts/start-ui-parity-xserver-ubuntu2404.sh --watch
```

Then set this environment variable in your Eclipse launch:

```bash
DISPLAY=127.0.0.1:29.0
```

This workflow is for host-launched tests that should render on the container-managed Ubuntu display. It does not run the test JVM inside Docker.

## 3. Recommended workflows

For most changes:

1. Build artifacts once.
2. Run `scripts/run-ui-tests-local.sh --scope focused-failures`.
3. If the problem looks environment-specific, rerun with `scripts/run-ui-tests-ubuntu2404.sh`.

For debugging one testcase:

1. Build artifacts once.
2. Run `scripts/prepare-single-test-loop.sh`.
3. Iterate with `scripts/run-single-test-loop.sh --no-build`.

For diagnosing display or font differences between host and Ubuntu:

1. Start `scripts/start-ui-parity-xserver-ubuntu2404.sh`.
2. Launch the test from Eclipse with `DISPLAY=127.0.0.1:<display>.0`.

## 4. Troubleshooting

### VNC port already allocated

Use a different display:

```bash
scripts/run-ui-tests-ubuntu2404.sh -- --display 30 --scope focused-failures
vncviewer localhost:30
```

Or inspect the current listener:

```bash
ss -ltnp '( sport = :5929 )'
docker ps --filter publish=5929
```

### Root-owned old test caches break a run

`scripts/run-ui-tests-local.sh` now uses dedicated local directories under:

- `runtime/ui-tests-local`
- `test-results/ui-tests-local`
- `test-workspaces/ui-tests-local`

so it should no longer fail because of unrelated old caches left by other workflows.

### Inspect failures quickly

For suite runs:

```bash
rg -n "FAIL|ERROR|Exception" test-results/ui-tests-local/*.log
tail -n 200 test-results/ui-tests-local/xvnc.log
```

For single-test runs:

```bash
eza -la test-results/single-test/latest
rg -n "FAIL|ERROR|Exception" test-results/single-test/latest/*.log
tail -n 200 test-results/single-test/latest/xvnc.log
```
