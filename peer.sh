#!/bin/bash
# Manage peers (VPN users) of the running server. Changes apply live, nobody gets disconnected.
#
#   peer list
#   peer add <name>       create a peer, print its client config
#   peer show <name>      print the client config again (rebuilt with the current server params)
#   peer qr <name>        same as a QR code, for the Amnezia app on a phone
#   peer remove <name>
#
# Peers are [Peer] sections in /data/awg0.conf, named by a "# Name = <name>" line.
# Client private keys are kept in /data/clients/<name>.conf so configs can be exported again.
set -euo pipefail

CONF=/data/awg0.conf
CLIENTS=/data/clients

die() { echo "error: $*" >&2; exit 1; }

[[ -f $CONF ]] || die "$CONF not found, is the server running?"
umask 077
mkdir -p "$CLIENTS"

apply() { awg syncconf awg0 <(awg-quick strip "$CONF"); }

# Overwrite in place (keeps owner and mode).
save() { local tmp; tmp=$(mktemp); cat > "$tmp"; cat "$tmp" > "$1"; rm -f "$tmp"; }

check_name() { [[ ${1:-} =~ ^[A-Za-z0-9._-]+$ ]] || die "name must match [A-Za-z0-9._-]+ (got '${1:-}')"; }

# Value of <key> in the [Interface] section (first match).
iface_value() { awk -v k="$1" '/^\[Peer\]/ { exit } $1 == k && $2 == "=" { sub(/^[^=]*= */, ""); print; exit }' "$CONF"; }

# Value of <key> in the [Peer] section named <name>.
peer_value() {
  awk -v n="$1" -v k="$2" '
    /^\[/ { inp = ($0 == "[Peer]"); found = 0 }
    inp && $0 == "# Name = " n { found = 1 }
    inp && found && $1 == k && $2 == "=" { sub(/^[^=]*= */, ""); print; exit }' "$CONF"
}

peer_exists() { grep -qxF "# Name = $1" "$CONF"; }

# Highest peer address + 1, skipping the server's own address.
next_ip() {
  local srv base max next
  srv=$(iface_value Address); srv=${srv%%/*}; base=${srv%.*}
  max=$(awk -v base="$base" '$1 == "AllowedIPs" {
      split($3, a, "/"); n = split(a[1], o, ".")
      if (n == 4 && o[1] "." o[2] "." o[3] == base && o[4] + 0 > max) max = o[4] + 0
    } END { print max + 0 }' "$CONF")
  next=$((max + 1))
  [[ "$base.$next" == "$srv" ]] && next=$((next + 1))
  [[ $next -le 254 ]] || die "no free addresses left in $base.0/24"
  echo "$base.$next"
}

# Client-side params = the server's [Interface] minus its own identity.
client_params() {
  awk '/^\[Peer\]/ { exit }
       /^[A-Za-z0-9]+ = / && $1 != "PrivateKey" && $1 != "Address" && $1 != "ListenPort" { print }' "$CONF"
}

client_config() { # <name> <client private key>
  local name=$1 priv=$2
  [[ -n "${AWG_ENDPOINT:-}" ]] || die "AWG_ENDPOINT is not set (.env)"
  cat <<EOF
[Interface]
PrivateKey = $priv
Address = $(peer_value "$name" AllowedIPs)
DNS = ${AWG_CLIENT_DNS:-1.1.1.1, 1.0.0.1}
MTU = ${AWG_CLIENT_MTU:-1280}
$(client_params)

[Peer]
PublicKey = $(awg pubkey <<<"$(iface_value PrivateKey)")
PresharedKey = $(peer_value "$name" PresharedKey)
AllowedIPs = ${AWG_CLIENT_ALLOWED_IPS:-0.0.0.0/0, ::/0}
Endpoint = $AWG_ENDPOINT:$(iface_value ListenPort)
PersistentKeepalive = ${AWG_CLIENT_PERSISTENT_KEEPALIVE:-25-35}
EOF
}

# Rebuild the stored client config from its private key and the current server params.
export_config() {
  local name=$1 file=$CLIENTS/$1.conf priv
  peer_exists "$name" || die "no such peer: $name"
  [[ -f $file ]] || die "$file not found: the client private key of '$name' is not stored here"
  priv=$(awk '$1 == "PrivateKey" { print $3; exit }' "$file")
  client_config "$name" "$priv" | save "$file"
  cat "$file"
}

cmd_add() {
  local name=${1:-} priv
  check_name "$name"
  peer_exists "$name" && die "peer '$name' already exists"
  priv=$(awg genkey)
  printf '\n[Peer]\n# Name = %s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
    "$name" "$(awg pubkey <<<"$priv")" "$(awg genpsk)" "$(next_ip)" >> "$CONF"
  apply
  client_config "$name" "$priv" > "$CLIENTS/$name.conf"
  cat "$CLIENTS/$name.conf"
  echo "added '$name' ($(peer_value "$name" AllowedIPs))" >&2
}

cmd_remove() {
  local name=${1:-}
  check_name "$name"
  peer_exists "$name" || die "no such peer: $name"
  awk -v n="$name" '
    function flush() { if (!drop) printf "%s", blk; blk = ""; drop = 0 }
    /^\[/ { flush() }
    { blk = blk $0 "\n"; if ($0 == "# Name = " n) drop = 1 }
    END { flush() }' "$CONF" | save "$CONF"
  apply
  rm -f "$CLIENTS/$name.conf"
  echo "removed '$name'" >&2
}

cmd_list() {
  local names; names=$(mktemp)
  awk '/^\[/ { n = "" } $1 == "#" && $2 == "Name" { n = $4 } $1 == "PublicKey" && n != "" { print $3 "\t" n }' \
    "$CONF" > "$names"
  printf "%-20s %-16s %-11s %-11s %-11s %s\n" NAME IP HANDSHAKE RX TX ENDPOINT
  awg show awg0 dump | awk -F'\t' -v now="$(date +%s)" -v names="$names" '
    function human(b) { split("B KiB MiB GiB TiB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } return sprintf("%.1f %s", b, u[i]) }
    function ago(t) { if (t == 0) return "never"; d = now - t
      if (d < 120) return d "s ago"; if (d < 7200) return int(d / 60) "m ago"
      if (d < 172800) return int(d / 3600) "h ago"; return int(d / 86400) "d ago" }
    FILENAME == names { nm[$1] = $2; next }
    FNR > 1 { split($4, a, "[./]")
      printf "%03d%03d%03d%03d %-20s %-16s %-11s %-11s %-11s %s\n", a[1], a[2], a[3], a[4],
        ($1 in nm ? nm[$1] : "?"), $4, ago($5), human($6), human($7), $3 }' "$names" - | sort | cut -d' ' -f2-
  rm -f "$names"
}

case "${1:-}" in
  add) cmd_add "${2:-}" ;;
  show) check_name "${2:-}"; export_config "$2" ;;
  qr) check_name "${2:-}"; export_config "$2" | qrencode -t ansiutf8 ;;
  remove|rm) cmd_remove "${2:-}" ;;
  list|ls) cmd_list ;;
  *) echo "usage: peer {list | add <name> | show <name> | qr <name> | remove <name>}" >&2; exit 2 ;;
esac
