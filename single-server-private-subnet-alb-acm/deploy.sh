#!/usr/bin/env bash
# =============================================================================
# deploy.sh — BMI Health Tracker: Private Subnet + ALB + ACM (imported cert)
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh <domain> <public-subnet-1-id> <public-subnet-2-id>
#
# Example:
#   ./deploy.sh bmi.ostaddevops.click subnet-0abc1234567890abc subnet-0def0987654321fed
#
# Architecture:
#   Internet → ALB (public subnets, ACM cert) → EC2 (private subnet, no public IP)
#   Certificate: Let's Encrypt via DNS-01 (Route53) → imported into ACM → used by ALB
#
# Prerequisites:
#   - Private subnet EC2 with NAT Gateway for outbound internet access
#   - Two PUBLIC subnets in DIFFERENT Availability Zones (required by ALB)
#   - IAM role with Route53 + ACM + ELBv2 + EC2 permissions (see MANUAL_DEPLOYMENT.md)
#   - Run as 'ubuntu' user (not root)
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
ALB_NAME="bmi-health-tracker-alb"
TG_NAME="bmi-health-tracker-tg"
ALB_SG_NAME="bmi-alb-sg"
CERT_ARN_FILE="/etc/letsencrypt/bmi-acm-cert-arn"

# ── Argument validation ───────────────────────────────────────────────────────
if [[ $# -lt 3 ]]; then
  die "Three arguments required.\n\n  Usage:   ./deploy.sh <domain> <public-subnet-1-id> <public-subnet-2-id>\n  Example: ./deploy.sh bmi.ostaddevops.click subnet-0abc1234 subnet-0def5678"
fi
DOMAIN="$1"; PUBLIC_SUBNET_1="$2"; PUBLIC_SUBNET_2="$3"

echo "${DOMAIN}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)+$' \
  || die "Invalid domain name: '${DOMAIN}'"
echo "${PUBLIC_SUBNET_1}" | grep -qE '^subnet-[0-9a-f]+$' \
  || die "Invalid subnet ID: '${PUBLIC_SUBNET_1}'"
echo "${PUBLIC_SUBNET_2}" | grep -qE '^subnet-[0-9a-f]+$' \
  || die "Invalid subnet ID: '${PUBLIC_SUBNET_2}'"
[[ $EUID -eq 0 ]] && die "Run as the 'ubuntu' user, not root.\n  sudo is used internally where needed."

echo -e "\n${BOLD}${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   BMI Health Tracker — Private Subnet + ALB + ACM              ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo -e "  Domain   : ${BLUE}${DOMAIN}${NC}"
echo -e "  Subnet 1 : ${BLUE}${PUBLIC_SUBNET_1}${NC}"
echo -e "  Subnet 2 : ${BLUE}${PUBLIC_SUBNET_2}${NC}"
echo -e "  App dir  : ${BLUE}${APP_DIR}${NC}\n"

[[ -f "${BACKEND_DIR}/src/server.js" ]] || die "backend/src/server.js not found. Run from the repo root."
[[ -f "${FRONTEND_DIR}/package.json" ]] || die "frontend/package.json not found. Run from the repo root."
[[ -f "${DB_MIGRATION}" ]]              || die "Migration file not found: ${DB_MIGRATION}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 1: Retrieve EC2 metadata (IMDSv2)"
# ═══════════════════════════════════════════════════════════════════════════════
info "Fetching IMDSv2 token..."
IMDS_TOKEN=$(curl -sf --connect-timeout 5 \
  -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") \
  || die "IMDSv2 token failed. Is this an EC2 instance?"

imds() { curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" "http://169.254.169.254/latest/meta-data/$1"; }

INSTANCE_ID=$(imds "instance-id")
PRIVATE_IP=$(imds "local-ipv4")
AZ=$(imds "placement/availability-zone")
REGION=$(imds "placement/region")
log "Instance: ${INSTANCE_ID} | Private IP: ${PRIVATE_IP} | AZ: ${AZ} | Region: ${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 2: Detect VPC and EC2 security group (via IMDSv2 — no AWS CLI needed)"
# ═══════════════════════════════════════════════════════════════════════════════
# All values come from the EC2 metadata service, which is available immediately.
# This avoids a dependency on AWS CLI, which is installed later in Step 7.
MAC=$(imds "network/interfaces/macs/")
MAC="${MAC%/}"   # strip trailing slash

VPC_ID=$(imds "network/interfaces/macs/${MAC}/vpc-id") \
  || die "Could not read VPC ID from instance metadata."
VPC_CIDR=$(imds "network/interfaces/macs/${MAC}/vpc-ipv4-cidr-block") \
  || die "Could not read VPC CIDR from instance metadata."
EC2_SG_ID=$(imds "network/interfaces/macs/${MAC}/security-group-ids" | head -1) \
  || die "Could not read security group IDs from instance metadata."

log "VPC: ${VPC_ID} | CIDR: ${VPC_CIDR} | EC2 SG: ${EC2_SG_ID}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 3: Update system & install base packages"
# ═══════════════════════════════════════════════════════════════════════════════
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
  curl unzip jq dnsutils openssl snapd ca-certificates gnupg lsb-release
log "System packages up to date"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 4: Install Node.js ${NODE_MIN_MAJOR}+ LTS"
# ═══════════════════════════════════════════════════════════════════════════════
NEED_NODE=true
if command -v node &>/dev/null; then
  NODE_MAJOR=$(node -e "process.stdout.write(process.version.split('.')[0].replace('v',''))")
  if [[ ${NODE_MAJOR} -ge ${NODE_MIN_MAJOR} ]]; then
    info "Node.js $(node --version) already installed — skipping"
    NEED_NODE=false
  else
    warn "Node.js $(node --version) too old — upgrading"
  fi
fi
if [[ "${NEED_NODE}" == "true" ]]; then
  info "Installing Node.js 22 LTS via NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y -qq nodejs
fi
log "Node.js $(node --version) | npm $(npm --version)"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 5: Install PostgreSQL"
# ═══════════════════════════════════════════════════════════════════════════════
if ! command -v psql &>/dev/null; then
  sudo apt-get install -y -qq postgresql postgresql-contrib
else
  info "PostgreSQL already installed"
fi
sudo systemctl enable postgresql
sudo systemctl start postgresql
sudo systemctl is-active --quiet postgresql || die "PostgreSQL failed to start"
log "PostgreSQL running"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 6: Install Nginx"
# ═══════════════════════════════════════════════════════════════════════════════
if ! command -v nginx &>/dev/null; then
  sudo apt-get install -y -qq nginx
else
  info "Nginx already installed"
fi
sudo systemctl enable nginx
sudo systemctl start nginx
sudo systemctl is-active --quiet nginx || die "Nginx failed to start"
log "Nginx running"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 7: Install AWS CLI v2"
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

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 8: Verify IAM permissions"
# ═══════════════════════════════════════════════════════════════════════════════
info "Route53..."
aws route53 get-hosted-zone --id "${HOSTED_ZONE_ID}" --query 'HostedZone.Name' --output text \
  || die "Route53 access denied. Check IAM role permissions."

info "ACM..."
aws acm list-certificates --region "${REGION}" --output text >/dev/null \
  || die "ACM access denied. Check IAM role has acm:ListCertificates."

info "ELBv2..."
aws elbv2 describe-load-balancers --region "${REGION}" --output text >/dev/null 2>&1 \
  || die "ELBv2 access denied. Check IAM role has elasticloadbalancing:DescribeLoadBalancers."

info "EC2..."
aws ec2 describe-security-groups --group-ids "${EC2_SG_ID}" --output text >/dev/null \
  || die "EC2 access denied. Check IAM role has ec2:DescribeSecurityGroups."

log "All IAM permissions verified"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 9: Install Certbot (snap)"
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
step "Step 10: Configure firewall (ufw)"
# ═══════════════════════════════════════════════════════════════════════════════
# Private subnet: only allow port 80 from within the VPC (ALB traffic).
# Port 22 (SSH) is intentionally NOT opened — SSM Session Manager is the
# only access method. The EC2 security group has no port 22 inbound rule.
if command -v ufw &>/dev/null; then
  sudo ufw allow from "${VPC_CIDR}" to any port 80  >/dev/null 2>&1 || true
  sudo ufw --force enable                            >/dev/null 2>&1 || true
  log "Firewall: port 80 restricted to VPC CIDR (${VPC_CIDR}); SSH disabled (SSM only)"
else
  warn "ufw not found — relying on EC2 security group"
fi

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 11: Set up PostgreSQL database"
# ═══════════════════════════════════════════════════════════════════════════════
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

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" >/dev/null
  log "User '${DB_USER}' exists — password rotated"
else
  sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" >/dev/null
  log "User '${DB_USER}' created"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  log "Database '${DB_NAME}' already exists"
else
  sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"
  log "Database '${DB_NAME}' created"
fi

MIGRATION_TMP=$(mktemp /tmp/bmi_migration_XXXXXX.sql)
cp "${DB_MIGRATION}" "${MIGRATION_TMP}" && chmod 644 "${MIGRATION_TMP}"
PGPASSWORD="${DB_PASS}" psql -h 127.0.0.1 -U "${DB_USER}" -d "${DB_NAME}" -f "${MIGRATION_TMP}" >/dev/null
rm -f "${MIGRATION_TMP}"
sudo -u postgres psql -d "${DB_NAME}" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};" >/dev/null
sudo -u postgres psql -d "${DB_NAME}" -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};" >/dev/null
log "Database ready"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 12: Write backend .env"
# ═══════════════════════════════════════════════════════════════════════════════
cat > "${BACKEND_DIR}/.env" <<EOF
NODE_ENV=production
PORT=3000
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}
FRONTEND_URL=https://${DOMAIN}
EOF
chmod 600 "${BACKEND_DIR}/.env"
log ".env written (mode 600)"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 13: Install npm dependencies & build frontend"
# ═══════════════════════════════════════════════════════════════════════════════
info "Installing backend production dependencies..."
cd "${BACKEND_DIR}" && npm install --omit=dev --silent
log "Backend dependencies installed"

info "Installing frontend dependencies and building..."
cd "${FRONTEND_DIR}" && npm install --silent && npm run build
log "Frontend built → ${FRONTEND_DIR}/dist"

chmod o+x "${HOME}"
chmod o+x "${APP_DIR}"
chmod o+x "${FRONTEND_DIR}"
sudo chmod -R o+rX "${FRONTEND_DIR}/dist"
cd "${APP_DIR}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 14: Configure Nginx (HTTP only — ALB handles TLS)"
# ═══════════════════════════════════════════════════════════════════════════════
# The ALB terminates HTTPS and sends plain HTTP to Nginx on port 80.
# Nginx must NOT attempt SSL — the ALB's security group controls external access.
sudo tee "/etc/nginx/sites-available/${DOMAIN}" > /dev/null <<'NGINX'
server {
    listen 80 default_server;
    server_name _;

    root FRONTEND_DIST_PLACEHOLDER;
    index index.html;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    # Trust X-Forwarded-For from ALB (within VPC CIDR only)
    real_ip_header    X-Forwarded-For;
    set_real_ip_from  VPC_CIDR_PLACEHOLDER;

    # ALB health check — must return 200, log suppressed
    location = /health {
        proxy_pass       http://127.0.0.1:3000/health;
        proxy_set_header Host $host;
        access_log off;
    }

    # API proxy → Express backend
    location /api/ {
        proxy_pass          http://127.0.0.1:3000;
        proxy_http_version  1.1;
        proxy_set_header    Host              $host;
        proxy_set_header    X-Real-IP         $remote_addr;
        proxy_set_header    X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_read_timeout  30s;
        proxy_connect_timeout 5s;
    }

    # SPA fallback
    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX

sudo sed -i "s|FRONTEND_DIST_PLACEHOLDER|${FRONTEND_DIR}/dist|g" "/etc/nginx/sites-available/${DOMAIN}"
sudo sed -i "s|VPC_CIDR_PLACEHOLDER|${VPC_CIDR}|g"               "/etc/nginx/sites-available/${DOMAIN}"
sudo ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t || die "Nginx config syntax error — see above"
sudo systemctl reload nginx
log "Nginx configured (HTTP only — TLS terminated at ALB)"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 15: Create systemd service for backend"
# ═══════════════════════════════════════════════════════════════════════════════
NODE_BIN=$(command -v node)
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=BMI Health Tracker — Express/Node.js backend
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
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"
sleep 3
sudo systemctl is-active --quiet "${SERVICE_NAME}" \
  || die "Backend failed to start. Check: journalctl -u ${SERVICE_NAME} -n 50"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:3000/health")
[[ "${HTTP_STATUS}" == "200" ]] || die "Backend /health returned ${HTTP_STATUS}"
log "Backend service running and healthy"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 16: Obtain Let's Encrypt certificate via DNS-01 (Route53)"
# ═══════════════════════════════════════════════════════════════════════════════
# DNS-01 proves domain ownership via a Route53 TXT record — no public IP needed.
# This is the ONLY challenge type that works from a private subnet.
CERTBOT_EMAIL="admin@${DOMAIN#*.}"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

if [[ -d "${CERT_DIR}" ]]; then
  info "Certificate already exists at ${CERT_DIR} — skipping issuance"
  log "Existing certificate retained"
else
  info "Writing DNS-01 auth/cleanup hook scripts..."

  # Auth hook: creates _acme-challenge TXT record and waits for Route53 to sync
  sudo tee /tmp/certbot-dns-auth.sh > /dev/null << 'HOOK'
#!/bin/bash
set -euo pipefail
PAYLOAD=$(jq -n \
  --arg name "_acme-challenge.${CERTBOT_DOMAIN}." \
  --arg val  "\"${CERTBOT_VALIDATION}\"" \
  '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":$name,"Type":"TXT","TTL":60,"ResourceRecords":[{"Value":$val}]}}]}')
CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "${ROUTE53_ZONE_ID}" \
  --change-batch   "${PAYLOAD}" \
  --query 'ChangeInfo.Id' --output text)
aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}"
sleep 5
HOOK
  sudo chmod +x /tmp/certbot-dns-auth.sh

  # Cleanup hook: removes the TXT record after challenge verification
  sudo tee /tmp/certbot-dns-cleanup.sh > /dev/null << 'HOOK'
