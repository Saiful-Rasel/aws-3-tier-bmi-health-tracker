
#!/usr/bin/env bash

set -Eeuo pipefail

# The exact commit SHA is supplied by GitHub Actions.
COMMIT_SHA="${1:?Commit SHA is required}"

# Validate the SHA before using it in filesystem paths.
if [[ ! "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid commit SHA"
  exit 1
fi

APP_USER="ec2-user"
APP_ROOT="/opt/bmi-app"
REPO_URL="https://github.com/Saiful-Rasel/aws-3-tier-bmi-health-tracker.git"

RELEASE_DIR="${APP_ROOT}/releases/${COMMIT_SHA}"
SHARED_DIR="${APP_ROOT}/shared"
CURRENT_LINK="${APP_ROOT}/current"

echo "Starting deployment: ${COMMIT_SHA}"

# The production environment file must be configured separately.
if [[ ! -f "${SHARED_DIR}/.env" ]]; then
  echo "ERROR: ${SHARED_DIR}/.env does not exist"
  exit 1
fi

# Prepare release directories.
mkdir -p "${APP_ROOT}/releases" "${SHARED_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${APP_ROOT}"

# Verify required runtime tools in the application user's environment.
runuser -u "${APP_USER}" -- bash -lc '
  command -v git
  command -v node
  command -v npm
  command -v pm2
'

# Download the exact commit being deployed.
if [[ ! -d "${RELEASE_DIR}/.git" ]]; then
  runuser -u "${APP_USER}" -- \
    git clone --no-checkout "${REPO_URL}" "${RELEASE_DIR}"
fi

runuser -u "${APP_USER}" -- \
  git -C "${RELEASE_DIR}" fetch --depth 1 origin "${COMMIT_SHA}"

runuser -u "${APP_USER}" -- \
  git -C "${RELEASE_DIR}" checkout --detach FETCH_HEAD

BACKEND_DIR="${RELEASE_DIR}/backend"

# Install only production dependencies.
runuser -u "${APP_USER}" -- bash -lc \
  "cd '${BACKEND_DIR}' && npm ci --omit=dev"

# Make the production environment available to dotenv.
ln -sfn "${SHARED_DIR}/.env" "${BACKEND_DIR}/.env"

# PM2 uses the stable current symlink, not the versioned release path.
cat > "${BACKEND_DIR}/ecosystem.config.cjs" <<'EOF'
module.exports = {
  apps: [
    {
      name: "bmi-backend",
      script: "src/server.js",
      cwd: "/opt/bmi-app/current/backend",
      instances: 1,
      exec_mode: "fork",
      autorestart: true,
      watch: false,
      max_memory_restart: "300M",
      env: {
        NODE_ENV: "production"
      }
    }
  ]
};
EOF

chown -R "${APP_USER}:${APP_USER}" "${RELEASE_DIR}"

# Remember the previous release so we can restore it if PM2 reload fails.
PREVIOUS_RELEASE="$(readlink -f "${CURRENT_LINK}" || true)"

# Atomically point the current symlink to the new release.
ln -sfn "${RELEASE_DIR}" "${CURRENT_LINK}"

# Reload the application as ec2-user.
if ! runuser -u "${APP_USER}" -- bash -lc \
  'pm2 startOrReload /opt/bmi-app/current/backend/ecosystem.config.cjs --env production --update-env && pm2 save'
then
  echo "PM2 reload failed. Attempting rollback."

  if [[ -n "${PREVIOUS_RELEASE}" ]]; then
    ln -sfn "${PREVIOUS_RELEASE}" "${CURRENT_LINK}"

    runuser -u "${APP_USER}" -- bash -lc \
      'pm2 startOrReload /opt/bmi-app/current/backend/ecosystem.config.cjs --env production --update-env' \
      || true
  fi

  exit 1
fi

echo "Deployment completed: ${COMMIT_SHA}"

runuser -u "${APP_USER}" -- bash -lc 'pm2 status'

