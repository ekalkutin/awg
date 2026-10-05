#!/bin/bash
# AmneziaWG 3.1 server. All state lives in /data (mount it):
#
#   /data/awg0.conf          server keys, obfuscation params and all peers
#   /data/clients/<name>.conf  client configs, see "peer"
#
# First start without /data/awg0.conf generates a new server (keys + params). Later starts
# only take ListenPort from AWG_PORT, everything else is read from the file as is.
#
#   serve           (default) bring awg0 up, NAT, wait
#   anything else   exec'd as is (e.g. "peer list")
set -euo pipefail

CONF=/data/awg0.conf

die() { echo "error: $*" >&2; exit 1; }

rnd() { od -An -N4 -tu4 /dev/urandom | tr -d ' '; }

# Defaults mirror the official Amnezia client (protocolConstants.h, AWG 3.1).
new_server() {
  cat <<EOF
[Interface]
PrivateKey = $(awg genkey)
Address = ${AWG_ADDRESS:-10.8.3.1/24}
ListenPort = $AWG_PORT
# Obfuscation. Changing anything here needs fresh client configs (peer show <name>).
# Must match on both sides:
HeaderProtectionKey = $(awg genkey)
S1 = 12
S2 = 12
S3 = 12
S4 = 12
H1 = 1
H2 = 2
H3 = 3
H4 = 4
RandomTrailers = on
DisableCookies = on
# Per side, copied into client configs as is:
Jc = $((4 + $(rnd) % 3))
Jmin = 10
Jmax = 50
ContentPaddingAddition = 10-100
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
RejectAfterTime = 150-180
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20
I1 = <r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>
EOF
}

prepare_config() {
  : "${AWG_PORT:?AWG_PORT is required (.env)}"
  umask 077
  mkdir -p /data/clients
  if [[ ! -f $CONF ]]; then
    new_server > "$CONF"
    echo "new server generated in $CONF, back up /data"
  fi
  sed -i "s/^ListenPort = .*/ListenPort = $AWG_PORT/" "$CONF"
}

ipt() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }

setup_nat() {
  local subnet wan
  subnet=$(ip -4 route show dev awg0 proto kernel | awk '{print $1; exit}')
  wan=$(ip -4 route show default | awk '{print $5; exit}')
  [[ -n "$subnet" && -n "$wan" ]] || die "cannot detect tunnel subnet ($subnet) or WAN interface ($wan)"
  ipt INPUT -i awg0 -j ACCEPT
  ipt FORWARD -i awg0 -j ACCEPT
  ipt FORWARD -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ipt POSTROUTING -t nat -s "$subnet" -o "$wan" -j MASQUERADE
}

serve() {
  prepare_config
  awg-quick down "$CONF" >/dev/null 2>&1 || true
  awg-quick up "$CONF"
  setup_nat
  echo "ready: udp/$AWG_PORT, $(grep -c '^\[Peer\]' "$CONF" || true) peer(s), endpoint ${AWG_ENDPOINT:-<unset>}"

  trap 'echo "stopping"; awg-quick down "$CONF"; exit 0' TERM INT
  sleep infinity &
  wait $!
}

case "${1:-serve}" in
  serve) serve ;;
  *) exec "$@" ;;
esac
