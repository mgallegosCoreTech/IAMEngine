import type { ChangelogEntry } from "../format";

export const entry: ChangelogEntry = {
  id: "sharepoint-grant-dry-run",
  date: "2026-09-28",
  time: "10:00",
  title: "A dry-run offboard previews the OneDrive/SharePoint grant instead of warning (runner 1.144.0)",
  items: [
    "Since runner 1.131.0 the OneDrive/SharePoint full-access grant runs in its own PowerShell process. In a dry run it never got its instructions, so every dry-run offboard that named a delegate showed \"the SharePoint grant helper exited without reporting any grant\"",
    "A dry run now reaches that process and shows what it would do (\"would grant ... site-collection admin ... (WhatIf)\"), and it is told it is a dry run, so it never makes the grant for real",
    "The temporary file holding the certificate is always removed, dry run or not",
  ],
};
