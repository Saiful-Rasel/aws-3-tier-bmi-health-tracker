# Manual Deployment Guide — BMI Health Tracker
### Private Subnet + Application Load Balancer + ACM Certificate

> This guide covers **two ways** to deploy:
> 1. **Automated** — run `deploy.sh` and it handles everything (recommended)
> 2. **Manual** — follow the step-by-step instructions below to understand each piece

---

## Script Overview

This folder contains two complementary automation scripts:

| Script | Language | Run where | Purpose |
|---|---|---|---|
| `setup_infra.py` | Python (boto3) | **Local machine** | Creates the AWS networking + EC2 infrastructure *before* deploying the app |
| `deploy.sh` | Bash | **On the EC2 server** (via SSM) | Installs the app, configures Nginx, gets SSL cert, builds ALB, goes live |

**Correct order:**
```
1. Local  → python setup_infra.py --action create    (build VPC, subnets, NAT, EC2)
2. Server → ./deploy.sh bmi.ostaddevops.click ...    (install app + provision ALB)
3. Local  → python setup_infra.py --action teardown  (destroy everything when done)
```

---

## `setup_infra.py` — AWS Infrastructure Provisioner

### What it does

Builds the entire AWS networking and compute foundation from your local machine using boto3 with the `sarowar-ostad` AWS profile. Nothing needs to be pre-created in the console.

### Resources created

| # | Resource | Name / Value | Detail |
|---|---|---|---|
| 1 | VPC | `bmi-health-tracker-vpc` | CIDR `10.0.0.0/16`, DNS hostnames + support enabled |
| 2 | Internet Gateway | `bmi-health-tracker-igw` | Attached to the VPC |
| 3 | Public Subnet 1 | `bmi-health-tracker-public-subnet-1` | `10.0.1.0/24` — AZ-a, auto-assign public IP |
| 4 | Public Subnet 2 | `bmi-health-tracker-public-subnet-2` | `10.0.2.0/24` — AZ-b, auto-assign public IP |
| 5 | Private Subnet 1 | `bmi-health-tracker-private-subnet-1` | `10.0.11.0/24` — AZ-a, no public IP |
| 6 | Private Subnet 2 | `bmi-health-tracker-private-subnet-2` | `10.0.12.0/24` — AZ-b, no public IP |
| 7 | Public Route Table | `bmi-health-tracker-public-rt` | `0.0.0.0/0 → IGW`, associated to both public subnets |
| 8 | Elastic IP | `bmi-health-tracker-nat-eip` | Static IP for the NAT Gateway |
| 9 | NAT Gateway | `bmi-health-tracker-nat-gw` | 1 regional, public, in public-subnet-1 |
| 10 | Private Route Table | `bmi-health-tracker-private-rt` | `0.0.0.0/0 → NAT GW`, associated to both private subnets |
| 11 | VPC Endpoint SG | `bmi-health-tracker-vpce-sg` | Allows HTTPS 443 inbound from `10.0.0.0/16` |
| 12 | SSM VPC Endpoint | `bmi-health-tracker-vpce-ssm` | Interface type, `com.amazonaws.ap-south-1.ssm` |
| 13 | SSM Messages Endpoint | `bmi-health-tracker-vpce-ssmmessages` | Interface type, `com.amazonaws.ap-south-1.ssmmessages` |
| 14 | EC2 Messages Endpoint | `bmi-health-tracker-vpce-ec2messages` | Interface type, `com.amazonaws.ap-south-1.ec2messages` |
| 15 | EC2 Security Group | `bmi-health-tracker-ec2-sg` | No inbound rules initially — `deploy.sh` adds port 80 from ALB SG |
| 16 | IAM Role | `bmi-ec2-role` | Trust: EC2 service; Policy: `AmazonSSMManagedInstanceCore` |
| 17 | IAM Instance Profile | `bmi-ec2-role` | Attached to the role, used by the EC2 instance |
| 18 | EC2 Instance | `bmi-health-tracker-server` | `t3.medium`, Ubuntu 26.04 (`ami-01a00762f46d584a1`), private-subnet-1, IMDSv2 only, 20 GiB gp3 encrypted |

### State file

Every resource ID is written to `infra_state.json` immediately after creation. Teardown reads this file to know exactly what to delete. The file is excluded from git (`.gitignore`).

