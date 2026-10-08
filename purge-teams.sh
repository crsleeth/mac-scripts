#!/bin/bash
#
# purge-teams.sh — remove Microsoft Teams (new com.microsoft.teams2 and classic
# com.microsoft.teams) from macOS. Run as root (Jamf policy, or `sudo ./...`).
#
# User data under ~/Library is MOVED to ~/.ms-purge-backup/<timestamp>/.
# App bundle, TeamsUpdaterDaemon, audio driver, and receipts are deleted
# outright.
#
# Shared SSO/identity keychain tokens are left in place so other Microsoft
# apps stay signed in (purge-office.sh has a toggle that clears them).
#
# On recent macOS the calling process needs Full Disk Access to modify
# /Applications and ~/Library/Containers (Jamf: PPPC profile; sudo: grant it
# to Terminal). Without it items are reported as WARN and the exit code is 1.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

DRY_RUN=false              # true, or pass --dry-run = log only, change nothing
BACKUP_ROOT=".ms-purge-backup"
MSGRP="UBF8T346G9"
TS="$(date +%Y%m%d-%H%M%S)"
CU=$(stat -f%Su /dev/console 2>/dev/null)   # logged-in user ("root" if none)
FAILS=0
log(){ printf '%s\n' "$*"; }
warn(){ log "  WARN: $*"; FAILS=$((FAILS+1)); }
for arg in "$@"; do [ "$arg" = "--dry-run" ] && DRY_RUN=true; done
[ "$(id -u)" -eq 0 ] || { log "Must run as root."; exit 1; }

rm_path(){
  local p="$1"; { [ -e "$p" ] || [ -L "$p" ]; } || return 0
  if $DRY_RUN; then log "  [dry-run] rm: $p"; return; fi
  rm -rf "$p" 2>/dev/null && log "  removed: $p" || warn "could not remove $p"
}
# unload a system LaunchDaemon, then delete its plist and helper tool
rm_daemon(){
  $DRY_RUN || launchctl bootout "system/$1" 2>/dev/null
  rm_path "/Library/LaunchDaemons/$1.plist"
  rm_path "/Library/PrivilegedHelperTools/$1"
}
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

TEAMS_APPS=( "Microsoft Teams" "Microsoft Teams (work or school)"
             "Microsoft Teams classic" )

# ─── 1. quit processes ─────────────────────────────────────────────────────
# Matched by bundle path, so helpers inside each app go too.
log "Quitting Teams..."
quit_apps '/Applications/Microsoft Teams( \(work or school\)| classic)?\.app/' \
  "${TEAMS_APPS[@]}"

# ─── 2. app bundles ────────────────────────────────────────────────────────
log "Removing app bundles..."
for t in "${TEAMS_APPS[@]}"; do
  rm_path "/Applications/${t}.app"
done

# ─── 3. receipts ───────────────────────────────────────────────────────────
log "Forgetting receipts..."
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  if $DRY_RUN; then log "  [dry-run] forget: $pkg"
  else pkgutil --forget "$pkg" >/dev/null 2>&1 && log "  forgot: $pkg"; fi
done < <(pkgutil --pkgs | grep -Ei 'com\.microsoft\.(teams|MSTeamsAudioDevice)')

# ─── 4. updater daemon + audio driver ──────────────────────────────────────
log "Removing Teams system components..."
rm_daemon com.microsoft.teams.TeamsUpdaterDaemon
# "Microsoft Teams Audio" device; drops out of the sound list after a restart
rm_path "/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver"

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
  home=$(dscacheutil -q user -a name "$u" 2>/dev/null | sed -n 's/^dir: //p')
  { [ -n "$home" ] && [ "$home" != "/" ] && [ -d "$home/Library" ]; } || continue
  purge_user "$home"
  [ -d "$home/$BACKUP_ROOT" ] && ! $DRY_RUN && chown -R "$u" "$home/$BACKUP_ROOT" 2>/dev/null
done < <(dscl . list /Users UniqueID | awk '$2 >= 500 {print $1}')

log "Done. Backups (if any) in each user's ~/$BACKUP_ROOT/$TS/"
[ "$FAILS" -eq 0 ] || { log "$FAILS item(s) failed — see WARN lines above."; exit 1; }
exit 0
