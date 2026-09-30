// Seeds the DB from profiles/*.json (hand-authored, authoritative) and then from
// profiles/generated/*.json (KB-generated drafts). Generated profiles only ENRICH existing
// roster clients (matched by slug during generation) — they never create new clients and
// never clobber a hand-authored profile.
// DB-EDIT GUARD: ClientSystem rows, Secret references, client plan blocks (personas/globals/
// locations), and existing runbooks that differ from the profile are treated as DB-edited and
// KEPT (the Edit-systems UI, the fleet sweeps, the Delinea rewiring, the rules editor and the KB
// fetch pipeline all write state the profiles don't have); pass --force to overwrite. See
// lib/clients/seed-guard.ts.
// Run via: npx prisma db seed   (for --force: npx tsx prisma/seed.ts --force)
import { PrismaClient, Prisma } from "@prisma/client";
import { readdirSync, readFileSync, existsSync } from "fs";
import { join } from "path";
import { parseRunbookText } from "../lib/clients/runbook-parse";
import { clientSystemMatches, stableEqual, type SeedSystemFields } from "../lib/clients/seed-guard";
import { seedDocuments } from "./seed-docs";

const prisma = new PrismaClient();
// RESEED PROTECTION: ClientSystem rows whose current values differ from the profile are treated as
// DB-edited (Edit-systems OUs, the licence sweep's offboard config, mailbox policies — none of it
// lives in the profile JSON) and are KEPT. --force overwrites them back to profile values. Rows that
// already match are a no-op either way. Invoke directly for the flag: `npx tsx prisma/seed.ts --force`
// (`prisma db seed` does not forward args).
const FORCE = process.argv.includes("--force");
const keptRows: Array<{ client: string; systemKey: string }> = [];
const keptSecrets: Array<{ client: string; name: string }> = [];
const keptClientFields: Array<{ client: string; field: string }> = [];
let keptRunbooks = 0;
const PROFILES = join(process.cwd(), "..", "profiles");
// Generated drafts are produced by tools/profile-generator (the canonical generator) into
// profiles/_drafts/. Pass 2 enriches existing roster clients from these.
const GENERATED = join(PROFILES, "_drafts");

const backboneMap: Record<string, "entra" | "google" | "ad_synced" | "ad_standalone"> = {
  entra: "entra", google: "google", "ad-synced": "ad_synced", "ad-standalone": "ad_standalone",
};
const laneMap: Record<string, "always" | "on_request" | "never" | "by_persona"> = {
  always: "always", "on-request": "on_request", never: "never", "by-persona": "by_persona",
};

