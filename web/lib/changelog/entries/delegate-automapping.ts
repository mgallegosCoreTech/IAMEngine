import type { ChangelogEntry } from "../format";

export const entry: ChangelogEntry = {
  id: "delegate-automapping",
  date: "2026-09-30",
  time: "12:00",
  title: "An offboarding can delegate the mailbox with or without AutoMapping (runner 1.145.0)",
  items: [
    "FR #0000211. When an offboarding gives someone Full Access to the leaver's mailbox, the mailbox was always added to their Outlook automatically (AutoMapping). You can now grant the access without it",
    "It applies to both delegates: the leaver's manager, when the client grants the manager access, and anyone named on the ticket under \"Enable delegate\"",
    "Each client has a default, set on its Exchange system in Edit systems (\"Delegate AutoMapping\"). It is on unless you change it, so nothing changes for existing clients",
    "An offboarding case with delegates shows them on its page, with a choice of the client default, on or off for this case. It can be changed until the Exchange step starts, and it is kept if the case is re-planned",
    "AutoMapping is set when the access is granted, so someone who already had Full Access keeps whatever they had; the step says so",
    "The Exchange preview and the step's results say whether AutoMapping was on or off",
    "Needs runner 1.145.0. An older runner ignores the setting and keeps AutoMapping on",
  ],
};
