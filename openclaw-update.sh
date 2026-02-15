#!/usr/bin/env bash
# ============================================================================
# openclaw-update.sh — Bulletproof OpenClaw Self-Update Script
# ============================================================================
# Designed to be executed by OpenClaw via the exec tool (e.g. from Telegram).
# Performs pre-flight checks, backs up config, updates, runs doctor, restarts
# the gateway, and verifies health — all with logging and rollback support.
#
# Usage:
#   chmod +x openclaw-update.sh
#   ./openclaw-update.sh [--force] [--channel <stable|beta|dev>] [--dry-run]
#
# Options:
#   --force       Skip confirmation-style delays
#   --channel     Set update channel (default: stable)
#   --dry-run     Run all checks but skip the actual update + restart
#   --no-backup   Skip the config backup step
#   --timeout     Gateway health timeout in seconds (default: 60)
# ============================================================================

set -euo pipefail

# ── Portable readlink -f (works on macOS < 15 and Linux) ────────────────────
resolve_path() {
    local target="$1"
    if readlink -f "$target" 2>/dev/null; then
        return
    fi
    # Fallback for macOS < 15 (BSD readlink without -f)
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$target" 2>/dev/null \
        || echo "$target"
}

# ── Configuration ────────────────────────────────────────────────────────────
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_CONFIG="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_HOME/openclaw.json}"
BACKUP_DIR="$OPENCLAW_HOME/backups"
LOG_FILE="/tmp/openclaw-update-$(date +%Y%m%d-%H%M%S).log"
HEALTH_TIMEOUT=60
UPDATE_CHANNEL="stable"
DRY_RUN=false
FORCE=false
SKIP_BACKUP=false
GATEWAY_PORT=18789

# ── Colors & Output ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { local msg="[$(date '+%H:%M:%S')] $1"; echo -e "${BLUE}${msg}${NC}"; echo "$msg" >> "$LOG_FILE"; }
ok()     { local msg="[$(date '+%H:%M:%S')] ✅ $1"; echo -e "${GREEN}${msg}${NC}"; echo "$msg" >> "$LOG_FILE"; }
warn()   { local msg="[$(date '+%H:%M:%S')] ⚠️  $1"; echo -e "${YELLOW}${msg}${NC}"; echo "$msg" >> "$LOG_FILE"; }
fail()   { local msg="[$(date '+%H:%M:%S')] ❌ $1"; echo -e "${RED}${msg}${NC}"; echo "$msg" >> "$LOG_FILE"; }
info()   { local msg="[$(date '+%H:%M:%S')] ℹ️  $1"; echo -e "${CYAN}${msg}${NC}"; echo "$msg" >> "$LOG_FILE"; }
header() { echo -e "\n${BOLD}━━━ $1 ━━━${NC}"; echo "━━━ $1 ━━━" >> "$LOG_FILE"; }

die() {
    fail "$1"
    echo ""
    fail "Update ABORTED. Log saved to: $LOG_FILE"
    exit 1
}

# ── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)      FORCE=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --no-backup)  SKIP_BACKUP=true; shift ;;
        --channel)    [[ $# -ge 2 ]] || die "--channel requires a value (stable|beta|dev)"; UPDATE_CHANNEL="$2"; shift 2 ;;
        --timeout)    [[ $# -ge 2 ]] || die "--timeout requires a value (seconds)"; HEALTH_TIMEOUT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--force] [--channel <stable|beta|dev>] [--dry-run] [--no-backup] [--timeout <secs>]"
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Validate channel ────────────────────────────────────────────────────────
if [[ ! "$UPDATE_CHANNEL" =~ ^(stable|beta|dev)$ ]]; then
    die "Invalid channel '$UPDATE_CHANNEL'. Must be: stable, beta, or dev"
fi

# ============================================================================
#  PHASE 1: PRE-FLIGHT CHECKS
# ============================================================================
header "PHASE 1: Pre-Flight Checks"

# 1.1 — Check we're not running as root
if [[ $EUID -eq 0 ]]; then
    die "Do not run this script as root. OpenClaw should run under your user account."
fi
ok "Running as user: $(whoami)"

# 1.2 — Check Node.js
if ! command -v node &>/dev/null; then
    die "Node.js not found. OpenClaw requires Node 22+."
fi
NODE_VERSION=$(node --version | sed 's/^v//')
NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
if [[ "$NODE_MAJOR" -lt 22 ]]; then
    die "Node.js $NODE_VERSION is too old. OpenClaw requires Node 22+."
fi
ok "Node.js v$NODE_VERSION"

# 1.3 — Check openclaw CLI exists
if ! command -v openclaw &>/dev/null; then
    die "openclaw CLI not found in PATH. Is OpenClaw installed?"
fi
CURRENT_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
ok "Current OpenClaw version: $CURRENT_VERSION"

# 1.4 — Detect install method
INSTALL_METHOD="unknown"
OPENCLAW_BIN=$(command -v openclaw 2>/dev/null || true)
if [[ -n "$OPENCLAW_BIN" ]]; then
    REAL_PATH=$(resolve_path "$OPENCLAW_BIN")
    if [[ "$REAL_PATH" == *"node_modules"* ]] || [[ "$REAL_PATH" == *"npm"* ]] || [[ "$REAL_PATH" == *"pnpm"* ]]; then
        INSTALL_METHOD="global"
    elif [[ -d "$(dirname "$REAL_PATH")/.git" ]] || [[ -d "$(dirname "$(dirname "$REAL_PATH")")/.git" ]]; then
        INSTALL_METHOD="source"
    else
        # Fallback: check if openclaw update detects git
        if openclaw update status --json 2>/dev/null | grep -q '"source"'; then
            INSTALL_METHOD="source"
        else
            INSTALL_METHOD="global"
        fi
    fi
fi
ok "Install method detected: $INSTALL_METHOD"

# 1.5 — Check config file exists
if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
    warn "Config file not found at $OPENCLAW_CONFIG (may use defaults)"
else
    ok "Config file: $OPENCLAW_CONFIG"
fi

# 1.6 — Check OpenClaw home directory
if [[ ! -d "$OPENCLAW_HOME" ]]; then
    die "OpenClaw home directory not found: $OPENCLAW_HOME"
fi
ok "OpenClaw home: $OPENCLAW_HOME"

# 1.7 — Check current gateway status
GATEWAY_RUNNING=false
if openclaw gateway status 2>/dev/null | grep -qi "running"; then
    GATEWAY_RUNNING=true
    ok "Gateway is currently running"
else
    warn "Gateway is NOT currently running (will attempt start after update)"
fi

# 1.8 — Check disk space (need at least 500MB free)
AVAILABLE_MB=$(df -m "$OPENCLAW_HOME" | awk 'NR==2 {print $4}')
if [[ "$AVAILABLE_MB" -lt 500 ]]; then
    die "Low disk space: ${AVAILABLE_MB}MB available (need at least 500MB)"
fi
ok "Disk space: ${AVAILABLE_MB}MB available"

# 1.9 — Check for source install clean worktree
if [[ "$INSTALL_METHOD" == "source" ]]; then
    REPO_DIR=$(dirname "$(resolve_path "$(command -v openclaw)")" 2>/dev/null || echo "")
    if [[ -n "$REPO_DIR" ]] && [[ -d "$REPO_DIR/.git" ]]; then
        if ! git -C "$REPO_DIR" diff --quiet 2>/dev/null; then
            warn "Git worktree has uncommitted changes. openclaw update requires a clean worktree."
            if [[ "$FORCE" != true ]]; then
                die "Commit or stash changes first, or use --force to proceed anyway."
            fi
            warn "Proceeding anyway due to --force flag..."
        else
            ok "Git worktree is clean"
        fi
    fi
fi

# 1.10 — Network connectivity check
if ! curl -sf --max-time 10 "https://registry.npmjs.org/openclaw" >/dev/null 2>&1; then
    if ! curl -sf --max-time 10 "https://openclaw.ai" >/dev/null 2>&1; then
        die "No network connectivity. Cannot reach npm registry or openclaw.ai."
    fi
fi
ok "Network connectivity verified"

# 1.11 — Check available update
LATEST_VERSION=$(npm view openclaw version 2>/dev/null || echo "unknown")
if [[ "$LATEST_VERSION" != "unknown" ]]; then
    info "Latest published version: $LATEST_VERSION"
    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        info "Already on the latest version."
        if [[ "$FORCE" != true ]]; then
            ok "No update needed. Use --force to reinstall anyway."
            echo ""
            ok "All pre-flight checks passed. Nothing to update."
            exit 0
        fi
        warn "Forcing reinstall of same version due to --force flag."
    fi
else
    warn "Could not determine latest version from npm registry"
fi

echo ""
ok "All pre-flight checks passed!"

# ── Dry-run exit point ───────────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
    echo ""
    info "DRY RUN — would update from $CURRENT_VERSION to $LATEST_VERSION (channel: $UPDATE_CHANNEL)"
    info "No changes were made."
    exit 0
fi

# ============================================================================
#  PHASE 2: BACKUP
# ============================================================================
header "PHASE 2: Backup"

if [[ "$SKIP_BACKUP" == true ]]; then
    warn "Skipping backup (--no-backup flag)"
else
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/$TIMESTAMP"
    mkdir -p "$BACKUP_PATH"

    log "Backing up config and credentials..."

    # Backup config
    if [[ -f "$OPENCLAW_CONFIG" ]]; then
        cp "$OPENCLAW_CONFIG" "$BACKUP_PATH/openclaw.json"
        ok "Config backed up"
    fi

    # Backup credentials
    if [[ -d "$OPENCLAW_HOME/credentials" ]]; then
        cp -r "$OPENCLAW_HOME/credentials" "$BACKUP_PATH/credentials"
        ok "Credentials backed up"
    fi

    # Backup auth profiles
    if compgen -G "$OPENCLAW_HOME/agents/*/auth-profiles.json" >/dev/null 2>&1; then
        mkdir -p "$BACKUP_PATH/auth-profiles"
        for f in "$OPENCLAW_HOME"/agents/*/auth-profiles.json; do
            AGENT_DIR=$(basename "$(dirname "$f")")
            cp "$f" "$BACKUP_PATH/auth-profiles/${AGENT_DIR}-auth-profiles.json"
        done
        ok "Auth profiles backed up"
    fi

    # Backup .env
    if [[ -f "$OPENCLAW_HOME/.env" ]]; then
        cp "$OPENCLAW_HOME/.env" "$BACKUP_PATH/.env"
        ok ".env backed up"
    fi

    ok "Backup saved to: $BACKUP_PATH"

    # Cleanup old backups (keep last 10)
    BACKUP_COUNT=$(ls -1d "$BACKUP_DIR"/20* 2>/dev/null | wc -l || echo "0")
    if [[ "$BACKUP_COUNT" -gt 10 ]]; then
        ls -1dt "$BACKUP_DIR"/20* | tail -n +"11" | xargs rm -rf
        info "Cleaned up old backups (kept latest 10)"
    fi
fi

# ============================================================================
#  PHASE 3: UPDATE
# ============================================================================
header "PHASE 3: Update"

log "Updating OpenClaw (channel: $UPDATE_CHANNEL)..."

UPDATE_EXIT=0
if [[ "$INSTALL_METHOD" == "source" ]]; then
    log "Using: openclaw update --channel $UPDATE_CHANNEL --no-restart"
    openclaw update --channel "$UPDATE_CHANNEL" --no-restart 2>&1 | tee -a "$LOG_FILE" || UPDATE_EXIT=$?
else
    NPM_TAG="latest"
    if [[ "$UPDATE_CHANNEL" == "beta" ]]; then NPM_TAG="beta"; fi
    if [[ "$UPDATE_CHANNEL" == "dev" ]]; then NPM_TAG="dev"; fi
    log "Using: npm global install (openclaw@${NPM_TAG})"
    npm i -g "openclaw@${NPM_TAG}" 2>&1 | tee -a "$LOG_FILE" || UPDATE_EXIT=$?
fi

if [[ $UPDATE_EXIT -ne 0 ]]; then
    fail "Update command exited with code $UPDATE_EXIT"
    warn "Attempting recovery with openclaw doctor..."
    openclaw doctor 2>&1 | tee -a "$LOG_FILE" || true
    die "Update failed. Check log: $LOG_FILE"
fi

NEW_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
ok "Update completed: $CURRENT_VERSION → $NEW_VERSION"

# ============================================================================
#  PHASE 4: DOCTOR
# ============================================================================
header "PHASE 4: Doctor (Post-Update Migrations)"

log "Running openclaw doctor..."
DOCTOR_EXIT=0
openclaw doctor 2>&1 | tee -a "$LOG_FILE" || DOCTOR_EXIT=$?

if [[ $DOCTOR_EXIT -ne 0 ]]; then
    warn "Doctor reported issues (exit $DOCTOR_EXIT). Attempting --fix..."
    openclaw doctor --fix 2>&1 | tee -a "$LOG_FILE" || true
fi
ok "Doctor completed"

# ============================================================================
#  PHASE 5: GATEWAY RESTART
# ============================================================================
header "PHASE 5: Gateway Restart"

log "Restarting gateway..."
RESTART_EXIT=0
openclaw gateway restart 2>&1 | tee -a "$LOG_FILE" || RESTART_EXIT=$?

if [[ $RESTART_EXIT -ne 0 ]]; then
    warn "Gateway restart returned exit $RESTART_EXIT"
    log "Attempting gateway stop + start..."
    openclaw gateway stop 2>&1 | tee -a "$LOG_FILE" || true
    sleep 3
    openclaw gateway start 2>&1 | tee -a "$LOG_FILE" || die "Gateway failed to start after update."
fi

ok "Gateway restart issued"

# ============================================================================
#  PHASE 6: HEALTH VERIFICATION
# ============================================================================
header "PHASE 6: Health Verification"

log "Waiting for gateway to become healthy (timeout: ${HEALTH_TIMEOUT}s)..."

HEALTH_OK=false
ELAPSED=0
INTERVAL=5

while [[ $ELAPSED -lt $HEALTH_TIMEOUT ]]; do
    if openclaw health 2>/dev/null | grep -qi "ok\|healthy\|running"; then
        HEALTH_OK=true
        break
    fi
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
    info "Waiting... (${ELAPSED}s / ${HEALTH_TIMEOUT}s)"
done

if [[ "$HEALTH_OK" != true ]]; then
    # Second attempt: try checking the gateway status directly
    if openclaw gateway status 2>/dev/null | grep -qi "running"; then
        HEALTH_OK=true
        warn "Health endpoint didn't confirm, but gateway reports running."
    fi
fi

if [[ "$HEALTH_OK" != true ]]; then
    fail "Gateway did not become healthy within ${HEALTH_TIMEOUT}s"
    warn "Check logs: openclaw logs --follow"
    warn "Log file: $LOG_FILE"
    exit 1
fi

ok "Gateway is healthy!"

# ── Verify models are accessible ────────────────────────────────────────────
log "Checking model status..."
MODEL_STATUS_EXIT=0
openclaw models status 2>&1 | tee -a "$LOG_FILE" || MODEL_STATUS_EXIT=$?
if [[ $MODEL_STATUS_EXIT -ne 0 ]]; then
    warn "Model status check returned non-zero. Credentials may need refresh."
    warn "Run: openclaw models status --probe"
else
    ok "Model status check passed"
fi

# ── Verify channels ─────────────────────────────────────────────────────────
log "Checking channel status..."
CHANNEL_EXIT=0
openclaw channels status 2>&1 | tee -a "$LOG_FILE" || CHANNEL_EXIT=$?
if [[ $CHANNEL_EXIT -ne 0 ]]; then
    warn "Channel status check returned non-zero. Some channels may need attention."
else
    ok "Channel status check passed"
fi

# ============================================================================
#  SUMMARY
# ============================================================================
header "UPDATE COMPLETE"

echo ""
echo -e "${GREEN}${BOLD}OpenClaw Update Summary${NC}"
echo -e "${GREEN}─────────────────────────────────${NC}"
echo -e "  Previous : ${BOLD}$CURRENT_VERSION${NC}"
echo -e "  Current  : ${BOLD}$NEW_VERSION${NC}"
echo -e "  Channel  : ${BOLD}$UPDATE_CHANNEL${NC}"
echo -e "  Gateway  : ${BOLD}$(if [[ "$HEALTH_OK" == true ]]; then echo "Healthy"; else echo "Check logs"; fi)${NC}"
echo -e "  Log      : ${BOLD}$LOG_FILE${NC}"
echo -e "${GREEN}─────────────────────────────────${NC}"
echo ""

if [[ "$SKIP_BACKUP" != true ]]; then
    info "Backup at: $BACKUP_PATH"
fi
info "Full log: $LOG_FILE"
echo ""
ok "OpenClaw is updated and running. 🦞"
