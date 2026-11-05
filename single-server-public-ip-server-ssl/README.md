# Manual Deployment Guide — BMI Health Tracker
### Single Server · Public IP · SSL (Let's Encrypt)

> This guide walks through every step that `deploy.sh` automates.  
> Use it to understand what the script does, or when you want full manual control.

---

## Prerequisites

| What | Value |
|---|---|
| Domain | `bmi.ostaddevops.click` |
| Hosted Zone ID | `Z1019653XLWIJ02C53P5` |
| OS | Ubuntu 26.04 LTS |
| Instance type | t3.medium (2 vCPU / 4 GB RAM) |
| Repo | https://github.com/sarowar-alam/bmi-health-tracker-ec2-server.git |

---

## Step 1 — Launch EC2 Instance

1. Go to **EC2 → Launch Instance**
2. Set:
   - **Name**: `bmi-health-tracker`
   - **AMI**: Ubuntu Server 26.04 LTS (64-bit x86)
   - **Instance type**: `t3.medium`
   - **Key pair**: create or select one (needed for SSH login)
3. Under **Network settings → Security group**, create a new group with these rules:

| Type | Protocol | Port | Source |
|---|---|---|---|
| SSH | TCP | 22 | My IP (or `0.0.0.0/0` for lab use) |
| HTTP | TCP | 80 | `0.0.0.0/0` |
| HTTPS | TCP | 443 | `0.0.0.0/0` |

4. **Storage**: 20 GiB gp3 (default is fine)
5. Click **Launch Instance**

---

## Step 2 — Create & Attach IAM Role (SSM + Route53)

### 2a — Create the IAM Role

1. Go to **IAM → Roles → Create role**
2. **Trusted entity**: AWS service → **EC2**
3. **Permissions** — attach one managed policy:
   - `AmazonSSMManagedInstanceCore` — enables SSM Session Manager login

4. Click **Next**, name the role: `bmi-ec2-role`
5. Click **Create role**

### 2b — Add inline Route53 policy

After creating the role, open it and add an **inline policy**:

**Policy name**: `bmi-route53-access`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Route53RecordManagement",
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:GetHostedZone",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/Z1019653XLWIJ02C53P5"
    }
  ]
}
```

### 2c — Attach role to the EC2 instance

1. Go to **EC2 → Instances**, select your instance
2. **Actions → Security → Modify IAM role**
3. Select `bmi-ec2-role` → **Update IAM role**

### Verify IAM + SSM

In **Systems Manager → Fleet Manager**, your instance should appear as `Online` within 2–3 minutes.

---

## Step 3 — Connect to the Server

### Option A — SSH (classic)

```bash
ssh -i your-key.pem ubuntu@<PUBLIC-IP>
```

### Option B — SSM Session Manager (no SSH key needed)

1. **EC2 → Instances** → select instance → **Connect**
2. Choose **Session Manager** tab → **Connect**

### Verify you're on the right server

```bash
hostnamectl
curl -s -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/public-ipv4
```

---

## Step 4 — Clone the Repository

```bash
git clone https://github.com/sarowar-alam/bmi-health-tracker-ec2-server.git
cd bmi-health-tracker-ec2-server
ls
# Expected: backend  database  frontend  single-server-public-ip-server-ssl
```

---

## Step 5 — Update System & Install Base Packages

```bash
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y \
  curl unzip jq dnsutils openssl \
  snapd ca-certificates gnupg lsb-release
```

> `snapd` is required for Certbot (step 11).  
> `ca-certificates gnupg lsb-release` are required for the NodeSource repository setup.

**Verify:**
```bash
curl --version | head -1
jq --version
dig -v 2>&1 | head -1
```

---

## Step 6 — Install & Configure PostgreSQL

### Install

```bash
sudo apt-get install -y postgresql postgresql-contrib
sudo systemctl enable postgresql
sudo systemctl start postgresql
```

**Verify PostgreSQL is running:**
```bash
sudo systemctl status postgresql
psql --version
# Expected: psql (PostgreSQL) 18.x
```

### Create database user and database

```bash
# Create the app user
sudo -u postgres psql -c "CREATE USER bmi_user WITH PASSWORD 'YourStrongPassword123';"

# Create the database owned by bmi_user
sudo -u postgres createdb -O bmi_user bmidb

# Verify both exist
sudo -u postgres psql -c "\du"          # lists roles
sudo -u postgres psql -c "\l"           # lists databases
```

### Run database migration

```bash
# Copy migration to /tmp so postgres can read it (postgres can't traverse /home/ubuntu)
cp database/migrations/001_create_measurements.sql /tmp/migration.sql
chmod 644 /tmp/migration.sql

# Run migration AS bmi_user via TCP — this ensures tables are owned by bmi_user
PGPASSWORD='YourStrongPassword123' psql -h 127.0.0.1 -U bmi_user -d bmidb -f /tmp/migration.sql

# Safety grant — ensures bmi_user has full access even on re-runs
sudo -u postgres psql -d bmidb -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO bmi_user;"
sudo -u postgres psql -d bmidb -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO bmi_user;"