const CATALOG: Array<[string, string, number, string?]> = [
  ["servicenow", "ServiceNow", 1, "Coretelligent.ServiceNow"],
  ["m365", "Microsoft 365", 1, "Coretelligent.M365"],
  ["entra", "Entra", 1, "Coretelligent.M365"],
  ["tap", "Temporary Access Pass", 2, "Coretelligent.M365"],
  ["exchange", "Exchange", 1, "Coretelligent.M365"],
  ["active-directory", "Active Directory", 2, "Coretelligent.ActiveDirectory"],
  ["directory-sync", "Entra Connect sync", 2, "Coretelligent.ActiveDirectory"],
  ["mimecast", "Mimecast", 2, "Coretelligent.Mimecast"], ["adobe", "Adobe", 2, "Coretelligent.Adobe"], ["google-workspace", "Google Workspace", 2, "Coretelligent.GoogleWorkspace"],
  ["knowbe4", "KnowBe4", 2, "Coretelligent.KnowBe4"], ["sharepoint", "SharePoint", 3], ["spanning", "Spanning", 3, "Coretelligent.Spanning"],
  ["zoom", "Zoom", 3, "Coretelligent.Zoom"], ["slack", "Slack", 3, "Coretelligent.Slack"], ["egnyte", "Egnyte", 3, "Coretelligent.Egnyte"], ["mdm", "MDM (Addigy/Jamf/Intune)", 3],
  ["proofpoint", "Proofpoint", 3], ["dropbox", "Dropbox", 3], ["perimeter81", "Perimeter 81", 3, "Coretelligent.Perimeter81"],
  ["teams", "Teams Phone", 3, "Coretelligent.Teams"], ["avd", "Azure Virtual Desktop", 3], ["1password", "1Password", 3, "Coretelligent.1Password"],
  ["tableau", "Tableau", 3], ["notion", "Notion", 3], ["printix", "Printix", 3], ["uniflow", "UniFlow secure printing", 3],
  ["salesforce", "Salesforce", 3, "Coretelligent.Salesforce"], ["jira", "Jira (Atlassian)", 3, "Coretelligent.Jira"], ["hubspot", "HubSpot", 3, "Coretelligent.HubSpot"],
  ["sentinelone", "SentinelOne", 2, "Coretelligent.SentinelOne"], ["duo", "Duo Security", 3, "Coretelligent.Duo"],
  ["xmatters", "xMatters", 3, "Coretelligent.XMatters"], ["logicmonitor", "LogicMonitor", 3, "Coretelligent.LogicMonitor"],
  ["notify", "Offboard notification", 3, "Coretelligent.Notify"],
  ["hardware", "Hardware", 3], ["workstation", "Workstation", 3], ["welcome-letter", "Welcome letter", 3],
  ["first-day-call", "First-day call", 3], ["case-resolution", "Case resolution", 1],
  // Ad-hoc operator actions (dispatched on demand from a case line, never planned):
  ["ad-password-reset", "Password reset (AD)", 2, "Coretelligent.ActiveDirectory"],
  ["m365-password-reset", "Password reset (M365)", 1, "Coretelligent.M365"],
  ["google-password-reset", "Password reset (Google)", 2, "Coretelligent.GoogleWorkspace"],
  // long-tail keys the Phase-6 generator can emit; needed so a promoted draft seeds without a FK error
  ["data-transfer", "Data transfer", 2], ["archive", "Archive", 3],
  ["egnyte-sync-server", "Egnyte Sync Server", 3], ["address-book", "Printer address book", 3],
  ["equipment-return", "Equipment return", 3],
];

// Normalised client-name key for matching generated profiles to roster clients (whose slugs
// are CORE ids, so slug equality never matches a name-slugged generated profile).
function normName(s: string): string {
  return (s || "").toLowerCase().replace(/&/g, " and ").replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
}
function stripSuffix(n: string): string {
  return n.replace(/\b(llc|inc|lp|llp|ltd|co|corp|corporation|company|holdings|partners|capital|group|management|the)\b/g, " ").replace(/\s+/g, " ").trim();
}