```json
{
  "vpc_id": "vpc-xxx",
  "igw_id": "igw-xxx",
  "public_subnet_ids":  ["subnet-xxx", "subnet-yyy"],
  "private_subnet_ids": ["subnet-aaa", "subnet-bbb"],
  "public_rt_id":  "rtb-xxx",
  "private_rt_id": "rtb-yyy",
  "eip_allocation_id": "eipalloc-xxx",
  "nat_gw_id": "nat-xxx",
  "endpoint_sg_id": "sg-xxx",
  "endpoint_ids": {"ssm": "vpce-xxx", "ssmmessages": "vpce-yyy", "ec2messages": "vpce-zzz"},
  "ec2_sg_id": "sg-yyy",
  "iam_instance_profile_arn": "arn:aws:iam::...",
  "ec2_instance_id": "i-xxx"
}
```

### Prerequisites

- Python 3.9+
- `pip install boto3`
- AWS CLI profile `sarowar-ostad` configured in `~/.aws/credentials`
- IAM user/role for the profile must have permissions to create VPC, EC2, IAM resources

### Usage

```bash
cd single-server-private-subnet-alb-acm

# Create all infrastructure (~3 minutes for NAT Gateway)
python setup_infra.py --action create

# Show current state and live EC2 status
python setup_infra.py --action status

# Destroy everything tracked in infra_state.json
python setup_infra.py --action teardown
```

### Idempotency

Re-running `--action create` is safe — each step checks by `Name` tag before creating:

| Resource | Check method |
|---|---|
| VPC, IGW, subnets, route tables | `describe_*` filtered by `Name` tag |
| NAT Gateway | `describe_nat_gateways` filtered by `Name` tag and state `available/pending` |
| VPC Endpoints | `describe_vpc_endpoints` filtered by `vpc-id` + `service-name` |
| Security groups | `describe_security_groups` filtered by `Name` tag + VPC ID |
| EC2 instance | Checks `ec2_instance_id` in state; verifies instance is not `terminated` |
| IAM role + profile | `get_role` / `get_instance_profile` — creates only if `NoSuchEntity` |

### Teardown order

Teardown runs in strict reverse-dependency order. Each step is wrapped in error handling so a single failure does not abort the rest:

```
1.  Terminate EC2 instance (wait for terminated state)
2.  Delete VPC Endpoints (poll until state = deleted)
3.  Delete security groups (endpoint SG + EC2 SG)
4.  Delete NAT Gateway (wait ~90s)
5.  Release Elastic IP
6.  Delete route tables (disassociate subnets first)
6b. Delete ALB Listeners → ALB → Target Group → ALB SG  ← deploy.sh resources
7.  Delete subnets (private first, then public)
8.  Detach + delete Internet Gateway
9.  Delete VPC
10. Warn about IAM role (not auto-deleted — shared resource)
```

> **Note:** The IAM role `bmi-ec2-role` is intentionally not deleted automatically because it may be reused. Remove manually if no longer needed.

---

## Quick Start — Automated Deployment (`deploy.sh`)

`deploy.sh` is a fully automated, idempotent 27-step script that provisions the entire stack from a fresh private-subnet EC2 instance to a running HTTPS application.

### What it does

| Phase | Steps | What happens |
|---|---|---|
| Infrastructure detection | 1–2 | Reads EC2 metadata (instance ID, region, AZ); detects VPC ID, CIDR, and EC2 security group via AWS CLI |
| Software install | 3–9 | System update, Node.js 22, PostgreSQL, Nginx, AWS CLI v2, Certbot |
| Firewall | 10 | ufw: port 80 from VPC CIDR only; port 22 intentionally not opened (SSM only) |
| App setup | 11–15 | DB + migration, `.env`, npm build, Nginx HTTP-only config, systemd service |
| Certificate | 16–18 | Let's Encrypt DNS-01 via Route53 hooks → import to ACM → auto-renewal deploy hook |
| AWS networking | 19–24 | ALB SG, EC2 SG update, target group + register, ALB, HTTP+HTTPS listeners, Route53 ALIAS |
| Validation | 25–27 | Poll ALB active, poll target healthy, 3-point HTTPS end-to-end verify |

