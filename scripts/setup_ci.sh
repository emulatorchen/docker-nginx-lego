#!/usr/bin/env bash
# setup_ci.sh — Bootstrap CI for a new GitHub repo with Docker Hub publishing.
#
# Handles:
#   - GitHub Actions settings (enable, fork PR approval)
#   - GitHub secrets and repository variables
#   - Docker Hub repository creation
#
# Usage:
#   ./scripts/setup_ci.sh              # dry-run: show what would change
#   ./scripts/setup_ci.sh --apply      # execute all changes
#
# Prerequisites:
#   - gh CLI (https://cli.github.com), authenticated: gh auth login
#   - curl, jq
#
# To adapt for another project, edit the CONFIG section below.
# Everything below the CONFIG section is generic and should not need changes.
#
# Secrets and tokens are never passed as arguments. The script prompts
# interactively or reads from environment variables:
#
#   DOCKERHUB_PASSWORD   Docker Hub password (for login + repo creation)
#   DOCKERHUB_TOKEN      Docker Hub access token (stored as GitHub secret)
#   FREEMYIP_TOKEN       FreeMyIP token (stored as GitHub secret)
#
# Any variable not set in the environment will be prompted for interactively.
# Set a variable to "" (empty string) to skip storing that secret/variable.

set -euo pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
# Edit this section when adapting for a new project.

# GitHub repo in "owner/name" format.
GITHUB_REPO="emulatorchen/docker-nginx-certbot"

# Docker Hub namespace and repository name.
DOCKERHUB_USERNAME="emulator"
DOCKERHUB_REPO="docker-nginx-lego"
DOCKERHUB_REPO_DESCRIPTION="Nginx + automated SSL via Let's Encrypt and lego"
DOCKERHUB_REPO_PRIVATE=false

# GitHub secrets to set (name → env var to read value from).
# Set the value to "" to skip that secret.
declare -A GITHUB_SECRETS=(
    [DOCKERHUB_USERNAME]="DOCKERHUB_USERNAME"   # reuse the config value above
    [DOCKERHUB_TOKEN]="DOCKERHUB_TOKEN"
    [FREEMYIP_TOKEN]="FREEMYIP_TOKEN"
)

# GitHub repository variables to set (name → value).
# Set the value to "" to skip that variable.
declare -A GITHUB_VARS=(
    [FREEMYIP_DOMAIN]="this.freemyip.com"
    [FREEMYIP_CERT_NAME]="this-freemyip.dns-freemyip"
)

# ─── END CONFIG ───────────────────────────────────────────────────────────────

APPLY=false
if [[ "${1:-}" == "--apply" ]]; then
    APPLY=true
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[info]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ok]${NC}    $*"; }
plan()    { echo -e "${YELLOW}[plan]${NC}  $*"; }
err()     { echo -e "${RED}[error]${NC} $*" >&2; }

apply() {
    # apply <description> <command...>
    local desc="$1"; shift
    if $APPLY; then
        info "Applying: ${desc}"
        "$@"
    else
        plan "${desc}"
    fi
}

prompt_secret() {
    # prompt_secret <var_name> <prompt_text>
    # Sets the variable named by $1. Reads from env first, then prompts.
    local var="$1" prompt="$2" value
    value="${!var:-}"
    if [[ -z "$value" ]]; then
        read -rsp "  Enter ${prompt} (or press Enter to skip): " value
        echo
    fi
    printf -v "$var" '%s' "$value"
}

check_prereqs() {
    local ok=true
    for cmd in gh curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Missing prerequisite: $cmd"
            ok=false
        fi
    done
    if ! gh auth status &>/dev/null; then
        err "gh CLI not authenticated. Run: gh auth login"
        ok=false
    fi
    $ok || exit 1
}

# ─── Docker Hub ───────────────────────────────────────────────────────────────

dockerhub_login() {
    prompt_secret DOCKERHUB_PASSWORD "Docker Hub password for '${DOCKERHUB_USERNAME}'"
    [[ -z "$DOCKERHUB_PASSWORD" ]] && { info "Skipping Docker Hub login (no password)"; return 1; }

    DOCKERHUB_AUTH_TOKEN=$(curl -s -X POST "https://hub.docker.com/v2/users/login/" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${DOCKERHUB_USERNAME}\",\"password\":\"${DOCKERHUB_PASSWORD}\"}" \
        | jq -r '.token // empty')

    if [[ -z "$DOCKERHUB_AUTH_TOKEN" ]]; then
        err "Docker Hub login failed. Check credentials."
        return 1
    fi
    ok "Docker Hub login succeeded"
    return 0
}

