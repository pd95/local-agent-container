# Apple container contracts exercised by agentctl

The suite tests observable behavior through the actual Apple runtime. The
adapter only adds bounded execution and diagnostics. Production functions are
loaded with the repository's existing unit-harness convention, without replacing
runtime calls. Public `agentctl` invocations inherit the same adapter.

| Case | Production contract and entry points | Observable checks |
| --- | --- | --- |
| `health` | `require_container`, `host_doctor`, `container_list_*` | Running API server, matching CLI/server versions, JSON versions, bounded list; health after every workload |
| `lifecycle` | `run_mode`, `simple_name_cmd`, `start_existing_container_*` | Create/stopped state, table/quiet/JSON listing, inspect, start/stop, public restart, removal/absence, workload exit code and logs, fresh workload after failure |
| `images` | `build_cmd`, `image_list_json_required`, `container_image_digests_in_use`, `remove_image_ref` | Pull from a loopback OCI registry with unique layers and verified digest/download, build with repository flags, local execution, inspect/list/tag/remove, digest changes after retagging, original digest retained by stopped container |
| `exec` | `exec_cmd`, `su_exec_cmd`, `run_agent_sh_in_container`, `configure_container_host_alias` | Exact arguments, stdout/stderr, exit code, guest environment, inherited working directory, root and coder execution, explicit PTY |
| `streams` | `exec_cmd --stdio`, stdin-dependent state/refresh paths | `-i`/`--interactive` stdin, EOF, JSON replies before stdin closes, 2 MiB actual managed upload and public stdio download, separate simultaneous-echo diagnostic, failed stdio command |
| `agentctl_run` | Public `run --stdio`, `run --temp`, `run_mode` | Initial create/exec/stop, reuse, nonzero exit, protocol bytes, temporary-container removal |
| `transfers` | `refresh_container_file`, `refresh_container_tree`, `activate_container_refresh_stage`, `agent.sh state export/import` | Bytes, modes/owners, hidden/nested files, symlinks, spaces/colons, replacement, stale-file removal, staging cleanup, missing-source preservation, archive round trip |
| `recovery` | `export_container_for_upgrade`, `extract_container_export_rootfs`, `build_backup_image_from_export` | Stopped filesystem export, changed state and metadata, actual recovery-image construction and boot |
| `mounts` | `run_mode`, `container_upgrade_info`, `container_mount_mode` | Workdir/home binds, host/guest writes, read-only enforcement including root, restart persistence, mount parsing |
| `resources` | Create flags, `container_upgrade_info`, `container_shm_size` | CPU/memory configuration and observable guest resources; advertised shared-memory size |
| `default_network` | `container_network_host_address`, `configure_container_host_alias`, Ollama/MCP host connectivity | Gateway parsing, default route, host alias, actual host TCP round trip |
| `named_network` | `network_create_cmd`, `network_*_normalized_json`, `container_network_names` | Labels/ownership, inspect/list, repeated network attachments, same-network TCP, restart, host access, refusal to delete attached networks, deletion |
| `internal_network` | `--internal`, host-only network selection and host aliases | Same-network traffic, cross-network isolation, selected-gateway host access, rejected off-subnet traffic with a live positive control |
| `mounted_socket` | `--volume` through `socket_volume_arguments`, `container_extra_mounts` | Coder round trip through a host Unix socket, restart, inspect-visible mapping |
| `published_socket` | `--publish-socket`, `container_published_sockets`, lifecycle listener checks | Guest-to-host Unix socket, coder server, inspect-visible mapping, listener disappearance/recreation on stop/start/removal |
| `ssh` | `--ssh`, `container_ssh_enabled`, `guest_ssh_socket_available` | Disposable host agent/key visible to coder, inspect flag, restart forwarding |
| `storage` | `container_system_df_supported`, `container_storage_usage_json` | Advertised storage accounting satisfies the actual production JSON parser |
| `retained_upgrade` | Public `refresh`, transfer/state/export functions on pre-upgrade fixtures | Original running/stopped guest agents, consumed configuration, baseline markers, mounts/sockets, streamed refresh, state archive, stop/start/export, diagnostic copy in both directions |

Image pulling is mandatory in every candidate run, using a tiny repository-owned
OCI registry fixture bound to host loopback with explicit HTTP transport. Each
run creates unique layer bytes, requires their download, verifies the pulled
manifest digest, and removes its uniquely named image. Registry TLS and external
registry authentication remain outside this local runtime contract. The immutable
base pulled during preparation and saved root filesystem are intentional prepared
assets; other image checks use local scratch builds. Runtime-owned init/builder image caching belongs to
Apple's runtime. The suite preserves a pre-existing builder and restores its
running state if a production backup helper stopped it; a suite-created builder
is journaled and removed. Do not run unrelated builds concurrently.

Optional cases are named/internal networking, published sockets, SSH forwarding,
and storage accounting. Shared-memory support is an optional part of the required
resource case. Missing advertised help capabilities yield explicit unsupported
results matching agentctl's guards. Failed probes fail the suite; an unavailable
optional subcommand is confirmed through successful parent help. Failure of an
advertised capability blocks
compatibility. Help-only diagnostics such as `machine --help` do not establish a
workload contract and do not require machine creation or global reconfiguration.

`container copy` is exercised separately as a non-gating diagnostic: its exit
code alone is insufficient, and both directions require matching bytes. Current
agentctl relies on exec streaming instead. A diagnostic hang still has a
deadline, and subsequent mandatory runtime health checks must pass.

Bulk transfers are gated through `refresh_container_file` and public
`agentctl exec --stdio` downloads, with exact 2 MiB binary equality. Interactive
protocol replies must also arrive before stdin closes. An unbounded simultaneous
bulk echo is an additional stress diagnostic, not a production transfer
requirement; 1.3.1 has intermittently stalled after a prefix of the input. The
diagnostic retains its operation deadline, byte counts, and subsequent mandatory
runtime health check. Passing these contracts does not establish arbitrary bulk
full-duplex reliability.

The suite uses host-controlled listeners instead of public Internet services.
This validates local host/guest networking and off-subnet isolation without
confusing an Internet outage with a runtime regression. Public Internet reachability,
host firewall policy, AI-provider availability, interactive authentication, and
image-specific AI tools remain outside this runtime suite. Existing full host
integration coverage remains required for releases.

When adding a production CLI operation or consuming another inspect/list field,
update this inventory and add an observable assertion. Full certification
requires every required case and every advertised optional case to pass;
filtered, resumed, incomplete, interrupted, or cleanup-failed runs cannot certify.