### Prerequisites before running the script

- [ ] Private subnet EC2 running Ubuntu 22.04 / 24.04 / 26.04 (no public IP)
- [ ] NAT Gateway in a public subnet (for outbound internet: npm, apt, AWS CLI, certbot)
- [ ] IAM role `bmi-ec2-role` attached to the instance with the policies from Step 2 below
- [ ] Two **public** subnet IDs in **different AZs** (required by ALB)
- [ ] Connected to the server via **SSM Session Manager** (see Step 3)
- [ ] Repository cloned on the server

### Usage

```bash
# 1. Clone the repo on the EC2 instance (via SSM session)
git clone https://github.com/sarowar-alam/bmi-health-tracker-ec2-server.git
cd bmi-health-tracker-ec2-server

# 2. Run the script — provide domain and two public subnet IDs
./single-server-private-subnet-alb-acm/deploy.sh \
  bmi.ostaddevops.click \
  subnet-0abc1234567890abc \
  subnet-0def0987654321fed
```

### Re-running (idempotent)

Safe to run multiple times. Already-completed steps are skipped:

| Resource | Behaviour on re-run |
|---|---|
| Node.js / PostgreSQL / Nginx | Skipped if already installed |
| DB user / database | Password reused from existing `.env`; migration is `CREATE TABLE IF NOT EXISTS` |
| Let's Encrypt cert | Skipped if cert directory already exists |
| ACM certificate | Updated (import replaces the existing cert) |
| ALB / target group / listeners | Skipped if already exist by name |
| Route53 ALIAS | UPSERT — updates if ALB DNS changed |

---

## Architecture Overview

```
Internet (HTTPS 443 / HTTP 80)
         │
         ▼
┌────────────────────────────────────────────────┐
│  Application Load Balancer (internet-facing)   │
│  Public Subnets — 2 AZs                        │
│  TLS terminated here — ACM certificate         │
│  HTTP 80 → 301 redirect to HTTPS               │
│  HTTPS 443 → forwards to Target Group          │
└───────────────────┬────────────────────────────┘
                    │ HTTP port 80 (internal)
                    ▼
┌────────────────────────────────────────────────┐
│  EC2 t3.medium — Private Subnet                │
│  No public IP — No SSH — No bastion            │
│                                                │
│  ┌──────────┐  ┌──────────────┐  ┌──────────┐  │
│  │  Nginx   │→ │  Express.js  │→ │PostgreSQL│  │
│  │  :80     │  │  :3000       │  │  :5432   │  │
│  └──────────┘  └──────────────┘  └──────────┘  │
└────────────────────────────────────────────────┘
         │
         ▼
Route 53: bmi.ostaddevops.click  (ALIAS → ALB DNS)

Admin / DevOps access (no SSH, no bastion, no port 22):
  AWS Console / CLI → SSM Service → VPC Endpoint → EC2 (private)

Certificate flow:
  Let's Encrypt (DNS-01 via Route53) → cert.pem → ACM import → ALB HTTPS listener
```

**Key differences from single-server-public-ip:**

| Aspect | single-server-public-ip | private-subnet-alb-acm |
|---|---|---|
| EC2 public IP | Yes | No (private only) |
| TLS termination | Nginx (Certbot) | ALB (ACM certificate) |
| Certificate type | Let's Encrypt on server | Let's Encrypt → imported to ACM |
| Challenge method | HTTP-01 (port 80 public) | DNS-01 (Route53 TXT record) |
| Route53 record | A record → EC2 IP | ALIAS record → ALB DNS |
| SSL renewal | certbot auto-renew on server | certbot renew → redeploy hook re-imports to ACM |
| **Server access** | **SSH (port 22, public IP)** | **SSM Session Manager (no SSH, no port 22, no bastion)** |

---

## Prerequisites

| What | Detail |
|---|---|
| VPC | Existing VPC with private + public subnets |
| Private subnet | EC2 instance resides here (no public IP) |
| Public subnets | Two subnets in **different AZs** — required by ALB |
| NAT Gateway | In a public subnet; routes outbound internet traffic from private subnet |
| Internet Gateway | Attached to VPC |
| SSM Agent | Pre-installed on Ubuntu 18.04+ AMIs — no manual setup needed |
| Domain | `bmi.ostaddevops.click` |
| Hosted Zone ID | `Z1019653XLWIJ02C53P5` |