setup_dockerhub_repo() {
    info "--- Docker Hub ---"

    # Check if repo already exists
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" \
        "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/${DOCKERHUB_REPO}/")

    if [[ "$status" == "200" ]]; then
        ok "Docker Hub repo '${DOCKERHUB_USERNAME}/${DOCKERHUB_REPO}' already exists"
        return
    fi

    apply "Create Docker Hub repo: ${DOCKERHUB_USERNAME}/${DOCKERHUB_REPO} (private=${DOCKERHUB_REPO_PRIVATE})" \
        bash -c "
            dockerhub_login || exit 1
            curl -sf -X POST 'https://hub.docker.com/v2/repositories/' \
                -H 'Authorization: Bearer ${DOCKERHUB_AUTH_TOKEN}' \
                -H 'Content-Type: application/json' \
                -d '{
                    \"name\": \"${DOCKERHUB_REPO}\",
                    \"namespace\": \"${DOCKERHUB_USERNAME}\",
                    \"description\": \"${DOCKERHUB_REPO_DESCRIPTION}\",
                    \"is_private\": ${DOCKERHUB_REPO_PRIVATE}
                }' | jq -r '.name' && echo '[ok] Docker Hub repo created'
        "
}

# ─── GitHub ───────────────────────────────────────────────────────────────────

setup_github_actions() {
    info "--- GitHub Actions settings ---"

    apply "Enable GitHub Actions on ${GITHUB_REPO}" \
        gh api -X PUT "repos/${GITHUB_REPO}/actions/permissions" \
            -f enabled=true \
            -f allowed_actions=all

    apply "Set fork PR workflow approval to 'all outside collaborators' on ${GITHUB_REPO}" \
        gh api -X PUT "repos/${GITHUB_REPO}/actions/permissions/workflow" \
            -f default_workflow_permissions=read \
            -f can_approve_pull_request_reviews=false \
            --field fork_pull_request_workflows_require_approval=true
}

setup_github_secrets() {
    info "--- GitHub secrets ---"

    # DOCKERHUB_USERNAME is a config value, not prompted
    if [[ -n "${DOCKERHUB_USERNAME}" ]]; then
        apply "Set GitHub secret: DOCKERHUB_USERNAME" \
            gh secret set DOCKERHUB_USERNAME \
                --repo "${GITHUB_REPO}" \
                --body "${DOCKERHUB_USERNAME}"
    fi

    for secret_name in "${!GITHUB_SECRETS[@]}"; do
        [[ "$secret_name" == "DOCKERHUB_USERNAME" ]] && continue  # handled above
        local env_var="${GITHUB_SECRETS[$secret_name]}"
        prompt_secret "$env_var" "${secret_name}"
        local value="${!env_var:-}"
        if [[ -z "$value" ]]; then
            info "Skipping secret: ${secret_name} (no value)"
            continue
        fi
        apply "Set GitHub secret: ${secret_name}" \
            gh secret set "${secret_name}" \
                --repo "${GITHUB_REPO}" \
                --body "${value}"
    done
}

setup_github_vars() {
    info "--- GitHub repository variables ---"

    for var_name in "${!GITHUB_VARS[@]}"; do
        local value="${GITHUB_VARS[$var_name]}"
        if [[ -z "$value" ]]; then
            info "Skipping variable: ${var_name} (no value configured)"
            continue
        fi
        # Check if variable already exists
        local existing
        existing=$(gh api "repos/${GITHUB_REPO}/actions/variables/${var_name}" \
            --jq '.value' 2>/dev/null || echo "")
        if [[ "$existing" == "$value" ]]; then
            ok "GitHub variable ${var_name} already set to '${value}'"
            continue
        fi
        apply "Set GitHub variable: ${var_name}=${value}" \
            gh variable set "${var_name}" \
                --repo "${GITHUB_REPO}" \
                --body "${value}"
    done
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo
    if $APPLY; then
        echo -e "${GREEN}Running in APPLY mode — changes will be made.${NC}"
    else
        echo -e "${YELLOW}Running in DRY-RUN mode — no changes will be made.${NC}"
        echo -e "${YELLOW}Re-run with --apply to execute.${NC}"
    fi
    echo

    check_prereqs
    setup_dockerhub_repo
    setup_github_actions
    setup_github_secrets
    setup_github_vars

    echo
    if $APPLY; then
        ok "Setup complete."
        echo
        echo "Next steps:"
        echo "  1. Push your branch:  git push -u origin feat/lego-only"
        echo "  2. Open a PR and verify CI passes"
        echo "  3. Merge to master, then tag the first release:"
        echo "       git tag lego4.33.0-nginx1.29.5"
        echo "       git push origin lego4.33.0-nginx1.29.5"
    else
        plan "Review the plan above, then run with --apply to execute."
    fi
    echo
}

main
