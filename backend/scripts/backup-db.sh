#!/usr/bin/env bash
#
# Take a dump of the production database and keep it somewhere Railway does not
# control.
#
# Railway's own point-in-time recovery protects the data against mistakes —
# a bad migration, rows deleted by accident. It does not protect against losing
# the project or the account, because the backups live inside the thing that
# would be lost. This does.
#
#   ./backup-db.sh                      # dump to ~/HearfulBackups
#   HEARFUL_BACKUP_DIR=/vol ./backup-db.sh
#
# The DATABASE_URL must be Railway's *public* connection string. The one in the
# service variables uses postgres.railway.internal, which only resolves inside
# Railway's network; the public one is under the Postgres service's Connect tab.
#
# What comes out is personal data — every user's email address, what they have
# listened to, and their encrypted Apple tokens. Treat the output the way you
# would treat the database itself.

set -euo pipefail

BACKUP_DIR="${HEARFUL_BACKUP_DIR:-$HOME/HearfulBackups}"
# Old dumps are deleted, not kept forever. The privacy policy promises that
# deleting an account erases it; a backup from a year ago quietly breaks that
# promise. A month is long enough to notice a disaster and short enough that
# a deleted account really does go away.
RETENTION_DAYS="${HEARFUL_BACKUP_RETENTION_DAYS:-30}"

die() { echo "error: $*" >&2; exit 1; }

command -v pg_dump >/dev/null || die "pg_dump not found (brew install libpq)"
[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is not set — use Railway's public connection string"

# Refuse to write inside the repository. A dump full of users' email addresses
# committed to a public repo is not a mistake anyone gets to make twice.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$(cd "$(dirname "$BACKUP_DIR")" 2>/dev/null && pwd || echo /nonexistent)/" in
  "$repo_root"/*) die "refusing to write backups inside the repository: $BACKUP_DIR" ;;
esac

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$BACKUP_DIR/hearful-$stamp.dump"

echo "dumping to $out"
# Custom format: compressed, and restorable selectively with pg_restore.
# --no-owner/--no-privileges so it restores cleanly into a fresh database that
# does not have Railway's roles.
pg_dump --format=custom --no-owner --no-privileges --file="$out" "$DATABASE_URL"
chmod 600 "$out"

# A dump that is technically valid but empty is worse than none, because it
# looks like protection. Check the tables that matter are actually in there.
tables="$(pg_restore --list "$out" | grep -c 'TABLE DATA' || true)"
[ "$tables" -ge 5 ] || die "dump contains only $tables tables — refusing to treat this as a backup"

size="$(du -h "$out" | cut -f1)"
echo "ok: $size, $tables tables with data"

deleted="$(find "$BACKUP_DIR" -name 'hearful-*.dump' -type f -mtime "+$RETENTION_DAYS" -print -delete | wc -l | tr -d ' ')"
[ "$deleted" -eq 0 ] || echo "pruned $deleted dump(s) older than $RETENTION_DAYS days"

echo "kept: $(find "$BACKUP_DIR" -name 'hearful-*.dump' -type f | wc -l | tr -d ' ') dump(s) in $BACKUP_DIR"
