# Gluetun DDNS watcher for Dockhand

If your VPN endpoint is on a dynamic address, Gluetun's `WIREGUARD_ENDPOINT_IP` goes stale and the tunnel dies. This watches your DDNS hostname and, when the address changes, updates Gluetun's `.env` and tells Dockhand to redeploy Gluetun.

Setup is: run one command, paste two things into Dockhand, done. You do not change your Gluetun stack and you do not create any files.

## Before you start

You need these already working:

- **Dockhand**, running and managing your stacks
- **Gluetun**, already deployed as a Dockhand stack and connecting fine
- Gluetun using a **custom WireGuard provider**, so its `.env` has `WIREGUARD_ENDPOINT_IP`
- A **DDNS hostname with an IPv4 A record**
- **Shell access to the Docker host** for step 1

If your containers are not named `gluetun` and `dockhand`, change the first line of the command in step 1.

---

## Step 1 — Run this on your Docker host

```bash
curl -fsSLO https://raw.githubusercontent.com/ilariima/Alpine-gluetun-ddns/main/find-my-values.sh
sh find-my-values.sh
```

It only reads: two `docker inspect` calls and a check that the file it found exists. Read it first with `cat find-my-values.sh` if you like.

It prints your `.env`, ready to paste:

```text
==============================================================
  PASTE THIS into the watcher stack's environment editor
==============================================================

DDNS_HOST=CHANGE_ME.example.com
GLUETUN_STACK_DIR_HOST="/var/lib/docker/volumes/dockhand_dockhand_data/_data/stacks/Your Environment/gluetun"
DOCKHAND_STACK=gluetun
DOCKHAND_NETWORK=your_dockhand_network
DOCKHAND_ENV_NAME="Your Environment"

--------------------------------------------------------------
  [ok]   found the Gluetun .env
  [ok]   WIREGUARD_ENDPOINT_IP is already set in it
  [ok]   environment name read from the stack path
  [note] other Dockhand networks: dockhand_socket-proxy

  Only DDNS_HOST is left. Replace CHANGE_ME.example.com with the
  DDNS hostname that follows your VPN endpoint. Nothing on this
  host knows it, so it is the one value you have to supply.

  If Dockhand has authentication turned on, also add a line:
    DOCKHAND_TOKEN=dh_your_token_here
==============================================================
```

Three `[ok]` lines means everything it worked out is good. If it says **COULD NOT WORK IT OUT**, your containers are named something other than `gluetun` and `dockhand` — edit the two names at the top of the script and run it again.

Dockhand is usually on more than one network. The script skips its `socket-proxy` network, since the watcher has no business reaching a Docker socket proxy, and picks a normal one instead. Others are listed if you want a different one.

<details>
<summary>Prefer not to download anything? Paste this instead.</summary>

```bash
# If your containers are named differently, change these two:
GLUETUN=gluetun; DOCKHAND=dockhand

WD=$(sudo docker inspect "$GLUETUN" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
PROJ=$(sudo docker inspect "$GLUETUN" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
NETS=$(sudo docker inspect "$DOCKHAND" --format '{{range $n, $_ := .NetworkSettings.Networks}}{{println $n}}{{end}}' 2>/dev/null | grep -v '^$')
NET=$(printf '%s\n' "$NETS" | grep -v 'socket-proxy' | head -n 1); [ -n "$NET" ] || NET=$(printf '%s\n' "$NETS" | head -n 1)
OTHER=$(printf '%s\n' "$NETS" | grep -v "^${NET}$" | tr '\n' ' ')


# Dockhand stores stacks as .../stacks/<environment>/<stack>, so the
# environment name is the directory above the stack directory.
ENVNAME=$(basename "$(dirname "$WD")" 2>/dev/null)
case "$ENVNAME" in stacks|/|.|'') ENVNAME="" ;; esac

DIR=""; B=0
while IFS='|' read -r d s; do
  [ -n "$d" ] || continue
  case "$WD" in "$d"/*|"$d") [ "${#d}" -gt "$B" ] && { B=${#d}; DIR="${s}${WD#"$d"}"; } ;; esac
done <<EOF
$(sudo docker inspect "$DOCKHAND" --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
EOF

if [ -n "$DIR" ] && sudo test -f "$DIR/.env"; then
  sudo grep -q '^WIREGUARD_ENDPOINT_IP=' "$DIR/.env" \
    && CHK="[ok]   WIREGUARD_ENDPOINT_IP is already set in it" \
    || CHK="[note] WIREGUARD_ENDPOINT_IP not set yet; the watcher will add it"
  if [ -n "$ENVNAME" ]; then
    ENVLINE="DOCKHAND_ENV_NAME=\"$ENVNAME\""
    ENVCHK="[ok]   environment name read from the stack path"
  else
    ENVLINE='DOCKHAND_ENV_NAME="CHANGE_ME"'
    ENVCHK="[!]    could not read the environment name; copy it from Dockhand's menu"
  fi
  cat <<OUT


==============================================================
  PASTE THIS into the watcher stack's environment editor
==============================================================

DDNS_HOST=CHANGE_ME.example.com
GLUETUN_STACK_DIR_HOST="$DIR"
DOCKHAND_STACK=$PROJ
DOCKHAND_NETWORK=$NET
$ENVLINE
--------------------------------------------------------------
  [ok]   found the Gluetun .env
  $CHK
  $ENVCHK
  [note] other Dockhand networks: ${OTHER:-none}

  Only DDNS_HOST is left. Replace CHANGE_ME.example.com with the
  DDNS hostname that follows your VPN endpoint. Nothing on this
  host knows it, so it is the one value you have to supply.

  If Dockhand has authentication turned on, also add a line:
    DOCKHAND_TOKEN=dh_your_token_here
==============================================================

OUT
else
  cat <<OUT


==============================================================
  COULD NOT WORK IT OUT
==============================================================

  container names tried : GLUETUN=$GLUETUN  DOCKHAND=$DOCKHAND
  gluetun working dir   : ${WD:-<gluetun container not found>}
  resolved host dir     : ${DIR:-<no matching Dockhand mount>}

  Fix the names at the top of this script to match your
  containers, then run it again. List them with:
    sudo docker ps --format '{{.Names}}'
==============================================================

OUT
fi
```

