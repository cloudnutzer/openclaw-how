#!/usr/bin/env bash
#===============================================================================
# update_moltbot.sh - Openclaw (Moltbot) Safe Update Script
# Erstellt automatisches Backup von Config & .env vor jedem Container-Update.
#
# Ausfuehrung: ./update_moltbot.sh [--force] [--service <name>]
#===============================================================================
set -euo pipefail

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="${HOME}/openclaw"
BACKUP_DIR="${INSTALL_DIR}/backups"
CONFIG_DIR="${INSTALL_DIR}/config"
LOG_DIR="${INSTALL_DIR}/logs"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

FORCE=false
TARGET_SERVICE=""
MAX_BACKUPS=30

#-------------------------------------------------------------------------------
# Argumente parsen
#-------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)     FORCE=true; shift ;;
        --service)   TARGET_SERVICE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--force] [--service <name>]"
            echo ""
            echo "  --force           Update ohne Bestaetigung"
            echo "  --service <name>  Nur bestimmten Service updaten"
            echo "                    (openclaw, n8n, whatsapp-bridge, telegram-bot)"
            exit 0
            ;;
        *)
            echo "Unbekannte Option: $1"
            exit 1
            ;;
    esac
done

#-------------------------------------------------------------------------------
# Hilfsfunktionen
#-------------------------------------------------------------------------------
log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}=== $1 ===${NC}"; }

timestamp() { date +"%Y%m%d_%H%M%S"; }

#-------------------------------------------------------------------------------
# Preflight
#-------------------------------------------------------------------------------
if [ ! -f "$COMPOSE_FILE" ]; then
    log_error "docker-compose.yml nicht gefunden unter ${INSTALL_DIR}"
    log_error "Fuehre zuerst setup_moltbot.sh aus."
    exit 1
fi

cd "$INSTALL_DIR"

#-------------------------------------------------------------------------------
# Schritt 1: Backup erstellen
#-------------------------------------------------------------------------------
log_step "Backup erstellen"

BACKUP_NAME="backup_$(timestamp)"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"
mkdir -p "$BACKUP_PATH"

# Config-Dateien sichern
if [ -d "$CONFIG_DIR" ]; then
    cp -r "$CONFIG_DIR" "${BACKUP_PATH}/config"
    log_info "Config gesichert -> ${BACKUP_PATH}/config/"
fi

# docker-compose.yml sichern
if [ -f "$COMPOSE_FILE" ]; then
    cp "$COMPOSE_FILE" "${BACKUP_PATH}/docker-compose.yml"
    log_info "docker-compose.yml gesichert"
fi

# .env sichern (das Symlink-Ziel)
if [ -f "${CONFIG_DIR}/.env" ]; then
    cp "${CONFIG_DIR}/.env" "${BACKUP_PATH}/.env"
    chmod 600 "${BACKUP_PATH}/.env"
    log_info ".env gesichert (chmod 600)"
fi

# n8n Workflows sichern (falls vorhanden)
if [ -d "${INSTALL_DIR}/n8n-data" ]; then
    # Nur die Workflow-Definitionen, nicht die gesamte DB
    if [ -f "${INSTALL_DIR}/n8n-data/database.sqlite" ]; then
        cp "${INSTALL_DIR}/n8n-data/database.sqlite" "${BACKUP_PATH}/n8n-database.sqlite"
        log_info "n8n Datenbank gesichert"
    fi
fi

# Container-Versionen dokumentieren
docker compose ps --format json 2>/dev/null > "${BACKUP_PATH}/container-state.json" || true
docker compose images 2>/dev/null > "${BACKUP_PATH}/image-versions.txt" || true

log_info "Backup komplett: ${BACKUP_PATH}"

# Backup-Integritaet pruefen
BACKUP_SIZE=$(du -sh "$BACKUP_PATH" | cut -f1)
FILE_COUNT=$(find "$BACKUP_PATH" -type f | wc -l | tr -d ' ')
log_info "Backup-Groesse: ${BACKUP_SIZE}, Dateien: ${FILE_COUNT}"

