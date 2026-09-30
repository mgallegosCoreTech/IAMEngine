// Runner coordination: enrollment, heartbeat, atomic claim, credential broker, result +
// case advance. Factory-style over PrismaClient, mirroring lib/clients/repository.ts.
// Pure decisions live in runner-logic.ts; this layer is the I/O around them.
import type { AgentScope, CaseStatus, JobStatus, Mode, PrismaClient } from "@prisma/client";
import { Prisma } from "@prisma/client";
import { deriveCaseStatus, isClaimable, shouldStandBy, setupGateBlocks, maintenanceBlocks, LICENSE_DEPENDENT_SYSTEMS, type JobLite, type SetupGatePolicy } from "./runner-logic";
import { getAppSetting, setAppSetting } from "../settings";
import { MAINTENANCE_KEY, normalizeMaintenance, maintenanceScope, type MaintenanceState } from "./maintenance";
import { CONCURRENCY_KEY, resolveCaps, admitUnderCaps, governorActive, groupKey, type ConcurrencySetting, type Inflight } from "./concurrency";

// AppSetting key for the setup-state dispatch gate ({ enforceTested: boolean }, default off).
export const SETUP_GATE_KEY = "setup_gate";
import { isConvertConfirmed, isConvertStillComing } from "./mailbox-convert";
import { jobResultEnvelope } from "./job-result";
import { teamsPhoneNumberOf } from "../teams/phone";

import { cloudObjectFor, type CloudObject } from "./cloud-object";
import { PASSWORD_RESET_SYSTEM_KEYS } from "./password-reset";
import { ADHOC_SYSTEM_KEYS } from "./adhoc";
import { HttpError, type BrokeredCredential, type ResultInput, type RunnerJob } from "./types";
import { resolveSecretFields, delineaConfigFromEnv, delineaConfigured, getDelineaToken, getOneTimePasswordCode } from "../secrets/delinea";
import { checkFieldShape } from "../secrets/field-requirements";
import { classifyDelineaError, credFailure, type CredFailure } from "./cred-failure";
import { testableSystems, isNotNeededForTest, type RightsRow } from "./conn-test-logic";
import { wiredOptionalSecrets } from "../secrets/auxiliary";
import { diffConnOutcome, sweepConnTests } from "./conn-sweep";
import { sweepDbBackup } from "./db-backup";
import { sweepRestoreDrill } from "./restore-drill";
import { sweepFleetAlerts } from "./fleet-alerts";
import { AGENT_MIGRATION_KEY, migrateDecision, type AgentMigrationSetting } from "./agent-migration";
import { generateAgentToken } from "../runner/agent-token";
import { effectiveExternalId, missingRequiredSecrets, allSecretsNotNeeded, ALWAYS_ON_PREM_SYSTEMS, systemIsOnPrem } from "../cases/case-secrets";
import { parseCapabilities, onPremExclusions, browserExclusions, BROWSER_SYSTEMS } from "../runner/capabilities";
import { connectorNeedsBrowser } from "../connectors/definition";
import { purgeCutoff } from "./agent-trash";
import { generateInitialPassword } from "../auth/password";
import { sweepProcurementWatches } from "./procurement-watch";
import { sweepServiceNowIntake } from "./intake-sweep";
import { sweepServiceNowAssignees } from "./assignee-sweep";
import { postWorkNote, writeBackEnabled } from "../servicenow/worknote";
import { snConfigFromEnv } from "../servicenow/gateway";
import { jobOutcome } from "../cases/run-report";
import { mailboxPurgeLines } from "../cases/decision-markers";
import { fireNotification } from "../notifications/sender";
import { parseClientOverride } from "../notifications/types";
import { outcomeFingerprint } from "../runs/outcomes-repo";
import { runnerBuildId } from "../runner/bundle";
import { agentBuildIsCurrent, autoUpdateDecision, AGENT_AUTO_UPDATE_KEY } from "./agent-updates";
import { decideAutoRetry, type AutoRetryMarker } from "./auto-retry";
import { applyAdStandaloneUpn } from "./ad-standalone-upn";
import { resolveActor, type ActorInput } from "../auth/actor";
import { planTokenRefresh, planTokenConfirm } from "./agent-token-refresh";

type JobRequest = { config?: unknown; requiresApproval?: boolean; captureEvidence?: boolean; secretNames?: string[]; approved?: boolean; dryRun?: boolean; validateOnly?: boolean };

const req = (j: { request: unknown }): JobRequest => (j.request ?? {}) as JobRequest;

// Agent.updateRequestedBy/restartRequestedBy are rendered verbatim on the Agents page ("by <x>"), so
// they keep the bare email the column has always held — the "user:" label form belongs to AuditLog.
const displayActor = (actor: string) => actor.replace(/^user:/, "");

// The offboard-target shortlist an executor returns when it cannot tell WHICH person to offboard —
// result.Candidates (PowerShell) / result.candidates. See recordResult: a result carrying these is a
// DECISION, never a success. Shape mirrors the runner's: { id, upn, displayName, ... }.
export type OffboardCandidate = {
  id: string; upn: string; displayName: string; jobTitle?: string; department?: string;
  enabled?: boolean; mail?: string; samAccountName?: string; source?: string;
};

export function offboardCandidatesOf(result: unknown): OffboardCandidate[] {
  if (!result || typeof result !== "object") return [];
  const r = result as Record<string, unknown>;
  const raw = r.Candidates ?? r.candidates;
  if (!Array.isArray(raw)) return [];
  return raw
    .map((c) => (c ?? {}) as Record<string, unknown>)
    // A candidate with no identifier is unusable — the operator could pick it and we'd still not know who they meant.
    .filter((c) => typeof c.upn === "string" && c.upn.length > 0)
    .map((c) => ({
      id: String(c.id ?? c.upn),
      upn: String(c.upn),
      displayName: String(c.displayName ?? c.upn),
      jobTitle: c.jobTitle ? String(c.jobTitle) : undefined,
      department: c.department ? String(c.department) : undefined,
      enabled: typeof c.enabled === "boolean" ? c.enabled : undefined,
      mail: c.mail ? String(c.mail) : undefined,
      samAccountName: c.samAccountName ? String(c.samAccountName) : undefined,
      source: c.source ? String(c.source) : undefined,
    }));
}

// The name we searched for (what ServiceNow gave us) — shown to the operator so they can see WHY we
// couldn't resolve it ("we looked for 'Parth Shah'; the directory has 'Parth K. Shah'").
export function offboardCandidateQuery(result: unknown): string | null {
  if (!result || typeof result !== "object") return null;
  const r = result as Record<string, unknown>;
  const q = r.CandidateQuery ?? r.candidateQuery;
  return typeof q === "string" && q ? q : null;
}

// Same marker convention as the username-collision decision, so the UI can key off the error text.
function offboardDecisionError(result: unknown, count: number): string {
  const r = (result ?? {}) as Record<string, unknown>;
  const reason = String(r.CandidateReason ?? r.candidateReason ?? "ambiguous");
  const query = offboardCandidateQuery(result) ?? "the name on the ticket";
  const why = reason === "no-match"
    ? `no exact match for "${query}"`
    : `${count} users match "${query}"`;
  return `DECISION_NEEDED:offboard_target | ${why} — pick the user to offboard, then the case re-runs from the start. Nothing was changed.`;
}

// One shape for every ConnectionTest row, whichever path enqueued it — otherwise the fleet sweep and
// the per-client button disagree about what a system needs, and a probe reports "no portal secret
// wired" for a client that has one. REQUIRED secrets come from the system; OPTIONAL ones are attached
// only when the client has actually wired them and are brokered best-effort by the runner.
function connTestRow(
  clientId: string,
  s: { systemKey: string; secretNames: string[]; config: unknown; onPrem: boolean },
  clientSecrets: { name: string; externalId: string | null }[],
  source: "manual" | "sweep" | "google-setup",
  deep: boolean
) {
  return {
    clientId,
    systemKey: s.systemKey,
    secretNames: s.secretNames,
    optionalSecretNames: wiredOptionalSecrets(s.systemKey, clientSecrets).filter((n) => !s.secretNames.includes(n)),
    config: (s.config ?? undefined) as Prisma.InputJsonValue | undefined,
    onPrem: s.onPrem,
    source,
    deep,
  };
}

// Claim ordering. singleRun FIRST: "Run this step only" is a human sitting and watching, and a
// runner does not poll again until its current batch drains (Start-IamRunner: it only sleeps when a
// cycle claimed nothing). Behind arbitrary background work that meant a median 11-MINUTE wait before
// the step even started — 23 minutes on the case that reported it — so the case paused and looked
// dead (FR #0000101). Operator-initiated work jumps the queue; the rest keeps its stable
// case-then-sequence order so a case's steps still run in order.
export const CLAIM_ORDER: Prisma.JobOrderByWithRelationInput[] = [{ singleRun: "desc" }, { caseRequestId: "asc" }, { sequence: "asc" }];

// What to write for the browser sidecar on this heartbeat. Reporting 'browser' clears any recorded
// error unconditionally — the capability is the agent saying the sidecar works now, which outranks a
// reason it did not five minutes ago. Otherwise record whatever reason the agent sent, and say
// nothing when it sent none (an install still running reports neither, and must not be mistaken for
// one that failed).
export function browserInstallPatch(
  capabilities: string[] | null | undefined,
  browserInstallError: string | null | undefined,
): { browserInstallError?: string | null } {
  if (capabilities?.includes("browser")) return { browserInstallError: null };
  if (browserInstallError != null) return { browserInstallError: browserInstallError.slice(0, 2000) };
  return {};
}

// What to write for the EXO pin on this heartbeat. Mirrors browserInstallPatch exactly, with the
// runner's explicit exoPinOk playing the role the 'browser' capability plays there: the pin has no
// capability of its own, and an absent error cannot mean "healthy" because a pre-1.122 runner sends
// neither field. So healthy is stated, not inferred.
export function exoPinPatch(
  exoPinOk: boolean | null | undefined,
  exoPinError: string | null | undefined,
): { exoPinError?: string | null } {
  if (exoPinOk) return { exoPinError: null };
  if (exoPinError != null) return { exoPinError: exoPinError.slice(0, 2000) };
  return {};
}

// A claimed job whose runner never posts a result is reclaimed after this long (crash/stall).
const LEASE_MS = 10 * 60 * 1000;
// A "running" job whose progress hasn't moved in this long has wedged (the worker died / a step hung
// past the runner's 10-min watchdog). Generous so a genuinely-slow-but-narrating step never trips it.
const PROGRESS_STALE_MS = 20 * 60 * 1000;
const MAX_PROGRESS_RECLAIMS = 1; // re-queue a wedged job once; if it wedges again, FAIL it (don't loop)

// Feature #4 (concurrency governor): a stable, single fleet-wide advisory-lock key. "0004" = feature
// #4 — never reuse this bigint for another lock. `pg_advisory_xact_lock` serializes the count→admit→
// assign critical section across every claim() (all runners, all app instances — the lock lives in
// Postgres), auto-releasing on commit OR rollback so a thrown error can't strand it. Keep the section
// TIGHT: it serializes ALL claims fleet-wide, and the runner pool (#1) depends on it staying short.
const ADMISSION_LOCK_KEY = 0x1a3c0004n;

// Live in-flight counts for the concurrency caps, read UNDER the advisory lock. Job has no clientId
// column, so join through CaseRequest→Client and COALESCE the parent (D7: a child account shares its
// parent's Graph/EXO tenant, so caps + rule (d) key on the parent tenant). One grouped scan yields
// the global, per-tenant, and per-(tenant, systemKey) views at once. Counts ALL dispatched/running
// work — including ad-hoc/singleRun jobs — because they occupy the same shared session a normal job
// would collide with; the cap-exemption for those jobs is applied in admitUnderCaps, not here.
async function countInflight(tx: Prisma.TransactionClient): Promise<Inflight> {
  const rows = await tx.$queryRaw<{ tenantId: string; systemKey: string; n: number | bigint }[]>`
    SELECT COALESCE(cl."parentId", cl.id) AS "tenantId", j."systemKey" AS "systemKey", COUNT(*)::int AS n
    FROM "Job" j
    JOIN "CaseRequest" c ON c.id = j."caseRequestId"
    JOIN "Client" cl ON cl.id = c."clientId"
    WHERE j.status IN ('dispatched','running')
    GROUP BY COALESCE(cl."parentId", cl.id), j."systemKey"
  `;
  let global = 0;
  const byTenant: Record<string, number> = {};
  const byTenantSystem: Record<string, number> = {};
  for (const r of rows) {
    const n = Number(r.n);
    global += n;
    byTenant[r.tenantId] = (byTenant[r.tenantId] ?? 0) + n;
    byTenantSystem[groupKey(r.tenantId, r.systemKey)] = n;
  }
  return { global, byTenant, byTenantSystem };
}

// systemKeys on this case whose FAILED run the operator ACCEPTED ("ignore warning — mark complete",
// which resolves the run-log outcome). The claim gate builds the same set inline for the dependency
// gate; the run report reads it to render the step verified.
export async function acceptedKeysFor(db: PrismaClient, caseRequestId: string): Promise<Set<string>> {
  const rows = await db.runOutcome.findMany({
    where: { caseRequestId, status: "failed", resolvedAt: { not: null } },
    select: { systemKey: true },
  });
  return new Set(rows.map((r) => r.systemKey));
}

type CaseJobRow = { id: string; systemKey: string; sequence: number; mode: Mode; status: JobStatus; singleRun: boolean; request: Prisma.JsonValue; validation: Prisma.JsonValue };

// The ONE place a case's badge is derived from the database — so no caller can forget the
// accepted-failure overlay and pin a case at "failed" whose every step reads green on the case page.
// (singleRun jobs are NOT excluded here: three parallel deriveCaseStatus call sites don't exclude
// them either, and an exclusion made a failed case read "completed" while its only failed step's
// single-step re-run was pending. The narrow pinning edge that motivated an exclusion — a pending
// singleRun job holding a case at "running" after its real failures were accepted — is accepted as
// the lesser problem and documented in the PR.)
async function caseStatusFrom(db: PrismaClient, caseRequestId: string): Promise<{ caseJobs: CaseJobRow[]; caseStatus: CaseStatus }> {
  const caseJobs = await db.job.findMany({ where: { caseRequestId }, select: { id: true, systemKey: true, sequence: true, mode: true, status: true, singleRun: true, request: true, validation: true } });
  const accepted = await acceptedKeysFor(db, caseRequestId);
  const caseStatus = deriveCaseStatus(
    caseJobs.map((j) => ({
      id: j.id, systemKey: j.systemKey, sequence: j.sequence, mode: j.mode, status: j.status,
      requiresApproval: Boolean(req(j).requiresApproval), approved: Boolean(req(j).approved),
      accepted: j.status === "failed" && accepted.has(j.systemKey),
    }))
  );
  return { caseJobs, caseStatus };
}

// CASE-FAILURE SWEEP — the case just derived "failed"; quiesce its remaining PENDING work.
//   - ordinary case steps -> "skipped": their gate sits behind the failure (a re-plan or re-run
//     revives them; see the run report's Re-run).
//   - queued verify jobs (request.validateOnly) -> ROLLED BACK to the priorStatus/priorError that
//     verifyCase stamped when it reset them. Skipping them rewrote real successes into "never
//     done"; leaving them pending kept a "failed" case executing (Stop didn't quiesce, one blip
//     produced N duplicate caseFailed alerts). A pre-stamp legacy verify job falls back to
//     "skipped" — never to an invented success.
//   - ad-hoc actions and "run this step only" resets -> untouched (operator side-actions, not case
//     work; an unrelated case failure must not cancel them behind the operator's back).
// Works off the caller's job snapshot with write-time guards (status must still be pending); a job
// that flips to pending mid-derive is caught by the next failed re-derivation, which re-runs this.
async function sweepPendingCaseWork(db: PrismaClient, caseRequestId: string, caseJobs: CaseJobRow[]): Promise<void> {
  const restored: string[] = [];
  for (const j of caseJobs) {
    if (j.status !== "pending" || req(j).validateOnly !== true) continue;
    const r = { ...((j.request ?? {}) as Record<string, unknown>) };
    const prior = typeof r.priorStatus === "string" ? r.priorStatus : null;
    const priorError = typeof r.priorError === "string" ? r.priorError : null;
    const priorValidation = r.priorValidation; // stashed at reset so a warning verdict survives the round trip
    delete r.validateOnly; delete r.priorStatus; delete r.priorError; delete r.priorValidation;
    const status = (prior === "succeeded" || prior === "failed" ? prior : "skipped") as JobStatus;
    const u = await db.job.updateMany({
      // Two write-time guards: still pending (claimed since the snapshot -> leave it to the runner)
      // AND still a verify job — requeueJob can convert a queued verify into a full re-run (the
      // mailbox-decision answer) without changing status, and rolling THAT back would silently
      // discard the operator's answer with a stale request.
      where: { id: j.id, status: "pending", request: { path: ["validateOnly"], equals: true } },
      data: {
        status,
        error: status === "failed" ? priorError : null,
        validation: priorValidation === undefined || priorValidation === null ? Prisma.DbNull : (priorValidation as Prisma.InputJsonValue),
        assignedAgentId: null,
        request: r as Prisma.InputJsonValue,
      },
    });
    if (u.count) restored.push(j.systemKey);
  }
  const toSkip = caseJobs
    .filter((j) => j.status === "pending" && !j.singleRun && !ADHOC_SYSTEM_KEYS.includes(j.systemKey) && req(j).validateOnly !== true)
    .map((j) => j.id);
  const skipped = toSkip.length
    ? await db.job.updateMany({ where: { id: { in: toSkip }, status: "pending", singleRun: false }, data: { status: "skipped" } })
    : { count: 0 };
  // The status flips above are invisible otherwise — say in the audit trail WHICH sweep did this
  // and why (every job status change is supposed to leave a trace).
  if (restored.length || skipped.count) {
    await db.auditLog.create({
      data: {
        actor: "system:case-failed-sweep", action: "job.failure_sweep", caseRequestId,
        detail: { skippedPending: skipped.count, restoredVerify: restored },
      },
    });
  }
}

// Re-derive a case's status from its jobs and persist it; on failure, quiesce the still-pending case
// work (skip ordinary steps, roll queued verify jobs back — see sweepPendingCaseWork). Shared by the
// wedged-job reclaim, the operator Stop, and accepting/un-accepting a failure, so they all advance
// the case exactly like a real job result does.
export async function refreshCaseStatus(db: PrismaClient, caseRequestId: string) {
  const { caseJobs, caseStatus } = await caseStatusFrom(db, caseRequestId);
  if (caseStatus === "failed") await sweepPendingCaseWork(db, caseRequestId, caseJobs);
  await db.caseRequest.update({ where: { id: caseRequestId }, data: { status: caseStatus } });
  return caseStatus;
}


// An agent disabled mid-flight must not keep brokering credentials or posting results.
async function assertAgentEnabled(db: PrismaClient, agentId: string): Promise<void> {
  const agent = await db.agent.findUnique({ where: { id: agentId }, select: { enabled: true } });
  if (!agent) throw new HttpError(404, "unknown agent");
  if (!agent.enabled) throw new HttpError(403, "agent disabled");
}

