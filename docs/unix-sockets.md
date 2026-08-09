# Unix-socket forwarding

Agentctl can connect containers to services exposed through Unix sockets in
either direction:

- `--mount-socket` makes a host service available inside a container.
- `--publish-socket` makes a container service available on the host.

Socket forwarding grants access to the authority of the service behind the
socket. Use narrowly scoped services, private paths, and permissions suitable
for the non-root `coder` user inside the container.

## Mount a host socket in a container

Mount a host Unix socket when creating a container:

```bash
agentctl run --mount-socket /tmp/my-service.sock:/run/host-services/my-service.sock
```

`--mount-socket` is repeatable and is also available to `bootstrap` and
`upgrade`. Use stable, absolute socket paths: agentctl stores the literal host
path and does not rediscover a moved socket.

An existing container must exactly match mappings requested by `run` or
`bootstrap`. Use `upgrade` to add, replace, or remove mappings:

```bash
agentctl upgrade --name agent-my-project \
  --mount-socket /tmp/new.sock:/run/host-services/service.sock
agentctl upgrade --name agent-my-project \
  --unmount-socket /run/host-services/service.sock
```

Upgrade preserves mappings by default, including in `--copy` mode. A missing
preserved source is fatal until restored, replaced, or explicitly unmounted.

Access to a mounted socket grants the container the service's effective
authority. Only mount sockets whose access is appropriate for code running as
`coder`.

## Publish a container socket on the host

Create a private host directory, then publish a service running inside the
container:

```bash
mkdir -m 700 "$HOME/.agentctl-sockets"
agentctl run \
  --publish-socket "$HOME/.agentctl-sockets/service.sock:/run/service.sock"
```

`--publish-socket` is repeatable and is also available to `bootstrap` and
`upgrade`. The parent directory must already be canonical, owned by you,
writable and searchable by you, and inaccessible to group and other users. The
host destination must not already exist.

Agentctl never creates the parent directory or deletes socket paths, including
stale listeners left by the container runtime. Existing containers must
exactly match mappings requested by `run` or `bootstrap`.

Upgrade preserves mappings and merges replacements by host path:

```bash
agentctl upgrade --name agent-my-project \
  --publish-socket "$HOME/.agentctl-sockets/second.sock:/run/service.sock"
agentctl upgrade --name agent-my-project \
  --unpublish-socket "$HOME/.agentctl-sockets/service.sock"
```

Multiple private host paths may intentionally publish the same container
service. Published services and authentication are the user's responsibility.

## Related documentation

- [Managed host MCP bridge](managed-mcp.md)
- [Networking and Ollama connectivity](networking.md)
