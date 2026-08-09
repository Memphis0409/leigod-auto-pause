---
name: leigod-auto-pause
description: Install, check, repair, or uninstall automatic time pausing for the Windows Leigod accelerator when the app exits or Windows shuts down. Use when the user asks about 雷神自动暂停, 雷神退出自动暂停, 雷神关机暂停, or this plugin's status.
---

# 雷神自动暂停

This skill manages the bundled PowerShell patcher. It modifies only Leigod's `resources/app.asar`, keeps a SHA-256-addressed backup under `%LOCALAPPDATA%\LeigodAutoPause\backups`, and calls Leigod's own renderer-side `toggleTimeStatus("pause")`. It never reads or stores credentials.

## Workflow

1. Run `scripts/leigod-auto-pause.ps1 -Action Status` first.
2. For install or repair, explain that Leigod must be restarted after the patch. Then run with `-Action Install` or `-Action Repair`.
3. Run `-Action Status` again and report the detected Leigod version, patch state, and whether restart is required.
4. For uninstall, run `-Action Uninstall`. This restores the most recent matching original backup. If no safe matching backup exists, stop and report the exact reason; never invent or download an app archive.

## Safety

- Never terminate Leigod or restart Windows without explicit user confirmation.
- Never overwrite an unknown existing backup.
- If Leigod is running during installation, patch on disk and report that restart is required.
- If the patcher reports an unsupported layout, do not perform a broad text replacement. Report that the installed Leigod version needs a patcher update.
- The automatic pause is best-effort when the account is logged out, the network is unavailable, or the remaining time is marked non-pausable by Leigod.

## Commands

Run from the plugin root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\leigod-auto-pause.ps1 -Action Status
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\leigod-auto-pause.ps1 -Action Install
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\leigod-auto-pause.ps1 -Action Repair
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\leigod-auto-pause.ps1 -Action Uninstall
```
