#!/usr/bin/env bash
set -euo pipefail

# ----------------------
# Default variables
# ----------------------
: "${BACKUP_SRC:=/data}"
: "${BACKUP_DEST:=/backup}"
: "${SCALE_LABEL:=com.example.autobackup.enable}"
: "${SCALE_VALUE:=true}"
: "${DAILY_COUNT:=7}"
: "${WEEKLY_COUNT:=4}"
: "${MONTHLY_COUNT:=6}"
: "${EMAIL_ON_SUCCESS:=off}"
: "${EMAIL_ON_FAILURE:=on}"
: "${SMTP_SERVER:=smtp.example.com}"
: "${SMTP_PORT:=25}"
: "${SMTP_TLS:=off}"
: "${SMTP_USER:=}"
: "${SMTP_PASS:=}"
: "${EMAIL_TO:=admin@example.com}"
: "${EMAIL_FROM:=backup@example.com}"
: "${DRY_RUN:=off}"

LOG_FILE="/var/log/backup.log"
ORIG_REPLICAS_FILE="/tmp/original_replicas.$$"
RUN_LOG="/tmp/backup_run_$$.log"

touch "$ORIG_REPLICAS_FILE" "$RUN_LOG"
chmod 600 "$ORIG_REPLICAS_FILE" "$RUN_LOG"

cleanup() { rm -f "$ORIG_REPLICAS_FILE" "$RUN_LOG" || true; }
trap cleanup EXIT

# ----------------------
# Logging
# ----------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" -a "$RUN_LOG"
}

# ----------------------
# Email sending
# ----------------------
send_email() {
    local subject="$1"
    local status="$2"

    # Skip sending if conditions not met
    if [[ "$status" == "success" && "$EMAIL_ON_SUCCESS" != "on" ]]; then return; fi
    if [[ "$status" == "failure" && "$EMAIL_ON_FAILURE" != "on" ]]; then return; fi

    # Read only current run log
    local body
    body=$(cat "$RUN_LOG")

    # Send email using msmtp and capture errors in main backup log
    if ! printf "To: %s\nFrom: %s\nSubject: %s\n\n%s" \
        "$EMAIL_TO" "$EMAIL_FROM" "$subject" "$body" \
        | msmtp --file /etc/msmtp/msmtprc -t >>"$LOG_FILE" 2>&1; then
        log "Email send failed. Check SMTP server or credentials."
    fi
}

# ----------------------
# Pre-link pruning
# ----------------------
if [[ -d "$BACKUP_DEST" ]]; then
    log "Pre-link pruning old dirs (>30 days)..."
    if [[ "$DRY_RUN" != "on" ]]; then
        find "$BACKUP_DEST" -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true
    else
        log "[DRY-RUN] would prune old dirs in $BACKUP_DEST"
    fi
fi

# ----------------------
# Prepare daily backup folder
# ----------------------
daily_dir="$BACKUP_DEST/daily"
timestamp=$(date +%Y-%m-%d_%H-%M-%S)
backup_dir="$daily_dir/$timestamp"

if [[ "$DRY_RUN" != "on" ]]; then
    mkdir -p "$daily_dir"
    mkdir -p "$backup_dir"
else
    log "[DRY-RUN] would create $backup_dir"
fi

# ----------------------
# Pre-populate from previous latest
# ----------------------
if [[ -L "$BACKUP_DEST/latest" && -d "$BACKUP_DEST/latest" ]]; then
    log "Pre-populating new backup from latest..."
    if [[ "$DRY_RUN" != "on" ]]; then
        cp -al "$BACKUP_DEST/latest/." "$backup_dir/" 2>/dev/null || true
    else
        log "[DRY-RUN] would cp -al $BACKUP_DEST/latest/. $backup_dir/"
    fi
else
    log "No previous backup found; starting fresh."
fi

