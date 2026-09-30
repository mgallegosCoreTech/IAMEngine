// RUN REPORT: after-action aggregation of a case — per-step status (verified / warning /
// failed), the actions each module took, the validation read-backs, and any errors — plus a
// summary. A "warning" is a job that succeeded but whose validation missed (ok=false); warnings
// never fail the case (deriveCaseStatus is unchanged). Always available on-screen + as markdown.
//
// Pure core (buildRunReport) takes already-loaded rows so it's unit-testable without a DB; the
// DB loader (loadRunReport) gathers the inputs and a markdown renderer produces the export.
import type { PrismaClient } from "@prisma/client";
import { missingRequiredSecrets, ALWAYS_ON_PREM_SYSTEMS, systemIsOnPrem } from "./case-secrets";
import { parseCapabilities, agentCanRun, BROWSER_SYSTEMS } from "../runner/capabilities";
import { runnerBuildId } from "../runner/bundle";
import { outcomeFingerprint } from "../runs/outcomes-repo";
import { offboardCandidatesOf, offboardCandidateQuery, acceptedKeysFor, type OffboardCandidate } from "../jobs/runner-service";
import { blockingJobs, type JobLite } from "../jobs/runner-logic";
import { jobResultEnvelope } from "../jobs/job-result";
import { unmodeledStepTitle } from "./unmodeled-steps";

export type StepVerdict = "verified" | "warning" | "failed" | "skipped" | "manual" | "needs_approval" | "pending" | "running" | "verifying" | "retrying";

export type RunReportStep = {
  seq: number;
  jobId?: string; // for the per-step re-run action
  systemKey: string;
  systemName: string;
  status: string; // raw JobStatus
  // Flagged by "Run this step only" and cleared when the result lands. A pending singleRun step is
  // ARMED AND WAITING for a runner, not stalled — the report says so, because a paused case with a
  // silent step is exactly what made this look broken (FR #0000101).
  singleRun: boolean;
  verdict: StepVerdict;
  actions: string[];
  validation: { ok: boolean; checks: { name: string; expected?: unknown; actual?: unknown; pass: boolean }[] } | null;
  error: string | null;
  finishedAt: string | null;
  currentPhase: string | null; // what the runner is doing right now (in-flight steps only)
  lastProgressAt: string | null; // when this step last posted progress — the UI flags a running step
                                 // that's been silent too long as "no progress for Ns" (possible stall)
  autoStopped: boolean; // the server auto-stopped this step after it wedged (no progress); case continued
  phaseTrail: { ts: string; phase: string }[]; // the phases this step has gone through
  manualCompleted: boolean; // marked done by an operator (a manual/skipped step closed by hand)
  // The run-log fingerprint of this step's warning/failure — lets the operator "ignore" it. Resolving
  // it (by fingerprint) is STICKY: a re-run of the same line inherits the resolution. null when clean.
  fingerprint: string | null;
  accepted: boolean; // the operator ignored this warning/failure (its fingerprint is resolved)
  // Procurement-case watch on this step (license blocked on seats): when the PC resolves in SN the
  // job auto-re-queues. null = no watch.
  procurement: { number: string; state: string; note: string | null; lastCheckedAt: string | null } | null;
  // Self-scheduled retry (request.autoRetry): the step is waiting for a vendor-side sync (e.g.
  // Spanning discovering a new M365 user) and re-runs itself when `at` arrives. null = none.
  autoRetry: { at: string; count: number; firstAt: string } | null;
  // When an M365 license couldn't be assigned for lack of seats, the tenant's license inventory
  // (owned SKUs + free seat counts) so the operator can pick another and re-run. null otherwise.
  licenseOptions: { skuId: string; skuPartNumber: string; name: string; available: number; enabled: number; consumed: number }[] | null;
  // M365 onboard: service-plan(s) the runner had to hold back because a hard prerequisite wasn't met
  // (e.g. Defender for O365 P2 with no Exchange Online plan). The user got the base license; these
  // plans are OFF until the prerequisite exists. The UI shows a "retry license assignment" box; a
  // re-run re-enables any plan whose prerequisite is now present. null when the license is complete.
  licenseIssues:
    | { plan: string; sku: string; requires: string[]; resolution: string }[]
    | null;
  // OFFBOARD only: the executor could not tell WHICH person to offboard — the ticket's name matched
  // several users, or none — so it returned the shortlist it found instead of acting. The operator
  // picks one; the pick lands on the CASE payload (every system resolves the leaver from there) and the
  // case re-runs from the top. null when the target resolved cleanly.
  offboardCandidates: { query: string | null; reason: string; candidates: OffboardCandidate[] } | null;
  // Offboard step classification: "disable" = reversible containment (auto-runnable later),
  // "destructive" = deletes data (always approval-gated + evidence-snapshotted). null = unclassified.
  intent: "disable" | "destructive" | null;
  // M365 step (onboard): the license(s) this user is expected to get — the plan's resolved
  // config.licenses (which already applied the client's licensing rules), or the ticket's explicit
  // product licenses when present (those override the rule). null for non-m365 / offboard / none.
  expectedLicenses: { names: string[]; fromTicket: boolean } | null;
  // For a step sitting at "pending": WHY it hasn't started — waiting on predecessors, a missing
  // credential, or no runner online. The ordering part is computed here; loadRunReport refines the
  // "ready" case with credential/runner checks. null when the step isn't pending.
  pendingReason: string | null;
};

