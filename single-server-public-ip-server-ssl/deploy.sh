#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Full one-shot deployment for BMI Health Tracker on Ubuntu EC2
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh <domain>
#
# Example:
#   ./deploy.sh bmi.ostaddevops.click
#
# Requirements:
#   - Ubuntu 22.04 / 24.04 / 26.04 on EC2
#   - IAM role attached with route53:ChangeResourceRecordSets permission
#   - Run as the 'ubuntu' user (not root)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Constants ─────────────────────────────────────────────────────────────────
HOSTED_ZONE_ID="Z1019653XLWIJ02C53P5"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="${APP_DIR}/backend"
FRONTEND_DIR="${APP_DIR}/frontend"
DB_MIGRATION="${APP_DIR}/database/migrations/001_create_measurements.sql"
DB_NAME="bmidb"
DB_USER="bmi_user"
SERVICE_NAME="bmi-backend"
NODE_MIN_MAJOR=20

# ── Argument validation ───────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  die "Domain argument required.\n\n  Usage:   ./deploy.sh <domain>\n  Example: ./deploy.sh bmi.ostaddevops.click"
fi
DOMAIN="$1"

# Basic domain format check
if ! echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)+$'; then
  die "Invalid domain name: '$DOMAIN'"
fi

# ── Must NOT run as root ──────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "Run as the 'ubuntu' user, not root.\n  sudo is used internally where needed."

echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   BMI Health Tracker — EC2 Deployment Script             ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo -e "  Domain : ${BLUE}${DOMAIN}${NC}"
echo -e "  App dir: ${BLUE}${APP_DIR}${NC}\n"

# Verify expected project structure is present
[[ -f "${BACKEND_DIR}/src/server.js" ]]  || die "backend/src/server.js not found. Run from the repo root."
[[ -f "${FRONTEND_DIR}/package.json" ]]  || die "frontend/package.json not found. Run from the repo root."
[[ -f "${DB_MIGRATION}" ]]               || die "Database migration file not found: ${DB_MIGRATION}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 1: Retrieve EC2 public IP (IMDSv2)"
# ═══════════════════════════════════════════════════════════════════════════════
info "Fetching IMDSv2 token..."
IMDS_TOKEN=$(curl -sf --connect-timeout 5 \
  -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") \
  || die "Could not obtain IMDSv2 token. Is this an EC2 instance with IMDSv2 enabled?"

PUBLIC_IP=$(curl -sf --connect-timeout 5 \
  -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  "http://169.254.169.254/latest/meta-data/public-ipv4") \
  || die "Could not retrieve public IP from EC2 metadata service."

# Validate it looks like an IP
echo "${PUBLIC_IP}" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "Unexpected public IP value: '${PUBLIC_IP}'"

log "Public IP: ${PUBLIC_IP}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 2: Update system & install base packages"
# ═══════════════════════════════════════════════════════════════════════════════
info "Running apt update & upgrade..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
  curl unzip jq dnsutils openssl snapd ca-certificates gnupg lsb-release
log "System packages up to date"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 3: Install Node.js ${NODE_MIN_MAJOR}+ LTS"
# ═══════════════════════════════════════════════════════════════════════════════
NEED_NODE=true
if command -v node &>/dev/null; then
  NODE_MAJOR=$(node -e "process.stdout.write(process.version.split('.')[0].replace('v',''))")
  if [[ ${NODE_MAJOR} -ge ${NODE_MIN_MAJOR} ]]; then
    info "Node.js $(node --version) already installed — skipping"
    NEED_NODE=false
  else
    warn "Node.js $(node --version) too old (need v${NODE_MIN_MAJOR}+) — upgrading"
  fi
fi

if [[ "${NEED_NODE}" == "true" ]]; then
  info "Installing Node.js 22 LTS via NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y -qq nodejs
fi
log "Node.js $(node --version) | npm $(npm --version)"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 4: Install PostgreSQL"
# ═══════════════════════════════════════════════════════════════════════════════
if ! command -v psql &>/dev/null; then
  info "Installing PostgreSQL..."
  sudo apt-get install -y -qq postgresql postgresql-contrib
else
  info "PostgreSQL already installed — $(psql --version)"
fi
sudo systemctl enable postgresql
sudo systemctl start postgresql
sudo systemctl is-active --quiet postgresql || die "PostgreSQL failed to start"
log "PostgreSQL running"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 5: Install Nginx"
# ═══════════════════════════════════════════════════════════════════════════════
if ! command -v nginx &>/dev/null; then
  info "Installing Nginx..."
  sudo apt-get install -y -qq nginx
else
  info "Nginx already installed"
fi
sudo systemctl enable nginx
sudo systemctl start nginx
sudo systemctl is-active --quiet nginx || die "Nginx failed to start"
log "Nginx running"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 6: Install AWS CLI v2"
# ═══════════════════════════════════════════════════════════════════════════════
if command -v aws &>/dev/null; then
  info "AWS CLI already installed — $(aws --version)"
else
  info "Installing AWS CLI v2..."
  cd /tmp
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip -q awscliv2.zip
  sudo ./aws/install --update
  rm -rf awscliv2.zip aws/
  cd "${APP_DIR}"
fi
log "$(aws --version)"

# Verify IAM role can access Route53 before we need it
info "Verifying IAM permissions for Route53..."
aws route53 get-hosted-zone --id "${HOSTED_ZONE_ID}" --query 'HostedZone.Name' --output text \
  || die "Cannot access Route53 hosted zone ${HOSTED_ZONE_ID}.\nEnsure the EC2 instance has an IAM role with route53:ChangeResourceRecordSets permission."
log "IAM Route53 access confirmed"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 7: Install Certbot (snap)"
# ═══════════════════════════════════════════════════════════════════════════════
if command -v certbot &>/dev/null; then
  info "Certbot already installed — $(certbot --version 2>&1)"
else
  info "Installing Certbot via snap..."
  sudo snap install core 2>/dev/null || true
  sudo snap refresh core  2>/dev/null || true
  sudo snap install --classic certbot
  sudo ln -sf /snap/bin/certbot /usr/bin/certbot
fi
log "$(certbot --version 2>&1)"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 8: Configure firewall (ufw)"
# ═══════════════════════════════════════════════════════════════════════════════
if command -v ufw &>/dev/null; then
  info "Configuring ufw rules..."
  sudo ufw allow OpenSSH    >/dev/null 2>&1 || true
  sudo ufw allow 'Nginx Full' >/dev/null 2>&1 || true
  sudo ufw --force enable   >/dev/null 2>&1 || true
  log "Firewall: SSH + HTTP(S) allowed"
else
  warn "ufw not found — skipping firewall configuration"
fi

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 9: Create Route53 DNS A record  ${DOMAIN} → ${PUBLIC_IP}"
# ═══════════════════════════════════════════════════════════════════════════════
CHANGE_BATCH=$(cat <<JSON
{
  "Comment": "BMI Health Tracker — auto deployment $(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${DOMAIN}",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${PUBLIC_IP}"}]
    }
  }]
}
JSON
)

