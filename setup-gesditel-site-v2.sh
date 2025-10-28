#!/usr/bin/env bash
# setup-gesditel-site.sh
# Creates Apache vhosts, swaps subdomain references inside the app,
# updates wildcard SSL certs for Apache & Asterisk, and refreshes the calendar view file.
# Designed to be re-runnable (idempotent) and careful (backups + checks).

set -Eeuo pipefail

### ------------------------- CONFIGURABLE DEFAULTS -------------------------
CONFIG_PATH="/etc/apache2/sites-available"
WWW_PATH="/var/www/html"
APP_DIR="qalliEz"

# SSL / Asterisk
WILDCARD_DIR="/etc/ssl/wildcard"
WILDCARD_CERT="${WILDCARD_DIR}/certificate.pem"
ASTERISK_KEYS_DIR="/etc/asterisk/keys"
ASTERISK_PEM="${ASTERISK_KEYS_DIR}/asterisk.pem"

# Remote assets
REMOTE_CERT_URL="https://config-telemarketing.gesditel.app/wildcard/certificate.pem"
REMOTE_CAL_ZIP="https://config-telemarketing.gesditel.app/calendar/calendar.zip"

# Calendar (CodeIgniter view)
CAL_DIR="${WWW_PATH}/${APP_DIR}/application/views/report"
CAL_FILE="${CAL_DIR}/calendar.php"

# Replace occurrences inside project
DEMO_HOST="demo.gesditel.app"

