#!/bin/bash
#
# purge-office.sh — remove core Microsoft Office apps (Word, Excel, PowerPoint,
# Outlook, OneNote) from macOS. Run as root (Jamf policy, or `sudo ./...`).
#
# User data under ~/Library is MOVED to ~/.ms-purge-backup/<timestamp>/ (not
# deleted). App bundles, /Library daemons, receipts, and keychain items are
# deleted outright — those are recreated on reinstall.
#
# Does NOT remove Teams or OneDrive — see purge-teams.sh / purge-onedrive.sh.
# To remove Outlook on its own, see purge-outlook.sh.
#
# On recent macOS the calling process needs Full Disk Access to modify
# /Applications and ~/Library/Containers (Jamf: PPPC profile; sudo: grant it
# to Terminal). Without it items are reported as WARN and the exit code is 1.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

### ─── toggles ────────────────────────────────────────────────────────────
REMOVE_MAU=false           # Microsoft AutoUpdate. New Teams, Defender and
                           # Company Portal update through it too, so only
                           # set true when no Microsoft apps are staying.
DEACTIVATE_LICENSE=true    # remove licensing helper -> re-activation next launch
CLEAN_KEYCHAIN=true        # console user's Office sign-in entries. These are
                           # shared: Teams/OneDrive will ask that user to sign
                           # in again. Set false to leave them signed in.
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
# unload a system LaunchDaemon, then delete its plist and helper tool
rm_daemon(){
  $DRY_RUN || launchctl bootout "system/$1" 2>/dev/null
  rm_path "/Library/LaunchDaemons/$1.plist"
  rm_path "/Library/PrivilegedHelperTools/$1"
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

OFFICE_APPS=( "Microsoft Word" "Microsoft Excel" "Microsoft PowerPoint"
              "Microsoft Outlook" "Microsoft OneNote" )

# ─── 1. quit processes ─────────────────────────────────────────────────────
# Matched by bundle path, so helpers and extensions inside each app go too.
log "Quitting Office processes..."
PROC='/Applications/Microsoft (Word|Excel|PowerPoint|Outlook|OneNote)\.app/'
$REMOVE_MAU && PROC="$PROC|/Library/Application Support/Microsoft/MAU2\.0/"
quit_apps "$PROC" "${OFFICE_APPS[@]}"

# ─── 2. app bundles ────────────────────────────────────────────────────────
log "Removing app bundles..."
for app in "${OFFICE_APPS[@]}"; do
  rm_path "/Applications/${app}.app"
done
$REMOVE_MAU && rm_path "/Applications/Microsoft AutoUpdate.app"

# ─── 3. receipts (office packages only; follows the toggles above) ─────────
log "Forgetting receipts..."
RCPT='package\.(Microsoft_(Word|Excel|PowerPoint|Outlook|OneNote)\.app|Frameworks|Proofing_Tools|Fonts|DFonts)|office\..*'
$DEACTIVATE_LICENSE && RCPT="$RCPT|pkg\.licensing(\.volume)?"
$REMOVE_MAU && RCPT="$RCPT|package\.Microsoft_(AutoUpdate|AU_Bootstrapper)\.app|mau\..*"
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  if $DRY_RUN; then log "  [dry-run] forget: $pkg"
  else pkgutil --forget "$pkg" >/dev/null 2>&1 && log "  forgot: $pkg"; fi
done < <(pkgutil --pkgs | grep -Ei "^com\.microsoft\.($RCPT)\$")

# ─── 4. system-level helpers/daemons ───────────────────────────────────────
log "Removing system components..."
SYS=( "/Library/Fonts/Microsoft" )
$DEACTIVATE_LICENSE && {
  rm_daemon com.microsoft.office.licensingV2.helper
  SYS+=( "/Library/Preferences/com.microsoft.office.licensingV2.plist" )
}
$REMOVE_MAU && {
  rm_daemon com.microsoft.autoupdate.helper
  # per-user agent: unloaded for the logged-in user, plist removed for everyone
  { ! $DRY_RUN && [ -n "$CU" ] && [ "$CU" != "root" ]; } && \
    launchctl bootout "gui/$(id -u "$CU")/com.microsoft.update.agent" 2>/dev/null
  SYS+=( "/Library/LaunchAgents/com.microsoft.update.agent.plist"
         "/Library/Application Support/Microsoft/MAU2.0"
         "/Library/Logs/Microsoft/autoupdate.log" )
}
for p in "${SYS[@]}"; do rm_path "$p"; done
# /Library/Logs/Microsoft also holds Defender/Teams/OneDrive logs, so it is
# only removed once nothing is left in it.
$DRY_RUN || rmdir "/Library/Logs/Microsoft" 2>/dev/null

# ─── 5. per-user data (backed up, not deleted) ─────────────────────────────
OFFICE_BIDS=( com.microsoft.Word com.microsoft.Excel com.microsoft.Powerpoint
  com.microsoft.Outlook com.microsoft.onenote.mac com.microsoft.errorreporting
  com.microsoft.autoupdate.fba com.microsoft.RMS-XPCService
  com.microsoft.rms-sharing-mac )

purge_user(){
  local home="$1" b
  log "  user home: $home"
  for b in "${OFFICE_BIDS[@]}"; do
    backup_item "$home/Library/Containers/$b" "$home"
    backup_item "$home/Library/Caches/$b" "$home"
    backup_item "$home/Library/HTTPStorages/$b" "$home"
    backup_item "$home/Library/Preferences/$b.plist" "$home"
    backup_item "$home/Library/Application Scripts/$b" "$home"
    backup_item "$home/Library/Saved Application State/$b.savedState" "$home"
  done
  backup_item "$home/Library/Group Containers/${MSGRP}.ms" "$home"
  backup_item "$home/Library/Group Containers/${MSGRP}.Office" "$home"
  backup_item "$home/Library/Group Containers/${MSGRP}.OfficeOsfWebHost" "$home"
  backup_item "$home/Library/Preferences/com.microsoft.office.plist" "$home"
  $REMOVE_MAU && backup_item "$home/Library/Preferences/com.microsoft.autoupdate2.plist" "$home"
  $REMOVE_MAU && backup_item "$home/Library/Cookies/com.microsoft.autoupdate.fba.binarycookies" "$home"
}

log "Purging per-user Office data..."
while IFS= read -r u; do
  home=$(dscacheutil -q user -a name "$u" 2>/dev/null | sed -n 's/^dir: //p')
  { [ -n "$home" ] && [ "$home" != "/" ] && [ -d "$home/Library" ]; } || continue
  purge_user "$home"
  [ -d "$home/$BACKUP_ROOT" ] && ! $DRY_RUN && chown -R "$u" "$home/$BACKUP_ROOT" 2>/dev/null
done < <(dscl . list /Users UniqueID | awk '$2 >= 500 {print $1}')

# ─── 6. keychain (console user only; not backed up) ────────────────────────
if $CLEAN_KEYCHAIN; then
  if [ -n "$CU" ] && [ "$CU" != "root" ]; then
    log "Cleaning keychain for console user: $CU"
    uid=$(id -u "$CU")
    for lbl in "Microsoft Office Identities Cache 3" \
               "Microsoft Office Identities Settings 3" \
               "MicrosoftOfficeRMSCredential" "MSOpenTech.ADAL.1" \
               "Microsoft Office Ticket Cache"; do
      for _ in 1 2 3; do
        $DRY_RUN && { log "  [dry-run] kc del: $lbl"; break; }
        launchctl asuser "$uid" sudo -u "$CU" \
          security delete-generic-password -l "$lbl" >/dev/null 2>&1 || break
        log "  deleted keychain: $lbl"
      done
    done
  fi
fi

log "Done. Backups (if any) in each user's ~/$BACKUP_ROOT/$TS/"
[ "$FAILS" -eq 0 ] || { log "$FAILS item(s) failed — see WARN lines above."; exit 1; }
exit 0
