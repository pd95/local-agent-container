# Apple container 1.1 compatibility upgrade

This runbook tracks the `agentctl` migration from Apple `container` 0.12.3 to
1.1.0. It is deliberately split at the host-runtime upgrade because replacing
the runtime interrupts the active development container.

## Scope

- Preserve compatibility with the currently installed 0.12.3 runtime while
  adding tested support for 1.1.0.
- Replace parsing of unstable table and pre-1.0 JSON output with supported
  structured or quiet output.
- Add host runtime diagnostics and capability detection.
- Verify build, lifecycle, auth, refresh, upgrade, rescue, and stdio flows.
- Evaluate `container cp`, SSH/socket forwarding, network isolation, resource
  controls, and operational diagnostics as follow-up features.

## Work phases

### Phase 1: prepare while the host still runs 0.12.3

1. Add fixtures for both the 0.12.3 and 1.1.0 structured output shapes.
2. Update image timestamp discovery for both schemas.
3. Replace container table parsing with exact IDs from `--quiet` or JSON.
4. Extend `doctor` with CLI, service, installation-path, and capability checks.
5. Run repo-local unit tests.
6. Capture a macOS integration baseline using the commands below.

### Phase 2: interruption checkpoint

Before changing the host runtime:

1. Verify the active Git branch is
   `upgrade/apple-container-1.1-compat`.
2. Record `git status --short --branch`.
3. Commit the prepared compatibility work if it is ready to preserve a clean
   resumption point.
4. Capture the host diagnostics and integration results under `/tmp` or in a
   location outside the repository.
5. Stop the Apple container service and perform the upgrade.

The active agent session is expected to end when the service stops. No work
should depend on an in-memory process surviving this checkpoint.

### Phase 3: resume under 1.1.0

Start a new development container from the repository and send Codex:

> Resume the Apple container 1.1 compatibility work on branch
> `upgrade/apple-container-1.1-compat`. Read
> `docs/apple-container-1.1-upgrade.md`, inspect Git status, and continue from
> the Phase 3 checkpoint. The host now runs Apple container 1.1.0.

Then:

1. Confirm the CLI and API service both report 1.1.0.
2. Check for duplicate `/usr/local` and Homebrew `container` installations.
3. Run the host integration suite.
4. Exercise a disposable build/run/refresh/upgrade/rescue lifecycle.
5. Fix regressions and repeat the affected checks.
6. Implement selected 1.1 features only after the compatibility suite passes.

### Discovered network migration issue

After upgrading this host, the default container network moved from
`192.168.64.0/24` to `192.168.65.0/24`. Existing literal references to
`192.168.64.1` are therefore stale.

`agent.sh` already detects the current default gateway from `/proc/net/route`
when neither `OLLAMA_HOST` nor runtime config `ollama_host` is supplied. On the
host, `agentctl host-address` reads the authoritative gateway from `container
network inspect default`; `--network NAME` supports a non-default network.
Agentctl writes that gateway to each managed container's `/etc/hosts` as
`host.container.internal` on start and before exec. The Xcode MCP shim advertises
the stable hostname rather than a fixed address.

Apple container 1.1 also documents a named host-service route using
`host.container.internal`, created with `container system dns create
--localhost`. That mechanism requires elevated host setup, disables Private
Relay, and its packet-filter rule is removed on restart. Evaluate it as an
explicit opt-in rather than silently configuring it from `agentctl`.

## Host baseline commands for 0.12.3

Run these on the macOS host, not inside an agent container:

```zsh
cd /path/to/local-agent-container

mkdir -p /tmp/agentctl-container-upgrade
container --version \
  | tee /tmp/agentctl-container-upgrade/cli-version-0.12.3.txt
container system version --format json \
  | tee /tmp/agentctl-container-upgrade/system-version-0.12.3.json
container system status --format json \
  | tee /tmp/agentctl-container-upgrade/system-status-0.12.3.json
container ls -a --format json \
  > /tmp/agentctl-container-upgrade/containers-0.12.3.json
container image ls --format json \
  > /tmp/agentctl-container-upgrade/images-0.12.3.json
command -v -a container \
  | tee /tmp/agentctl-container-upgrade/container-paths-before.txt
sw_vers \
  | tee /tmp/agentctl-container-upgrade/macos-before.txt

bash tests/run-tests.sh --tier full \
  2>&1 | tee /tmp/agentctl-container-upgrade/integration-0.12.3.log
```

Do not upgrade until the Phase 1 compatibility preparation is complete and
the baseline results have been reviewed.

## Installation choice

Prefer upgrading with the same distribution mechanism used for the current
installation. This tests the runtime change without also changing installation
layout and service ownership.

Determine the current installation:

