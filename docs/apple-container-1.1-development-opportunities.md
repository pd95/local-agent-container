# Apple container 1.1 development opportunities

This document collects possible `agentctl` developments enabled by Apple
container changes between releases 0.12.3 and 1.1.0. It is a candidate backlog,
not an implementation commitment.

The review covered all 126 commits in the upstream range, the final 1.1 command
reference, and the relevant command implementations and tests. The existing
[Apple container 1.1 compatibility upgrade](apple-container-1.1-upgrade.md)
runbook remains the source for runtime migration and compatibility work. This
document focuses on what to build next.

Upstream references:

- [0.12.3...1.1.0 commit range](https://github.com/apple/container/compare/0.12.3...1.1.0)
- [Apple container 1.1.0 release](https://github.com/apple/container/releases/tag/1.1.0)
- [Apple container 1.1 command reference](https://github.com/apple/container/blob/1.1.0/docs/command-reference.md)
- [Apple container system configuration reference](https://github.com/apple/container/blob/1.1.0/docs/container-system-config.md)

## Executive summary

`container machine` is the largest new upstream subsystem, but several smaller
changes are a better fit for near-term `agentctl` development:

1. expose and preserve configurable shared-memory size
2. use corrected storage accounting for backup diagnostics
3. optionally use `container cp` for host-container file transfer
4. export existing recovery images as clean, portable OCI archives
5. report effective Apple container TOML defaults in host diagnostics
6. expose custom and host-only networking
7. expose SSH and Unix-socket forwarding now that non-root socket permissions
   work reliably
8. add builder DNS, download-concurrency, and progress controls

Apple container 1.1 still cannot clone a container, commit a container directly
to an image, import a root-filesystem tar as an image, or create incremental
container snapshots. Full recovery images therefore still require the existing
export-and-build pipeline. `agentctl upgrade --copy` remains the faster safety
option when preserving the original container under its existing name is
acceptable and the replacement can use a new name.

## Status vocabulary

The candidate tables use these labels:

- **adopted**: `agentctl` already uses the behavior
- **detected**: `doctor --host` reports the capability, but normal commands do
  not use it
- **automatic**: the upstream fix benefits existing commands without an
  `agentctl` change
- **candidate**: a bounded enhancement suitable for selection
- **research**: a larger design question that should not be mixed into routine
  compatibility work

## Candidate overview

| Topic | Current status | Expected value | Likely effort | Suggested priority |
|---|---|---:|---:|---:|
| `--shm-size` | implemented | high for browsers and shared-memory workloads | complete | selected |
| Storage and backup diagnostics | implemented | high for full backup reliability | complete | selected |
| `container cp` transfer backend | detected | medium; simpler and less guest-tool dependent | medium | high |
| OCI recovery-image export | unused | high for off-host disaster recovery | medium | high |
| Effective runtime defaults in doctor | implicit only | medium; clearer resource behavior | small-medium | medium |
| Custom and host-only networks | partial network awareness | medium-high for isolation | medium-large | medium |
| SSH and socket forwarding | detected | medium for developer integrations | medium | medium |
| Builder DNS controls | unused | medium in VPN/private-network environments | medium | medium |
| Pull concurrency and progress | unused | low-medium | small-medium | medium-low |
| Stop-signal support | unused | low with the current keepalive process | medium | low-medium |
| Localhost DNS helper | documented alternative | situational | medium; privileged host change | low |
| `container machine` backend | detected | potentially high, but a different operating model | large | research |

Priorities are starting points. A topic should move into implementation only
after its open questions and host verification steps have been resolved.

## Shared-memory sizing

### Upstream capability

Apple added `--shm-size` to `container create` and `container run`. It controls
the size of `/dev/shm` in the guest.

This matters for:

- Chromium and Playwright
- browser-based testing and automation
- databases using shared memory
- build and machine-learning tools that exceed the default allocation

### Current agentctl state

`doctor --host` detects the flag. `run`, `bootstrap`, `upgrade`, and `rescue`
expose it. Upgrade preserves an explicit inspected value unless the user
supplies an override, and `run` compares a requested value when reusing an
existing container.

### Candidate interface

```bash
agentctl run --shm-size 2G
agentctl bootstrap --shm-size 2G
agentctl upgrade --shm-size 2G
agentctl rescue --shm-size 2G
```

When `upgrade` receives no override, it should preserve the inspected source
setting if Apple reports it. If the old runtime does not expose the value,
upgrade should retain current behavior rather than inventing one.

### Investigation before implementation

- Confirm the 1.1 `container inspect` field name and representation.
- Verify whether the setting is present when it came from a system default.
- Determine whether a recreated container can distinguish an explicit value
  from the default.
- Add an integration test that checks the actual size inside `/dev/shm`.
- Decide whether the option belongs in every creation path or only `run` and
  `upgrade` initially.

## Storage and backup diagnostics

### Upstream capability

Apple corrected `container system df` so that it counts content blobs and
deduplicates shared storage. Earlier output could misstate actual usage.

### Agentctl integration

`agentctl doctor --host` reports validated global image, container, and volume
usage from `container system df --format json`. Backup export and image-build
failures include the same best-effort summary and direct users to host doctor.
Successful backup paths remain quiet.

The report explicitly treats Apple's reclaimable value as a runtime
classification, not permission to delete data. Stopped containers and volumes
may contain valuable mutable state, so diagnostics never trigger pruning.

### Boundaries and verification

`system df` does not report free host disk space or predict BuildKit's peak
temporary use. It can support warnings and diagnosis, but not a reliable
preflight guarantee.

- The 1.1 JSON contract contains `images`, `containers`, and `volumes`, each
  with `total`, `active`, `sizeInBytes`, and `reclaimable`.
- Older runtimes without `system df` remain supported; host doctor reports the
  capability as unavailable without failing.
- A supported command that fails or returns malformed JSON makes host doctor
  fail, while failure-path diagnostics never mask the original backup error.
- Human-readable Apple tables are never parsed.

## Optional container-copy backend

### Upstream capability

`container copy`, with alias `container cp`, copies files or directories
between the host and a running container. Apple 1.1 fixes relative host-source
path resolution.

Limitations:

- the container must be running
- one endpoint must be on the host
- container-to-container copying is unsupported
- there are no include/exclude filters
- ownership and mode policy still needs explicit handling
- it does not replace stopped-container export

### Current agentctl state

`doctor --host` detects the command, but normal operations still use:

- `container exec -i ... cat` for individual files
- host `tar` piped to guest `tar` for directory trees
- guest `tar` streamed to the host for selective state backups

### Candidate design

Introduce a small transfer abstraction with capability-based selection:

```text
host file/tree -> running container
├── container cp supported: copy, then normalize ownership and modes
└── otherwise: retain the current cat/tar stream
```

Good first users are managed host-to-container files and trees. Selective state
backup should retain tar initially because it already supports exclusions and
creates the final archive without a staging tree.

### Expected benefit

The main benefit is simpler, more robust transfer with less dependence on guest
utilities. It is not yet established that `cp` is faster. Directory copying may
still use archive-like transport internally, and copying state out before
packing it can add host I/O.

### Investigation before implementation

- Benchmark current streaming and `container cp` for small files, many small
  files, and a large directory.
- Verify symlink, hardlink, timestamp, sparse-file, and extended-attribute
  behavior.
- Verify destination semantics for existing directories and trailing slashes.
- Verify failures are atomic enough for managed configuration updates.
- Test spaces, colons, relative paths, and non-ASCII host paths.
- Determine which owner/mode corrections remain necessary.
- Preserve regression coverage for stdin-dependent `container exec -i` calls.

## Portable OCI recovery-image export

### Upstream capability

Apple fixed `container image save` so that, without `--output`, stdout contains
only OCI archive bytes. Saved image references are now written to stderr. This
makes redirection and pipelines safe for strict tar and OCI consumers.

### Opportunity

Recovery images currently remain in Apple container's local image store. A
portable export would make them useful after loss or corruption of that store:

```bash
agentctl images export IMAGE --output backup.oci.tar
agentctl images export IMAGE --compress zstd --output backup.oci.tar.zst
```

Restoration would load the uncompressed archive with `container image load`.
Compression could initially be an optional host-tool integration rather than a
required dependency.

### Boundaries

This archives an image that already exists. It does not accelerate converting a
mutable container into the recovery image.

### Investigation before implementation

- Verify stdout behavior on 1.0 and 1.1 and require `--output` on runtimes where
  stdout is unsafe.
- Round-trip a backup image through save, deletion, load, rescue, and state
  verification.
- Decide whether multiple image references should be accepted.
- Decide whether checksums and a sidecar manifest should be generated.
- Determine supported compression tools and restore UX.

## Effective Apple container defaults

### Upstream capability and breaking change

Apple replaced mutable user-default-backed system properties with layered TOML
configuration. The user configuration lives at:

```text
~/.config/container/config.toml
```

It can set defaults for builder resources, container resources, DNS, kernels,
networks, registries, vminit, and plugins. The service reads it at startup.
`container system property set`, `get`, and `clear` were removed; property
listing now prints merged TOML by default or JSON on request.

### Current agentctl state

When `agentctl` omits `--cpu` or `--mem`, Apple container defaults apply
implicitly. Host doctor reports runtime versions but not the effective defaults
or their source.

### Candidate enhancement

Extend `doctor --host` to call:

```bash
container system property list --format json
```

and report the effective values most relevant to `agentctl`:

- default container CPU and memory
- builder CPU and memory
- builder image and Rosetta setting
- registry domain
- DNS domain
- configured network subnets

Diagnostics should not edit the user's Apple container configuration.

### Investigation before implementation

- Capture both 0.12.3 and 1.1 property-list behavior.
- Decide whether to report effective values only or also identify the user
  configuration file.
- Clarify precedence between explicit `agentctl` flags and runtime defaults.
- Detect obsolete instructions or files left from pre-1.0 property handling.
- Keep this distinct from Codex's unrelated `config.toml`.

## Custom and host-only networking

### Upstream capability

Network creation now supports host-only networks and explicit plugins:

```bash
container network create --internal agent-isolated
container network create --plugin PLUGIN --option key=value NAME
```

The release also refreshes the default network from current system
configuration during service startup.

### Current agentctl state

`agentctl` dynamically discovers the default gateway and maintains
`host.container.internal`; this is already the correct response to changing
default subnets. `host-address` can inspect a named network, but `agentctl run`
does not expose network selection or network lifecycle management.

### Candidate interface

```bash
agentctl network create agent-isolated --internal
agentctl run --network agent-isolated
agentctl upgrade --network agent-isolated
```

An internal network could reduce exposure for agents working on untrusted code.
It cannot be the unconditional default because online runtimes, Git hosts,
registries, package managers, and other integrations need external access.

### Investigation before implementation

- Verify exactly what `--internal` permits between containers and the host.
- Test online runtimes, local Ollama, package installation, and MCP relays.
- Determine how to preserve all network attachments during upgrade.
- Determine whether host alias configuration must inspect the selected network
  instead of `default`.
- Establish ownership/naming rules before adding network prune or delete.
- Avoid deleting user-created networks that merely share an `agent-` prefix.

## Localhost DNS forwarding

Apple documents a DNS and packet-filter mechanism for making a host localhost
service reachable under a container DNS name:

```bash
container system dns create --localhost ADDRESS DOMAIN
```

It has important host-level effects:

- creating the localhost domain disables Private Relay
- the packet-filter rule is removed on restart
- setup requires elevated host permissions

`agentctl` should continue treating this as an explicit host setup option, not
automatic configuration. A future diagnostic could verify the DNS record and
explain how to recreate it after a restart.

## SSH agent and Unix-socket forwarding

### Upstream capability and fix

Apple 1.1 propagates host socket permissions into the guest so non-root users
can use mounted Unix sockets reliably. This improves SSH-agent forwarding,
published sockets, MCP connections, and developer-tool integrations.

### Current agentctl state

Host doctor detects `--ssh` and `--publish-socket`, but `agentctl run` does not
expose them generally.

### Candidate interface

```bash
agentctl run --ssh
agentctl run --publish-socket HOST_PATH:CONTAINER_PATH
```

Upgrade should preserve requested socket configuration where meaningful, but
must distinguish ephemeral host paths such as a login-session SSH socket from
stable configuration.

### Investigation before implementation

- Test access as `coder`, not only root.
- Verify behavior after host logout/login changes `SSH_AUTH_SOCK`.
- Decide whether `--ssh` should be opt-in per run or persisted in container
  configuration.
- Validate socket paths and avoid printing sensitive path or connection data.
- Document the trust consequences of exposing a host agent or daemon socket to
  code inside the container.

## Builder DNS controls

`container builder start` now accepts DNS nameservers, search domains, domain,
and resolver options. These can solve build-only failures on VPNs, split-DNS
networks, private registries, and internal package mirrors.

Possible approaches:

1. expose builder DNS flags from `agentctl build`
2. document Apple container's TOML configuration as the preferred persistent
   mechanism
3. add project-local `agentctl` build configuration that starts the builder
   explicitly

Investigation should determine whether explicitly starting the builder changes
its lifetime, whether settings persist across builds, and how conflicting DNS
sources are handled. A global Apple container setting is preferable when the
same DNS applies to every project; per-project flags are preferable for
isolated development environments.

## Pull concurrency and progress output

Apple standardized progress output and added `--max-concurrent-downloads` to
image-fetching paths. Relevant modes include plain, color, ANSI, none, and
automatic selection depending on the command.

Potential uses:

- deterministic plain logs in CI
- no progress noise in machine-readable or stdio flows
- lower concurrency on constrained connections
- higher concurrency with fast local registries

Rather than repeat flags across every `agentctl` command, consider environment
or project configuration:

```bash
AGENTCTL_PROGRESS=plain
AGENTCTL_MAX_CONCURRENT_DOWNLOADS=6
```

Before implementation, verify which flags are accepted by `pull`, `create`,
`run`, `build`, and `machine create`; Apple does not expose an identical set on
every path.

## Stop-signal support

Apple added stored stop-signal configuration and explicit stop-signal handling.
This is useful for application containers whose main process expects a signal
other than `SIGTERM`.

Current `agentctl` containers use a long-lived `sleep infinity` command and run
the selected agent through `container exec`, so stop-signal configuration has
limited immediate value. It becomes more important if `agentctl` supports a
custom persistent main process.

If selected, investigate the inspect field, preservation during upgrade, signal
name/number validation, and the interaction with the current stop timeout.

## Structured output and stdout safety

The upstream range contains extensive scripting-related changes:

- normalized container, image, network, and volume JSON shapes
- YAML and TOML support and rendering fixes
- a new array shape for `container system version`
- consistent not-found behavior for inspect commands
- sorted network output
- corrected volume creation-date encoding
- image IDs without the `sha256:` scheme
- removal of duplicated image names in image JSON
- clean separation of result output on stdout and logs/errors on stderr
- build output limited to result tags and paths

### Current agentctl state

The 1.1 compatibility work already covers both old and new structured output
for important image and container operations. `agentctl` also uses quiet output
where an exact ID is required.

### Remaining audit

Before relying on 1.1 stdout contracts more broadly, inventory every command
substitution and pipeline involving Apple container. Tests should verify that:

- temporary `container create` captures only the container ID
- stdio ACP/MCP commands receive no lifecycle messages on stdout
- image save emits only archive bytes
- build output is not parsed as a human-readable table
- errors remain visible when successful output is redirected

This is primarily hardening, not a new user-facing feature.

## Automatic runtime benefits

The following fixes improve current `agentctl` operations without requiring a
new interface:

- XPC sessions release leaked IP allocations when clients disconnect.
- `container kill` waits for the container to exit, reducing remove/recreate
  races.
- graceful-stop errors are logged instead of silently discarded.
- empty `container exec` arguments no longer crash the CLI.
- missing network sessions no longer trigger a force-unwrap crash.
- service directory-creation failures propagate from `system start`.
- publish-port arithmetic no longer risks an integer crash.
- progress rendering no longer crashes in very narrow terminals.
- relative `container cp` host paths resolve against the current directory.
- image-load failures and other command diagnostics are routed to stderr.
- missing-resource inspect behavior is more consistent.
- default network configuration is refreshed on service start.
- source image-index media types are preserved when pushing images through the
  updated Containerization dependency.

These changes should be represented in integration coverage where they affect
an existing lifecycle, but they do not need individual `agentctl` features.

## Known limitations retained in 1.1

Do not plan work on the assumption that 1.1 provides any of the following:

- container clone or rename
- Docker-style `container commit`
- direct rootfs-tar import as an OCI image
- incremental container export
- block-level container snapshot commands
- container-to-container `cp`
- copying from or to a stopped container
- automatic anonymous-volume cleanup with `--rm`

Apple added an explicit error for Dockerfiles at or above the unresolved 16 KiB
limit; it did not remove the limitation. Keep project Dockerfiles below the
limit by moving substantial logic into scripts and copied assets.

## Container machine research track

### What it provides

`container machine` is a persistent Linux-environment abstraction with:

- OCI-image-based creation
- `/sbin/init` and service-manager support
- automatic host-user provisioning
- configurable host-home mounting
- named and default machines
- command execution, logs, stop, delete, inspect, and resource updates
- nested virtualization with an M3-or-later Mac and a custom KVM-enabled kernel

### Why it is not a transparent agentctl backend

The operating model differs materially from regular project containers:

- the host home is shared by default
- the machine is a long-lived Linux environment rather than an application
  container
- agent authentication and Keychain replay assumptions differ
- `/workdir` ownership and lifecycle differ
- upgrade, backup, rescue, and isolation semantics must be redesigned
- machines cannot be cloned through the CLI either

### Research questions

- Is a machine useful as a shared build host while agents still run in regular
  containers?
- Can `home-mount=none` or `ro` provide an acceptable security model?
- Should a future `agentctl machine` be a distinct command family rather than a
  backend switch?
- How should runtime installation and updates interact with systemd services?
- What state must be backed up, and can machine storage be exported safely?
- Does nested virtualization unlock a concrete agent workflow worth its kernel
  and hardware requirements?

Treat this as a separate design project. It should not delay bounded regular
container improvements.

## Suggested selection process

For each topic selected for further work:

1. create a focused issue or development note
2. capture the final 1.1 CLI help and structured inspect output on the macOS host
3. test the upstream behavior directly with a disposable container
4. define compatibility behavior for 0.12.3 where support remains required
5. specify upgrade preservation and rollback behavior
6. add unit fixtures before changing shell logic
7. implement the smallest useful slice
8. run `bash tests/run-unit-tests.sh`
9. run the relevant macOS integration tier and a tailored manual smoke test

Host lifecycle and Apple framework tests must be run by the user on macOS. Use
`container exec -i` whenever a host integration test pipes or redirects input
into a container.

## Proposed first investigation batch

The following batch gives useful evidence without committing to large design
changes:

1. capture `container inspect` for `--shm-size`, stop signal, networks, SSH, and
   published sockets
2. benchmark `container cp` against current cat/tar transfers
3. capture `container system df --format json` before, during, and after a full
   backup-image build
4. round-trip one recovery image through `image save`, external compression,
   `image load`, and `agentctl rescue`
5. test a disposable `--internal` network with local Ollama, an online runtime,
   package installation, and Git access

After those results are recorded, the first implementation topics can be
selected with measured performance and compatibility data rather than release
notes alone.
