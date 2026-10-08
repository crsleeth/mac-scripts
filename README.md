# Mac scripts

Status: purge-outlook.sh added, tested only against a simulated home folder | Next: run it on a Mac that has Outlook, then apply the review fixes to the other three scripts

Removal scripts for Microsoft apps on macOS. Run as root (Jamf policy, or `sudo`).

| Script | Removes |
|---|---|
| `purge-office.sh` | Word, Excel, PowerPoint, Outlook, OneNote (optionally AutoUpdate, licensing, keychain sign-in) |
| `purge-outlook.sh` | Outlook only — the rest of Office keeps working |
| `purge-teams.sh` | Teams (new and classic) |
| `purge-onedrive.sh` | The OneDrive sync client — synced files are left in place |

User data under `~/Library` is moved to `~/.ms-purge-backup/<timestamp>/`, not deleted.
`purge-outlook.sh` accepts `--dry-run` to preview; the others have a `DRY_RUN` toggle at the top of the file.
