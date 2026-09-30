// Per-case credential resolution + "where does this step run" helpers. The credential broker prefers
// a case-level override (a one-off / fill-in reference) over the client's default; both are Delinea
// REFERENCES (ids), never values. Pure functions here are unit-tested; DB-touching status lives in
// case-secrets-repo.

export type SecretSource = "case" | "client" | "parent" | "missing" | "not_needed";

// Sentinel reference meaning "this module is handled as a manual step — don't require a credential."
// Stored as a secret's externalId so it travels with the client wiring (and can be set as a case
// override). The broker never resolves it; the preflight treats it as satisfied, not missing.
export const NOT_NEEDED = "NOT_NEEDED";

// Extract a server/host hint from a secret label, e.g. "Domain controller (core-cce-dc01) admin"
// -> "core-cce-dc01". Returns null when the label names no host.
export function serverHintFromLabel(label?: string | null): string | null {
  if (!label) return null;
  const m = label.match(/\(([^)]+)\)/);
  if (!m) return null;
  const h = m[1].trim();
  // A hostname has a dot or hyphen and NO whitespace ("core-cce-dc01"); a parenthetical like
  // "On-Boarding Script" (an app name) is not a server.
  return h && !/\s/.test(h) && /[.-]/.test(h) ? h : null;
}

// active-directory + directory-sync only exist on the client network — never runnable centrally.
// exchange is the only AMBIGUOUS one: on-prem Exchange (hybrid) vs Exchange Online (cloud). It's
// on-prem ONLY for a client that actually has an on-prem AD/sync system. A no-AD client is NOT
// hybrid — even if a backbone was mislabeled "ad-synced" — so its exchange runs centrally.
export const ALWAYS_ON_PREM_SYSTEMS = ["active-directory", "directory-sync", "ad-email-writeback", "ad-phone-writeback", "ad-consistency-check", "ad-hard-match", "ad-password-reset"];

export function systemIsOnPrem(systemKey: string, clientHasOnPremAd: boolean): boolean {
  if (ALWAYS_ON_PREM_SYSTEMS.includes(systemKey)) return true;
  if (systemKey === "exchange") return clientHasOnPremAd;
  return false;
}

// Human label for where a step executes: on-prem systems run on the client-network agent (named
// server if the secret label gives one); cloud systems on the central runner; servicenow/case
// resolution are app/manual. `clientHasOnPremAd` = the client actually has an AD/sync system.
export function stepRunsOn(systemKey: string, clientHasOnPremAd: boolean, serverHints: string[]): string {
  const onPrem = systemIsOnPrem(systemKey, clientHasOnPremAd);
  const where = onPrem
    ? "Client-network agent"
    : systemKey === "servicenow" || systemKey === "case-resolution"
      ? "App / manual"
      : "Central / cloud runner";
  const server = serverHints.map((s) => s.trim()).filter(Boolean)[0];
  return server ? `${where} · ${server}` : where;
}

// Preflight: which of a job's required secrets have NO usable reference (case override > client
// default, both missing/REPLACE_ME). A non-empty result means the job can't run — the broker can't
// hand the runner a credential — so it shouldn't be claimed. clientSecretByName maps the client's
// secret name -> its stored externalId.
export function missingRequiredSecrets(
  secretNames: string[] | undefined,
  overrides: unknown,
  clientSecretByName: Map<string, string | null>,
  parentSecretByName?: Map<string, string | null>
): string[] {
  const missing: string[] = [];
  for (const name of secretNames ?? []) {
    const { externalId, source } = effectiveExternalId(name, overrides, clientSecretByName.get(name) ?? null, parentSecretByName?.get(name) ?? null);
    // "not needed" is intentional (manual-step module) — satisfied, not missing.
    if (!externalId && source !== "not_needed") missing.push(name);
  }
  return missing;
}

// Every required secret resolves to the NOT_NEEDED sentinel — the system is handled by hand, so there
// is nothing for the broker to hand a runner. planCase already plans such a system as a manual
// checklist item (orchestrator: noCredNeeded), but a job planned while a real credential still existed
// and marked not-needed AFTERWARDS is already sitting in the queue as an api step: it gets claimed
// (missingRequiredSecrets counts not-needed as satisfied), dispatched, and dies at the broker with a
// 409 — failing the whole case over a step a human was always going to do. The claim gate uses this to
// demote such a job to the manual checklist item it should have been.
// A MISSING secret is deliberately not "not needed": that step is blocked pending wiring, not manual.
export function allSecretsNotNeeded(
  secretNames: string[] | undefined,
  overrides: unknown,
  clientSecretByName: Map<string, string | null>,
  parentSecretByName?: Map<string, string | null>
): boolean {
  const names = secretNames ?? [];
  if (names.length === 0) return false;
  return names.every(
    (name) =>
      effectiveExternalId(name, overrides, clientSecretByName.get(name) ?? null, parentSecretByName?.get(name) ?? null).source === "not_needed"
  );
}

// The reference the broker should use for a secret on this case: a case override wins over the
// client default; null when neither is set (the step can't run until it's filled).
// Precedence: a case OVERRIDE wins, then the CHILD client's own reference, then (for a child account
// running its parent's runbook) the PARENT client's reference, else missing. A "not needed" marker at
// any tier that's reached short-circuits as satisfied. `parentExternalId` is the parent client's
// reference for the same name (only consulted when the child has none of its own).
export function effectiveExternalId(
  name: string,
  overrides: unknown,
  clientExternalId: string | null | undefined,
  parentExternalId?: string | null | undefined
): { externalId: string | null; source: SecretSource } {
  const o = overrides && typeof overrides === "object" ? (overrides as Record<string, unknown>)[name] : undefined;
  // A case override wins — including an override that marks the secret not-needed for this case.
  if (typeof o === "string" && o.trim() === NOT_NEEDED) return { externalId: null, source: "not_needed" };
  if (typeof o === "string" && o.trim() && o.trim() !== "REPLACE_ME") return { externalId: o.trim(), source: "case" };
  // Child client's own reference (or "not needed" marker).
  if (typeof clientExternalId === "string" && clientExternalId.trim() === NOT_NEEDED) return { externalId: null, source: "not_needed" };
  if (typeof clientExternalId === "string" && clientExternalId.trim() && clientExternalId.trim() !== "REPLACE_ME") {
    return { externalId: clientExternalId.trim(), source: "client" };
  }
  // Inherit the parent account's reference when the child has none of its own (mirrors runbook/system
  // inheritance for child accounts). A parent "not needed" marker also inherits.
  if (typeof parentExternalId === "string" && parentExternalId.trim() === NOT_NEEDED) return { externalId: null, source: "not_needed" };
  if (typeof parentExternalId === "string" && parentExternalId.trim() && parentExternalId.trim() !== "REPLACE_ME") {
    return { externalId: parentExternalId.trim(), source: "parent" };
  }
  return { externalId: null, source: "missing" };
}
