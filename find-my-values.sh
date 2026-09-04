#!/bin/sh
# Works out the values you need for the gluetun-ddns watcher .env
# and prints them ready to paste. Reads only; changes nothing.
# https://github.com/ilariima/Alpine-gluetun-ddns

# If your containers are named differently, change these two:
GLUETUN=gluetun; DOCKHAND=dockhand

WD=$(sudo docker inspect "$GLUETUN" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
PROJ=$(sudo docker inspect "$GLUETUN" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
NETS=$(sudo docker inspect "$DOCKHAND" --format '{{range $n, $_ := .NetworkSettings.Networks}}{{println $n}}{{end}}' 2>/dev/null | grep -v '^$')
NET=$(printf '%s\n' "$NETS" | grep -v 'socket-proxy' | head -n 1); [ -n "$NET" ] || NET=$(printf '%s\n' "$NETS" | head -n 1)
OTHER=$(printf '%s\n' "$NETS" | grep -v "^${NET}$" | tr '\n' ' ')

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
  cat <<OUT


==============================================================
  PASTE THIS into the watcher stack's environment editor
==============================================================

DDNS_HOST=CHANGE_ME.example.com
GLUETUN_STACK_DIR_HOST="$DIR"
DOCKHAND_STACK=$PROJ
DOCKHAND_NETWORK=$NET
DOCKHAND_ENV_NAME="CHANGE_ME"

--------------------------------------------------------------
  [ok]   found the Gluetun .env
  $CHK
  [note] other Dockhand networks: ${OTHER:-none}

  Now replace the two CHANGE_ME values:
    DDNS_HOST          your DDNS hostname
    DOCKHAND_ENV_NAME  the name in Dockhand's environment menu
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

  Fix the names on the first line to match your containers,
  then run it again. List them with:  sudo docker ps --format '{{.Names}}'
==============================================================

OUT
fi