// App-side connection-test preflight (the "Fields" stage): resolve each queued row's secrets from
// Delinea and shape-check the FIELD NAMES against the provider requirements, persisting the verdict
// on the just-created rows. Secret values never leave this function — details carry names and
// missing-requirement labels only. Best-effort by design: callers swallow errors so the runner's
// access/API stages always still run.
async function preflightConnTestFields(
  db: PrismaClient,
  clientId: string,
  primaryDomain: string | null,
  specs: { systemKey: string; secretNames: string[] }[]
): Promise<void> {
  const cfg = delineaConfigFromEnv();
  if (!delineaConfigured(cfg)) {
    await db.connectionTest.updateMany({
      where: { clientId, systemKey: { in: specs.map((s) => s.systemKey) }, status: "pending" },
      data: { fieldsDetail: "Delinea not configured on the app — set DELINEA_* to enable the field preflight" },
    });
    return;
  }
  const names = [...new Set(specs.flatMap((s) => s.secretNames))];
  const secrets = await db.secret.findMany({ where: { clientId, name: { in: names } }, select: { name: true, externalId: true } });
  const byName = new Map(secrets.map((s) => [s.name, s.externalId] as const));
  const hasTenantHint = Boolean(primaryDomain && primaryDomain.trim());
  // One token for the whole batch — not one password-grant per secret.
  let token: string | undefined;
  let tokenError: string | null = null;
  try {
    token = await getDelineaToken(cfg);
  } catch (e) {
    tokenError = e instanceof Error ? e.message : "token grant failed";
  }
  // Resolve each distinct secret once, then stamp the verdict per system.
  const checks = new Map<string, { ok: boolean; note: string }>();
  for (const name of names) {
    if (tokenError) { checks.set(name, { ok: false, note: `${name}: Delinea unreachable (${tokenError})` }); continue; }
    const { externalId, source } = effectiveExternalId(name, null, byName.get(name) ?? null);
    if (source === "not_needed") { checks.set(name, { ok: true, note: `${name}: not needed` }); continue; }
    if (!externalId) { checks.set(name, { ok: false, note: `${name}: no reference set` }); continue; }
    const resolved = await resolveSecretFields(cfg, externalId, undefined, token);
    if (!resolved.ok) { checks.set(name, { ok: false, note: `${name}: ${resolved.error ?? "not resolvable"}` }); continue; }
    // Opportunistic expiry capture — never fails the preflight.
    if (resolved.expiresAt) {
      const at = new Date(resolved.expiresAt);
      if (!Number.isNaN(at.getTime())) await db.secret.updateMany({ where: { clientId, name }, data: { expiresAt: at, expiryCheckedAt: new Date() } }).catch(() => {});
    }
    const shape = checkFieldShape(name, Object.keys(resolved.fields ?? {}), { clientHasTenantHint: hasTenantHint });
    checks.set(
      name,
      shape.missing.length === 0
        ? { ok: true, note: `${name}: fields ok` }
        : { ok: false, note: `${name}: missing ${shape.missing.join(", ")}` }
    );
  }
  for (const spec of specs) {
    const rows = spec.secretNames.map((n) => checks.get(n)).filter((r): r is { ok: boolean; note: string } => Boolean(r));
    if (rows.length === 0) continue;
    await db.connectionTest.updateMany({
      where: { clientId, systemKey: spec.systemKey, status: "pending" },
      data: { fieldsOk: rows.every((r) => r.ok), fieldsDetail: rows.map((r) => r.note).join("; ").slice(0, 500) || null },
    });
  }
}

// Shared guard for the central-runner discovery RESULT endpoints (cloud groups + shared mailboxes):
// only the central (cloud) runner may write these, and never a client-network agent — that would be a
// cross-client write into another client's picker. Returns the client id. `what` names the resource in
// the error. Keep both callers on this one guard so the cross-client rule can't drift between them.
async function assertCentralAgentForClient(db: PrismaClient, agentId: string, clientSlug: string, what: string): Promise<string> {
  const agent = await db.agent.findUnique({ where: { id: agentId }, select: { enabled: true, clientId: true } });
  if (!agent || !agent.enabled) throw new HttpError(403, "unknown or disabled agent");
  if (agent.clientId) throw new HttpError(403, `only the central runner reports ${what}`);
  const client = await db.client.findUnique({ where: { slug: clientSlug }, select: { id: true } });
  if (!client) throw new HttpError(404, `unknown client ${clientSlug}`);
  return client.id;
}