# ----------------------
# Scale down services (quiet)
# ----------------------
services=$(docker service ls -q --filter "label=${SCALE_LABEL}=${SCALE_VALUE}" || true)
if [[ -n "$services" ]]; then
    log "Scaling down services:"
    while read -r svc; do
        [[ -z "$svc" ]] && continue
        name=$(docker service inspect --format '{{.Spec.Name}}' "$svc" 2>/dev/null || echo "$svc")
        replicas=$(docker service inspect --format '{{.Spec.Mode.Replicated.Replicas}}' "$svc" 2>/dev/null || echo "0")
        echo "${name}:${replicas}" >> "$ORIG_REPLICAS_FILE"
        log "  - $name (replicas: $replicas)"
        if [[ "$DRY_RUN" == "on" ]]; then
            log "[DRY-RUN] would scale $name to 0"
        else
            docker service scale "$name=0" >/dev/null 2>&1 || log "Warning: scaling down $name failed"
        fi
    done <<< "$services"
else
    log "No services matched for scaling."
fi

# ----------------------
# Daily rsync backup
# ----------------------
RSYNC_CMD="rsync -aH --delete --link-dest=$BACKUP_DEST/latest $BACKUP_SRC/ $backup_dir/"
if [[ "$DRY_RUN" == "on" ]]; then RSYNC_CMD="$RSYNC_CMD --dry-run"; fi

log "Running daily backup"
eval "$RSYNC_CMD" >> "$RUN_LOG" 2>&1
log "Daily backup complete"

# ----------------------
# Update latest symlink
# ----------------------
if [[ "$DRY_RUN" != "on" ]]; then
    ( cd "$BACKUP_DEST" && ln -sfn "daily/$(basename "$backup_dir")" latest )
    log "Updated latest -> daily/$(basename "$backup_dir")"
else
    log "[DRY-RUN] would update latest symlink"
fi

# ----------------------
# Restore services (quiet)
# ----------------------
if [[ -s "$ORIG_REPLICAS_FILE" ]]; then
    log "Restoring services:"
    while IFS=: read -r name replicas; do
        [[ -z "$name" ]] && continue
        if [[ "$DRY_RUN" == "on" ]]; then
            log "[DRY-RUN] would scale $name to $replicas"
        else
            docker service scale "$name=$replicas" >/dev/null 2>&1 || log "Warning: restore failed for $name"
        fi
        log "  - $name -> $replicas"
    done < "$ORIG_REPLICAS_FILE"
else
    log "No recorded replicas to restore."
fi

# ----------------------
# Weekly / Monthly GFS
# ----------------------
weekly_dir="$BACKUP_DEST/weekly"
monthly_dir="$BACKUP_DEST/monthly"
[[ "$DRY_RUN" != "on" ]] && mkdir -p "$weekly_dir" "$monthly_dir"

if [[ $(date +%u) -eq 7 ]]; then
    log "Creating weekly snapshot..."
    [[ "$DRY_RUN" != "on" ]] && cp -al "$backup_dir" "$weekly_dir/$timestamp" || log "[DRY-RUN] would cp -al $backup_dir $weekly_dir/$timestamp"
fi

if [[ $(date +%d) -eq 01 ]]; then
    log "Creating monthly snapshot..."
    [[ "$DRY_RUN" != "on" ]] && cp -al "$backup_dir" "$monthly_dir/$timestamp" || log "[DRY-RUN] would cp -al $backup_dir $monthly_dir/$timestamp"
fi

# ----------------------
# GFS pruning
# ----------------------
log "Pruning old backups..."
if [[ "$DRY_RUN" != "on" ]]; then
    find "$daily_dir"   -maxdepth 1 -type d -name '????-??-??_*' -mtime +${DAILY_COUNT}      -exec rm -rf {} \; 2>/dev/null || true
    find "$weekly_dir"  -maxdepth 1 -type d -mtime +$((7*WEEKLY_COUNT))                     -exec rm -rf {} \; 2>/dev/null || true
    find "$monthly_dir" -maxdepth 1 -type d -mtime +$((30*MONTHLY_COUNT))                   -exec rm -rf {} \; 2>/dev/null || true
else
    log "[DRY-RUN] would prune expired daily/weekly/monthly backups"
fi

# ----------------------
# Send email with only current run logs
# ----------------------
send_email "Backup completed $(date '+%Y-%m-%d %H:%M:%S')" "success"
log "Backup script finished"