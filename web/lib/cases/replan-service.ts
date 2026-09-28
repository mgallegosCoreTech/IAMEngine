// Re-plan an existing case: re-pull the latest UM (if ServiceNow-sourced), re-derive the user's
// identity from the client's CURRENT username pattern + domain, and re-plan against the client's
// CURRENT systems — replacing the planned jobs. The review→adjust→re-plan loop: an engineer can
// tweak the client's systems (Edit systems) or the requester can edit the ticket, then re-plan to
// regenerate the playbook. Only allowed BEFORE execution starts.
import type { PrismaClient } from "@prisma/client";
import { planCase } from "../orchestrator";
import { deriveIdentity } from "../servicenow/intake-mapper";
import { matchIntakeRule } from "../profiles/intake-rules";
import { fetchNormalizedIntake } from "./import-service";
import { makeCaseRepository } from "./repository";
import { deriveStatus, type PlanOutcome } from "./planning-service";
import { CaseAlreadyStartedError } from "./job-status";
import { makeEmailDomainResolver } from "./plan-domain";
import { resolvePlannedConfigs, personaSystemKeys } from "../profiles/plan-resolve";
import { unmodeledManualSteps } from "./unmodeled-steps";
import { documentedRank, inDocumentedOrder, mergeInDocumentedOrder } from "./documented-order";
import { resolveActor, type ActorInput } from "../auth/actor";

export type ReplanResult =
  | { ok: true; outcome: PlanOutcome; refreshedFromServiceNow: boolean; mode: "full" | "incremental"; kept: number; added: number; rerun: number }
  | { ok: false; error: string; code: "not_found" | "already_started" };

// A re-plan on a ServiceNow-sourced case re-pulls the ticket and wholesale-replaces the payload —
// SN is the source of truth for everything it supplies. But an operator can hand-edit fields on the
// case review panel (PATCH /api/cases/:id/fields, /m365-override, /offboard-target), which stamps
// payload.fieldSource[k] = "operator". Those edits must survive the refresh (both for THIS plan and
// for the write-back that follows it) or they silently vanish — the ticket re-pull erases a value
// the requester's ticket never had an opinion on. Overlay every operator-sourced key from the
// persisted payload onto the fresh intake, including the fieldSource bookkeeping itself so the
// provenance badge survives; SN still wins for every key the operator hasn't touched, and — if SN
// now ALSO supplies an operator-edited key — the operator's value wins (it's a deliberate override).
export function mergeOperatorEdits(
  freshPayload: Record<string, unknown>,
  persistedPayload: Record<string, unknown>
): Record<string, unknown> {
  const fieldSource = persistedPayload.fieldSource && typeof persistedPayload.fieldSource === "object"
    ? (persistedPayload.fieldSource as Record<string, unknown>)
    : undefined;
  if (!fieldSource) return freshPayload;
  const operatorKeys = Object.keys(fieldSource).filter((k) => fieldSource[k] === "operator");
  if (operatorKeys.length === 0) return freshPayload;
  const merged = { ...freshPayload };
  for (const k of operatorKeys) {
    if (k in persistedPayload) merged[k] = persistedPayload[k];
  }
  merged.fieldSource = fieldSource;
  return merged;
}