export function makeRunnerService(db: PrismaClient) {
  return {
    async enroll(input: { name: string; scope: AgentScope; clientSlug?: string | null }): Promise<{ id: string; scope: AgentScope; clientId: string | null; agentToken?: string }> {
      let clientId: string | null = null;
      const slug = input.clientSlug?.trim() || null; // tolerate a stray space in a token's client
      if (slug) {
        const c = await db.client.findUnique({ where: { slug }, select: { id: true } });
        if (!c) throw new HttpError(404, `unknown client ${slug}`);
        clientId = c.id;
      }
      if (input.scope === "client_network" && !clientId) {
        throw new HttpError(422, "a client_network agent must be bound to a client");
      }
      // Only mint a per-agent token once the edge is actually configured to admit agt_ bearers
      // (RUNNER_PER_AGENT_EDGE_ENABLED) or we've reached the RUNNER_REQUIRE_PER_AGENT cutover — see
      // edge-runner-auth.ts. Minting before then would hand the runner a token the edge rejects,
      // locking it out with no fallback (the shared token is dropped on adopt). Until the flag is on,
      // a freshly enrolled agent has no token fields at all and simply uses the shared token like
      // every other pre-migration agent.
      const edgeReady = process.env.RUNNER_PER_AGENT_EDGE_ENABLED === "true" || process.env.RUNNER_REQUIRE_PER_AGENT === "true";
      const now = new Date();
      if (edgeReady) {
        // A freshly enrolled agent mints its own per-agent token and starts confirmed on it —
        // it never falls back to the shared token (unlike a pre-existing agent mid-migration).
        const { token, prefix, hash } = generateAgentToken();
        const agent = await db.agent.create({
          data: { name: input.name, scope: input.scope, clientId, lastSeenAt: now, tokenHash: hash, tokenPrefix: prefix, tokenProvisionedAt: now, tokenConfirmedAt: now },
          select: { id: true, scope: true, clientId: true },
        });
        await db.auditLog.create({ data: { actor: "system", action: "agent.enroll", clientId, detail: { agentId: agent.id, scope: agent.scope } } });
        return { ...agent, agentToken: token };
      }
      const agent = await db.agent.create({
        data: { name: input.name, scope: input.scope, clientId, lastSeenAt: now },
        select: { id: true, scope: true, clientId: true },
      });
      await db.auditLog.create({ data: { actor: "system", action: "agent.enroll", clientId, detail: { agentId: agent.id, scope: agent.scope } } });
      return { ...agent };
    },

    // Operator action: enable/disable an agent (a disabled agent can't claim/broker/post).
    async setEnabled(agentId: string, enabled: boolean, actor: ActorInput = "ui"): Promise<{ id: string; enabled: boolean }> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      await db.agent.update({ where: { id: agentId }, data: { enabled } });
      const who = resolveActor(actor);
      await db.auditLog.create({ data: { actor: who.actor, userId: who.userId, action: enabled ? "agent.enable" : "agent.disable", detail: { agentId } } });
      return { id: agentId, enabled };
    },

    // Move a DISABLED agent to the trash (soft delete; restorable for TRASH_RETENTION_DAYS).
    async trashAgent(agentId: string, actor: ActorInput = "ui"): Promise<{ id: string }> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true, enabled: true, deletedAt: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      if (agent.enabled) throw new HttpError(409, "disable the runner before moving it to the trash");
      if (agent.deletedAt) return { id: agentId }; // already trashed (idempotent)
      await db.agent.update({ where: { id: agentId }, data: { deletedAt: new Date() } });
      const who = resolveActor(actor);
      await db.auditLog.create({ data: { actor: who.actor, userId: who.userId, action: "agent.trash", detail: { agentId } } });
      return { id: agentId };
    },

    // Restore a trashed agent — it comes back DISABLED (re-enable explicitly before use).
    async restoreAgent(agentId: string, actor: ActorInput = "ui"): Promise<{ id: string }> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      await db.agent.update({ where: { id: agentId }, data: { deletedAt: null, enabled: false } });
      const who = resolveActor(actor);
      await db.auditLog.create({ data: { actor: who.actor, userId: who.userId, action: "agent.restore", detail: { agentId } } });
      return { id: agentId };
    },

    // Permanently delete an agent (jobs keep their history; assignedAgentId is set null).
    async deleteAgentForever(agentId: string, actor: ActorInput = "ui"): Promise<{ id: string }> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      const who = resolveActor(actor);
      await db.auditLog.create({ data: { actor: who.actor, userId: who.userId, action: "agent.delete", detail: { agentId } } });
      await db.agent.delete({ where: { id: agentId } });
      return { id: agentId };
    },

    // Hard-delete trashed agents past the retention window. Returns how many were purged.
    async purgeExpiredTrash(now: Date = new Date()): Promise<number> {
      const res = await db.agent.deleteMany({ where: { deletedAt: { not: null, lte: purgeCutoff(now) } } });
      if (res.count) await db.auditLog.create({ data: { actor: "system", action: "agent.purge", detail: { count: res.count } } });
      return res.count;
    },

    async heartbeat(agentId: string, version?: string | null, semver?: string | null, startedAt?: string | null, capabilities?: string[] | null, appUrl?: string | null, migrateError?: string | null, browserInstallError?: string | null, exoPinOk?: boolean | null, exoPinError?: string | null, authVia?: "per-agent" | "shared" | null): Promise<{ ok: true; enabled: boolean; update: boolean; restart: boolean; discover: boolean; installBrowser: boolean; migrate: { appUrl: string } | null; drain: boolean; governorActive: boolean; provisionToken?: string }> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true, version: true, semver: true, enabled: true, updateRequested: true, updateDeliveredAt: true, updateAttempts: true, updateStalledAt: true, updateStalledBuild: true, restartRequested: true, browserInstallRequested: true, migrateRequested: true, currentAppUrl: true, clientId: true, tokenRefreshRequested: true, tokenConfirmedAt: true, client: { select: { adDiscoverRequestedAt: true } } } });
      if (!agent) throw new HttpError(404, "unknown agent");
      // Tell an ENABLED agent to self-update at most once. Consume the flag with an ATOMIC
      // conditional flip (updateMany guarded by updateRequested:true) so two overlapping heartbeats
      // can't both win (double restart) and a requestUpdate() landing mid-beat isn't clobbered —
      // exactly one heartbeat flips true->false and gets update=true. A DISABLED agent keeps its
      // pending update until re-enabled (the runner ignores update when disabled, so consuming it
      // here would silently drop it).
      let update = false;
      if (agent.enabled && agent.updateRequested) {
        // Stamp updateDeliveredAt on consume → the UI shows "updating…" until the agent restarts and
        // its next heartbeat pushes lastSeenAt past this timestamp ("updated ✓").
        const consumed = await db.agent.updateMany({ where: { id: agentId, updateRequested: true }, data: { updateRequested: false, updateDeliveredAt: new Date() } });
        update = consumed.count > 0;
      }
      // Auto-update stale agents (default ON): if this agent is enabled, not already updating, and the
      // build it just reported differs from the build the app now serves, tell it to self-update. This
      // is what makes a server restart (new bundle) roll the fleet forward on its own — no per-agent
      // click. A short cooldown via updateDeliveredAt keeps it from re-issuing every ~5s heartbeat
      // while the agent is mid-pull; a failed update naturally retries after the cooldown.
      if (agent.enabled) {
        const reported = version ?? agent.version;
        const build = runnerBuildId();
        if (agentBuildIsCurrent(reported, build)) {
          // CONVERGED. Whatever it took to get here, the agent is on the served build, so clear the
          // guard: the next time it falls behind it gets a full set of attempts again. Cheap guard so
          // the common case (an up-to-date agent, every heartbeat, every agent) writes nothing.
          if (agent.updateAttempts > 0 || agent.updateStalledAt) {
            await db.agent.update({ where: { id: agentId }, data: { updateAttempts: 0, updateStalledAt: null, updateStalledBuild: null } }).catch(() => {});
          }
        } else if (!update) {
          const cooldownOver = !agent.updateDeliveredAt || Date.now() - agent.updateDeliveredAt.getTime() > 90_000;
          if (cooldownOver) {
            const autoUpdate = (await getAppSetting<{ enabled?: boolean }>(db, AGENT_AUTO_UPDATE_KEY))?.enabled !== false; // default on
            if (autoUpdate) {
              // STALE and eligible. Everything above is unchanged; what is new is that we count the
              // attempt and stop after AGENT_UPDATE_MAX_ATTEMPTS. The agent reporting a build that is
              // still not the served one, cooldown expired, is the definition of an attempt that did
              // not take — there is no other signal, because self-update is fire-and-forget.
              const d = autoUpdateDecision({ attempts: agent.updateAttempts, stalledBuild: agent.updateStalledBuild, build });
              if (d.action === "update") {
                update = true;
                await db.agent.update({ where: { id: agentId }, data: { updateDeliveredAt: new Date(), updateRequestedBy: "system:auto-update", updateRequestedAt: new Date(), updateAttempts: d.attempts, ...(d.reset ? { updateStalledAt: null, updateStalledBuild: null } : {}) } }).catch(() => {});
              } else if (!agent.updateStalledAt || agent.updateStalledBuild !== build) {
                // Give up on this build and say so ONCE. Not issuing the update is the point: the
                // agent stays up on the build it has instead of being exited every 90 seconds by a
                // pull that never lands. An operator's explicit Update click clears this and retries.
                await db.agent.update({ where: { id: agentId }, data: { updateStalledAt: new Date(), updateStalledBuild: build } }).catch(() => {});
              }
            }
          }
        }
      }
      // Same atomic-consume for a plain RESTART request (no file pull). An update already restarts, so
      // if both are pending the update wins and this just clears the redundant flag.
      let restart = false;
      if (agent.enabled && agent.restartRequested) {
        const consumed = await db.agent.updateMany({ where: { id: agentId, restartRequested: true }, data: { restartRequested: false, restartDeliveredAt: new Date() } });
        restart = consumed.count > 0;
      }
      // Same atomic-consume for a browser-automation INSTALL request. The runner does the work in the
      // background (portable Node bootstrap if the host has none, then Playwright + Chromium) and
      // starts advertising 'browser' in capabilities on a later heartbeat — that, not this delivery,
      // is the "it worked" signal the UI keys off.
      let installBrowser = false;
      if (agent.enabled && agent.browserInstallRequested) {
        const consumed = await db.agent.updateMany({ where: { id: agentId, browserInstallRequested: true }, data: { browserInstallRequested: false, browserInstallDeliveredAt: new Date() } });
        installBrowser = consumed.count > 0;
      }
      // Tell this (client-network) agent to run AD discovery if its client has a pending request.
      // Consume atomically so just one of the client's agents runs it (discovery is read-only, so a
      // double-run would only be wasteful, not wrong).
      let discover = false;
      if (agent.enabled && agent.clientId && agent.client?.adDiscoverRequestedAt) {
        const consumed = await db.client.updateMany({ where: { id: agent.clientId, adDiscoverRequestedAt: { not: null } }, data: { adDiscoverRequestedAt: null } });
        discover = consumed.count > 0;
      }
      // App-URL migration: decide from the global target (AppSetting) + this agent's canary flag, using
      // the URL the agent reports THIS heartbeat (falling back to its last-known). Only emit when the
      // agent isn't already on the target — that's how it stops (convergence). The runner verifies the
      // new URL, rewrites its own supervisor entry, and switches; we just tell it where to go.
      const migrateSetting = await getAppSetting<AgentMigrationSetting>(db, AGENT_MIGRATION_KEY);
      const reportedUrl = appUrl ?? agent.currentAppUrl ?? null;
      const decision = migrateDecision({ setting: migrateSetting, agentMigrateRequested: agent.enabled && agent.migrateRequested, reportedUrl });
      let migrate: { appUrl: string } | null = null;
      if (decision.migrate && decision.targetUrl) {
        // Clear the one-shot canary flag on delivery (a fleet-enabled migration keeps re-emitting until
        // the agent converges); stamp delivery so the UI can show "migrating…".
        await db.agent.updateMany({ where: { id: agentId }, data: { migrateDeliveredAt: new Date(), ...(agent.migrateRequested ? { migrateRequested: false } : {}) } });
        migrate = { appUrl: decision.targetUrl };
      }
      // bootAt = the runner's reported process start (for the uptime display). Parse defensively; only
      // set it when a valid value is sent (older runners don't report it — keep whatever's stored).
      const boot = startedAt ? new Date(startedAt) : null;
      const bootAt = boot && !Number.isNaN(boot.getTime()) ? boot : undefined;
      // Persist reported on-prem capabilities only when the runner sent them (1.31+). A legacy runner
      // passes null → keep whatever's stored (stays null → treated as capable). An empty array IS a
      // report ("can run no on-prem system") and is persisted as [].
      await db.agent.update({ where: { id: agentId }, data: { lastSeenAt: new Date(), version: version ?? agent.version, semver: semver ?? agent.semver, ...(bootAt ? { bootAt } : {}), ...(capabilities != null ? { capabilities: capabilities as Prisma.InputJsonValue } : {}), ...(appUrl ? { currentAppUrl: appUrl } : {}), ...(decision.converged ? { migratedAt: new Date(), migrateError: null, migrateRequested: false } : migrateError != null ? { migrateError } : {}), ...browserInstallPatch(capabilities, browserInstallError), ...exoPinPatch(exoPinOk, exoPinError) } });
      // A failed PROOF migration (the "prove it on one agent first" canary) clears the pending proof
      // right here, server-side — otherwise every admin's Agents page would keep waiting to offer
      // "move all the others" on a canary that already gave its answer. The row still shows the
      // ⚠ failed status from migrateError; only the pointer is retired.
      if (migrateError != null && !decision.converged && migrateSetting?.proofAgentId === agentId) {
        await setAppSetting(db, AGENT_MIGRATION_KEY, { ...migrateSetting, proofAgentId: null });
        await db.auditLog.create({ data: { actor: "system:agent", action: "agent.migration.proof_failed", detail: { agentId, error: migrateError, targetUrl: migrateSetting.targetUrl ?? null } } });
      }
      // Heartbeats double as the app's pulse: piggyback the procurement-case sweep (PC resolved ->
      // re-queue the blocked job). Fire-and-forget — a SN hiccup must never fail a heartbeat. The
      // sweep self-throttles to ~1/min and checks each watch every ~5 min.
      void sweepProcurementWatches(db).catch(() => {});
      // Same pulse: auto-import new ServiceNow intake tickets (off unless enabled; self-throttles to ~15 min).
      void sweepServiceNowIntake(db).catch(() => {});
      // Same pulse: mirror each open case's ServiceNow assignee for the Cases list (self-throttles to ~5 min).
      void sweepServiceNowAssignees(db).catch(() => {});
      // Same pulse: the scheduled credential-health sweep + expiry alerts (off unless enabled;
      // durable AppSetting throttle, one client batch per tick). Reuses the operator enqueue path.
      const svc = this;
      void sweepConnTests(db, { enqueueClient: (slug, source) => svc.requestConnectionTests(slug, undefined, source) }).catch(() => {});
      // Same pulse: the nightly pg_dump database backup (default ON; durable AppSetting throttle,
      // one run per night after the configured local hour). See lib/jobs/db-backup.ts.
      void sweepDbBackup(db).catch(() => {});
      // Same pulse (feature #5): the WEEKLY restore drill — restore the latest dump into a scratch DB,
      // assert integrity, drop it, alert on failure — plus the ">26h no backup" staleness watch. Self-
      // throttles + claims its own AppSetting; default ON. See lib/jobs/restore-drill.ts.
      void sweepRestoreDrill(db).catch(() => {});
      // Same pulse (feature #3): proactive fleet alerts — agent-offline / queue-backlog / repeated-
      // failures / backup-stale, evaluated at query time and delivered via fireNotification. Self-
      // throttles + claims its own AppSetting (alerts.state); dedupes with a deadline-read cooldown.
      void sweepFleetAlerts(db).catch(() => {});
      // Maintenance drain (feature #7, S2): tell the runner to finish the job in hand and then idle.
      // A PURE READ (no atomic-consume) — drain is a level, not a one-shot edge, so it must keep being
      // reported every beat until an operator clears maintenance. Driven by `global` ONLY: a
      // per-system/per-client pause does NOT idle the whole runner (it keeps working un-paused systems);
      // those scoped pauses are enforced purely by the claim() gate. An older runner ignores this field.
      const maint = normalizeMaintenance(await getAppSetting<Partial<MaintenanceState>>(db, MAINTENANCE_KEY));
      const drain = maint.global === true;
      // S7 governor contract (feature #4 ⇄ #1): tell the runner whether the concurrency governor is
      // ACTIVE. The pool supervisor (Start-IamRunnerPool.ps1) refuses -PoolSize > 1 while this is false
      // — an ungoverned pool lets two members run the same tenant+system concurrently (UM0029840 across
      // processes). Fail-open: an absent/disabled/unparseable setting reads as inactive (single-runner
      // safe). An older runner simply ignores the extra field.
      const governor = governorActive(resolveCaps(await getAppSetting<ConcurrencySetting>(db, CONCURRENCY_KEY)));
      // Per-agent token lifecycle. Deliver an armed refresh once; confirm on a per-agent heartbeat.
      let provisionToken: string | undefined;
      // Gate on agent.enabled — same as update/restart/discover above — so a disabled/trashed agent
      // never gets a freshly minted credential. Gating before planTokenRefresh also avoids minting a
      // token we'd just discard. ALSO gate on edgeReady (RUNNER_PER_AGENT_EDGE_ENABLED or the
      // RUNNER_REQUIRE_PER_AGENT cutover — see edge-runner-auth.ts): the edge must be able to admit
      // agt_ bearers before we ever hand one out, or an adopting runner would lock itself out with no
      // fallback. When not edgeReady we deliberately do NOT consume tokenRefreshRequested (leave it
      // set) so the token is delivered on a later heartbeat once the flag flips on.
      const edgeReady = process.env.RUNNER_PER_AGENT_EDGE_ENABLED === "true" || process.env.RUNNER_REQUIRE_PER_AGENT === "true";
      const refresh = (agent.enabled && edgeReady) ? planTokenRefresh({ tokenRefreshRequested: agent.tokenRefreshRequested }) : null;
      if (refresh) {
        // Atomic consume so overlapping heartbeats can't both mint.
        const consumed = await db.agent.updateMany({ where: { id: agentId, tokenRefreshRequested: true }, data: refresh.update });
        if (consumed.count > 0) provisionToken = refresh.token;
      }
      const confirm = planTokenConfirm({ via: authVia, tokenConfirmedAt: agent.tokenConfirmedAt });
      if (confirm) await db.agent.update({ where: { id: agentId }, data: confirm }).catch(() => {});
      return { ok: true, enabled: agent.enabled, update, restart, discover, installBrowser, migrate, drain, governorActive: governor, provisionToken };
    },

    // Operator action: ask the client's on-prem agent to (re)discover AD OUs + groups. Set the flag;
    // the next client-network heartbeat for that client consumes it and runs discovery.
    async requestAdDiscovery(clientSlug: string, actor: ActorInput = "ui"): Promise<{ clientId: string }> {
      const client = await db.client.findUnique({ where: { slug: clientSlug }, select: { id: true } });
      if (!client) throw new HttpError(404, "unknown client");
      const agent = await db.agent.findFirst({ where: { clientId: client.id, scope: "client_network", enabled: true, deletedAt: null }, select: { id: true } });
      if (!agent) throw new HttpError(409, "no enabled on-prem agent for this client to read its DC");
      const who = resolveActor(actor);
      // Stamp WHO requested it so the runner's later result audit can be attributed to the user.
      await db.client.update({ where: { id: client.id }, data: { adDiscoverRequestedAt: new Date(), adDiscoverRequestedById: who.userId } });
      await db.auditLog.create({ data: { actor: who.actor, userId: who.userId, action: "client.ad_discovery.request", clientId: client.id } });
      return { clientId: client.id };
    },

    // Runner posts the discovered AD objects back; store them on the agent's client for the editor.
    async recordAdObjects(agentId: string, ous: string[], groups: string[]): Promise<{ clientId: string; ous: number; groups: number }> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { clientId: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      if (!agent.clientId) throw new HttpError(422, "only a client-network agent reports AD objects");
      await assertAgentEnabled(db, agentId);
      // Cap count AND per-string length, sort + dedupe — a hostile/spoofed runner can't bloat the row
      // or DoS the editor's substring filter with huge strings (a real DN/group name is well < 512).
      const clean = (xs: unknown): string[] =>
        [...new Set((Array.isArray(xs) ? xs : []).filter((x): x is string => typeof x === "string" && x.length > 0 && x.length <= 512))].sort().slice(0, 5000);
      const adObjects = { ous: clean(ous), groups: clean(groups), discoveredAt: new Date().toISOString() };
      // Attribute the result to the human who requested it (kept the agent id in detail for traceability),
      // so the audit log shows the user, not "agent:<id>".
      const c = await db.client.update({ where: { id: agent.clientId }, data: { adObjects }, select: { adDiscoverRequestedById: true } });
      await db.auditLog.create({ data: { actor: `agent:${agentId}`, userId: c.adDiscoverRequestedById, action: "client.ad_discovery.result", clientId: agent.clientId, detail: { ous: adObjects.ous.length, groups: adObjects.groups.length, agentId } } });
      return { clientId: agent.clientId, ous: adObjects.ous.length, groups: adObjects.groups.length };
    },

    // Operator action: queue a self-update. The next heartbeat returns update:true (see above).
    // actor = the operator who requested it (their email), recorded in the audit log AND stamped on
    // the agent (updateRequestedBy) so the Agents page can show WHO pushed the update. Defaults to
    // "ui" only when no identity is available (auth off).
    async requestUpdate(agentId: string, actor: ActorInput = "ui"): Promise<{ id: string }> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true, enabled: true, deletedAt: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      // The UI hides Update for disabled/trashed agents, but the action is callable — guard here too:
      // a disabled agent won't heartbeat to consume the flag, so the request would just hang pending.
      if (agent.deletedAt) throw new HttpError(409, "agent is in the trash");
      if (!agent.enabled) throw new HttpError(409, "enable the runner before requesting an update");
      const who = resolveActor(actor);
      // Clear the convergence guard: an explicit click is the manual override. If auto-update gave up
      // on this agent, a human asking for it again means try once more — and it starts a fresh count,
      // so a click can never be swallowed by a stall the operator can see on the page but not clear.
      await db.agent.update({ where: { id: agentId }, data: { updateRequested: true, updateRequestedAt: new Date(), updateRequestedBy: displayActor(who.actor), updateDeliveredAt: null, updateAttempts: 0, updateStalledAt: null, updateStalledBuild: null } });
      await db.auditLog.create({ data: { actor: who.actor, userId: who.userId, action: "agent.update_requested", detail: { agentId } } });
      return { id: agentId };
    },

    // Operator action: arm a per-agent token refresh (joint->individual, or rotate). Mirrors
    // requestUpdate — the next heartbeat mints + delivers the token, then clears the flag.
    async requestTokenRefresh(agentId: string, actor: ActorInput = "ui"): Promise<{ id: string }> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true, enabled: true, deletedAt: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      // Mirrors requestUpdate's guard: a disabled/trashed agent won't heartbeat to consume the flag
      // (and now can't mint a token even if it did — see heartbeat's agent.enabled gate above), so
      // reject here rather than leave the request pending indefinitely.
      if (agent.deletedAt) throw new HttpError(409, "agent is in the trash");
      if (!agent.enabled) throw new HttpError(409, "enable the runner before requesting a token refresh");
      const who = resolveActor(actor);
      await db.agent.update({
        where: { id: agentId },
        data: { tokenRefreshRequested: true, tokenRefreshRequestedAt: new Date(), tokenRefreshRequestedBy: displayActor(who.actor), tokenRefreshDeliveredAt: null },
      });
      await db.auditLog.create({ data: { actor: who.actor, userId: who.userId, action: "agent.token_refresh_requested", detail: { agentId } } });
      return { id: agentId };
    },

    // Operator action: ask the runner to RESTART (re-exec, no file pull) on its next heartbeat — clears
    // a wedged claim/work loop remotely. Needs a supervised runner to come back cleanly.
    async requestRestart(agentId: string, actor: ActorInput = "ui"): Promise<{ id: string }> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true, enabled: true, deletedAt: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      if (agent.deletedAt) throw new HttpError(409, "agent is in the trash");
      if (!agent.enabled) throw new HttpError(409, "enable the runner before requesting a restart");
      const who = resolveActor(actor);
      await db.agent.update({ where: { id: agentId }, data: { restartRequested: true, restartRequestedAt: new Date(), restartRequestedBy: displayActor(who.actor), restartDeliveredAt: null } });
      await db.auditLog.create({ data: { actor: who.actor, userId: who.userId, action: "agent.restart_requested", detail: { agentId } } });
      return { id: agentId };
    },

    // Operator action: ask the runner to install browser automation on its next heartbeat — portable
    // Node (if the host has none) + Playwright + Chromium, all in the runner's own folder. The remote
    // fix for an agent that never advertises 'browser' (its startup self-heal needs Node already on
    // PATH). Success shows up as 'browser' in the agent's reported capabilities a few beats later.
    async requestBrowserInstall(agentId: string, actor: ActorInput = "ui"): Promise<{ id: string }> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true, enabled: true, deletedAt: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      if (agent.deletedAt) throw new HttpError(409, "agent is in the trash");
      if (!agent.enabled) throw new HttpError(409, "enable the runner before requesting a browser install");
      const who = resolveActor(actor);
      await db.agent.update({ where: { id: agentId }, data: { browserInstallRequested: true, browserInstallRequestedAt: new Date(), browserInstallRequestedBy: displayActor(who.actor), browserInstallDeliveredAt: null } });
      await db.auditLog.create({ data: { actor: who.actor, userId: who.userId, action: "agent.browser_install_requested", detail: { agentId } } });
      return { id: agentId };
    },

    // Operator action: move THIS agent to the new app URL (the canary). Requires a global target to be
    // set (Settings → Agent domain migration) — the target is the single source of truth for WHERE to
    // go; this flag just says "this agent, now". The next heartbeat returns migrate:{appUrl}; the runner
    // verifies + rewrites its supervisor entry + switches. Reset migratedAt/migrateError so a re-migrate
    // (e.g. after a fixed target) starts clean.
    async requestMigrate(agentId: string, actor: ActorInput = "ui"): Promise<{ id: string }> {
      const setting = await getAppSetting<AgentMigrationSetting>(db, AGENT_MIGRATION_KEY);
      if (!setting?.targetUrl || !setting.targetUrl.trim()) throw new HttpError(409, "set the migration target URL in Settings before migrating an agent");
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true, enabled: true, deletedAt: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      if (agent.deletedAt) throw new HttpError(409, "agent is in the trash");
      if (!agent.enabled) throw new HttpError(409, "enable the runner before migrating it");
      const who = resolveActor(actor);
      await db.agent.update({ where: { id: agentId }, data: { migrateRequested: true, migrateRequestedAt: new Date(), migrateRequestedBy: displayActor(who.actor), migrateDeliveredAt: null, migratedAt: null, migrateError: null } });
      await db.auditLog.create({ data: { actor: who.actor, userId: who.userId, action: "agent.migrate_requested", detail: { agentId, targetUrl: setting.targetUrl } } });
      return { id: agentId };
    },

    // Atomically claim up to `batchSize` eligible api jobs for this agent.
    async claim(agentId: string, batchSize: number, version?: string | null): Promise<RunnerJob[]> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true, clientId: true, enabled: true, version: true, capabilities: true, priority: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      if (!agent.enabled) throw new HttpError(403, "agent disabled");

      // ===== ADMISSION GATE (a): maintenance / drain — feature #7. THE FIRST admission decision (S1a). =====
      // One settings read; fail-open (an absent/corrupt setting reads as "no maintenance"). A GLOBAL
      // drain short-circuits the whole claim BEFORE the stale/wedged reclaims below — deliberately: we
      // do not want reclaims re-queuing work into a fleet we're trying to quiesce for the Azure cutover.
      // When drain clears, the next claim runs the reclaims normally, so a genuinely-stale lease is
      // still recovered — just deferred until resume. This is the "claiming agent is draining" branch.
      const maint = normalizeMaintenance(await getAppSetting<Partial<MaintenanceState>>(db, MAINTENANCE_KEY));
      if (maint.global) return [];
      const maintScope = maintenanceScope(maint); // scoped (per-system/per-client) pauses are applied per-candidate below
      // (Feature #4's global/per-tenant/per-(client,system) concurrency caps layer AFTER this gate —
      // see the per-candidate insertion point in the eligibility loop below.)

      // Priority failover: stand by (claim nothing) while a STRICTLY higher-priority peer of the same
      // scope is online — a client's other agents for a client runner, the other central runners for the
      // central one. Equal priority load-balances (unchanged). When the primary stops heartbeating
      // (> ONLINE_MS), this backup starts claiming; the stale-lease reclaim below then re-queues the
      // primary's in-flight jobs so the backup can pick them up.
      const ONLINE_MS = 90_000;
      const onlinePeers = await db.agent.findMany({
        where: { enabled: true, deletedAt: null, id: { not: agent.id }, clientId: agent.clientId, lastSeenAt: { gt: new Date(Date.now() - ONLINE_MS) } },
        select: { priority: true },
      });
      if (shouldStandBy(agent.priority, onlinePeers.map((p) => p.priority))) return [];

      // Reclaim stale leases: a job dispatched long ago whose assigned agent is gone/stale/
      // disabled goes back to pending. Scoped to dead agents so a peer can't reset a live
      // agent's in-flight jobs (the live agent keeps lastSeenAt fresh via heartbeat). This runs
      // BEFORE the stale-code guard below: an outdated single-agent client must still recover its
      // OWN crashed leases (no peer/central runner will — host affinity keeps on-prem jobs here).
      const staleCutoff = new Date(Date.now() - LEASE_MS);
      const stale = await db.job.findMany({
        where: {
          status: "dispatched",
          startedAt: { lt: staleCutoff },
          OR: [{ assignedAgentId: null }, { assignedAgent: { lastSeenAt: { lt: staleCutoff } } }, { assignedAgent: { enabled: false } }],
        },
        select: { id: true },
      });
      if (stale.length > 0) {
        await db.job.updateMany({ where: { id: { in: stale.map((s) => s.id) } }, data: { status: "pending", assignedAgentId: null } });
        await db.auditLog.create({ data: { actor: "system", action: "job.lease.reclaim", detail: { count: stale.length } } });
      }

      // Reclaim WEDGED "running" jobs — ones that posted progress then went silent (the dispatched
      // reclaim above only covers "dispatched"; a job flips to "running" on its first progress post).
      // Keyed off the JOB's own progressAt, NOT the agent heartbeat (the agent identity is reused, so a
      // restarted runner keeps the heartbeat green while the worker that owned this job is dead).
      // Bounded: re-queue once, then FAIL — so a deterministically-hanging step (e.g. a stuck Exchange
      // mirror) can't loop forever; the case fails and an operator re-plans (or uses Stop).
      const progressCutoff = new Date(Date.now() - PROGRESS_STALE_MS);
      // A clock-skewed writer (seen after a runner-host recovery) can stamp progressAt HOURS in the
      // future — such a job never ages past the cutoff and wedges forever. Anything claiming to be
      // from the future (beyond small skew slack) is just as dead as anything stale.
      const futureSkew = new Date(Date.now() + 10 * 60 * 1000);
      const wedged = await db.job.findMany({
        where: {
          status: "running",
          OR: [
            { progressAt: { lt: progressCutoff } },
            { progressAt: { gt: futureSkew } },
            { progressAt: null, startedAt: { lt: progressCutoff } },
            { progressAt: null, startedAt: { gt: futureSkew } },
          ],
        },
        select: { id: true, request: true, caseRequestId: true, systemKey: true, case: { select: { serviceNowCaseNumber: true, client: { select: { name: true, restricted: true, notifyOverride: true } } } } },
      });
      for (const w of wedged) {
        const reclaims = Number((req(w) as { progressReclaims?: unknown }).progressReclaims ?? 0);
        if (reclaims >= MAX_PROGRESS_RECLAIMS) {
          // Auto-stop: mark it failed but TAG it (request.autoStopped) so the run report shows a distinct
          // "⏱ auto-stopped — no progress" warning rather than a generic failure. refreshCaseStatus then
          // advances the case (a failed step doesn't block independent siblings) — "move on + warn".
          await db.job.update({ where: { id: w.id }, data: { status: "failed", error: "auto-stopped: this step made no progress for 20 minutes after a re-run — treated as wedged (e.g. a hung vendor call). The case continued; re-run this step to retry.", request: { ...(req(w) as object), autoStopped: true } as Prisma.InputJsonValue, finishedAt: new Date(), oneTimePassword: null } });
          await db.auditLog.create({ data: { actor: "system", action: "job.progress.failed", jobId: w.id, caseRequestId: w.caseRequestId, detail: { reclaims, autoStopped: true } } });
          await refreshCaseStatus(db, w.caseRequestId);
          const who = `${w.case?.serviceNowCaseNumber ?? w.caseRequestId}${w.case?.client?.name ? ` (${w.case.client.name})` : ""}`;
          await fireNotification({ event: "autoStopped", title: `Auto-stopped (wedged): ${w.systemKey} — ${who}`, caseNumber: w.case?.serviceNowCaseNumber ?? null, clientName: w.case?.client?.name ?? null, restricted: w.case?.client?.restricted ?? false, override: parseClientOverride(w.case?.client?.notifyOverride), systemKey: w.systemKey, at: new Date().toISOString(), detail: "No progress for 20 minutes after a re-run — treated as wedged. The case continued; re-run to retry.", url: process.env.APP_PUBLIC_URL ? `${process.env.APP_PUBLIC_URL}/cases/${w.caseRequestId}` : null });
        } else {
          await db.job.update({ where: { id: w.id }, data: { status: "pending", assignedAgentId: null, request: { ...(req(w) as object), progressReclaims: reclaims + 1 } as Prisma.InputJsonValue } });
          await db.auditLog.create({ data: { actor: "system", action: "job.progress.reclaim", jobId: w.id, caseRequestId: w.caseRequestId, detail: { reclaims: reclaims + 1 } } });
        }
      }

      // STALE-CODE GUARD: never hand jobs to a runner that isn't on the current build. A half-landed
      // self-update can leave an OLD process alive (it predates the single-instance lock so it won't
      // self-evict) which would run jobs with stale modules in memory — the cause of executors
      // crashing on bugs that were already fixed. The claiming process sends its OWN build id
      // (race-free); fall back to the last heartbeat's version. A valid-hash mismatch -> claim nothing.
      const build = runnerBuildId();
      const running = (version && version.trim()) || agent.version || "";
      const validHash = /^[0-9a-f]{6,}$/.test(running);
      if (validHash && running !== build) {
        return []; // outdated runner — the run report shows "agent outdated" as the pending reason
      }

      // central runner (clientId null) sees all clients' api jobs; a client agent sees only
      // its own. Jobs on a failed/completed case are excluded so a dead case can't run more.
      // Host affinity + capability gate: the central (cloud) runner must NEVER claim on-prem systems
      // (the ActiveDirectory/RSAT module, ADSync) — those only work on a client-network agent. A client
      // agent claims its client's jobs, but an on-prem system is withheld unless the agent REPORTS it can
      // run it (its Coretelligent module loaded) — so a DC missing RSAT doesn't grab an AD job it would
      // hard-fail ("Invoke-CtgADOnboarding not recognized"); it stays pending with a clear reason. A
      // legacy (pre-1.31) agent reports nothing (caps null) → withholds nothing → old behavior preserved.
      const scope = agent.clientId ? { clientId: agent.clientId } : {};
      const caps = parseCapabilities(agent.capabilities);
      const onPremExclude = agent.clientId ? onPremExclusions(caps) : ALWAYS_ON_PREM_SYSTEMS;
      // Browser-needing CONNECTORS (custom-…) are browser systems too: they join the capability gate
      // and the pinning exception exactly like the built-in list. Published-only — a draft never
      // claims. This is EVERY browser-kind connector PLUS every http connector whose auth is
      // browser-session (it opens a headless browser to sign in) — an http kind is no longer proof it
      // needs no browser, so filter on the definition, not the kind column.
      const browserConnectorKeys = (
        await db.connector.findMany({ where: { status: "published" }, select: { key: true, kind: true, definition: true } })
      ).filter((c) => connectorNeedsBrowser(c.kind, c.definition)).map((c) => c.key);
      const browserSystems = [...BROWSER_SYSTEMS, ...browserConnectorKeys];
      // Browser-automation gate (both central AND client agents): withhold browser-only systems (e.g.
      // spanning-force-sync + every published browser connector) unless the agent reports the 'browser'
      // capability (Node+Playwright installed). browserExclusions returns the built-in browser systems
      // when the cap is absent (empty when present) — so when it fires, the connector keys go too.
      const builtinBrowserExcluded = browserExclusions(caps); // BROWSER_SYSTEMS when cap absent, else []
      const excluded = [...new Set([...onPremExclude, ...builtinBrowserExcluded, ...(builtinBrowserExcluded.length ? browserConnectorKeys : [])])];
      const candidates = await db.job.findMany({
        where: {
          status: "pending",
          mode: "api",
          ...(excluded.length ? { systemKey: { notIn: excluded } } : {}),
          OR: [
            // Normal flow. Don't exclude a "failed" case: a failed step (e.g. egnyte) must NOT strand
            // an unrelated pending step (e.g. m365) whose own deps succeeded. Only "pending" jobs are
            // candidates and the per-job dependency gate (below) blocks any whose prerequisites didn't
            // succeed. "completed" is excluded (no pending work) and paused cases are held.
            { case: { status: { not: "completed" }, deletedAt: null, pausedAt: null, ...scope } },
            // "Run this step only": an operator-targeted job runs even though its case is paused (or
            // completed) — that pause is exactly what stops the rest of the run from cascading.
            { singleRun: true, case: { deletedAt: null, ...scope } },
          ],
        },
        orderBy: CLAIM_ORDER,
        select: { id: true, caseRequestId: true, systemKey: true, sequence: true, mode: true, status: true, singleRun: true, request: true, case: { select: { status: true } } },
      });
      if (candidates.length === 0) return [];

      // load all jobs of the candidate cases once, for the dependency gate
      const caseIds = [...new Set(candidates.map((c) => c.caseRequestId))];
      const allJobs = await db.job.findMany({
        where: { caseRequestId: { in: caseIds } },
        select: { id: true, caseRequestId: true, systemKey: true, sequence: true, mode: true, status: true, request: true },
      });
      // A FAILED step the operator ACCEPTED ("ignore warning — mark complete") resolves its run-log
      // outcome. Treat that step as satisfied for the dependency gate so its dependents proceed (e.g.
      // an accepted directory-sync failure stops blocking m365). Keyed by case+systemKey.
      const acceptedOutcomes = await db.runOutcome.findMany({
        where: { caseRequestId: { in: caseIds }, status: "failed", resolvedAt: { not: null } },
        select: { caseRequestId: true, systemKey: true },
      });
      const acceptedSet = new Set(acceptedOutcomes.map((o) => `${o.caseRequestId}|${o.systemKey}`));
      const lite = (j: { id: string; caseRequestId: string; systemKey: string; sequence: number; mode: JobLite["mode"]; status: JobLite["status"]; request: unknown }): JobLite => {
        const r = req(j) as { requiresApproval?: boolean; approved?: boolean; dependsOn?: unknown; hold?: unknown };
        const deps = Array.isArray(r.dependsOn) ? (r.dependsOn as unknown[]).filter((d): d is string => typeof d === "string") : null;
        const accepted = j.status === "failed" && acceptedSet.has(`${j.caseRequestId}|${j.systemKey}`);
        return { id: j.id, systemKey: j.systemKey, sequence: j.sequence, mode: j.mode, status: j.status, requiresApproval: Boolean(r.requiresApproval), approved: Boolean(r.approved), dependsOn: deps, accepted, hold: typeof r.hold === "string" ? r.hold : null };
      };
      const byCase = new Map<string, JobLite[]>();
      for (const j of allJobs) {
        const arr = byCase.get(j.caseRequestId) ?? [];
        arr.push(lite(j));
        byCase.set(j.caseRequestId, arr);
      }
      // A case is "hybrid" — its exchange runs on the on-prem agent — only if it actually has an
      // AD/sync job. Without one, exchange is Exchange Online and the central runner CAN run it.
      const hybridCases = new Set(allJobs.filter((j) => ALWAYS_ON_PREM_SYSTEMS.includes(j.systemKey)).map((j) => j.caseRequestId));

      // Preflight: don't claim a job whose required secrets aren't set — the broker couldn't resolve a
      // credential, so it would just fail. Load the candidate cases' client refs + overrides once.
      const caseMeta = await db.caseRequest.findMany({ where: { id: { in: caseIds } }, select: { id: true, clientId: true, secretOverrides: true, client: { select: { parentId: true, runCloudOnOwnAgent: true } } } });
      const caseMetaById = new Map(caseMeta.map((c) => [c.id, c]));
      // Own-agent affinity: for the CENTRAL runner, a client that pins its work to its own agent
      // (runCloudOnOwnAgent) AND actually HAS one gets ALL its jobs skipped here — they wait for that
      // client's agent (same as on-prem jobs). Falls back to central when the client has no agent.
      let pinnedClientIds = new Set<string>();
      if (!agent.clientId) {
        const pinned = [...new Set(caseMeta.filter((c) => c.client?.runCloudOnOwnAgent).map((c) => c.clientId))];
        if (pinned.length) {
          const withAgent = await db.agent.findMany({ where: { clientId: { in: pinned }, scope: "client_network", enabled: true, deletedAt: null }, select: { clientId: true } });
          pinnedClientIds = new Set(withAgent.map((a) => a.clientId).filter((x): x is string => Boolean(x)));
        }
      }
      // Load the candidate clients' secrets AND their parents' (a child account inherits the parent's
      // Delinea refs for systems it inherits) so an inheriting case isn't wrongly skipped as "missing".
      const parentIds = [...new Set(caseMeta.map((c) => c.client?.parentId).filter((x): x is string => Boolean(x)))];
      const clientSecrets = await db.secret.findMany({ where: { clientId: { in: [...new Set([...caseMeta.map((c) => c.clientId), ...parentIds])] } }, select: { clientId: true, name: true, externalId: true } });
      const secretsByClient = new Map<string, Map<string, string | null>>();
      for (const s of clientSecrets) {
        const m = secretsByClient.get(s.clientId) ?? new Map<string, string | null>();
        m.set(s.name, s.externalId);
        secretsByClient.set(s.clientId, m);
      }
      // Setup-state gate (opt-in, AppSetting "setup_gate"): only when enforcing does the claim path
      // pay for the extra lookups — default mode adds zero queries here.
      const gate: SetupGatePolicy = { enforceTested: false, ...((await getAppSetting<Partial<SetupGatePolicy>>(db, SETUP_GATE_KEY)) ?? {}) };
      const latestTestByKey = new Map<string, "ok" | "fail" | "untested">();
      const attestedKeys = new Set<string>();
      if (gate.enforceTested) {
        const gateClientIds = [...new Set(caseMeta.map((c) => c.clientId))];
        const [gateTests, gateStates] = await Promise.all([
          db.connectionTest.findMany({
            where: { clientId: { in: gateClientIds } },
            select: { clientId: true, systemKey: true, status: true, finishedAt: true },
            orderBy: { finishedAt: "desc" },
          }),
          db.systemSetupState.findMany({ where: { clientId: { in: gateClientIds }, attestedAt: { not: null } }, select: { clientId: true, systemKey: true } }),
        ]);
        for (const t of gateTests) {
          const k = `${t.clientId}:${t.systemKey}`;
          if (!latestTestByKey.has(k)) latestTestByKey.set(k, t.status === "ok" ? "ok" : t.status === "fail" ? "fail" : "untested");
        }
        for (const s of gateStates) attestedKeys.add(`${s.clientId}:${s.systemKey}`);
      }

      const eligible: string[] = [];
      const notNeeded: { id: string; caseRequestId: string; clientId: string; systemKey: string; singleRun: boolean }[] = [];
      for (const c of candidates) {
        // ADMISSION GATE (a) per-candidate: maintenance / drain (feature #7) — the FIRST per-candidate
        // check. A scoped pause (this system OR this client is in maintenance) drops the candidate as
        // early and cheaply as possible, before any dependency/secret/host-affinity work. (A GLOBAL
        // drain already returned [] above, so only per-system/per-client pauses reach here.)
        const cMeta = caseMetaById.get(c.caseRequestId);
        if (cMeta && maintenanceBlocks(maintScope, { systemKey: c.systemKey, clientId: cMeta.clientId })) continue;
        // ===== INSERTION POINT FOR FEATURE #4 (concurrency caps, gates b–d) =====
        // #4's caps (b global / c per-tenant / d per-(tenant,systemKey) ≤ 1) layer AFTER #7's
        // maintenance gate (S1) — but they are NOT applied per-candidate here. The eligibility loop
        // stays purely subtractive (deps/secrets/host/setup), producing `eligible[]`; #4's caps then
        // run as a single FINAL admission stage below (just before the assignment write), where the
        // count → admit → assign are wrapped in one fleet-wide `pg_advisory_xact_lock` transaction so
        // the caps hold under concurrent claims from multiple runners (see the ADMISSION LOCK block).
        // A bare per-candidate count-then-assign here would race (write skew under READ COMMITTED).
        // The counts key on the PARENT tenant for child accounts (D7 / cMeta.client.parentId).

        // A single-step job bypasses the dependency gate AND the terminal/paused-case exclusion
        // (it's an explicit, operator-confirmed run), but still honors the approval gate below and
        // the secret/host-affinity preflight. Everything else uses the normal claim rules.
        const lj = lite(c);
        const claimable = c.singleRun
          ? !(lj.requiresApproval && !lj.approved)
          : isClaimable(lj, byCase.get(c.caseRequestId) ?? [], c.case.status);
        if (!claimable) continue;
        const meta = caseMetaById.get(c.caseRequestId);
        const clientMap = (meta && secretsByClient.get(meta.clientId)) ?? new Map<string, string | null>();
        const parentMap = meta?.client?.parentId ? secretsByClient.get(meta.client.parentId) : undefined;
        // EVERY required secret is marked not-needed: this system is done by hand, so there is nothing
        // to broker. planCase would have planned it as a manual checklist item; this job was planned
        // while a credential still existed and marked not-needed afterwards. Dispatching it means a
        // guaranteed 409 at the credential broker, which FAILS the step and takes the whole case down
        // over work a human was always going to do. Demote it to the checklist item it should be.
        // Checked before host affinity so whichever agent polls first demotes it, even one that could
        // not have run the step itself.
        if (meta && allSecretsNotNeeded(req(c).secretNames, meta.secretOverrides, clientMap, parentMap)) {
          notNeeded.push({ id: c.id, caseRequestId: c.caseRequestId, clientId: meta.clientId, systemKey: c.systemKey, singleRun: c.singleRun });
          continue;
        }
        // Host affinity — the on-prem / cloud split:
        //  - the CENTRAL runner can't run an on-prem step (only a hybrid case's exchange reaches here);
        //  - a CLIENT-network agent (on-prem box, e.g. a DC) can't run a CLOUD step — it doesn't have the
        //    Microsoft.Graph / EXO modules — so cloud steps go to the central runner, which does.
        // A client that pins cloud to its own agent (runCloudOnOwnAgent) is the exception on both sides.
        // Without this, an on-prem client agent grabs an M365 job it can't run ("Get-MgSubscribedSku not recognized").
        const onPrem = systemIsOnPrem(c.systemKey, hybridCases.has(c.caseRequestId));
        if (!agent.clientId && onPrem) continue;                                             // central: skip on-prem
        if (agent.clientId && !onPrem && !meta?.client?.runCloudOnOwnAgent) continue;        // client agent: skip cloud -> central
        // Own-agent affinity: central runner leaves a pinned client's cloud jobs for that client's agent.
        // EXCEPT browser jobs (spanning-force-sync): browser automation only exists on the central runner
        // (a client's on-prem agent has no Node/Playwright and is withheld browser systems by the caps
        // gate above), so pinning one to the own agent strands it — claimable by nobody, pending forever.
        // Browser jobs are central-only; never pinned away from central.
        if (!agent.clientId && meta && pinnedClientIds.has(meta.clientId) && !browserSystems.includes(c.systemKey)) continue;
        if (missingRequiredSecrets(req(c).secretNames, meta?.secretOverrides, clientMap, parentMap).length > 0) continue; // secrets not set — skip
        // Setup-state gate (enforce mode only): withhold a job whose system's latest conn-test
        // failed, unless attested. singleRun bypasses (an explicit operator-confirmed run).
        if (gate.enforceTested && !c.singleRun && meta) {
          const k = `${meta.clientId}:${c.systemKey}`;
          const verdict = setupGateBlocks({ test: latestTestByKey.get(k) ?? "unknown", attested: attestedKeys.has(k) }, gate);
          if (verdict.block) continue;
        }
        eligible.push(c.id);
        if (eligible.length >= batchSize) break;
      }

      // Demote the not-needed jobs to manual checklist items (never dispatched, never 409'd). The note
      // tells the operator what to do by hand; the case then reads "needs manual", not "failed".
      for (const n of notNeeded) {
        const job = candidates.find((c) => c.id === n.id)!;
        const r = req(job) as Record<string, unknown>;
        const cfg = (r.config && typeof r.config === "object" ? (r.config as Record<string, unknown>) : {}) as Record<string, unknown>;
        const notes = Array.isArray(cfg.notes) ? cfg.notes.filter((x): x is string => typeof x === "string") : [];
        const note = `${n.systemKey} is handled by hand for this client — its credential is marked "not needed", so there is nothing for the engine to connect with. Do this step manually, then tick it off.`;
        // Guard on status:pending so two agents polling at once can't both demote it — the loser's
        // update matches nothing and only the winner writes the audit line.
        const demoted = await db.job.updateMany({
          where: { id: n.id, status: "pending" },
          data: {
            mode: "manual",
            status: "manual",
            request: { ...r, config: { ...cfg, notes: [...notes, note] } } as Prisma.InputJsonValue,
          },
        });
        if (demoted.count === 0) continue; // raced to another status — leave it alone
        await db.auditLog.create({
          data: {
            actor: "system", action: "job.demote_manual", jobId: n.id, caseRequestId: n.caseRequestId, clientId: n.clientId,
            detail: { systemKey: n.systemKey, reason: "every required secret is marked not-needed — no credential to broker" },
          },
        });
      }
      // Advance the case — but NEVER off the back of a singleRun job. "Run this step only" is an
      // out-of-band operator action that deliberately leaves the case status alone (see run-single, and
      // the same guard in recordResult): cascading here would reopen a COMPLETED case as "needs_manual"
      // just because someone single-ran a step whose credential is marked not-needed.
      const cascade = new Set(notNeeded.filter((n) => !n.singleRun).map((n) => n.caseRequestId));
      for (const caseId of cascade) await refreshCaseStatus(db, caseId);

      if (eligible.length === 0) return [];

      // ===== ADMISSION GATES (b)(c)(d): concurrency governor — feature #4. The FINAL admission stage. =====
      // Read the caps once (only now that we actually have candidates to admit — an idle agent never
      // pays for this). Fail-open: an absent/unparseable/disabled setting resolves to enabled:false,
      // and the governor is a no-op (behavior byte-identical to pre-feature).
      const concCaps = resolveCaps(await getAppSetting<ConcurrencySetting>(db, CONCURRENCY_KEY));
      let admitted: string[];
      let capSkips: { id: string; reason: string }[] = [];
      if (!concCaps.enabled) {
        // Governor OFF (default / dark): the original single atomic assignment, no lock, no extra read.
        // Only rows still pending flip; a racing agent's updateMany skips already-claimed rows. Clear
        // progress so every (re-)run starts with a fresh phase trail — DbNull writes SQL NULL.
        await db.job.updateMany({
          where: { id: { in: eligible }, status: "pending" },
          data: { status: "dispatched", assignedAgentId: agent.id, startedAt: new Date(), progress: Prisma.DbNull },
        });
        admitted = eligible;
      } else {
        // Governor ON: enforce the caps inside a fleet-wide advisory-locked critical section. Only
        // count → admit → assign live inside the lock; all the (expensive) candidate/case/secret loads
        // above stayed outside it. The lock serializes this section against every other claim(), so the
        // in-flight count a claim reads and the assignment it writes can't interleave — closing the
        // write-skew window that lets two agents each flip a different job of the same (tenant, system).
        const byId = new Map(candidates.map((c) => [c.id, c] as const));
        const tenantOf = (id: string) => {
          const m = caseMetaById.get(byId.get(id)!.caseRequestId);
          return m?.client?.parentId ?? m!.clientId; // D7: PARENT tenant for a child account
        };
        const systemKeyOf = (id: string) => byId.get(id)!.systemKey;
        const exemptOf = (id: string) => {
          const c = byId.get(id)!;
          return c.singleRun || ADHOC_SYSTEM_KEYS.includes(c.systemKey); // D7: ad-hoc / singleRun exempt
        };
        admitted = await db.$transaction(async (tx) => {
          // Serialize the admission critical section fleet-wide; auto-released at tx end (commit OR
          // rollback). Blocks until acquired — keep everything inside this callback minimal.
          await tx.$executeRaw`SELECT pg_advisory_xact_lock(${ADMISSION_LOCK_KEY})`;
          const inflight = await countInflight(tx); // FRESH counts, read under the lock
          const admit = admitUnderCaps({ eligible, tenantOf, systemKeyOf, exemptOf, inflight, caps: concCaps });
          capSkips = admit.skipped;
          if (admit.ids.length === 0) return [];
          await tx.job.updateMany({
            where: { id: { in: admit.ids }, status: "pending" },
            data: { status: "dispatched", assignedAgentId: agent.id, startedAt: new Date(), progress: Prisma.DbNull },
          });
          return admit.ids;
        }, { timeout: 20_000, maxWait: 10_000 });
      }
      // Surface the governor acting (outside the locked tx — an audit write must not extend the section).
      if (capSkips.length) {
        await db.auditLog.create({ data: { actor: `agent:${agent.id}`, action: "job.claim.capped", detail: { capped: capSkips.slice(0, 50) } } });
      }
      if (admitted.length === 0) return []; // everything the agent could run is at capacity this poll

      const claimed = await db.job.findMany({
        where: { id: { in: admitted }, assignedAgentId: agent.id, status: "dispatched" },
        include: { case: { include: { client: { select: { slug: true, primaryDomain: true, backbone: true, identity: true } } } } },
        orderBy: { sequence: "asc" },
      });
      await db.auditLog.create({ data: { actor: `agent:${agent.id}`, action: "job.claim", detail: { count: claimed.length, jobIds: claimed.map((c) => c.id), clients: [...new Set(claimed.map((c) => c.case.client.slug))] } } });

      // A case with a dispatched/running step IS running — reflect it now so the cases list shows
      // "running" instead of "queued" while work executes (status is only otherwise recomputed when a
      // job finishes). Only bump pre-execution states; never override a paused/needs_* hold.
      const runningCaseIds = [...new Set(claimed.map((c) => c.caseRequestId))];
      await db.caseRequest.updateMany({ where: { id: { in: runningCaseIds }, status: { in: ["queued", "planning"] } }, data: { status: "running" } });

      // AD phone write-back: the number the teams step assigned (its result's PhoneNumber), injected as
      // `writebackPhone` so the on-prem agent writes AD telephoneNumber without any cloud credential.
      // No succeeded teams result, or no number on it, and the step writes nothing.
      const phoneWritebackCaseIds = [...new Set(claimed.filter((j) => j.systemKey === "ad-phone-writeback").map((j) => j.caseRequestId))];
      const phoneByCase = new Map<string, string>();
      if (phoneWritebackCaseIds.length > 0) {
        const teamsJobs = await db.job.findMany({
          where: { caseRequestId: { in: phoneWritebackCaseIds }, systemKey: "teams", status: "succeeded" },
          select: { caseRequestId: true, result: true },
        });
        for (const t of teamsJobs) {
          const n = teamsPhoneNumberOf(t.result);
          if (n) phoneByCase.set(t.caseRequestId, n);
        }
      }

      // AD email write-back (B1): for any ad-email-writeback job being handed out, resolve the
      // mailbox's ASSIGNED primary SMTP from the sibling cloud job's result (exchange preferred, then
      // m365) and inject it into the payload as `writebackEmail`, so the on-prem agent just writes AD
      // `mail` = that address without needing cloud creds. The executor falls back to the deterministic
      // workEmail/UPN when no result carries an address (e.g. an older runner that didn't return it).
      const writebackCaseIds = [...new Set(claimed.filter((j) => j.systemKey === "ad-email-writeback").map((j) => j.caseRequestId))];
      const emailByCase = new Map<string, string>();
      if (writebackCaseIds.length > 0) {
        const siblings = await db.job.findMany({
          where: { caseRequestId: { in: writebackCaseIds }, systemKey: { in: ["exchange", "m365"] }, status: "succeeded" },
          select: { caseRequestId: true, systemKey: true, result: true },
        });
        for (const s of siblings) {
          // The runner emits PascalCase result keys (PrimarySmtpAddress); tolerate lowercase too.
          const res = jobResultEnvelope(s.result) as { PrimarySmtpAddress?: unknown; primarySmtpAddress?: unknown } | null;
          const addr = res?.PrimarySmtpAddress ?? res?.primarySmtpAddress;
          if (typeof addr === "string" && addr.includes("@")) {
            const cur = emailByCase.get(s.caseRequestId);
            if (!cur || s.systemKey === "exchange") emailByCase.set(s.caseRequestId, addr); // exchange wins over m365
          }
        }
      }

      // Offboard manager hand-off: exchange grants the departing user's MANAGER Full Access to the
      // converted shared mailbox (delegateManagerFullAccess). It normally runs first and reads the live
      // directory link — but if it runs AFTER active-directory (a re-run, or a first attempt that
      // failed), AD has already CLEARED that link and the delegate would be silently skipped. The AD
      // step captures the manager it cleared; inject that address so exchange can still grant access.
      const exchangeOffboardCaseIds = [
        ...new Set(claimed.filter((j) => j.systemKey === "exchange" && j.case.action === "offboard").map((j) => j.caseRequestId)),
      ];
      const managerByCase = new Map<string, string>();
      if (exchangeOffboardCaseIds.length > 0) {
        // AD is authoritative when it ran; m365/entra capture the same link for cloud-only clients,
        // which have no AD step at all. Sorted so AD wins when both exist.
        const dirJobs = await db.job.findMany({
          where: { caseRequestId: { in: exchangeOffboardCaseIds }, systemKey: { in: ["active-directory", "m365", "entra"] }, status: "succeeded" },
          select: { caseRequestId: true, systemKey: true, result: true },
        });
        dirJobs.sort((a, b) => (a.systemKey === "active-directory" ? 0 : 1) - (b.systemKey === "active-directory" ? 0 : 1));
        for (const a of dirJobs) {
          if (managerByCase.has(a.caseRequestId)) continue;
          // The runner emits PascalCase result keys (Manager.Email); tolerate lowercase too.
          const res = (jobResultEnvelope(a.result) ?? {}) as { Manager?: unknown; manager?: unknown };
          const m = (res.Manager ?? res.manager) as { Email?: unknown; email?: unknown } | null;
          const addr = m?.Email ?? m?.email;
          if (typeof addr === "string" && addr.includes("@")) managerByCase.set(a.caseRequestId, addr);
        }
      }

      // AD consistency check (Design D, detect-only): inject the Entra object's anchor data (from the
      // m365 result) so the on-prem agent can compare it to the AD source anchor without cloud creds.
      const checkCaseIds = [...new Set(claimed.filter((j) => j.systemKey === "ad-consistency-check").map((j) => j.caseRequestId))];
      const cloudByCase = new Map<string, CloudObject>();
      if (checkCaseIds.length > 0) {
        // NOT filtered to succeeded any more: a failed or manually-completed m365 step is exactly the
        // case the check used to pass silently, and the REASON has to reach the operator (FR #0000093).
        const m365s = await db.job.findMany({
          where: { caseRequestId: { in: checkCaseIds }, systemKey: { in: ["m365", "entra"] } },
          orderBy: { finishedAt: "desc" },
          select: { caseRequestId: true, status: true, result: true },
        });
        const best = new Map<string, { status: string; result: unknown }>();
        for (const s of m365s) {
          // Prefer a succeeded one; otherwise keep the most recent (the query is already newest-first).
          const held = best.get(s.caseRequestId);
          if (!held || (held.status !== "succeeded" && s.status === "succeeded")) {
            best.set(s.caseRequestId, { status: s.status, result: s.result });
          }
        }
        for (const id of checkCaseIds) {
          const b = best.get(id) ?? null;
          cloudByCase.set(id, cloudObjectFor(b ? { status: b.status, envelope: jobResultEnvelope(b.result) } : null));
        }
      }

      // MAILBOX HAND-OFF (offboard): the m365/entra executor is the one that removes the license, and it
      // must NOT strip the license off a mailbox that was never converted to shared — Exchange purges an
      // unlicensed, unconverted mailbox after its 30-day grace, which loses the leaver's mail outright.
      // The Exchange step already computes the size and decides whether to convert; it just had nobody to
      // tell. Hand both facts to the downstream license step:
      //   mailboxSizeGB   — drives the executor's existing "keep the license over the threshold" rule,
      //                     which until now was DEAD: -MailboxSizeGB was never passed, so it was always 0.
      //   mailboxConverted— true only when the mailbox is actually shared now. The license removal is
      //                     gated on it, so a skipped conversion keeps the license instead of orphaning it.
      // Absent (Exchange hasn't run / isn't in the plan) => both undefined, and the executor keeps its
      // old behaviour, so a cloud-only client with no Exchange step is unaffected.
      const licenseCaseIds = [
        ...new Set(claimed.filter((j) => (j.systemKey === "m365" || j.systemKey === "entra") && j.case.action === "offboard").map((j) => j.caseRequestId)),
      ];
      const mailboxByCase = new Map<string, { sizeGB: number | null; converted: boolean; convertPending: boolean }>();
      if (licenseCaseIds.length > 0) {
        // EVERY exchange job on these cases, not just the finished ones — because the dangerous case is
        // the one that HASN'T run. Most clients' profiles put the licence removal in a step that runs
        // BEFORE exchange converts the mailbox (regal, six-one, yuma…). Ordering is per-client data and
        // will drift again; this guard does not depend on getting it right. If a conversion is CONFIGURED
        // and hasn't succeeded yet, the licence stays put and the step says so.
        const exJobs = await db.job.findMany({
          where: { caseRequestId: { in: licenseCaseIds }, systemKey: "exchange" },
          select: { caseRequestId: true, result: true, status: true, request: true },
        });
        for (const e of exJobs) {
          const res = (jobResultEnvelope(e.result) ?? {}) as Record<string, unknown>;
          const raw = res.MailboxSizeGB ?? res.mailboxSizeGB;
          const sizeGB = typeof raw === "number" ? raw : null;
          // The executor reports the conversion in its action lines ("converted mailbox to shared…"), and
          // says so explicitly when it declines ("over threshold … kept as a user mailbox").
          const actions = (res.Actions ?? res.actions ?? []) as unknown[];
          const lines = actions.filter((a): a is string => typeof a === "string");
          // Only a conversion the runner CONFIRMED counts, and a convert is only "pending" while it
          // can still actually happen. Both rules live in ./mailbox-convert, with the reasoning.
          const converted = isConvertConfirmed(lines);
          // Does this client even ask for a conversion? If not, there is nothing to wait for.
          const exCfg = ((req(e).config ?? {}) as { convertToShared?: unknown }).convertToShared;
          const convertPending = isConvertStillComing(e.status, exCfg != null);
          mailboxByCase.set(e.caseRequestId, { sizeGB, converted, convertPending });
        }
      }

      // Generated INITIAL password (revealed once): for a "generate"-mode m365/entra onboard, generate
      // the password app-side so we can show it to the operator, store it on the case (revealed once,
      // then wiped), and inject it as the runner's initial password. Only when the runner WOULD generate
      // one anyway (no initialPasswordSecret, no literal, no brokered default-password) — never overrides
      // a wired/fixed password. Idempotent: reuse the stored value across re-claims.
      const pwByCase = new Map<string, string>();
      for (const j of claimed) {
        if (j.case.action !== "onboard" || (j.systemKey !== "m365" && j.systemKey !== "entra")) continue;
        if (pwByCase.has(j.caseRequestId)) continue;
        const rr = req(j);
        const cfg = (rr.config ?? {}) as { initialPasswordSecret?: unknown; initialPassword?: unknown };
        const generateMode = !cfg.initialPasswordSecret && !cfg.initialPassword && !((rr.secretNames ?? []).includes("default-password"));
        if (!generateMode) continue;
        let pw = (j.case as { initialPassword?: string | null }).initialPassword ?? null;
        if (!pw) {
          pw = generateInitialPassword();
          await db.caseRequest.update({ where: { id: j.caseRequestId }, data: { initialPassword: pw } });
        }
        pwByCase.set(j.caseRequestId, pw);
      }

      // LOW-CODE CONNECTORS: a "custom-…" systemKey has no hand-written executor — the generic
      // Coretelligent.Connector module interprets the PUBLISHED definition, injected here at claim
      // time as config.connector (same hand-off pattern as mailboxSizeGB/writebackEmail above).
      // Injected at claim, not plan, so an edit to the definition reaches the very next (re-)run,
      // and so a draft/archived connector can never execute: no published row → no injection → the
      // runner's "no executor" fallback resolves the job as a manual follow-up instead.
      const customKeys = [...new Set(claimed.map((j) => j.systemKey).filter((k) => k.startsWith("custom-")))];
      const connectorByKey = customKeys.length
        ? new Map(
            (
              await db.connector.findMany({
                where: { key: { in: customKeys }, status: "published" },
                select: { key: true, kind: true, definition: true },
              })
            ).map((c) => [c.key, c])
          )
        : new Map<string, { key: string; kind: string; definition: unknown }>();

      return claimed.map((j) => {
        const r = req(j);
        const injectedPw = (j.systemKey === "m365" || j.systemKey === "entra") ? pwByCase.get(j.caseRequestId) : undefined;
        let config = injectedPw ? { ...((r.config as Record<string, unknown> | null) ?? {}), initialPassword: injectedPw } : (r.config ?? null);
        const connector = connectorByKey.get(j.systemKey);
        if (connector) {
          config = { ...((config as Record<string, unknown> | null) ?? {}), connector: { kind: connector.kind, definition: connector.definition } };
        }
        // Ad-hoc password reset: hand the app-generated value (Job.oneTimePassword — revealed once to
        // the operator, then wiped) to the runner as config.newPassword. Kept on the row across
        // re-claims (lease reclaim) until the reveal/failure wipes it; never persisted into request.
        if (PASSWORD_RESET_SYSTEM_KEYS.includes(j.systemKey) && j.oneTimePassword) {
          config = { ...((config as Record<string, unknown> | null) ?? {}), newPassword: j.oneTimePassword };
        }
        // Per-client "must change password at first sign-in" (FR #14): the profile's
        // password.requireChangeAtSignIn (schema default true) reaches the executors as
        // config.requireChangeAtSignIn. Only fills the gap — a value already on the job config
        // (an operator's per-reset choice, or a plan-time setting) wins.
        if (j.case.action === "onboard" && ["m365", "entra", "google-workspace"].includes(j.systemKey)) {
          const cfgNow = (config ?? {}) as Record<string, unknown>;
          if (cfgNow.requireChangeAtSignIn === undefined) {
            const idPw = ((j.case.client as { identity?: unknown }).identity as { password?: { requireChangeAtSignIn?: unknown } } | null)?.password;
            if (typeof idPw?.requireChangeAtSignIn === "boolean") config = { ...cfgNow, requireChangeAtSignIn: idPw.requireChangeAtSignIn };
          }
        }
        // Mailbox facts from the Exchange step, so the license removal can honour "convert first".
        const mbx = (j.systemKey === "m365" || j.systemKey === "entra") && j.case.action === "offboard"
          ? mailboxByCase.get(j.caseRequestId)
          : undefined;
        if (mbx) {
          config = {
            ...((config as Record<string, unknown> | null) ?? {}),
            ...(mbx.sizeGB !== null ? { mailboxSizeGB: mbx.sizeGB } : {}),
            mailboxConverted: mbx.converted,
            mailboxConvertPending: mbx.convertPending,
          };
        }
        const casePayload = (j.case.payload ?? {}) as Record<string, unknown>;
        // Only fill a manager the intake didn't already carry — an operator-supplied address wins.
        const capturedManager =
          j.systemKey === "exchange" && j.case.action === "offboard" && !casePayload.managerEmail
            ? managerByCase.get(j.caseRequestId)
            : undefined;
        const basePayload =
          j.systemKey === "ad-email-writeback"
            ? { ...casePayload, writebackEmail: emailByCase.get(j.caseRequestId) ?? null }
            : j.systemKey === "ad-phone-writeback"
            ? { ...casePayload, writebackPhone: phoneByCase.get(j.caseRequestId) ?? null }
            : j.systemKey === "ad-consistency-check"
            ? { ...casePayload, cloudObject: cloudByCase.get(j.caseRequestId) ?? cloudObjectFor(null) }
            : capturedManager
            ? { ...casePayload, managerEmail: capturedManager }
            : j.case.payload;
        // AD-STANDALONE domain separation (FR #83/#107): on the on-prem lane, hand the AD-domain UPN
        // instead of the mail-domain one. Wraps the chain above (not another arm of it) so
        // ad-email-writeback / ad-consistency-check keep their own overrides AND get this one; a no-op
        // for every client except a standalone one with identity.adDomain set.
        const payload = applyAdStandaloneUpn(basePayload as Record<string, unknown>, j.systemKey, j.case.client);
        return {
          id: j.id,
          caseNumber: j.case.serviceNowCaseNumber ?? null,
          action: j.case.action,
          systemKey: j.systemKey,
          mode: j.mode,
          client: { slug: j.case.client.slug, primaryDomain: j.case.client.primaryDomain, backbone: j.case.client.backbone },
          config,
          secretNames: r.secretNames ?? [],
          payload,
          requiresApproval: Boolean(r.requiresApproval),
          captureEvidence: Boolean(r.captureEvidence),
          // case.dryRun is AUTHORITATIVE at claim time (the per-job request.dryRun stamp is only a
          // planning hint for the UI/playbook). Reading it here means: an absent stamp can't run a
          // dry-run case LIVE (fail-safe), a job claimed mid-toggle uses the committed case mode (no
          // TOCTOU), and an approve that rewrites request can't revert the mode. -WhatIf when true.
          dryRun: Boolean(j.case.dryRun),
          // Verify pass: run only the read-only validator (Confirm-Ctg*), no mutations. Per-job stamp
          // set by the case-level "Verify" action.
          validateOnly: Boolean(r.validateOnly),
        };
      });
    },

    // Broker a Delinea credential for a job. Least-privilege: the agent must own the job and
    // the secret must be one named on that job. Never returns a secret value (we store only
    // the Delinea reference); production exchanges externalId for a short-TTL scoped cred here.
    async brokerCredential(jobId: string, agentId: string, secretName: string, withOtp = false): Promise<BrokeredCredential> {
      const job = await db.job.findUnique({ where: { id: jobId }, select: { status: true, assignedAgentId: true, request: true, case: { select: { clientId: true, secretOverrides: true, client: { select: { parentId: true } } } } } });
      if (!job) throw new HttpError(404, "unknown job");
      if (job.assignedAgentId !== agentId) throw new HttpError(403, "job not assigned to this agent");
      await assertAgentEnabled(db, agentId);
      if (job.status !== "dispatched" && job.status !== "running") throw new HttpError(409, `job is ${job.status}; credentials only brokered for in-progress jobs`);
      // WHY a broker attempt failed, stamped on the Job so the run outcome can carry the structured
      // reason (recordResult copies it) — remediation is then scriptable off `code` + secretName.
      // Best-effort: stamping must never mask the real error. Cleared again on a clean broker.
      const stamp = async (cf: CredFailure | null) => {
        try { await db.job.update({ where: { id: jobId }, data: { credFailure: cf === null ? Prisma.DbNull : (cf as unknown as Prisma.InputJsonValue) } }); } catch { /* non-fatal */ }
      };
      const allowed = req(job).secretNames ?? [];
      if (!allowed.includes(secretName)) {
        await stamp(credFailure("not_authorized", secretName, `secret ${secretName} is not authorized for this job`));
        throw new HttpError(403, `secret ${secretName} is not authorized for this job`);
      }
      const clientSecret = await db.secret.findUnique({ where: { clientId_name: { clientId: job.case.clientId, name: secretName } }, select: { provider: true, externalId: true } });
      // Child accounts that run their parent's runbook also inherit the parent's Delinea references —
      // looked up only when the child has none of its own (the override/own ref take precedence).
      const parentId = job.case.client.parentId;
      const parentSecret = parentId && !clientSecret?.externalId
        ? await db.secret.findUnique({ where: { clientId_name: { clientId: parentId, name: secretName } }, select: { provider: true, externalId: true } })
        : null;
      // A per-case override wins over the child's own ref, which wins over the parent's; all Delinea ids.
      const { externalId, source } = effectiveExternalId(secretName, job.case.secretOverrides, clientSecret?.externalId ?? null, parentSecret?.externalId ?? null);
      if (source === "not_needed") {
        await stamp(credFailure("not_needed", secretName, "the secret is marked not-needed (manual step), yet the executor requested it"));
        throw new HttpError(409, `secret '${secretName}' is marked not needed (handled as a manual step) — no credential to broker`);
      }
      if (!externalId) {
        await stamp(credFailure("reference_missing", secretName, "no Delinea reference wired on the client, its parent, or a case override"));
        throw new HttpError(404, `no usable secret reference '${secretName}' (set it on the client or override it on the case)`);
      }
      // Overrides only replace the reference id, not the provider — every reference is a Delinea id.
      const secret = { provider: clientSecret?.provider ?? parentSecret?.provider ?? "delinea", externalId, source };

      // Push-down model: the app resolves the secret's VALUE from Delinea and returns the fields so
      // the runner doesn't need Delinea creds of its own (nothing to distribute to client DCs). A
      // dead/misscoped reference fails here with a clear error rather than deep in the runner. When
      // the app has no Delinea creds we can't push down — return a note so the runner says so.
      const cfg = delineaConfigFromEnv();
      let brokered = false;
      let label: string | undefined;
      let fields: Record<string, string> | undefined;
      let note: string | undefined = "Delinea not configured on the app — set DELINEA_* so the app can resolve and push the credential to the runner";
      if (delineaConfigured(cfg)) {
        const resolved = await resolveSecretFields(cfg, secret.externalId);
        if (!resolved.ok) {
          const why = resolved.error ?? "unknown error";
          await stamp(credFailure(classifyDelineaError(why), secretName, why, { externalId: secret.externalId, source: secret.source }));
          throw new HttpError(502, `secret '${secretName}' is not resolvable in Delinea: ${why}`);
        }
        brokered = true;
        label = resolved.label;
        fields = resolved.fields;
        note = undefined;
      } else {
        await stamp(credFailure("delinea_not_configured", secretName, "the app has no Delinea credentials — nothing can be resolved or pushed down"));
      }
      // One-time password, ON REQUEST only. Delinea holds the authenticator seed (one-time-password
      // enabled on the secret) and mints the current code; we never store or broker the SEED. The
      // code lives ~30s, so the runner asks for it at the moment it needs it — not at claim time —
      // and getOneTimePasswordCode waits out a nearly-dead window so it can't expire mid-login.
      let otpCode: string | undefined;
      let otpRemainingSeconds: number | undefined;
      let otpError: string | undefined;
      if (withOtp) {
        if (!delineaConfigured(cfg)) otpError = "Delinea not configured on the app";
        else {
          const otp = await getOneTimePasswordCode(cfg, secret.externalId);
          if (otp.ok) { otpCode = otp.code; otpRemainingSeconds = otp.remainingSeconds; }
          else otpError = otp.error;
        }
      }
      if (withOtp && otpError) {
        await stamp(credFailure("otp_unavailable", secretName, otpError, { externalId: secret.externalId, source: secret.source }));
      } else if (brokered) {
        // clean broker — clear any stale stamp from an earlier failed attempt so a later, unrelated
        // job failure isn't mislabeled as a credential problem
        await stamp(null);
      }
      // Audit records metadata ONLY — the field NAMES, never their values (and never the OTP).
      await db.auditLog.create({ data: { actor: `agent:${agentId}`, action: "job.credential", jobId, clientId: job.case.clientId, detail: { secretName, brokered, source: secret.source, fieldNames: fields ? Object.keys(fields) : [], ...(withOtp ? { otp: otpCode ? "minted" : `unavailable: ${otpError}` } : {}) } } });
      return { provider: secret.provider, externalId: secret.externalId, secretName, brokered, expiresInSeconds: 300, label, note, fields, otpCode, otpRemainingSeconds, otpError };
    },

    // --- Connection tests (isolated permission preflight) ----------------------------------------
    // A separate lane from the Job pipeline: the runner connects with the brokered credential and
    // does one cheap authorized read, proving the cred not only resolves but actually has access.
    // Routed like a job (cloud -> central runner, on-prem -> client agent) via the onPrem flag.

    // Queue a fresh set of tests for a client (replaces any prior run). One row per api system that
    // actually connects to something (has a required secret). With a systemKey, retests ONLY that
    // system — its row is replaced and every other system's latest result survives.
    // deepAllowed: caller states whether an INTERACTIVE probe (a real vendor-portal sign-in) is wanted.
    // Only the operator's explicit "test this one system" says yes — a save-and-test after editing a
    // token, a whole-client run, the fleet button and the nightly sweep all say no. See ConnectionTest.deep.
    // source: "google-setup" is a one-off auto-trigger fired by the Google Workspace auto-setup GET
    // poller once a run lands on a vaulted credential (see google-setup-run.ts) — otherwise a normal
    // single-system retest, just distinguishable in the ConnectionTest.source column.
    async requestConnectionTests(clientSlug: string, systemKey?: string, source: "manual" | "sweep" | "google-setup" = "manual", deepAllowed = false): Promise<{ tests: { systemKey: string; onPrem: boolean }[] }> {
      const client = await db.client.findUnique({
        where: { slug: clientSlug },
        select: { id: true, primaryDomain: true, systems: { select: { systemKey: true, mode: true, secretNames: true, config: true } }, secrets: { select: { name: true, externalId: true } } },
      });
      if (!client) throw new HttpError(404, `unknown client ${clientSlug}`);
      const hasAd = client.systems.some((s) => ALWAYS_ON_PREM_SYSTEMS.includes(s.systemKey));
      if (systemKey) {
        const target = client.systems.find((s) => s.systemKey === systemKey);
        if (!target) throw new HttpError(404, `client has no system '${systemKey}'`);
        if (target.mode !== "api" || (target.secretNames?.length ?? 0) === 0)
          throw new HttpError(422, `system '${systemKey}' has no connection to test (needs mode=api and at least one secret)`);
      }
      // Manual-step systems (every required secret marked NOT_NEEDED) are excluded from dispatch: there
      // is nothing to connect to, and dispatching one only fails the broker with "secret is marked not
      // needed — nothing to test". listConnectionTests surfaces them as read-only "not needed" rows.
      const externalIdByName = new Map(client.secrets.map((s) => [s.name, s.externalId] as const));
      const specs = testableSystems(client.systems, hasAd, systemKey, externalIdByName);
      await db.connectionTest.deleteMany({ where: { clientId: client.id, ...(systemKey ? { systemKey } : {}) } });
      if (specs.length === 0) return { tests: [] };
      // Retesting ONE system, by hand, is the only place a deep (interactive, browser) probe may run.
      const deep = Boolean(systemKey) && deepAllowed;
      const rows = specs.map((s) => connTestRow(client.id, s, client.secrets, source, deep));
      await db.connectionTest.createMany({ data: rows });
      // Stage 1 ("Fields"): the app's own Delinea resolve + field-shape check, persisted on the
      // rows. Best-effort — a preflight problem must never stop the runner stages from running.
      await preflightConnTestFields(db, client.id, client.primaryDomain, specs).catch(() => {});
      return { tests: rows.map((r) => ({ systemKey: r.systemKey, onPrem: r.onPrem })) };
    },

    // FLEET sweep: enqueue connection tests for every modeled, active client at once (one row per
    // testable api system). Replaces any prior run per client. Runners claim them on their next poll
    // — cloud tests on the central runner, on-prem on each client's own agent (so clients without an
    // installed agent leave their on-prem tests pending, surfaced as such in the roll-up). Returns
    // how many clients + tests were queued, and how many of those tests are on-prem.
    async requestConnectionTestsForAll(): Promise<{ clients: number; tests: number; onPrem: number }> {
      const clients = await db.client.findMany({
        where: { status: "active", systems: { some: {} } },
        select: { id: true, systems: { select: { systemKey: true, mode: true, secretNames: true, config: true } }, secrets: { select: { name: true, externalId: true } } },
      });
      let total = 0, onPrem = 0, withTests = 0;
      for (const client of clients) {
        const hasAd = client.systems.some((s) => ALWAYS_ON_PREM_SYSTEMS.includes(s.systemKey));
        const externalIdByName = new Map(client.secrets.map((s) => [s.name, s.externalId] as const));
        const specs = testableSystems(client.systems, hasAd, undefined, externalIdByName);
        await db.connectionTest.deleteMany({ where: { clientId: client.id } });
        if (specs.length === 0) continue;
        // Same row shape as the per-client path (optional secrets attached), but NEVER deep: a fleet
        // run must not fire an interactive M365 sign-in once per client, however it was triggered.
        const rows = specs.map((s) => connTestRow(client.id, s, client.secrets, "manual", false));
        await db.connectionTest.createMany({ data: rows });
        withTests++; total += rows.length; onPrem += rows.filter((r) => r.onPrem).length;
      }
      return { clients: withTests, tests: total, onPrem };
    },

    // Fleet roll-up: every connection-test result joined to its client, for the /health/connections page.
    async listAllConnectionTests() {
      const tests = await db.connectionTest.findMany({
        orderBy: [{ status: "asc" }, { clientId: "asc" }, { systemKey: "asc" }],
        select: { systemKey: true, status: true, detail: true, accessOk: true, accessDetail: true, fieldsOk: true, fieldsDetail: true, rights: true, credExpiresAt: true, source: true, onPrem: true, finishedAt: true, claimedAt: true, client: { select: { name: true, slug: true } } },
      });
      return tests;
    },

    async listConnectionTests(clientSlug: string) {
      const client = await db.client.findUnique({
        where: { slug: clientSlug },
        select: { id: true, systems: { select: { systemKey: true, mode: true, secretNames: true } }, secrets: { select: { name: true, externalId: true } } },
      });
      if (!client) throw new HttpError(404, `unknown client ${clientSlug}`);
      const tests = await db.connectionTest.findMany({
        where: { clientId: client.id },
        orderBy: { systemKey: "asc" },
        select: { systemKey: true, status: true, detail: true, accessOk: true, accessDetail: true, fieldsOk: true, fieldsDetail: true, rights: true, credExpiresAt: true, onPrem: true, finishedAt: true },
      });
      // Manual-step systems (every required secret marked NOT_NEEDED) are never dispatched, so they have
      // no real test row — surface them as read-only "not_needed" rows so the operator sees them
      // accounted for (N/A across the stages), not silently absent. A stale real row for a system that
      // has SINCE been marked not-needed is superseded by the synthetic row so it can't linger as a fail.
      const externalIdByName = new Map(client.secrets.map((s) => [s.name, s.externalId] as const));
      const hasAd = client.systems.some((s) => ALWAYS_ON_PREM_SYSTEMS.includes(s.systemKey));
      const notNeededSystems = client.systems.filter(
        (s) => s.mode === "api" && (s.secretNames?.length ?? 0) > 0 && isNotNeededForTest(s.secretNames, externalIdByName)
      );
      const notNeededKeys = new Set(notNeededSystems.map((s) => s.systemKey));
      const notNeededRows = notNeededSystems.map((s) => ({
        systemKey: s.systemKey,
        status: "not_needed",
        detail: null,
        accessOk: null,
        accessDetail: null,
        fieldsOk: null,
        fieldsDetail: null,
        rights: null,
        credExpiresAt: null,
        onPrem: systemIsOnPrem(s.systemKey, hasAd),
        finishedAt: null,
      }));
      const rows = [...tests.filter((t) => !notNeededKeys.has(t.systemKey)), ...notNeededRows].sort((a, b) =>
        a.systemKey.localeCompare(b.systemKey)
      );
      return { tests: rows };
    },

    // Atomic claim, same scope rule as job claim: a central runner (no clientId) takes only cloud
    // tests; a client agent takes its own client's (cloud + on-prem).
    async claimConnectionTests(agentId: string, max = 5): Promise<{ id: string; systemKey: string; secretNames: string[]; clientSlug: string; primaryDomain: string; config: unknown; deep: boolean }[]> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { id: true, enabled: true, clientId: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      if (!agent.enabled) return [];
      const where = { status: "pending", ...(agent.clientId ? { clientId: agent.clientId } : { onPrem: false }) };
      const candidates = await db.connectionTest.findMany({ where, orderBy: { requestedAt: "asc" }, take: Math.max(1, Math.min(25, max)), select: { id: true } });
      if (candidates.length === 0) return [];
      const ids = candidates.map((c) => c.id);
      await db.connectionTest.updateMany({ where: { id: { in: ids }, status: "pending" }, data: { status: "running", assignedAgentId: agent.id, claimedAt: new Date() } });
      const claimed = await db.connectionTest.findMany({
        where: { id: { in: ids }, assignedAgentId: agent.id, status: "running" },
        select: { id: true, systemKey: true, secretNames: true, optionalSecretNames: true, config: true, deep: true, client: { select: { slug: true, primaryDomain: true } } },
      });
      // Low-code connectors: hand the published definition to the conn-test probe the same way the
      // job claim does (config.connector), so a connector's `test` lane runs as its connection test.
      const testCustomKeys = [...new Set(claimed.map((t) => t.systemKey).filter((k) => k.startsWith("custom-")))];
      const testConnectors = testCustomKeys.length
        ? new Map(
            (
              await db.connector.findMany({ where: { key: { in: testCustomKeys }, status: "published" }, select: { key: true, kind: true, definition: true } })
            ).map((c) => [c.key, c])
          )
        : new Map<string, { key: string; kind: string; definition: unknown }>();
      // `deep` travels to the runner so an interactive probe (a real browser sign-in) runs ONLY on a
      // targeted single-system retest. There is deliberately no capability gate on the claim itself:
      // withholding the test from a browser-less agent would take the ordinary API check down with it.
      // The runner reports "browser not available on this agent" as an unverified rights row instead.
      return claimed.map((t) => {
        const cn = testConnectors.get(t.systemKey);
        const config = cn ? { ...((t.config as Record<string, unknown> | null) ?? {}), connector: { kind: cn.kind, definition: cn.definition } } : (t.config ?? null);
        return { id: t.id, systemKey: t.systemKey, secretNames: t.secretNames, optionalSecretNames: t.optionalSecretNames, clientSlug: t.client.slug, primaryDomain: t.client.primaryDomain, config, deep: t.deep };
      });
    },

    // Same push-down broker as a job, scoped to the test's own secretNames (no case overrides).
    // withOtp mints a CURRENT Delinea one-time password, mirroring the job path: a deep probe signs in
    // to a vendor portal for real, and its MFA code must be minted AT the prompt (a 30s TOTP cannot
    // survive browser launch + the SSO hop). The authenticator seed stays in the vault; we only ever
    // hold a code. Authorization is unchanged — the secret must still be one of the test's own.
    async brokerConnectionTestCredential(testId: string, agentId: string, secretName: string, withOtp = false): Promise<BrokeredCredential> {
      const t = await db.connectionTest.findUnique({ where: { id: testId }, select: { status: true, assignedAgentId: true, secretNames: true, optionalSecretNames: true, deep: true, clientId: true } });
      if (!t) throw new HttpError(404, "unknown connection test");
      if (t.assignedAgentId !== agentId) throw new HttpError(403, "connection test not assigned to this agent");
      await assertAgentEnabled(db, agentId);
      if (t.status !== "running") throw new HttpError(409, `connection test is ${t.status}; credentials only brokered while running`);
      if (!t.secretNames.includes(secretName) && !t.optionalSecretNames.includes(secretName)) throw new HttpError(403, `secret ${secretName} is not authorized for this connection test`);
      // Minting a live MFA code is only ever legitimate for an interactive probe, which only a deep
      // test runs. Enforce that HERE rather than trusting the runner to ask nicely: a bug (or a
      // compromised agent) must not be able to pull one-time passwords out of the vault on a routine
      // sweep. This is the server's own check, independent of anything the caller claims.
      if (withOtp && !t.deep) throw new HttpError(403, "a one-time password is only brokered for a deep (interactive) connection test");
      const clientSecret = await db.secret.findUnique({ where: { clientId_name: { clientId: t.clientId, name: secretName } }, select: { provider: true, externalId: true } });
      const { externalId, source } = effectiveExternalId(secretName, null, clientSecret?.externalId ?? null);
      if (source === "not_needed") throw new HttpError(409, `secret '${secretName}' is marked not needed (manual step) — nothing to test`);
      if (!externalId) throw new HttpError(404, `no usable secret reference '${secretName}' (set it on the client)`);
      const cfg = delineaConfigFromEnv();
      let brokered = false; let label: string | undefined; let fields: Record<string, string> | undefined;
      let note: string | undefined = "Delinea not configured on the app — set DELINEA_* so the app can resolve and push the credential";
      if (delineaConfigured(cfg)) {
        const resolved = await resolveSecretFields(cfg, externalId);
        if (!resolved.ok) throw new HttpError(502, `secret '${secretName}' is not resolvable in Delinea: ${resolved.error ?? "unknown error"}`);
        brokered = true; label = resolved.label; fields = resolved.fields; note = undefined;
      }
      let otpCode: string | undefined;
      let otpRemainingSeconds: number | undefined;
      let otpError: string | undefined;
      if (withOtp) {
        if (!delineaConfigured(cfg)) otpError = "Delinea not configured on the app";
        else {
          const otp = await getOneTimePasswordCode(cfg, externalId);
          if (otp.ok) { otpCode = otp.code; otpRemainingSeconds = otp.remainingSeconds; }
          else otpError = otp.error;
        }
      }
      // Metadata ONLY — field NAMES, never values, and never the OTP itself.
      await db.auditLog.create({ data: { actor: `agent:${agentId}`, action: "conntest.credential", clientId: t.clientId, detail: { secretName, brokered, fieldNames: fields ? Object.keys(fields) : [], ...(withOtp ? { otp: otpCode ? "minted" : `unavailable: ${otpError}` } : {}) } } });
      return { provider: clientSecret?.provider ?? "delinea", externalId, secretName, brokered, expiresInSeconds: 300, label, note, fields, otpCode, otpRemainingSeconds, otpError };
    },

    async reportConnectionTest(
      testId: string,
      agentId: string,
      ok: boolean,
      detail: string,
      accessOk: boolean | null = null,
      accessDetail: string | null = null,
      rights: RightsRow[] | null = null,
      credExpiresAt: Date | null = null
    ): Promise<{ ok: true }> {
      const t = await db.connectionTest.findUnique({ where: { id: testId }, select: { assignedAgentId: true, clientId: true, systemKey: true, source: true } });
      if (!t) throw new HttpError(404, "unknown connection test");
      if (t.assignedAgentId !== agentId) throw new HttpError(403, "connection test not assigned to this agent");
      // Overall status is a fail if EITHER stage failed (access couldn't resolve, or the API read failed).
      const passed = accessOk !== false && ok;
      const finishedAt = new Date();
      const trimmedDetail = (detail ?? "").slice(0, 500);
      await db.connectionTest.update({
        where: { id: testId },
        data: {
          status: passed ? "ok" : "fail",
          detail: trimmedDetail,
          accessOk,
          accessDetail: accessDetail === null ? null : accessDetail.slice(0, 500),
          // Optional extras from newer runners: per-operation rights rows + the credential's own
          // expiry when the probe could read it. Null-tolerant so older runners keep working.
          ...(rights ? { rights: rights as unknown as Prisma.InputJsonValue } : {}),
          ...(credExpiresAt ? { credExpiresAt } : {}),
          finishedAt,
        },
      });
      // Durable per-(client, system) health snapshot — ConnectionTest rows are deleted per run, so
      // new-failure detection and notification suppression live here. Only SWEEP-sourced new
      // failures queue a notification (the operator watches manual runs in the panel).
      try {
        const key = { clientId: t.clientId, systemKey: t.systemKey };
        const prev = await db.connHealthState.findUnique({ where: { clientId_systemKey: key }, select: { lastStatus: true } });
        const outcome = diffConnOutcome(prev, { passed });
        const common = {
          lastStatus: passed ? "ok" : "fail",
          lastDetail: trimmedDetail || null,
          ...(passed ? { lastOkAt: finishedAt } : { lastFailAt: finishedAt }),
          ...(credExpiresAt ? { credExpiresAt } : {}),
          ...(outcome === "new_failure" && t.source === "sweep" ? { pendingNotifyAt: finishedAt } : {}),
          ...(outcome === "recovered" ? { failNotifiedAt: null, pendingNotifyAt: null } : {}),
        };
        await db.connHealthState.upsert({ where: { clientId_systemKey: key }, update: common, create: { ...key, ...common } });
      } catch {
        // the snapshot is best-effort — never fail the result post over it
      }
      await db.auditLog.create({ data: { actor: `agent:${agentId}`, action: "conntest.result", clientId: t.clientId, detail: { systemKey: t.systemKey, accessOk, apiOk: ok, rightsMissing: rights ? rights.filter((r) => r.ok === false).length : undefined } } });
      return { ok: true };
    },

    // --- Cloud (Entra) group discovery -----------------------------------------------------------
    // Pull the tenant's groups (DLs / Security / M365 Groups) via the m365-admin secret so the group
    // pickers can offer cloud groups AD sync never sees. Like AD discovery (a request flag + a result
    // blob on the client), but claimed by the CENTRAL runner — it's the one with Graph.

    async requestCloudGroupDiscovery(clientSlug: string, actor: ActorInput = "ui"): Promise<{ ok: true }> {
      const client = await db.client.findUnique({
        where: { slug: clientSlug },
        select: { id: true, systems: { where: { systemKey: "m365" }, select: { secretNames: true } } },
      });
      if (!client) throw new HttpError(404, `unknown client ${clientSlug}`);
      if (client.systems.length === 0) throw new HttpError(422, "this client has no m365 system to read groups from");
      // Stamp WHO requested it so the central runner's result (cloud groups + mailboxes) is attributed
      // to the user, not "agent:<id>".
      await db.client.update({ where: { id: client.id }, data: { cloudGroupsRequestedAt: new Date(), cloudGroupsRequestedById: resolveActor(actor).userId } });
      return { ok: true };
    },

    // Central runner only. Claim every pending request, resolve its m365 secret(s) inline (push-down),
    // and clear the flag so it isn't claimed twice. Returns enough for the runner to connect + read.
    async claimCloudGroupDiscovery(agentId: string): Promise<{ clientSlug: string; primaryDomain: string; creds: Record<string, { fields?: Record<string, string>; note?: string }> }[]> {
      const agent = await db.agent.findUnique({ where: { id: agentId }, select: { enabled: true, clientId: true } });
      if (!agent) throw new HttpError(404, "unknown agent");
      if (!agent.enabled || agent.clientId) return []; // cloud groups come from the central (cloud) runner
      const pending = await db.client.findMany({
        where: { cloudGroupsRequestedAt: { not: null }, systems: { some: { systemKey: "m365" } } },
        select: { id: true, slug: true, primaryDomain: true, systems: { where: { systemKey: "m365" }, select: { secretNames: true } } },
        take: 5,
      });
      if (pending.length === 0) return [];
      // Claim: clear the flag now (so a second central runner won't re-claim). The runner reports back.
      await db.client.updateMany({ where: { id: { in: pending.map((c) => c.id) } }, data: { cloudGroupsRequestedAt: null } });
      const cfg = delineaConfigFromEnv();
      const out = [];
      for (const c of pending) {
        const names = c.systems[0]?.secretNames ?? [];
        const creds: Record<string, { fields?: Record<string, string>; note?: string }> = {};
        for (const name of names) {
          const sec = await db.secret.findUnique({ where: { clientId_name: { clientId: c.id, name } }, select: { externalId: true } });
          const { externalId } = effectiveExternalId(name, null, sec?.externalId ?? null);
          if (!externalId) { creds[name] = { note: "no usable secret reference" }; continue; }
          if (!delineaConfigured(cfg)) { creds[name] = { note: "Delinea not configured on the app" }; continue; }
          const resolved = await resolveSecretFields(cfg, externalId);
          creds[name] = resolved.ok ? { fields: resolved.fields } : { note: resolved.error ?? "unresolved" };
        }
        out.push({ clientSlug: c.slug, primaryDomain: c.primaryDomain, creds });
      }
      await db.auditLog.create({ data: { actor: `agent:${agentId}`, action: "cloudgroups.claim", detail: { clients: pending.map((c) => c.slug) } } });
      return out;
    },

    async reportCloudGroups(agentId: string, clientSlug: string, groups: { name: string; type: string }[]): Promise<{ ok: true; count: number }> {
      // Central-runner-only, no cross-client write — shared with reportCloudMailboxes.
      const clientId = await assertCentralAgentForClient(db, agentId, clientSlug, "cloud groups");
      // Normalize + cap (a big tenant can have thousands) so the picker payload stays sane.
      const clean = groups
        .filter((g) => g && typeof g.name === "string" && g.name.trim())
        .map((g) => ({ name: g.name.trim(), type: ["dl", "security", "m365"].includes(g.type) ? g.type : "security" }))
        .slice(0, 5000);
      const c = await db.client.update({ where: { id: clientId }, data: { cloudGroups: { groups: clean, discoveredAt: new Date().toISOString() } }, select: { cloudGroupsRequestedById: true } });
      await db.auditLog.create({ data: { actor: `agent:${agentId}`, userId: c.cloudGroupsRequestedById, action: "cloudgroups.result", clientId, detail: { count: clean.length, agentId } } });
      return { ok: true, count: clean.length };
    },

    // Shared mailboxes the central runner enumerated over Exchange Online alongside the cloud groups
    // (same discovery request). Stored on the client to back the "default shared-mailbox access" picker
    // (FR #15). Central-runner-only, exactly like reportCloudGroups — a client-network agent must not
    // be able to write another client's mailbox picker.
    async reportCloudMailboxes(agentId: string, clientSlug: string, mailboxes: { address: string; displayName?: string }[]): Promise<{ ok: true; count: number }> {
      // Central-runner-only, no cross-client write — same guard as reportCloudGroups.
      const clientId = await assertCentralAgentForClient(db, agentId, clientSlug, "cloud mailboxes");
      // Normalize (address is the identity the runner grants against) + dedupe by address + cap.
      const seen = new Set<string>();
      const clean = mailboxes
        .filter((m) => m && typeof m.address === "string" && m.address.trim())
        .map((m) => ({ address: m.address.trim(), displayName: typeof m.displayName === "string" ? m.displayName.trim() : "" }))
        .filter((m) => { const k = m.address.toLowerCase(); if (seen.has(k)) return false; seen.add(k); return true; })
        .slice(0, 5000);
      // Same discovery request as cloud groups → attribute to the same requesting user.
      const c = await db.client.update({ where: { id: clientId }, data: { cloudMailboxes: { mailboxes: clean, discoveredAt: new Date().toISOString() } }, select: { cloudGroupsRequestedById: true } });
      await db.auditLog.create({ data: { actor: `agent:${agentId}`, userId: c.cloudGroupsRequestedById, action: "cloudmailboxes.result", clientId, detail: { count: clean.length, agentId } } });
      return { ok: true, count: clean.length };
    },

    // Live progress: the runner posts the phase it's entering ("connecting to Exchange Online",
    // "enabling remote mailbox", …) as it works, so the run report can show what a step is doing
    // right now instead of an opaque "running". Best-effort + append-only (last 20), and only while
    // the job is in flight — a late post after the job finished is ignored, not an error.
    async recordProgress(jobId: string, agentId: string, phase?: string, stage?: string): Promise<{ ok: true }> {
      const job = await db.job.findUnique({ where: { id: jobId }, select: { status: true, assignedAgentId: true, progress: true } });
      if (!job) throw new HttpError(404, "unknown job");
      if (job.assignedAgentId !== agentId) throw new HttpError(403, "job not assigned to this agent");
      if (job.status !== "dispatched" && job.status !== "running") return { ok: true }; // job already done — drop
      // Stamp running on the first progress post so the case/step reflects in-flight immediately.
      // progressAt = the queryable "still working?" signal (the JSON trail can't be filtered on) — the
      // reclaim/stuck logic keys off this, NOT the agent heartbeat (the agent identity is reused, so a
      // restarted runner keeps the heartbeat green while the worker that owned THIS job is dead).
      const data: Prisma.JobUpdateInput = { status: "running", progressAt: new Date() };
      if (phase) {
        const trail = Array.isArray(job.progress) ? (job.progress as unknown[]) : [];
        data.progress = [...trail, { ts: new Date().toISOString(), phase: String(phase).slice(0, 200) }].slice(-20) as Prisma.InputJsonValue;
      }
      // A coarse setup-stage marker (signin|create|harvest|vault) lands on a SCALAR column, kept apart
      // from the free-text narration trail so the guided-setup run checklist reads one field to advance.
      if (stage) data.stage = String(stage).slice(0, 40);
      await db.job.update({ where: { id: jobId }, data });
      // A runner mid-step posts progress every second or two, but only the between-jobs heartbeat
      // loop refreshes lastSeenAt — so a long step (an Exchange mailbox/DL mirror can run minutes)
      // would read "offline" while it's actively working. Treat a progress post as a heartbeat too:
      // a runner that's narrating its work IS alive. It now reads offline only when GENUINELY stuck
      // (no progress for the offline window) — which is the alarm we actually want.
      await db.agent.update({ where: { id: agentId }, data: { lastSeenAt: new Date() } });
      return { ok: true };
    },

    // Operator "Stop": abort an in-flight (or queued) step that looks wedged — mark it failed so the
    // case stops waiting on it (and its still-pending siblings are cancelled). A late result the runner
    // eventually posts is rejected by recordResult's terminal guard (409), so the Stop holds.
    async stopJob(jobId: string, actor: ActorInput): Promise<{ jobId: string; status: string; caseStatus: string }> {
      const job = await db.job.findUnique({ where: { id: jobId }, select: { status: true, caseRequestId: true, systemKey: true, case: { select: { clientId: true } } } });
      if (!job) throw new HttpError(404, "unknown job");
      if (!["pending", "dispatched", "running"].includes(job.status)) {
        throw new HttpError(409, `job is ${job.status} — only an in-flight or queued step can be stopped`);
      }
      const by = resolveActor(actor);
      const who = by.actor.startsWith("user:") ? by.actor.slice(5) : "an operator";
      // oneTimePassword: a stopped password reset may or may not have landed — the value is unverified,
      // so wipe it (same as a failed result); null is a no-op for every other job type.
      await db.job.update({ where: { id: jobId }, data: { status: "failed", error: `stopped by ${who} — the step was not progressing`, finishedAt: new Date(), oneTimePassword: null } });
      const caseStatus = await refreshCaseStatus(db, job.caseRequestId);
      await db.auditLog.create({ data: { actor: by.actor, userId: by.userId, action: "job.stop", jobId, caseRequestId: job.caseRequestId, clientId: job.case.clientId, detail: { systemKey: job.systemKey } } });
      // Operator stops bypass recordResult (the runner never posts a result), so without this the
      // stopped step never reaches the /runs log. Never fatal to the stop itself.
      try {
        const full = await db.caseRequest.findUnique({ where: { id: job.caseRequestId }, select: { serviceNowCaseNumber: true, action: true, clientId: true, client: { select: { name: true } } } });
        if (full) {
          const error = `stopped by ${who} — the step was not progressing`;
          const fingerprint = outcomeFingerprint({ caseRequestId: job.caseRequestId, systemKey: job.systemKey, verdict: "failed", messages: [], error });
          await db.runOutcome.create({ data: {
            caseRequestId: job.caseRequestId, caseNumber: full.serviceNowCaseNumber ?? job.caseRequestId, action: full.action,
            clientId: full.clientId, clientName: full.client.name, systemKey: job.systemKey,
            verdict: "failed", status: "failed", messages: [], error, fingerprint,
          } });
        }
      } catch { /* outcome logging must not fail the stop */ }
      return { jobId, status: "failed", caseStatus };
    },

    // Record a job result, advance the case, audit, and queue a work note. The posting agent
    // must own the job; a repeat of the same terminal result is an idempotent no-op.
    async recordResult(jobId: string, agentId: string, input: ResultInput): Promise<{ jobId: string; status: string; caseStatus: string }> {
      const job = await db.job.findUnique({ where: { id: jobId }, select: { status: true, caseRequestId: true, systemKey: true, assignedAgentId: true, singleRun: true, request: true, credFailure: true, case: { select: { clientId: true, serviceNowCaseNumber: true, action: true, client: { select: { name: true, restricted: true, notifyOverride: true } } } } } });
      if (!job) throw new HttpError(404, "unknown job");
      if (job.assignedAgentId !== agentId) throw new HttpError(403, "job not assigned to this agent");
      await assertAgentEnabled(db, agentId);

      // Unwrap a pipeline-leaked array result BEFORE anything reads or stores it — one stray
      // emission in an executor otherwise blanks every downstream reader (see lib/jobs/job-result.ts).
      const result = jobResultEnvelope(input.result);

      // OFFBOARD TARGET AMBIGUITY. An executor that cannot tell WHICH person to offboard (the name on
      // the ticket matched several users, or none) returns the shortlist it found rather than acting.
      // Such a result must NEVER be recorded as a success: it used to come back 'ok' with a WARN, which
      // let the case march to "completed" with the account still live. Force it to a decision: the step
      // fails with a DECISION_NEEDED marker (the same convention the username-collision flow uses), and
      // the case is HELD so an operator picks the right user and re-runs. The candidates ride along in
      // Job.result for the picker to render.
      const candidates = offboardCandidatesOf(result);
      const needsTargetDecision = input.status === "succeeded" && candidates.length > 0 && job.case.action === "offboard";

      const status = needsTargetDecision ? "failed" : input.status === "succeeded" ? "succeeded" : input.status === "skipped" ? "skipped" : "failed";
      if (job.status !== "dispatched" && job.status !== "running") {
        // idempotent: a lost-ack retry of the same outcome succeeds; a conflicting re-post 409s.
        if (job.status === status) {
          const cs = await db.caseRequest.findUnique({ where: { id: job.caseRequestId }, select: { status: true } });
          return { jobId, status, caseStatus: cs?.status ?? "unknown" };
        }
        throw new HttpError(409, `job already ${job.status}`);
      }

      await db.job.update({
        where: { id: jobId },
        data: {
          status, result: (result ?? undefined) as Prisma.InputJsonValue | undefined, evidence: (input.evidence ?? undefined) as Prisma.InputJsonValue | undefined, validation: (input.validation ?? undefined) as Prisma.InputJsonValue | undefined,
          error: needsTargetDecision ? offboardDecisionError(result, candidates.length) : (input.error ?? null),
          finishedAt: new Date(), singleRun: false,
          // A password reset that didn't land never shows its value — wipe it so a plaintext that was
          // never set on the account can't linger. A GENERATED reset keeps its value on success until
          // the one-time reveal; a MANUAL one (FR #17) is never revealed (the operator already has it),
          // so wipe it on any terminal state — a reused human passphrase must not linger or stay
          // revealable via the reset line's reveal button.
          ...(PASSWORD_RESET_SYSTEM_KEYS.includes(job.systemKey) && (status !== "succeeded" || (job.request as Record<string, unknown> | null)?.manualPassword === true) ? { oneTimePassword: null } : {}),
        },
      });

      const isAdhoc = ADHOC_SYSTEM_KEYS.includes(job.systemKey);
      // AUTO-RETRY: a succeeded result carrying RetryAfterMinutes (e.g. Spanning/Mimecast "user not
      // discovered yet") schedules its own re-run; sweepAutoRetries re-queues it when due. A result
      // WITHOUT the marker clears any schedule (the wait is over) and audits the elapsed time. This
      // runs for the normal cascade AND for an ad-hoc singleRun action whose result says "queued, not
      // done" (the force-sync's promised re-poll) — but NOT for a plain "run this step only" of a
      // normal step, which intentionally doesn't reschedule.
      // Set when THIS result scheduled another wait: the step is benignly "retrying", not broken, so
      // it must not raise a chat alert or a run-log warning line (see the notify + outcome blocks
      // below). An EXHAUSTED retry is the opposite — the wait is over and it never resolved, so it
      // falls through as a normal warning and the operator finally sees it.
      let retryScheduled = false;
      if (status === "succeeded" && !req(job).validateOnly && (!job.singleRun || isAdhoc)) {
        const marker = (result ?? {}) as { RetryAfterMinutes?: unknown; retryAfterMinutes?: unknown };
        const mins = Number(marker.RetryAfterMinutes ?? marker.retryAfterMinutes ?? 0);
        const reqJson = { ...(job.request as Record<string, unknown> ?? {}) };
        const decision = decideAutoRetry((reqJson.autoRetry ?? null) as AutoRetryMarker | null, mins, Date.now());
        if (decision.kind === "scheduled") {
          reqJson.autoRetry = decision.marker;
          await db.job.update({ where: { id: jobId }, data: { request: reqJson as Prisma.InputJsonValue } });
          retryScheduled = true;
        } else if (decision.kind !== "none") {
          delete reqJson.autoRetry;
          await db.job.update({ where: { id: jobId }, data: { request: reqJson as Prisma.InputJsonValue } });
          // "exhausted" = we gave up: the vendor never caught up. Usually because the upstream work
          // never really landed (an M365 user created UNLICENSED has no mailbox, so Spanning/Mimecast
          // will never discover them — waiting longer cannot help). It now falls through as a warning.
          const action = decision.kind === "resolved" ? "job.autoretry.resolved" : "job.autoretry.exhausted";
          await db.auditLog.create({ data: { actor: "system:auto-retry", action, jobId, caseRequestId: job.caseRequestId, detail: { attempts: decision.attempts, elapsedMinutes: decision.elapsedMinutes } } });
        }
      }

      // FR #5: an m365/entra onboard that SUCCEEDED but left the user UNLICENSED (seat shortage is a
      // WARN, not a failure) cannot feed the license-dependent systems — an unlicensed user has no
      // mailbox, so Mimecast/Spanning would never discover them and would burn their entire ~4h retry
      // budget on a guaranteed failure. Hold those siblings; a later licensed re-run clears the hold
      // (the license-picker → re-run path), and the claim gate dispatches them then.
      if (!req(job).validateOnly && job.case.action === "onboard" && (job.systemKey === "m365" || job.systemKey === "entra") && status === "succeeded") {
        const res = (result ?? {}) as { SeatShortage?: unknown; seatShortage?: unknown; AvailableLicenses?: unknown };
        // Older runners don't send the explicit flag; the inventory is only ever returned on shortage.
        const shortage = res.SeatShortage === true || res.seatShortage === true
          || (Array.isArray(res.AvailableLicenses) && res.AvailableLicenses.length > 0);
        // Only the lane that OWNS licensing may RELEASE a hold: when a client models both m365 and
        // entra, the licence-less sibling lane also succeeds (shortage=false, trivially) and would
        // otherwise free mimecast/spanning while the user is still unlicensed. Setting a hold has
        // no such risk — a shortage report is authoritative whichever lane saw it.
        const jobCfg = (req(job).config ?? {}) as { licenses?: unknown; defaultLicenses?: unknown };
        const ownsLicensing = (Array.isArray(jobCfg.licenses) && jobCfg.licenses.length > 0)
          || (Array.isArray(jobCfg.defaultLicenses) && jobCfg.defaultLicenses.length > 0);
        const dependents = await db.job.findMany({
          where: { caseRequestId: job.caseRequestId, systemKey: { in: LICENSE_DEPENDENT_SYSTEMS }, status: "pending" },
          select: { id: true, systemKey: true, request: true },
        });
        const flipped: string[] = [];
        for (const s of dependents) {
          const reqJson = { ...((s.request ?? {}) as Record<string, unknown>) };
          const held = typeof reqJson.hold === "string";
          if (shortage && !held) {
            reqJson.hold = "waiting for an M365 license — the user was created unlicensed (no free seats). Pick a license on the m365 step and re-run it; this step then proceeds on its own.";
            await db.job.update({ where: { id: s.id }, data: { request: reqJson as Prisma.InputJsonValue } });
            flipped.push(s.systemKey);
          } else if (!shortage && held && ownsLicensing) {
            delete reqJson.hold;
            await db.job.update({ where: { id: s.id }, data: { request: reqJson as Prisma.InputJsonValue } });
            flipped.push(s.systemKey);
          }
        }
        if (flipped.length) {
          await db.auditLog.create({ data: { actor: "system", action: shortage ? "job.hold.license" : "job.hold.release", jobId, caseRequestId: job.caseRequestId, clientId: job.case.clientId, detail: { systems: flipped } } });
        }
      }

      // "Run this step only" (and ad-hoc actions) record the outcome but do NOT cascade the CASE — no
      // case-status advance, no auto-verify sweep. The case stays paused; the operator resumes to
      // continue the normal run. (The shared outcome log + work-note below still run for both paths.)
      let caseStatus: string;
      if (job.singleRun) {
        const cs = await db.caseRequest.findUnique({ where: { id: job.caseRequestId }, select: { status: true } });
        caseStatus = cs?.status ?? "unknown";
      } else {
      const derived = await caseStatusFrom(db, job.caseRequestId);
      const caseJobs = derived.caseJobs;
      caseStatus = derived.caseStatus;
      // On case failure, quiesce the still-pending case work (skip ordinary steps, roll queued
      // verify jobs back to their pre-verify state, leave operator side-actions alone) — one shared
      // sweep, so this and refreshCaseStatus can never drift apart. See sweepPendingCaseWork.
      if (caseStatus === "failed") await sweepPendingCaseWork(db, job.caseRequestId, caseJobs);

      // Auto-verify: when the automated work first finishes, run a read-only validation sweep across
      // every step (re-run each Confirm-Ctg*) once — confirming accounts/licensing/mirroring/access
      // all landed after everything settled — before the case is "done" and the operator resolves it.
      // validateOnly = the sweep itself; verifiedAt guards against looping.
      if (caseStatus === "completed") {
        const cr = await db.caseRequest.findUnique({ where: { id: job.caseRequestId }, select: { verifiedAt: true } });
        if (!cr?.verifiedAt) {
          const thisJob = caseJobs.find((j) => j.id === jobId);
          const thisWasVerify = Boolean(thisJob && req(thisJob).validateOnly);
          if (thisWasVerify) {
            await db.caseRequest.update({ where: { id: job.caseRequestId }, data: { verifiedAt: new Date() } });
          } else {
            // Re-validate every succeeded automated step that has a validator (skip servicenow/case-resolution).
            const sweep = caseJobs.filter((j) => j.mode === "api" && j.status === "succeeded" && !["servicenow", "case-resolution", ...ADHOC_SYSTEM_KEYS].includes(j.systemKey));
            if (sweep.length) {
              await db.$transaction(sweep.map((j) => {
                // Stamp the rollback markers EXACTLY like verifyCase does — without them an
                // interrupted auto-verify pass rolled real successes back to "skipped" (the
                // legacy fallback), the very bug the rollback exists to prevent. Stale stamps
                // from an earlier pass are dropped first so they can't resurrect an old state.
                const r = { ...((j.request ?? {}) as Record<string, unknown>) };
                delete r.priorStatus; delete r.priorError; delete r.priorValidation;
                r.validateOnly = true;
                r.priorStatus = j.status; // always "succeeded" here (the sweep filters on it)
                if (j.validation) r.priorValidation = j.validation;
                return db.job.update({ where: { id: j.id }, data: { status: "pending", assignedAgentId: null, validation: Prisma.DbNull, progress: Prisma.DbNull, error: null, finishedAt: null, request: r as Prisma.InputJsonValue } });
              }));
              caseStatus = "running"; // verifying
              await db.auditLog.create({ data: { actor: "system", action: "case.auto_verify", caseRequestId: job.caseRequestId, detail: { steps: sweep.length } } });
            } else {
              await db.caseRequest.update({ where: { id: job.caseRequestId }, data: { verifiedAt: new Date() } });
            }
          }
        }
      }
      await db.caseRequest.update({ where: { id: job.caseRequestId }, data: { status: caseStatus as CaseStatus } });
      } // end normal (non-single-step) cascade

      // HOLD the case on an unresolved offboard target. This is the ONE place a runner RESULT can pause
      // a case (everything else that holds does so at import/plan time) — without it the operator would
      // have to notice a failed step, rather than the case telling them it needs a decision. Held even
      // for a single-step run: whoever picks the user is choosing who gets locked out.
      if (needsTargetDecision) {
        await db.caseRequest.update({
          where: { id: job.caseRequestId },
          data: { pausedAt: new Date(), pausedReason: "needs_info", scheduledFor: null },
        });
        await db.auditLog.create({
          data: { actor: "system", action: "case.offboard_target.ambiguous", jobId, caseRequestId: job.caseRequestId, clientId: job.case.clientId, detail: { systemKey: job.systemKey, candidates: candidates.length, query: offboardCandidateQuery(result) } },
        });
      }

      // A NEW real result after a case-level warning dismissal (FR #13) re-opens the case's
      // warnings: fresh problems must not hide behind an old "I finished it by hand" stamp — the
      // same resurfacing rule the run log applies to "Fixed" lines. Ad-hoc actions (password reset,
      // force-sync) are NOT case work and must not resurface answered warnings.
      if (!req(job).validateOnly && !isAdhoc) {
        await db.caseRequest.updateMany({
          where: { id: job.caseRequestId, warningsDismissedAt: { not: null } },
          data: { warningsDismissedAt: null, warningsDismissedBy: null },
        });
      }

      await db.auditLog.create({ data: { actor: `agent:${job.assignedAgentId ?? "unknown"}`, action: job.singleRun ? "job.result.single" : "job.result", jobId, caseRequestId: job.caseRequestId, clientId: job.case.clientId, detail: { status, error: input.error ?? null } } });

      // The run-report verdict for THIS result: "failed", or "warning" when the step succeeded but its
      // validation read-back missed. Computed once here and reused by both the notify block below and
      // the outcome log — a warning is a real problem an operator must see, so it notifies too.
      const { verdict, messages } = jobOutcome(status, result, input.validation, input.error ?? null);

      // Failure notifications — best-effort + awaited (the sender is timeout-bounded, so it can't hang
      // the result path). Step-level alerts (failed/warning) fire for single-step re-runs too — a re-run
      // is the usual way an operator retries a broken step, and its failure must not go silent. Only the
      // normal cascade produces a meaningful new CASE status, so case-level alerts stay gated on it.
      {
        const caseNumber = job.case.serviceNowCaseNumber;
        const clientName = job.case.client?.name ?? null;
        const restricted = job.case.client?.restricted ?? false;
        const override = parseClientOverride(job.case.client?.notifyOverride);
        const url = process.env.APP_PUBLIC_URL ? `${process.env.APP_PUBLIC_URL}/cases/${job.caseRequestId}` : null;
        const who = `${caseNumber ?? job.caseRequestId}${clientName ? ` (${clientName})` : ""}`;
        // Who kicked off the run that led here — the most recent operator "run" action on this case
        // (resume/re-run/verify/import). Null when auth is off or the case ran unattended.
        const runAudit = await db.auditLog.findFirst({
          where: { caseRequestId: job.caseRequestId, action: { in: ["case.plan", "job.rerun", "case.verify", "case.resume", "case.dry_run.set"] }, actor: { startsWith: "user:" } },
          orderBy: { at: "desc" },
          select: { actor: true },
        });
        const actor = runAudit?.actor ? runAudit.actor.replace(/^user:/, "") : null;
        const at = new Date().toISOString();
        // A licence removed off an UNCONVERTED mailbox is a DECIDED outcome (client opt-out or an
        // operator's picker answer) — the step lands verified-green, no WARN, by the "decided is not
        // unresolved" rule. But it starts Exchange's irreversible 30-day purge clock, and that must
        // reach chat rather than live only inside the case: whoever needs the mail archived has 30
        // days, starting now, whether or not anyone re-opens the run report.
        // mailboxPurgeLines only matches when a licence actually came off IN THIS RUN (the "freed N"
        // signal), so idempotent re-runs and group-inherited rejections don't re-alert; the
        // !retryScheduled guard mirrors stepWarning — an auto-retrying step must not spam per attempt.
        const purge = status === "succeeded" && !retryScheduled ? mailboxPurgeLines(result) : [];
        if (purge.length) {
          await fireNotification({ event: "mailboxPurge", title: `Mailbox purge scheduled: ${job.systemKey} — ${who}`, caseNumber, clientName, restricted, override, systemKey: job.systemKey, actor, at, detail: purge.join("\n"), url });
        }
        if (status === "failed") {
          await fireNotification({ event: "stepFailed", title: `Step failed: ${job.systemKey} — ${who}`, caseNumber, clientName, restricted, override, systemKey: job.systemKey, actor, at, detail: input.error ?? null, url });
        } else if (verdict === "warning" && !retryScheduled) {
          // Succeeded, but the read-back didn't confirm the change. Surfaced on /runs — now in chat too.
          // NOT while a retry is scheduled: the step is deliberately waiting on a vendor sync it told us
          // to wait for, so its "miss" is expected. Alerting there cried wolf every 15 minutes for a
          // step that self-heals. If the retries run out, the wait is over and this fires for real.
          await fireNotification({ event: "stepWarning", title: `Step warning: ${job.systemKey} — ${who}`, caseNumber, clientName, restricted, override, systemKey: job.systemKey, actor, at, detail: messages.length ? messages.join("\n") : "The step reported success but its validation read-back did not confirm the change.", url });
        }
        // Case-level alerts only make sense off the normal cascade (a single-step re-run doesn't
        // recompute a meaningful case status).
        if (!job.singleRun) {
          if (caseStatus === "failed") {
            await fireNotification({ event: "caseFailed", title: `Case failed: ${who}`, caseNumber, clientName, restricted, override, systemKey: job.systemKey, actor, at, detail: input.error ?? null, url });
          } else if (caseStatus === "needs_approval") {
            await fireNotification({ event: "needsApproval", title: `Case needs approval: ${who}`, caseNumber, clientName, restricted, override, actor, at, detail: "A destructive offboard step is waiting for approval.", url });
          }
        }
      }

      // Append-only outcome log: capture this run's success/warning/error per module, with the case
      // number + client + messages, so module problems can be tracked across cases (a re-run
      // overwrites the Job, but each result still lands here). Never fatal to result recording.
      //
      // A step that scheduled its own retry writes NO row: it is waiting on a vendor sync, exactly as
      // designed, and the run report already shows it as "retrying" (run-report.ts). Logging it filled
      // /runs with "validation missed: <vendor> user present" lines for steps that were about to fix
      // themselves — one per attempt, every 15 minutes. When the retries are exhausted the wait is
      // over, retryScheduled is false, and the (now genuine) warning is logged.
      if (!retryScheduled) try {
        const fingerprint = outcomeFingerprint({ caseRequestId: job.caseRequestId, systemKey: job.systemKey, verdict, messages, error: input.error ?? null });
        // A NEW occurrence is never born resolved.
        //
        // This used to inherit a prior "Fixed" for the same fingerprint, so a re-run of an
        // already-handled line wouldn't reappear. The reasoning was that "a genuinely new error has a
        // new fingerprint and won't match" — but the inverse is the problem: an IDENTICAL fingerprint
        // means the identical problem happened AGAIN, which is the one fact that proves it was not
        // fixed. Inheriting hid exactly that. "Fixed" is a display action with no verification behind
        // it, and this turned one click into a permanent silence: every future occurrence was born
        // hidden and uncounted (outcomes-repo.ts:95), so the step could keep failing forever and
        // /runs would never say so.
        //
        // UM0029796 is what this looked like: an operator marked entra's "MFA methods NOT removed" and
        // "license KEPT" warnings Fixed at 21:00 while closing the case. Neither was fixed — the
        // permission is still missing and the seat is still assigned — and any re-run would have been
        // silently pre-resolved.
        //
        // Now a recurrence resurfaces, which is what makes "Fixed" honest: it dismisses what you have
        // seen, and the problem coming back tells you the truth. This costs no noise — a step that is
        // genuinely fixed stops emitting the message, which changes the fingerprint (it hashes the
        // messages), so it simply never matches again. Steps waiting on their own retry are already
        // excluded above and never reach here. Marking one line Fixed still resolves every EXISTING
        // occurrence of that fingerprint; that dedupe of history is unchanged.
        await db.runOutcome.create({
          data: {
            caseRequestId: job.caseRequestId,
            caseNumber: job.case.serviceNowCaseNumber ?? job.caseRequestId,
            action: job.case.action,
            clientId: job.case.clientId,
            clientName: job.case.client.name,
            systemKey: job.systemKey,
            verdict, status, messages,
            error: input.error ?? null,
            validateOnly: Boolean(req(job).validateOnly),
            // The broker's structured "why the credential failed" rides along on problem rows only —
            // /runs and remediation scripts key off credFailure.code instead of parsing error text.
            ...(job.credFailure && (verdict === "failed" || verdict === "warning")
              ? { credFailure: job.credFailure as Prisma.InputJsonValue }
              : {}),
            fingerprint,
          },
        });
      } catch { /* an outcome-log failure must never lose the job result */ }
      // Work-note write-back (RUNNER_PROTOCOL): append a note to the UM ticket. postWorkNote
      // resolves the number -> sys_id and PATCHes work_notes; it's gated by SN_WRITE_ENABLED and
      // never fatal to result recording (a ServiceNow outage must not lose the job result).
      const caseNumber = job.case.serviceNowCaseNumber;
      const note = `${job.systemKey}: ${status}${input.error ? ` — ${input.error}` : ""}`;
      if (caseNumber && writeBackEnabled()) {
        try {
          const wn = await postWorkNote(snConfigFromEnv(), caseNumber, note);
          await db.auditLog.create({ data: { actor: "system", action: wn.ok ? "servicenow.worknote" : "servicenow.worknote.failed", caseRequestId: job.caseRequestId, detail: { caseNumber, note, ...(wn.ok ? { sysId: wn.sysId } : { error: wn.error }) } } });
        } catch (e) {
          await db.auditLog.create({ data: { actor: "system", action: "servicenow.worknote.failed", caseRequestId: job.caseRequestId, detail: { caseNumber, note, error: (e as Error).message } } });
        }
      } else {
        // Write-back disabled or no SN number: record the note we would have posted.
        await db.auditLog.create({ data: { actor: "system", action: "servicenow.worknote.pending", caseRequestId: job.caseRequestId, detail: { caseNumber, note } } });
      }

      return { jobId, status, caseStatus };
    },

    // Release an approval-gated job so it can be claimed. Gate is enforced here (server-side),
    // per CLAUDE.md: destructive steps need a recorded approval before dispatch.
    async approveJob(jobId: string, approvedBy: ActorInput): Promise<{ jobId: string; caseStatus: string }> {
      const job = await db.job.findUnique({ where: { id: jobId }, select: { status: true, caseRequestId: true, request: true, case: { select: { clientId: true } } } });
      if (!job) throw new HttpError(404, "unknown job");
      const r = req(job);
      if (!r.requiresApproval) throw new HttpError(409, "job does not require approval");
      if (job.status !== "pending") throw new HttpError(409, `job is ${job.status}; only a pending job can be approved`);

      await db.job.update({ where: { id: jobId }, data: { request: { ...r, approved: true } as Prisma.InputJsonValue } });
      const { caseStatus } = await caseStatusFrom(db, job.caseRequestId);
      await db.caseRequest.update({ where: { id: job.caseRequestId }, data: { status: caseStatus } });
      const by = resolveActor(approvedBy);
      await db.auditLog.create({ data: { actor: by.actor, userId: by.userId, action: "job.approve", jobId, caseRequestId: job.caseRequestId, clientId: job.case.clientId, detail: { approvedBy: by.actor } } });
      return { jobId, caseStatus };
    },
  };
}

export type RunnerService = ReturnType<typeof makeRunnerService>;