CHANGE_OUTPUT=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "${CHANGE_BATCH}") \
  || die "Route53 DNS record creation failed."

CHANGE_ID=$(echo "${CHANGE_OUTPUT}" | jq -r '.ChangeInfo.Id')
CHANGE_STATUS=$(echo "${CHANGE_OUTPUT}" | jq -r '.ChangeInfo.Status')
log "DNS record submitted — Change ID: ${CHANGE_ID} | Status: ${CHANGE_STATUS}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 10: Set up PostgreSQL database"
# ═══════════════════════════════════════════════════════════════════════════════
# On re-runs reuse the existing password so the running service keeps working;
# generate a fresh one only on first deploy.
EXISTING_PASS=""
if [[ -f "${BACKEND_DIR}/.env" ]]; then
  EXISTING_PASS=$(grep -oP '(?<=://[^:]+:)[^@]+(?=@localhost)' "${BACKEND_DIR}/.env" 2>/dev/null || true)
fi
if [[ -n "${EXISTING_PASS}" ]]; then
  DB_PASS="${EXISTING_PASS}"
  info "Re-using existing database password from .env"
else
  DB_PASS=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
  info "Generated new database password"
fi

info "Creating database user '${DB_USER}'..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  # User exists — rotate password to match new .env we will write
  sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" >/dev/null
  log "User '${DB_USER}' exists — password rotated"
else
  sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" >/dev/null
  log "User '${DB_USER}' created"
fi

info "Creating database '${DB_NAME}'..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  log "Database '${DB_NAME}' already exists — skipping creation"
else
  sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"
  log "Database '${DB_NAME}' created"
fi