// Ad-hoc systemKeys have no SystemCatalog row, so their step title would fall back to the raw key
// ("spanning-force-sync"). Give them a human label here. Keep in sync with ADHOC_SYSTEM_KEYS. The view
// (run-report-view) folds the "force Spanning sync" step in UNDER the Spanning step so it reads as a
// sub-action of it rather than a bare, duplicated top-level warning.
export const ADHOC_STEP_LABELS: Record<string, string> = {
  "spanning-force-sync": "Spanning force sync",
  printers: "Printers",
};

export type RunReport = {
  caseId: string;
  caseNumber: string | null;
  subject: string | null;
  action: string;
  client: { name: string; slug: string };
  caseStatus: string;
  verifiedAt: string | null; // when the auto-verify sweep completed (null until verified)
  warningsDismissed?: { at: string; by: string | null } | null;
  verifying: boolean; // a validate-only sweep is in flight right now (persistent across step gaps)
  // Client credentials this case needs that AREN'T set up in Delinea yet (secret name -> the systems
  // that need it). Computed regardless of hold state, so an auto-imported case for an un-onboarded
  // client shows "credentials not set up" up front. Empty when everything resolves.
  credsMissing: { secretName: string; systems: string[] }[];
  // Intake fields the system couldn't determine — editable to fill in. held = the case is paused as
  // "Needs Information" until they're provided. null when there's nothing to fill.
  needsInfo: { fields: { field: string; label: string; note: string }[]; held: boolean } | null;
  // Fields the LLM filled as a last resort (marked for an operator to confirm). null when none.
  aiResolved: { field: string; note: string }[] | null;
  // Dry-run review (onboard): the resolved identity/detail fields that WILL be set (editable), plus
  // the groups (with type hint) and licenses the plan will apply. null for offboard.
  review: {
    fields: { key: string; label: string; value: string; source: "ai" | "operator" | "derived" }[];
    groups: { name: string; type: string | null }[];
    licenses: string[];
    fallbacks: string[]; // conflict-fallback usernames (payload.userPrincipalNameFallbacks)
    extraGroups: string; // operator-typed additional groups (FR #30), comma-separated for the input
  } | null;
  user: string | null;
  startedAt: string | null;
  finishedAt: string | null;
  steps: RunReportStep[];
  summary: { succeeded: number; warnings: number; failed: number; skipped: number; manual: number; needsApproval: number; pending: number; running: number };
};

type JobRow = {
  procurementWatch?: { number: string; state: string; note: string | null; lastCheckedAt: Date | null } | null;
  id?: string;
  systemKey: string;
  sequence: number;
  mode: string;
  status: string;
  // Set by "Run this step only" and cleared when the result lands (FR #0000101).
  singleRun?: boolean;
  request: unknown;
  result: unknown;
  validation: unknown;
  progress?: unknown;
  progressAt?: Date | null;
  error: string | null;
  startedAt: Date | null;
  finishedAt: Date | null;
};

export type BuildRunReportInput = {
  caseId: string;
  caseNumber: string | null;
  subject: string | null;
  action: string;
  caseStatus: string;
  verifiedAt?: string | null;
  pausedReason?: string | null;
  client: { name: string; slug: string };
  payload: Record<string, unknown>;
  jobs: JobRow[];
  names: Map<string, string>;
  // systemKeys whose FAILED outcome the operator accepted ("ignore warning") — they no longer block
  // dependents, so a step waiting on an accepted failure reads "ready", matching the claim gate.
  acceptedSystemKeys?: Set<string>;
};

// Pull the human-readable action lines out of a module result envelope ({ Actions: [...] } —
// PowerShell PascalCase; tolerate camelCase too).
function actionsOf(result: unknown): string[] {
  if (!result || typeof result !== "object") return [];
  const r = result as Record<string, unknown>;
  const a = r.Actions ?? r.actions;
  return Array.isArray(a) ? a.map(String) : [];
}

// A MANUAL step has no runner result, so it would otherwise render as an empty checklist line with
// nothing but its name. Its instruction lives in the step's own config (`note`, or `notes[]`) — surface
// that as the step's body, so a checklist item can actually say what the human is meant to do (or, as
// with the clients whose runbook forbids removing the licence, why the engine deliberately did NOT).
function manualNotesOf(request: unknown): string[] {
  const cfg = ((request ?? {}) as { config?: unknown }).config;
  if (!cfg || typeof cfg !== "object") return [];
  const c = cfg as Record<string, unknown>;
  const out: string[] = [];
  if (typeof c.note === "string" && c.note.trim()) out.push(c.note.trim());
  if (Array.isArray(c.notes)) out.push(...c.notes.filter((n): n is string => typeof n === "string" && n.trim().length > 0));
  return out;
}

function normalizeValidation(v: unknown): RunReportStep["validation"] {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const ok = o.ok ?? o.Ok ?? o.OK;
  const checksRaw = o.checks ?? o.Checks;
  const checks = Array.isArray(checksRaw)
    ? checksRaw.map((c) => {
        const cc = (c ?? {}) as Record<string, unknown>;
        return { name: String(cc.name ?? cc.Name ?? ""), expected: cc.expected ?? cc.Expected, actual: cc.actual ?? cc.Actual, pass: Boolean(cc.pass ?? cc.Pass) };
      })
    : [];
  return { ok: Boolean(ok), checks };
}

