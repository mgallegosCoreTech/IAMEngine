// PATCH /api/cases/:id/delegate-automapping { autoMapping: true | false | null } — FR #0000211.
// This offboard's choice of whether its mailbox delegates' Full Access also adds the leaver's mailbox
// to their Outlook (AutoMapping). null goes back to the client's default. Writes the case payload (so
// a re-plan keeps it) and the exchange job's config (so it applies now), and is refused once the
// exchange step has started: AutoMapping is fixed when the access is granted. See
// lib/cases/delegate-automapping.ts.
import { NextResponse } from "next/server";
import { guard } from "@/lib/auth/route-guard";
import { caseInScope } from "@/lib/auth/client-scope";
import { Prisma } from "@prisma/client";
import { db } from "@/lib/db";
import { recordAudit } from "@/lib/auth/audit";
import { applyAutoMappingChoice, clientAutoMappingDefault } from "@/lib/cases/delegate-automapping";

export const dynamic = "force-dynamic";

export async function PATCH(req: Request, { params }: { params: { id: string } }) {
  const g = await guard("case.dispatch"); if (g.res) return g.res;
  if (!(await caseInScope(db, params.id))) return NextResponse.json({ error: "not found" }, { status: 404 });

  let body: { autoMapping?: unknown };
  try { body = await req.json(); } catch { return NextResponse.json({ error: "invalid JSON body" }, { status: 422 }); }
  if (!(typeof body.autoMapping === "boolean" || body.autoMapping === null)) {
    return NextResponse.json({ error: "autoMapping must be true, false or null (the client default)" }, { status: 422 });
  }

  const c = await db.caseRequest.findUnique({
    where: { id: params.id },
    select: {
      action: true, payload: true,
      client: { select: { id: true, parentId: true } },
      jobs: { where: { systemKey: "exchange" }, select: { id: true, systemKey: true, status: true, request: true } },
    },
  });
  if (!c) return NextResponse.json({ error: "case not found" }, { status: 404 });
  if (c.action !== "offboard") return NextResponse.json({ error: "only an offboarding delegates the mailbox" }, { status: 422 });

  // The client default, for "back to the client default". A child planning with its parent's systems
  // has no exchange row of its own.
  const own = await db.clientSystem.findFirst({ where: { clientId: c.client.id, systemKey: "exchange" }, select: { config: true } });
  const sys = own ?? (c.client.parentId
    ? await db.clientSystem.findFirst({ where: { clientId: c.client.parentId, systemKey: "exchange" }, select: { config: true } })
    : null);

  const change = applyAutoMappingChoice(body.autoMapping, (c.payload ?? {}) as Record<string, unknown>, c.jobs, clientAutoMappingDefault(sys?.config ?? null));
  if (!change.ok) return NextResponse.json({ error: change.error }, { status: change.status });

  // The exchange job is only written while it still hasn't started: a runner can claim it between the
  // check above and this write, and then the grant is already on its way with the old setting.
  class Started extends Error {}
  try {
    await db.$transaction(async (tx) => {
      for (const j of change.jobs) {
        const current = c.jobs.find((x) => x.id === j.id)!;
        const request = { ...((current.request ?? {}) as Record<string, unknown>), config: j.config };
        const r = await tx.job.updateMany({
          where: { id: j.id, status: { notIn: ["dispatched", "running", "succeeded", "failed"] } },
          data: { request: request as Prisma.InputJsonValue },
        });
        if (r.count === 0) throw new Started();
      }
      await tx.caseRequest.update({ where: { id: params.id }, data: { payload: change.payload as Prisma.InputJsonValue } });
    });
  } catch (e) {
    if (e instanceof Started) return NextResponse.json({ error: "the Exchange step has just started, so its delegate access is already decided" }, { status: 409 });
    throw e;
  }
  await recordAudit("case.delegate_automapping.set", { user: g.user, caseRequestId: params.id, detail: { autoMapping: body.autoMapping } });

  return NextResponse.json({ ok: true, autoMapping: body.autoMapping });
}