#-------------------------------------------------------------------------------
# Schritt 2: Alte Backups aufraeumen
#-------------------------------------------------------------------------------
BACKUP_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "backup_*" | wc -l | tr -d ' ')
if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    REMOVE_COUNT=$((BACKUP_COUNT - MAX_BACKUPS))
    log_info "Entferne ${REMOVE_COUNT} alte Backups (behalte letzte ${MAX_BACKUPS})"
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "backup_*" | sort | head -n "$REMOVE_COUNT" | while read -r old_backup; do
        rm -rf "$old_backup"
        log_info "  Entfernt: $(basename "$old_backup")"
    done
fi

#-------------------------------------------------------------------------------
# Schritt 3: Update-Bestaetigung
#-------------------------------------------------------------------------------
if [ "$FORCE" = false ]; then
    echo ""
    log_info "Aktuelle Container:"
    docker compose ps 2>/dev/null || true
    echo ""

    if [ -n "$TARGET_SERVICE" ]; then
        echo -ne "${YELLOW}Service '${TARGET_SERVICE}' updaten? (j/N): ${NC}"
    else
        echo -ne "${YELLOW}Alle Services updaten? (j/N): ${NC}"
    fi
    read -r confirm
    if [[ ! "$confirm" =~ ^[jJyY]$ ]]; then
        log_info "Update abgebrochen. Backup bleibt erhalten unter: ${BACKUP_PATH}"
        exit 0
    fi
fi

#-------------------------------------------------------------------------------
# Schritt 4: Images pullen
#-------------------------------------------------------------------------------
log_step "Neue Images herunterladen"

if [ -n "$TARGET_SERVICE" ]; then
    docker compose pull "$TARGET_SERVICE"
else
    docker compose pull
fi

#-------------------------------------------------------------------------------
# Schritt 5: Container neu starten
#-------------------------------------------------------------------------------
log_step "Container neu starten"

if [ -n "$TARGET_SERVICE" ]; then
    docker compose up -d "$TARGET_SERVICE"
else
    docker compose up -d
fi

#-------------------------------------------------------------------------------
# Schritt 6: Health-Check
#-------------------------------------------------------------------------------
log_step "Health-Check"

sleep 5

UNHEALTHY=0
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | awk '{print $NF}')
    if echo "$state" | grep -qi "unhealthy\|exit"; then
        log_error "Container ${name} ist ${state}!"
        UNHEALTHY=$((UNHEALTHY + 1))
    else
        log_info "Container ${name}: ${state}"
    fi
done < <(docker compose ps 2>/dev/null | tail -n +2)

if [ "$UNHEALTHY" -gt 0 ]; then
    log_error "${UNHEALTHY} Container sind nicht gesund!"
    log_warn "Rollback mit: cd ${INSTALL_DIR} && cp ${BACKUP_PATH}/docker-compose.yml . && docker compose up -d"
    exit 1
fi

#-------------------------------------------------------------------------------
# Schritt 7: Update-Log schreiben
#-------------------------------------------------------------------------------
UPDATE_LOG="${LOG_DIR}/updates.log"
{
    echo "---"
    echo "timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "backup: ${BACKUP_NAME}"
    echo "target: ${TARGET_SERVICE:-all}"
    echo "result: success"
    echo "images:"
    docker compose images 2>/dev/null | tail -n +2
} >> "$UPDATE_LOG"

#-------------------------------------------------------------------------------
# Zusammenfassung
#-------------------------------------------------------------------------------
log_step "Update abgeschlossen"

echo ""
log_info "Backup:    ${BACKUP_PATH}"
log_info "Update-Log: ${UPDATE_LOG}"
echo ""
log_info "Bei Problemen Rollback ausfuehren:"
echo -e "  ${CYAN}cd ${INSTALL_DIR}${NC}"
echo -e "  ${CYAN}cp ${BACKUP_PATH}/docker-compose.yml .${NC}"
echo -e "  ${CYAN}cp ${BACKUP_PATH}/config/* config/${NC}"
echo -e "  ${CYAN}docker compose up -d${NC}"
echo ""