async function upsertSecretsAndSystems(clientId: string, p: any): Promise<void> {
  const clientLabel = p.client?.name ?? p.client?.id ?? clientId;
  // Secrets get the same protection as systems: DB-side rewires (the Delinea recovery re-pointed
  // 319 slots directly in the DB; the app UI wires more) are NOT in the profile JSON, and a reseed
  // that rewrote externalId would silently send jobs to a stale — or another tenant's — secret.
  const existingSecrets = await prisma.secret.findMany({ where: { clientId }, select: { name: true, externalId: true, label: true } });
  const secretByName = new Map(existingSecrets.map((s) => [s.name, s]));
  for (const [secName, ref] of Object.entries<any>(p.secrets ?? {})) {
    const ex = secretByName.get(secName);
    if (!ex) {
      // upsert with an empty update: atomic against a row appearing since the fetch (left as-is).
      await prisma.secret.upsert({
        where: { clientId_name: { clientId, name: secName } },
        update: {},
        create: { clientId, name: secName, provider: ref.provider, externalId: ref.id, label: ref.label ?? null },
      });
      continue;
    }
    if (ex.externalId === ref.id && (ex.label ?? null) === (ref.label ?? null)) continue;
    if (!FORCE) { keptSecrets.push({ client: clientLabel, name: secName }); continue; }
    await prisma.secret.update({ where: { clientId_name: { clientId, name: secName } }, data: { externalId: ref.id, label: ref.label ?? null } });
  }
  // One fetch for the client's rows instead of one per system — a full reseed touches ~200 clients.
  const existingRows = await prisma.clientSystem.findMany({
    where: { clientId },
    select: { systemKey: true, mode: true, onboardWhen: true, offboardWhen: true, dependsOn: true, requiresApproval: true, captureEvidence: true, secretNames: true, config: true },
  });
  const rowByKey = new Map(existingRows.map((r) => [r.systemKey, r]));
  for (const s of p.systems) {
    // Build the full field set once so create and update can't drift apart.
    const fields = {
      mode: s.mode,
      onboardWhen: laneMap[s.onboard?.when ?? "never"] ?? "never",
      offboardWhen: laneMap[s.offboard?.when ?? "never"] ?? "never",
      dependsOn: s.dependsOn ?? [],
      // collapsed columns kept for the UI's coarse "needs approval / captures evidence" badge…
      requiresApproval: Boolean(s.onboard?.requiresApproval || s.offboard?.requiresApproval),
      captureEvidence: Boolean(s.onboard?.captureEvidence || s.offboard?.captureEvidence),
      secretNames: s.secrets ?? [],
      // …while config carries the authoritative PER-LANE flags + lane config + lane deps the
      // orchestrator resolves (so an offboard-only approval gate never fires on an onboard).
      config: {
        onboard: s.onboard?.config ?? null,
        offboard: s.offboard?.config ?? null,
        dependsOn: { onboard: s.onboard?.dependsOn, offboard: s.offboard?.dependsOn },
        requiresApproval: { onboard: Boolean(s.onboard?.requiresApproval), offboard: Boolean(s.offboard?.requiresApproval) },
        captureEvidence: { onboard: Boolean(s.onboard?.captureEvidence), offboard: Boolean(s.offboard?.captureEvidence) },
        // planner hint (orchestrator): runLast systems implicitly depend on every other active system
        ...(s.runLast ? { runLast: true } : {}),
      },
    };
    const existing = rowByKey.get(s.key);
    if (!existing) {
      // upsert with an empty update: atomic against a row appearing since the fetch (left as-is).
      await prisma.clientSystem.upsert({
        where: { clientId_systemKey: { clientId, systemKey: s.key } },
        update: {},
        create: { clientId, systemKey: s.key, ...fields },
      });
      continue;
    }
    if (clientSystemMatches(existing as SeedSystemFields, fields as SeedSystemFields)) continue; // already what we'd write
    if (!FORCE) { keptRows.push({ client: clientLabel, systemKey: s.key }); continue; } // DB-edited — keep it
    await prisma.clientSystem.update({ where: { clientId_systemKey: { clientId, systemKey: s.key } }, data: fields });
  }
}

// The plan-time JSON blocks (personas/globals/locations) the seed may write for this client: a
// profile value only lands when the DB column is empty, still equals it, or --force is passed —
// the Roles & rules editor persists edits into these columns without any editedFields stamp, so
// "differs from the profile" is the only provenance a reseed has.
function protectedPlanBlocks(
  p: any,
  existing: { personas?: unknown; globals?: unknown; locations?: unknown } | null,
  clientLabel: string
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const field of ["personas", "globals", "locations"] as const) {
    const fromProfile = p[field];
    if (fromProfile === undefined || fromProfile === null) continue; // profile says nothing — column left as-is
    const inDb = existing?.[field] ?? null;
    if (inDb !== null && !stableEqual(inDb, fromProfile) && !FORCE) {
      keptClientFields.push({ client: clientLabel, field });
      continue;
    }
    out[field] = fromProfile;
  }
  return out;
}

// Drop fields a human edited in the UI (Client.editedFields) from a seed update, so a reseed
// doesn't clobber manual corrections — matching the routine sync's behaviour. A field that was
// never edited is written normally.
function stripEdited<T extends Record<string, any>>(data: T, editedFields: string[]): Partial<T> {
  const d: Record<string, any> = { ...data };
  if (editedFields.includes("primaryDomain")) { delete d.primaryDomain; delete d.domains; }
  if (editedFields.includes("backbone")) delete d.backbone;
  if (editedFields.includes("usernamePattern")) delete d.identity; // identity holds usernamePatterns
  return d as Partial<T>;
}

