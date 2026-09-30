// Static knowledge for the KB->profile generator: how runbook section headers map to
// system keys, the default mode/lane/secret for each modeled system, and how to infer the
// identity backbone from what was detected. Mirrors docs/modules/_INDEX.md.

export type Lane = "always" | "on-request" | "never" | "by-persona";
export type Mode = "api" | "browser" | "manual" | "scim";

export type CatalogEntry = {
  mode: Mode;
  tier: 1 | 2 | 3;
  onboard: Lane | null; // null = system absent for that action
  offboard: Lane | null;
  secret?: string; // logical secret name (-> top-level secrets map + system.secrets)
  dependsOn?: string[];
};

// Per-system defaults for a *draft* profile. Hand-tuned from the module specs + six-one.json.
export const CATALOG: Record<string, CatalogEntry> = {
  servicenow:        { mode: "manual", tier: 1, onboard: "always", offboard: "always" }, // no write-back executor yet — manual checklist
  "active-directory":{ mode: "api", tier: 2, onboard: "always", offboard: "always", secret: "ad-dc", dependsOn: ["servicenow"] },
  "directory-sync":  { mode: "api", tier: 2, onboard: "always", offboard: "always", secret: "ad-dc", dependsOn: ["active-directory"] },
  m365:              { mode: "api", tier: 1, onboard: "always", offboard: "always", secret: "m365-admin", dependsOn: ["servicenow"] },
  entra:             { mode: "api", tier: 1, onboard: null,     offboard: "always", secret: "m365-admin", dependsOn: ["m365"] },
  exchange:          { mode: "api", tier: 1, onboard: null,     offboard: "always", secret: "m365-admin", dependsOn: ["m365"] },
  "google-workspace":{ mode: "api", tier: 2, onboard: "always", offboard: "always", secret: "google-admin" },
  mimecast:          { mode: "api", tier: 2, onboard: "always", offboard: "always", secret: "mimecast", dependsOn: ["m365"] },
  proofpoint:        { mode: "api", tier: 3, onboard: "always", offboard: "always", secret: "proofpoint", dependsOn: ["m365"] },
  knowbe4:           { mode: "api", tier: 2, onboard: "always", offboard: "always", secret: "knowbe4", dependsOn: ["m365"] },
  adobe:             { mode: "api", tier: 2, onboard: "on-request", offboard: "always", secret: "adobe", dependsOn: ["m365"] },
  spanning:          { mode: "api", tier: 3, onboard: "always", offboard: "always", secret: "spanning", dependsOn: ["m365"] },
  sharepoint:        { mode: "api", tier: 3, onboard: "on-request", offboard: "on-request", secret: "m365-admin", dependsOn: ["m365"] },
  zoom:              { mode: "api", tier: 3, onboard: "on-request", offboard: "on-request", secret: "zoom" },
  slack:             { mode: "api", tier: 3, onboard: "on-request", offboard: "on-request", secret: "slack" },
  egnyte:            { mode: "manual", tier: 3, onboard: "on-request", offboard: "on-request", secret: "egnyte" }, // executor exists; set mode:"api" per-client once that client's Egnyte is wired
  mdm:               { mode: "api", tier: 3, onboard: "on-request", offboard: "on-request", secret: "mdm" },
  dropbox:           { mode: "api", tier: 3, onboard: "on-request", offboard: "on-request", secret: "dropbox" },
  perimeter81:       { mode: "api", tier: 3, onboard: "on-request", offboard: "always", secret: "perimeter81", dependsOn: ["m365"] },
  // Endpoint containment + the apps the offboard "please remove from…" email used to name. Offboard-
  // focused (onboarding is out of band); destructive S1 actions are gated by requiresApproval per client.
  sentinelone:       { mode: "api", tier: 2, onboard: null, offboard: "always", secret: "sentinelone", dependsOn: ["m365"] },
  duo:               { mode: "api", tier: 3, onboard: null, offboard: "always", secret: "duo", dependsOn: ["m365"] },
  xmatters:          { mode: "api", tier: 3, onboard: null, offboard: "on-request", secret: "xmatters" },
  logicmonitor:      { mode: "api", tier: 3, onboard: null, offboard: "on-request", secret: "logicmonitor" },
  // Offboard completion notice (Graph sendMail via m365-admin): communication email + SN case note.
  // Runs LAST — its per-client dependsOn lists the other offboard steps.
  notify:            { mode: "api", tier: 3, onboard: null, offboard: "on-request", secret: "m365-admin", dependsOn: ["m365"] },
  // Teams Phone signs in with the m365-admin app (Coretelligent.Teams). Offboard releases the number.
  teams:             { mode: "api", tier: 3, onboard: "on-request", offboard: "always", secret: "m365-admin", dependsOn: ["m365"] },
  avd:               { mode: "api", tier: 3, onboard: "on-request", offboard: "on-request", secret: "m365-admin", dependsOn: ["m365"] },
  "1password":       { mode: "api", tier: 3, onboard: "on-request", offboard: "on-request", secret: "1password" },
  notion:            { mode: "api", tier: 3, onboard: "on-request", offboard: null, secret: "notion" },
  tableau:           { mode: "manual", tier: 3, onboard: "on-request", offboard: null },
  printix:           { mode: "api", tier: 3, onboard: "on-request", offboard: null, secret: "printix" },
  uniflow:           { mode: "manual", tier: 3, onboard: "on-request", offboard: null }, // secure pull-printing — manual setup (emails the user a PIN)
  salesforce:        { mode: "api", tier: 3, onboard: "on-request", offboard: "always", secret: "salesforce", dependsOn: ["m365"] },
  jira:              { mode: "api", tier: 3, onboard: "on-request", offboard: "on-request", secret: "jira", dependsOn: ["m365"] },
  hubspot:           { mode: "api", tier: 3, onboard: "on-request", offboard: "on-request", secret: "hubspot", dependsOn: ["m365"] },
  "welcome-letter":  { mode: "manual", tier: 3, onboard: "always", offboard: null, dependsOn: ["m365"] },
  "first-day-call":  { mode: "manual", tier: 3, onboard: "always", offboard: null },
  hardware:          { mode: "manual", tier: 3, onboard: null, offboard: "on-request" },
  workstation:       { mode: "manual", tier: 3, onboard: "on-request", offboard: null },
  "case-resolution": { mode: "manual", tier: 1, onboard: "always", offboard: "always", dependsOn: ["m365"] }, // SN write-back not available — manual
};