---

## Step 1 — Launch EC2 Instance (Private Subnet)

1. Go to **EC2 → Launch Instance**
2. Set:
   - **AMI**: Ubuntu Server 26.04 LTS (64-bit x86)
   - **Instance type**: `t3.medium`
   - **Network**: select your VPC, **private subnet**, disable "Auto-assign public IP"
   - **Key pair**: select **"Proceed without a key pair"** — SSM Session Manager is the only access method
3. **Security group** — create `bmi-ec2-sg` with:

| Type | Protocol | Port | Source | Why |
|---|---|---|---|---|
| HTTP | TCP | 80 | `bmi-alb-sg` (add after ALB SG created) | ALB → Nginx |

> **No SSH rule (port 22).** SSM Session Manager replaces SSH entirely — the EC2 instance is fully managed without any open inbound ports from the internet or a bastion host.

4. **Storage**: 20 GiB gp3
5. **IAM instance profile**: attach `bmi-ec2-role` (see Step 2)
6. Launch

---

## Step 2 — Create & Attach IAM Role

### 2a — Create the role

1. **IAM → Roles → Create role**
2. Trusted entity: **EC2**
3. Attach managed policy: **`AmazonSSMManagedInstanceCore`**
   - This enables SSM Session Manager (browser/CLI shell), SSM Run Command, and Patch Manager
   - The SSM agent (pre-installed on Ubuntu) uses this policy to register with the SSM service and accept sessions
4. Name: `bmi-ec2-role`
5. Create role

### 2b — Add existing Route53 basic policy

Add inline policy `bmi-route53-access` (same as single-server deployment):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Route53ZoneManagement",
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

### 2c — Add new ALB + ACM policy

Add inline policy `bmi-alb-acm-access`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Route53ChangeTracking",
      "Effect": "Allow",
      "Action": [
        "route53:GetChange",
        "route53:ListHostedZones"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ACMCertificateManagement",
      "Effect": "Allow",
      "Action": [
        "acm:ImportCertificate",
        "acm:DescribeCertificate",
        "acm:ListCertificates",
        "acm:GetCertificate",
        "acm:AddTagsToCertificate"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ALBManagement",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:AddTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2Discovery",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeSecurityGroups",
        "ec2:CreateSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    }
  ]
}
```

### 2d — Attach role to instance

**EC2 → Instances → select instance → Actions → Security → Modify IAM role → bmi-ec2-role**

**Verify SSM can see the instance:**
```bash
aws ssm describe-instance-information \
  --query 'InstanceInformationList[?InstanceId==`<your-instance-id>`].[InstanceId,PingStatus,PlatformName]' \
  --output table
# Expected: PingStatus = Online
```
> It may take 2–3 minutes after role attachment for the SSM agent to register.

---

## Step 2b — SSM VPC Endpoints (Recommended)

By default, SSM traffic from the private subnet goes **out through the NAT Gateway** to reach AWS SSM endpoints. VPC Endpoints keep all SSM traffic **within the VPC** — faster, cheaper, and more secure.

Create three **Interface VPC Endpoints** in your private subnet:

| Service | Endpoint name |
|---|---|
| Systems Manager | `com.amazonaws.REGION.ssm` |
| SSM Messages | `com.amazonaws.REGION.ssmmessages` |
| EC2 Messages | `com.amazonaws.REGION.ec2messages` |

**In the AWS Console** (repeat for each):
1. **VPC → Endpoints → Create endpoint**
2. **Service category**: AWS services
3. **Service name**: search and select the endpoint above
4. **VPC**: your VPC
5. **Subnets**: select your **private subnets**
6. **Security group**: create/select one that allows **HTTPS (443) inbound from the EC2 security group**
7. **Policy**: Full access

**Or via AWS CLI:**
```bash
REGION="ap-south-1"
VPC_ID="vpc-xxxxxxxxx"
SUBNET_ID="subnet-xxxxxxxxx"  # your private subnet
SG_ID="sg-xxxxxxxxx"           # EC2 security group

