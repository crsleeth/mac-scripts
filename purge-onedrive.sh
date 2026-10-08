#!/bin/bash
#
# purge-onedrive.sh — remove the OneDrive sync client from macOS. Run as root.
#
# User APP data under ~/Library is MOVED to ~/.ms-purge-backup/<timestamp>/.
# App bundle and receipts are deleted outright.
#
# IMPORTANT: synced files (~/Library/CloudStorage/OneDrive-* and legacy
# ~/OneDrive*) are left completely untouched. This removes the client, not
# the user's data.

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
log "Quitting OneDrive..."
osascript -e 'quit app "OneDrive"' 2>/dev/null
sleep 2
pkill -f "OneDrive" 2>/dev/null
sleep 1

# ─── 2. app bundle ─────────────────────────────────────────────────────────
log "Removing app bundle..."
rm_path "/Applications/OneDrive.app"

# ─── 3. receipts ───────────────────────────────────────────────────────────
log "Forgetting receipts..."
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  if $DRY_RUN; then log "  [dry-run] forget: $pkg"
  else pkgutil --forget "$pkg" >/dev/null 2>&1 && log "  forgot: $pkg"; fi
done < <(pkgutil --pkgs | grep -Ei 'com\.microsoft\.onedrive')

# ─── 4. per-user APP data (backed up, not deleted) ─────────────────────────
ONEDRIVE_BIDS=( com.microsoft.OneDrive com.microsoft.OneDrive-mac
  com.microsoft.OneDrive.FinderSync com.microsoft.OneDriveUpdater
  com.microsoft.OneDriveStandaloneUpdater )

purge_user(){
  local home="$1" b
  log "  user home: $home"
  for b in "${ONEDRIVE_BIDS[@]}"; do
    backup_item "$home/Library/Containers/$b" "$home"
    backup_item "$home/Library/Caches/$b" "$home"
    backup_item "$home/Library/HTTPStorages/$b" "$home"
    backup_item "$home/Library/Preferences/$b.plist" "$home"
    backup_item "$home/Library/Saved Application State/$b.savedState" "$home"
  done
  backup_item "$home/Library/Group Containers/${MSGRP}.OneDriveStandaloneSuite" "$home"
  backup_item "$home/Library/Group Containers/${MSGRP}.OneDriveSyncClientSuite" "$home"
  backup_item "$home/Library/Application Support/OneDrive" "$home"
  # NOTE: ~/Library/CloudStorage/OneDrive-* and ~/OneDrive* are intentionally left.
}

log "Purging per-user OneDrive client data..."
while IFS= read -r u; do
  home=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [ -d "$home" ] || continue
  purge_user "$home"
  [ -d "$home/$BACKUP_ROOT" ] && ! $DRY_RUN && chown -R "$u" "$home/$BACKUP_ROOT" 2>/dev/null
done < <(dscl . list /Users UniqueID | awk '$2 >= 500 {print $1}')

log "Done. Synced files left intact. Backups (if any) in ~/$BACKUP_ROOT/$TS/"
exit 0