// Hand-authored profiles are authoritative: upsert the client by its own slug (create
// allowed). Returns the client id (so the generated pass can protect it by id, not name).
async function applyAuthored(p: any): Promise<string | null> {
  if (p.schemaVersion !== "2.0" && p.schemaVersion !== "2.1") return null;
  const backbone = backboneMap[p.identity.backbone];
  if (!backbone) { console.warn(`skip ${p.client.id}: unknown backbone "${p.identity.backbone}"`); return null; }
  const existing = await prisma.client.findUnique({ where: { slug: p.client.id }, select: { editedFields: true, emailDomainLocked: true, personas: true, globals: true, locations: true } });
  // v2.1 plan-time blocks (undefined for v2.0 profiles → column left null). The Roles & rules editor
  // writes these columns in-app WITHOUT stamping editedFields — so a DB value that differs from the
  // profile is a rules-editor edit and is KEPT unless --force (same rule as ClientSystem config).
  const planBlocks = protectedPlanBlocks(p, existing ?? null, p.client.id);
  // Don't overwrite an email domain a human locked in the UI.
  const emailDomain = existing?.emailDomainLocked ? undefined : (p.client.emailDomain ?? undefined);
  const intakeSource = p.client.intakeSource ?? undefined; // "incident" for internal clients (Coretelligent)
  const update = stripEdited(
    { backbone, pod: p.client.pod ?? undefined, primaryDomain: p.client.primaryDomain, domains: p.client.domains ?? [], emailDomain, identity: p.identity ?? undefined, ...(intakeSource ? { intakeSource } : {}), ...planBlocks },
    existing?.editedFields ?? []
  );
  const client = await prisma.client.upsert({
    where: { slug: p.client.id },
    update,
    create: { slug: p.client.id, name: p.client.name, primaryDomain: p.client.primaryDomain, domains: p.client.domains ?? [], emailDomain, backbone, pod: p.client.pod ?? null, identity: p.identity ?? undefined, ...(intakeSource ? { intakeSource } : {}), ...planBlocks },
  });
  await upsertSecretsAndSystems(client.id, p);
  // Hand-authored runbook (for KB-less clients like Coretelligent): { runbook: { onboard, offboard } }
  // parsed into RunbookSection rows, replacing any existing for that action.
  if (p.runbook && typeof p.runbook === "object") {
    for (const action of ["onboard", "offboard"] as const) {
      const text = (p.runbook as Record<string, unknown>)[action];
      if (typeof text !== "string" || !text.trim()) continue;
      // Runbooks are rebuilt IN-APP too (the KB fetch pipeline writes RunbookSection directly), so an
      // existing runbook is kept on a reseed — replacing it needs --force, same as the config guard.
      if (!FORCE && (await prisma.runbookSection.count({ where: { clientId: client.id, action } })) > 0) { keptRunbooks++; continue; }
      const sections = parseRunbookText(text);
      await prisma.runbookSection.deleteMany({ where: { clientId: client.id, action } });
      if (sections.length) {
        await prisma.runbookSection.createMany({
          data: sections.map((s) => ({ clientId: client.id, action, seq: s.seq, systemKey: s.systemKey, title: s.title, status: s.status, steps: s.steps })),
        });
      }
    }
  }
  return client.id;
}

