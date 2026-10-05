# AmneziaWG 3.1 server: amneziawg-go v3.1.20260828 + amneziawg-tools v3.1.20260812.
# Pinned by digest: older tools reject the 3.1 keys (HeaderProtectionKey, RandomTrailers, ...).
FROM amneziavpn/amneziawg-go:3.1.20260828@sha256:cbafc02b8373a83f428272db6d8001b37bc02e6211cbd8c0cb4e2e3759b12b72

RUN apk add --no-cache tini libqrencode-tools

COPY entrypoint.sh /usr/local/bin/entrypoint
COPY peer.sh /usr/local/bin/peer
RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/peer

# Server config with all peers + client configs. Mount it, or peers are lost with the container.
VOLUME /data

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD awg show awg0 >/dev/null || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint"]
CMD ["serve"]
