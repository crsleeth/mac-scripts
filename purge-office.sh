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

set -u

### ─── toggles ────────────────────────────────────────────────────────────
REMOVE_MAU=true            # Microsoft AutoUpdate. Set false if keeping Teams/
                           # OneDrive on this Mac (they rely on their own
                           # updaters, but MAU is the shared Office updater).
DEACTIVATE_LICENSE=true    # remove licensing helper -> re-activation next launch
CLEAN_KEYCHAIN=true        # console user's Office identity/ADAL entries
DRY_RUN=false              # true = log only, move/delete nothing
BACKUP_ROOT=".ms-purge-backup"   # created inside each user's home
### ────────────────────────────────────────────────────────────────────────

MSGRP="UBF8T346G9"
TS="$(date +%Y%m%d-%H%M%S)"
log(){ printf '%s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { log "Must run as root."; exit 1; }

# delete a system/app path (not user data)
rm_path(){
  local p="$1"; { [ -e "$p" ] || [ -L "$p" ]; } || return 0
  if $DRY_RUN; then log "  [dry-run] rm: $p"; else rm -rf "$p" && log "  removed: $p"; fi
}
# move a user file into that user's timestamped backup dir, preserving rel path
backup_item(){
  local src="$1" home="$2"
  { [ -e "$src" ] || [ -L "$src" ]; } || return 0
  local dest="$home/$BACKUP_ROOT/$TS/${src#"$home"/}"
  if $DRY_RUN; then log "  [dry-run] backup: $src -> $dest"; return; fi
  mkdir -p "$(dirname "$dest")"
  mv "$src" "$dest" && log "  backed up: $src" || log "  WARN: could not move $src"
}

# ─── 1. quit processes ─────────────────────────────────────────────────────
log "Quitting Office processes..."
for app in "Microsoft Word" "Microsoft Excel" "Microsoft PowerPoint" \
           "Microsoft Outlook" "Microsoft OneNote" "Microsoft Error Reporting" \
           "Microsoft Database Daemon"; do
  osascript -e "quit app \"$app\"" 2>/dev/null
done
$REMOVE_MAU && osascript -e 'quit app "Microsoft AutoUpdate"' 2>/dev/null
sleep 2
pkill -f "Microsoft Word\|Microsoft Excel\|Microsoft PowerPoint\|Microsoft Outlook\|Microsoft OneNote" 2>/dev/null
$REMOVE_MAU && pkill -f "Microsoft AU Daemon" 2>/dev/null
sleep 1

# ─── 2. app bundles ────────────────────────────────────────────────────────
log "Removing app bundles..."
for app in "Microsoft Word" "Microsoft Excel" "Microsoft PowerPoint" \
           "Microsoft Outlook" "Microsoft OneNote"; do
  rm_path "/Applications/${app}.app"
done
$REMOVE_MAU && rm_path "/Applications/Microsoft AutoUpdate.app"

# ─── 3. receipts (office only; exclude teams/onedrive/edge) ─────────────────
log "Forgetting receipts..."
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  if $DRY_RUN; then log "  [dry-run] forget: $pkg"
  else pkgutil --forget "$pkg" >/dev/null 2>&1 && log "  forgot: $pkg"; fi
done < <(pkgutil --pkgs | grep -Ei 'com\.microsoft' | grep -Eiv 'teams|onedrive|edge')

# ─── 4. system-level helpers/daemons ───────────────────────────────────────
log "Removing system components..."
SYS=()
$DEACTIVATE_LICENSE && {
  launchctl bootout system/com.microsoft.office.licensingV2.helper 2>/dev/null
  SYS+=( "/Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist"
         "/Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper"
         "/Library/Preferences/com.microsoft.office.licensingV2.plist" )
}
$REMOVE_MAU && {
  launchctl bootout system/com.microsoft.autoupdate.helper 2>/dev/null
  SYS+=( "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist"
         "/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper"
         "/Library/Application Support/Microsoft/MAU2.0" )
}
SYS+=( "/Library/Logs/Microsoft" "/Library/Fonts/Microsoft" )
for p in "${SYS[@]}"; do rm_path "$p"; done

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
  home=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [ -d "$home" ] || continue
  purge_user "$home"
  [ -d "$home/$BACKUP_ROOT" ] && ! $DRY_RUN && chown -R "$u" "$home/$BACKUP_ROOT" 2>/dev/null
done < <(dscl . list /Users UniqueID | awk '$2 >= 500 {print $1}')

# ─── 6. keychain (console user only; not backed up) ────────────────────────
if $CLEAN_KEYCHAIN; then
  cu=$(stat -f%Su /dev/console 2>/dev/null)
  if [ -n "$cu" ] && [ "$cu" != "root" ]; then
    log "Cleaning keychain for console user: $cu"
    uid=$(id -u "$cu")
    for lbl in "Microsoft Office Identities Cache 3" \
               "Microsoft Office Identities Settings 3" \
               "MicrosoftOfficeRMSCredential" "MSOpenTech.ADAL.1" \
               "Microsoft Office Ticket Cache"; do
      for _ in 1 2 3; do
        $DRY_RUN && { log "  [dry-run] kc del: $lbl"; break; }
        launchctl asuser "$uid" sudo -u "$cu" \
          security delete-generic-password -l "$lbl" >/dev/null 2>&1 || break
        log "  deleted keychain: $lbl"
      done
    done
  fi
fi

log "Done. Backups (if any) in each user's ~/$BACKUP_ROOT/$TS/"
exit 0
