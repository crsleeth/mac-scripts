#!/bin/bash
#
# purge-teams.sh — remove Microsoft Teams (new com.microsoft.teams2 and classic
# com.microsoft.teams) from macOS. Run as root.
#
# User data under ~/Library is MOVED to ~/.ms-purge-backup/<timestamp>/.
# App bundle, TeamsUpdaterDaemon, and receipts are deleted outright.
#
# Shared SSO/identity keychain tokens are left in place (handled by
# purge-office.sh) so other Microsoft apps keep working.

set -u

DRY_RUN=false
BACKUP_ROOT=".ms-purge-backup"
MSGRP="UBF8T346G9"
TS="$(date +%Y%m%d-%H%M%S)"
log(){ printf '%s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { log "Must run as root."; exit 1; }

rm_path(){
  local p="$1"; { [ -e "$p" ] || [ -L "$p" ]; } || return 0
  if $DRY_RUN; then log "  [dry-run] rm: $p"; else rm -rf "$p" && log "  removed: $p"; fi
}
backup_item(){
  local src="$1" home="$2"
  { [ -e "$src" ] || [ -L "$src" ]; } || return 0
  local dest="$home/$BACKUP_ROOT/$TS/${src#"$home"/}"
  if $DRY_RUN; then log "  [dry-run] backup: $src -> $dest"; return; fi
  mkdir -p "$(dirname "$dest")"
  mv "$src" "$dest" && log "  backed up: $src" || log "  WARN: could not move $src"
}

# ─── 1. quit processes ─────────────────────────────────────────────────────
log "Quitting Teams..."
for app in "Microsoft Teams" "Microsoft Teams (work or school)" "Microsoft Teams classic"; do
  osascript -e "quit app \"$app\"" 2>/dev/null
done
sleep 2
pkill -f "Microsoft Teams" 2>/dev/null
pkill -f "com.microsoft.teams" 2>/dev/null
sleep 1

# ─── 2. app bundles ────────────────────────────────────────────────────────
log "Removing app bundles..."
for t in "Microsoft Teams" "Microsoft Teams (work or school)" "Microsoft Teams classic"; do
  rm_path "/Applications/${t}.app"
done

# ─── 3. receipts ───────────────────────────────────────────────────────────
log "Forgetting receipts..."
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  if $DRY_RUN; then log "  [dry-run] forget: $pkg"
  else pkgutil --forget "$pkg" >/dev/null 2>&1 && log "  forgot: $pkg"; fi
done < <(pkgutil --pkgs | grep -Ei 'com\.microsoft\.teams')

# ─── 4. updater daemon + helper ────────────────────────────────────────────
log "Removing Teams updater daemon..."
launchctl bootout system/com.microsoft.teams.TeamsUpdaterDaemon 2>/dev/null
rm_path "/Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist"
rm_path "/Library/PrivilegedHelperTools/com.microsoft.teams.TeamsUpdaterDaemon"

# ─── 5. per-user data (backed up, not deleted) ─────────────────────────────
TEAMS_BIDS=( com.microsoft.teams com.microsoft.teams2 com.microsoft.teams2.launcher )

purge_user(){
  local home="$1" b
  log "  user home: $home"
  for b in "${TEAMS_BIDS[@]}"; do
    backup_item "$home/Library/Containers/$b" "$home"
    backup_item "$home/Library/Caches/$b" "$home"
    backup_item "$home/Library/HTTPStorages/$b" "$home"
    backup_item "$home/Library/Preferences/$b.plist" "$home"
    backup_item "$home/Library/Saved Application State/$b.savedState" "$home"
  done
  backup_item "$home/Library/Group Containers/${MSGRP}.com.microsoft.teams" "$home"
  backup_item "$home/Library/Application Support/Microsoft/Teams" "$home"   # classic
}

log "Purging per-user Teams data..."
while IFS= read -r u; do
  home=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [ -d "$home" ] || continue
  purge_user "$home"
  [ -d "$home/$BACKUP_ROOT" ] && ! $DRY_RUN && chown -R "$u" "$home/$BACKUP_ROOT" 2>/dev/null
done < <(dscl . list /Users UniqueID | awk '$2 >= 500 {print $1}')

log "Done. Backups (if any) in each user's ~/$BACKUP_ROOT/$TS/"
exit 0
