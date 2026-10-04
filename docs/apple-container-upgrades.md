# Upgrade Apple container and verify agentctl compatibility

Run this workflow in the macOS host checkout. Apple `container` is the host
runtime used by agentctl; upgrading it is separate from `agentctl upgrade`, which
recreates a managed container. Change both the CLI and API server, then require a
complete passing compatibility report before accepting a candidate.

Use 1.3.1 as the known-good baseline for this comparison. The candidate versions
below are examples, not an unconditional support declaration. A failed or
interrupted run does not certify a version, even if an isolated retry passes.
See [TESTING.md](../TESTING.md#apple-container-compatibility-and-regression-suite)
for prerequisites, contracts, deadlines, and report contents.

## Switch versioned Homebrew installations

Use a custom Homebrew tap with separate `container@1.3.1`, `container@1.4.1`,
and `container@1.5.0` formulae. This keeps the baseline and candidates installed
independently so compatibility testing can switch between them repeatedly.
Ensure Homebrew's binary directory precedes any separate `/usr/local/bin/container`
installation in `PATH`.

For a custom tap, replace `OWNER/TAP` below with its actual identifier:

```bash
brew tap OWNER/TAP &&
brew install OWNER/TAP/container@1.3.1 \
  OWNER/TAP/container@1.4.1 OWNER/TAP/container@1.5.0
```

The tap should define independently versioned formulae, pin each upstream
release and checksum, and preserve its complete signed executable/plugin layout.
Its CLI wrapper must select that formula's install root when starting services.
When adding a candidate release, add its versioned formula to the tap and install
it alongside the baseline. Extend the switching function below before running
the compatibility suite. Keep baseline formulae available for rollback.

Add this function to your host shell configuration, or paste it into the current
terminal. It follows the existing `container-version` workflow, but checks the
requested formula before stopping services and stops on service shutdown errors.
Stopping the service interrupts running containers; finish active agent sessions
and suite runs first.

```bash
container-version() {
  local version="${1:-}" formula cli_info
  [ -n "$version" ] || { echo 'Usage: container-version VERSION' >&2; return 1; }
  brew --prefix --installed "container@$version" >/dev/null || return 1
  container system stop || return 1

  for formula in container@1.3.1 container@1.4.1 container@1.5.0; do
    brew unlink "$formula" >/dev/null 2>&1 || true
  done
  brew link --overwrite --force "container@$version" || return 1
  hash -r

  cli_info="$(container --version)" || return 1
  printf '%s\n' "$cli_info"
  case "$cli_info" in
    *"version $version "*) ;;
    *) echo 'Unexpected CLI version; check PATH before starting services' >&2; return 1 ;;
  esac
  container system start || return 1
  container system status
}
```

`--force` permits linking keg-only versioned formulae. If linking or CLI
validation fails, the API server remains stopped: correct the formula or `PATH`,
then rerun the function with the intended version. Do not continue the test chain
until CLI and API server versions match.

Extend the unlink list when installing another version. To switch and inspect the
active pair:

```bash
container-version 1.3.1
container --version
container system status
container system version --format json
```

The suite rejects a stopped server, unknown versions, and mismatched CLI/server
versions. Selecting another CLI with `CONTAINER_CMD` alone does not replace the
running API server.

## Prepare reusable baseline assets

Prepare once with matching 1.3.1 CLI/server versions:

```bash
container-version 1.3.1 &&
bash tests/run-container-compat-tests.sh --prepare \
  --assets-dir "$HOME/.cache/agentctl-container-compat/assets-1.3.1"
```

Skip this step when that assets directory already has a valid prepared fixture.
Reuse the same baseline assets for every candidate. Reprepare into a new directory
only when the preparation recipe or host architecture changes, or assets fail
validation. A runtime switch by itself does not require new assets.

## Test one upgrade

First run the complete baseline suite. Only after it passes, preserve dedicated
running and stopped fixtures, switch versions, and verify them. The verification
phase also runs the complete fresh-container suite on the candidate.

Paste this into the host terminal where `container-version` is defined:

```bash
compat_assets="$HOME/.cache/agentctl-container-compat/assets-1.3.1"
compat_transition="$HOME/.cache/agentctl-container-compat/upgrade-1.3.1-to-1.5.0-$(date +%Y%m%d%H%M%S)"

container-version 1.3.1 &&
bash tests/run-container-compat-tests.sh --assets-dir "$compat_assets" &&
bash tests/run-container-compat-tests.sh --prepare-upgrade \
  --assets-dir "$compat_assets" --state-dir "$compat_transition" &&
container-version 1.5.0 &&
bash tests/run-container-compat-tests.sh --verify-upgrade \
  --assets-dir "$compat_assets" --state-dir "$compat_transition"
```

The `&&` chain stops on the first failure. Do not switch versions while a suite is
still running. Keep the retained fixtures and state directory between preparation
and verification. Setup failures before retained verification begins preserve
those fixtures for retry; once verification begins, cleanup consumes them even
on failure. A new attempt then needs new baseline fixtures and a new state path.

## Test both candidate versions in one chain

With assets already prepared, this runs the baseline once and tests separate
1.3.1-to-candidate transitions. It finishes on 1.5.0 only if every phase succeeds:

```bash
compat_assets="$HOME/.cache/agentctl-container-compat/assets-1.3.1"
compat_batch="$HOME/.cache/agentctl-container-compat/review-$(date +%Y%m%d%H%M%S)"

container-version 1.3.1 &&
bash tests/run-container-compat-tests.sh --assets-dir "$compat_assets" &&
bash tests/run-container-compat-tests.sh --prepare-upgrade \
  --assets-dir "$compat_assets" --state-dir "$compat_batch-to-1.4.1" &&
container-version 1.4.1 &&
bash tests/run-container-compat-tests.sh --verify-upgrade \
  --assets-dir "$compat_assets" --state-dir "$compat_batch-to-1.4.1" &&
container-version 1.3.1 &&
bash tests/run-container-compat-tests.sh --prepare-upgrade \
  --assets-dir "$compat_assets" --state-dir "$compat_batch-to-1.5.0" &&
container-version 1.5.0 &&
bash tests/run-container-compat-tests.sh --verify-upgrade \
  --assets-dir "$compat_assets" --state-dir "$compat_batch-to-1.5.0"
```

## Decide, diagnose, and recover

Check each printed report's `metadata.json` for the intended CLI/API server
versions. A certification report must have `compatible: true`, `exit_code: 0`,
`cleanup_passed: true`, and the complete test inventory in `summary.json`.
Retain the successful baseline and candidate reports, including the recorded
upgrade transitions. Run `bash tests/run-tests.sh --tier full` for the separate
agentctl integration requirement before release or compatibility sign-off.

Direct `container copy` regressions are non-gating diagnostics because agentctl
uses streamed transfers. Simultaneous bulk echo is also a non-gating stress
diagnostic; real 2 MiB managed uploads/downloads and replies before stdin EOF
remain mandatory. The bulk-echo diagnostic records timeouts and byte counts,
including the intermittent stall observed on 1.3.1. Mandatory transfer, stream,
lifecycle, and advertised optional-feature failures still block certification.

For a failed stream test, keep the same runtime active and retry that entire
case after the current suite finishes:

```bash
bash tests/run-container-compat-tests.sh \
  --assets-dir "$HOME/.cache/agentctl-container-compat/assets-1.3.1" \
  --filter streams
```

A successful focused retry produces `partial`, not `compatible`. Repeat the full
affected suite before accepting the version. Do not hide a stall by dropping
assertions or increasing deadlines without investigating its cause. For example,
a `missing signal in xpc message` error printed during timeout termination can
be secondary to a stalled stream; inspect the operation's bytes, timestamps,
and `timed_out` flag to identify the initial failure.

Cancel with Ctrl+C and wait for cleanup. If cleanup failed or a run was killed,
use its report or retained state directory:

```bash
bash tests/run-container-compat-tests.sh --cleanup --state-dir /path/to/report-or-state
```

If the API server is unresponsive, recover it on the host first, then repeat
cleanup. Keep resource journals until cleanup succeeds. Afterwards, obsolete
failed reports and consumed upgrade-state directories can be deleted; retain
reusable assets and successful certification reports.

To return to the baseline, wait for the suite to finish, then run
`container-version 1.3.1`. Changing the host runtime does not automatically rebuild
images or replace existing guest agents. Continue to use agentctl's streamed
transfer workaround for retained containers.