for SVC in ssm ssmmessages ec2messages; do
  aws ec2 create-vpc-endpoint \
    --vpc-id              "${VPC_ID}" \
    --vpc-endpoint-type   Interface \
    --service-name        "com.amazonaws.${REGION}.${SVC}" \
    --subnet-ids          "${SUBNET_ID}" \
    --security-group-ids  "${SG_ID}" \
    --private-dns-enabled
  echo "Created: ${SVC}"
done
```

> Without VPC Endpoints, SSM still works (via NAT Gateway) but every session byte is billed as NAT Gateway data processing.

---

## Step 3 — Connect to the Server (SSM Session Manager)

There is **no SSH, no key pair, no bastion host**. All server access is via AWS Systems Manager Session Manager. The EC2 instance has no inbound port 22 — it is unreachable from the internet entirely.

### Option A — AWS Management Console

1. **EC2 → Instances** → select your instance
2. **Connect** → **Session Manager** tab → **Connect**
3. A browser-based shell opens directly — no credentials needed

### Option B — AWS CLI

```bash
# Install Session Manager plugin first (once)
# https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

INSTANCE_ID="i-0abc1234567890def"

aws ssm start-session --target "${INSTANCE_ID}"
# Opens an interactive shell on the EC2 instance
```

### Option C — SSH over SSM (for SCP / SFTP / port forwarding)

Add this to your local `~/.ssh/config` to tunnel SSH through SSM:

```
Host i-* mi-*
  ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
```

Then connect as normal:
```bash
ssh ubuntu@i-0abc1234567890def
```

> This requires the `AmazonSSMManagedInstanceCore` policy on the instance role and the Session Manager plugin installed locally.

### Verify SSM connectivity before deploying

```bash
# From your local machine — confirm instance is online in SSM
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=i-0abc1234567890def" \
  --query 'InstanceInformationList[0].{ID:InstanceId,Status:PingStatus,Platform:PlatformName}' \
  --output table
# Expected: PingStatus = Online
```

---

## Step 4 — Clone the Repository

```bash
git clone https://github.com/sarowar-alam/bmi-health-tracker-ec2-server.git
cd bmi-health-tracker-ec2-server
```

---

## Step 5 — Update System & Install Base Packages

```bash
sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get install -y curl unzip jq dnsutils openssl snapd ca-certificates gnupg lsb-release
```

---

## Step 6 — Install Node.js 22 LTS

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version   # v22.x.x
```

---

## Step 7 — Install & Configure PostgreSQL

```bash
sudo apt-get install -y postgresql postgresql-contrib
sudo systemctl enable postgresql && sudo systemctl start postgresql
```

```bash
# Create DB user and database
sudo -u postgres psql -c "CREATE USER bmi_user WITH PASSWORD 'YourStrongPassword123';"
sudo -u postgres createdb -O bmi_user bmidb

# Run migration AS bmi_user (TCP connection — tables owned by bmi_user)
cp database/migrations/001_create_measurements.sql /tmp/migration.sql
chmod 644 /tmp/migration.sql
PGPASSWORD='YourStrongPassword123' psql -h 127.0.0.1 -U bmi_user -d bmidb -f /tmp/migration.sql
rm /tmp/migration.sql

# Safety grants
sudo -u postgres psql -d bmidb -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO bmi_user;"
sudo -u postgres psql -d bmidb -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO bmi_user;"
```

**Verify:**
```bash
PGPASSWORD='YourStrongPassword123' psql -h 127.0.0.1 -U bmi_user -d bmidb -c "\dt"
# Expected: measurements table listed
```

---

## Step 8 — Configure & Start the Backend

```bash
cd ~/bmi-health-tracker-ec2-server/backend
npm install --omit=dev
```

```bash
cat > .env <<EOF
NODE_ENV=production
PORT=3000
DATABASE_URL=postgresql://bmi_user:YourStrongPassword123@localhost:5432/bmidb
FRONTEND_URL=https://bmi.ostaddevops.click
EOF
chmod 600 .env
```

**Test manually:**
```bash
node src/server.js &
sleep 2
curl -s http://127.0.0.1:3000/health
# Expected: {"status":"ok"}
curl -s http://127.0.0.1:3000/api/measurements
# Expected: {"rows":[]}
kill %1
```

