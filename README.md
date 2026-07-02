# QuickServices

QuickServices is a fast Windows GUI for reviewing and changing service startup settings without fighting through `services.msc` one service at a time.

It shows service names, descriptions, current state, startup mode, search, filters, right-click actions, and a pending-change workflow so you can mark several services for disable/manual/automatic and apply them with one Save.

## Why

Windows' native Services app is reliable, but slow for bulk cleanup. QuickServices is built for quick passes: filter to automatic startup services, hide most Microsoft/Windows services, queue changes, then save once.

## Run

Download this repo, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\QuickServices.ps1
```

For service changes, run as Administrator:

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ".\QuickServices.ps1"'
```

Or double-click:

```text
Run-QuickServices-AsAdmin.cmd
```

## One-Line Remote Run

If you host `QuickServices.ps1` somewhere raw-accessible, users can run it with:

```powershell
irm https://your-server.example/QuickServices.ps1 -OutFile "$env:TEMP\QuickServices.ps1"; Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$env:TEMP\QuickServices.ps1`""
```

Replace the URL with your raw GitHub or server URL.

## Features

- Search by name, display name, description, or path
- Filter by startup mode and running/stopped state
- Optional hide Microsoft/Windows services filter
- Left-side automatic-service toggle for quick disable queueing
- Pending changes with Save/Discard
- Right-click actions: Disable, Stop, Start, Restart
- No dependencies beyond Windows PowerShell and WinForms

## Safety

Disabling services can break Windows features, drivers, or applications. QuickServices queues startup-type changes before applying them, but you should still review pending changes before pressing Save.