</details>

---

## Step 2 — Fill in DDNS_HOST

Replace `CHANGE_ME.example.com` with the DDNS hostname that follows your VPN endpoint.

That is the only value the script cannot work out, because nothing on the host knows it. If it also printed `DOCKHAND_ENV_NAME="CHANGE_ME"`, copy that one from Dockhand's environment menu too.

You now have your whole `.env`.

---

## Step 3 — Create the stack in Dockhand

1. **New Compose stack.** Name it `gluetun-ddns`. It must not have the same name as your Gluetun stack, or the watcher will refuse to start.
2. **Compose editor:** paste all of [`compose.yaml`](compose.yaml), unchanged.
3. **Environment editor:** paste the five lines from step 1, with `DDNS_HOST` filled in.
4. **Deploy.**

That is the entire `.env`. Everything else has a working default, listed under [Optional settings](#optional-settings).

If Dockhand has authentication turned on, add one more line:

```dotenv
DOCKHAND_TOKEN=dh_your_token_here
```

**Already running an older version of this watcher?** Remove that stack first. Two watchers editing the same file will both force-redeploy Gluetun.

---

## Step 4 — Check it worked

```bash
sudo docker logs -f gluetun-ddns
```

You should see it redeploy Gluetun once, then go quiet:

```text
using Dockhand environment 'Your Environment' (id 1)
watcher started; checking vpn-endpoint.example.com every 60s
editing WIREGUARD_ENDPOINT_IP in /target/.env
DDNS changed: 203.0.113.9 -> 203.0.113.10
requesting Dockhand force-redeploy of stack 'gluetun'
SUCCESS: stack 'gluetun' recreated with WIREGUARD_ENDPOINT_IP=203.0.113.10
no change (203.0.113.10)
```

`no change` every 60 seconds means it is working. Confirm Gluetun actually got the address:

```bash
sudo docker inspect gluetun --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^WIREGUARD_ENDPOINT_IP='
```

That's it. You're done.

---

## If something goes wrong

| Log message | What to do |
| --- | --- |
| `env file does not exist` | `GLUETUN_STACK_DIR_HOST` is wrong. Re-run step 1 and use its exact output, quotes included. |
| Step 1 says `COULD NOT WORK IT OUT` | Your containers are not named `gluetun` and `dockhand`. Edit the two names at the top of the script and run it again. |
| `the stack directory /target is not writable` | The watcher replaces the file by rename, so it needs write access to the directory, not just the file. |
| `Dockhand environment ... was not found` | `DOCKHAND_ENV_NAME` must match Dockhand exactly, including spaces and capitals. |
| `Could not resolve host: dockhand` | `DOCKHAND_NETWORK` is not a network Dockhand is on, or your Dockhand container is not named `dockhand`. |
| `401` or `403` | Dockhand authentication is on. Add `DOCKHAND_TOKEN`. |
| `which is this watcher's own stack` | `DOCKHAND_STACK` is naming the watcher instead of Gluetun. |
| `IPv4 DNS resolution failed` | Your hostname has no A record. Check with `sudo docker run --rm alpine sh -c 'apk add -q bind-tools && dig +short A your-host.example.com'` |
| File changes but Gluetun keeps the old value | The redeploy failed. Look further up the log, and check `DOCKHAND_STACK`. |

---

## Optional settings

Only add these if you want to change something. All have defaults, and a 5-line `.env` is a complete, working configuration — the defaults are preferences, not blanks you must fill.

[`.env.example`](.env.example) has all of these written out with comments, if you would rather start from a file than this table.

The one to know about is `DOCKHAND_TOKEN`: it is empty by default, which is correct only if Dockhand authentication is off. With it on you get `401` in the log and just add the token.

`DOCKHAND_URL` is `http://dockhand:3000`, which is right for a normal Dockhand install. The rest only change timing, naming, or which variable is edited.

| Variable | Default | What it does |
| --- | --- | --- |
| `CHECK_INTERVAL` | `60` | Seconds between DNS checks |
| `DOCKHAND_URL` | `http://dockhand:3000` | Where Dockhand is, from inside the container |
| `DOCKHAND_TOKEN` | empty | Only if Dockhand authentication is on |
| `DOCKHAND_ENV_ID` | empty | Numeric id instead of the name |
| `TARGET_VARIABLE` | `WIREGUARD_ENDPOINT_IP` | The variable to keep updated |
| `TARGET_ENV_FILENAME` | `.env` | Which file in the stack directory to edit |
| `STARTUP_DELAY` | `15` | Seconds to wait before the first check |
| `DEPLOY_TIMEOUT` | `300` | Seconds allowed for one deploy |
| `MAX_DEPLOY_BACKOFF` | `900` | Longest wait between failed deploys |
| `SIDECAR_CONTAINER_NAME` | `gluetun-ddns` | Container name |
| `WATCHER_IMAGE` | `alpine:latest` | Pin it if you prefer |

---

## Optional: keep the watcher away from your keys

Everything above mounts the Gluetun stack directory read-write, so the watcher **can** write to the folder holding your WireGuard private key. It only ever rewrites one variable, but the access is real.

If you would rather it could not reach your keys at all, give it a second env file holding nothing but the endpoint. This costs you a small edit to the Gluetun stack, which is the thing the main guide avoids.

**1.** In your Gluetun stack directory, create `endpoint.env` with the current address:

```dotenv
WIREGUARD_ENDPOINT_IP=203.0.113.10
```

**2.** Remove `WIREGUARD_ENDPOINT_IP` from Gluetun's main `.env`. Leave everything else.

**3.** In the Gluetun stack's compose file, load both files, `endpoint.env` **second**:

```yaml
    env_file:
      - .env
      - endpoint.env
```

Order matters. When the same variable is in two `env_file` entries, Compose keeps the value from the last one.

**4.** Redeploy the Gluetun stack once.

**5.** Add this to the watcher's `.env` and redeploy the watcher:

```dotenv
TARGET_ENV_FILENAME=endpoint.env
```

The watcher now only ever rewrites `endpoint.env`. Your private key stays in `.env`, which the watcher never touches.

---

## What it actually does

Every `CHECK_INTERVAL` seconds it resolves your hostname, checks the result is a real IPv4 address, and compares it to the file. If it changed, it rewrites that one line, reads it back to confirm, then asks Dockhand to force-recreate the Gluetun stack. A plain restart is not enough, because Docker keeps the environment baked into the existing container.

It records what it applied, so restarting or updating the watcher does not trigger a pointless Gluetun redeploy.

If a deploy fails it backs off: 60s, then 120s, 240s, 480s, up to 15 minutes, so a Dockhand problem cannot mean recreating your VPN stack every minute for hours. DNS keeps being checked the whole time, and a genuinely new address retries immediately.

It edits the file by writing a copy alongside and renaming it into place, keeping the owner and permissions, so the file is never half-written. It mounts the stack **directory** rather than the single file, because a single-file mount breaks permanently the moment anything replaces the file, and Dockhand rewrites a stack's `.env` whenever you edit it in the UI.

**One caveat:** Dockhand recreates the whole stack named by `DOCKHAND_STACK`. If other services share that stack, they are recreated too. Anything using `network_mode: container:gluetun` should live in the same stack.

## License

MIT. See [LICENSE](LICENSE).