// The warning lines a single (succeeded) job contributes: its WARN-tagged actions plus any failed
// validation checks. Shared with the cases list so a "completed" case can show orange + the
// warnings on hover, with exactly the same definition of "warning" as the run report.
// The M365 license inventory returned on a seat shortage (result.AvailableLicenses), or null.
function licenseOptionsOf(result: unknown): RunReportStep["licenseOptions"] {
  if (!result || typeof result !== "object") return null;
  const raw = (result as Record<string, unknown>).AvailableLicenses ?? (result as Record<string, unknown>).availableLicenses;
  if (!Array.isArray(raw) || raw.length === 0) return null;
  const opts = raw
    .map((o) => o as Record<string, unknown>)
    .filter((o) => typeof o.skuId === "string")
    .map((o) => ({
      skuId: String(o.skuId),
      skuPartNumber: String(o.skuPartNumber ?? ""),
      name: String(o.name ?? o.skuPartNumber ?? "license"),
      available: Number(o.available ?? 0),
      enabled: Number(o.enabled ?? 0),
      consumed: Number(o.consumed ?? 0),
    }));
  return opts.length ? opts : null;
}

// Service-plan dependencies the M365 onboard held back (result.LicenseDependencyIssues), or null.
// Mirrors licenseOptionsOf — the runner already shaped the data; we just normalize the field casing
// (the runner emits PascalCase PlanName/SkuName/RequiresNames/Resolution).
function licenseIssuesOf(result: unknown): RunReportStep["licenseIssues"] {
  if (!result || typeof result !== "object") return null;
  const r = result as Record<string, unknown>;
  const raw = r.LicenseDependencyIssues ?? r.licenseDependencyIssues;
  if (!Array.isArray(raw) || raw.length === 0) return null;
  const issues = raw
    .map((o) => o as Record<string, unknown>)
    .map((o) => {
      const req = o.RequiresNames ?? o.requiresNames ?? o.Requires ?? o.requires;
      return {
        plan: String(o.PlanName ?? o.planName ?? o.PlanId ?? o.planId ?? "a service plan"),
        sku: String(o.SkuName ?? o.skuName ?? o.SkuId ?? o.skuId ?? "a license"),
        requires: Array.isArray(req) ? req.map((x) => String(x)).filter(Boolean) : [],
        resolution: String(o.Resolution ?? o.resolution ?? ""),
      };
    });
  return issues.length ? issues : null;
}

// The offboard-target shortlist a step returned when it couldn't resolve the leaver (result.Candidates),
// or null. Mirrors licenseOptionsOf: the runner already put the data in the result — we just shape it.
function offboardCandidatesFor(result: unknown): RunReportStep["offboardCandidates"] {
  const candidates = offboardCandidatesOf(result);
  if (!candidates.length) return null;
  const r = (result ?? {}) as Record<string, unknown>;
  return {
    query: offboardCandidateQuery(result),
    reason: String(r.CandidateReason ?? r.candidateReason ?? "ambiguous"),
    candidates,
  };
}

// The license(s) the M365 onboard step is expected to assign: the ticket's explicit product licenses
// when present (they override the rule, matching the runner), else the plan's resolved config.licenses
// (which already applied the client's licensing rules at plan time). null for non-m365/offboard/none.
function expectedLicensesFor(j: JobRow, action: string, payload: Record<string, unknown>): RunReportStep["expectedLicenses"] {
  if (j.systemKey !== "m365" || action !== "onboard") return null;
  const names = (v: unknown): string[] =>
    Array.isArray(v) ? v.map((l) => (typeof l === "string" ? l : String((l as { name?: unknown })?.name ?? ""))).map((s) => s.trim()).filter(Boolean) : [];

  const ticket = names(payload.productLicenses);
  if (ticket.length) return { names: [...new Set(ticket)], fromTicket: true };

  const cfg = (((j.request ?? {}) as { config?: unknown }).config ?? {}) as { licenses?: unknown; defaultLicenses?: unknown };
  const planned = names(cfg.licenses).length ? names(cfg.licenses) : names(cfg.defaultLicenses);
  return planned.length ? { names: [...new Set(planned)], fromTicket: false } : null;
}

export function jobWarningLines(result: unknown, validation: unknown): string[] {
  const lines = actionsOf(result).filter((a) => /\bWARN\b/i.test(a));
  const v = normalizeValidation(validation);
  if (v && !v.ok) {
    const missed = v.checks.filter((c) => !c.pass).map((c) => c.name).filter(Boolean);
    lines.push(missed.length ? `validation missed: ${missed.join(", ")}` : "validation missed");
  }
  return lines;
}

// One job's outcome for the append-only RunOutcome log: the same verdict the run report shows, plus
// the human messages worth tracking (the failure error, WARN actions, and validation misses). A
// clean success has no messages. Shared so the log and the report can never disagree on "warning".
export function jobOutcome(
  status: string,
  result: unknown,
  validation: unknown,
  error: string | null,
): { verdict: StepVerdict; messages: string[] } {
  let verdict = verdictOf(status, normalizeValidation(validation));
  if (verdict === "verified" && actionsOf(result).some((a) => /\bWARN\b/i.test(a))) verdict = "warning";
  const messages: string[] = [];
  if (error) messages.push(error);
  messages.push(...jobWarningLines(result, validation));
  return { verdict, messages };
}

