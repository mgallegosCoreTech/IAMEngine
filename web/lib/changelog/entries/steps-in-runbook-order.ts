import type { ChangelogEntry } from "../format";

export const entry: ChangelogEntry = {
  id: "steps-in-runbook-order",
  date: "2026-09-28",
  time: "12:00",
  title: "A case's steps follow the client's runbook order",
  items: [
    "FR #0000178. Steps that don't depend on each other now appear, and run, in the order the client's onboarding or offboarding runbook lists them. Before, their order was whatever the database happened to return, and it could change after the client's systems were edited",
    "Dependencies still come first. A step is never placed before one it depends on, and the fixed safety rules still hold: on an AD-synced client, AD comes before directory sync and then the cloud; on an offboard, the mailbox is converted to shared before the licence comes off; and the closing step stays last",
    "Steps the runbook doesn't cover (the automatic AD email write-back and link check, or a system added in the editor) come after the documented ones, unless a documented step depends on them",
    "Runbook sections that aren't automated yet (the manual checklist steps) now appear where the runbook lists them, not all at the end",
    "Existing cases keep their current order until they're re-planned. A re-plan puts them in runbook order, finished steps included. A client with no runbook imported keeps its current order",
    "Web-only — no runner change",
  ],
};