rm /tmp/migration.sql
```

**Verify the table was created:**
```bash
PGPASSWORD='YourStrongPassword123' psql -h 127.0.0.1 -U bmi_user -d bmidb -c "\dt"
# Expected: measurements table listed

PGPASSWORD='YourStrongPassword123' psql -h 127.0.0.1 -U bmi_user -d bmidb -c "\d measurements"
# Expected: full column listing
```

---

## Step 7 — Install Node.js

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
```

**Verify:**
```bash
node --version    # Expected: v22.x.x
npm --version     # Expected: 10.x.x
```

---

## Step 8 — Configure & Start the Backend

### Install dependencies

```bash
cd ~/bmi-health-tracker-ec2-server/backend
npm install --omit=dev
```

### Write the `.env` file

```bash
cat > .env <<EOF
NODE_ENV=production
PORT=3000
DATABASE_URL=postgresql://bmi_user:YourStrongPassword123@localhost:5432/bmidb
FRONTEND_URL=https://bmi.ostaddevops.click
EOF
chmod 600 .env
cat .env    # verify contents (never commit this file)
```

### Test the backend manually (before systemd)

```bash
node src/server.js &
sleep 2

# Health check
curl -s http://127.0.0.1:3000/health
# Expected: {"status":"ok"}

# API with DB access
curl -s http://127.0.0.1:3000/api/measurements
# Expected: {"rows":[]}

# Stop the manual test
kill %1
```

### Create systemd service

```bash
NODE_BIN=$(which node)
BACKEND_DIR=$(pwd)

sudo tee /etc/systemd/system/bmi-backend.service > /dev/null <<EOF
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
SyslogIdentifier=bmi-backend
EnvironmentFile=${BACKEND_DIR}/.env
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable bmi-backend
sudo systemctl start bmi-backend
```

**Verify the service:**
```bash
sudo systemctl status bmi-backend
# Expected: active (running)

journalctl -u bmi-backend -n 20
# Expected: [OK] Database connected at: ...  |  Server running on port 3000

curl -s http://127.0.0.1:3000/health
# Expected: {"status":"ok"}

curl -s http://127.0.0.1:3000/api/measurements | jq .
# Expected: {"rows":[]}
```

---

## Step 9 — Build Frontend & Configure Nginx

### Install Nginx

```bash
sudo apt-get install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx
```

### Build the frontend

```bash
cd ~/bmi-health-tracker-ec2-server/frontend
npm install
npm run build
# Expected: dist/ folder created

ls dist/
# Expected: index.html  assets/
```

### Grant Nginx permission to read files

> EC2 Ubuntu sets `/home/ubuntu` to `750` by default — Nginx (`www-data`) cannot traverse it without this fix.

```bash
chmod o+x /home/ubuntu
chmod o+x ~/bmi-health-tracker-ec2-server
chmod o+x ~/bmi-health-tracker-ec2-server/frontend
sudo chmod -R o+rX ~/bmi-health-tracker-ec2-server/frontend/dist
```

### Write the Nginx site config

```bash
DOMAIN="bmi.ostaddevops.click"
FRONTEND_DIST="/home/ubuntu/bmi-health-tracker-ec2-server/frontend/dist"

sudo tee /etc/nginx/sites-available/${DOMAIN} > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${FRONTEND_DIST};
    index index.html;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    location /api/ {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
    }

    location = /health {
        proxy_pass       http://127.0.0.1:3000/health;
        proxy_set_header Host \$host;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

# Enable the site, disable default
sudo ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/${DOMAIN}
sudo rm -f /etc/nginx/sites-enabled/default

# Test and reload
sudo nginx -t
# Expected: syntax is ok  |  test is successful

sudo systemctl reload nginx
```

**Verify frontend + backend via Nginx (HTTP):**
```bash
PUBLIC_IP=$(curl -sf \
  -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

# Frontend HTML
curl -s -o /dev/null -w "%{http_code}" http://${PUBLIC_IP}/
# Expected: 200

# API via Nginx proxy
curl -s http://${PUBLIC_IP}/api/measurements | jq .
# Expected: {"rows":[]}

# Health via Nginx proxy
curl -s http://${PUBLIC_IP}/health
# Expected: {"status":"ok"}
```

---

## Step 9 — Install AWS CLI v2

> Required to create the Route53 DNS record. The EC2 IAM role provides credentials — no access keys needed.

```bash
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/
cd ~
```

**Verify + confirm IAM role is attached:**
```bash
aws --version
# Expected: aws-cli/2.x.x ...

aws route53 get-hosted-zone --id Z1019653XLWIJ02C53P5 --query 'HostedZone.Name' --output text
# Expected: ostaddevops.click.
# If this fails: check the IAM role is attached to the instance (Step 2)
```

---

## Step 10 — Configure OS Firewall (ufw)

