# Gluetun DDNS watcher for Dockhand

Gluetun's `WIREGUARD_ENDPOINT_IP` is a fixed address. If your VPN endpoint is behind a dynamic address, the tunnel breaks whenever that address changes.

This is a small sidecar that watches an IPv4 DDNS hostname, writes the new address into the Gluetun stack's own `.env`, and asks Dockhand to force-redeploy the Gluetun stack. Restarting the container is not enough: Docker keeps the environment baked into the existing container, so only a force-recreate picks up the changed file.

Setup is two pastes and a fill-in-the-blanks. You do not edit the Gluetun stack, and you do not create any files by hand.

## What this guide assumes

This builds on a working setup. It is not a from-scratch VPN guide. You need all of the following already in place:

- **Dockhand** is already running and managing your stacks. This is the whole mechanism the watcher uses; there is no Docker socket and no fallback. Dockhand's API docs: <https://dockhand.pro/manual/>
- **Gluetun is already deployed as a Dockhand-managed Compose stack** and working. If the tunnel has never come up, fix that first.
- **Gluetun uses a custom WireGuard provider** with `WIREGUARD_ENDPOINT_IP` set in that stack's `.env`. Providers configured by server name or country do not use this variable and do not need this watcher.
- **The Gluetun stack's files live on the same Docker host** the watcher runs on, in a directory you can bind-mount.
- **Your DDNS hostname has an IPv4 `A` record.** IPv6-only or CNAME-only will not work.
- **Shell access to the Docker host**, for the read-only commands in step 1. That is the only terminal work; nothing in this guide asks you to create or edit a file from a shell.
- Dockhand authentication may be on or off. A token is only needed when it is on.

## What it does not need

- No changes to your Gluetun stack, its compose file, or its `env_file` list
- No files created or edited by hand
- No Docker socket and no socket proxy
- No exposed ports
- No image to build; it runs stock `alpine:latest`

## How it works

The watcher bind-mounts the Gluetun stack **directory** and edits one variable in the stack's `.env`, leaving every other line, including your WireGuard keys, exactly as it found them. The file is rewritten beside the original and renamed into place, so it is never observed half-written and its owner and permissions are preserved.

The directory is mounted rather than the single file on purpose. A single-file bind mount is severed the moment anything replaces the file on the host, and Dockhand rewrites a stack's `.env` whenever you edit it in the UI. Mounting the directory means the watcher keeps working across that.

## 1. Collect the values

These commands only read. Run them on the Docker host.

**The Gluetun stack directory.** First ask Gluetun where its project lives:

```bash
sudo docker inspect gluetun --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'
```

That path is inside the Dockhand container, so translate it to a host path using Dockhand's mounts:

```bash
sudo docker inspect dockhand --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

Match the start of the working directory to a mount destination and swap in its source. For example:

```text
Gluetun working directory (inside Dockhand):
/app/data/stacks/Your Environment/gluetun

Dockhand mount:
/var/lib/docker/volumes/dockhand_dockhand_data/_data -> /app/data

Host directory (this is GLUETUN_STACK_DIR_HOST):
/var/lib/docker/volumes/dockhand_dockhand_data/_data/stacks/Your Environment/gluetun
```

Confirm the stack's `.env` is really there, and that it has the variable:

```bash
sudo grep -c '^WIREGUARD_ENDPOINT_IP=' "/your/host/path/to/the/gluetun/stack/.env"
```

`1` means you are in the right place. `0` means the file exists but the variable is absent; the watcher will add it. An error means the path is wrong.

**The Gluetun stack name**, for `DOCKHAND_STACK`:

```bash
sudo docker inspect gluetun --format '{{index .Config.Labels "com.docker.compose.project"}}'
```

**A network Dockhand is attached to**, for `DOCKHAND_NETWORK`:

```bash
sudo docker inspect dockhand --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}'
```

**The environment name**, for `DOCKHAND_ENV_NAME`, is the one shown in Dockhand's environment selector. It must match exactly, including spaces and capitalization.

**The Dockhand URL** is normally `http://dockhand:3000` when the container is named `dockhand`.

## 2. Create the stack in Dockhand

1. Create a new Compose stack. Name it something other than your Gluetun stack; `gluetun-ddns` is fine. The watcher refuses to start if you point it at itself.
2. Paste [`compose.yaml`](compose.yaml) into the Compose editor, unchanged.
3. Paste [`.env.example`](.env.example) into the stack's environment-file editor.
4. Fill in the values from step 1. The two you must change are `DDNS_HOST` and `GLUETUN_STACK_DIR_HOST`.
5. Deploy.

The network named by `DOCKHAND_NETWORK` must already exist. The stack brings its own egress network and state volume.

## 3. Verify

```bash
sudo docker logs -f gluetun-ddns
```

The first start force-redeploys the Gluetun stack once and records what it applied. Expected output:

```text
using Dockhand environment 'Your Environment' (id 1)
watcher started; checking vpn-endpoint.example.com every 60s
editing WIREGUARD_ENDPOINT_IP in /target/.env
DDNS changed: 203.0.113.9 -> 203.0.113.10
WIREGUARD_ENDPOINT_IP updated to 203.0.113.10
requesting Dockhand force-redeploy of stack 'gluetun'
{"success":true,"output":" Container gluetun Recreate ..."}
SUCCESS: stack 'gluetun' recreated with WIREGUARD_ENDPOINT_IP=203.0.113.10
no change (203.0.113.10)
```

Confirm the recreated container actually received it:

```bash
sudo docker inspect gluetun --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^WIREGUARD_ENDPOINT_IP='
```