**Create systemd service:**
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
sudo systemctl status bmi-backend
```

---

## Step 9 — Build Frontend & Configure Nginx

```bash
cd ~/bmi-health-tracker-ec2-server/frontend
npm install && npm run build
ls dist/   # index.html  assets/
```

**Fix permissions (EC2 sets /home/ubuntu to 750):**
```bash
chmod o+x /home/ubuntu
chmod o+x ~/bmi-health-tracker-ec2-server
chmod o+x ~/bmi-health-tracker-ec2-server/frontend
sudo chmod -R o+rX ~/bmi-health-tracker-ec2-server/frontend/dist
```

**Install Nginx and configure (HTTP only — no SSL on the server):**
```bash
sudo apt-get install -y nginx
sudo systemctl enable nginx && sudo systemctl start nginx
```

Detect VPC CIDR for the real_ip directive:
```bash
INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/instance-id)
VPC_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].VpcId' --output text)
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].CidrBlock' --output text)
echo "VPC CIDR: ${VPC_CIDR}"
```

```bash
FRONTEND_DIST="/home/ubuntu/bmi-health-tracker-ec2-server/frontend/dist"

sudo tee /etc/nginx/sites-available/bmi.ostaddevops.click > /dev/null <<EOF
server {
    listen 80 default_server;
    server_name _;
    root ${FRONTEND_DIST};
    index index.html;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;
    real_ip_header    X-Forwarded-For;
    set_real_ip_from  ${VPC_CIDR};
    location = /health {
        proxy_pass       http://127.0.0.1:3000/health;
        proxy_set_header Host \$host;
        access_log off;
    }
    location /api/ {
        proxy_pass          http://127.0.0.1:3000;
        proxy_http_version  1.1;
        proxy_set_header    Host              \$host;
        proxy_set_header    X-Real-IP         \$remote_addr;
        proxy_set_header    X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto \$http_x_forwarded_proto;
        proxy_read_timeout  30s;
    }
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/bmi.ostaddevops.click /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

**Verify (internal test — no public access yet):**
```bash
curl -s http://127.0.0.1/health
# Expected: {"status":"ok"}
curl -s http://127.0.0.1/api/measurements | jq .
# Expected: {"rows":[]}
```

---

## Step 10 — Install AWS CLI v2

```bash
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install
rm -rf awscliv2.zip aws/
cd ~
aws --version
aws route53 get-hosted-zone --id Z1019653XLWIJ02C53P5 --query 'HostedZone.Name' --output text
# Expected: ostaddevops.click.
```

---

## Step 11 — Install Certbot

```bash
sudo snap install core && sudo snap refresh core
sudo snap install --classic certbot
sudo ln -sf /snap/bin/certbot /usr/bin/certbot
certbot --version
```

---

## Step 12 — Obtain Let's Encrypt Certificate via DNS-01

> **Why DNS-01?** The server is in a private subnet with no public IP. HTTP-01 (port 80) requires public accessibility. DNS-01 only requires IAM access to Route53 — no public port needed.

**Write the auth hook** (creates TXT record in Route53):
```bash
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
```

**Write the cleanup hook** (removes TXT record after challenge):
```bash
sudo tee /tmp/certbot-dns-cleanup.sh > /dev/null << 'HOOK'
#!/bin/bash
PAYLOAD=$(jq -n \
  --arg name "_acme-challenge.${CERTBOT_DOMAIN}." \
  --arg val  "\"${CERTBOT_VALIDATION}\"" \
  '{"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":$name,"Type":"TXT","TTL":60,"ResourceRecords":[{"Value":$val}]}}]}')
aws route53 change-resource-record-sets \
  --hosted-zone-id "${ROUTE53_ZONE_ID}" \
  --change-batch "${PAYLOAD}" 2>/dev/null || true
HOOK
sudo chmod +x /tmp/certbot-dns-cleanup.sh
```

**Request the certificate:**
```bash
sudo env \
  ROUTE53_ZONE_ID="Z1019653XLWIJ02C53P5" \
  AWS_DEFAULT_REGION="$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/placement/region)" \
  certbot certonly \
  --manual \
  --preferred-challenges dns \
  --manual-auth-hook    /tmp/certbot-dns-auth.sh \
  --manual-cleanup-hook /tmp/certbot-dns-cleanup.sh \
  --domain              bmi.ostaddevops.click \
  --non-interactive --agree-tos \
  --email               admin@ostaddevops.click
```

**Verify certificate:**
```bash
sudo certbot certificates
# Expected: Certificate for bmi.ostaddevops.click
#           Expiry: 2026-10-xx
ls /etc/letsencrypt/live/bmi.ostaddevops.click/
# cert.pem  chain.pem  fullchain.pem  privkey.pem
```

---

## Step 13 — Import Certificate into ACM

```bash
REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/placement/region)
CERT_DIR="/etc/letsencrypt/live/bmi.ostaddevops.click"

CERT_ARN=$(aws acm import-certificate \
  --certificate       "fileb://${CERT_DIR}/cert.pem" \
  --private-key       "fileb://${CERT_DIR}/privkey.pem" \
  --certificate-chain "fileb://${CERT_DIR}/chain.pem" \
  --region            "${REGION}" \
  --query 'CertificateArn' --output text)

echo "Certificate ARN: ${CERT_ARN}"

# Persist for renewal hook
echo "${CERT_ARN}" | sudo tee /etc/letsencrypt/bmi-acm-cert-arn > /dev/null
echo "${REGION}"   | sudo tee /etc/letsencrypt/bmi-acm-cert-arn.region > /dev/null
```

**Set up auto-renewal hook** (re-imports to ACM after each renewal):
```bash
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
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Re-imported: ${CERT_ARN}" >> /var/log/bmi-cert-renewal.log
HOOK
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reimport-to-acm.sh

# Test renewal
sudo certbot renew --dry-run
```

---

## Step 14 — Create ALB Security Group

```bash
VPC_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].VpcId' --output text)

ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name  "bmi-alb-sg" \
  --description "BMI Health Tracker ALB — HTTP/HTTPS from internet" \
  --vpc-id      "${VPC_ID}" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "${ALB_SG_ID}" --protocol tcp --port 80  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress \
  --group-id "${ALB_SG_ID}" --protocol tcp --port 443 --cidr 0.0.0.0/0

echo "ALB SG: ${ALB_SG_ID}"
```

---

## Step 15 — Update EC2 Security Group

Allow port 80 from the ALB security group **only** (no direct internet access):

```bash
EC2_SG_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id     "${EC2_SG_ID}" \
  --protocol     tcp \
  --port         80 \
  --source-group "${ALB_SG_ID}"

echo "EC2 SG ${EC2_SG_ID} now accepts port 80 from ALB SG ${ALB_SG_ID} only"
```

---

## Step 16 — Create Target Group and Register Instance

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name                          "bmi-health-tracker-tg" \
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

aws elbv2 register-targets \
  --target-group-arn "${TG_ARN}" \
  --targets          "Id=${INSTANCE_ID}"

echo "Target group ARN: ${TG_ARN}"
```

---

## Step 17 — Create Application Load Balancer

```bash
# Use your two public subnet IDs here
PUBLIC_SUBNET_1="subnet-0abc1234567890abc"
PUBLIC_SUBNET_2="subnet-0def0987654321fed"

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name            "bmi-health-tracker-alb" \
  --subnets         "${PUBLIC_SUBNET_1}" "${PUBLIC_SUBNET_2}" \
  --security-groups "${ALB_SG_ID}" \
  --scheme          internet-facing \
  --type            application \
  --ip-address-type ipv4 \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "${ALB_ARN}" \
  --query 'LoadBalancers[0].DNSName' --output text)