function phaseTrailOf(progress: unknown): { ts: string; phase: string }[] {
  if (!Array.isArray(progress)) return [];
  return progress
    .map((p) => (p && typeof p === "object" ? (p as Record<string, unknown>) : {}))
    .filter((p) => typeof p.phase === "string")
    .map((p) => ({ ts: String(p.ts ?? ""), phase: String(p.phase) }));
}

function verdictOf(status: string, validation: RunReportStep["validation"], validateOnly = false): StepVerdict {
  switch (status) {
    case "succeeded":
      return validation && !validation.ok ? "warning" : "verified";
    case "failed":
      return "failed";
    case "skipped":
      return "skipped";
    case "manual":
      return "manual";
    case "dispatched":
    case "running":
      // A re-dispatch with validateOnly is the auto-verify sweep re-checking the step.
      return validateOnly ? "verifying" : "running";
    default:
      return "pending"; // pending
  }
}

function userHeader(action: string, payload: Record<string, unknown>): string | null {
  const u =
    action === "offboard"
      ? payload.userToOffboard ?? payload.userPrincipalName ?? payload.workEmail
      : payload.userPrincipalName ?? payload.workEmail ?? payload.displayName;
  return u ? String(u) : null;
}

export function buildRunReport(input: BuildRunReportInput): RunReport {
  const jobs = [...input.jobs].sort((a, b) => a.sequence - b.sequence);
  const summary = { succeeded: 0, warnings: 0, failed: 0, skipped: 0, manual: 0, needsApproval: 0, pending: 0, running: 0 };

  // The claim-gate view of every job, computed ONCE (the report is rebuilt on every case-page poll;
  // per-pending-step remapping was quadratic). Used by the pendingReason line below.
  const acceptedKeys = input.acceptedSystemKeys ?? new Set<string>();
  const liteOf = (o: JobRow): JobLite => {
    const r = (o.request ?? {}) as { requiresApproval?: boolean; approved?: boolean; dependsOn?: unknown };
    const deps = Array.isArray(r.dependsOn) ? (r.dependsOn as unknown[]).filter((d): d is string => typeof d === "string") : null;
    return {
      id: o.id ?? "", systemKey: o.systemKey, sequence: o.sequence,
      mode: o.mode as JobLite["mode"], status: o.status as JobLite["status"],
      requiresApproval: Boolean(r.requiresApproval), approved: Boolean(r.approved), dependsOn: deps,
      accepted: o.status === "failed" && acceptedKeys.has(o.systemKey),
    };
  };
  const lites = jobs.map(liteOf);

  const steps: RunReportStep[] = jobs.map((j, i) => {
    // Older rows can hold a pipeline-leaked ARRAY result ([null, {…envelope…}]) recorded before
    // recordResult normalized the shape; unwrap here so their actions/markers still render.
    const jr = jobResultEnvelope(j.result);
    const validation = normalizeValidation(j.validation);
    const req = (j.request ?? {}) as { requiresApproval?: boolean; approved?: boolean; validateOnly?: boolean; intent?: "disable" | "destructive" | null; autoStopped?: boolean };
    let verdict = verdictOf(j.status, validation, Boolean(req.validateOnly));
    // A pending approval-gated job is surfaced distinctly from an ordinary pending step.
    if (verdict === "pending" && req.requiresApproval && !req.approved) verdict = "needs_approval";
    // A step that succeeded but logged a WARN action (e.g. a group/license it couldn't apply) is a
    // warning, not a clean "verified" — surface it even when the validation read-back passed.
    // Match WARN anywhere in the action, not just the start — actions are often prefixed
    // ("license: WARN could not add to E5 group"), which a start-anchored match would miss.
    const stepActions = actionsOf(jr);
    if (verdict === "verified" && stepActions.some((a) => /\bWARN\b/i.test(a))) verdict = "warning";

    // A step that scheduled its OWN re-run (request.autoRetry) is deliberately waiting for a
    // vendor-side sync (e.g. Spanning discovering a new M365 user). Its validation "miss" is
    // EXPECTED until the sync lands, so show it as a benign "retrying" state — not a warning/failure
    // — and don't write a run-log outcome for it (the retry resolves it automatically).
    const autoRetryData = (() => {
      const ar = ((j.request ?? {}) as { autoRetry?: { at?: number; count?: number; firstAt?: number } }).autoRetry;
      return ar?.at ? { at: new Date(ar.at).toISOString(), count: ar.count ?? 1, firstAt: new Date(ar.firstAt ?? ar.at).toISOString() } : null;
    })();
    if (autoRetryData && (verdict === "warning" || verdict === "failed" || verdict === "verified")) verdict = "retrying";

    if (verdict === "verified") summary.succeeded++;
    else if (verdict === "warning") summary.warnings++;
    else if (verdict === "failed") summary.failed++;
    else if (verdict === "skipped") summary.skipped++;
    else if (verdict === "manual") summary.manual++;
    else if (verdict === "needs_approval") summary.needsApproval++;
    else if (verdict === "running" || verdict === "verifying" || verdict === "retrying") summary.running++;
    else summary.pending++;

    const manualCompleted = Boolean((jr as Record<string, unknown> | null)?.manualCompletion);
    // Why is a pending api step not running yet? THE gating rule is the runner's claim gate
    // (blockingJobs) — reused here, not mirrored, so the report can never disagree with what the
    // runner will actually do (the old hand-rolled copy counted ad-hoc jobs as blockers the claim
    // gate ignores, and applied "accepted" to steps that hadn't failed).
    let pendingReason: string | null = null;
    if (j.status === "pending" && j.mode === "api" && verdict === "pending") {
      const blockers = blockingJobs(liteOf(j), lites);
      pendingReason = blockers.length
        ? `waiting for ${blockers.map((b) => input.names.get(b.systemKey) ?? b.systemKey).join(", ")} to finish first`
        : "ready — waiting for a runner to claim it";
    }
    const phaseTrail = phaseTrailOf(j.progress);
    // Only show a "current phase" while the step is actually in flight — a finished step's last
    // phase isn't what it's "doing now".
    const inFlight = j.status === "running" || j.status === "dispatched";
    const currentPhase = inFlight && phaseTrail.length ? phaseTrail[phaseTrail.length - 1].phase : null;

    // The run-log fingerprint for a warning/failed step — same line recordResult wrote, so "ignore"
    // resolves the SAME row (and re-runs inherit it). null for clean/in-progress steps.
    let fingerprint: string | null = null;
    if (verdict === "warning" || verdict === "failed") {
      const oc = jobOutcome(j.status, jr, j.validation, j.error);
      fingerprint = outcomeFingerprint({ caseRequestId: input.caseId, systemKey: j.systemKey, verdict: oc.verdict, messages: oc.messages, error: j.error });
    }

    return {
      seq: i + 1,
      jobId: j.id,
      fingerprint,
      accepted: false, // loadRunReport flips this on when the fingerprint is resolved

      procurement: j.procurementWatch
        ? { number: j.procurementWatch.number, state: j.procurementWatch.state, note: j.procurementWatch.note ?? null, lastCheckedAt: j.procurementWatch.lastCheckedAt ? new Date(j.procurementWatch.lastCheckedAt).toISOString() : null }
        : null,
      systemKey: j.systemKey,
      // An unmodeled step carries its runbook title on the job — show that, not the slugged
      // synthetic key ("Visual Studio Subscriptions", not "unmodeled:visual-studio-subscriptions").
      systemName: unmodeledStepTitle(j.request) ?? input.names.get(j.systemKey) ?? ADHOC_STEP_LABELS[j.systemKey] ?? j.systemKey,
      status: j.status,
      singleRun: Boolean(j.singleRun),
      verdict,
      // A manual step has no result to report — show its instruction note instead of an empty line.
      actions: j.mode === "manual" ? [...manualNotesOf(j.request), ...actionsOf(jr)] : actionsOf(jr),
      validation,
      error: j.error,
      finishedAt: j.finishedAt ? j.finishedAt.toISOString() : null,
      currentPhase,
      lastProgressAt: j.progressAt ? j.progressAt.toISOString() : null,
      autoStopped: Boolean(req.autoStopped),
      phaseTrail,
      manualCompleted,
      pendingReason,
      licenseOptions: licenseOptionsOf(jr),
      licenseIssues: licenseIssuesOf(jr),
      offboardCandidates: offboardCandidatesFor(jr),
      autoRetry: autoRetryData,
      intent: req.intent ?? null,
      expectedLicenses: expectedLicensesFor(j, input.action, input.payload),
    };
  });

  const times = jobs.map((j) => j.startedAt).filter(Boolean) as Date[];
  const ends = jobs.map((j) => j.finishedAt).filter(Boolean) as Date[];
  return {
    caseId: input.caseId,
    caseNumber: input.caseNumber,
    subject: input.subject,
    action: input.action,
    client: input.client,
    caseStatus: input.caseStatus,
    verifiedAt: input.verifiedAt ?? null,
    credsMissing: [], // filled in by loadRunReport (needs the client's Delinea secrets)
    needsInfo: (() => {
      const uf = input.payload.unknownFields;
      const fields = Array.isArray(uf)
        ? (uf as unknown[]).map((x) => x as { field?: unknown; label?: unknown; note?: unknown }).filter((x) => typeof x.field === "string").map((x) => ({ field: String(x.field), label: String(x.label ?? x.field), note: String(x.note ?? "") }))
        : [];
      return fields.length ? { fields, held: input.pausedReason === "needs_info" } : null;
    })(),
    aiResolved: (() => {
      const ar = input.payload.aiResolved;
      if (!ar || typeof ar !== "object") return null;
      const list = Object.entries(ar as Record<string, unknown>).map(([field, note]) => ({ field, note: String(note) }));
      return list.length ? list : null;
    })(),
    review: (() => {
      if (input.action !== "onboard") return null;
      const p = input.payload;
      const ai = (p.aiResolved && typeof p.aiResolved === "object" ? p.aiResolved : {}) as Record<string, unknown>;
      const defs: [string, string][] = [
        ["displayName", "Display name"], ["userPrincipalName", "UPN / username"], ["jobTitle", "Job title"],
        ["department", "Department"], ["managerName", "Manager"], ["officeLocation", "Office location"],
        ["usageLocation", "Usage location (M365)"], ["timezone", "Timezone"], ["startDate", "Start date"],
        // Teams Phone: blank = the next free number for the office's area code (lib/teams/phone.ts).
        ...(input.jobs.some((j) => j.systemKey === "teams") ? [["teamsPhoneNumber", "Teams phone number (blank = next free for the office)"] as [string, string]] : []),
      ];
      const srcMap = (p.fieldSource && typeof p.fieldSource === "object" ? p.fieldSource : {}) as Record<string, unknown>;
      const fields = defs.map(([key, label]) => ({
        key, label,
        value: p[key] == null ? "" : String(p[key]),
        source: (srcMap[key] === "operator" ? "operator" : key in ai ? "ai" : "derived") as "ai" | "operator" | "derived",
      }));
      // Groups/licenses can live on whichever job carries identity config (m365, entra, ad,
      // google…), so aggregate across every job rather than only m365.
      const groupMap = new Map<string, { name: string; type: string | null }>();
      const licSet = new Set<string>();
      for (const j of input.jobs) {
        const cfg = (((j.request ?? {}) as { config?: unknown }).config ?? {}) as { groups?: unknown; defaultGroups?: unknown; licenses?: unknown; defaultLicenses?: unknown };
        for (const g of (Array.isArray(cfg.groups) ? cfg.groups : Array.isArray(cfg.defaultGroups) ? cfg.defaultGroups : [])) {
          const name = typeof g === "string" ? g : String((g as { name?: unknown }).name ?? "");
          if (name && !groupMap.has(name)) groupMap.set(name, { name, type: typeof g === "string" ? null : (((g as { type?: unknown }).type as string) ?? null) });
        }
        for (const l of (Array.isArray(cfg.licenses) ? cfg.licenses : Array.isArray(cfg.defaultLicenses) ? cfg.defaultLicenses : [])) {
          const name = typeof l === "string" ? l : String((l as { name?: unknown }).name ?? "");
          if (name) licSet.add(name);
        }
      }
      const fallbacks = Array.isArray(p.userPrincipalNameFallbacks) ? (p.userPrincipalNameFallbacks as unknown[]).filter((x): x is string => typeof x === "string") : [];
      const extraGroups = Array.isArray(p.extraGroups)
        ? (p.extraGroups as unknown[]).filter((x): x is string => typeof x === "string").join(", ")
        : typeof p.extraGroups === "string" ? p.extraGroups : "";
      return { fields, groups: [...groupMap.values()], licenses: [...licSet], fallbacks, extraGroups };
    })(),
    // A sweep is in flight when a validate-only job is still pending/dispatched/running.
    verifying: input.jobs.some((j) => Boolean((j.request as { validateOnly?: boolean } | null)?.validateOnly) && ["pending", "dispatched", "running"].includes(j.status)),
    user: userHeader(input.action, input.payload),
    startedAt: times.length ? new Date(Math.min(...times.map((d) => d.getTime()))).toISOString() : null,
    finishedAt: ends.length ? new Date(Math.max(...ends.map((d) => d.getTime()))).toISOString() : null,
    steps,
    summary,
  };
}