## What happens on each check

1. Resolve the hostname's IPv4 `A` record.
2. Validate the result is a real IPv4 address; reject anything else.
3. If it differs from the file, rewrite that one variable in the stack's `.env` and read it back to confirm.
4. `POST /api/stacks/<stack>/deploy` to Dockhand with `forceRecreate: true`.
5. Record the applied address and target only after Dockhand returns `success: true`.
6. On failure, schedule a retry using the backoff below.

If several valid `A` records come back, the watcher sorts them and always takes the first, so the choice is stable rather than following resolver rotation.

## Retry behavior

DNS is polled every `CHECK_INTERVAL` no matter what. Only failed deploy attempts are rate limited.

The first failure waits `CHECK_INTERVAL`, and each further consecutive failure doubles it, up to `MAX_DEPLOY_BACKOFF`. With the defaults the gap grows 60s, 120s, 240s, 480s, then holds at 900s. Success resets it, and a newly resolved address clears it immediately, so a real DDNS change is never delayed by earlier failures.

This matters because the deploy force-recreates the whole Gluetun stack. Without backoff, a Dockhand that is reachable but failing would be asked to tear down and rebuild that stack every cycle for as long as the fault lasted.

If the watcher cannot install `curl`, `bind-tools` and `jq` at startup, it retries instead of exiting, since the network it needs may be the one it is about to repair. It reports unhealthy while that is the case.

## Settings

Only `DDNS_HOST` and `GLUETUN_STACK_DIR_HOST` normally need changing. Everything else has a working default.

| Variable | Default | Purpose |
| --- | --- | --- |
| `DDNS_HOST` | — | Hostname whose IPv4 address is followed |
| `GLUETUN_STACK_DIR_HOST` | — | Host path to the Gluetun stack directory |
| `DOCKHAND_URL` | `http://dockhand:3000` | Dockhand as seen from the watcher |
| `DOCKHAND_NETWORK` | — | An existing network Dockhand is on |
| `DOCKHAND_ENV_NAME` | — | Environment name shown in Dockhand |
| `DOCKHAND_ENV_ID` | empty | Numeric id; wins over the name if set |
| `DOCKHAND_STACK` | — | Compose project name of the Gluetun stack |
| `DOCKHAND_TOKEN` | empty | Only if Dockhand authentication is on |
| `TARGET_VARIABLE` | `WIREGUARD_ENDPOINT_IP` | The variable to rewrite |
| `TARGET_ENV_FILENAME` | `.env` | The file inside the stack directory to edit |
| `CHECK_INTERVAL` | `60` | Seconds between DNS checks |
| `STARTUP_DELAY` | `15` | Seconds before the first check |
| `DEPLOY_TIMEOUT` | `300` | Seconds allowed for one deploy request |
| `MAX_DEPLOY_BACKOFF` | `900` | Ceiling on the wait between failed deploys |
| `SIDECAR_CONTAINER_NAME` | `gluetun-ddns` | Watcher container name |
| `WATCHER_IMAGE` | `alpine:latest` | Pin it if you prefer |

## Troubleshooting

### `env file does not exist`

`GLUETUN_STACK_DIR_HOST` is wrong. It must be the absolute host path to the directory containing the Gluetun stack's `.env`, not a path inside the Dockhand container. Re-run the translation in step 1.

### `the stack directory /target is not writable`

The watcher replaces the env file by rename, so it needs write permission on the directory, not just the file.

### `Dockhand environment ... was not found`

`DOCKHAND_ENV_NAME` must match Dockhand exactly, including spaces and capitalization. Or set the numeric `DOCKHAND_ENV_ID` instead.

### `Could not resolve host: dockhand`

`DOCKHAND_NETWORK` is not a network shared with Dockhand, or `DOCKHAND_URL` names the wrong container.

### Dockhand returns `401` or `403`

Authentication is enabled. Set `DOCKHAND_TOKEN` to a valid API token.

### `which is this watcher's own stack`

`DOCKHAND_STACK` names the watcher's own Dockhand stack. It must name the Gluetun stack.

### The file changes but Gluetun still has the old value

The stack was not actually recreated. Check the logs for a failed deploy, and confirm `DOCKHAND_STACK` is the Gluetun project name from step 1.

### Repeated DNS failures

Confirm the hostname really has an IPv4 `A` record:

```bash
sudo docker run --rm alpine:latest sh -c 'apk add -q bind-tools && dig +short A your-hostname.example.com'
```

## Notes and limits

**The whole stack is recreated.** Dockhand force-redeploys the stack named by `DOCKHAND_STACK`. If that stack holds Gluetun plus other services, those are recreated too.

**Services in other stacks using `network_mode: container:gluetun`** will hold a reference to the destroyed container. Keep network-namespace-dependent services in the same Compose stack as Gluetun.

**The watcher can write to the Gluetun stack directory.** That is the cost of not modifying your Gluetun stack: the mount is read-write, so the directory holding your WireGuard keys is writable by this container. The script only ever touches the one variable in the one file, and the rename is atomic, but the access is real. If you would rather it not have that reach, point `TARGET_ENV_FILENAME` at a second env file that holds only the endpoint variable and add that file to Gluetun's `env_file` list after `.env` — at the cost of the stack edit this guide otherwise avoids.

**Editing the Gluetun stack in Dockhand** rewrites its `.env` and can revert the endpoint address. The watcher notices on its next check and re-applies it.

**Updating the watcher** is an ordinary redeploy. Its state volume survives, so a routine update does not trigger an unnecessary Gluetun deployment.

## License

MIT. See [LICENSE](LICENSE).