### ---------------------------- HELPER FUNCTIONS ---------------------------
log()   { printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn()  { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
error() { printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { error "Missing required command: $1"; exit 1; }
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "This script needs root. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

ts() { date +"%Y%m%d-%H%M%S"; }

# Download helper: prefers curl, falls back to wget
fetch() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSLk "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --no-check-certificate "$url" -O "$dest"
  else
    error "Neither curl nor wget found for downloading."
    return 1
  fi
  [[ -s "$dest" ]] || { error "Downloaded file is empty: $dest"; return 1; }
}

backup_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    local bkp="${path}.bkp-$(ts)"
    cp -a "$path" "$bkp"
    log "Backup created: $bkp"
  fi
}

### ------------------------------ ARGUMENTS --------------------------------
if [[ $# -lt 1 || -z "${1:-}" ]]; then
  error "Usage: $0 <subdomain>"
  exit 1
fi

SUBDOMAIN="$1"
CONFIG1="${CONFIG_PATH}/config-${SUBDOMAIN}.gesditel.app.conf"
CONFIG2="${CONFIG_PATH}/${SUBDOMAIN}.gesditel.app.conf"

### ------------------------------ PRECHECKS --------------------------------
require_root "$@"
need_cmd a2ensite
need_cmd systemctl
need_cmd sed
need_cmd grep
need_cmd tar

# a2enmod ssl (safe to run repeatedly)
if ! apache2ctl -M 2>/dev/null | grep -qiE ' ssl_module|^ ssl_module'; then
  log "Enabling Apache SSL module..."
  a2enmod ssl >/dev/null
fi

### -------------------------- CREATE APACHE SITES --------------------------
log "Creating Apache config for config-${SUBDOMAIN}.gesditel.app..."
backup_if_exists "$CONFIG1"
cat > "$CONFIG1" <<EOF
<VirtualHost *:80>
  ServerName config-${SUBDOMAIN}.gesditel.app
  Redirect permanent / https://config-${SUBDOMAIN}.gesditel.app/
</VirtualHost>

<VirtualHost *:443>
  ServerName config-${SUBDOMAIN}.gesditel.app
  DocumentRoot ${WWW_PATH}
  SSLEngine on
  SSLCertificateFile ${WILDCARD_CERT}
  <Directory ${WWW_PATH}>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
</VirtualHost>
EOF

log "Creating Apache config for ${SUBDOMAIN}.gesditel.app..."
backup_if_exists "$CONFIG2"
cat > "$CONFIG2" <<EOF
<VirtualHost *:80>
  ServerName ${SUBDOMAIN}.gesditel.app
  Redirect permanent / https://${SUBDOMAIN}.gesditel.app/
</VirtualHost>

<VirtualHost *:443>
  ServerName ${SUBDOMAIN}.gesditel.app
  DocumentRoot ${WWW_PATH}/${APP_DIR}
  SSLEngine on
  SSLCertificateFile ${WILDCARD_CERT}
  <Directory ${WWW_PATH}/${APP_DIR}>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
</VirtualHost>
EOF

log "Enabling sites..."
a2ensite "config-${SUBDOMAIN}.gesditel.app.conf" >/dev/null || true
a2ensite "${SUBDOMAIN}.gesditel.app.conf"        >/dev/null || true

log "Reloading Apache to apply vhost changes..."
systemctl reload apache2

### ------------------------ IN-PROJECT DOMAIN REPLACE ----------------------
log "Replacing '${DEMO_HOST}' → '${SUBDOMAIN}.gesditel.app' inside ${WWW_PATH}/${APP_DIR} (if present)..."
if [[ -d "${WWW_PATH}/${APP_DIR}" ]]; then
  # Only run sed on files containing the pattern; ignore binary files
  set +e
  mapfile -t hits < <(grep -rIl --exclude-dir=.git --exclude-dir=node_modules --exclude='*.zip' --exclude='*.tar*' "${DEMO_HOST}" "${WWW_PATH}/${APP_DIR}" 2>/dev/null)
  set -e
  if [[ ${#hits[@]} -gt 0 ]]; then
    for f in "${hits[@]}"; do
      sed -i "s/${DEMO_HOST//\//\\/}/${SUBDOMAIN}.gesditel.app/g" "$f"
    done
    log "Replaced occurrences in ${#hits[@]} file(s)."
  else
    warn "No occurrences of '${DEMO_HOST}' found—nothing to replace."
  fi
else
  warn "Directory not found: ${WWW_PATH}/${APP_DIR} — skipping replacement."
fi

### ------------------------------- SSL UPDATE ------------------------------
log "Updating wildcard SSL certificate (Apache & Asterisk)..."
mkdir -p "$WILDCARD_DIR" "$ASTERISK_KEYS_DIR"

tmp_cert="$(mktemp /tmp/cert.XXXXXX.pem)"
log "Downloading wildcard cert from: ${REMOTE_CERT_URL}"
fetch "${REMOTE_CERT_URL}" "${tmp_cert}"

# Backup & replace wildcard cert
backup_if_exists "$WILDCARD_CERT"
install -m 0644 -o root -g root "${tmp_cert}" "${WILDCARD_CERT}"
rm -f "${tmp_cert}"

# Copy to Asterisk keys (backup first)
backup_if_exists "$ASTERISK_PEM"
install -m 0640 -o root -g asterisk "${WILDCARD_CERT}" "${ASTERISK_PEM}"

# Reload services
if command -v asterisk >/dev/null 2>&1; then
  log "Reloading Asterisk..."
  asterisk -rx "core reload" || warn "Asterisk reload returned a non-zero status (check if Asterisk is running)."
else
  warn "Asterisk binary not found; skipping Asterisk reload."
fi

log "Reloading Apache after SSL update..."
systemctl reload apache2

### --------------------------- CALENDAR FILE UPDATE ------------------------
log "Updating calendar view file..."
mkdir -p "${CAL_DIR}"

pushd "${CAL_DIR}" >/dev/null

# Backup existing calendar.php (if present)
backup_if_exists "${CAL_FILE}"

# Fetch & extract new calendar package into CAL_DIR
zip_tmp="$(mktemp /tmp/calendar.XXXXXX.zip)"
log "Downloading calendar zip from: ${REMOTE_CAL_ZIP}"
fetch "${REMOTE_CAL_ZIP}" "${zip_tmp}"

log "Extracting calendar.zip..."
# Extract quietly but show file list once; use tar for .zip? We'll use 'unzip' if present, else 'busybox unzip' if available
if command -v unzip >/dev/null 2>&1; then
  unzip -o "${zip_tmp}"
else
  # Try using tar as a fallback only if it's actually a tar zip (not typical). If unzip is missing, we install minimal fallback:
  error "The 'unzip' utility is required to extract ${zip_tmp}. Please install it (e.g., apt-get install -y unzip) and re-run."
  rm -f "${zip_tmp}"
  popd >/dev/null
  exit 1
fi

rm -f "${zip_tmp}"

# Ensure ownership and sane perms for the file we care about
if [[ -f "${CAL_FILE}" ]]; then
  chown asterisk:asterisk "${CAL_FILE}" || warn "Could not chown ${CAL_FILE} to asterisk:asterisk"
  chmod 0644 "${CAL_FILE}" || true
  log "calendar.php updated and permissions set."
else
  warn "calendar.php was not found after extraction. Please verify the zip contents."
fi

popd >/dev/null

log "✅ All done! Sites configured, SSL updated, Asterisk/Apache reloaded, and calendar view refreshed for subdomain: ${SUBDOMAIN}.gesditel.app"
