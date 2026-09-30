import type { ChangelogEntry } from "../format";

export const entry: ChangelogEntry = {
  id: "teams-phone",
  date: "2026-09-30",
  time: "15:00",
  title: "Teams Phone: new hires get a phone number, and leavers' numbers are released (runner 1.146.0)",
  items: [
    "The Teams Phone step is now automated. On an onboarding it gives the new hire a Teams phone number once their licence includes Teams Phone and a Calling Plan; on an offboarding it releases the number back to the tenant's pool and records which number it was",
    "The number is the next free Calling Plan number for the hire's office area code (the client's phoneByAreaCode, e.g. Stamford 203). To use a specific number, enter it as \"Teams phone number\" in the onboarding review",
    "Right after onboarding, Teams usually hasn't picked up the licence yet. The step waits and checks again every 15 minutes, and if no number is free for the area code it says so and checks every hour",
    "It never replaces a number someone already has, and a dry run only shows what it would do",
    "On AD-synced clients a new step writes the number into AD telephoneNumber; the number is also in the step's results and case notes. Writing it back to the ServiceNow contact is a follow-up",
    "On an offboarding the number is released before the licence comes off",
    "It signs in with the client's m365-admin app, which needs the Teams Administrator role, and it runs in its own PowerShell process so it can't interfere with the M365 steps. Setup is at /help/teams",
    "Only Calling Plan numbers for now. Needs runner 1.146.0",
  ],
};