```zsh
command -v -a container
ls -l "$(command -v container)"
pkgutil --pkgs | grep -i container
brew list --versions container 2>/dev/null || true
sw_vers -productVersion
```

### Selected installation path for this upgrade

The current host was verified as:

- macOS 26.5.2
- Apple Silicon (`arm64`)
- Homebrew-managed `container` 0.12.3
- active executable `/opt/homebrew/bin/container`, linked into the Homebrew
  cellar
- no matching Apple installer package receipt

Use an in-place Homebrew upgrade. Do not uninstall the existing formula and do
not use Apple's `/usr/local/bin` updater:

```zsh
brew update
brew upgrade container
```

Homebrew's formula stops the Apple container service during post-install to
avoid mixing incompatible CLI and API-server components. The active agent
session is therefore expected to terminate during `brew upgrade container`.
After the command returns in the host Terminal:

```zsh
hash -r
type -a container
container --version
container system start
container system version --format json
```

Do not run the Homebrew upgrade until the Phase 2 checkpoint is explicitly
declared ready.

### Existing Apple package installation: preferred path

```zsh
container system stop
/usr/local/bin/update-container.sh
container --version
container system start
container system version --format json
```

The session running inside Apple container will terminate at
`container system stop`. Run the remaining commands from a separate macOS
Terminal after it exits.

### Intentional migration to Homebrew

Homebrew's 1.1.0 formula requires Apple Silicon and macOS 26 Tahoe. Do not mix
an active Apple-package installation under `/usr/local` with a Homebrew CLI and
service under `/opt/homebrew`.

If migrating, retain Apple container user data while removing its installed
binaries, then install through Homebrew:

```zsh
container system stop
/usr/local/bin/uninstall-container.sh -k
brew install container
command -v -a container
container --version
container system start
container system version --format json
```

If `command -v -a container` shows both installations after migration, stop
and resolve the duplicate before running `agentctl`.

## Post-upgrade capture

After 1.1.0 is running:

```zsh
mkdir -p /tmp/agentctl-container-upgrade
container --version \
  | tee /tmp/agentctl-container-upgrade/cli-version-1.1.0.txt
container system version --format json \
  | tee /tmp/agentctl-container-upgrade/system-version-1.1.0.json
container system status --format json \
  | tee /tmp/agentctl-container-upgrade/system-status-1.1.0.json
container ls -a --format json \
  > /tmp/agentctl-container-upgrade/containers-1.1.0.json
container image ls --format json \
  > /tmp/agentctl-container-upgrade/images-1.1.0.json
command -v -a container \
  | tee /tmp/agentctl-container-upgrade/container-paths-after.txt
```

Keep `/tmp/agentctl-container-upgrade` until compatibility verification is
complete so the old and new output shapes can be compared.

Run the complete unit and host suites before declaring 1.1 compatible. The host
runner defaults to only its smoke tier, so `--tier full` is required here:

```zsh
bash tests/run-unit-tests.sh \
  2>&1 | tee /tmp/agentctl-container-upgrade/unit-1.1.0.log
bash tests/run-tests.sh --tier full \
  2>&1 | tee /tmp/agentctl-container-upgrade/integration-1.1.0-full.log
```

After updating an existing managed container to agentctl 0.2, run `agentctl
refresh --name NAME` once. Refresh migrates image-owned runtime defaults from
the former runtime-specific `/etc/*ctl` directories into
`/etc/agentctl/<runtime>` and repairs the image guidance link without changing
user-owned runtime configuration.

## Rollback

If 1.1.0 cannot start the service or breaks critical existing containers, use
Apple's supported update script to reinstall the previous release while
retaining user data:

```zsh
container system stop 2>/dev/null || true
/usr/local/bin/uninstall-container.sh -k
/usr/local/bin/update-container.sh -v 0.12.3
container system start
container --version
```

The exact rollback procedure depends on the chosen installation mechanism. Do
not use the Apple-package rollback commands against a Homebrew-managed install;
use `brew uninstall container` before restoring the Apple package.

## Completion criteria

- Repo-local unit tests pass.
- Host integration tests pass on 1.1.0.
- Existing 0.12.3 fixtures remain covered.
- Image timestamp snapshots are discovered correctly under both schemas.
- Container existence/running checks do not parse human-readable tables.
- CLI and API service version skew is diagnosed clearly.
- Build helper cleanup is verified with the 1.1 builder implementation.
- Backup-enabled upgrade and rescue succeed on disposable data.
- Stdio ACP/MCP behavior remains byte-clean on stdout.
- README and testing documentation state the supported macOS and runtime
  versions and provide installation guidance.
- Default local-model and relay paths do not assume a fixed `192.168.64.1`
  gateway; stable host DNS setup is documented as an explicit alternative.