ALB_ZONE_ID=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "${ALB_ARN}" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)

echo "ALB DNS: ${ALB_DNS}"
echo "ALB Zone ID: ${ALB_ZONE_ID}"

# Wait for ALB to become active
aws elbv2 wait load-balancer-available --load-balancer-arns "${ALB_ARN}"
echo "ALB is active"
```

---

## Step 18 — Create ALB Listeners

```bash
# HTTP listener: redirect all traffic to HTTPS
aws elbv2 create-listener \
  --load-balancer-arn "${ALB_ARN}" \
  --protocol          HTTP \
  --port              80 \
  --default-actions   'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}'

# HTTPS listener: terminate TLS with ACM cert, forward to target group
aws elbv2 create-listener \
  --load-balancer-arn "${ALB_ARN}" \
  --protocol          HTTPS \
  --port              443 \
  --certificates      "CertificateArn=${CERT_ARN}" \
  --default-actions   "Type=forward,TargetGroupArn=${TG_ARN}"

echo "Listeners created"
```

---

## Step 19 — Create Route53 ALIAS Record → ALB

> An **ALIAS record** (not a plain A record) is used because:
> - It tracks ALB IP changes automatically
> - It has no TTL cost
> - Route53 health-checks the ALB when `EvaluateTargetHealth: true`

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id "Z1019653XLWIJ02C53P5" \
  --change-batch "$(jq -n \
    --arg  name     "bmi.ostaddevops.click" \
    --arg  alb_dns  "dualstack.${ALB_DNS}" \
    --arg  alb_zone "${ALB_ZONE_ID}" \
    '{
      "Comment": "BMI Health Tracker — ALB alias",
      "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": $name, "Type": "A",
          "AliasTarget": {
            "HostedZoneId": $alb_zone,
            "DNSName": $alb_dns,
            "EvaluateTargetHealth": true
          }
        }
      }]
    }')"
```

