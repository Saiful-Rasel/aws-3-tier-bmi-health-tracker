#!/usr/bin/env bash

# Configure AWS GitHub OIDC trust for infrastructure provisioning.
# Safe to rerun: existing provider and role are reused and updated.

set -Eeuo pipefail

# --------------------------------------------------
# 1. Configuration
# --------------------------------------------------

OWNER="Saiful-Rasel"
REPO_NAME="aws-3-tier-bmi-health-tracker"
REPO="${OWNER}/${REPO_NAME}"

BRANCH="main"
AWS_REGION="ap-south-1"
EXPECTED_ACCOUNT_ID="949502931402"

ROLE_NAME="GitHubActionsProvisionRole"
PROVIDER_URL="https://token.actions.githubusercontent.com"
PROVIDER_HOST="token.actions.githubusercontent.com"

WORKFLOW_FILE=".github/workflows/provision-infrastructure.yml"

ROLE_ARN="arn:aws:iam::${EXPECTED_ACCOUNT_ID}:role/${ROLE_NAME}"
PROVIDER_ARN="arn:aws:iam::${EXPECTED_ACCOUNT_ID}:oidc-provider/${PROVIDER_HOST}"

TEMP_DIR="$(mktemp -d)"
TRUST_POLICY="${TEMP_DIR}/trust-policy.json"

# --------------------------------------------------
# 2. Helper functions
# --------------------------------------------------

log() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$1"
}

pass() {
  printf '\033[1;32m[PASS]\033[0m %s\n' "$1"
}

fail() {
  printf '\033[1;31m[FAIL]\033[0m %s\n' "$1"
  exit 1
}

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Required command not found: $1"
}

# --------------------------------------------------
# 3. Check required tools
# --------------------------------------------------

log "Checking required tools"

for cmd in aws gh jq git; do
  require_command "$cmd"
done

pass "Required CLI tools are installed"

# --------------------------------------------------
# 4. Verify AWS authentication and account
# --------------------------------------------------

log "Checking AWS identity"

AWS_ACCOUNT_ID="$(
  aws sts get-caller-identity \
    --query Account \
    --output text
)"

[[ "$AWS_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] ||
  fail "Wrong AWS account. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID}"

pass "AWS authentication verified: ${AWS_ACCOUNT_ID}"

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

# --------------------------------------------------
# 5. Verify GitHub authentication
# --------------------------------------------------

log "Checking GitHub authentication"

gh auth status >/dev/null 2>&1 ||
  fail "GitHub CLI is not authenticated. Run: gh auth login"

pass "GitHub CLI authentication verified"

# --------------------------------------------------
# 6. Verify repository and branch
# --------------------------------------------------

log "Checking GitHub repository"

REPO_JSON="$(gh api "repos/${REPO}")"

ACTUAL_REPO="$(jq -r '.full_name' <<< "$REPO_JSON")"
REPO_ID="$(jq -r '.id' <<< "$REPO_JSON")"
OWNER_ID="$(jq -r '.owner.id' <<< "$REPO_JSON")"
CREATED_AT="$(jq -r '.created_at' <<< "$REPO_JSON")"
DEFAULT_BRANCH="$(jq -r '.default_branch' <<< "$REPO_JSON")"

[[ "$ACTUAL_REPO" == "$REPO" ]] ||
  fail "Repository mismatch: ${ACTUAL_REPO}"

[[ "$DEFAULT_BRANCH" == "$BRANCH" ]] ||
  fail "Expected default branch ${BRANCH}, got ${DEFAULT_BRANCH}"

pass "Repository and main branch verified"

# --------------------------------------------------
# 7. Detect GitHub OIDC subject format
# --------------------------------------------------

log "Detecting GitHub OIDC subject format"

IMMUTABLE_SUBJECT="false"

# Repositories created after July 15, 2026 use immutable subjects.
if [[ "$CREATED_AT" > "2026-07-15T00:00:00Z" ]]; then
  IMMUTABLE_SUBJECT="true"
fi

# Check repository-level OIDC customization settings.
OIDC_CONFIG="$(
  gh api "repos/${REPO}/actions/oidc/customization/sub" \
    2>/dev/null || printf '{}'
)"

if [[ "$(jq -r '.use_immutable_subject // false' <<< "$OIDC_CONFIG")" == "true" ]]; then
  IMMUTABLE_SUBJECT="true"
fi

if [[ "$IMMUTABLE_SUBJECT" == "true" ]]; then
  SUBJECT="repo:${OWNER}@${OWNER_ID}/${REPO_NAME}@${REPO_ID}:ref:refs/heads/${BRANCH}"
  log "Using immutable GitHub OIDC subject"
else
  SUBJECT="repo:${REPO}:ref:refs/heads/${BRANCH}"
  log "Using traditional GitHub OIDC subject"
fi

pass "OIDC subject determined"

# --------------------------------------------------
# 8. Create or reuse GitHub OIDC provider
# --------------------------------------------------

log "Checking AWS OIDC provider"

if aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "$PROVIDER_ARN" \
  >/dev/null 2>&1; then

  pass "Existing OIDC provider found"

else

  log "Creating GitHub OIDC provider"

  aws iam create-open-id-connect-provider \
    --url "$PROVIDER_URL" \
    --client-id-list sts.amazonaws.com

  pass "OIDC provider created"
fi

# Ensure sts.amazonaws.com is registered as an audience.
CLIENT_IDS="$(
  aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$PROVIDER_ARN" \
    --query 'ClientIDList' \
    --output json
)"

