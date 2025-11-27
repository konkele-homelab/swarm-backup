#!/usr/bin/env bash
set -euo pipefail

# ----------------------
# Load environment variables
# ----------------------
: "${SMTP_SERVER:=smtp.example.com}"
: "${SMTP_PORT:=25}"
: "${SMTP_TLS:=off}"
: "${SMTP_USER:=}"
: "${SMTP_PASS:=}"
: "${EMAIL_FROM:=admin@example.com}"

# ----------------------
# Load SMTP secrets if they exist
# ----------------------
SMTP_PASS_FILE="/run/secrets/smtp_pass"
SMTP_USER_FILE="/run/secrets/smtp_user"

[[ -f "$SMTP_USER_FILE" ]] && export SMTP_USER=$(cat "$SMTP_USER_FILE")

[[ -f "$SMTP_PASS_FILE" ]] && export SMTP_PASS=$(cat "$SMTP_PASS_FILE")

# ----------------------
# Generate msmtp config dynamically
# ----------------------
MSMTP_CONF="/etc/msmtp/msmtprc"
mkdir -p "$(dirname "$MSMTP_CONF")"
chmod 600 "$(dirname "$MSMTP_CONF")"

cat > "$MSMTP_CONF" <<EOF
defaults
auth $( [[ -n "$SMTP_USER" ]] && echo "on" || echo "off" )
tls $( [[ "$SMTP_TLS" == "on" ]] && echo "on" || echo "off" )
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log

account default
host $SMTP_SERVER
port $SMTP_PORT
from $EMAIL_FROM
user $SMTP_USER
passwordeval $( [[ -f "$SMTP_PASS_FILE" ]] && echo "cat $SMTP_PASS_FILE" || echo "")
EOF

chmod 600 "$MSMTP_CONF"
export MSMTP_CONFIG="$MSMTP_CONF"

# ----------------------
# Set timezone
# ----------------------
if [[ -n "${TZ:-}" ]]; then
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime
    echo "$TZ" > /etc/timezone
fi

# ----------------------
# Execute backup
# ----------------------
exec /usr/local/bin/backup.sh