info "Running migration: 001_create_measurements.sql..."
# Copy to /tmp — postgres system user cannot traverse /home/ubuntu
MIGRATION_TMP=$(mktemp /tmp/bmi_migration_XXXXXX.sql)
cp "${DB_MIGRATION}" "${MIGRATION_TMP}"
chmod 644 "${MIGRATION_TMP}"
# Run as bmi_user (TCP connection) so tables are owned by bmi_user, not postgres
# This prevents permission-denied errors on INSERT/SELECT at runtime
PGPASSWORD="${DB_PASS}" psql -h 127.0.0.1 -U "${DB_USER}" -d "${DB_NAME}" -f "${MIGRATION_TMP}" >/dev/null
rm -f "${MIGRATION_TMP}"
# Safety net for re-runs where migration was previously run as postgres:
# grant full access to bmi_user in case any objects are postgres-owned
sudo -u postgres psql -d "${DB_NAME}" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};" >/dev/null
sudo -u postgres psql -d "${DB_NAME}" -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};" >/dev/null
log "Migration applied (CREATE TABLE IF NOT EXISTS — idempotent)"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 11: Write backend .env"
# ═══════════════════════════════════════════════════════════════════════════════
cat > "${BACKEND_DIR}/.env" <<EOF
NODE_ENV=production
PORT=3000
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}
FRONTEND_URL=https://${DOMAIN}
EOF
chmod 600 "${BACKEND_DIR}/.env"
log ".env written (mode 600 — owner-only)"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 12: Install npm dependencies & build frontend"
# ═══════════════════════════════════════════════════════════════════════════════
info "Installing backend production dependencies..."
cd "${BACKEND_DIR}"
npm install --omit=dev --silent
log "Backend dependencies installed"

info "Installing frontend dependencies..."
cd "${FRONTEND_DIR}"
npm install --silent

info "Building frontend (Vite production build)..."
npm run build
log "Frontend built → ${FRONTEND_DIR}/dist"

# EC2 Ubuntu sets /home/ubuntu to 750 by default, blocking nginx (www-data).
# Grant execute (traversal) on every directory in the path to dist/.
chmod o+x "${HOME}"
chmod o+x "${APP_DIR}"
chmod o+x "${FRONTEND_DIR}"
sudo chmod -R o+rX "${FRONTEND_DIR}/dist"

cd "${APP_DIR}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 13: Create systemd service for backend"
# ═══════════════════════════════════════════════════════════════════════════════
NODE_BIN=$(command -v node)
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=BMI Health Tracker — Express/Node.js backend
Documentation=https://github.com/sarowar-alam/bmi-health-tracker-ec2-server
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=${BACKEND_DIR}
ExecStart=${NODE_BIN} src/server.js
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
EnvironmentFile=${BACKEND_DIR}/.env

# Security hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"

info "Waiting for backend to start..."
sleep 3

sudo systemctl is-active --quiet "${SERVICE_NAME}" \
  || die "Backend service failed to start.\n  Check logs: sudo journalctl -u ${SERVICE_NAME} -n 50"

# Verify health endpoint responds
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:3000/health" || echo "000")
if [[ "${HTTP_STATUS}" == "200" ]]; then
  log "Backend healthy (HTTP ${HTTP_STATUS})"
else
  die "Backend /health returned HTTP ${HTTP_STATUS}.\n  Check: sudo journalctl -u ${SERVICE_NAME} -n 50"
fi

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 14: Configure Nginx (HTTP — temporary pre-SSL)"
# ═══════════════════════════════════════════════════════════════════════════════
sudo tee "/etc/nginx/sites-available/${DOMAIN}" > /dev/null <<'NGINX'
# Managed by deploy.sh — do not edit manually
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

    # Frontend static files (Vite production build)
    root FRONTEND_DIST_PLACEHOLDER;
    index index.html;

    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

    # Backend API proxy
    location /api/ {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
        proxy_connect_timeout 5s;
    }

    # Backend health check
    location = /health {
        proxy_pass         http://127.0.0.1:3000/health;
        proxy_set_header   Host $host;
    }

    # SPA fallback — all unknown paths serve index.html (React Router)
    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX

# Replace placeholders (avoiding escaping issues with heredoc)
sudo sed -i "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g"           "/etc/nginx/sites-available/${DOMAIN}"
sudo sed -i "s|FRONTEND_DIST_PLACEHOLDER|${FRONTEND_DIR}/dist|g" "/etc/nginx/sites-available/${DOMAIN}"

sudo ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"

# Disable default Nginx site if present
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t || die "Nginx configuration syntax error — see above"
sudo systemctl reload nginx
log "Nginx configured (HTTP)"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 15: Wait for DNS propagation"
# ═══════════════════════════════════════════════════════════════════════════════
MAX_WAIT=300   # seconds
INTERVAL=10
ELAPSED=0
DNS_OK=false

