#!/usr/bin/env bash
# Backup-Skript für Paperless PostgreSQL in Docker
# - erstellt tägliches gzip-Backup
# - rotiert/entfernt Backups älter als 30 Tage

set -euo pipefail

# === Konfiguration ===
CONTAINER="paperless-db-1"         # Name des Postgres-Containers
DBUSER="paperless"                 # DB-User
DBNAME="paperless"                 # Zu sichernde DB
BACKUP_DIR="/volume1/NetBackup/paperless"
DATE="$(date +%Y%m%d)"
FILENAME="${DATE}.sql.gz"
TMPFILE="${BACKUP_DIR}/.${FILENAME}.part"

# === Vorbereitung ===
mkdir -p "$BACKUP_DIR"

# === Backup erstellen ===
# Hinweis: Kein -it verwenden, damit Cron & gzip zuverlässig arbeiten.
# pg_dump ist korrekt für einzelne Datenbanken. Für alle DBs siehe Alternativen unten.
echo "[INFO] Erstelle Backup: ${BACKUP_DIR}/${FILENAME}"
if docker exec "$CONTAINER" pg_dump -U "$DBUSER" -d "$DBNAME" \
  | gzip -c > "$TMPFILE"; then
  mv "$TMPFILE" "${BACKUP_DIR}/${FILENAME}"
  echo "[OK] Backup gespeichert: ${BACKUP_DIR}/${FILENAME}"
else
  echo "[ERROR] Backup fehlgeschlagen." >&2
  rm -f "$TMPFILE" || true
  exit 1
fi

# === Aufräumen: Backups älter als 30 Tage löschen ===
echo "[INFO] Entferne Backups älter als 30 Tage…"
find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +30 -print -delete

echo "[DONE] Backup & Rotation abgeschlossen."
