# scripts

Helper scripts for the OpenTeams suite (upstream, for local development).

## Files

| File | Purpose |
|------|---------|
| `setup-hosts.sh` | Adds the suite's `*.localhost` domains to `/etc/hosts` for local dev. |

## setup-hosts.sh

Manages an idempotent, marker-delimited block in `/etc/hosts` mapping the suite's
friendly names to `127.0.0.1`: `cloud.localhost` (Nextcloud), `chat.localhost`
(Rocket.Chat), `boards.localhost` (Wekan), `meet.localhost` (Jitsi Meet),
`ldap.localhost` (LLDAP). Must be run as root.

```bash
sudo ./setup-hosts.sh          # add entries (then verifies each resolves to 127.0.0.1)
sudo ./setup-hosts.sh --remove # remove the block
sudo ./setup-hosts.sh --help
```

Adding first removes any existing block, so re-running never duplicates entries.
