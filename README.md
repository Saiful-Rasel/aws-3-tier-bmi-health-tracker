# BMI Health Tracker

A production-ready **three-tier web application** for tracking Body Mass Index (BMI), Basal Metabolic Rate (BMR), and daily calorie requirements. Built as a DevOps portfolio project to demonstrate full-stack development, cloud deployment, infrastructure-as-code scripting, and operational best practices on AWS.

**Live demo:** https://bmi.ostaddevops.click

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture Overview](#2-architecture-overview)
3. [Tech Stack](#3-tech-stack)
4. [Repository Structure](#4-repository-structure)
5. [Application Workflow](#5-application-workflow)
6. [Environment Variables](#6-environment-variables)
7. [Prerequisites](#7-prerequisites)
8. [Local Development Setup](#8-local-development-setup)
9. [Build and Run](#9-build-and-run)
10. [API Reference](#10-api-reference)
11. [Database Schema](#11-database-schema)
12. [Production Deployment](#12-production-deployment)
13. [Automated Deployment Script](#13-automated-deployment-script)
14. [Manual Deployment Guide](#14-manual-deployment-guide)
15. [Monitoring and Logging](#15-monitoring-and-logging)
16. [Security Practices](#16-security-practices)
17. [Troubleshooting](#17-troubleshooting)
18. [Future Improvements](#18-future-improvements)
19. [Contributing](#19-contributing)
20. [License](#20-license)

---

## 1. Project Overview

BMI Health Tracker allows users to log health measurements and visualise trends over time. Users enter their weight, height, age, sex, and activity level. The application calculates BMI (Body Mass Index), BMR (Basal Metabolic Rate using the Mifflin-St Jeor formula), and daily calorie requirements server-side and stores the results in a PostgreSQL database.

**Key features:**

- Submit health measurements via a responsive web form
- View the 10 most recent measurements with colour-coded BMI category badges
- Visualise a 30-day BMI trend line chart (configurable up to 365 days)
- Production-grade deployment with HTTPS, systemd process management, and Nginx reverse proxy
- One-command automated deployment to AWS EC2 via `deploy.sh`

---

## 2. Architecture Overview

The application follows a strict **three-tier architecture**. No tier communicates with any tier other than its immediate neighbour.

```
Browser (HTTPS)
      │
      ▼
┌─────────────────────────────────────────┐
│  TIER 1 — Presentation                  │
│  React 18 + Vite (static files)         │
│  Served by Nginx from frontend/dist/    │
└───────────────┬─────────────────────────┘
                │ /api/* proxy (HTTP, internal)
                ▼
┌─────────────────────────────────────────┐
│  TIER 2 — Application Logic             │
│  Express.js REST API (port 3000)        │
│  BMI / BMR / calorie calculations       │
│  Managed by systemd (bmi-backend)       │
└───────────────┬─────────────────────────┘
                │ TCP pg.Pool (localhost:5432)
                ▼
┌─────────────────────────────────────────┐
│  TIER 3 — Data                          │
│  PostgreSQL 18 (local)                  │
│  Single table: measurements             │
└─────────────────────────────────────────┘
```

**Infrastructure layer (AWS):**

```
Internet → Route 53 (DNS A record) → EC2 t3.medium (Ubuntu 26.04)
                                           ├── Nginx (80 → 443 redirect, TLS termination)
                                           ├── Let's Encrypt certificate (Certbot)
                                           ├── Node.js / Express (port 3000, internal)
                                           └── PostgreSQL 18 (port 5432, local only)
```

**Rules enforced by design:**

| Rule | Detail |
|---|---|
| Frontend never queries the DB | All DB access goes through the Express API |
| Backend never serves static files | Nginx handles all static file serving |
| All calculations are server-side | `backend/src/calculations.js` is the only place BMI/BMR logic lives |
| No raw SQL from user input | All queries use parameterised `$1, $2` placeholders |
| Secrets never committed | Only `.env.example` is in the repo; `.env` is in `.gitignore` |

---

## 3. Tech Stack

### Frontend

| Technology | Version | Role |
|---|---|---|
| React | 18.2 | UI component library |
| Vite | 5.0 | Build tool and dev server (port 5173) |
| Axios | 1.4 | HTTP client with response interceptor |
| Chart.js | 4.4 | BMI trend line chart |
| react-chartjs-2 | 5.2 | React wrapper for Chart.js |

### Backend

| Technology | Version | Role |
|---|---|---|
| Node.js | 22 LTS | JavaScript runtime |
| Express | 4.18 | REST API framework |
| node-postgres (pg) | 8.10 | PostgreSQL driver with connection pooling |
| cors | 2.8 | Cross-origin resource sharing middleware |
| dotenv | 16.0 | Environment variable loading |
| body-parser | 1.20 | JSON request parsing |
| nodemon | 3.0 | Auto-restart during development |

### Database

| Technology | Version | Role |
|---|---|---|
| PostgreSQL | 18 | Relational database |

### Infrastructure

| Technology | Role |
|---|---|
| AWS EC2 (t3.medium) | Application server |
| AWS Route 53 | DNS — A record pointing domain to EC2 public IP |
| Ubuntu 26.04 LTS | Server operating system |
| Nginx 1.28 | Reverse proxy, SSL termination, static file server |
| Let's Encrypt (Certbot) | Free TLS certificate with auto-renewal |
| systemd | Process manager for the Node.js backend |
| ufw | OS-level firewall (ports 22, 80, 443) |
| AWS IAM | EC2 instance role for Route 53 access (no static keys) |

---

## 4. Repository Structure

```
bmi-health-tracker-ec2-server/
│
├── backend/                          # Tier 2 — Express REST API
│   ├── src/
│   │   ├── server.js                 # App entry point, CORS, graceful shutdown
│   │   ├── routes.js                 # All REST endpoints (/api/*)
│   │   ├── db.js                     # PostgreSQL connection pool
│   │   └── calculations.js           # BMI, BMR, daily calorie functions
│   ├── .env.example                  # Required environment variable template
│   └── package.json
│
├── frontend/                         # Tier 1 — React SPA
│   ├── src/
│   │   ├── main.jsx                  # React entry point
│   │   ├── App.jsx                   # Root component, data fetching, layout
│   │   ├── api.js                    # Axios instance (baseURL: /api)
│   │   ├── index.css                 # Global styles (CSS custom properties)
│   │   └── components/
│   │       ├── MeasurementForm.jsx   # POST /api/measurements form
│   │       └── TrendChart.jsx        # GET /api/measurements/trends chart
│   ├── index.html
│   ├── vite.config.js                # Dev proxy: /api → localhost:3000
│   └── package.json
│
├── database/
│   └── migrations/
│       └── 001_create_measurements.sql  # Schema migration (CREATE TABLE IF NOT EXISTS)
│
├── single-server-public-ip-server-ssl/
│   ├── deploy.sh                     # One-command automated deployment script
│   └── MANUAL_DEPLOYMENT.md          # Step-by-step manual deployment guide
│
├── .github/
│   └── copilot-instructions.md       # AI coding assistant project rules
│
├── .gitattributes                    # Enforces LF line endings for shell scripts
├── .gitignore                        # Excludes node_modules, .env, dist, logs
└── README.md                         # This file
```

---

## 5. Application Workflow

### Write path (creating a measurement)

```
User fills form
      │  POST /api/measurements (JSON: weightKg, heightCm, age, sex, activity, measurementDate)
      ▼
MeasurementForm.jsx → Axios → /api/measurements
      │
      ▼
routes.js validates input → calculateMetrics() in calculations.js
      │  BMI = weight / height²  |  BMR = Mifflin-St Jeor  |  calories = BMR × activity multiplier
      ▼
INSERT INTO measurements (...) VALUES ($1…$10) RETURNING *
      │
      ▼
201 Created → { measurement: {...} }
      │
      ▼
App.jsx reloads measurement list
```

### Read path (loading history)

```
App.jsx mounts
      │  GET /api/measurements?limit=100&offset=0
      ▼
SELECT * FROM measurements ORDER BY measurement_date DESC, created_at DESC LIMIT $1 OFFSET $2
      │
      ▼
{ rows: [...] } → App.jsx displays last 10 as styled list
```

### Trend chart path

```
TrendChart.jsx mounts
      │  GET /api/measurements/trends?days=30
      ▼
SELECT measurement_date, ROUND(AVG(bmi), 1) FROM measurements
WHERE measurement_date >= CURRENT_DATE - '30 days'
GROUP BY measurement_date ORDER BY measurement_date
      │
      ▼
{ rows: [{day, avg_bmi}] } → Chart.js line chart
```

---

## 6. Environment Variables

Create `backend/.env` (never commit this file). Use `backend/.env.example` as the template.

| Variable | Required | Example | Description |
|---|---|---|---|
| `NODE_ENV` | Yes | `production` | `development` or `production` |
| `PORT` | No | `3000` | Express server port (default: 3000) |
| `DATABASE_URL` | Yes | `postgresql://bmi_user:pass@localhost:5432/bmidb` | Full PostgreSQL connection string |
| `FRONTEND_URL` | Yes (prod) | `https://bmi.ostaddevops.click` | Allowed CORS origin in production |
| `DB_POOL_SIZE` | No | `20` | Max PostgreSQL pool connections (default: 20) |

> **Important:** In production, the server throws at startup if `DATABASE_URL` or `FRONTEND_URL` are missing. There is no silent fallback.

---

## 7. Prerequisites

### Local development

- Node.js **v20+** (v22 LTS recommended)
- npm **v9+**
- PostgreSQL **v14+** running locally
- Git

### Production server

- Ubuntu 22.04 / 24.04 / 26.04 on AWS EC2
- EC2 IAM role with:
  - `AmazonSSMManagedInstanceCore` (managed policy)
  - Inline policy: `route53:ChangeResourceRecordSets`, `route53:GetHostedZone`
- Security group: ports 22 (SSH), 80 (HTTP), 443 (HTTPS) open
- Route 53 hosted zone for your domain

---

## 8. Local Development Setup

### 1. Clone the repository

```bash
git clone https://github.com/sarowar-alam/bmi-health-tracker-ec2-server.git
cd bmi-health-tracker-ec2-server
```

### 2. Set up the database

```bash
# Create user and database
psql -U postgres -c "CREATE USER bmi_user WITH PASSWORD 'devpassword';"
psql -U postgres -c "CREATE DATABASE bmidb OWNER bmi_user;"

# Run the migration
PGPASSWORD='devpassword' psql -h localhost -U bmi_user -d bmidb \
  -f database/migrations/001_create_measurements.sql
```

### 3. Configure the backend

```bash
cd backend
cp .env.example .env
```

Edit `backend/.env`:

```env
NODE_ENV=development
PORT=3000
DATABASE_URL=postgresql://bmi_user:devpassword@localhost:5432/bmidb
FRONTEND_URL=http://localhost:5173
```

### 4. Install dependencies

```bash
# Backend
cd backend && npm install

# Frontend
cd ../frontend && npm install
```

---

## 9. Build and Run

### Development (with hot-reload)

```bash
# Terminal 1 — Backend (nodemon auto-restarts on file changes)
cd backend && npm run dev

# Terminal 2 — Frontend (Vite dev server with /api proxy to :3000)
cd frontend && npm run dev
```

Open http://localhost:5173 — the Vite proxy forwards all `/api/*` requests to `http://localhost:3000`.

### Production build (local test)

```bash
cd frontend && npm run build
# Output: frontend/dist/  (static files ready for Nginx)
```

### Run backend in production mode

```bash
cd backend && npm start
```

---

## 10. API Reference

All endpoints are prefixed `/api`. The backend runs on port **3000**; Nginx proxies from the public domain.

### `POST /api/measurements`

Create a new measurement. All calculations happen server-side.

**Request body:**

```json
{
  "weightKg": 70,
  "heightCm": 175,
  "age": 30,
  "sex": "male",
  "activity": "moderate",
  "measurementDate": "2026-07-05"
}
```

| Field | Type | Required | Constraints |
|---|---|---|---|
| `weightKg` | number | Yes | > 0 |
| `heightCm` | number | Yes | > 0 |
| `age` | number | Yes | > 0 |
| `sex` | string | Yes | `"male"` or `"female"` |
| `activity` | string | No | `sedentary`, `light`, `moderate`, `active`, `very_active` |
| `measurementDate` | string | No | ISO date (defaults to today) |

**Response `201`:**

```json
{
  "measurement": {
    "id": 1,
    "weight_kg": "70.00",
    "height_cm": "175.00",
    "age": 30,
    "sex": "male",
    "activity_level": "moderate",
    "bmi": "22.9",
    "bmi_category": "Normal",
    "bmr": 1695,
    "daily_calories": 2627,
    "measurement_date": "2026-07-05",
    "created_at": "2026-07-05T10:00:00.000Z"
  }
}
```

---

### `GET /api/measurements`

Retrieve measurements, most recent first.

**Query parameters:**

| Parameter | Default | Max | Description |
|---|---|---|---|
| `limit` | `100` | `100` | Number of rows to return |
| `offset` | `0` | — | Pagination offset |

**Response `200`:** `{ "rows": [ ...measurement objects ] }`

---

### `GET /api/measurements/trends`

Get rolling average BMI grouped by date.

**Query parameters:**

| Parameter | Default | Range | Description |
|---|---|---|---|
| `days` | `30` | `1–365` | Number of days to look back |

**Response `200`:**

```json
{
  "rows": [
    { "day": "2026-06-10", "avg_bmi": "22.9" },
    { "day": "2026-06-11", "avg_bmi": "23.1" }
  ]
}
```

---

### `GET /health`

Backend health check. Does not query the database.

**Response `200`:** `{ "status": "ok" }` (no `environment` field in production)

---

## 11. Database Schema

Single table: `measurements`

```sql
CREATE TABLE measurements (
  id               SERIAL PRIMARY KEY,
  weight_kg        NUMERIC(5,2)  NOT NULL CHECK (weight_kg > 20 AND weight_kg < 500),
  height_cm        NUMERIC(5,2)  NOT NULL CHECK (height_cm > 0  AND height_cm < 300),
  age              INTEGER       NOT NULL CHECK (age > 0 AND age < 150),
  sex              VARCHAR(10)   NOT NULL CHECK (sex IN ('male', 'female')),
  activity_level   VARCHAR(30)            CHECK (activity_level IN
                     ('sedentary','light','moderate','active','very_active')),
  bmi              NUMERIC(4,1)  NOT NULL,
  bmi_category     VARCHAR(30),           -- Underweight / Normal / Overweight / Obese
  bmr              INTEGER,
  daily_calories   INTEGER,
  measurement_date DATE          NOT NULL DEFAULT CURRENT_DATE,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_measurements_measurement_date ON measurements(measurement_date DESC);
CREATE INDEX idx_measurements_created_at       ON measurements(created_at DESC);
CREATE INDEX idx_measurements_bmi              ON measurements(bmi);
```

**Migration file:** `database/migrations/001_create_measurements.sql`  
All DDL uses `CREATE TABLE IF NOT EXISTS` — safe to re-run.

---

## 12. Production Deployment

### Infrastructure

| Component | Value |
|---|---|
| Server | AWS EC2 t3.medium |
| OS | Ubuntu 26.04 LTS |
| Region | ap-south-1 (Mumbai) |
| Domain | bmi.ostaddevops.click |
| DNS | AWS Route 53 (Hosted Zone: Z1019653XLWIJ02C53P5) |
| SSL | Let's Encrypt via Certbot (auto-renews every 60 days) |

### Runtime layout on server

```
/home/ubuntu/bmi-health-tracker-ec2-server/
├── backend/
│   ├── src/          (application code)
│   └── .env          (mode 600 — secrets, never committed)
└── frontend/
    └── dist/         (Vite production build, served by Nginx)

/etc/systemd/system/bmi-backend.service   (process manager)
/etc/nginx/sites-enabled/bmi.ostaddevops.click  (reverse proxy + SSL)
/etc/letsencrypt/live/bmi.ostaddevops.click/    (TLS certificate)
```

---

## 13. Automated Deployment Script

`single-server-public-ip-server-ssl/deploy.sh` is a fully automated, idempotent deployment script. Run it once on a fresh Ubuntu EC2 instance and the entire stack is up with HTTPS.

### Prerequisites

- EC2 instance with the `bmi-ec2-role` IAM role attached
- Repository cloned to `/home/ubuntu/bmi-health-tracker-ec2-server`

### Usage

```bash
git clone https://github.com/sarowar-alam/bmi-health-tracker-ec2-server.git
cd bmi-health-tracker-ec2-server
chmod +x single-server-public-ip-server-ssl/deploy.sh
./single-server-public-ip-server-ssl/deploy.sh bmi.ostaddevops.click
```

### What the script does (17 steps)

| Step | Action |
|---|---|
| 1 | Retrieves EC2 public IP via IMDSv2 (token-based, secure) |
| 2 | `apt update` + `apt upgrade` + installs base packages |
| 3 | Installs Node.js 22 LTS via NodeSource (skips if v20+ already present) |
| 4 | Installs PostgreSQL, enables and starts service |
| 5 | Installs Nginx, enables and starts service |
| 6 | Installs AWS CLI v2, verifies IAM role has Route 53 access |
| 7 | Installs Certbot via snap |
| 8 | Configures ufw: allows SSH + Nginx Full (80/443) |
| 9 | Creates Route 53 A record via AWS CLI (UPSERT — safe to re-run) |
| 10 | Creates PostgreSQL user + database, runs migration as `bmi_user` via TCP, applies GRANT statements |
| 11 | Writes `backend/.env` with randomly generated password (mode 600) |
| 12 | `npm install --omit=dev` (backend), `npm run build` (frontend), fixes Nginx home-dir permissions |
| 13 | Creates systemd service with `Restart=always`, `NoNewPrivileges=true` |
| 14 | Writes Nginx config (HTTP), validates config, reloads Nginx |
| 15 | Polls DNS propagation every 10s (up to 5 minutes) |
| 16 | Runs `certbot --nginx` for HTTPS + redirect (skips if cert already exists) |
| 17 | Post-deploy verification: `/health` + `/api/measurements` |

### Idempotency behaviour

Re-running the script on an existing server is safe:

| State | Behaviour |
|---|---|
| Node.js v20+ already installed | Skipped |
| PostgreSQL / Nginx already installed | Skipped |
| AWS CLI already installed | Skipped |
| Certbot already installed | Skipped |
| DB user already exists | Password rotated (kept in sync with `.env`) |
| `.env` already exists | Existing password is reused (no unnecessary rotation) |
| DB migration already applied | `CREATE TABLE IF NOT EXISTS` makes it a no-op |
| SSL cert already exists | Certbot issuance skipped |
| Route 53 record already exists | UPSERT updates the IP if it changed |

---

## 14. Manual Deployment Guide

For full step-by-step manual deployment instructions (including IAM policy JSON, individual verification commands, and architecture diagrams), see:

**[single-server-public-ip-server-ssl/MANUAL_DEPLOYMENT.md](single-server-public-ip-server-ssl/MANUAL_DEPLOYMENT.md)**

---

## 15. Monitoring and Logging

### Backend logs

```bash
# Live log stream
journalctl -u bmi-backend -f

# Last 50 lines
journalctl -u bmi-backend -n 50

# Logs since last boot
journalctl -u bmi-backend -b
```

### Nginx logs

```bash
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
```

### Service status

```bash
# All three services at once
sudo systemctl status bmi-backend nginx postgresql

# Quick active/inactive check
systemctl is-active bmi-backend nginx postgresql
```

### Health endpoint

```bash
curl -s https://bmi.ostaddevops.click/health
# Returns: {"status":"ok"}
```

> No external monitoring or alerting tool (Prometheus, Grafana, CloudWatch) is currently configured. See [Future Improvements](#18-future-improvements).

---

## 16. Security Practices

| Practice | Implementation |
|---|---|
| **No secrets in version control** | `.env` excluded by `.gitignore`; only `.env.example` committed |
| **Environment validation at startup** | Server throws immediately if `DATABASE_URL` or `FRONTEND_URL` (production) are unset |
| **Parameterised SQL** | All queries use `$1, $2, …` placeholders — no string concatenation |
| **Error message sanitisation** | Validation errors return user-facing messages; server faults return generic `"Failed to …"` — DB internals never leak to clients |
| **CORS locked in production** | Allowed origin set exclusively by `FRONTEND_URL` env var; no wildcard fallback |
| **HTTPS everywhere** | HTTP → HTTPS redirect enforced by Nginx/Certbot; TLS 1.2/1.3 |
| **TLS auto-renewal** | Certbot systemd timer renews the cert before expiry |
| **Least-privilege DB user** | `bmi_user` owns only the `bmidb` database — not a superuser |
| **DB access via TCP with auth** | `scram-sha-256` authentication; no peer/trust auth for app connections |
| **systemd hardening** | `NoNewPrivileges=true`, `PrivateTmp=true` on the backend service |
| **Input validation** | Checked in `routes.js` (presence and sign) and `calculations.js` (type and value) — throws 400 on invalid data |
| **IAM role (no static keys)** | AWS CLI uses the EC2 instance profile; no `AWS_ACCESS_KEY_ID` ever on the server |
| **ufw firewall** | Only ports 22, 80, 443 open at OS level |
| **Graceful shutdown** | SIGTERM handler drains HTTP connections and closes the DB pool before exit |

---

## 17. Troubleshooting

### Backend won't start

```bash
# Check systemd status
sudo systemctl status bmi-backend

# View recent logs
journalctl -u bmi-backend -n 50

# Common causes:
# - Missing .env file         → cat backend/.env
# - DATABASE_URL not set      → check .env
# - PostgreSQL not running    → sudo systemctl start postgresql
# - Port 3000 already in use  → sudo lsof -i :3000
```

### Nginx returns 500 on homepage

```bash
# Check nginx error log
sudo tail -20 /var/log/nginx/error.log

# Most likely cause: nginx can't traverse /home/ubuntu
# Fix:
chmod o+x /home/ubuntu
sudo systemctl reload nginx
```

### API returns 500 (database permission error)

```bash
# Most likely cause: migration was run as postgres user, not bmi_user
sudo -u postgres psql -d bmidb -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO bmi_user;"
sudo -u postgres psql -d bmidb -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO bmi_user;"
sudo systemctl restart bmi-backend
```

### Certbot fails with "Connection refused"

The domain must resolve to the server's IP before Certbot can validate ownership.

```bash
# Check DNS propagation
dig +short bmi.ostaddevops.click @8.8.8.8
# Must match the server's public IP

# Retry certificate issuance manually
sudo certbot --nginx -d bmi.ostaddevops.click
```

### `git pull` blocked by local changes on server

```bash
git checkout -- single-server-public-ip-server-ssl/deploy.sh
git pull
```

### `./deploy.sh: Permission denied`

```bash
chmod +x single-server-public-ip-server-ssl/deploy.sh
```

### Migration "Permission denied" (postgres can't read file)

The script handles this automatically by copying to `/tmp` first. If running manually:

```bash
cp database/migrations/001_create_measurements.sql /tmp/migration.sql
chmod 644 /tmp/migration.sql
PGPASSWORD='your_password' psql -h 127.0.0.1 -U bmi_user -d bmidb -f /tmp/migration.sql
rm /tmp/migration.sql
```

### Check all services and connectivity

```bash
# Services
sudo systemctl status bmi-backend nginx postgresql

# Backend health (direct, bypasses Nginx)
curl -s http://127.0.0.1:3000/health

# Full stack health (via Nginx + TLS)
curl -s https://bmi.ostaddevops.click/health

# Database connectivity
PGPASSWORD='your_password' psql -h 127.0.0.1 -U bmi_user -d bmidb -c "SELECT NOW();"
```

---

## 18. Future Improvements

### CI/CD Pipeline (GitHub Actions)

This project currently uses a manual deployment script (`deploy.sh`). A GitHub Actions workflow with a self-hosted runner on EC2 would automate the following on every push to `main`:

```yaml
# .github/workflows/deploy.yml (not yet implemented)
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: self-hosted      # EC2 runner
    steps:
      - uses: actions/checkout@v4
      - name: Install deps & build frontend
        run: cd frontend && npm ci && npm run build
      - name: Install backend deps
        run: cd backend && npm ci --omit=dev
      - name: Reload backend service
        run: sudo systemctl restart bmi-backend && sudo systemctl reload nginx
```

**To implement:**
1. Install the GitHub Actions runner on the EC2 instance
2. Create `.github/workflows/deploy.yml`
3. Add `FRONTEND_URL` and any other values as GitHub repository secrets
4. Configure the runner as a systemd service for persistence

### Other planned improvements

| Improvement | Benefit |
|---|---|
| GitHub Actions CI/CD | Automated deployments on push to `main` |
| Automated tests (Jest/Vitest) | Catch regressions before deploy |
| CloudWatch or Prometheus + Grafana | Metrics, alerting, dashboards |
| Multi-environment support (staging/prod) | Safe testing before production |
| Rate limiting on API endpoints | Protect against abuse |
| `DELETE /api/measurements/:id` endpoint | Allow users to remove entries |
| User authentication (JWT) | Multi-user support |
| RDS PostgreSQL | Managed database with automated backups |
| Infrastructure as Code (Terraform) | Reproducible AWS infrastructure |
| Docker + Docker Compose | Containerised local development |
| Nginx access log → S3 archival | Long-term audit trail |

---

## 19. Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Follow existing code conventions:
   - Backend: all calculations in `calculations.js` only; never expose internal error messages to clients
   - Frontend: no direct DB calls; all API calls through `src/api.js`; no external UI component libraries
   - SQL: always use parameterised queries (`$1, $2, …`)
4. Test locally with both `npm run dev` services running
5. Commit using conventional commits: `feat:`, `fix:`, `chore:`, `docs:`
6. Open a pull request against `main` with a clear description

---

## 20. License

This project is released under the **MIT License**.

```
MIT License

Copyright (c) 2026 sarowar-alam

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Project Lead

**MD Sarowar Alam**<br>
Lead DevOps Engineer, WPP Production<br>
📧 Email: [sarowar@hotmail.com](mailto:sarowar@hotmail.com)<br>
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