---

## Step 20 — Full End-to-End Verification

```bash
# 1. Target health
aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
  --query 'TargetHealthDescriptions[0].TargetHealth'
# Expected: {"State": "healthy", "Reason": "Target.ResponseCodeMismatch"} or just healthy

# 2. HTTPS health check
curl -s https://bmi.ostaddevops.click/health | jq .
# Expected: {"status":"ok"}

# 3. API returns data
curl -s https://bmi.ostaddevops.click/api/measurements | jq .
# Expected: {"rows":[]}

# 4. HTTP redirect to HTTPS
curl -I http://bmi.ostaddevops.click/
# Expected: 301 Moved Permanently → https://bmi.ostaddevops.click/

# 5. Frontend loads
curl -s -o /dev/null -w "%{http_code}" https://bmi.ostaddevops.click/
# Expected: 200

# 6. TLS certificate details
echo | openssl s_client -connect bmi.ostaddevops.click:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
# Expected: issued by Let's Encrypt, expiry ~90 days out

# 7. Submit a test measurement
curl -s -X POST https://bmi.ostaddevops.click/api/measurements \
  -H "Content-Type: application/json" \
  -d '{"weightKg":70,"heightCm":175,"age":30,"sex":"male","activity":"moderate"}' | jq .
# Expected: {"measurement":{"id":1,"bmi":22.9,...}}
```

---

## Useful Commands (Post-Deployment)

```bash
# Backend logs
journalctl -u bmi-backend -f

# Check ALB target health
aws elbv2 describe-target-health --target-group-arn "<TG_ARN>"

# Check ALB state
aws elbv2 describe-load-balancers --names bmi-health-tracker-alb \
  --query 'LoadBalancers[0].State'

# Certificate renewal test
sudo certbot renew --dry-run

# Renewal log (checks ACM re-import happened)
cat /var/log/bmi-cert-renewal.log

# Nginx error log
sudo tail -50 /var/log/nginx/error.log

# Check ACM certificate status
aws acm describe-certificate \
  --certificate-arn "$(cat /etc/letsencrypt/bmi-acm-cert-arn)" \
  --query 'Certificate.Status'
```

---

## Architecture Summary

```
Internet
    │ HTTPS 443
    ▼
ALB (internet-facing, 2 AZs)
  Security group: 0.0.0.0/0 → 80, 443
  Listener 80: HTTP_301 → HTTPS
  Listener 443: ACM cert (Let's Encrypt imported) → Target Group
    │
    │ HTTP 80 (internal VPC traffic only)
    ▼
EC2 (private subnet)
  Security group: ALB SG → 80 only
  Nginx: serves React SPA, proxies /api → :3000
  Express: REST API, calculates BMI/BMR/calories
  PostgreSQL: stores measurements
    │
    ▼
Route 53: bmi.ostaddevops.click ALIAS → ALB DNS (dualstack)
```

---

## Project Lead

**MD Sarowar Alam**<br>
Lead DevOps Engineer, WPP Production<br>
📧 Email: [sarowar@hotmail.com](mailto:sarowar@hotmail.com)<br>
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
