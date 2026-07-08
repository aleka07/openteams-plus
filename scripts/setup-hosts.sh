#!/usr/bin/env bash
# =============================================================================
# OpenTeams+ Local Development — /etc/hosts Setup Script
# Adds required *.localhost domains to /etc/hosts so services are reachable
# via their friendly names (cloud.localhost, chat.localhost, etc.).
#
# Usage:
#   sudo ./setup-hosts.sh          # add entries
#   sudo ./setup-hosts.sh --remove # remove entries
# =============================================================================

set -euo pipefail

HOSTS_FILE="/etc/hosts"
MARKER="# >>> openteams-local-dev"
MARKER_END="# <<< openteams-local-dev"

DOMAINS=(
  "cloud.localhost"    # Nextcloud — file storage & collaboration
  "chat.localhost"     # Rocket.Chat — team messaging
  "boards.localhost"   # Wekan — kanban boards
  "meet.localhost"     # Jitsi Meet — video conferencing
  "ldap.localhost"     # LLDAP — lightweight LDAP server
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { printf "\033[1;34m[INFO]\033[0m  %s\n" "$*"; }
success() { printf "\033[1;32m[OK]\033[0m    %s\n" "$*"; }
warn()    { printf "\033[1;33m[WARN]\033[0m  %s\n" "$*"; }
error()   { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; exit 1; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
  fi
}

# ---------------------------------------------------------------------------
# Remove existing OpenTeams+ block (idempotent)
# ---------------------------------------------------------------------------
remove_entries() {
  if grep -q "$MARKER" "$HOSTS_FILE" 2>/dev/null; then
    sed -i "/$MARKER/,/$MARKER_END/d" "$HOSTS_FILE"
    info "Removed existing OpenTeams+ entries from $HOSTS_FILE."
  fi
}

# ---------------------------------------------------------------------------
# Add entries
# ---------------------------------------------------------------------------
add_entries() {
  remove_entries   # ensure no duplicates

  {
    echo ""
    echo "$MARKER"
    for domain in "${DOMAINS[@]}"; do
      # strip inline comments for the hosts line
      local name="${domain%%#*}"
      name="${name// /}"   # trim spaces
      echo "127.0.0.1   $name"
    done
    echo "$MARKER_END"
  } >> "$HOSTS_FILE"
}

# ---------------------------------------------------------------------------
# Verify domains resolve to 127.0.0.1
# ---------------------------------------------------------------------------
verify() {
  local all_ok=true
  for domain in "${DOMAINS[@]}"; do
    local name="${domain%%#*}"
    name="${name// /}"
    if getent hosts "$name" | grep -q "127.0.0.1"; then
      success "$name → 127.0.0.1"
    else
      warn "$name does not resolve to 127.0.0.1"
      all_ok=false
    fi
  done

  if $all_ok; then
    echo ""
    success "All domains are configured correctly! 🚀"
    echo ""
    info "Services will be available at:"
    echo "  • http://cloud.localhost    — Nextcloud"
    echo "  • http://chat.localhost     — Rocket.Chat"
    echo "  • http://boards.localhost   — Wekan"
    echo "  • http://meet.localhost     — Jitsi Meet"
    echo "  • http://ldap.localhost     — LLDAP Admin"
    echo "  • http://localhost:8080     — Traefik Dashboard"
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  check_root

  case "${1:-}" in
    --remove|-r)
      remove_entries
      success "OpenTeams+ local domains removed from $HOSTS_FILE."
      ;;
    --help|-h)
      echo "Usage: sudo $0 [--remove | --help]"
      echo ""
      echo "  (no args)   Add OpenTeams+ domains to /etc/hosts"
      echo "  --remove    Remove OpenTeams+ domains from /etc/hosts"
      echo "  --help      Show this help message"
      ;;
    *)
      info "Adding OpenTeams+ local domains to $HOSTS_FILE …"
      add_entries
      verify
      ;;
  esac
}

main "$@"