if ! jq -e 'index("sts.amazonaws.com") != null' \
  <<< "$CLIENT_IDS" >/dev/null; then

  aws iam add-client-id-to-open-id-connect-provider \
    --open-id-connect-provider-arn "$PROVIDER_ARN" \
    --client-id sts.amazonaws.com

  pass "STS audience added"

else
  pass "STS audience already exists"
fi

# --------------------------------------------------
# 9. Generate IAM trust policy
# --------------------------------------------------

log "Generating IAM trust policy"

jq -n \
  --arg provider "$PROVIDER_ARN" \
  --arg subject "$SUBJECT" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Principal: {
          Federated: $provider
        },
        Action: "sts:AssumeRoleWithWebIdentity",
        Condition: {
          StringEquals: {
            "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
            "token.actions.githubusercontent.com:sub": $subject
          }
        }
      }
    ]
  }' > "$TRUST_POLICY"

jq . "$TRUST_POLICY" >/dev/null ||
  fail "Generated trust policy is invalid JSON"

pass "Trust policy generated"

# --------------------------------------------------
# 10. Create or update IAM role
# --------------------------------------------------

log "Checking IAM role"

if aws iam get-role \
  --role-name "$ROLE_NAME" \
  >/dev/null 2>&1; then

  log "Updating existing IAM role trust policy"

  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://${TRUST_POLICY}"

  pass "Existing IAM role trust policy updated"

else

  log "Creating IAM role"

  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${TRUST_POLICY}" \
    --description "GitHub Actions OIDC role for infrastructure provisioning" \
    --max-session-duration 3600

  pass "IAM role created"
fi

# --------------------------------------------------
# 11. Configure GitHub repository variables
# --------------------------------------------------

log "Updating GitHub repository variables"

gh variable set AWS_PROVISION_ROLE_ARN \
  --repo "$REPO" \
  --body "$ROLE_ARN"

gh variable set AWS_REGION \
  --repo "$REPO" \
  --body "$AWS_REGION"

pass "GitHub variables updated"

# --------------------------------------------------
# 12. Verify workflow configuration
# --------------------------------------------------

log "Checking local workflow file"

[[ -f "$WORKFLOW_FILE" ]] ||
  fail "Workflow not found: ${WORKFLOW_FILE}"

grep -Eq '^[[:space:]]*id-token:[[:space:]]*write[[:space:]]*$' \
  "$WORKFLOW_FILE" ||
  fail "Workflow must include permissions: id-token: write"

grep -Fq 'vars.AWS_PROVISION_ROLE_ARN' "$WORKFLOW_FILE" ||
  fail "Workflow must reference vars.AWS_PROVISION_ROLE_ARN"

grep -Fq 'vars.AWS_REGION' "$WORKFLOW_FILE" ||
  fail "Workflow must reference vars.AWS_REGION"

pass "Workflow OIDC permissions and variables verified"

# --------------------------------------------------
# 13. Verify final AWS trust configuration
# --------------------------------------------------

log "Verifying final IAM trust policy"

FINAL_TRUST="$(
  aws iam get-role \
    --role-name "$ROLE_NAME" \
    --query 'Role.AssumeRolePolicyDocument' \
    --output json
)"

FINAL_SUB="$(
  jq -r '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]' \
    <<< "$FINAL_TRUST"
)"

FINAL_AUD="$(
  jq -r '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"]' \
    <<< "$FINAL_TRUST"
)"

[[ "$FINAL_SUB" == "$SUBJECT" ]] ||
  fail "IAM subject mismatch"

[[ "$FINAL_AUD" == "sts.amazonaws.com" ]] ||
  fail "IAM audience mismatch"

pass "IAM trust policy verified"

# --------------------------------------------------
# 14. Verify GitHub repository variables
# --------------------------------------------------

log "Verifying GitHub variables"

# Read the actual variable values from GitHub REST API.
# Do not use `gh variable get`; this command is unsupported
# in the installed GitHub CLI version.

ACTUAL_ROLE_ARN="$(
  gh api "repos/${REPO}/actions/variables/AWS_PROVISION_ROLE_ARN" \
    --jq '.value'
)"

ACTUAL_REGION="$(
  gh api "repos/${REPO}/actions/variables/AWS_REGION" \
    --jq '.value'
)"

# Compare GitHub values with expected configuration.
[[ "$ACTUAL_ROLE_ARN" == "$ROLE_ARN" ]] ||
  fail "GitHub Role ARN variable mismatch"

[[ "$ACTUAL_REGION" == "$AWS_REGION" ]] ||
  fail "GitHub region variable mismatch"

pass "GitHub variables verified"

# --------------------------------------------------
# 15. Final result
# --------------------------------------------------

echo
echo "=============================================="
echo " AWS GITHUB OIDC CONFIGURATION COMPLETE"
echo "=============================================="
echo "AWS Account : ${AWS_ACCOUNT_ID}"
echo "AWS Region  : ${AWS_REGION}"
echo "Repository  : ${REPO}"
echo "Branch      : ${BRANCH}"
echo "Role        : ${ROLE_ARN}"
echo "Subject     : ${SUBJECT}"
echo "=============================================="
echo
echo "Next: run an OIDC authentication test workflow."
echo "Note: This script configures trust, not provisioning permissions."
