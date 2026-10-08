# Mac scripts

Status: review fixes applied to all four scripts, tested only against a simulated system | Next: dry-run, then real run, on a Mac that has the Microsoft apps installed

Removal scripts for Microsoft apps on macOS. Run as root (Jamf policy, or `sudo`).

| Script | Removes |
|---|---|
| `purge-office.sh` | Word, Excel, PowerPoint, Outlook, OneNote (optionally AutoUpdate, licensing, keychain sign-in) |
| `purge-outlook.sh` | Outlook only — the rest of Office keeps working |
| `purge-teams.sh` | Teams (new and classic) |
| `purge-onedrive.sh` | The OneDrive sync client — synced files are not touched |

User data under `~/Library` is moved to `~/.ms-purge-backup/<timestamp>/`, not deleted.

Every script accepts `--dry-run` to preview without changing anything, and exits 1 if anything could not be removed or moved (look for `WARN` lines).
On recent macOS the calling process needs Full Disk Access.
