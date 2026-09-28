// Plans a CaseRequest into ordered Jobs. The brain's core logic.
// See docs/DATA_MODEL.md ("Planning a case").
import type { ClientSystem, Action, Mode } from "@prisma/client";
import { OPTIONAL_SECRETS } from "./secrets/optional-secrets";
import { STANDALONE } from "./profiles/ad-domain";

// A step's INTENT — chiefly for offboarding. "disable" = reversible containment (lock the account,
// isolate the device, revoke sessions); eventually safe to automate. "destructive" = actually deletes
// / unrecoverable (delete a mailbox, hard-delete the user); ALWAYS gated for human approval AND we
// snapshot state first (captureEvidence) so it's redoable/auditable. null = unclassified (the default
// for onboard, which isn't disable/destructive in this sense).
export type StepIntent = "disable" | "destructive";

export type PlannedJob = {
  systemKey: string;
  sequence: number;
  mode: Mode;
  requiresApproval: boolean;
  captureEvidence: boolean;
  intent: StepIntent | null;
  secretNames: string[];
  config: unknown;
  // Effective dependencies (lane-specific override applied, filtered to systems in this plan).
  // Persisted on the job so the claim gate runs the DAG, not strict sequence order.
  dependsOn: string[];
};

// The per-lane config shape seed.ts writes into ClientSystem.config.
type SystemConfig = {
  onboard?: unknown;
  offboard?: unknown;
  dependsOn?: Record<string, string[]>;
  runLast?: boolean;
  requestKey?: string;
  requiresApproval?: Record<string, boolean | undefined>;
  captureEvidence?: Record<string, boolean | undefined>;
  intent?: Record<string, StepIntent | undefined>;
};

// Maps an on-request system to the intake-payload signal that turns it on. This is the
// generalized mechanism (vs hardcoding per profile): add a row as new signals are mapped
// in the intake-mapper. A profile/editor can override via config.requestKey, and manual
// cases can set a payload flag named after the system key.
const REQUEST_SIGNALS: Record<string, (payload: Record<string, unknown>, action: Action) => boolean> = {
  teams: (p, a) => a === "onboard" && Boolean(p.officeLineRequired || p.cellPhoneRequired),
};

// Identity-flow invariant for on-prem-origin clients: when the identity ORIGINATES in on-prem AD, the
// order is ALWAYS create-in-AD -> directory-sync (push to the cloud) -> cloud consumers (entra / m365 /
// exchange, which need the synced user to exist). We enforce it at plan time so a mis-wired client can't
// deadlock — e.g. exchange waiting for a mailbox while the directory-sync that would create it is gated
// behind exchange.
//
// ONBOARD order. Offboarding is not the reverse of this chain, it is the reverse of its CLOUD half:
// the mailbox has to be converted to shared while the account still holds its licence, so `exchange`
// must run BEFORE the steps that strip the licence (entra / m365). Running the onboard chain on an
// offboard is what left a paid seat on every AD-origin leaver: entra ran first, correctly refused to
// remove a licence from an unconverted mailbox, warned "re-run once the mailbox step is done" — and
// nothing ever re-ran it. See OFFBOARD_LICENCE_SYSTEMS below.
const IDENTITY_PIPELINE_ONBOARD = ["active-directory", "directory-sync", "entra", "m365", "exchange"];
const IDENTITY_PIPELINE_OFFBOARD = ["active-directory", "directory-sync", "exchange", "entra", "m365"];

// The steps that take an M365 licence off. They must never run before `exchange` on an offboard.
const OFFBOARD_LICENCE_SYSTEMS = ["entra", "m365"];

// For an on-prem-origin client, the corrected dependencies for the pipeline systems: each keeps its
// NON-pipeline deps (e.g. servicenow) but its pipeline-to-pipeline edges (forward OR reversed) are
// replaced by the single chain edge to the previous ACTIVE pipeline system. Returns null (leave deps
// untouched) when the client is cloud-native.
function identityPipelineDeps(
  active: ClientSystem[],
  declaredOf: (s: ClientSystem) => string[],
  action: Action
): Map<string, string[]> | null {
  const activeKeys = new Set(active.map((s) => s.systemKey));
  // The invariant only exists where identity ORIGINATES on-prem and is PUSHED to the cloud — which is
  // precisely the clients that have a directory-sync. Keying on the mere presence of an
  // active-directory system swept up ad-standalone clients too (AD for file/print, 365 provisioned
  // separately, no sync): their profiles state outright that 365 is independent of AD, and this
  // rewrite silently reversed their declared entra/m365 order and gated an entire cloud offboard
  // behind an AD step they explicitly disclaim. No sync, no on-prem origin, no rewrite.
  if (!activeKeys.has("active-directory") || !activeKeys.has("directory-sync")) return null;
  const pipeline = action === "offboard" ? IDENTITY_PIPELINE_OFFBOARD : IDENTITY_PIPELINE_ONBOARD;
  const pipeActive = pipeline.filter((k) => activeKeys.has(k));
  const pipeSet = new Set(pipeActive);
  const byKey = new Map(active.map((s) => [s.systemKey, s]));
  const out = new Map<string, string[]>();
  for (let i = 0; i < pipeActive.length; i++) {
    const key = pipeActive[i];
    const prev = i > 0 ? pipeActive[i - 1] : null;
    const nonPipeline = declaredOf(byKey.get(key)!).filter((d) => !pipeSet.has(d));
    out.set(key, prev ? [...new Set([...nonPipeline, prev])] : nonPipeline);
  }
  return out;
}