info "Polling DNS for ${DOMAIN} → ${PUBLIC_IP} (timeout: ${MAX_WAIT}s)..."

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
  RESOLVED=$(dig +short "${DOMAIN}" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
  if [[ "${RESOLVED}" == "${PUBLIC_IP}" ]]; then
    DNS_OK=true
    break
  fi
  warn "Waiting... resolved='${RESOLVED:-<empty>}' | expected='${PUBLIC_IP}' | elapsed=${ELAPSED}s"
  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ "${DNS_OK}" != "true" ]]; then
  warn "DNS did not propagate within ${MAX_WAIT}s."
  warn "The app is running over HTTP on http://${PUBLIC_IP}"
  warn "To add SSL later, run:"
  warn "  sudo certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN#*.}"
  echo ""
  echo -e "${YELLOW}━━ Deployment complete (HTTP only) ━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  App:     ${BLUE}http://${PUBLIC_IP}${NC}"
  echo -e "  Service: sudo systemctl status ${SERVICE_NAME}"
  echo -e "  Logs:    journalctl -u ${SERVICE_NAME} -f"
  exit 0
fi
log "DNS resolved: ${DOMAIN} → ${PUBLIC_IP}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 16: Obtain SSL certificate (Let's Encrypt via Certbot)"
# ═══════════════════════════════════════════════════════════════════════════════
CERTBOT_EMAIL="admin@${DOMAIN#*.}"

# Skip certificate issuance if a valid cert already exists for this domain
if sudo certbot certificates 2>/dev/null | grep -q "Domains:.*${DOMAIN}"; then
  info "Certificate for ${DOMAIN} already exists — skipping issuance"
  log "Existing certificate retained"
else
  info "Requesting certificate for ${DOMAIN} (email: ${CERTBOT_EMAIL})..."
  sudo certbot --nginx \
    --domain "${DOMAIN}" \
    --email  "${CERTBOT_EMAIL}" \
    --non-interactive \
    --agree-tos \
    --redirect \
    || die "Certbot failed.\n  Check: sudo journalctl -u snap.certbot.certbot -n 50\n  Or run manually: sudo certbot --nginx -d ${DOMAIN}"
  log "SSL certificate issued for ${DOMAIN}"
fi

# Verify auto-renewal timer
if sudo systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null; then
  log "Certbot auto-renewal timer active (certificates renew automatically)"
else
  warn "Auto-renewal timer not found — test manually: sudo certbot renew --dry-run"
fi

# Reload Nginx to apply final HTTPS config written by Certbot
sudo nginx -t && sudo systemctl reload nginx

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 17: Verify deployment"
# ═══════════════════════════════════════════════════════════════════════════════
info "Running post-deployment checks..."

# Backend health
HEALTH=$(curl -sf "https://${DOMAIN}/health" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unreachable")
if [[ "${HEALTH}" == "ok" ]]; then
  log "HTTPS health check passed (status: ok)"
else
  warn "HTTPS health check returned: '${HEALTH}' — Nginx or cert may need a moment to settle"
fi

# API endpoint reachable
# Note: do NOT use curl -f here — it exits non-zero on 4xx/5xx and the
# shell's || fallback would append "000" to the real status code.
API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/api/measurements" 2>/dev/null)
if [[ "${API_STATUS}" == "200" ]]; then
  log "API endpoint reachable (HTTP ${API_STATUS})"
else
  warn "API returned HTTP ${API_STATUS} — check: journalctl -u ${SERVICE_NAME} -n 30"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ── Deployment Summary ──────────────────────────────────────────────────────
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   Deployment Complete!                                   ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo -e "  ${BOLD}App URL:${NC}    ${BLUE}https://${DOMAIN}${NC}"
echo -e "  ${BOLD}Health:${NC}     ${BLUE}https://${DOMAIN}/health${NC}"
echo -e "  ${BOLD}API:${NC}        ${BLUE}https://${DOMAIN}/api/measurements${NC}"
echo ""
echo -e "  ${BOLD}Service management:${NC}"
echo -e "    sudo systemctl status  ${SERVICE_NAME}"
echo -e "    sudo systemctl restart ${SERVICE_NAME}"
echo -e "    journalctl -u ${SERVICE_NAME} -f"
echo ""
echo -e "  ${BOLD}SSL renewal:${NC}"
echo -e "    sudo certbot renew --dry-run"
echo -e "    sudo systemctl status snap.certbot.renew.timer"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════${NC}"
