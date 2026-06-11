#!/bin/bash
# Configure package managers to use Socket Registry Firewall
# Deploys system-wide registry overrides so all package installs route through
# your Socket Firewall instance.
#
# Platform: macOS
# Run as:   root (via MDM custom script: Kandji, Jamf, Intune, etc.)
#
# Usage:
#   1. Set FIREWALL_HOST below to your Socket Firewall hostname
#   2. Uncomment the registries your team uses
#   3. Deploy via your endpoint management tool

set -e

###############################################################################
# Configuration — set your firewall hostname here
###############################################################################

FIREWALL_HOST="sfw.yourcompany.com:8443"

# Uncomment the registries your team uses:
NPM_REGISTRY_URL="https://${FIREWALL_HOST}/npm/"
PYPI_REGISTRY_URL="https://${FIREWALL_HOST}/pypi/simple"
# MAVEN_REGISTRY_URL="https://${FIREWALL_HOST}/maven"
# GO_REGISTRY_URL="https://${FIREWALL_HOST}/go"
# NUGET_REGISTRY_URL="https://${FIREWALL_HOST}/nuget/v3/index.json"
# CARGO_REGISTRY_URL="https://${FIREWALL_HOST}/cargo"
# RUBYGEMS_REGISTRY_URL="https://${FIREWALL_HOST}/rubygems"
# CONDA_REGISTRY_URL="https://${FIREWALL_HOST}/conda"

###############################################################################
# Logging and backup
###############################################################################

log() { echo "[socket-registry] $*"; }

BACKUP_DIR="$(mktemp -d)"
BACKED_UP_FILES=()

log "Backup directory: $BACKUP_DIR"

backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    local dest
    dest="$BACKUP_DIR/$(echo "$f" | tr '/' '_')"
    cp -p "$f" "$dest"
    BACKED_UP_FILES+=("$f|$dest")
    log "Backed up $f"
  fi
}

restore_backups() {
  log "ERROR: restoring backups due to failure"
  for entry in "${BACKED_UP_FILES[@]}"; do
    local original="${entry%%|*}"
    local backup="${entry##*|}"
    if [ -f "$backup" ]; then
      cp -p "$backup" "$original"
      log "Restored $original"
    else
      rm -f "$original"
      log "Removed $original (did not exist before)"
    fi
  done
  rm -rf "$BACKUP_DIR"
  log "Backups restored. Exiting."
  exit 1
}

trap restore_backups ERR

###############################################################################
# Helper: set index-url in a pip.conf file, preserving existing content
###############################################################################

set_pip_conf_index() {
  local conf="$1"
  backup_file "$conf"
  if [ -f "$conf" ] && grep -q '^\[global\]' "$conf"; then
    if grep -q '^index-url' "$conf"; then
      log "Updating existing index-url in $conf"
      sed -i '' "s|^index-url.*|index-url = ${PYPI_REGISTRY_URL}|" "$conf"
    else
      log "Adding index-url to existing [global] section in $conf"
      sed -i '' "/^\[global\]/a\\
index-url = ${PYPI_REGISTRY_URL}
" "$conf"
    fi
  else
    log "Appending [global] section to $conf"
    cat >> "$conf" <<EOF

[global]
index-url = ${PYPI_REGISTRY_URL}
EOF
  fi
  chmod 644 "$conf"
}

###############################################################################
# npm — global config via /etc/npmrc (system-wide)
###############################################################################

if [ -n "$NPM_REGISTRY_URL" ]; then
  NPMRC="/etc/npmrc"
  log "Configuring npm registry"
  backup_file "$NPMRC"
  if [ -f "$NPMRC" ] && grep -q '^registry=' "$NPMRC"; then
    log "Updating existing registry in $NPMRC"
    sed -i '' "s|^registry=.*|registry=${NPM_REGISTRY_URL}|" "$NPMRC"
  else
    log "Adding registry to $NPMRC"
    echo "registry=${NPM_REGISTRY_URL}" >> "$NPMRC"
  fi
  chmod 644 "$NPMRC"
fi

###############################################################################
# pip — global config
###############################################################################

if [ -n "$PYPI_REGISTRY_URL" ]; then
  log "Configuring pip global index-url"
  mkdir -p "/Library/Application Support/pip"
  set_pip_conf_index "/Library/Application Support/pip/pip.conf"
fi

###############################################################################
# uv — system-wide config at /etc/uv/uv.toml
###############################################################################

if [ -n "$PYPI_REGISTRY_URL" ]; then
  UV_CONF="/etc/uv/uv.toml"
  log "Configuring uv index-url"
  mkdir -p /etc/uv
  backup_file "$UV_CONF"
  if [ -f "$UV_CONF" ] && grep -q '^index-url' "$UV_CONF"; then
    log "Updating existing index-url in $UV_CONF"
    sed -i '' "s|^index-url.*|index-url = \"${PYPI_REGISTRY_URL}\"|" "$UV_CONF"
  else
    log "Adding index-url to $UV_CONF"
    cat >> "$UV_CONF" <<EOF
index-url = "${PYPI_REGISTRY_URL}"
EOF
  fi
  chmod 644 "$UV_CONF"
fi

###############################################################################
# Maven — system-wide settings at /etc/maven/settings.xml
# Uncomment this block if MAVEN_REGISTRY_URL is set
###############################################################################

