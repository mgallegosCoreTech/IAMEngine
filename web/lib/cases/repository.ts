// Thin Prisma wrapper for the cases domain. Factory-style for testability, mirroring
// lib/clients/repository.ts.
import type { PrismaClient, ClientSystem, CaseStatus, Action } from "@prisma/client";
import { Prisma } from "@prisma/client"; // value import — Prisma.DbNull is used at runtime
import type { PlannedJob } from "../orchestrator";
import type { AuditEntry } from "../clients/types";
import type { AuditActor } from "../auth/actor";
import type { CaseDetail, CaseListItem, NewCaseInput, TrashedCaseItem } from "./types";
import type { DocumentedSection } from "./documented-order";
import { STARTED_STATUSES, hasStartedJobs, CaseAlreadyStartedError } from "./job-status";
import { autoOffboardScheduleAt, offboardTargetResolved, engineOwnsSchedule, AUTO_SCHEDULE_ACTOR } from "./schedule";
import { deriveCaseStatus } from "../jobs/runner-logic";
import { missingRequiredSecrets, NOT_NEEDED } from "./case-secrets";
import { ALL_OPTIONAL_SECRET_NAMES } from "../secrets/optional-secrets";
import { secretIsSet } from "../secrets/wiring";
import { jobWarningLines, ADHOC_STEP_LABELS } from "./run-report";
import { iamCaseNumber, needsIamNumber } from "./case-number";
import { notM365AutoSetupCase } from "./exclude-m365-autosetup";
import { type ClientScope, clientIdWhere, scopeAllows } from "../auth/client-scope";
import { inheritsFromParent, inheritsParentModeling, applyParentInheritance, PARENT_INHERIT_SELECT } from "./parent-inheritance";
import { unmodeledStepTitle, type UnmodeledSection } from "./unmodeled-steps";

// One-line explanation of a case's status, for the list hover tooltip. Reads the case's jobs the
// same way deriveCaseStatus / the dependency gate do, so the hint matches the badge.
type HintJob = { systemKey: string; sequence: number; status: string; mode: string; error: string | null; request: Prisma.JsonValue };
export function buildCaseStatusHint(
  status: CaseStatus,
  jobs: HintJob[],
  name: (key: string) => string,
  runnerOnline: boolean,
  missingSecrets: string[] = []
): string {
  const req = (j: HintJob) => (j.request ?? {}) as { requiresApproval?: boolean; approved?: boolean };
  const list = (js: HintJob[]) => js.map((j) => name(j.systemKey)).join(", ");

  switch (status) {
    case "failed": {
      const failed = jobs.filter((j) => j.status === "failed");
      // The runner already prefixes its error with "[systemKey]"; strip it since we prefix the name.
      const clean = (e: string | null) => (e ?? "no detail").replace(/^\[[^\]]+\]\s*/, "");
      if (failed.length) return failed.map((j) => `${name(j.systemKey)} failed: ${clean(j.error)}`).join(" · ");
      return "a step failed";
    }
    case "needs_manual": {
      const manual = jobs.filter((j) => j.mode !== "api" && j.status === "manual");
      if (manual.length) return `Manual step${manual.length > 1 ? "s" : ""} — no API automation, a person must do: ${list(manual)}`;
      return "needs a manual step";
    }
    case "needs_approval": {
      const gated = jobs.filter((j) => req(j).requiresApproval && !req(j).approved && !STARTED_STATUSES.includes(j.status as never));
      return gated.length ? `Waiting for approval on: ${list(gated)} (destructive step)` : "waiting for approval on a destructive step";
    }
    case "running": {
      const active = jobs.filter((j) => j.status === "dispatched" || j.status === "running");
      if (active.length) return `Running: ${list(active)}`;
      // Nothing is actually executing. If a required credential is missing the runner won't claim
      // the pending work (preflight) — it's paused, not running.
      if (missingSecrets.length) return `Paused — credentials needed: ${missingSecrets.join(", ")}. Fill them on the case Credentials panel.`;
      return "running";
    }
    case "planning":
      return "being planned…";
    case "queued": {
      // A required credential isn't set → the runner won't claim it (preflight). Surface that first.
      if (missingSecrets.length) return `Blocked — credential not set: ${missingSecrets.join(", ")}. Fill it on the case Credentials panel.`;
      const pending = [...jobs.filter((j) => j.mode === "api" && j.status === "pending")].sort((a, b) => a.sequence - b.sequence);
      if (!pending.length) return "queued";
      // DAG-aware (same rule as blockingJobs): a job with persisted dependsOn waits only on those
      // systems; legacy jobs wait on every earlier api job. Some pending job may be READY even
      // while others are blocked — report the ready one.
      const blockersOf = (job: HintJob) => {
        const deps = ((job.request ?? {}) as { dependsOn?: unknown }).dependsOn;
        const unmet = (j: HintJob) => j.mode === "api" && j.status !== "succeeded" && j.status !== "skipped";
        return Array.isArray(deps)
          ? jobs.filter((j) => unmet(j) && (deps as unknown[]).includes(j.systemKey))
          : jobs.filter((j) => unmet(j) && j.sequence < job.sequence);
      };
      const ready = pending.find((p) => blockersOf(p).length === 0);
      if (ready) {
        return runnerOnline
          ? `Ready — waiting for a runner to claim ${name(ready.systemKey)}`
          : `Ready, but no runner is online to claim it (next: ${name(ready.systemKey)})`;
      }
      const next = pending[0];
      return `Waiting on ${list(blockersOf(next))} to finish before ${name(next.systemKey)}`;
    }
    case "completed":
      return "all steps done";
    default:
      return "";
  }
}

// Secret names the client has marked "not needed" (NOT_NEEDED) — the step is done by hand, so there
// is no credential to broker. The planner turns such a system into a manual checklist item instead of
// an api job that would 409 at the broker. A child inherits the parent's marks for names it doesn't
// set itself (same precedence as credential resolution in case-secrets).
// The effective per-name externalId for a client (parent-inherited, child wins) — the shared basis for
// both "which secrets are not-needed" and "which optional secrets are wired".
async function effectiveSecretMap(db: PrismaClient, clientId: string, parentId: string | null): Promise<Map<string, string>> {
  const rows = await db.secret.findMany({
    where: { clientId: { in: parentId ? [clientId, parentId] : [clientId] } },
    select: { clientId: true, name: true, externalId: true },
  });
  const effective = new Map<string, string>();
  for (const r of rows) if (r.clientId !== clientId) effective.set(r.name, r.externalId); // parent first…
  for (const r of rows) if (r.clientId === clientId) effective.set(r.name, r.externalId); // …child wins
  return effective;
}

