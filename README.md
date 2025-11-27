# Backup Container

This repository provides a lightweight Alpine-based container for efficient, snapshot-style backups using **rsync**, **hard-link deduplication**, **GFS (Grandfather–Father–Son)** rotation, optional **Docker Swarm service scaling**, and email notifications via dynamically generated `msmtp` configuration.

It includes:

- `Dockerfile` – builds the backup container  
- `entrypoint.sh` – prepares SMTP configuration, loads secrets, configures timezone, and launches the backup script  
- `backup.sh` – performs the full backup workflow  

---

## Features

- Incremental backups with `rsync --link-dest`
- Daily / Weekly / Monthly GFS rotation
- Automatic pruning of old backup sets
- Swarm service scaling down/up during backup
- Dynamic SMTP configuration using environment variables **and/or Docker secrets**
- Email notifications on success/failure
- Timezone handling through `TZ`
- DRY-RUN mode for testing backup logic
- Alpine base for minimal footprint

---

# Dockerfile Overview

The Dockerfile:

- Starts from `alpine:latest`
- Installs:
  - `bash`, `rsync`, `docker-cli`, `msmtp`, `tzdata`, `coreutils`, `ca-certificates`
- Copies scripts into `/usr/local/bin`
- Sets both scripts executable
- Defines:
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

---

# Entrypoint Script (`entrypoint.sh`)

The `entrypoint.sh` script is responsible for:

### 1. Loading SMTP-related environment variables

Default values are applied if not set:

| Variable | Default |
|----------|---------|
| `SMTP_SERVER` | `smtp.example.com` |
| `SMTP_PORT` | `25` |
| `SMTP_TLS` | `off` |
| `SMTP_USER` | *(empty)* |
| `SMTP_PASS` | *(empty)* |
| `EMAIL_FROM` | `admin@example.com` |

---

### 2. Loading secrets (optional)

If provided using Docker secrets:

| Secret File | Variable Filled |
|-------------|-----------------|
| `/run/secrets/smtp_user` | `SMTP_USER` |
| `/run/secrets/smtp_pass` | `SMTP_PASS` |

This allows secure credential handling in Swarm or Compose.

---

### 3. Dynamic `msmtp` configuration generation

The script creates `/etc/msmtp/msmtprc` automatically at container start using the environment variables and provided secrets:

- Enables authentication only if `SMTP_USER` is set
- Enables TLS if `SMTP_TLS=on`
- Writes logs to `/var/log/msmtp.log`
- Uses certificate bundle at `/etc/ssl/certs/ca-certificates.crt`
- Uses `passwordeval` when a Docker secret is present

This ensures `backup.sh` can send notifications reliably without pre-baked credentials.

---

### 4. Timezone handling

If the `TZ` environment variable is set:

- Links correct zoneinfo file to `/etc/localtime`
- Writes timezone name to `/etc/timezone`

Example:

TZ=America/Chicago

---

### 5. Executing the backup script

After initializing SMTP and timezone:

exec /usr/local/bin/backup.sh

This replaces the shell with the backup process.

---

# Backup Script (`backup.sh`)

`backup.sh` performs the full backup routine including:

- Pre-run cleanup and aging directory pruning
- Daily backup creation
- Hard-link optimization from previous `latest`
- Optional Swarm service scale-down before rsync
- Running the rsync backup
- Updating `latest` symlink
- Scaling services back up
- GFS­ rotation (daily/weekly/monthly)
- Email notification with run log

---

## Backup Configuration Variables

| Variable | Default | Description |
|---------|---------|-------------|
| `BACKUP_SRC` | `/data` | Source directory |
| `BACKUP_DEST` | `/backup` | Backup destination |
| `SCALE_LABEL` | `com.example.autobackup.enable` | Swarm label to match |
| `SCALE_VALUE` | `true` | Value required for scaling |
| `DAILY_COUNT` | `7` | Daily backups to keep |
| `WEEKLY_COUNT` | `4` | Weekly backups to keep |
| `MONTHLY_COUNT` | `6` | Monthly backups to keep |
| `EMAIL_ON_SUCCESS` | `off` | Email on success |
| `EMAIL_ON_FAILURE` | `on` | Email on failure |
| `SMTP_SERVER` | `smtp.example.com` | SMTP host |
| `SMTP_PORT` | `25` | SMTP port |
| `SMTP_TLS` | `off` | TLS for SMTP |
| `SMTP_USER` | *(env or secret)* | SMTP user |
| `SMTP_PASS` | *(env or secret)* | SMTP password |
| `EMAIL_TO` | `admin@example.com` | Notification destination |
| `EMAIL_FROM` | `backup@example.com` | Sender |
| `DRY_RUN` | `off` | Simulate backups |

---

# Email Notification Behavior

- Emails contain **only the current run log**
- Emails are sent using `msmtp` with the dynamically generated config
- Success emails sent only if:
EMAIL_ON_SUCCESS=on
- Failure emails sent only if:
EMAIL_ON_FAILURE=on

---

# Logging

| Path | Description |
|------|-------------|
| `/var/log/backup.log` | Rolling persistent backup log |
| `/tmp/backup_run_<pid>.log` | Per-run log used for emails |
| `/var/log/msmtp.log` | msmtp email logs |

---

# DRY RUN Mode

DRY_RUN=on

This prevents:
- rsync writing
- directory removal
- Swarm scale-down/up
- symlink updates

Useful for testing.

---

# Example Docker Compose

```yaml
version: "3.9"

services:
  backup:
    image: your-registry/backup-container:latest

    volumes:
      - /data:/data:ro
      - /backup:/backup
      - /var/run/docker.sock:/var/run/docker.sock:ro

    environment:
      # Backup parameters
      BACKUP_SRC: /data
      BACKUP_DEST: /backup

      # Swarm scaling behavior
      SCALE_LABEL: "com.example.autobackup.enable"
      SCALE_VALUE: "true"

      # GFS retention rotation
      DAILY_COUNT: "7"
      WEEKLY_COUNT: "4"
      MONTHLY_COUNT: "6"

      # Email behavior
      EMAIL_ON_SUCCESS: "off"
      EMAIL_ON_FAILURE: "on"

      # SMTP baseline config (secrets override user/pass)
      SMTP_SERVER: "smtp.example.com"
      SMTP_PORT: "587"
      SMTP_TLS: "on"
      EMAIL_FROM: "backup@example.com"

      # Optional: container timezone
      TZ: "America/Chicago"

    secrets:
      - smtp_user
      - smtp_pass

    deploy:
      replicas: 0
      restart_policy:
        condition: none

      # Optional: run backup only on manager nodes
      placement:
        constraints:
          - node.role == manager

secrets:
  smtp_user:
    external: true

  smtp_pass:
    external: true

