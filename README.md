# Gluetun DDNS watcher for Dockhand

This sidecar watches an IPv4 DDNS hostname. When its address changes, it updates Gluetun's `WIREGUARD_ENDPOINT_IP` and asks Dockhand to force-redeploy the Gluetun stack. A normal container restart is insufficient because Docker keeps the environment stored in the existing container; force-recreation builds a new container from the changed env file.

The watcher uses `alpine:latest` by default, does not mount the Docker socket, does not expose a port, and gives itself write access only to a dedicated `endpoint.env` file.

## Requirements

- Gluetun is deployed as a Compose stack managed by Dockhand.
- The watcher runs on the Docker host where the Gluetun stack files are stored.
- The watcher can reach Dockhand over a shared Docker network.
- The DDNS hostname has an IPv4 `A` record.
- The Gluetun configuration uses `WIREGUARD_ENDPOINT_IP`.

The watcher supports Dockhand with authentication disabled or enabled. An API token is only needed when authentication is enabled.

## Included files

- `compose.yaml`: the watcher stack.
- `.env.example`: all installation-specific settings.
- `endpoint.env.example`: the one variable the watcher changes.
- `gluetun-compose.example.yaml`: a minimal Gluetun example showing the two env files.
- `.gitignore`: keeps each installation's completed `.env` out of the shared package.
- `LICENSE`: MIT.

## 1. Identify the Dockhand network

List the networks attached to Dockhand:

```bash
sudo docker inspect dockhand \
  --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}'
```

Choose a network that Dockhand is attached to. Set that network as `DOCKHAND_NETWORK`. If the Dockhand container is named `dockhand`, its internal URL is normally:

```text
http://dockhand:3000
```

Set that as `DOCKHAND_URL`.

## 2. Identify the Dockhand environment and stack names

The environment name is shown in Dockhand's environment selector. It must match exactly, including spaces and capitalization.

Find the Compose project name used by the Gluetun container:

```bash
sudo docker inspect gluetun \
  --format '{{index .Config.Labels "com.docker.compose.project"}}'
```

Use that result as `DOCKHAND_STACK`.

Normally you should set `DOCKHAND_ENV_NAME` and leave `DOCKHAND_ENV_ID` empty. The watcher will obtain the numeric ID from Dockhand. If you already know the ID, you can set `DOCKHAND_ENV_ID` instead.

## 3. Find Gluetun's stack directory on the host

First, display the directory that Dockhand used for the Gluetun Compose project:

```bash
sudo docker inspect gluetun \
  --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'
```

Then display Dockhand's host mounts:

```bash
sudo docker inspect dockhand \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

Match the beginning of the project working directory to the mount destination. Replace that destination with its host source.

Example:

```text
Gluetun working directory:
/app/data/stacks/Your Environment/gluetun

Dockhand mount:
/var/lib/docker/volumes/dockhand_dockhand_data/_data -> /app/data

Host stack directory:
/var/lib/docker/volumes/dockhand_dockhand_data/_data/stacks/Your Environment/gluetun
```

The endpoint file for this example is:

```text
/var/lib/docker/volumes/dockhand_dockhand_data/_data/stacks/Your Environment/gluetun/endpoint.env
```

That complete file path becomes `TARGET_ENV_FILE_HOST`.

## 4. Create `endpoint.env`

Resolve the current address of the DDNS hostname:

```bash
getent ahostsv4 vpn-endpoint.example.com | awk 'NR == 1 {print $1}'
```

Create the file in Gluetun's stack directory:

```bash
sudo nano "/absolute/host/path/to/the/gluetun/stack/endpoint.env"
```

Enter the current address:

```dotenv
WIREGUARD_ENDPOINT_IP=203.0.113.10
```

Use the actual result from your hostname, not the example address.

## 5. Update the Gluetun stack

Remove `WIREGUARD_ENDPOINT_IP` from Gluetun's existing `.env`. Keep the private key, public key, port, addresses, and the rest of the Gluetun settings there.

Change the Gluetun service to load both files, with `endpoint.env` second:

```yaml
services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      VPN_SERVICE_PROVIDER: custom
      VPN_TYPE: wireguard
    env_file:
      - .env
      - endpoint.env
    restart: unless-stopped
```

Keep any existing ports, networks, proxy settings, health checks, and other Gluetun options. Deploy the updated Gluetun stack once in Dockhand.

The order matters: when the same variable exists in multiple `env_file` entries, Docker Compose uses the value from the last file.

## 6. Configure the watcher

Copy `.env.example` to `.env` and fill in the values:

```dotenv
SIDECAR_CONTAINER_NAME=gluetun-ddns
WATCHER_IMAGE=alpine:latest
DDNS_HOST=vpn-endpoint.example.com
CHECK_INTERVAL=60
STARTUP_DELAY=15
DEPLOY_TIMEOUT=300
MAX_DEPLOY_BACKOFF=900

TARGET_VARIABLE=WIREGUARD_ENDPOINT_IP
TARGET_ENV_FILE_HOST="/var/lib/docker/volumes/dockhand_dockhand_data/_data/stacks/Your Environment/gluetun/endpoint.env"