#!/bin/bash
PAYLOAD=$(jq -n \
  --arg name "_acme-challenge.${CERTBOT_DOMAIN}." \
  --arg val  "\"${CERTBOT_VALIDATION}\"" \
  '{"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":$name,"Type":"TXT","TTL":60,"ResourceRecords":[{"Value":$val}]}}]}')
aws route53 change-resource-record-sets \
  --hosted-zone-id "${ROUTE53_ZONE_ID}" \
  --change-batch   "${PAYLOAD}" 2>/dev/null || true
HOOK
  sudo chmod +x /tmp/certbot-dns-cleanup.sh

  info "Requesting certificate for ${DOMAIN} (DNS-01, no port 80 needed)..."
  sudo env \
    ROUTE53_ZONE_ID="${HOSTED_ZONE_ID}" \
    AWS_DEFAULT_REGION="${REGION}" \
    certbot certonly \
    --manual \
    --preferred-challenges dns \
    --manual-auth-hook    /tmp/certbot-dns-auth.sh \
    --manual-cleanup-hook /tmp/certbot-dns-cleanup.sh \
    --domain              "${DOMAIN}" \
    --non-interactive \
    --agree-tos \
    --email               "${CERTBOT_EMAIL}" \
    || die "Certbot DNS-01 failed. Check: sudo journalctl -u snap.certbot.certbot -n 50"

  log "Certificate issued: ${CERT_DIR}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 17: Import certificate into ACM"
