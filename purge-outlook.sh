#!/bin/bash
#
# purge-outlook.sh — remove Microsoft Outlook ONLY from macOS, leaving Word,
# Excel, PowerPoint and OneNote installed, licensed and signed in. Run as root
# (Jamf policy, or `sudo ./...`). For the whole suite use purge-office.sh.
#
# User data under ~/Library is MOVED to ~/.ms-purge-backup/<timestamp>/ (not
# deleted). That includes the mail profiles: accounts, "On My Computer" mail,
# signatures, rules. The app bundle and its receipt are deleted outright.
#
# Left alone because the other Office apps share them: the rest of the
# UBF8T346G9.Office group container, licensing, Microsoft AutoUpdate, and the
# sign-in keychain items.
#
# On recent macOS the calling process needs Full Disk Access to modify
# /Applications and ~/Library/Containers (Jamf: PPPC profile; sudo: grant it
# to Terminal). Without it items are reported as WARN and the exit code is 1.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

### ─── toggles ────────────────────────────────────────────────────────────
DRY_RUN=false              # true, or pass --dry-run = log only, change nothing
BACKUP_ROOT=".ms-purge-backup"   # created inside each user's home
### ────────────────────────────────────────────────────────────────────────

MSGRP="UBF8T346G9"
TS="$(date +%Y%m%d-%H%M%S)"
CU=$(stat -f%Su /dev/console 2>/dev/null)   # logged-in user ("root" if none)
FAILS=0
log(){ printf '%s\n' "$*"; }
warn(){ log "  WARN: $*"; FAILS=$((FAILS+1)); }
for arg in "$@"; do [ "$arg" = "--dry-run" ] && DRY_RUN=true; done
[ "$(id -u)" -eq 0 ] || { log "Must run as root."; exit 1; }

# delete a system/app path (not user data)
rm_path(){
  local p="$1"; { [ -e "$p" ] || [ -L "$p" ]; } || return 0
  if $DRY_RUN; then log "  [dry-run] rm: $p"; return; fi
  rm -rf "$p" 2>/dev/null && log "  removed: $p" || warn "could not remove $p"
}
# move a user file into that user's timestamped backup dir, preserving rel path
backup_item(){
  local src="$1" home="$2"
  { [ -e "$src" ] || [ -L "$src" ]; } || return 0
  local dest="$home/$BACKUP_ROOT/$TS/${src#"$home"/}"
  if $DRY_RUN; then log "  [dry-run] backup: $src -> $dest"; return; fi
  mkdir -p "$(dirname "$dest")"
  mv "$src" "$dest" && log "  backed up: $src" || warn "could not move $src"
}

# quit_apps <path regex> <app name>... — ask each app to quit in the logged-in
# user's session (root can't reach it otherwise), wait up to 10s, then kill
# whatever is still running from a path matching the regex.
quit_apps(){
  local re="$1" app; shift
  pgrep -f "$re" >/dev/null || { log "  not running"; return 0; }
  if $DRY_RUN; then log "  [dry-run] quit: $*"; return 0; fi
  for app in "$@"; do
    { [ -d "/Applications/$app.app" ] && [ -n "$CU" ] && [ "$CU" != "root" ]; } || continue
    launchctl asuser "$(id -u "$CU")" sudo -u "$CU" osascript -e \
      "if application \"$app\" is running then tell application \"$app\" to quit" \
      >/dev/null 2>&1 &
  done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$re" >/dev/null || return 0; sleep 1
  done
  pkill -f "$re" 2>/dev/null && sleep 1
  pkill -9 -f "$re" 2>/dev/null
  return 0
}

# ─── 1. quit processes ─────────────────────────────────────────────────────
# Matched by bundle path, so helpers and extensions are included and nothing
# outside the Outlook bundle is.
log "Quitting Outlook..."
quit_apps '/Applications/Microsoft Outlook\.app/' "Microsoft Outlook"

# ─── 2. app bundle ─────────────────────────────────────────────────────────
log "Removing app bundle..."
rm_path "/Applications/Microsoft Outlook.app"

# ─── 3. receipts (outlook only; shared office packages stay) ───────────────
log "Forgetting receipts..."
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  if $DRY_RUN; then log "  [dry-run] forget: $pkg"
  else pkgutil --forget "$pkg" >/dev/null 2>&1 && log "  forgot: $pkg"; fi
done < <(pkgutil --pkgs | grep -Ei '^com\.microsoft\..*outlook')

# ─── 4. per-user data (backed up, not deleted) ─────────────────────────────
# Globs rather than a bundle-ID list, so Outlook's extensions and helpers
# (com.microsoft.Outlook.*, com.microsoft.outlook.*) are caught as well.
purge_user(){
  local home="$1" d p
  log "  user home: $home"
  for d in Containers "Application Scripts" Caches HTTPStorages Preferences \
           "Saved Application State" Cookies; do
    for p in "$home/Library/$d"/com.microsoft.[Oo]utlook*; do
      backup_item "$p" "$home"
    done
  done
  # Mail profiles and the default-profile setting. Only the Outlook entries:
  # the rest of this group container belongs to Word/Excel/PowerPoint too.
  for p in "$home/Library/Group Containers/${MSGRP}.Office"/[Oo]utlook*; do
    backup_item "$p" "$home"
  done
}

log "Purging per-user Outlook data..."
while IFS= read -r u; do
  home=$(dscacheutil -q user -a name "$u" 2>/dev/null | sed -n 's/^dir: //p')
  { [ -n "$home" ] && [ "$home" != "/" ] && [ -d "$home/Library" ]; } || continue
  purge_user "$home"
  [ -d "$home/$BACKUP_ROOT" ] && ! $DRY_RUN && chown -R "$u" "$home/$BACKUP_ROOT" 2>/dev/null
done < <(dscl . list /Users UniqueID | awk '$2 >= 500 {print $1}')

log "Done. Backups (if any) in each user's ~/$BACKUP_ROOT/$TS/"
[ "$FAILS" -eq 0 ] || { log "$FAILS item(s) failed — see WARN lines above."; exit 1; }
exit 0