// Decide whether a system participates in this action, given the case payload.
function included(cs: ClientSystem, action: Action, payload: Record<string, unknown>, personaSystems?: ReadonlySet<string>): boolean {
  const when = action === "onboard" ? cs.onboardWhen : cs.offboardWhen;
  if (when === "never") return false;
  if (when === "always") return true;
  // by_persona: only when the selected persona's bundle lists this system (no persona -> excluded,
  // same shape as an unsignalled on_request). The key set comes from the caller via
  // personaSystemKeys() so persona selection stays centralized in buildPlanContext.
  if (when === "by_persona") return personaSystems?.has(cs.systemKey) ?? false;
  // on_request: explicit requestKey override -> central signal map -> systemKey fallback.
  const cfg = cs.config as SystemConfig | null;
  if (cfg?.requestKey) return Boolean(payload[cfg.requestKey]);
  const signal = REQUEST_SIGNALS[cs.systemKey];
  if (signal) return signal(payload, action);
  return Boolean(payload[cs.systemKey]);
}

// Topological sort honoring dependsOn, with the order the systems are passed in as the tiebreak —
// the planning services pass them in the client's documented runbook order (inDocumentedOrder,
// FR #0000178). Lane-specific deps, if present in config.dependsOn[action], override the system-level
// dependsOn.
export function planCase(
  systems: ClientSystem[],
  action: Action,
  payload: Record<string, unknown>,
  // System keys the selected persona pulls in — gates by_persona lanes only (see personaSystemKeys).
  personaSystems?: ReadonlySet<string>,
  // Secret names the client marked "not needed" (the NOT_NEEDED sentinel). A system whose every
  // required secret is marked so is done by hand — planned as a manual step, not an api job.
  notNeededSecrets?: ReadonlySet<string>,
  // OPTIONAL secret names this client has actually WIRED (a real Delinea reference). An optional
  // secret (e.g. ad-dc, which AD only needs off a domain controller — a DC agent authenticates as
  // ambient SYSTEM) is stripped from a job's required secretNames UNLESS the client wired it, in
  // which case it's kept so the runner brokers it as the fallback. Mirrors wiredOptionalSecrets.
  wiredOptional?: ReadonlySet<string>,
  // System keys to exclude from this plan regardless of onboardWhen (per-contact intake rules,
  // FR #0000019). Skipping active-directory also suppresses the synthetic ad-email-writeback /
  // ad-consistency-check steps, which only inject when active-directory is active.
  skipSystems?: ReadonlySet<string>,
  // The client's backbone (profile spelling "ad-standalone" or Prisma's "ad_standalone" — both
  // accepted, see STANDALONE). Only consulted to suppress the two synthetic hybrid-only steps below
  // for standalone clients; undefined means "not standalone", i.e. every caller's existing behaviour.
  backbone?: string | null
): PlannedJob[] {
  const active = systems.filter(
    (s) => !skipSystems?.has(s.systemKey) && included(s, action, payload, personaSystems)
  );
  // Standalone: AD and the cloud are two separate accounts for one person, managed independently —
  // neither of the synthetic hybrid steps below makes sense there (FR #107).
  const isAdStandalone = STANDALONE.has(String(backbone ?? ""));
  // Synthetic ONBOARD step: once the cloud mailbox exists, write the assigned email back into AD's
  // `mail` attribute. Applies to every AD-origin client (identity starts on-prem) automatically — no
  // per-client ClientSystem row or migration. It depends on the cloud consumers present (m365/exchange)
  // so it runs after them; the actual address is resolved + injected at dispatch time (runner-service
  // claim), since it isn't known until those run. Routed on-prem via ALWAYS_ON_PREM_SYSTEMS.
  const activeKeys = new Set(active.map((s) => s.systemKey));
  // NOT for ad-standalone: there, AD and the cloud are two separate accounts for one person, managed
  // independently — so writing the CLOUD mailbox address into on-prem `mail` is wrong, not helpful
  // (FR #107). Hybrid (ad_synced) is the case this step exists for.
  if (action === "onboard" && !isAdStandalone && activeKeys.has("active-directory") && (activeKeys.has("m365") || activeKeys.has("exchange")) && !activeKeys.has("ad-email-writeback")) {
    const base = active.find((s) => s.systemKey === "active-directory")!;
    active.push({
      ...base,
      id: `${base.clientId}:ad-email-writeback`,
      systemKey: "ad-email-writeback",
      mode: "api",
      onboardWhen: "always",
      offboardWhen: "never",
      dependsOn: ["m365", "exchange"].filter((k) => activeKeys.has(k)),
      requiresApproval: false,
      captureEvidence: false,
      secretNames: ["ad-dc"],
      config: null,
    } as ClientSystem);
  }
  // Synthetic ONBOARD step: hybrid identity-link CHECK. For every AD + cloud client, after the cloud
  // account resolves, verify the on-prem object's source anchor (mS-DS-ConsistencyGuid / objectGUID)
  // matches the Entra immutableId — so a rehire / pre-existing cloud account LINKS instead of spawning
  // a duplicate. Detect + flag only (no auto-write). Runs on the client agent; the app injects the
  // Entra object's id/immutableId/sync state (from the m365 result) at dispatch time.
  // NOT for ad-standalone: the on-prem object is not supposed to link to the cloud one, so an anchor
  // comparison can only ever report a mismatch — noise that trains operators to ignore the warning
  // where it does matter (FR #107).
  if (action === "onboard" && !isAdStandalone && activeKeys.has("active-directory") && (activeKeys.has("m365") || activeKeys.has("entra")) && !activeKeys.has("ad-consistency-check")) {
    const base = active.find((s) => s.systemKey === "active-directory")!;
    active.push({
      ...base,
      id: `${base.clientId}:ad-consistency-check`,
      systemKey: "ad-consistency-check",
      mode: "api",
      onboardWhen: "always",
      offboardWhen: "never",
      dependsOn: ["m365", "entra", "ad-email-writeback"], // filtered to present systems by declaredOf below
      requiresApproval: false,
      captureEvidence: false,
      secretNames: ["ad-dc"],
      config: null,
    } as ClientSystem);
  }
  const byKey = new Map(active.map((s) => [s.systemKey, s]));
  // Closing steps must run AFTER everything else, whatever the declared deps say — under DAG
  // gating an under-declared dependsOn would otherwise let case-resolution dispatch first.
  // runLast systems implicitly depend on every other (non-runLast) active system; among multiple
  // runLast systems the declared deps/order decide.
  const runLast = (s: ClientSystem) =>
    s.systemKey === "case-resolution" || Boolean((s.config as SystemConfig | null)?.runLast);
  const declaredOf = (s: ClientSystem): string[] => {
    const laneDeps = (s.config as SystemConfig | null)?.dependsOn?.[action];
    return (laneDeps ?? s.dependsOn).filter((d) => byKey.has(d));
  };
  // Enforce the on-prem identity flow (AD -> directory-sync -> cloud) for pipeline systems; other
  // systems keep their declared deps. This can't be reversed by bad data, so it's deadlock-proof.
  const pipelineDeps = identityPipelineDeps(active, declaredOf, action);
  // OFFBOARD safety invariant, for EVERY client — not just on-prem-origin ones. The mailbox must be
  // converted to shared before its licence is removed: strip the licence off a mailbox that is still a
  // UserMailbox and Exchange purges it after the 30-day grace. Most profiles declare the opposite
  // (`exchange dependsOn m365`, inherited from the onboard lane where the mailbox needs a licence
  // first), and the ~200 seeded clients carry that ordering in the database where a profile edit can't
  // reach them. So make it structural: on an offboard, entra/m365 wait for exchange, and exchange
  // drops any declared edge onto them — which is also what keeps the two rules from forming a cycle.
  const convertBeforeLicence = action === "offboard" && byKey.has("exchange");
  const offboardOrdered = (key: string, declared: string[]): string[] => {
    if (!convertBeforeLicence) return declared;
    if (OFFBOARD_LICENCE_SYSTEMS.includes(key)) return [...new Set([...declared, "exchange"])];
    if (key === "exchange") return declared.filter((d) => !OFFBOARD_LICENCE_SYSTEMS.includes(d));
    return declared;
  };
  const depsOf = (s: ClientSystem): string[] => {
    const declared = offboardOrdered(s.systemKey, pipelineDeps?.get(s.systemKey) ?? declaredOf(s));
    if (!runLast(s)) return declared;
    const everyoneElse = active.filter((o) => o.systemKey !== s.systemKey && !runLast(o)).map((o) => o.systemKey);
    return [...new Set([...declared, ...everyoneElse])];
  };

  // A step's dependencies are pulled in that same order too, not the order its dependsOn lists them.
  const position = new Map(active.map((s, i) => [s.systemKey, i]));
  const inPassedOrder = (keys: string[]) => [...keys].sort((a, b) => position.get(a)! - position.get(b)!);

  const order: ClientSystem[] = [];
  const state = new Map<string, "open" | "done">();
  const visit = (s: ClientSystem) => {
    if (state.get(s.systemKey) === "done") return;
    if (state.get(s.systemKey) === "open") throw new Error(`dependency cycle at ${s.systemKey}`);
    state.set(s.systemKey, "open");
    for (const d of inPassedOrder(depsOf(s))) visit(byKey.get(d)!);
    state.set(s.systemKey, "done");
    order.push(s);
  };
  for (const s of active) visit(s);

  return order.map((s, i) => {
    const cfg = s.config as SystemConfig | null;
    // Per-lane flags: if config carries the per-lane map use it authoritatively (an absent
    // lane means false — no cross-lane bleed); otherwise fall back to the collapsed column.
    const ra = cfg?.requiresApproval;
    const ce = cfg?.captureEvidence;
    // Effective intent for this lane. Offboard defaults to "disable" (most offboard work is
    // reversible containment) so every offboard step carries a classification; onboard is unclassified.
    const intent: StepIntent | null = cfg?.intent?.[action] ?? (action === "offboard" ? "disable" : null);
    const destructive = intent === "destructive";
    // OPTIONAL secrets for this system (e.g. ad-dc for AD): never REQUIRED, so they don't count toward
    // the manual-step rule and are only kept in secretNames when the client actually wired them.
    const optionalForSys = OPTIONAL_SECRETS[s.systemKey] ?? [];
    const requiredNames = s.secretNames.filter((n) => !optionalForSys.includes(n));
    // "Not needed" secrets = the system has no credential to broker because a human does this step
    // (the same rule readiness.ts calls notNeeded). Plan it as a MANUAL checklist item: left as an
    // api job it would dispatch, fail at the credential broker (409 "marked not needed"), and take
    // the case down with it. A real credential appearing later flips it straight back to api. Only
    // REQUIRED secrets count — a system whose only secret is optional (AD/ad-dc) runs api (ambient),
    // NOT manual, even when that optional secret is marked not-needed.
    const noCredNeeded =
      s.mode === "api" && requiredNames.length > 0 && requiredNames.every((n) => notNeededSecrets?.has(n) ?? false);
    const mode: Mode = noCredNeeded ? "manual" : s.mode;
    // Required names plus any optional secret this system lists that the client HAS wired (kept so the
    // runner brokers it as the fallback — e.g. a member-server AD agent that genuinely needs ad-dc).
    const jobSecretNames = [
      ...requiredNames,
      ...optionalForSys.filter((n) => s.secretNames.includes(n) && (wiredOptional?.has(n) ?? false)),
    ];
    return {
      systemKey: s.systemKey,
      sequence: i,
      mode,
      dependsOn: depsOf(s),
      intent,
      // Approval gates only auto-executing API steps. A manual/browser step is done by a human, so
      // the act of doing it IS the approval — it must never put the case in "needs approval".
      // A DESTRUCTIVE step ALWAYS requires approval (and evidence below) — it can't be turned off.
      requiresApproval: mode === "api" ? (destructive || (ra ? Boolean(ra[action]) : s.requiresApproval)) : false,
      // Destructive steps ALWAYS snapshot state first ("save the settings so we can redo it").
      captureEvidence: destructive || (ce ? Boolean(ce[action]) : s.captureEvidence),
      // SentinelOne's offboard resolves the user's machines from their Entra registered devices, so it
      // also needs the m365-admin app brokered (catalog-wide, no per-client wiring).
      //
      // CAUTION before you copy this: every name here is treated as REQUIRED downstream — the claim
      // gate skips a job with any unreferenced secret (runner-service missingRequiredSecrets) and the
      // runner brokers each name unconditionally. So an OPTIONAL secret must never be appended here;
      // it would make the step unclaimable for every client that hasn't wired it. See
      // lib/secrets/auxiliary.ts, which attaches optional secrets only where they're actually wired.
      secretNames: s.systemKey === "sentinelone" && !jobSecretNames.includes("m365-admin")
        ? [...jobSecretNames, "m365-admin"]
        : jobSecretNames,
      // The runner needs only this action's resolved config, not the whole blob. planCase is only
      // ever invoked for onboard/offboard (change has its own planner) — cfg only has those two keys.
      config: cfg ? (cfg[action as "onboard" | "offboard"] ?? null) : null,
    };
  });
}