async function main() {
  for (const [key, name, buildTier, moduleName] of CATALOG) {
    await prisma.systemCatalog.upsert({
      where: { key }, update: { name, buildTier, moduleName },
      create: { key, name, buildTier, moduleName: moduleName ?? null },
    });
  }

  // Optional single-client target: `tsx prisma/seed.ts <profile-slug>` re-seeds JUST that authored
  // profile and SKIPS the generated pass — so it can't revert other clients' in-app config edits.
  // The DB-edit guard applies here too: rows differing from the profile are KEPT and reported. To
  // push a corrected profile value over a differing row, add --force (scoped to this one client:
  // `npx tsx prisma/seed.ts <profile-slug> --force`). No arg = full seed (all profiles + generated).
  // Flags (--force) are not slugs — the first non-flag arg is the optional profile target.
  const only = (process.argv.slice(2).find((a) => !a.startsWith("--")) ?? "").replace(/\.json$/i, "").toLowerCase();
  if (only) console.log(`single-client seed: ${only} (generated pass skipped)`);
  if (FORCE) console.log(`--force: DB-edited ClientSystem rows WILL be overwritten with profile values`);

  // Pass 1: hand-authored profiles (authoritative). Collect their client ids to protect them
  // (by id, not name) from the generated pass.
  const curatedIds = new Set<string>();
  for (const file of readdirSync(PROFILES).filter((f) => f.endsWith(".json") && !f.startsWith("_"))) {
    if (only && file.replace(/\.json$/i, "").toLowerCase() !== only) continue;
    const p = JSON.parse(readFileSync(join(PROFILES, file), "utf8"));
    const id = await applyAuthored(p);
    if (id) { curatedIds.add(id); console.log(`authored: ${p.client.name} (${p.systems.length} systems)`); }
    else console.warn(`skip ${file}: not schema 2.0`);
  }
  if (only && curatedIds.size === 0) console.warn(`no profile matched "${only}" — nothing seeded`);

  // Pass 2: generated drafts, matched to a client by NAME (then domain), since roster slugs
  // are CORE ids and won't equal a name-slugged generated profile. A curated client keeps its
  // authored systems but STILL gets its KB runbook (the steps are informational).
  let enriched = 0, curatedRb = 0, nonV2 = 0, unmatched = 0, runbook = 0;
  if (!only && existsSync(GENERATED)) {
    const clients = await prisma.client.findMany({ select: { id: true, name: true, primaryDomain: true, editedFields: true, personas: true, globals: true, locations: true } });
    const editedById = new Map(clients.map((c) => [c.id, c.editedFields]));
    const planById = new Map(clients.map((c) => [c.id, { personas: c.personas, globals: c.globals, locations: c.locations }]));
    const byName = new Map<string, string>();
    const byDomain = new Map<string, string>();
    const strippedGroups = new Map<string, Set<string>>();
    for (const c of clients) {
      byName.set(normName(c.name), c.id);
      if (c.primaryDomain) byDomain.set(c.primaryDomain.toLowerCase(), c.id);
      const sk = stripSuffix(normName(c.name));
      if (sk) (strippedGroups.get(sk) ?? strippedGroups.set(sk, new Set()).get(sk)!).add(c.id);
    }
    const byStrippedUnique = new Map<string, string>();
    for (const [k, ids] of strippedGroups) if (ids.size === 1) byStrippedUnique.set(k, [...ids][0]);

    for (const file of readdirSync(GENERATED).filter((f) => f.endsWith(".json") && !f.endsWith(".runbook.json") && !f.startsWith("_"))) {
      const p = JSON.parse(readFileSync(join(GENERATED, file), "utf8"));
      if (p.schemaVersion !== "2.0" && p.schemaVersion !== "2.1") { nonV2++; continue; }
      const nn = normName(p.client.name);
      const clientId =
        byName.get(nn) ??
        (p.client.primaryDomain ? byDomain.get(String(p.client.primaryDomain).toLowerCase()) : undefined) ??
        byStrippedUnique.get(stripSuffix(nn));
      if (!clientId) { unmatched++; continue; } // KB client not in the roster
      if (curatedIds.has(clientId)) {
        runbook += await loadRunbook(clientId, p.client.id); // keep authored systems; load runbook
        curatedRb++;
      } else {
        const backbone = backboneMap[p.identity.backbone];
        // v2.1 plan-time blocks the extractor recovered (groups/attributes -> globals, plus
        // personas/locations). Absent for a v2.0 draft → column left as-is; a DB value the rules
        // editor changed is KEPT unless --force (protectedPlanBlocks).
        const planBlocks = protectedPlanBlocks(p, planById.get(clientId) ?? null, p.client.name ?? p.client.id);
        const update = stripEdited({ ...(backbone ? { backbone } : {}), pod: p.client.pod ?? undefined, identity: p.identity ?? undefined, ...planBlocks }, editedById.get(clientId) ?? []);
        await prisma.client.update({ where: { id: clientId }, data: update });
        await upsertSecretsAndSystems(clientId, p);
        runbook += await loadRunbook(clientId, p.client.id);
        enriched++;
      }
    }
    console.log(`generated: ${enriched} enriched, ${curatedRb} curated (runbook only), ${nonV2} unknown-schema, ${unmatched} no roster match; ${runbook} runbook sections loaded`);
  }

  await seedDocuments(prisma);

  if (keptRows.length) {
    console.log(`\nKEPT ${keptRows.length} ClientSystem row(s) whose DB values differ from the profile (DB-side edits win on a reseed):`);
    const byClient = new Map<string, string[]>();
    for (const r of keptRows) (byClient.get(r.client) ?? byClient.set(r.client, []).get(r.client)!).push(r.systemKey);
    for (const [client, keys] of byClient) console.log(`  ${client}: ${keys.join(", ")}`);
  }
  if (keptSecrets.length) {
    console.log(`\nKEPT ${keptSecrets.length} Secret reference(s) that differ from the profile (DB-side rewires win):`);
    for (const s of keptSecrets) console.log(`  ${s.client}: ${s.name}`);
  }
  if (keptClientFields.length) {
    console.log(`\nKEPT ${keptClientFields.length} client plan block(s) (personas/globals/locations) that differ from the profile (rules-editor edits win):`);
    for (const f of keptClientFields) console.log(`  ${f.client}: ${f.field}`);
  }
  if (keptRunbooks) console.log(`\nKEPT ${keptRunbooks} existing runbook(s) (in-app rebuilds win over the on-disk drafts).`);
  if (keptRows.length || keptSecrets.length || keptClientFields.length || keptRunbooks) {
    console.log(`Re-run with --force (npx tsx prisma/seed.ts [profile] --force) to overwrite the kept values with profile values.`);
  }
}

