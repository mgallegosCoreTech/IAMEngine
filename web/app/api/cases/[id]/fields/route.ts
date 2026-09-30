// PATCH /api/cases/:id/fields { fields: { <field>: <value> } } — fill in the "Needs Information"
// fields the intake couldn't determine, or correct one the ticket got wrong. Merges into the case
// payload, drops the filled keys from payload.unknownFields, and releases the hold once nothing's
// left to fill.
//
// Then RE-PLANS an unstarted case (FR #0000091). The payload alone is not enough: the runner reads
// user fields from it at claim time, but job CONFIGS — groups, licences, attributes, OU — were
// computed at plan time by the rules and personas, so a corrected department left every rule still
// holding the ticket's original value and the correction silently did not take.
import { NextResponse } from "next/server";
import { guard } from "@/lib/auth/route-guard";
import { caseInScope } from "@/lib/auth/client-scope";
import { Prisma } from "@prisma/client";
import { db } from "@/lib/db";
import { makeCaseRepository } from "@/lib/cases/repository";
import { replanCase } from "@/lib/cases/replan-service";
import { recordAudit } from "@/lib/auth/audit";
import { auditActor } from "@/lib/auth/actor";

export const dynamic = "force-dynamic";

export async function PATCH(req: Request, { params }: { params: { id: string } }) {
  const g = await guard("case.dispatch"); if (g.res) return g.res;
  if (!(await caseInScope(db, params.id))) return NextResponse.json({ error: "not found" }, { status: 404 });

  let body: { fields?: unknown };
  try { body = await req.json(); } catch { return NextResponse.json({ error: "invalid JSON body" }, { status: 422 }); }
  const fields = body.fields && typeof body.fields === "object" ? (body.fields as Record<string, unknown>) : {};

  const c = await db.caseRequest.findUnique({
    where: { id: params.id },
    select: { payload: true, pausedReason: true, jobs: { where: { startedAt: { not: null } }, select: { id: true }, take: 1 } },
  });
  if (!c) return NextResponse.json({ error: "case not found" }, { status: 404 });

  const payload = { ...((c.payload ?? {}) as Record<string, unknown>) };
  const unknown = Array.isArray(payload.unknownFields) ? (payload.unknownFields as { field: string }[]) : [];

  // Every key the operator submitted is "touched" (written, even to blank — clearing a wrong value
  // must take effect); "filled" = non-empty (these release an unknown and re-derive UPN siblings).
  const touched: string[] = [];
  const filled: string[] = [];
  for (const [k, v] of Object.entries(fields)) {
    const val = typeof v === "string" ? v.trim() : v;
    payload[k] = val;
    touched.push(k);
    if (typeof val === "string" ? val !== "" : val != null) filled.push(k);
  }
  // Editing the UPN must keep its siblings consistent (deriveIdentity computed them together) — the
  // AD lane reads samAccountName independently, so leaving it stale creates an account that doesn't
  // match the new UPN. Re-derive the local-part-based fields from the new UPN.
  if (filled.includes("userPrincipalName") && typeof payload.userPrincipalName === "string") {
    const upn = payload.userPrincipalName;
    const local = upn.split("@")[0] ?? upn;
    payload.samAccountName = local.slice(0, 20); // AD samAccountName max length
    payload.mailNickname = local;
    payload.workEmail = upn;
  }
  const remaining = unknown.filter((u) => !filled.includes(u.field));
  payload.unknownFields = remaining;
  if (filled.includes("usageLocation")) payload.usageLocationDerived = true;
  // Mark every operator-edited field as such (for the review provenance badge) and drop its stale
  // "AI-filled" note — a hand-entered value is no longer machine-derived.
  const fieldSource = { ...((payload.fieldSource ?? {}) as Record<string, string>) };
  for (const k of touched) fieldSource[k] = "operator";
  payload.fieldSource = fieldSource;
  if (payload.aiResolved && typeof payload.aiResolved === "object") {
    const ai = { ...(payload.aiResolved as Record<string, string>) };
    for (const k of touched) delete ai[k];
    payload.aiResolved = Object.keys(ai).length ? ai : undefined;
  }

  await db.caseRequest.update({ where: { id: params.id }, data: { payload: payload as Prisma.InputJsonValue } });

  // Re-run the rules and roles against the corrected value (FR #0000091). Job CONFIGS — groups,
  // licences, attributes, OU — are computed at PLAN time from the payload, so writing the new value
  // alone left every rule that keyed on it still holding the ticket's original.
  //
  // NOT on a case that has already started: an incremental re-plan can add or re-run steps, and a
  // field save must not reshape a run in flight. Those keep today's behaviour and the explicit
  // Re-plan button. Best-effort either way — the edit itself is already saved and is what the
  // operator asked for, so a re-plan failure is REPORTED, never a failed save.
  let replanned: string | null = null;
  if (c.jobs.length === 0) {
    try {
      const r = await replanCase(db, params.id, auditActor(g.user, "ui"));
      replanned = r.ok ? "replanned" : r.error;
    } catch (e) {
      replanned = e instanceof Error ? e.message : String(e);
    }
  }

  // Teams Phone: a number typed on a case that has already started isn't re-planned above, but it must
  // still reach the teams step — which, right after onboarding, is often waiting on its licence. Write
  // it onto any teams job not being worked on right now. One that already assigned a number is harmless
  // to update: the runner never replaces a number a user already has.
  if (c.jobs.length > 0 && touched.includes("teamsPhoneNumber")) {
    const teams = await db.job.findMany({ where: { caseRequestId: params.id, systemKey: "teams", status: { notIn: ["dispatched", "running"] } }, select: { id: true, request: true } });
    for (const t of teams) {
      const reqJson = { ...((t.request ?? {}) as Record<string, unknown>) };
      reqJson.config = { ...((reqJson.config ?? {}) as Record<string, unknown>), phoneNumber: payload.teamsPhoneNumber || null };
      await db.job.update({ where: { id: t.id }, data: { request: reqJson as Prisma.InputJsonValue } });
    }
  }

  // Release the "needs_info" hold once everything's provided.
  if (c.pausedReason === "needs_info" && remaining.length === 0) {
    await makeCaseRepository(db).setHold(params.id, null);
  }
  await recordAudit("case.fields.filled", { user: g.user, caseRequestId: params.id, detail: { filled, remaining: remaining.length } });

  return NextResponse.json({ ok: true, filled, remaining: remaining.length, replanned, released: c.pausedReason === "needs_info" && remaining.length === 0 });
}