# if [ -n "$MAVEN_REGISTRY_URL" ]; then
#   MAVEN_SETTINGS="/etc/maven/settings.xml"
#   log "Configuring Maven mirror"
#   mkdir -p /etc/maven
#   backup_file "$MAVEN_SETTINGS"
#   cat > "$MAVEN_SETTINGS" <<EOF
# <settings>
#   <mirrors>
#     <mirror>
#       <id>socket-firewall</id>
#       <url>${MAVEN_REGISTRY_URL}</url>
#       <mirrorOf>*</mirrorOf>
#     </mirror>
#   </mirrors>
# </settings>
# EOF
#   chmod 644 "$MAVEN_SETTINGS"
# fi

###############################################################################
# Go — set via environment variable (GOPROXY)
# Handled in the shell profile section below
###############################################################################

###############################################################################
# NuGet — system-wide config at /etc/nuget/NuGet.Config
# Uncomment this block if NUGET_REGISTRY_URL is set
###############################################################################

# if [ -n "$NUGET_REGISTRY_URL" ]; then
#   NUGET_CONFIG="/etc/nuget/NuGet.Config"
#   log "Configuring NuGet source"
#   mkdir -p /etc/nuget
#   backup_file "$NUGET_CONFIG"
#   cat > "$NUGET_CONFIG" <<EOF
# <?xml version="1.0" encoding="utf-8"?>
# <configuration>
#   <packageSources>
#     <clear />
#     <add key="socket-firewall" value="${NUGET_REGISTRY_URL}" />
#   </packageSources>
# </configuration>
# EOF
#   chmod 644 "$NUGET_CONFIG"
# fi

###############################################################################
# Cargo — config at /etc/cargo/config.toml
# Uncomment this block if CARGO_REGISTRY_URL is set
###############################################################################

# if [ -n "$CARGO_REGISTRY_URL" ]; then
#   CARGO_CONFIG="/etc/cargo/config.toml"
#   log "Configuring Cargo registry"
#   mkdir -p /etc/cargo
#   backup_file "$CARGO_CONFIG"
#   cat > "$CARGO_CONFIG" <<EOF
# [registries.socket-firewall]
# index = "${CARGO_REGISTRY_URL}"
#
# [registry]
# default = "socket-firewall"
# EOF
#   chmod 644 "$CARGO_CONFIG"
# fi

###############################################################################
# RubyGems — system-wide config at /etc/gemrc
# Uncomment this block if RUBYGEMS_REGISTRY_URL is set
###############################################################################

# if [ -n "$RUBYGEMS_REGISTRY_URL" ]; then
#   GEMRC="/etc/gemrc"
#   log "Configuring RubyGems source"
#   backup_file "$GEMRC"
#   cat > "$GEMRC" <<EOF
# ---
# :sources:
#   - ${RUBYGEMS_REGISTRY_URL}
# EOF
#   chmod 644 "$GEMRC"
# fi

###############################################################################
# Conda — system-wide config at /etc/conda/.condarc
# Uncomment this block if CONDA_REGISTRY_URL is set
###############################################################################

# if [ -n "$CONDA_REGISTRY_URL" ]; then
#   CONDARC="/etc/conda/.condarc"
#   log "Configuring Conda channel"
#   mkdir -p /etc/conda
#   backup_file "$CONDARC"
#   cat > "$CONDARC" <<EOF
# channels:
#   - ${CONDA_REGISTRY_URL}
# default_channels:
#   - ${CONDA_REGISTRY_URL}
# EOF
#   chmod 644 "$CONDARC"
# fi

###############################################################################
# Environment variables for all common shells on macOS
#
# These act as fallbacks in case a tool ignores config files.
# Uncomment variables for the registries you enabled above.
###############################################################################

MARKER="# Socket registry firewall"

for rc in /etc/zshenv /etc/bashrc /etc/profile; do
  backup_file "$rc"
  if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
    log "Updating environment variables in $rc"
    sed -i '' "/$MARKER/,/^$/d" "$rc"
  else
    log "Adding environment variables to $rc"
  fi
  cat >> "$rc" <<EOF
${MARKER}
EOF

  [ -n "$NPM_REGISTRY_URL" ]     && echo "export NPM_CONFIG_REGISTRY=\"${NPM_REGISTRY_URL}\"" >> "$rc"
  [ -n "$PYPI_REGISTRY_URL" ]    && echo "export PIP_INDEX_URL=\"${PYPI_REGISTRY_URL}\"" >> "$rc"
  [ -n "$PYPI_REGISTRY_URL" ]    && echo "export UV_INDEX_URL=\"${PYPI_REGISTRY_URL}\"" >> "$rc"
  # [ -n "$GO_REGISTRY_URL" ]    && echo "export GOPROXY=\"${GO_REGISTRY_URL},direct\"" >> "$rc"
  # [ -n "$CARGO_REGISTRY_URL" ] && echo "export CARGO_REGISTRIES_SOCKET_FIREWALL_INDEX=\"${CARGO_REGISTRY_URL}\"" >> "$rc"

  echo "" >> "$rc"
  chmod 644 "$rc"
done

###############################################################################
# Poetry
#
# Poetry does not support a global override for the default PyPI source URL.
# Each project must configure it in pyproject.toml:
#
#   [[tool.poetry.source]]
#   name = "pypi"
#   url = "https://<YOUR_FIREWALL_HOST>/pypi/simple"
#   priority = "primary"
#
# See: https://python-poetry.org/docs/repositories/#private-repository-example
###############################################################################

# Clean up backups on success
rm -rf "$BACKUP_DIR"
log "Done. Package managers configured to use Socket Registry Firewall."
