// Plan a case into Job rows. Reuses the existing orchestrator (lib/orchestrator.planCase)
// for lane filtering + topo-sort; this service persists the result and sets case status.
import type { CaseStatus } from "@prisma/client";
import { planCase, type PlannedJob } from "../orchestrator";
import { deriveIdentity } from "../servicenow/intake-mapper";
import { matchIntakeRule } from "../profiles/intake-rules";
import type { CaseRepository } from "./repository";
import type { NewCaseInput } from "./types";
import type { ResolveClient } from "../clients/email-domain";
import { resolvePlannedConfigs, personaSystemKeys } from "../profiles/plan-resolve";
import { resolveUnknownsWithAI } from "./ai-resolve";
import { autoOffboardScheduleAt, offboardTargetResolved } from "./schedule";
import { resolveActor, type ActorInput } from "../auth/actor";
import { unmodeledManualSteps } from "./unmodeled-steps";
import { documentedRank, inDocumentedOrder, mergeInDocumentedOrder } from "./documented-order";

export type PlanOutcome = {
  caseId: string;
  status: CaseStatus;
  jobCount: number;
  manualCount: number;
  approvalCount: number;
};

// Thrown when a case is created for a client marked "do not use engine". Enforced HERE, at the one
// layer every creation path funnels through (SN import, the intake sweep, and the "New case" form),
// so no caller can plan a case for a client the engine is supposed to leave alone.
export class EngineOptOutError extends Error {
  constructor(public readonly clientSlug: string) {
    super(`this client is marked "do not use engine" — the engine doesn't create cases for it`);
    this.name = "EngineOptOutError";
  }
}

// Derive the case's post-planning status from the planned jobs.
export function deriveStatus(jobs: PlannedJob[]): CaseStatus {
  if (jobs.some((j) => j.requiresApproval)) return "needs_approval";
  if (jobs.some((j) => j.mode === "api")) return "queued"; // ready to dispatch (no runners yet)
  return "needs_manual"; // only manual/browser steps
}