const VERDICT_LABEL: Record<StepVerdict, string> = {
  verified: "✅ verified",
  warning: "⚠️ warning",
  failed: "❌ failed",
  skipped: "skipped",
  manual: "✋ manual",
  needs_approval: "🔒 needs approval",
  pending: "… pending",
  running: "● running",
  verifying: "🔎 verifying",
  retrying: "⟳ waiting for sync",
};

export function renderRunReportMarkdown(rr: RunReport): string {
  const out: string[] = [];
  out.push(`# Run report — ${rr.subject ?? rr.caseNumber ?? rr.caseId}`);
  out.push("");
  out.push(`- Client: ${rr.client.name} (${rr.client.slug})`);
  out.push(`- Action: ${rr.action}`);
  if (rr.user) out.push(`- User: ${rr.user}`);
  if (rr.caseNumber) out.push(`- ServiceNow: ${rr.caseNumber}`);
  out.push(`- Case status: ${rr.caseStatus}`);
  const s = rr.summary;
  out.push(`- Summary: ${s.succeeded} verified, ${s.warnings} warning, ${s.failed} failed, ${s.skipped} skipped, ${s.manual} manual, ${s.needsApproval} needs approval, ${s.pending} pending`);
  out.push("");
  for (const step of rr.steps) {
    out.push(`## ${step.seq}. ${step.systemName} (${step.systemKey}) — ${VERDICT_LABEL[step.verdict]}`);
    if (step.actions.length) {
      out.push("");
      out.push("Actions:");
      for (const a of step.actions) out.push(`- ${a}`);
    }
    if (step.validation) {
      out.push("");
      out.push(`Validation: ${step.validation.ok ? "ok" : "MISS"}`);
      for (const c of step.validation.checks) out.push(`- ${c.pass ? "✓" : "✗"} ${c.name}${c.expected !== undefined ? ` (expected ${String(c.expected)}, got ${String(c.actual)})` : ""}`);
    }
    if (step.error) {
      out.push("");
      out.push(`Error: ${step.error}`);
    }
    out.push("");
  }
  return out.join("\n");
}

