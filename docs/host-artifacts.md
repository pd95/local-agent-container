# Import host artifacts into a container

The managed `host-artifacts` MCP server imports approved host files and directories
into `/workdir/.host-artifacts`. When paired with the built-in Xcode bridge, it additionally exposes
`extract_xcode_test_attachments` using `xcrun xcresulttool`. Files reach the owning container through the existing
private Unix-socket MCP bridge; no host TCP listener is added.

Host reads require Python 3.8 or newer (`python3` on the host's `PATH`), in
addition to the MCP bridge's Node.js requirement. Check with `python3 --version`.
The small reader uses descriptor-relative filesystem operations on macOS to
prevent source directory replacement from redirecting reads. It uses only the
Python standard library; containers do not need Python for this feature.

## Enable the server

Run these commands on the Mac from the project's workdir:

```bash
# New container: Xcode tools and their artifact imports.
agentctl create --mcp xcode --mcp host-artifacts

# Existing MCP-enabled container.
agentctl mcp add host-artifacts
```

Use `--name NAME` when targeting a container outside its project workdir.
Containers without MCP wiring first need `agentctl upgrade --enable-mcp`, followed
by `agentctl mcp add host-artifacts`. Enabling or changing definitions deploys the
managed guest writer automatically when the container starts. No image rebuild
is needed; `agentctl refresh` also updates the writer in existing MCP containers.

`host-artifacts` by itself grants **no host source access**. Enabling it alongside
the built-in `xcode` preset automatically grants narrow access to Xcode preview
PNGs, device interaction PNG/text artifacts, text logs from `BuildProject`,
`GetBuildLog`, `RunAllTests` and `RunSomeTests`, and test
result bundles directly under Xcode's `RunAllTests`/`RunSomeTests` ActionArtifacts directories. The order
of registration does not matter. Removing `xcode` removes these derived grants.
An explicitly granted `xcode` preset remains until revoked.

Canonical legacy Xcode definitions (`xcode`, `/usr/bin/xcrun mcpbridge`, shared
process) also qualify. Arbitrary servers named `xcode` and remote Xcode-over-SSH
servers do not. For other Xcode setups, grant the preset or source paths explicitly.

## Grant source access

Permissions are specific to the selected container and stored in its private
host registry. The MCP cannot change them, and editing a project file inside the
container cannot authorize additional host paths.

```bash
agentctl mcp artifacts allow-file "$HOME/Reports/latest.json"
agentctl mcp artifacts allow-directory "$HOME/Reports/Exports"

agentctl mcp artifacts allow-file-pattern \
  '^/(?:private/)?var/folders/.*/ActionArtifacts/[^/]+/RenderPreview/[^/]+\.png$'
agentctl mcp artifacts allow-directory-pattern \
  '^/Users/[^/]+/Reports/Test-[^/]+\.xcresult$'

# Named source rules, without requiring a corresponding upstream server.
agentctl mcp artifacts allow-preset xcode

agentctl mcp artifacts list
agentctl mcp artifacts list --json
agentctl mcp artifacts revoke GRANT_ID
agentctl mcp artifacts revoke preset:xcode
```

`list` shows grant IDs, effective rules, and whether they are explicit or automatic.
Automatic Xcode rules are removed by removing the built-in Xcode definition;
individual preset rules are not independently revocable. Revoking an explicit
Xcode preset while Xcode remains enabled leaves the automatic rules in effect.

Exact file/directory grants must exist and have the requested type when added;
their canonical paths are stored. Relative paths resolve from the command's
current directory. Regex grants need not match an existing source when added.
They use case-sensitive JavaScript regex syntax without flags and must match the
entire resolved absolute path. Single-quote regexes so the shell preserves them.

File grants authorize regular files only. Directory grants authorize the matched
directory and its descendants recursively. Sources are checked again on every
operation. Directory traversal resolves in-tree symlinks, rejects symlink escapes
and cycles, and refuses sockets, devices and other special filesystem objects.
A directory containing the artifact output area cannot itself be imported.

Identical grants are successful no-ops. Revocation uses the displayed ID and
continues to work after a source is deleted. Live changes use the normal managed
MCP restart and rollback flow; an active `agentctl run` lease prevents changes.
Changes to a stopped container do not start it.

### Reusable definitions

An owner-only private JSON file may describe the built-in server and its grants:

```json
{
  "name": "host-artifacts",
  "type": "builtin",
  "grants": [
    {"kind": "directory", "value": "/Users/you/Reports/Exports"},
    {"kind": "file-pattern", "value": "^/Users/you/Reports/[^/]+\\.json$"}
  ]
}
```

```bash
chmod 600 "$HOME/.config/agentctl/artifacts.json"
agentctl mcp add @"$HOME/.config/agentctl/artifacts.json"
```

The four grant kinds are `file`, `directory`, `file-pattern`, and
`directory-pattern`. Relative exact paths in a definition resolve against its
parent directory. Only `xcode` is accepted as a source preset. It grants source access;
it does not enable the optional Xcode extraction tool.
The built-in definition does not accept commands, environment values, destination
roots or container identity overrides. Changes to an already registered
server's grants should use the permission commands above.

## MCP tools

Codex registration uses the normal managed endpoint:
`http://127.0.0.1:47123/mcp/host-artifacts`. Other runtimes can configure that same
container-local URL manually.

### `import_artifact`

```json
{
  "sourcePath": "/absolute/approved/host/path/screenshot.png",
  "destinationName": "latest-screenshot.png",
  "overwrite": false
}
```

The destination is `/workdir/.host-artifacts/latest-screenshot.png`. Directories, including `.xcresult` bundles, are copied recursively to the
requested destination. An omitted
`destinationName` generates a unique name. Explicit names can contain relative
subdirectories; traversal, absolute names and destination symlinks are rejected.

The result includes `workspacePath`, `hostPath`, `sourcePath`, `kind`, `size`, and
`modifiedAt`. Read the resulting file with the runtime's normal local tools.
This is an on-demand import, not directory watching or bidirectional sync. Add
`/.host-artifacts/` to a project’s `.gitignore` when imported artifacts should stay
out of source control; the agentctl repository already includes that rule.

### `extract_xcode_test_attachments`

This tool is advertised and callable only when the built-in Xcode integration is
registered alongside host-artifacts. Generic installations expose only
`import_artifact` and `host_artifacts_status`.

There is no automatic access to DerivedData or discovery of bundles from logs.
Authorize the actual bundle or your project's result directory explicitly,
including when Xcode uses a custom DerivedData location:

```bash
agentctl mcp artifacts allow-directory "/absolute/project/results/Test-example.xcresult"
```

Xcode 27 can return an incomplete ActionArtifacts bundle lacking `Info.plist`.
If extraction fails for that bundle, obtain the original result bundle path from
Xcode's report or test log, authorize it explicitly, and call this tool with that
path. The tool does not search for or substitute another bundle.

```json
{
  "sourcePath": "/absolute/approved/host/path/Test-example.xcresult",
  "destinationName": "latest-tests",
  "filter": "*.png",
  "onlyFailures": false,
  "overwrite": false
}
```

Omit `filter` to export all retained attachment types. `testId` optionally selects
a test case or suite using an Xcode test identifier string or URL. `onlyFailures`
selects attachments associated with failures; omit it to include passing-test
attachments. Passing tests retain explicitly added XCTest attachments when their
lifetime is `.keepAlways`.

Outputs appear under `.host-artifacts/test-results/latest-tests/`:

```text
attachments/
manifest.json
metadata.json
```

Xcode's suggested readable filenames, including their generated suffixes, are
preserved when they fit the filesystem's 255-byte limit. Longer names have their
stems shortened without splitting Unicode characters; extensions are retained.
Filename collisions after shortening receive a numeric suffix. The original manifest
remains available; normalized metadata associates local files with their tests,
device/configuration, optional repetition/timestamp, and failure status. No UTI
filtering or original-name extraction from activity titles is attempted.

The tool returns output paths and `extractedCount`; it does not return image
bytes or a potentially large attachment manifest in conversation context.
A valid empty export succeeds with a count of zero.

Export requires an Xcode supporting `xcresulttool export attachments`; using
`filter` additionally requires that command's `--filter` option. The selected
Xcode follows the paired definition's resolved `DEVELOPER_DIR`, the host
environment at relay startup, or the normal `xcrun` selection. Unsupported
commands return an actionable error rather than using the old internal parser.

The approved bundle is first copied into private host staging, with source
symlink checks, so the exporter cannot read an escaping link. This requires
additional temporary disk space for the bundle and exported attachments.
Staging is removed after success, failure or cancellation.

### `host_artifacts_status`

Takes no arguments and reports the owning container, destination and effective
permissions. It neither invokes Xcode nor changes grants.

## Transfer and migration

The relay binds every call to its owning container. Calls cannot supply another
container name. The workdir must be a writable host-backed `/workdir` mount in a
running container. Approved bytes are streamed with `container exec -i` to a
managed writer running as `coder`; the host does not write through guest-created
destination paths. The Linux guest writer pins directory descriptors for staging,
publication and rollback, and rejects replaced destination directories detected
before publication. A later pathname replacement cannot redirect these operations
to the substitute directory. `overwrite` defaults to false. If publication and restoration both
fail, the previous artifact is retained in staging and its recovery path appears
in the error.

Existing external `container-sync` registrations and `.xcode-sync` files are
unchanged. To migrate, add `host-artifacts`, inspect its grants, update any tool
instructions to the new tool names and destination, then remove the old managed
`container-sync` definition or manually registered runtime endpoint explicitly.
Do not remove an HTTP bridge that still serves other clients.

Registries written by this version use schema 3, retaining readers for schemas
1 and 2. Older agentctl versions cannot read a schema 3 registry; keep the updated
host checkout when managing containers after a configuration change.

### Updating existing installations

After updating the host checkout, exit any active agent session for the affected
container, then restart the managed bridge with `agentctl restart --name NAME`.
Start a new agent session afterward so it discovers the updated tool list. This change requires no guest-script refresh, image rebuild or
container replacement. Update agent instructions
from `extract_test_attachments` to `extract_xcode_test_attachments`; the former
name and `extract_test_attachments_from_log` are removed.

The automatic DerivedData rule is removed. The generated Xcode grants are
numbered `xcode-1` through `xcode-4`; the last rule now covers ActionArtifacts
result bundles. Existing explicit file and
directory grants remain in effect. The former PapagEye preset no longer grants
access; stored entries are ignored and removed when permissions are next edited.
New definitions and permission commands reject that preset. Configure any needed
application paths through ordinary file or directory grants.