// `actor` is an AuditActor (label + User FK) for an operator-driven re-plan; a bare string for the
// system callers that also re-plan (they carry no userId, by design).
export async function replanCase(db: PrismaClient, caseId: string, actor: ActorInput, override?: string): Promise<ReplanResult> {
  const repo = makeCaseRepository(db);
  const info = await repo.replanInputs(caseId);
  if (!info) return { ok: false, error: "case not found", code: "not_found" };
  // A started case is fine: replanCaseJobs runs INCREMENTALLY (finished/in-flight jobs are kept;
  // only systems without a kept job get fresh jobs) — so KB/system changes can be picked up
  // mid-run. The only hard stop is the action flipping (guarded in the transaction).

  let action = info.action;
  let payload = info.payload;
  let refreshedFromServiceNow = false;
  // Per-contact intake rule (FR #0000019): a configured requester forces the domain and skips
  // systems. Hoisted to function scope so the planCase call below can see it.
  let intakeRule: ReturnType<typeof matchIntakeRule> = null;

  // Re-pull the latest ticket for a ServiceNow-sourced case (UM or INC — the requester may have
  // edited it). Best-effort: a SN outage / unconfigured env must NOT block re-planning against edited
  // local systems — keep the stored action/payload and carry on (refreshedFromServiceNow stays false).
  if (info.serviceNowCaseNumber) {
    try {
      const intake = await fetchNormalizedIntake(info.serviceNowCaseNumber);
      if (intake) {
        action = intake.action;
        payload = mergeOperatorEdits(intake.payload, info.payload);
        refreshedFromServiceNow = true;
      }
    } catch {
      // swallow — re-plan proceeds with the stored intake.
    }
  }

  // Same documented order as the initial plan (FR #0000178), now that the action is settled.
  // replanCaseJobs re-sequences kept jobs to the fresh plan, so re-planning an existing case also puts
  // its steps back in runbook order.
  const rank = documentedRank(await repo.documentedSections(info.client.id, action));
  info.client.systems = inDocumentedOrder(info.client.systems, rank);

  // Re-derive the identity for onboarding from the client's CURRENT username pattern + the resolved
  // EMAIL domain (contact-derived, with any per-case override), falling back to the website domain.
  if (action === "onboard") {
    const identity = (info.client.identity ?? {}) as { usernamePatterns?: string[] | null };
    // Explicit override (request body) wins; else the PERSISTED per-case choice (the operator's
    // domain pick survives later replans); else the client's default resolution.
    let { domain } = await makeEmailDomainResolver(db)(info.client, override ?? info.emailDomainOverride ?? undefined);
    intakeRule = matchIntakeRule((info.client as { intakeRules?: unknown }).intakeRules, payload as Record<string, unknown>);
    if (intakeRule?.forceDomain) domain = intakeRule.forceDomain;
    payload = deriveIdentity(payload, { usernamePatterns: identity.usernamePatterns ?? null, primaryDomain: domain });
    if (intakeRule) payload = { ...payload, __intakeRule: { id: intakeRule.id, label: intakeRule.label } };
  }

  const plannedSystems = resolvePlannedConfigs(info.client, payload, action,
    planCase(info.client.systems, action, payload, personaSystemKeys(info.client, payload, action),
      new Set(info.client.notNeededSecrets), new Set(info.client.wiredOptionalSecrets), intakeRule?.skipSystems, info.client.backbone));
  // Same manual checklist steps the initial plan adds (FR #0000096). The synthetic key is stable,
  // so a step an operator already ticked off is KEPT by the incremental re-plan, not resurrected.
  const planned = mergeInDocumentedOrder(plannedSystems, unmodeledManualSteps(
    await repo.unmodeledSections(info.client.id, action),
    plannedSystems.reduce((m, j) => Math.max(m, j.sequence), -1) + 1,
  ), rank);
  const status = deriveStatus(planned);
  let result: { mode: "full" | "incremental"; kept: number; added: number; rerun: number };
  try {
    result = await repo.replanCaseJobs(caseId, { action, payload, status }, planned);
  } catch (e) {
    // Only thrown when the ACTION flipped on a started case (onboard<->offboard mid-run).
    if (e instanceof CaseAlreadyStartedError) {
      return { ok: false, error: "the action changed (onboard/offboard) but this case already started — finish or trash it instead of re-planning across actions", code: "already_started" };
    }
    throw e;
  }

  const who = resolveActor(actor);
  await repo.writeAudit({
    actor: who.actor, userId: who.userId, action: "case.replan", clientId: info.client.id, caseRequestId: caseId,
    detail: { refreshedFromServiceNow, action, jobs: planned.length, mode: result.mode, kept: result.kept, added: result.added, rerun: result.rerun },
  });

  return {
    ok: true,
    refreshedFromServiceNow,
    mode: result.mode,
    kept: result.kept,
    added: result.added,
    rerun: result.rerun,
    outcome: {
      caseId, status, jobCount: planned.length,
      manualCount: planned.filter((j) => j.mode !== "api").length,
      approvalCount: planned.filter((j) => j.requiresApproval).length,
    },
  };
}