# ═══════════════════════════════════════════════════════════════════════════════
# /etc/letsencrypt/live/ is owned by root (mode 0700).
# The ubuntu user cannot read the cert files directly.
# Copy to a temp dir owned by the current user before calling aws CLI.
CERT_TMP=$(mktemp -d /tmp/bmi-cert-import-XXXXXX)
sudo cp "${CERT_DIR}/cert.pem"    "${CERT_TMP}/"
sudo cp "${CERT_DIR}/privkey.pem" "${CERT_TMP}/"
sudo cp "${CERT_DIR}/chain.pem"   "${CERT_TMP}/"
sudo chown "${USER}:${USER}" "${CERT_TMP}"/*.pem

info "Checking for existing ACM certificate for ${DOMAIN}..."
EXISTING_CERT_ARN=$(aws acm list-certificates \
  --region "${REGION}" \
  --query  "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" \
  --output text 2>/dev/null || true)

if [[ -n "${EXISTING_CERT_ARN}" && "${EXISTING_CERT_ARN}" != "None" ]]; then
  info "Existing ACM certificate found: ${EXISTING_CERT_ARN}"
  # AWS requires the replacement cert to have the same key algorithm.
  # Let's Encrypt now defaults to ECDSA; older certs may be RSA.
  # Try in-place update first; fall back to a new import if algorithms differ.
  if CERT_ARN=$(aws acm import-certificate \
      --certificate-arn   "${EXISTING_CERT_ARN}" \
      --certificate       "fileb://${CERT_TMP}/cert.pem" \
      --private-key       "fileb://${CERT_TMP}/privkey.pem" \
      --certificate-chain "fileb://${CERT_TMP}/chain.pem" \
      --region            "${REGION}" \
      --query 'CertificateArn' --output text 2>/dev/null); then
    log "ACM certificate updated in-place: ${CERT_ARN}"
  else
    warn "In-place update failed — key algorithm mismatch (RSA vs ECDSA)"
    warn "Importing as a new ACM certificate..."
    CERT_ARN=$(aws acm import-certificate \
      --certificate       "fileb://${CERT_TMP}/cert.pem" \
      --private-key       "fileb://${CERT_TMP}/privkey.pem" \
      --certificate-chain "fileb://${CERT_TMP}/chain.pem" \
      --region            "${REGION}" \
      --query 'CertificateArn' --output text) \
      || die "ACM import failed. Check IAM role has acm:ImportCertificate."
    log "New ACM certificate imported: ${CERT_ARN}"
  fi
else
  CERT_ARN=$(aws acm import-certificate \
    --certificate       "fileb://${CERT_TMP}/cert.pem" \
    --private-key       "fileb://${CERT_TMP}/privkey.pem" \
    --certificate-chain "fileb://${CERT_TMP}/chain.pem" \
    --region            "${REGION}" \
    --query 'CertificateArn' --output text) \
    || die "ACM import failed. Check IAM role has acm:ImportCertificate."
  log "ACM certificate imported: ${CERT_ARN}"
fi

rm -rf "${CERT_TMP}"
log "Temp cert files cleaned up"

echo "${CERT_ARN}" | sudo tee "${CERT_ARN_FILE}"        > /dev/null
echo "${REGION}"   | sudo tee "${CERT_ARN_FILE}.region" > /dev/null

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 18: Set up certificate auto-renewal → re-import to ACM"
# ═══════════════════════════════════════════════════════════════════════════════
# certbot's systemd timer renews the cert before expiry.
# This deploy hook fires after each successful renewal and re-imports to ACM.
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reimport-to-acm.sh > /dev/null << 'HOOK'
#!/bin/bash
set -euo pipefail
CERT_ARN=$(cat /etc/letsencrypt/bmi-acm-cert-arn)
REGION=$(cat /etc/letsencrypt/bmi-acm-cert-arn.region)
CERT_DIR="/etc/letsencrypt/live/${RENEWED_DOMAIN}"
aws acm import-certificate \
  --certificate-arn   "${CERT_ARN}" \
  --certificate       "fileb://${CERT_DIR}/cert.pem" \
  --private-key       "fileb://${CERT_DIR}/privkey.pem" \
  --certificate-chain "fileb://${CERT_DIR}/chain.pem" \
  --region            "${REGION}"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Renewed and re-imported to ACM: ${CERT_ARN}" \
  >> /var/log/bmi-cert-renewal.log
HOOK
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reimport-to-acm.sh
log "Auto-renewal hook installed (certs re-import to ACM automatically)"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 19: Create ALB security group"
# ═══════════════════════════════════════════════════════════════════════════════
EXISTING_ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${ALB_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

if [[ -z "${EXISTING_ALB_SG}" || "${EXISTING_ALB_SG}" == "None" ]]; then
  ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name  "${ALB_SG_NAME}" \
    --description "BMI Health Tracker ALB - HTTP/HTTPS from internet" \
    --vpc-id      "${VPC_ID}" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "${ALB_SG_ID}" --protocol tcp --port 80  --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id "${ALB_SG_ID}" --protocol tcp --port 443 --cidr 0.0.0.0/0
  log "ALB security group created: ${ALB_SG_ID}"
else
  ALB_SG_ID="${EXISTING_ALB_SG}"
  log "ALB security group already exists: ${ALB_SG_ID}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 20: Update EC2 security group (allow port 80 from ALB SG only)"
# ═══════════════════════════════════════════════════════════════════════════════
info "Adding inbound rule: TCP 80 from ALB SG (${ALB_SG_ID}) on EC2 SG (${EC2_SG_ID})..."
aws ec2 authorize-security-group-ingress \
  --group-id     "${EC2_SG_ID}" \
  --protocol     tcp \
  --port         80 \
  --source-group "${ALB_SG_ID}" 2>/dev/null \
  || info "Rule already exists — skipping"
log "EC2 security group updated (port 80 from ALB only)"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 21: Create target group and register EC2 instance"
# ═══════════════════════════════════════════════════════════════════════════════
EXISTING_TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${TG_NAME}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)

if [[ -z "${EXISTING_TG_ARN}" || "${EXISTING_TG_ARN}" == "None" ]]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name                          "${TG_NAME}" \
    --protocol                      HTTP \
    --port                          80 \
    --vpc-id                        "${VPC_ID}" \
    --target-type                   instance \
    --health-check-protocol         HTTP \
    --health-check-path             "/health" \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds  10 \
    --healthy-threshold-count       2 \
    --unhealthy-threshold-count     3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  log "Target group created: ${TG_ARN}"
else
  TG_ARN="${EXISTING_TG_ARN}"
  log "Target group already exists: ${TG_ARN}"
fi

info "Registering instance ${INSTANCE_ID} in target group..."
aws elbv2 register-targets \
  --target-group-arn "${TG_ARN}" \
  --targets          "Id=${INSTANCE_ID}" 2>/dev/null || true
log "Instance registered"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 22: Create Application Load Balancer"
# ═══════════════════════════════════════════════════════════════════════════════
EXISTING_ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${ALB_NAME}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)

if [[ -z "${EXISTING_ALB_ARN}" || "${EXISTING_ALB_ARN}" == "None" ]]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name            "${ALB_NAME}" \
    --subnets         "${PUBLIC_SUBNET_1}" "${PUBLIC_SUBNET_2}" \
    --security-groups "${ALB_SG_ID}" \
    --scheme          internet-facing \
    --type            application \
    --ip-address-type ipv4 \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  log "ALB created: ${ALB_NAME}"
else
  ALB_ARN="${EXISTING_ALB_ARN}"
  log "ALB already exists"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "${ALB_ARN}" \
  --query 'LoadBalancers[0].DNSName' --output text)
ALB_ZONE_ID=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "${ALB_ARN}" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)
log "ALB DNS: ${ALB_DNS}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 23: Create ALB listeners"
# ═══════════════════════════════════════════════════════════════════════════════
EXISTING_PORTS=$(aws elbv2 describe-listeners \
  --load-balancer-arn "${ALB_ARN}" \
  --query 'Listeners[].Port' --output text 2>/dev/null || true)

if echo "${EXISTING_PORTS}" | grep -qw "80"; then
  info "HTTP listener (80) already exists — skipping"
else
  aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol          HTTP \
    --port              80 \
    --default-actions   'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' \
    >/dev/null
  log "HTTP listener created (HTTP 301 → HTTPS)"
fi

if echo "${EXISTING_PORTS}" | grep -qw "443"; then
  # Listener exists — update cert ARN if it changed (e.g. key algorithm migration)
  HTTPS_LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn "${ALB_ARN}" \
    --query "Listeners[?Port==\`443\`].ListenerArn" --output text 2>/dev/null || true)
  CURRENT_CERT=$(aws elbv2 describe-listeners \
    --listener-arns "${HTTPS_LISTENER_ARN}" \
    --query 'Listeners[0].Certificates[0].CertificateArn' --output text 2>/dev/null || true)
  if [[ -n "${HTTPS_LISTENER_ARN}" && "${CURRENT_CERT}" != "${CERT_ARN}" ]]; then
    info "Updating HTTPS listener cert: ${CURRENT_CERT} -> ${CERT_ARN}..."
    aws elbv2 modify-listener \
      --listener-arn  "${HTTPS_LISTENER_ARN}" \
      --certificates  "CertificateArn=${CERT_ARN}" >/dev/null
    log "HTTPS listener cert updated"
  else
    info "HTTPS listener (443) already exists with correct cert — skipping"
  fi
else
  aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol          HTTPS \
    --port              443 \
    --certificates      "CertificateArn=${CERT_ARN}" \
    --default-actions   "Type=forward,TargetGroupArn=${TG_ARN}" \
    >/dev/null
  log "HTTPS listener created (forwards to target group)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 24: Create Route53 ALIAS record → ALB"
# ═══════════════════════════════════════════════════════════════════════════════
# ALIAS record is free, health-aware, and resolves to ALB IPs dynamically.
# Unlike a plain A record, it follows ALB IP changes automatically.
info "Creating/updating ALIAS A record: ${DOMAIN} → ${ALB_DNS}..."
CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "$(jq -n \
    --arg  name     "${DOMAIN}" \
    --arg  alb_dns  "dualstack.${ALB_DNS}" \
    --arg  alb_zone "${ALB_ZONE_ID}" \
    '{
      "Comment": "BMI Health Tracker - ALB alias record",
      "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": $name,
          "Type": "A",
          "AliasTarget": {
            "HostedZoneId": $alb_zone,
            "DNSName": $alb_dns,
            "EvaluateTargetHealth": true
          }
        }
      }]
    }')" \
  --query 'ChangeInfo.Id' --output text)
log "Route53 ALIAS submitted — Change ID: ${CHANGE_ID}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 25: Wait for ALB to become active"
# ═══════════════════════════════════════════════════════════════════════════════
MAX_WAIT=300; ELAPSED=0
info "Polling ALB state (timeout: ${MAX_WAIT}s)..."
while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
  ALB_STATE=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "${ALB_ARN}" \
    --query 'LoadBalancers[0].State.Code' --output text)
  if [[ "${ALB_STATE}" == "active" ]]; then log "ALB is active"; break; fi
  warn "ALB state: ${ALB_STATE} (${ELAPSED}s/${MAX_WAIT}s)"; sleep 15; ELAPSED=$((ELAPSED + 15))
done
[[ "${ALB_STATE}" != "active" ]] && \
  warn "ALB not active yet — check: aws elbv2 describe-load-balancers --names ${ALB_NAME}"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 26: Wait for target health check"
# ═══════════════════════════════════════════════════════════════════════════════
MAX_WAIT=180; ELAPSED=0
info "Waiting for target ${INSTANCE_ID} to become healthy..."
while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
  TARGET_STATE=$(aws elbv2 describe-target-health \
    --target-group-arn "${TG_ARN}" \
    --targets          "Id=${INSTANCE_ID}" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)
  if [[ "${TARGET_STATE}" == "healthy" ]]; then log "Target instance is healthy"; break; fi
  warn "Target health: ${TARGET_STATE} (${ELAPSED}s)"; sleep 10; ELAPSED=$((ELAPSED + 10))
done
[[ "${TARGET_STATE}" != "healthy" ]] && \
  warn "Target not healthy (${TARGET_STATE}). Check: journalctl -u ${SERVICE_NAME} -n 30"

# ═══════════════════════════════════════════════════════════════════════════════
step "Step 27: Verify deployment"
# ═══════════════════════════════════════════════════════════════════════════════
info "Running post-deployment checks..."

HEALTH=$(curl -s "https://${DOMAIN}/health" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unreachable")
[[ "${HEALTH}" == "ok" ]] \
  && log "HTTPS health check passed (status: ok)" \
  || warn "HTTPS health check: '${HEALTH}' — DNS/ALB may need a moment to settle"

API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/api/measurements" 2>/dev/null || echo "000")
[[ "${API_STATUS}" == "200" ]] \
  && log "API reachable (HTTP ${API_STATUS})" \
  || warn "API returned ${API_STATUS} — check: journalctl -u ${SERVICE_NAME} -n 30"

HTTP_REDIR=$(curl -s -o /dev/null -w "%{http_code}" "http://${DOMAIN}/" 2>/dev/null || echo "000")
[[ "${HTTP_REDIR}" == "301" || "${HTTP_REDIR}" == "302" ]] \
  && log "HTTP → HTTPS redirect working (${HTTP_REDIR})" \
  || warn "HTTP redirect returned ${HTTP_REDIR} (expected 301)"

echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   Deployment Complete!                                         ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
echo -e "  App URL  : ${BLUE}https://${DOMAIN}${NC}"
echo -e "  Health   : ${BLUE}https://${DOMAIN}/health${NC}"
echo -e "  ALB DNS  : ${BLUE}${ALB_DNS}${NC}"
echo -e "  Cert ARN : ${BLUE}${CERT_ARN}${NC}"
echo ""
echo -e "  Service management:"
echo -e "    sudo systemctl status  ${SERVICE_NAME}"
echo -e "    journalctl -u ${SERVICE_NAME} -f"
echo ""
echo -e "  ALB / target health:"
echo -e "    aws elbv2 describe-target-health --target-group-arn ${TG_ARN}"
echo -e "    aws elbv2 describe-load-balancers --names ${ALB_NAME}"
echo ""
echo -e "  SSL renewal:"
echo -e "    sudo certbot renew --dry-run"
echo -e "    cat /var/log/bmi-cert-renewal.log"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════════${NC}"