export async function createAndPlanCase(
  repo: CaseRepository,
  input: NewCaseInput,
  // An AuditActor (label + User FK) when an operator opened this; a bare string for genuine system
  // callers ("system:intake-poll", "cli:sim"). A string can't carry a userId — that's the point.
  actor: ActorInput,
  // Optional: resolve the email/UPN domain from the client's ServiceNow contacts (+ per-case
  // override). When omitted (e.g. manual cases) the cached emailDomain or website domain is used.
  opts?: { resolveDomain?: (client: ResolveClient) => Promise<string> }
): Promise<PlanOutcome> {
  const client = await repo.clientForPlanning(input.clientSlug);
  if (!client) throw new Error(`client not found: ${input.clientSlug}`);
  if (client.engineOptOut) throw new EngineOptOutError(input.clientSlug);

  // For onboarding, derive the user's identity (UPN/SamAccountName/work email) from the client's
  // username pattern + EMAIL domain so the runner modules receive ready-to-use fields. Prefer the
  // contact-derived emailDomain over the website-derived primaryDomain; a resolver (when supplied)
  // refreshes it from contacts and applies any per-case override. Offboarding identifies an
  // existing user, so no derivation is needed.
  const identity = (client.identity ?? {}) as { usernamePatterns?: string[] | null };
  // Offboarding identifies an EXISTING user — the executors resolve them by UPN/email when the
  // intake carries one, else by DISPLAY NAME against the live directory (more reliable than guessing
  // a UPN from a username pattern). So no identity derivation here for offboard.
  let domain = client.emailDomain ?? client.primaryDomain;
  if (input.action === "onboard" && opts?.resolveDomain) domain = await opts.resolveDomain(client);
  // Per-contact intake rule (FR #0000019): a configured requester forces the domain and skips systems.
  const intakeRule = input.action === "onboard"
    ? matchIntakeRule((client as { intakeRules?: unknown }).intakeRules, input.payload as Record<string, unknown>)
    : null;
  if (intakeRule?.forceDomain) domain = intakeRule.forceDomain;
  let payload =
    input.action === "onboard"
      ? deriveIdentity(input.payload, {
          usernamePatterns: identity.usernamePatterns ?? null,
          primaryDomain: domain,
        })
      : input.payload;
  if (intakeRule) payload = { ...payload, __intakeRule: { id: intakeRule.id, label: intakeRule.label } };

  // LLM last resort: before holding the case for unknowns, let the AI take a confident guess at the
  // fields the deterministic mapping couldn't resolve (marked AI-derived for an operator to confirm).
  if (input.action === "onboard" && Array.isArray((payload as { unknownFields?: unknown }).unknownFields) && (payload as { unknownFields: unknown[] }).unknownFields.length > 0) {
    const ai = await resolveUnknownsWithAI(payload as Record<string, unknown>);
    payload = ai.payload;
  }

  // Plan, then (for v2.1 clients) flatten persona/globals/location config into each onboard job.
  // Steps follow the runbook's documented order wherever their dependencies allow (FR #0000178).
  const rank = documentedRank(await repo.documentedSections(client.id, input.action));
  const plannedSystems = resolvePlannedConfigs(client, payload, input.action,
    planCase(inDocumentedOrder(client.systems, rank), input.action, payload, personaSystemKeys(client, payload, input.action),
      new Set(client.notNeededSecrets), new Set(client.wiredOptionalSecrets), intakeRule?.skipSystems, client.backbone));
  // Unmodeled runbook sections become manual checklist steps (FR #0000096), placed where the runbook
  // lists them — they depend on nothing and nothing depends on them, so the automated order is untouched.
  const planned = mergeInDocumentedOrder(plannedSystems, unmodeledManualSteps(
    await repo.unmodeledSections(client.id, input.action),
    plannedSystems.reduce((m, j) => Math.max(m, j.sequence), -1) + 1,
  ), rank);
  const status = deriveStatus(planned);
  const who = resolveActor(actor);
  const creator = { label: who.actor, userId: who.userId };
  const caseId = await repo.createCaseWithJobs({ ...input, payload }, client.id, planned, status, creator);

  // Creation is its own audit event, distinct from case.plan. Before this, "who opened this case?"
  // could only be inferred from the case.plan row that happens to be written in the same breath —
  // an inference that silently breaks the moment a case is created without being planned.
  await repo.writeAudit({
    actor: who.actor,
    userId: who.userId,
    action: "case.create",
    clientId: client.id,
    caseRequestId: caseId,
    detail: {
      action: input.action,
      source: input.source ?? "manual",
      serviceNowCaseNumber: input.serviceNowCaseNumber ?? null,
      subject: input.subject ?? null,
      dryRun: input.dryRun ?? false,
      intakeRule: intakeRule ? { id: intakeRule.id, label: intakeRule.label } : null,
    },
  });

  // Every imported case is HELD on import — nothing auto-dispatches. An operator reviews it and
  // resumes to run (and is recorded as the case's "ran by"). The hold reason is the most specific
  // one that applies:
  //   - needs_info: the intake left fields we couldn't determine — fill them in to release it.
  //   - scheduled:  an offboard that may be future-dated — resume when the offboard date arrives.
  //   - review:     anything else (a ready onboard) — a generic "review & run" hold.
  // A dry-run preview is exempt — the operator wants to see it run read-only now.
  let scheduledFor: Date | null = null;
  const unknownFields = Array.isArray((payload as { unknownFields?: unknown }).unknownFields) ? (payload as { unknownFields: unknown[] }).unknownFields : [];
  if (input.action === "onboard" && unknownFields.length > 0) {
    await repo.setHold(caseId, "needs_info");
  } else if (!input.dryRun) {
    if (input.action === "offboard") {
      // An offboard whose intake carries a real termination INSTANT (u_end_date with a time) releases
      // itself 5 minutes after it — the sweep (sweepScheduledCases) clears the hold when it comes due.
      //
      // But auto-release removes the human who used to eyeball every offboard before it ran, so it is
      // gated on the intake naming WHO is leaving. `needs_info` only ever applied to onboards, so an
      // offboard with an unresolved target (a "not listed" user, or a reference ServiceNow couldn't
      // resolve) would otherwise fire its destructive steps against a blank identity with nobody
      // watching. No target => no schedule: it stays a plain hold, exactly as before.
      //
      // A date-only / midnight / backdated / mis-keyed u_end_date also yields no instant — same
      // outcome, it waits for a human. See autoOffboardScheduleAt.
      const at = offboardTargetResolved(payload as Record<string, unknown>)
        ? autoOffboardScheduleAt(payload as Record<string, unknown>, new Date())
        : null;
      await repo.setHold(caseId, "scheduled", at);
      scheduledFor = at;
      if (at) {
        // The engine scheduled this on its own — record it as its own audit event, not just a field
        // buried in the plan detail, so "why did this case release itself at 5:05pm?" is answerable.
        await repo.writeAudit({
          actor: who.actor,
          userId: who.userId,
          action: "case.schedule.set",
          clientId: client.id,
          caseRequestId: caseId,
          detail: { scheduledFor: at.toISOString(), source: "servicenow:u_end_date", offboardAt: (payload as Record<string, unknown>).offboardAt ?? null },
        });
      }
    } else {
      await repo.setHold(caseId, "review");
    }
  }

  await repo.writeAudit({
    actor: who.actor,
    userId: who.userId,
    action: "case.plan",
    clientId: client.id,
    caseRequestId: caseId,
    detail: {
      action: input.action,
      jobs: planned.length,
      manual: planned.filter((j) => j.mode !== "api").length,
      approval: planned.filter((j) => j.requiresApproval).length,
      status,
      serviceNowCaseNumber: input.serviceNowCaseNumber ?? null,
      // The auto-schedule is a decision the engine made on its own — record the exact instant it
      // will fire so an operator can see (and audit) why a case released itself at 5:05pm.
      ...(scheduledFor ? { scheduledFor: scheduledFor.toISOString() } : {}),
    },
  });

  return {
    caseId,
    status,
    jobCount: planned.length,
    manualCount: planned.filter((j) => j.mode !== "api").length,
    approvalCount: planned.filter((j) => j.requiresApproval).length,
  };
}