DOCKHAND_URL=http://dockhand:3000
DOCKHAND_NETWORK=your_dockhand_network
DOCKHAND_ENV_NAME="Your Environment"
DOCKHAND_ENV_ID=
DOCKHAND_STACK=gluetun
DOCKHAND_TOKEN=
```

Settings that normally change between installations:

- `DDNS_HOST`: the hostname whose IPv4 address should be followed.
- `TARGET_ENV_FILE_HOST`: the absolute host path to `endpoint.env`.
- `DOCKHAND_URL`: Dockhand's address as seen by the watcher.
- `DOCKHAND_NETWORK`: an existing network attached to Dockhand.
- `DOCKHAND_ENV_NAME`: the target environment shown in Dockhand.
- `DOCKHAND_STACK`: the Gluetun Compose project name.
- `TARGET_VARIABLE`: defaults to `WIREGUARD_ENDPOINT_IP`, but can be changed if the target configuration uses another variable name.
- `CHECK_INTERVAL`: seconds between DNS checks.
- `MAX_DEPLOY_BACKOFF`: ceiling, in seconds, for the wait between failed deploy attempts. See "Retry behavior" below.
- `WATCHER_IMAGE`: defaults to `alpine:latest`. Pin it, for example to `alpine:3.24`, if you would rather decide when the base image moves.

`DOCKHAND_STACK` must name the Gluetun stack, not the watcher's own stack. The watcher compares the two and refuses to start if they match, because force-redeploying its own stack would kill it mid-request and repeat forever.

If Dockhand authentication is disabled, leave `DOCKHAND_TOKEN` empty. If authentication is enabled, create a Dockhand API token and place its `dh_...` value there.

## 7. Deploy the watcher in Dockhand

1. Create a new Compose stack in Dockhand named `gluetun-ddns`.
2. Paste the contents of `compose.yaml` into the Compose editor.
3. Paste your completed `.env` into the stack's environment-file editor.
4. Deploy the stack.

The external network selected by `DOCKHAND_NETWORK` must already exist. The stack creates its own egress network and persistent state volume.

## 8. Verify it

Follow the watcher logs:

```bash
sudo docker logs -f gluetun-ddns
```

The first start intentionally force-redeploys the target stack once and records the applied IP. Expected output resembles:

```text
using Dockhand environment 'Your Environment' (id 1)
watcher started; checking vpn-endpoint.example.com every 60s
requesting Dockhand force-redeploy of stack 'gluetun'
{"success":true,"output":" Container gluetun Recreate ..."}
SUCCESS: stack 'gluetun' recreated with WIREGUARD_ENDPOINT_IP=203.0.113.10
no change (203.0.113.10)
```

Confirm that the recreated Gluetun container received the address:

```bash
sudo docker inspect gluetun \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | \
  grep '^WIREGUARD_ENDPOINT_IP='
```

## What happens on each check

1. The watcher resolves the hostname's IPv4 `A` record.
2. It validates the result as an IPv4 address.
3. If the value changed, it updates `TARGET_VARIABLE` in `endpoint.env`.
4. It requests `POST /api/stacks/<stack>/deploy` from Dockhand with `forceRecreate: true`.
5. It records the successful target configuration and address only after Dockhand returns `success: true`.
6. If deployment fails, it schedules a retry using the backoff below.

If several valid `A` records are returned, the watcher consistently selects the first address after sorting them.

## Retry behavior

DNS is polled every `CHECK_INTERVAL` no matter what. Only failed deploy attempts are rate limited.

The first failure waits `CHECK_INTERVAL`, and each further consecutive failure doubles that wait, up to `MAX_DEPLOY_BACKOFF`. With the defaults the gap grows 60s, 120s, 240s, 480s, then holds at 900s. A successful deployment resets it.

A newly resolved address clears the backoff immediately, so a genuine DDNS change is always acted on at the next check rather than waiting out a delay earned by earlier failures.

This matters because the deploy is a force-recreate of the whole Gluetun stack. Without backoff, a Dockhand that is reachable but failing would be asked to tear down and rebuild that stack every single cycle for as long as the fault lasted.

If the watcher cannot install `curl`, `bind-tools` and `jq` at startup, it keeps retrying rather than exiting, since the network it needs may be the one it is about to repair. It stays unhealthy while that is the case, so the condition is visible in `docker ps`.

## Troubleshooting

### `target env file does not exist`

`TARGET_ENV_FILE_HOST` is wrong or `endpoint.env` has not been created. It must be an absolute path on the Docker host.

### `Dockhand environment ... was not found`

Make `DOCKHAND_ENV_NAME` exactly match Dockhand, or set the numeric `DOCKHAND_ENV_ID`.

### `Could not resolve host: dockhand`

The value of `DOCKHAND_NETWORK` is not a network shared with Dockhand, or `DOCKHAND_URL` uses the wrong container name.

### Dockhand returns `401` or `403`

Authentication is enabled. Set `DOCKHAND_TOKEN` to a valid API token.

### Dockhand returns only a `jobId`

The request is missing `Accept: application/json`. The included Compose file already sends it; replace older versions of the watcher with this one.

### The file changes but Gluetun still has the old value

Verify that Gluetun loads `endpoint.env` after its main `.env`, then confirm that `TARGET_ENV_FILE_HOST` points to that exact file.

### The watcher repeatedly reports DNS failure

Confirm that the hostname has an IPv4 `A` record:

```bash
getent ahostsv4 your-hostname.example.com | awk 'NR == 1 {print $1}'
```

## Stack-layout note

Dockhand force-redeploys the complete stack named by `DOCKHAND_STACK`. If that stack contains Gluetun plus other services, those services are recreated too. Containers in another stack that use `network_mode: container:gluetun` can retain a reference to the old Gluetun container, so place network-namespace-dependent services in the same Compose stack.

## Updating the watcher

Redeploy the watcher stack with image pulling enabled whenever you want it to pull the current `alpine:latest` image. Its state volume survives recreation, so an ordinary watcher update does not force an unnecessary Gluetun deployment.

## Sharing it

Publish the files in this directory as a repository or archive. Keep `.env.example` filled with placeholders and let each user copy it to `.env`. The same Compose file then works across different DDNS hostnames, Dockhand environments, networks, stack names, paths, and target variable names.

## License

MIT. See [LICENSE](LICENSE).