// Load <slug>.runbook.json (the full step-by-step, modeled + unmodeled) into RunbookSection.
async function loadRunbook(clientDbId: string, slug: string): Promise<number> {
  const path = join(GENERATED, `${slug}.runbook.json`);
  if (!existsSync(path)) return 0;
  // A runbook already in the DB may have been rebuilt in-app (KB fetch pipeline) — the on-disk draft
  // is the STALER copy then. Keep the DB version on a reseed; replacing it needs --force.
  if (!FORCE && (await prisma.runbookSection.count({ where: { clientId: clientDbId } })) > 0) { keptRunbooks++; return 0; }
  const items = JSON.parse(readFileSync(path, "utf8")) as Array<{
    action: string; seq: number; systemKey: string | null; title: string; status: string; guess: string | null; steps: string[]; kbArticle?: string | null; artifacts?: unknown[];
  }>;
  await prisma.runbookSection.deleteMany({ where: { clientId: clientDbId } });
  if (items.length === 0) return 0;
  await prisma.runbookSection.createMany({
    data: items.map((i) => ({
      clientId: clientDbId,
      action: i.action.startsWith("off") ? "offboard" : "onboard", // "offboarding"/"offboard" -> offboard
      seq: i.seq,
      systemKey: i.systemKey ?? null,
      title: i.title,
      status: i.status,
      guess: i.guess ?? null,
      steps: i.steps ?? [],
      kbArticle: i.kbArticle ?? null,
      artifacts: i.artifacts && i.artifacts.length ? (i.artifacts as Prisma.InputJsonValue) : undefined,
    })),
  });
  return items.length;
}

main().catch((e) => { console.error(e); process.exit(1); }).finally(() => prisma.$disconnect());