export async function loadRunReport(db: PrismaClient, caseId: string): Promise<RunReport | null> {
  const c = await db.caseRequest.findUnique({
    where: { id: caseId },
    include: {
      client: { select: { id: true, name: true, slug: true, parentId: true } },
      jobs: { orderBy: { sequence: "asc" }, select: { id: true, systemKey: true, sequence: true, mode: true, status: true, singleRun: true, request: true, result: true, validation: true, progress: true, progressAt: true, error: true, startedAt: true, finishedAt: true, procurementWatch: { select: { number: true, state: true, note: true, lastCheckedAt: true } } } },
    },
  });
  if (!c) return null;

  const keys = [...new Set(c.jobs.map((j) => j.systemKey))];
  const catalog = await db.systemCatalog.findMany({ where: { key: { in: keys } }, select: { key: true, name: true } });
  const names = new Map(catalog.map((sc) => [sc.key, sc.name]));

  // systemKeys whose FAILED run was accepted ("ignore warning") — they no longer block dependents,
  // matching the claim gate. Same helper the claim gate uses, so the definition can never fork.
  const acceptedSystemKeys = await acceptedKeysFor(db, c.id);

  const report = buildRunReport({
    caseId: c.id,
    caseNumber: c.serviceNowCaseNumber,
    subject: c.subject,
    action: c.action,
    caseStatus: c.status,
    verifiedAt: c.verifiedAt ? c.verifiedAt.toISOString() : null,
    pausedReason: c.pausedReason,
    client: c.client,
    payload: (c.payload ?? {}) as Record<string, unknown>,
    jobs: c.jobs,
    names,
    acceptedSystemKeys,
  });

  report.warningsDismissed = c.warningsDismissedAt
    ? {
        at: c.warningsDismissedAt.toISOString(),
        by: c.warningsDismissedBy,
      }
    : null;

  // "Ignore warning" — a step whose run-log fingerprint the operator resolved is ACCEPTED: it no
  // longer counts against the case (and the run log already hides it + re-runs inherit it).
  const fps = report.steps.map((s) => s.fingerprint).filter((x): x is string => Boolean(x));
  if (fps.length) {
    const resolved = new Set(
      (await db.runOutcome.findMany({ where: { fingerprint: { in: fps }, resolvedAt: { not: null } }, select: { fingerprint: true } })).map((r) => r.fingerprint)
    );
    for (const st of report.steps) {
      if (!st.fingerprint || !resolved.has(st.fingerprint)) continue;
      st.accepted = true;
      if (st.verdict === "warning") { report.summary.warnings--; report.summary.succeeded++; st.verdict = "verified"; }
      else if (st.verdict === "failed") { report.summary.failed--; report.summary.succeeded++; st.verdict = "verified"; }
    }
  }

  // An operator-paused case: every pending step is held by the pause, whatever else is true.
  if (c.pausedAt) {
    for (const st of report.steps) {
      if (st.pendingReason) st.pendingReason = "case is paused — resume it to dispatch this step";
    }
    return report;
  }

  // Refine the "ready — waiting for a runner" pending steps with the two REAL blockers the
  // ordering rule can't see: an unset required credential (the claim preflight skips the job) and
  // no runner being online to claim it. This is the on-page answer to "it's just sitting at
  // pending with no feedback".
  // This client's Delinea secret refs — used by BOTH the per-step "waiting for a runner" refinement
  // and the case-level credsMissing banner below. Fetch ONCE (was queried twice per run-report load).
  const clientSecrets = await db.secret.findMany({ where: { clientId: c.client.id }, select: { name: true, externalId: true } });
  const byName = new Map<string, string | null>(clientSecrets.map((sx) => [sx.name, sx.externalId]));
  // A child account inherits its parent's secret refs (claim() passes this same parentMap, as does the
  // broker). Without it the report calls a perfectly runnable child-account step "blocked — credential
  // not set" — the runner would happily claim it. Display must agree with dispatch.
  let parentByName: Map<string, string | null> | undefined;
  if (c.client.parentId) {
    const parentSecrets = await db.secret.findMany({ where: { clientId: c.client.parentId }, select: { name: true, externalId: true } });
    parentByName = new Map<string, string | null>(parentSecrets.map((sx) => [sx.name, sx.externalId]));
  }

  const ready = report.steps.filter((st) => st.pendingReason === "ready — waiting for a runner to claim it");
  if (ready.length > 0) {
    const onlineAgents = await db.agent.findMany({
      where: { enabled: true, deletedAt: null, lastSeenAt: { gt: new Date(Date.now() - 90_000) } },
      select: { clientId: true, name: true, lastSeenAt: true, version: true, capabilities: true },
    });
    const build = runnerBuildId();
    const upToDate = (v: string | null) => !!v && /^[0-9a-f]{6,}$/.test(v) && v === build;
    // Hybrid (exchange runs on-prem) only when this case actually has an AD/sync job — matches the
    // claim filter. A cloud-only case's exchange is Exchange Online, claimable by the central runner.
    const caseHasOnPremAd = c.jobs.some((j) => ALWAYS_ON_PREM_SYSTEMS.includes(j.systemKey));
    // Own-agent pinning: a client with runCloudOnOwnAgent AND a registered client-network agent has ALL
    // its steps (cloud included) claimed by that agent, not central — mirror the claim rule so the reason
    // names the right runner instead of implying the (now-excluded) central runner.
    const clientRow = await db.client.findUnique({ where: { id: c.client.id }, select: { runCloudOnOwnAgent: true } });
    const ownAgentCount = clientRow?.runCloudOnOwnAgent
      ? await db.agent.count({ where: { clientId: c.client.id, scope: "client_network", enabled: true, deletedAt: null } })
      : 0;
    const pinsToOwnAgent = Boolean(clientRow?.runCloudOnOwnAgent) && ownAgentCount > 0;
    for (const st of ready) {
      const job = c.jobs.find((j) => j.id === st.jobId);
      const needed = ((job?.request ?? {}) as { secretNames?: string[] }).secretNames ?? [];
      // Same preflight rule the claim loop uses (case override > client default, REPLACE_ME = unset).
      const missing = missingRequiredSecrets(needed, c.secretOverrides, byName, parentByName);
      if (missing.length) {
        st.pendingReason = `blocked — credential not set: ${missing.join(", ")}. Fill it on the Credentials panel; the runner skips this step until it resolves.`;
        continue;
      }
      // Browser jobs (spanning-force-sync) run ONLY on the central runner (Node/Playwright), so — unlike
      // every other cloud job — they are NEVER pinned to a client's own agent, not even for a
      // runCloudOnOwnAgent client. Mirror the claim rule (browser jobs are exempt from own-agent pinning)
      // so the reason names the central runner instead of the client's browser-less on-prem agent.
      const isBrowser = BROWSER_SYSTEMS.includes(st.systemKey);
      // Host affinity, same rule as the claim filter: on-prem systems (AD/Exchange/dir-sync) are
      // ONLY claimed by the client's own agent — a central runner being online doesn't help them.
      const needsOwnAgent = !isBrowser && (systemIsOnPrem(st.systemKey, caseHasOnPremAd) || pinsToOwnAgent);
      const eligible = onlineAgents.filter((a) => (needsOwnAgent ? a.clientId === c.client.id : a.clientId === null || a.clientId === c.client.id));
      if (eligible.length === 0) {
        st.pendingReason = needsOwnAgent
          ? "ready, but this step runs on THIS CLIENT'S OWN agent (on-prem / cloud-on-own-agent) and none is online — check the Agents page"
          : "ready, but no runner is online to claim it — check the Agents page";
        continue;
      }
      // Capability gate — mirrors the claim filter: a system is only claimable by an agent that REPORTS it
      // can run it. On-prem systems need the reported on-prem capability; BROWSER systems need the
      // 'browser' capability (Node/Playwright), which only the central runner has — so filter to it, or a
      // client's browser-less agent (which polls constantly and would otherwise win the "claims it next"
      // pick) gets named for a step it can never claim. A legacy agent reports nothing → treated as
      // capable for on-prem, but browser is explicit-only (matches browserExclusions).
      const runnable = ALWAYS_ON_PREM_SYSTEMS.includes(st.systemKey)
        ? eligible.filter((a) => agentCanRun(st.systemKey, parseCapabilities(a.capabilities)))
        : isBrowser
        ? eligible.filter((a) => { const caps = parseCapabilities(a.capabilities); return !!caps && caps.includes("browser"); })
        : eligible;
      if (runnable.length === 0) {
        if (isBrowser) {
          // Only the central runner can run a browser job; if none with 'browser' is online, say exactly that.
          st.pendingReason = "ready, but no browser-capable runner is online — Spanning force sync runs on the central runner (Node/Playwright); check the Agents page";
          continue;
        }
        const names = [...new Set(eligible.map((a) => a.name))].join(", ");
        // AD is the common case with specific remediation (RSAT); keep the advice keyed to the system so
        // it's never wrong if this ever fires for another on-prem system (e.g. a future addition).
        const fix = st.systemKey === "active-directory"
          ? "the ActiveDirectory (RSAT) module isn't loaded there — install RSAT-AD-PowerShell (or use the runner's Troubleshoot) and restart it"
          : `the module for ${st.systemKey} isn't loaded there — install its host dependency and restart the runner`;
        st.pendingReason = `ready, but ${names} on ${c.client.name}'s network can't run ${st.systemKey} — ${fix}; it claims this step once it reports the capability.`;
        continue;
      }
      // The agent is online but on an OUTDATED build — the app won't dispatch jobs to it (it would run
      // stale code), so the step sits. Tell the operator exactly that instead of "about to start".
      const current = runnable.filter((a) => upToDate(a.version));
      if (current.length === 0) {
        const names = [...new Set(runnable.map((a) => a.name))].join(", ");
        st.pendingReason = `ready, but ${names} ${runnable.length > 1 ? "are" : "is"} on an OUTDATED build — the app won't dispatch jobs to it until you update it on the Agents page`;
        continue;
      }
      // Pull model: the runner claims on its next poll (~15s). Name it + show how fresh it is, so
      // "ready" reads as "about to start" instead of "stuck".
      const best = [...current].sort((x, y) => new Date(y.lastSeenAt ?? 0).getTime() - new Date(x.lastSeenAt ?? 0).getTime())[0];
      const secs = Math.max(0, Math.round((Date.now() - new Date(best.lastSeenAt ?? 0).getTime()) / 1000));
      st.pendingReason = `ready — ${best.name} claims it on its next poll (~15s; last polled ${secs}s ago)`;
    }
  }

  // Case-level credential readiness (runs regardless of hold state, unlike the per-step block above):
  // which required secrets aren't set up for this client. Surfaced as a banner so an auto-imported
  // case for an un-onboarded client is obviously blocked on creds.
  {
    // reuses the hoisted `byName` (client secret refs) fetched once above
    const missMap = new Map<string, Set<string>>();
    for (const job of c.jobs) {
      if (job.mode !== "api") continue;
      const needed = ((job.request ?? {}) as { secretNames?: string[] }).secretNames ?? [];
      for (const m of missingRequiredSecrets(needed, c.secretOverrides, byName, parentByName)) {
        if (!missMap.has(m)) missMap.set(m, new Set());
        missMap.get(m)!.add(job.systemKey);
      }
    }
    report.credsMissing = [...missMap.entries()].map(([secretName, systems]) => ({ secretName, systems: [...systems] }));
  }
  return report;
}
