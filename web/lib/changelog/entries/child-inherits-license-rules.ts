import type { ChangelogEntry } from "../format";

export const entry: ChangelogEntry = {
  id: "child-inherits-license-rules",
  date: "2026-09-30",
  time: "10:00",
  title: "A child client uses its parent's M365 license rules",
  items: [
    "A child client with its own M365 system didn't use its parent's license rules, even with \"follow the parent's roles and rules\" on. The rules are saved on the M365 system rather than the client, which that setting didn't cover, so its new hires got no rule-picked license",
    "Now a child that follows its parent's rules, and hasn't set license rules of its own, uses the parent's. Rules set on the child still win, and saving an empty list on the child means no rules",
    "The child's page shows the parent's rules it is using, with a link to the parent. \"Set this client's own rules\" starts from a copy of them, and \"Use the parent's rules instead\" clears the child's own",
    "A child with no systems of its own already planned with its parent's whole runbook, rules included; that is unchanged",
    "Re-plan the child's open cases to apply this to onboardings already in flight",
    "Web-only — no runner change",
  ],
};