> AWS security groups control external traffic, but Ubuntu’s `ufw` adds a second layer of defence.

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'   # opens ports 80 and 443
sudo ufw --force enable
sudo ufw status
```

**Expected output:**
```
To                         Action      From
--                         ------      ----
OpenSSH                    ALLOW       Anywhere
Nginx Full                 ALLOW       Anywhere
```

---

## Step 11 — Create Route53 DNS A Record

```bash
PUBLIC_IP=$(curl -sf \
  -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

echo "Creating A record: bmi.ostaddevops.click → ${PUBLIC_IP}"

aws route53 change-resource-record-sets \
  --hosted-zone-id Z1019653XLWIJ02C53P5 \
  --change-batch "{
    \"Comment\": \"BMI Health Tracker\",
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"bmi.ostaddevops.click\",
        \"Type\": \"A\",
        \"TTL\": 60,
        \"ResourceRecords\": [{\"Value\": \"${PUBLIC_IP}\"}]
      }
    }]
  }"
```

**Wait for DNS propagation:**
```bash
# Poll until resolved (run this repeatedly)
dig +short bmi.ostaddevops.click @8.8.8.8
# Expected: <same as $PUBLIC_IP>

# Or watch it propagate
watch -n 10 "dig +short bmi.ostaddevops.click @8.8.8.8"
```

---

## Step 12 — Install Certbot

```bash
sudo snap install core
sudo snap refresh core
sudo snap install --classic certbot
sudo ln -sf /snap/bin/certbot /usr/bin/certbot

certbot --version
# Expected: certbot 5.x.x
```

---

## Step 13 — Obtain SSL Certificate

```bash
sudo certbot --nginx \
  --domain bmi.ostaddevops.click \
  --email admin@ostaddevops.click \
  --non-interactive \
  --agree-tos \
  --redirect
```

Certbot will:
1. Verify domain ownership (HTTP-01 challenge via Nginx)
2. Issue the certificate from Let's Encrypt
3. **Automatically update the Nginx config** to add HTTPS and redirect HTTP → HTTPS
4. Set up a systemd timer for auto-renewal

**Verify certificate:**
```bash
sudo certbot certificates
# Expected: Certificate Name: bmi.ostaddevops.click
#           Expiry Date: 2026-10-xx
#           Certificate Path: /etc/letsencrypt/live/bmi.ostaddevops.click/fullchain.pem

# Check auto-renewal timer
sudo systemctl status snap.certbot.renew.timer
# Expected: active
```

---

## Step 14 — Full End-to-End Verification

```bash
# 1. HTTPS health check
curl -s https://bmi.ostaddevops.click/health
# Expected: {"status":"ok"}

# 2. API returns data
curl -s https://bmi.ostaddevops.click/api/measurements | jq .
# Expected: {"rows":[]}

# 3. HTTP redirects to HTTPS
curl -I http://bmi.ostaddevops.click/
# Expected: 301 Moved Permanently  |  Location: https://bmi.ostaddevops.click/

# 4. Frontend loads
curl -s -o /dev/null -w "%{http_code}" https://bmi.ostaddevops.click/
# Expected: 200

# 5. SSL cert details
echo | openssl s_client -connect bmi.ostaddevops.click:443 2>/dev/null | openssl x509 -noout -dates
# Expected: notAfter=Oct xx 2026

# 6. Backend service is healthy
sudo systemctl is-active bmi-backend
# Expected: active

# 7. Test submitting a measurement
curl -s -X POST https://bmi.ostaddevops.click/api/measurements \
  -H "Content-Type: application/json" \
  -d '{"weightKg":70,"heightCm":175,"age":30,"sex":"male","activity":"moderate"}' | jq .
# Expected: {"measurement":{"id":1,"bmi":22.9,"bmi_category":"Normal",...}}

# 8. Verify it was stored
curl -s https://bmi.ostaddevops.click/api/measurements | jq '.rows | length'
# Expected: 1
```

---

## Useful Commands (Post-Deployment)

```bash
# Backend logs (live)
journalctl -u bmi-backend -f

# Restart backend
sudo systemctl restart bmi-backend

# Nginx error log
sudo tail -50 /var/log/nginx/error.log

# Test SSL renewal
sudo certbot renew --dry-run

# View current DB records
PGPASSWORD='YourStrongPassword123' psql -h 127.0.0.1 -U bmi_user -d bmidb \
  -c "SELECT id, bmi, bmi_category, measurement_date FROM measurements ORDER BY id DESC LIMIT 5;"

# Check all services at once
sudo systemctl status bmi-backend nginx postgresql
```

---

## Architecture Summary

```
Internet
    │ HTTPS 443 (Let's Encrypt cert)
    ▼
Nginx (port 80/443)
    ├── /          → serves frontend/dist/ (React static files)
    ├── /api/*     → proxy → Express (port 3000)
    └── /health    → proxy → Express (port 3000)
                            │
                            │ TCP (scram-sha-256 auth)
                            ▼
                     PostgreSQL (port 5432)
                     database: bmidb
                     user: bmi_user
```

---

## Project Lead

**MD Sarowar Alam**<br>
Lead DevOps Engineer, WPP Production<br>
📧 Email: [sarowar@hotmail.com](mailto:sarowar@hotmail.com)<br>
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
