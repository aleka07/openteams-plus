# caddy

Reverse-proxy site blocks for the recording module. See [`../README.md`](../README.md)
§4.8 for the full install flow.

## Files

| File | Purpose |
|------|---------|
| `Caddyfile.example` | Two site blocks (meet, rec) for a containerized Caddy. |

## Caddyfile.example

Assumes a **containerized** Caddy sharing the external `proxy` network with the
jitsi `web` container (alias `jitsi-web`) and the `recfront` filebrowser container
(alias `recfront`) — those aliases are set in
[`../compose/docker-compose.override.yml`](../compose/docker-compose.override.yml)
and [`../recfront/docker-compose.yml`](../recfront/docker-compose.yml).

Two blocks:

- `meet.example.com` -> `reverse_proxy jitsi-web:80` — Jitsi Meet.
- `rec.example.com` -> `reverse_proxy recfront:80` — recordings front (Filebrowser
  has its own login; this is the only auth in front of the recordings).

Caddy terminates TLS (automatic Let's Encrypt) and proxies over plain HTTP port 80
in-network. Replace the two hostnames with yours and point their DNS A records at
the server. Note: Jitsi media (JVB) does **not** go through Caddy — open UDP 10000
to the host directly in your firewall.

## Reload (containerized Caddy)

```bash
docker exec -w /etc/caddy <caddy-container> caddy reload
```