async function notNeededSecretNames(db: PrismaClient, clientId: string, parentId: string | null): Promise<string[]> {
  const effective = await effectiveSecretMap(db, clientId, parentId);
  return [...effective].filter(([, id]) => id === NOT_NEEDED).map(([name]) => name);
}

// OPTIONAL secret names this client has actually WIRED (a real Delinea reference — not blank / not the
// not-needed sentinel). The planner keeps such a name in a job's secretNames so the runner brokers it;
// an UNwired optional secret (e.g. ad-dc on a domain-controller agent) is simply omitted, so the AD
// job runs api under ambient SYSTEM instead of failing the up-front broker.
async function wiredOptionalSecretNames(db: PrismaClient, clientId: string, parentId: string | null): Promise<string[]> {
  const effective = await effectiveSecretMap(db, clientId, parentId);
  return [...effective].filter(([name, id]) => ALL_OPTIONAL_SECRET_NAMES.has(name) && secretIsSet(id)).map(([name]) => name);
}

export function makeCaseRepository(db: PrismaClient) {
  return {
    // Client + its systems + identity, needed to plan a case (identity/domain drive the UPN/
    // SamAccountName derivation). null if the client doesn't exist.
    // Runbook sections the extractor could not map to a system. The planner turns each into a
    // manual checklist step (FR #0000096); nothing else reads them at plan time.
    async unmodeledSections(clientId: string, action: Action): Promise<UnmodeledSection[]> {
      const rows = await db.runbookSection.findMany({
        where: { clientId, action, status: "unmodeled" },
        orderBy: { seq: "asc" },
        select: { title: true, steps: true, guess: true, seq: true },
      });
      return rows.map((r) => ({ title: r.title, steps: r.steps ?? [], guess: r.guess ?? null, seq: r.seq }));
    },

    // Where each system sits in this action's runbook: the order a case's steps follow wherever
    // their dependencies leave it open (FR #0000178).
    async documentedSections(clientId: string, action: Action): Promise<DocumentedSection[]> {
      return db.runbookSection.findMany({
        where: { clientId, action, systemKey: { not: null } },
        orderBy: { seq: "asc" },
        select: { systemKey: true, seq: true },
      });
    },

    async clientForPlanning(slug: string): Promise<
      | {
          id: string; name: string; slug: string; primaryDomain: string;
          backbone: string | null;
          emailDomain: string | null; emailDomainLocked: boolean; serviceNowSysId: string | null;
          engineOptOut: boolean;
          identity: unknown; personas: unknown; globals: unknown; globalsOffboard: unknown; locations: unknown; systems: ClientSystem[];
          adObjects: unknown; cloudGroups: unknown;
          intakeRules: unknown;
          notNeededSecrets: string[];
          wiredOptionalSecrets: string[];
        }
      | null
    > {
      const c = await db.client.findUnique({
        where: { slug },
        select: {
          id: true, name: true, slug: true, primaryDomain: true,
          backbone: true,
          emailDomain: true, emailDomainLocked: true, serviceNowSysId: true, engineOptOut: true,
          identity: true, personas: true, globals: true, globalsOffboard: true, locations: true, systems: true,
          adObjects: true, cloudGroups: true,
          intakeRules: true,
          parentId: true, inheritParentSystems: true, inheritParentModeling: true,
        },
      });
      if (!c) return null;
      const notNeededSecrets = await notNeededSecretNames(db, c.id, c.parentId);
      const wiredOptionalSecrets = await wiredOptionalSecretNames(db, c.id, c.parentId);
      // Account hierarchy: a child with NO modeled systems of its own plans with its PARENT's
      // runbook (e.g. CORE2181..89 inherit CORE1456). Systems come wholesale from the parent;
      // the modeling inputs fall back individually so anything the child HAS set still wins.
      // Adding systems to the child later automatically ends the inheritance, and a child whose
      // inheritParentSystems was switched off (it doesn't match its parent) never inherits.
      const wantSystems = inheritsFromParent(c);
      const wantModeling = inheritsParentModeling(c);
      if (wantSystems || wantModeling) {
        const p = await db.client.findUnique({ where: { id: c.parentId! }, select: PARENT_INHERIT_SELECT });
        return applyParentInheritance({ ...c, notNeededSecrets, wiredOptionalSecrets }, p, { systems: wantSystems, modeling: wantModeling });
      }
      return { ...c, notNeededSecrets, wiredOptionalSecrets };
    },

    async clientSysIdToSlug(serviceNowSysId: string): Promise<string | null> {
      const c = await db.client.findUnique({ where: { serviceNowSysId }, select: { slug: true } });
      return c?.slug ?? null;
    },

    async findCaseIdByNumber(number: string): Promise<string | null> {
      const c = await db.caseRequest.findUnique({ where: { serviceNowCaseNumber: number }, select: { id: true } });
      return c?.id ?? null;
    },

    // Create the case + its planned jobs + set status, atomically.
    async createCaseWithJobs(
      input: NewCaseInput,
      clientId: string,
      planned: PlannedJob[],
      status: CaseStatus,
      // WHO opened it. Written onto the row (not only into AuditLog) so the creator is a column the
      // list can show and filter on, and so it survives even if the audit trail is pruned.
      creator?: AuditActor
    ): Promise<string> {
      const created = await db.$transaction(async (tx) => {
        // A manual case (no ServiceNow number) gets an auto-assigned IAM number from the dedicated
        // sequence. nextval is atomic, so concurrent creates can't collide on the unique column; a
        // rolled-back create just leaves a gap, which is fine (same as any sequence / autoincrement).
        let caseNumber = input.serviceNowCaseNumber ?? null;
        if (needsIamNumber(caseNumber)) {
          const [row] = await tx.$queryRaw<{ nextval: bigint }[]>`SELECT nextval('"CaseRequest_iam_seq"') AS nextval`;
          caseNumber = iamCaseNumber(Number(row.nextval));
        }
        const c = await tx.caseRequest.create({
          data: {
            clientId,
            action: input.action,
            serviceNowCaseNumber: caseNumber,
            subject: input.subject ?? null,
            status,
            dryRun: input.dryRun ?? false,
            payload: input.payload as Prisma.InputJsonValue,
            createdBy: creator?.label ?? null,
            createdByUserId: creator?.userId ?? null,
            createdSource: input.source ?? "manual",
          },
          select: { id: true },
        });
        if (planned.length > 0) {
          await tx.job.createMany({
            data: planned.map((p) => ({
              caseRequestId: c.id,
              systemKey: p.systemKey,
              sequence: p.sequence,
              mode: p.mode,
              // scim = the IdP provisions this app automatically: the step stays VISIBLE in the plan
              // (it is part of the process) but is born satisfied so the case never waits on it.
              status: p.mode === "api" ? "pending" : p.mode === "scim" ? "succeeded" : "manual",
              // Resolved instructions for the runner (Phase 3) + the planning flags we surface now.
              request: {
                config: p.config ?? null,
                requiresApproval: p.requiresApproval,
                captureEvidence: p.captureEvidence,
                intent: p.intent,
                secretNames: p.secretNames,
                dependsOn: p.dependsOn,
                dryRun: input.dryRun ?? false,
              } as Prisma.InputJsonValue,
            })),
          });
        }
        return c;
      });
      return created.id;
    },

    // Inputs for re-planning an existing case: its SN number + payload, the client (with current
    // identity + systems), and whether any job has already started (re-plan is pre-execution only).
    async replanInputs(caseId: string): Promise<
      | { serviceNowCaseNumber: string | null; action: Action; payload: Record<string, unknown>;
          emailDomainOverride: string | null;
          client: {
            id: string; slug: string; primaryDomain: string; backbone: string | null;
            emailDomain: string | null; emailDomainLocked: boolean; serviceNowSysId: string | null;
            identity: unknown; personas: unknown; globals: unknown; globalsOffboard: unknown; locations: unknown; systems: ClientSystem[];
            adObjects: unknown; cloudGroups: unknown;
            intakeRules: unknown;
            notNeededSecrets: string[];
            wiredOptionalSecrets: string[];
          }; started: boolean }
      | null
    > {
      const c = await db.caseRequest.findUnique({
        where: { id: caseId },
        select: {
          serviceNowCaseNumber: true, action: true, payload: true, emailDomainOverride: true,
          client: {
            select: {
              // `backbone` must stay in this select: the planner's ad_synced injections (the FR#36
              // GAL-hide AD attribute and FR#25's cloudCreate deny) read client.backbone, and a
              // re-plan without it would silently REVERT them on a freshly planned case.
              id: true, slug: true, primaryDomain: true, backbone: true,
              emailDomain: true, emailDomainLocked: true, serviceNowSysId: true,
              identity: true, personas: true, globals: true, globalsOffboard: true, locations: true, systems: true,
              adObjects: true, cloudGroups: true,
              intakeRules: true,
              parentId: true,
              inheritParentSystems: true,
              inheritParentModeling: true,
            },
          },
          jobs: { select: { status: true } },
        },
      });
      if (!c) return null;
      const notNeededSecrets = await notNeededSecretNames(db, c.client.id, c.client.parentId);
      const wiredOptionalSecrets = await wiredOptionalSecretNames(db, c.client.id, c.client.parentId);
      // Same parent-inheritance the INITIAL plan applies. Without it a child with no systems of its own
      // re-planned to ZERO jobs — 77% of their re-plans — so nothing existed for the requested-groups
      // merge to land on and the ticket's groups were silently dropped (FR #0000042).
      const wantSystems = inheritsFromParent(c.client);
      const wantModeling = inheritsParentModeling(c.client);
      const inherited = wantSystems || wantModeling
        ? applyParentInheritance(c.client, await db.client.findUnique({ where: { id: c.client.parentId! }, select: PARENT_INHERIT_SELECT }), { systems: wantSystems, modeling: wantModeling })
        : c.client;
      return {
        serviceNowCaseNumber: c.serviceNowCaseNumber,
        action: c.action,
        payload: (c.payload ?? {}) as Record<string, unknown>,
        emailDomainOverride: c.emailDomainOverride,
        client: { ...inherited, notNeededSecrets, wiredOptionalSecrets },
        started: hasStartedJobs(c.jobs),
      };
    },

    // Rescan: refresh the stored intake (action/payload/subject) from ServiceNow WITHOUT touching the
    // planned jobs — the operator re-plans separately. Returns the changed field keys for the UI. An
    // onboard<->offboard flip on a started case is refused (it would desync the existing jobs).
    async refreshCaseIntake(
      caseId: string,
      intake: { action: Action; payload: Record<string, unknown>; subject: string | null }
    ): Promise<
      | { ok: true; changed: string[]; clientId: string; actionChanged: boolean }
      | { ok: false; reason: "not_found" | "action_flip_started" }
    > {
      const c = await db.caseRequest.findUnique({
        where: { id: caseId },
        select: { clientId: true, action: true, subject: true, payload: true, jobs: { select: { status: true } } },
      });
      if (!c) return { ok: false, reason: "not_found" };
      const actionChanged = c.action !== intake.action;
      if (actionChanged && hasStartedJobs(c.jobs)) return { ok: false, reason: "action_flip_started" };

      // Diff the stored vs incoming payload (union of keys, structural compare) + action/subject.
      const old = (c.payload ?? {}) as Record<string, unknown>;
      const changed: string[] = [];
      for (const k of new Set([...Object.keys(old), ...Object.keys(intake.payload)])) {
        if (JSON.stringify(old[k]) !== JSON.stringify(intake.payload[k])) changed.push(k);
      }
      if (actionChanged) changed.push("action");
      if ((c.subject ?? null) !== (intake.subject ?? null)) changed.push("subject");

      // The auto-schedule was derived from the OLD payload's termination instant. A rescan is exactly
      // the moment that instant can change — HR pushes a termination out a week, or the ticket flips
      // to an onboard. Leaving the stale scheduledFor in place would fire the offboard on the
      // ORIGINAL date and tear down an account for someone who is still employed. So recompute it
      // from the refreshed intake, and drop it entirely if the refreshed intake no longer earns one.
      //
      // ONLY recompute a schedule the ENGINE owns. `pausedReason: "scheduled"` is ALSO what the
      // operator's own schedule button writes — so keying on it alone cannot tell "the engine derived
      // this from u_end_date" from "a human deliberately picked a later time", and would silently
      // overwrite the human's choice (rewriting the provenance to system:intake on the way out). An
      // operator who holds a leaver's access open for a handover, and whose schedule is then snapped
      // back to the original date by a routine rescan, gets an unattended teardown a week early — the
      // exact failure this feature must never cause. `scheduledBy` is that provenance: recompute only
      // when it is ours.
      const c2 = await db.caseRequest.findUnique({ where: { id: caseId }, select: { pausedReason: true, scheduledBy: true } });
      const engineOwnedSchedule = engineOwnsSchedule(c2?.pausedReason ?? null, c2?.scheduledBy ?? null);
      const rescheduled =
        engineOwnedSchedule && intake.action === "offboard" && offboardTargetResolved(intake.payload)
          ? autoOffboardScheduleAt(intake.payload, new Date())
          : null;

      await db.caseRequest.update({
        where: { id: caseId },
        // verifiedAt is cleared: the plan no longer reflects the (now-refreshed) intake until re-planned.
        data: {
          action: intake.action,
          payload: intake.payload as Prisma.InputJsonValue,
          subject: intake.subject,
          verifiedAt: null,
          ...(engineOwnedSchedule
            ? { scheduledFor: rescheduled, scheduledBy: rescheduled ? AUTO_SCHEDULE_ACTOR : null }
            : {}),
        },
      });
      return { ok: true, changed, clientId: c.clientId, actionChanged };
    },

    // Re-plan: replace the case's jobs and refresh its action/payload/status in one transaction.
    async replanCaseJobs(
      caseId: string,
      upd: { action: Action; payload: Record<string, unknown>; status: CaseStatus },
      planned: PlannedJob[]
    ): Promise<{ mode: "full" | "incremental"; kept: number; added: number; rerun: number }> {
      return db.$transaction(async (tx) => {
        // Drop every job that hasn't ACTUALLY run; whatever survives is real work that must be
        // KEPT (the account exists — its history can't be re-planned away). SKIPPED jobs are
        // replaced too: nothing executed (no-executor skips, failure-cancelled pendings), and
        // keeping them would pin their old sequence + stale dependsOn forever (a skipped
        // case-resolution stayed at position 2 with no deps across every re-plan). An empty
        // survivor set = the classic full re-plan; survivors = INCREMENTAL: only systems without
        // a kept job get fresh jobs, so a mid-run case picks up changes without losing the run.
        await tx.job.deleteMany({ where: { caseRequestId: caseId, status: { notIn: ["dispatched", "running", "succeeded", "failed"] } } });
        const kept = await tx.job.findMany({
          where: { caseRequestId: caseId },
          select: { id: true, systemKey: true, sequence: true, mode: true, status: true, request: true, startedAt: true },
        });
        const existing = await tx.caseRequest.findUnique({ where: { id: caseId }, select: { dryRun: true, action: true } });
        const dryRun = existing?.dryRun ?? false; // replanned jobs inherit the case's current mode
        // Flipping onboard<->offboard mid-run would graft offboard steps onto a half-finished
        // onboard (or vice versa) — refuse; the operator should finish or trash the case instead.
        if (kept.length > 0 && existing && existing.action !== upd.action) throw new CaseAlreadyStartedError();

        const keptByKey = new Map(kept.map((k) => [k.systemKey, k]));
        const plannedKeys = new Set(planned.map((p) => p.systemKey));
        const reqOf = (p: PlannedJob) => ({
          config: p.config ?? null,
          requiresApproval: p.requiresApproval,
          captureEvidence: p.captureEvidence,
          intent: p.intent,
          secretNames: p.secretNames,
          dependsOn: p.dependsOn,
          dryRun,
        });
        const isTerminal = (s: string) => s === "succeeded" || s === "failed";
        // The status a freshly-planned job of a given mode is BORN with (mirrors the create path above
        // and createCaseWithJobs): api waits to dispatch; scim is provisioned by the IdP so it's born
        // satisfied; everything else is a manual checklist item.
        const bornStatus = (m: string) => (m === "api" ? "pending" : m === "scim" ? "succeeded" : "manual");

        await tx.caseRequest.update({
          where: { id: caseId },
          data: { action: upd.action, payload: upd.payload as Prisma.InputJsonValue, status: upd.status, verifiedAt: null },
        });

        // Reconcile every planned system against the kept jobs. Kept jobs are RE-SEQUENCED to the
        // fresh plan (so the displayed order matches the client again) and their config/deps are
        // refreshed. If a kept job's config actually changed (e.g. a new license) and it's a
        // finished api job, reset it to pending so the change re-runs (executors are idempotent).
        let added = 0;
        let rerun = 0;
        for (const p of planned) {
          const k = keptByKey.get(p.systemKey);
          const newReq = reqOf(p);
          if (!k) {
            await tx.job.create({
              data: {
                caseRequestId: caseId, systemKey: p.systemKey, sequence: p.sequence, mode: p.mode,
                status: p.mode === "api" ? "pending" : p.mode === "scim" ? "succeeded" : "manual",
                request: newReq as Prisma.InputJsonValue,
              },
            });
            added++;
            continue;
          }
          const oldReq = (k.request ?? {}) as { config?: unknown; approved?: boolean };
          const configChanged = JSON.stringify(oldReq.config ?? null) !== JSON.stringify(p.config ?? null);
          const willRerun = configChanged && k.mode === "api" && isTerminal(k.status);
          // A scim step is born status:"succeeded" WITHOUT ever dispatching (startedAt stays null), so
          // it lands in the kept set even though nothing ran. If the operator then corrects the system's
          // mode on the client page (e.g. scim->api because it's really an API integration), plain kept
          // reconciliation never rewrites `mode` — the phantom "verified" step sticks forever and the
          // corrected step never dispatches. Detect that exact shape (born-succeeded, never ran, planned
          // mode now differs) and re-derive it to the new mode + its born status so it actually runs. A
          // genuinely-executed job always has startedAt set, so this can never clobber real work.
          const neverRan = k.status === "succeeded" && k.startedAt == null;
          const modeCorrected = neverRan && p.mode !== k.mode;
          const reset = { result: Prisma.DbNull, validation: Prisma.DbNull, evidence: Prisma.DbNull, progress: Prisma.DbNull, error: null, startedAt: null, finishedAt: null, assignedAgentId: null };
          await tx.job.update({
            where: { id: k.id },
            data: {
              sequence: p.sequence,
              request: { ...newReq, approved: oldReq.approved } as Prisma.InputJsonValue,
              ...(modeCorrected
                ? { mode: p.mode, status: bornStatus(p.mode), ...reset }
                : willRerun
                ? { status: "pending", ...reset }
                : {}),
            },
          });
          if (willRerun || modeCorrected) rerun++;
        }
        // Systems removed from the plan: drop their not-yet-started kept jobs (started ones stay as history).
        for (const k of kept) {
          if (!plannedKeys.has(k.systemKey) && !STARTED_STATUSES.includes(k.status as never)) {
            await tx.job.delete({ where: { id: k.id } });
          }
        }

        if (kept.length > 0) {
          // Incremental: the plan-derived status ignores the kept jobs — recompute from ALL of them.
          const all = await tx.job.findMany({
            where: { caseRequestId: caseId },
            select: { id: true, systemKey: true, sequence: true, mode: true, status: true, request: true },
          });
          // A kept job may be a failure the operator ACCEPTED ("ignore") — it must not drag the
          // replanned case back to "failed" (see deriveCaseStatus / acceptedKeysFor).
          const acceptedKeys = new Set(
            (await tx.runOutcome.findMany({
              where: { caseRequestId: caseId, status: "failed", resolvedAt: { not: null } },
              select: { systemKey: true },
            })).map((o) => o.systemKey)
          );
          const st = deriveCaseStatus(
            all.map((j) => {
              const r = (j.request ?? {}) as { requiresApproval?: boolean; approved?: boolean };
              return {
                id: j.id, systemKey: j.systemKey, sequence: j.sequence, mode: j.mode, status: j.status,
                requiresApproval: Boolean(r.requiresApproval), approved: Boolean(r.approved),
                accepted: j.status === "failed" && acceptedKeys.has(j.systemKey),
              };
            })
          );
          await tx.caseRequest.update({ where: { id: caseId }, data: { status: st } });
        }
        return { mode: kept.length ? ("incremental" as const) : ("full" as const), kept: kept.length, added, rerun };
      });
    },

    // Hold / release a case. reason "needs_info" auto-holds an imported case whose intake had
    // unknowns to fill; "scheduled" auto-holds an offboard on import (it may be future-dated);
    // "operator" is a manual pause. Passing null releases the hold.
    // `scheduledFor` turns a "scheduled" hold into one the sweep will actually RELEASE
    // (sweepScheduledCases matches pausedReason="scheduled" AND scheduledFor <= now). A scheduled
    // hold with no scheduledFor — which is what every auto-imported offboard used to get — just sits
    // there until a human resumes it. Passing null keeps that (hold, but no auto-release).
    async setHold(
      caseId: string,
      reason: "needs_info" | "scheduled" | "review" | "operator" | null,
      scheduledFor: Date | null = null
    ): Promise<void> {
      await db.caseRequest.update({
        where: { id: caseId },
        data: {
          pausedAt: reason ? new Date() : null,
          pausedReason: reason,
          scheduledFor: reason === "scheduled" ? scheduledFor : null,
          // scheduledBy is a snapshot of WHO scheduled it; the engine's own schedules are attributed
          // to the intake rather than to an operator (the audit row carries the full provenance).
          scheduledBy: reason === "scheduled" && scheduledFor ? AUTO_SCHEDULE_ACTOR : null,
        },
      });
    },

    // Toggle a case's dry-run mode and propagate it onto every not-yet-started job's request.dryRun
    // (atomic jsonb merge), so a runner that later claims one runs -WhatIf. Started jobs are left
    // alone. Returns the number of pending jobs updated.
    async setCaseDryRun(caseId: string, dryRun: boolean): Promise<number> {
      return db.$transaction(async (tx) => {
        await tx.caseRequest.update({ where: { id: caseId }, data: { dryRun } });
        const updated = await tx.$executeRaw`UPDATE "Job" SET "request" = COALESCE("request", '{}'::jsonb) || ${JSON.stringify({ dryRun })}::jsonb WHERE "caseRequestId" = ${caseId} AND "status" NOT IN ('dispatched', 'running', 'succeeded', 'failed', 'skipped')`;
        return updated;
      });
    },

    // Take a case that has already run in dry-run mode LIVE: clear dryRun, resume it, and re-queue every
    // api step that ran under dry-run so it executes for real. Manual steps are left as-is. Returns how many
    // jobs were re-queued.
    async takeCaseLive(caseId: string): Promise<{ ok: boolean; jobsRequeued: number }> {
      const c = await db.caseRequest.findUnique({ where: { id: caseId }, select: { id: true, status: true, jobs: { select: { id: true, mode: true, status: true } } } });
      if (!c) return { ok: false, jobsRequeued: 0 };
      const toRequeue = c.jobs.filter((j) => j.mode === "api" && STARTED_STATUSES.includes(j.status as never)).map((j) => j.id);
      await db.$transaction(async (tx) => {
        // Case: out of dry-run, unpaused, back in the queue so runners pick up the re-queued steps.
        await tx.caseRequest.update({ where: { id: caseId }, data: { dryRun: false, pausedAt: null, pausedReason: null, ...(c.status === "completed" ? {} : { status: "queued" }) } });
        // Every api job: clear dryRun from its request so a real run doesn't -WhatIf. Pending ones stay pending.
        await tx.$executeRaw`UPDATE "Job" SET "request" = jsonb_set(COALESCE("request", '{}'::jsonb), '{dryRun}', 'false') WHERE "caseRequestId" = ${caseId} AND "mode" = 'api'`;
        // Re-queue the already-run api steps to a fresh claimable state with dryRun cleared.
        if (toRequeue.length) {
          await tx.job.updateMany({
            where: { id: { in: toRequeue } },
            data: { status: "pending", assignedAgentId: null, result: Prisma.DbNull, validation: Prisma.DbNull, evidence: Prisma.DbNull, progress: Prisma.DbNull, error: null, startedAt: null, finishedAt: null },
          });
        }
      });
      return { ok: true, jobsRequeued: toRequeue.length };
    },

    // `scope` (default unrestricted) limits the list to cases of the operator's visible clients.
    // `limit` bounds the query — this table + its inlined jobs/audit grow unboundedly, so the default
    // returns the most-recent N (an ops list scans recent cases; a history/pagination UI is the follow-up).
    async listCases(scope: ClientScope = null, limit = 250): Promise<CaseListItem[]> {
      const rows = await db.caseRequest.findMany({
        where: {
          deletedAt: null,
          clientId: clientIdWhere(scope), // trashed cases live in the Trash section
          // Exclude the synthetic onboard case that hosts a lone entra-devicecode browser job
          // (dispatch-device-code-job.ts) — it's not a real intake case and would just clutter the
          // queue. See notM365AutoSetupCase for why a bare NOT drops every normal case.
          ...notM365AutoSetupCase,
        },
        orderBy: { createdAt: "desc" },
        take: limit,
        select: {
          id: true, action: true, status: true, subject: true, pausedAt: true, pausedReason: true, scheduledFor: true,
          serviceNowCaseNumber: true, createdAt: true, clientId: true, payload: true, secretOverrides: true,
          createdBy: true, createdSource: true,
          snAssignedTo: true, snAssignedToEmail: true, snAssigneeCheckedAt: true,
          client: { select: { name: true, slug: true, parentId: true } },
          jobs: { select: { systemKey: true, sequence: true, status: true, mode: true, error: true, request: true, startedAt: true, finishedAt: true } },
        },
      });

      // Per-case audit attribution, from one query (latest-first). Two things come out of it:
      //   - lastAction: the most recent tracked action on the case + who did it ("Imported: Jane",
      //     "Unpaused: Bob", "Paused", "Verified") — a quick "who last touched this, and how".
      //   - ranBy:      the last OPERATOR who ran the case (import/re-run/resume/verify — not a pause),
      //     for the "Last run · by" column. Both ignore the "user:" prefix; the name is null when the
      //     actor isn't a signed-in user ("ui"/"system"/"agent:…" — e.g. auth off).
      const caseIds = rows.map((r) => r.id);
      const ACTION_LABEL: Record<string, string> = {
        "case.plan": "Imported",
        "case.resume": "Unpaused",
        "case.pause": "Paused",
        "case.verify": "Verified",
        "job.rerun": "Re-ran",
        "case.dry_run.set": "Set dry-run",
      };
      const RUN_ACTIONS = new Set(["case.plan", "job.rerun", "case.verify", "case.resume", "case.dry_run.set"]); // a "run", not a pause
      const audits = caseIds.length
        ? await db.auditLog.findMany({
            where: { caseRequestId: { in: caseIds }, action: { in: Object.keys(ACTION_LABEL) } },
            orderBy: { at: "desc" },
            select: { caseRequestId: true, actor: true, action: true },
          })
        : [];
      const userName = (actor: string): string | null => (actor.startsWith("user:") ? actor.slice(5) : null);
      const lastActionByCase = new Map<string, { label: string; by: string | null }>();
      const ranByCase = new Map<string, string>();
      for (const a of audits) {
        if (!a.caseRequestId) continue;
        if (!lastActionByCase.has(a.caseRequestId)) {
          lastActionByCase.set(a.caseRequestId, { label: ACTION_LABEL[a.action] ?? a.action, by: userName(a.actor) });
        }
        const name = userName(a.actor);
        if (name && RUN_ACTIONS.has(a.action) && !ranByCase.has(a.caseRequestId)) ranByCase.set(a.caseRequestId, name);
      }

      // Resolve display names for every system in play (one query) + which clients have a runner
      // online right now (so a "queued" hint can say "no runner online" — the usual stall cause).
      const keys = [...new Set(rows.flatMap((r) => r.jobs.map((j) => j.systemKey)))];
      const catalog = keys.length
        ? await db.systemCatalog.findMany({ where: { key: { in: keys } }, select: { key: true, name: true } })
        : [];
      const nameByKey = new Map(catalog.map((s) => [s.key, s.name]));

      // Warning lines for completed cases — a second, TARGETED query (succeeded jobs of completed
      // cases only) rather than selecting every job's full result/validation JSON in the list query
      // above: result envelopes carry evidence snapshots and action lists, and the list is
      // unpaginated, so dragging them all in grows the page's DB transfer with all-time history.
      const allCompletedIds = rows.filter((r) => r.status === "completed").map((r) => r.id);
      // Case-level warning dismissal (FR #13): the operator finished the leftovers by hand and
      // dismissed the warnings — the list must stop painting the case orange, same as the report.
      const dismissedIds = allCompletedIds.length
        ? new Set(
            (await db.caseRequest.findMany({ where: { id: { in: allCompletedIds }, warningsDismissedAt: { not: null } }, select: { id: true } })).map((c) => c.id)
          )
        : new Set<string>();
      const completedIds = allCompletedIds.filter((id) => !dismissedIds.has(id));
      const warnJobs = completedIds.length
        ? await db.job.findMany({
            where: { caseRequestId: { in: completedIds }, status: "succeeded" },
            select: { caseRequestId: true, systemKey: true, result: true, validation: true, request: true },
          })
        : [];
      // A completed case is only "green done" when no step carries a warning (a WARN action or a
      // missed validation) — same definition as the run report (jobWarningLines). The list shows
      // completed-with-warnings cases in orange with these lines on hover.
      //
      // A step with a scheduled auto-retry is EXCLUDED: it's waiting on a vendor-side directory sync
      // (Spanning/Mimecast discovering a new M365 user) and its validation miss is expected until the
      // sync lands. The run report already shows it as "retrying" (run-report.ts) — painting the case
      // orange here contradicted that, for a step that resolves itself.
      const warningsByCase = new Map<string, string[]>();
      for (const j of warnJobs) {
        if (((j.request ?? {}) as { autoRetry?: { at?: number } }).autoRetry?.at) continue;
        const lines = jobWarningLines(j.result, j.validation).map((w) => `${nameByKey.get(j.systemKey) ?? j.systemKey}: ${w}`);
        if (lines.length) warningsByCase.set(j.caseRequestId, [...(warningsByCase.get(j.caseRequestId) ?? []), ...lines]);
      }

      const onlineCutoff = new Date(Date.now() - 90_000);
      const onlineAgents = await db.agent.findMany({
        where: { enabled: true, deletedAt: null, lastSeenAt: { gt: onlineCutoff } },
        select: { clientId: true },
      });
      // A case is servable if a central runner (clientId null) OR a runner bound to its client is up.
      const centralOnline = onlineAgents.some((a) => a.clientId === null);
      const clientHasRunner = new Set(onlineAgents.map((a) => a.clientId).filter(Boolean) as string[]);

      // Required-secret preflight per case: which named secrets aren't set (so the runner won't claim).
      // Include PARENT client secrets: a child account (e.g. CORE218x) inherits its parent's runbook and
      // resolves credentials from the parent — claim() does the same, so readiness must too, else every
      // child case reads as "blocked".
      const clientIds = [...new Set(rows.map((r) => r.clientId))];
      const parentIds = [...new Set(rows.map((r) => r.client.parentId).filter((id): id is string => Boolean(id)))];
      const secretClientIds = [...new Set([...clientIds, ...parentIds])];
      const clientSecretRows = secretClientIds.length
        ? await db.secret.findMany({ where: { clientId: { in: secretClientIds } }, select: { clientId: true, name: true, externalId: true } })
        : [];
      const secretsByClient = new Map<string, Map<string, string | null>>();
      for (const s of clientSecretRows) {
        const m = secretsByClient.get(s.clientId) ?? new Map<string, string | null>();
        m.set(s.name, s.externalId);
        secretsByClient.set(s.clientId, m);
      }

      return rows.map((r) => {
        // Contextual date: a new hire's start date for onboarding, the offboarding date for offboards
        // (both come date-only from the intake — u_start_date / u_end_date). Offboards accept either
        // the canonical `dateOfOffboarding` or the legacy `endDate` key (incident cases imported before
        // the field was unified store it under endDate), so existing + new cases both show a date.
        const p = (r.payload ?? {}) as { startDate?: unknown; dateOfOffboarding?: unknown; endDate?: unknown };
        let raw = r.action === "offboard" ? (p.dateOfOffboarding ?? p.endDate) : p.startDate;
        // Incident offboards carry the date (or "Immediate") in the subject, e.g.
        // "Offboarding - Ryan McNulty - 06/19/2026" / "… - Immediate" — extract it when the payload
        // had no date field, so the column isn't blank.
        let immediate = false;
        if (r.action === "offboard" && !(typeof raw === "string" && raw)) {
          const subj = r.subject ?? "";
          const md = /\b(\d{1,2})\/(\d{1,2})\/(\d{4})\b/.exec(subj);
          if (md) raw = `${md[3]}-${md[1].padStart(2, "0")}-${md[2].padStart(2, "0")}`;
          else if (/\bimmediate\b/i.test(subj)) immediate = true;
        }
        const effectiveDate = typeof raw === "string" && raw ? raw : null;
        // Last run: the most recent time any job started or finished. null = never dispatched.
        const runTimes = r.jobs.map((j) => j.finishedAt ?? j.startedAt).filter((d): d is Date => Boolean(d));
        const lastRunAt = runTimes.length ? new Date(Math.max(...runTimes.map((d) => d.getTime()))) : null;
        // Match the claim preflight exactly: only the jobs the runner could claim NOW gate the case
        // — pending api jobs whose earlier api jobs are all done. (A later job's unset secret, or a
        // manual job's secret, must NOT show the case as blocked while an earlier step can still run.)
        const apiJobs = r.jobs.filter((j) => j.mode === "api");
        const claimableNow = apiJobs.filter(
          (j) => j.status === "pending" && apiJobs.every((o) => o.sequence >= j.sequence || o.status === "succeeded" || o.status === "skipped")
        );
        const neededSecrets = [...new Set(claimableNow.flatMap((j) => (((j.request ?? {}) as { secretNames?: string[] }).secretNames ?? [])))];
        // Child accounts resolve secrets from the parent, exactly as claim() does — pass the parent's map.
        const parentSecretMap = r.client.parentId ? secretsByClient.get(r.client.parentId) : undefined;
        const missingSecrets = missingRequiredSecrets(neededSecrets, r.secretOverrides, secretsByClient.get(r.clientId) ?? new Map(), parentSecretMap);
        // Per-case READINESS — across the WHOLE plan (every api job, not just what's claimable now): of
        // the systems this case needs credentials for, how many are set. ready=all set, partial=some,
        // blocked=none, none=no credential-gated systems. Reuses the same secret-resolution as the gate.
        const planSecrets = [...new Set(apiJobs.flatMap((j) => (((j.request ?? {}) as { secretNames?: string[] }).secretNames ?? [])))];
        const planMissing = missingRequiredSecrets(planSecrets, r.secretOverrides, secretsByClient.get(r.clientId) ?? new Map(), parentSecretMap);
        const readiness: "ready" | "partial" | "blocked" | "none" =
          planSecrets.length === 0 ? "none"
          : planMissing.length === 0 ? "ready"
          : planMissing.length >= planSecrets.length ? "blocked"
          : "partial";
        // "Paused": the case looks running/queued but nothing is actually executing and a required
        // credential is missing, so the runner won't claim it — surface that as paused, not running.
        const activeNow = r.jobs.some((j) => j.status === "dispatched" || j.status === "running");
        const operatorPaused = Boolean(r.pausedAt) && !["completed", "failed"].includes(r.status);
        const credsPaused = !activeNow && missingSecrets.length > 0 && (r.status === "running" || r.status === "queued");
        const needsInfo = operatorPaused && r.pausedReason === "needs_info";
        const scheduled = operatorPaused && r.pausedReason === "scheduled";
        const review = operatorPaused && r.pausedReason === "review";
        const paused = operatorPaused || credsPaused;
        // "Imported": a ServiceNow-sourced case held on import for review with NO activity yet
        // (nothing dispatched/run) — just landed, nothing done. Distinct from a reviewed case the
        // operator has started or re-held after a run.
        const imported = Boolean(r.serviceNowCaseNumber) && review && !lastRunAt && !["completed", "failed"].includes(r.status);
        return {
          id: r.id, action: r.action, status: r.status, subject: r.subject, paused, imported,
          pausedBy: needsInfo ? ("needs_info" as const) : scheduled ? ("scheduled" as const) : review ? ("review" as const) : operatorPaused ? ("operator" as const) : credsPaused ? ("creds" as const) : null,
          warnings: warningsByCase.get(r.id) ?? [],
          serviceNowCaseNumber: r.serviceNowCaseNumber, createdAt: r.createdAt, effectiveDate, immediate,
          scheduledFor: r.scheduledFor,
          lastRunAt, ranBy: ranByCase.get(r.id) ?? null,
          // A hand-keyed case was CREATED, not "Imported" — the label is derived from case.plan,
          // which fires for both paths, so the source is what tells them apart.
          lastActionLabel:
            lastActionByCase.get(r.id)?.label === "Imported" && r.createdSource === "manual"
              ? "Created"
              : (lastActionByCase.get(r.id)?.label ?? null),
          lastActionBy: lastActionByCase.get(r.id)?.by ?? null,
          createdBy: r.createdBy?.startsWith("user:") ? r.createdBy.slice(5) : (r.createdBy ?? null),
          createdSource: r.createdSource,
          snAssignedTo: r.snAssignedTo, snAssignedToEmail: r.snAssignedToEmail, snAssigneeCheckedAt: r.snAssigneeCheckedAt,
          readiness, readinessMissing: planMissing,
          clientName: r.client.name, clientSlug: r.client.slug, jobCount: r.jobs.length,
          statusHint: needsInfo
            ? "Needs information — the intake left fields blank. Fill them in on the case page to release it."
            : scheduled
            ? r.scheduledFor
              ? "Scheduled — the case resumes automatically at the scheduled time (or resume it on the case page sooner)."
              : "Scheduled — an offboard is held on import (it may be future-dated). Resume on the case page when the offboard date arrives."
            : review
            ? "Held on import — review the planned steps on the case page and resume to run it."
            : operatorPaused
            ? "Paused by an operator — runners won't claim its steps. Resume on the case page."
            : buildCaseStatusHint(
                r.status,
                r.jobs,
                (k) => nameByKey.get(k) ?? k,
                centralOnline || clientHasRunner.has(r.clientId),
                missingSecrets
              ),
        };
      });
    },

    // Cases in the trash (soft-deleted) — for the collapsible Trash section. Newest-trashed first.
    async listTrashedCases(scope: ClientScope = null): Promise<TrashedCaseItem[]> {
      const rows = await db.caseRequest.findMany({
        where: { deletedAt: { not: null }, clientId: clientIdWhere(scope) },
        orderBy: { deletedAt: "desc" },
        select: {
          id: true, action: true, status: true, subject: true, serviceNowCaseNumber: true,
          deletedAt: true, client: { select: { name: true } }, _count: { select: { jobs: true } },
        },
      });
      return rows.map((r) => ({
        id: r.id, action: r.action, status: r.status, subject: r.subject,
        serviceNowCaseNumber: r.serviceNowCaseNumber, deletedAt: r.deletedAt as Date,
        clientName: r.client.name, jobCount: r._count.jobs,
      }));
    },

    // Move a case to the trash (soft delete) — removed from the list, restorable for 30 days. Jobs
    // are kept (so a restore brings back the run history). Refuses while a job is genuinely in
    // flight so we don't orphan a runner mid-execution. Idempotent if already trashed.
    async trashCase(id: string): Promise<
      | { ok: true; subject: string | null; clientId: string }
      | { ok: false; reason: "not_found" | "in_flight" }
    > {
      const inFlight = (jobs: { status: string }[]) => jobs.some((j) => j.status === "dispatched" || j.status === "running");
      const c = await db.caseRequest.findUnique({
        where: { id },
        select: { id: true, subject: true, clientId: true, deletedAt: true, jobs: { select: { status: true } } },
      });
      if (!c) return { ok: false, reason: "not_found" };
      if (c.deletedAt) return { ok: true, subject: c.subject, clientId: c.clientId }; // already trashed (idempotent)
      if (inFlight(c.jobs)) return { ok: false, reason: "in_flight" };
      // Set deletedAt first — that immediately removes the case from the claim query — then re-check
      // for a job a runner dispatched in the read->write race window; if one snuck in, roll back.
      await db.caseRequest.update({ where: { id }, data: { deletedAt: new Date() } });
      const after = await db.job.findMany({ where: { caseRequestId: id }, select: { status: true } });
      if (inFlight(after)) {
        await db.caseRequest.update({ where: { id }, data: { deletedAt: null } });
        return { ok: false, reason: "in_flight" };
      }
      return { ok: true, subject: c.subject, clientId: c.clientId };
    },

    // Restore a trashed case back to the list. Also used by re-import (re-importing a trashed
    // number brings it back rather than colliding on the unique SN number).
    async restoreCase(id: string): Promise<{ ok: true; clientId: string } | { ok: false; reason: "not_found" }> {
      const c = await db.caseRequest.findUnique({ where: { id }, select: { id: true, clientId: true, deletedAt: true } });
      if (!c) return { ok: false, reason: "not_found" };
      if (c.deletedAt) await db.caseRequest.update({ where: { id }, data: { deletedAt: null } }); // no-op write if not trashed
      return { ok: true, clientId: c.clientId };
    },

    // Permanently delete a case and its jobs (Job.case isn't onDelete:Cascade, so remove jobs first
    // in a transaction). AuditLog rows are an unconstrained log — left intact as history. The case
    // MUST already be in the trash: that's the only way to reach "delete forever" in the UI, and it
    // guarantees the case isn't in flight (trashing refuses that), so a direct ?forever=1 call can't
    // hard-delete a live/running case out from under a runner.
    async deleteCaseForever(id: string): Promise<{ ok: true; subject: string | null; clientId: string } | { ok: false; reason: "not_found" | "not_trashed" }> {
      const c = await db.caseRequest.findUnique({ where: { id }, select: { id: true, subject: true, clientId: true, deletedAt: true } });
      if (!c) return { ok: false, reason: "not_found" };
      if (!c.deletedAt) return { ok: false, reason: "not_trashed" };
      await db.$transaction([
        db.job.deleteMany({ where: { caseRequestId: id } }),
        db.caseRequest.delete({ where: { id } }),
      ]);
      return { ok: true, subject: c.subject, clientId: c.clientId };
    },

    // Hard-delete every case that has sat in the trash past the retention window (called on the
    // cases page load, mirroring the agents purge). Returns the count purged.
    async purgeExpiredTrashedCases(cutoff: Date): Promise<number> {
      // Cap the batch so a large backlog (e.g. a mass-trash) can't turn one page load into a single
      // huge delete transaction that stalls the request and contends with runner writes — the
      // remainder is purged on subsequent loads.
      const PURGE_BATCH = 200;
      const expired = await db.caseRequest.findMany({
        where: { deletedAt: { not: null, lte: cutoff } },
        select: { id: true },
        take: PURGE_BATCH,
      });
      if (expired.length === 0) return 0;
      const ids = expired.map((e) => e.id);
      await db.$transaction([
        db.job.deleteMany({ where: { caseRequestId: { in: ids } } }),
        db.caseRequest.deleteMany({ where: { id: { in: ids } } }),
      ]);
      return ids.length;
    },

    // `scope` (default unrestricted) hard-gates direct access: a case of a hidden client reads as
    // not-found (404) so it can't be loaded by guessing the case id.
    async getCase(id: string, scope: ClientScope = null): Promise<CaseDetail | null> {
      const c = await db.caseRequest.findUnique({
        where: { id },
        include: {
          // backbone: which directory actually masters this client's identities. The pre-run password
          // reset picks its target lane from it (FR #0000080).
          client: { select: { name: true, slug: true, backbone: true } },
          jobs: { orderBy: { sequence: "asc" } },
        },
      });
      if (!c) return null;
      if (!scopeAllows(scope, c.clientId)) return null;

      // Job stores only systemKey; resolve display names from the catalog in one query.
      const keys = [...new Set(c.jobs.map((j) => j.systemKey))];
      const catalog = await db.systemCatalog.findMany({
        where: { key: { in: keys } },
        select: { key: true, name: true },
      });
      const nameByKey = new Map(catalog.map((s) => [s.key, s.name]));

      return {
        id: c.id, action: c.action, status: c.status, subject: c.subject, dryRun: c.dryRun,
        serviceNowCaseNumber: c.serviceNowCaseNumber, createdAt: c.createdAt,
        createdBy: c.createdBy?.startsWith("user:") ? c.createdBy.slice(5) : (c.createdBy ?? null),
        createdSource: c.createdSource,
        client: c.client,
        payload: (c.payload ?? {}) as Record<string, unknown>,
        jobs: c.jobs.map((j) => {
          const req = (j.request ?? {}) as { requiresApproval?: boolean };
          return {
            id: j.id,
            systemKey: j.systemKey,
            systemName: unmodeledStepTitle(j.request) ?? nameByKey.get(j.systemKey) ?? ADHOC_STEP_LABELS[j.systemKey] ?? j.systemKey,
            sequence: j.sequence,
            mode: j.mode,
            status: j.status,
            requiresApproval: Boolean(req.requiresApproval),
            isManual: j.mode !== "api",
          };
        }),
      };
    },

    async writeAudit(entry: AuditEntry): Promise<void> {
      await db.auditLog.create({
        data: {
          actor: entry.actor,
          userId: entry.userId ?? null,
          action: entry.action,
          clientId: entry.clientId ?? null,
          caseRequestId: entry.caseRequestId ?? null,
          detail: (entry.detail ?? undefined) as Prisma.InputJsonValue | undefined,
        },
      });
    },
  };
}

export type CaseRepository = ReturnType<typeof makeCaseRepository>;
