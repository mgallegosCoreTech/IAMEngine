// GET/POST /api/clients/:slug/m365-license-rules — the per-client M365 licensing RULES
// (config.onboard.licenseRules): an ordered list of { when, licenses } evaluated at plan time so a
// new user's license depends on intake facts (e.g. needs a computer → E5, else E1). First matching
// rule wins; an explicit license on the ServiceNow ticket overrides these. Re-plan open cases to apply.
// A child client that hasn't set its own rules uses its parent's (applyParentInheritance); POST
// { inherit: true } clears the child's own so it goes back to them. An empty list is a deliberate "none".
import { NextResponse } from "next/server";
import { guard } from "@/lib/auth/route-guard";
import { clientSlugInScope } from "@/lib/auth/client-scope";
import { Prisma } from "@prisma/client";
import { db } from "@/lib/db";
import { recordAudit } from "@/lib/auth/audit";
import { validateCondition } from "@/lib/profiles/condition-builder";
import { normalizeLicenseRules } from "@/lib/m365/license-rules";

export const dynamic = "force-dynamic";

async function m365System(slug: string) {
  return db.clientSystem.findFirst({ where: { client: { slug }, systemKey: "m365" }, select: { id: true, config: true, clientId: true } });
}

export async function GET(_req: Request, { params }: { params: { slug: string } }) {
  const g = await guard("client.edit_systems"); if (g.res) return g.res;
  // scope-gated: an out-of-scope client reads as not-found (see clientSlugInScope).
  if (!(await clientSlugInScope(db, params.slug))) return NextResponse.json({ error: "not found" }, { status: 404 });
  const sys = await m365System(params.slug);
  if (!sys) return NextResponse.json({ error: "this client has no m365 system" }, { status: 404 });
  const onboard = ((sys.config ?? {}) as { onboard?: { licenseRules?: unknown } }).onboard ?? {};
  return NextResponse.json({ rules: normalizeLicenseRules(onboard.licenseRules) });
}

export async function POST(req: Request, { params }: { params: { slug: string } }) {
  const g = await guard("client.edit_systems"); if (g.res) return g.res;
  // scope-gated: an out-of-scope client reads as not-found (see clientSlugInScope).
  if (!(await clientSlugInScope(db, params.slug))) return NextResponse.json({ error: "not found" }, { status: 404 });
  let body: { rules?: unknown; inherit?: unknown };
  try { body = await req.json(); } catch { return NextResponse.json({ error: "invalid JSON body" }, { status: 422 }); }
  if (body.inherit === true) {
    const sys = await m365System(params.slug);
    if (!sys) return NextResponse.json({ error: "this client has no m365 system" }, { status: 404 });
    const config = { ...((sys.config ?? {}) as Record<string, unknown>) };
    const onboard = { ...((config.onboard ?? {}) as Record<string, unknown>) };
    delete onboard.licenseRules;
    config.onboard = onboard;
    await db.clientSystem.update({ where: { id: sys.id }, data: { config: config as Prisma.InputJsonValue } });
    await recordAudit("client.m365_license_rules.inherit", { user: g.user, clientId: sys.clientId, detail: {} });
    return NextResponse.json({ ok: true, rules: [] });
  }
  if (!Array.isArray(body.rules)) return NextResponse.json({ error: "rules must be an array" }, { status: 422 });

  // Validate each condition before saving so a rule can't silently never-fire (mirrors validateRules).
  for (const r of body.rules) {
    const when = r && typeof r === "object" ? (r as { when?: unknown }).when : undefined;
    if (typeof when === "string" && when.trim()) {
      const v = validateCondition(when);
      if (!v.ok) return NextResponse.json({ error: `condition "${when}": ${v.error}` }, { status: 422 });
    }
  }
  const rules = normalizeLicenseRules(body.rules);

  const sys = await m365System(params.slug);
  if (!sys) return NextResponse.json({ error: "this client has no m365 system" }, { status: 404 });

  const config = { ...((sys.config ?? {}) as Record<string, unknown>) };
  config.onboard = { ...((config.onboard ?? {}) as Record<string, unknown>), licenseRules: rules };
  await db.clientSystem.update({ where: { id: sys.id }, data: { config: config as Prisma.InputJsonValue } });
  await recordAudit("client.m365_license_rules.set", { user: g.user, clientId: sys.clientId, detail: { count: rules.length } });

  return NextResponse.json({ ok: true, rules });
}