// Ordered header->systemKey rules. First match wins. Headers are stripped of leading
// numbering ("1. ") and lowercased before matching.
const HEADER_RULES: Array<[RegExp, string]> = [
  [/service ?now|^snow$/, "servicenow"],
  // specific m365 forms only — avoid generic "admin center" (zoom/google/adobe) and bare "365" (retention policies)
  [/microsoft 365|office 365|^m365$|o365|365 admin|^admin center$/, "m365"],
  [/case resolution|final steps/, "case-resolution"],
  [/welcome letter|welcome email/, "welcome-letter"],
  [/first day|day one|first-day/, "first-day-call"],
  [/workstation|new device|computer build|new computer|pc setup/, "workstation"],
  [/hardware/, "hardware"],
  [/mimecast/, "mimecast"],
  [/proofpoint/, "proofpoint"],
  [/spanning/, "spanning"],
  [/entra|azure active directory|azure ad/, "entra"],
  [/ad sync|aad ?connect|directory sync/, "directory-sync"],
  [/active directory/, "active-directory"],
  [/exchange|mailbox auditing/, "exchange"],
  [/knowbe4|know be4|security awareness/, "knowbe4"],
  [/salesforce|sfdc/, "salesforce"],
  [/jira|atlassian|confluence/, "jira"],
  [/hubspot|hub spot/, "hubspot"],
  [/g[- ]?suite|gsuite|google/, "google-workspace"],
  [/zoom/, "zoom"],
  [/egnyte/, "egnyte"],
  [/adobe/, "adobe"],
  [/slack/, "slack"],
  [/sharepoint/, "sharepoint"],
  [/\bteams\b/, "teams"],
  [/dropbox/, "dropbox"],
  [/1 ?password/, "1password"],
  [/notion/, "notion"],
  [/tableau/, "tableau"],
  [/uni ?flow/, "uniflow"],
  [/printix/, "printix"],
  [/perimeter ?81/, "perimeter81"],
  [/sentinel ?one|sentinel1|\bs1\b/, "sentinelone"],
  [/\bduo\b/, "duo"],
  [/x ?matters/, "xmatters"],
  [/logic ?monitor/, "logicmonitor"],
];

// Does this text mention the given system by ITS OWN name rules? Used to reject an LLM section
// mapping when neither the title nor the steps ever name the product (a near-miss hallucination,
// e.g. a Dashlane section mapped to "1password").
export function textMentionsSystem(key: string, text: string): boolean {
  const s = text.toLowerCase();
  return HEADER_RULES.some(([re, k]) => k === key && re.test(s));
}

// Some catalog keys (mdm, avd, notify) have NO name rules — for those, textMentionsSystem can never
// return true, so a "does the text substantiate this key?" check must not be applied to them.
export function systemHasNameRules(key: string): boolean {
  return HEADER_RULES.some(([, k]) => k === key);
}

// Map a raw runbook header to a system key, or null if it isn't a modeled system.
export function headerToSystemKey(header: string): string | null {
  const s = header.toLowerCase().replace(/^\s*\d+[.)]\s*/, "").trim();
  for (const [re, key] of HEADER_RULES) if (re.test(s)) return key;
  return null;
}

// Infer the identity backbone from the set of detected system keys.
export function inferBackbone(keys: Set<string>): { backbone: "entra" | "google" | "ad-synced" | "ad-standalone"; confident: boolean } {
  const hasAD = keys.has("active-directory");
  const hasSync = keys.has("directory-sync");
  const hasGoogle = keys.has("google-workspace");
  const hasM365 = keys.has("m365");
  if (hasAD && hasSync) return { backbone: "ad-synced", confident: true };
  if (hasAD) return { backbone: "ad-standalone", confident: true };
  if (hasGoogle && !hasM365) return { backbone: "google", confident: true };
  // google + m365 is ambiguous (M365-primary with Google apps vs Google-primary mirror);
  // default to entra and flag low-confidence so --enrich resolves it.
  if (hasGoogle && hasM365) return { backbone: "entra", confident: false };
  return { backbone: "entra", confident: hasM365 };
}
