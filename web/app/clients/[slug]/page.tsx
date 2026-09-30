// Client detail (server component): roster metadata + the modeled systems and their flags.
import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { db } from "@/lib/db";
import { makeClientRepository } from "@/lib/clients/repository";
import { currentClientScope, scopeAllows } from "@/lib/auth/client-scope";
import { findClientByCoreIdSlug } from "@/lib/clients/coreid-redirect";
import { currentIsSuperAdmin } from "@/lib/auth/acting";
import { RestrictedToggle } from "../_components/restricted-toggle";
import { OwnAgentToggle } from "../_components/own-agent-toggle";
import { NoRunnerToggle } from "../_components/no-runner-toggle";
import { EngineOptOutToggle } from "../_components/engine-opt-out-toggle";
import { ParentInheritanceControl } from "../_components/parent-inheritance-control";
import { ParentModelingToggle } from "../_components/parent-modeling-toggle";
import { kbUrl } from "@/lib/servicenow/kb-url";
import { automationPreview } from "@/lib/automation";
import { MODULES } from "@/lib/modules/catalog";
import { asArtifacts } from "@/lib/runbook/artifacts";
import { ClientActionsMenu } from "../_components/client-actions-menu";
import { SyncSystemsButton } from "../_components/sync-systems-button";
import { AddDirectorySyncButton } from "../_components/add-directory-sync-button";
import { EmailDomainsEditor } from "../_components/email-domains-editor";
import { AdDomainEditor } from "../_components/ad-domain-editor";
import { STANDALONE } from "@/lib/profiles/ad-domain";
import { SetupStageChips } from "../_components/setup-stage-chips";
import { RunbookView, type RunbookItemVM } from "../_components/runbook-view";
import { RunbookEditor } from "../_components/runbook-editor";
import { GenerateRunbookButton } from "../_components/generate-runbook-button";
import { M365LicenseEditor } from "../_components/m365-license-editor";
import { M365LicenseRulesEditor } from "../_components/m365-license-rules-editor";
import { normalizeLicenseRules } from "@/lib/m365/license-rules";
import { inheritedLicenseRules, inheritsParentModeling, licenseRulesOf } from "@/lib/cases/parent-inheritance";
import { parseLicenseEntries } from "@/lib/m365/license-config";
import { M365GroupsEditor } from "../_components/m365-groups-editor";
import { MailboxAccessEditor } from "../_components/mailbox-access-editor";
import { M365PasswordEditor } from "../_components/m365-password-editor";
import { RolesRulesView } from "../_components/roles-rules-view";
import { EditRulesButton } from "../_components/edit-rules-button";
import { IntakeRulesEditor } from "../_components/intake-rules-editor";
import { SecretsPanel } from "../_components/secrets-panel";
import { ConnectionTestPanel } from "../_components/connection-test-panel";
import { ClientNotifyOverride } from "../_components/client-notify-override";
import { parseClientOverride } from "@/lib/notifications/types";
import { deriveSecretRows } from "@/lib/secrets/wiring";
import { delineaConfigured, delineaConfigFromEnv } from "@/lib/secrets/delinea";
import { delineaWriteSummary } from "@/lib/secrets/delinea-templates";

export const dynamic = "force-dynamic";

// Tab title = the client's name, so open client tabs are tellable apart.
export async function generateMetadata({ params }: { params: { slug: string } }) {
  const c = await db.client.findUnique({ where: { slug: params.slug }, select: { id: true, name: true } });
  // Don't leak an out-of-scope client's name in the tab title (the page itself 404s).
  if (c && !scopeAllows(await currentClientScope(db), c.id)) return { title: "Client" };
  return { title: c?.name ?? params.slug };
}

// Hover help for the systems table — explains the columns + flags that aren't self-evident.
const HELP = {
  module:
    "The shared Coretelligent.* PowerShell module that runs this system. Rows under one module are different lanes of the SAME module — e.g. Entra, Exchange and M365 all run on Coretelligent.M365.",
  mode: "How the step runs — api: automated via the module · browser: Playwright automation · manual: a human checklist item.",
  onboard: "When this system runs on onboarding — always · on_request (only when the intake asks) · never (not part of onboarding).",
  offboard: "When this system runs on offboarding — always · on_request · never.",
  flags: "approval = destructive step, gated server-side until approved. evidence = snapshot the before-state and attach it to the case before any destructive change.",
  secrets: "Delinea secret references the runner brokers at run time — names only, never values.",
  approval: "Destructive step — gated server-side; it won't run until an operator approves it.",
  evidence:
    "Captures the before-state (group memberships, license/app assignments) and attaches it to the case BEFORE anything is removed — for audit and restore. Mainly used on offboarding.",
};
const laneHelp = (l: string) =>
  l === "always" ? "Runs every time for this action" : l === "on_request" ? "Runs only when the intake form requests it" : l === "by_persona" ? "Runs only when the matched persona's bundle lists this system (Roles & rules)" : "Not part of this action";

type SysRow = {
  id: string; systemKey: string; mode: string; onboardWhen: string; offboardWhen: string;
  requiresApproval: boolean; captureEvidence: boolean; secretNames: string[];
  system: { name: string; buildTier: number; moduleName: string | null };
};

// Group systems by the module that runs them so module-mates read together; modules with a
// real name first (by build tier), standalone (no-module) systems last; within a group by key.
function groupByModule(systems: SysRow[]) {
  const groups = new Map<string, SysRow[]>();
  for (const s of systems) {
    const k = s.system.moduleName ?? "";
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k)!.push(s);
  }
  return [...groups.entries()]
    .map(([k, sys]) => ({ module: k || null, systems: [...sys].sort((a, b) => a.systemKey.localeCompare(b.systemKey)), tier: Math.min(...sys.map((x) => x.system.buildTier)) }))
    .sort((a, b) => (!!a.module !== !!b.module ? (a.module ? -1 : 1) : a.tier !== b.tier ? a.tier - b.tier : (a.module ?? "").localeCompare(b.module ?? "")));
}

export default async function ClientDetailPage({ params }: { params: { slug: string } }) {
  // scope-gated: an out-of-scope (e.g. restricted) client reads as not-found here.
  const scope = await currentClientScope(db);
  const client = await makeClientRepository(db).getClientBySlug(params.slug, scope);
  if (!client) {
    // Slug miss: if the segment is a CORE id whose client lives under a name slug (e.g. /clients/core1955
    // → /clients/yuma), redirect to the canonical URL. Scope-gate on the resolved id first so an
    // out-of-scope client can't be reached (or probed for existence) via its coreid alias.
    const alias = await findClientByCoreIdSlug(db, params.slug);
    if (alias && scopeAllows(scope, alias.id)) redirect(`/clients/${alias.canonicalSlug}`);
    notFound();
  }
  const canRestrict = await currentIsSuperAdmin(); // only super admins see/flip the restricted control
  // Does this client have its own (client-network) agent? Drives the "run cloud on own agent" hint.
  const hasClientAgent = (await db.agent.count({ where: { clientId: client.id, scope: "client_network", enabled: true, deletedAt: null } })) > 0;
  // SN account hierarchy: the parent, for the inheritance control + the "inherits the parent's
  // runbook" banner. One query serves both (the banner needs the system count, the control needs
  // to know whether there's anything to copy).
  const parent = client.parentId
    ? await db.client.findUnique({
        where: { id: client.parentId },
        select: { slug: true, name: true, _count: { select: { systems: true } } },
      })
    : null;

  // v2.1 resolution rules (personas/globals/locations) — the conditional group/OU/attribute logic.
  const v21 = await db.client.findUnique({ where: { id: client.id }, select: { personas: true, globals: true, locations: true, adObjects: true, cloudGroups: true, cloudMailboxes: true } });
  const notify = await db.client.findUnique({ where: { id: client.id }, select: { notifyOverride: true } });
  const notifyOverride = parseClientOverride(notify?.notifyOverride);

  // Every-user M365/Entra groups from the globals rules (the always-add string entries) — these are
  // applied to the m365 job at plan time IN ADDITION to the m365 system's own onboarding groups, so
  // the groups editor can show they also apply (and not look like a missing duplicate).
  const everyUserM365Groups = (() => {
    const g = (v21?.globals ?? {}) as Record<string, { groups?: unknown }>;
    const names = new Set<string>();
    for (const key of ["entra", "m365"]) {
      const groups = g[key]?.groups;
      if (Array.isArray(groups)) for (const x of groups) if (typeof x === "string" && x.trim()) names.add(x.trim());
    }
    return [...names];
  })();
  // Known groups to offer as autocomplete (with a type when known) when editing onboarding groups:
  // cloud-discovered Entra groups (DL/Security/365), AD-discovered groups, and the every-user ones.
  const adGroupNames = Array.isArray((v21?.adObjects as { groups?: unknown } | null)?.groups)
    ? ((v21!.adObjects as { groups: unknown[] }).groups.filter((x): x is string => typeof x === "string"))
    : [];
  const cloudGroups = ((v21?.cloudGroups as { groups?: unknown; discoveredAt?: string } | null) ?? {});
  const cloudGroupList = Array.isArray(cloudGroups.groups)
    ? (cloudGroups.groups as unknown[]).filter((g): g is { name: string; type?: string } => !!g && typeof g === "object" && typeof (g as { name?: unknown }).name === "string")
    : [];
  // One typed list, cloud first (cloud carries real DL/Security/365 types; AD/every-user are untyped).
  const knownGroups: { name: string; type?: string }[] = [
    ...cloudGroupList.map((g) => ({ name: g.name, type: g.type })),
    ...adGroupNames.map((name) => ({ name })),
    ...everyUserM365Groups.map((name) => ({ name })),
  ];
  const cloudGroupsMeta = { count: cloudGroupList.length, discoveredAt: typeof cloudGroups.discoveredAt === "string" ? cloudGroups.discoveredAt : null };

  // Discovered shared mailboxes (FR #15) — backs the default shared-mailbox picker, same discovery run.
  const cloudMailboxes = ((v21?.cloudMailboxes as { mailboxes?: unknown; discoveredAt?: string } | null) ?? {});
  const cloudMailboxList = Array.isArray(cloudMailboxes.mailboxes)
    ? (cloudMailboxes.mailboxes as unknown[]).filter((m): m is { address: string; displayName?: string } => !!m && typeof m === "object" && typeof (m as { address?: unknown }).address === "string")
    : [];
  const cloudMailboxesMeta = { count: cloudMailboxList.length, discoveredAt: typeof cloudMailboxes.discoveredAt === "string" ? cloudMailboxes.discoveredAt : null };

  // Sectioned group options for the per-location groups picker (365 by type, then AD, then any
  // configured every-user groups not already listed). Empty sections render nothing in the picker.
  const groupSections = [
    { label: "365 Distribution", options: cloudGroupList.filter((g) => g.type === "dl").map((g) => g.name) },
    { label: "365 Security", options: cloudGroupList.filter((g) => g.type === "security").map((g) => g.name) },
    { label: "365 Groups", options: cloudGroupList.filter((g) => g.type === "m365").map((g) => g.name) },
    { label: "AD", options: adGroupNames },
  ];
  const everyUserExtra = everyUserM365Groups.filter((n) => !groupSections.some((s) => s.options.includes(n)));
  if (everyUserExtra.length) groupSections.push({ label: "Configured (every user)", options: everyUserExtra });
  // Flat set of discovered names for the display split of un-migrated locations (groups vs printers).
  const discoveredGroupNames = [...new Set(knownGroups.map((g) => g.name))];

  // Persona/location names + discovered AD folders — feed the "Change / move user" dialog (mover
  // persona/location pickers + ad-hoc OU move picker). Same v21 blocks RolesRulesView already reads.
  const personaNames = Object.keys((v21?.personas as Record<string, unknown> | null) ?? {});
  const locationNames = Object.keys((v21?.locations as Record<string, unknown> | null) ?? {});
  const adOus = Array.isArray((v21?.adObjects as { ous?: unknown } | null)?.ous)
    ? ((v21!.adObjects as { ous: unknown[] }).ous.filter((x): x is string => typeof x === "string"))
    : [];

  // FR #83/#107: the AD domain an ad-standalone client's on-prem namespace uses when it differs
  // from its mail domain — lives inside identity.adDomain (see lib/profiles/ad-domain.ts).
  const clientIdentity = (client.identity ?? {}) as { adDomain?: unknown };
  const adDomain = typeof clientIdentity.adDomain === "string" ? clientIdentity.adDomain : "";

  // Account hierarchy: a child with no systems of its own plans with its PARENT's runbook (see
  // clientForPlanning). Surface that here so an "empty" child isn't mistaken for unmodeled — but
  // ONLY while the link is intact: a child that broke it plans from its own systems, so claiming
  // the parent's runbook covers it would be a lie (its cases would plan zero jobs).
  const parentInfo = client.systems.length === 0 && client.inheritParentSystems ? parent : null;

  // RunbookSection rows only ever exist for onboard/offboard (change has no runbook — it uses a
  // separate planner); narrow here so downstream onboard/offboard-keyed lookups stay typed.
  const runbookAll = await db.runbookSection.findMany({
    where: { clientId: client.id },
    orderBy: [{ action: "asc" }, { seq: "asc" }],
  });
  const runbook = runbookAll.filter(
    (r): r is typeof r & { action: "onboard" | "offboard" } => r.action !== "change"
  );

  // Secret wiring: every secretName the systems reference + the saved Delinea references (with id).
  const wiring = await makeClientRepository(db).secretsWiring(params.slug);
  const secretRows = wiring ? deriveSecretRows(wiring.systems, wiring.secrets) : [];
  // Run-readiness, computed from wired secrets + latest connection tests.
  const readiness = await makeClientRepository(db).clientReadiness(params.slug);

  // index systems for dependency badges + per-system config (code preview)
  const sysByKey = new Map(client.systems.map((s) => [s.systemKey, s]));
  // A child with its own m365 system that hasn't set license rules plans with its parent's (see
  // applyParentInheritance), while it follows the parent's rules — show them rather than "none", and
  // offer to go back to them once the child has its own.
  const parentLicenseRules = parent && sysByKey.has("m365") && inheritsParentModeling(client)
    ? inheritedLicenseRules({}, await db.clientSystem.findMany({ where: { clientId: client.parentId!, systemKey: "m365" }, select: { systemKey: true, config: true } }))
    : null;
  const ownLicenseRulesSet = licenseRulesOf(sysByKey.get("m365")) !== undefined;
  const keysInAction: Record<"onboard" | "offboard", Set<string>> = { onboard: new Set(), offboard: new Set() };
  for (const r of runbook) if (r.systemKey) keysInAction[r.action].add(r.systemKey);

  // Systems that RUN in a lane but have no section in the KB doc — a client whose runbook came from a
  // script or the systems editor (not an article) would otherwise show a runbook that silently omits
  // steps a real case executes. Collected per lane, appended below, and flagged `unlisted` in the view.
  // They also join keysInAction FIRST so the "after: …" dependency badges resolve against them.
  const laneOf = (s: (typeof client.systems)[number], action: "onboard" | "offboard") =>
    action === "onboard" ? s.onboardWhen : s.offboardWhen;
  const unlisted: Record<"onboard" | "offboard", typeof client.systems> = { onboard: [], offboard: [] };
  for (const action of ["onboard", "offboard"] as const) {
    for (const s of client.systems) {
      if (laneOf(s, action) === "never" || keysInAction[action].has(s.systemKey)) continue;
      unlisted[action].push(s);
      keysInAction[action].add(s.systemKey);
    }
  }
  const whenLabel = (lane: string) => (lane === "on_request" ? "on request" : lane === "by_persona" ? "by persona" : null);

  const items: RunbookItemVM[] = runbook.map((r) => {
    const sys = r.systemKey ? sysByKey.get(r.systemKey) : undefined;
    const cfg = (sys?.config ?? null) as { onboard?: unknown; offboard?: unknown; dependsOn?: Record<string, string[]> } | null;
    // lane-specific deps win over the system-level list (mirrors orchestrator.depsOf), filtered
    // to systems actually present in this action's runbook.
    const laneDeps = cfg?.dependsOn?.[r.action];
    const after = sys ? (laneDeps ?? sys.dependsOn ?? []).filter((d) => keysInAction[r.action].has(d)) : [];
    const laneConfig = cfg?.[r.action] ?? null;
    const code = r.status === "automated" && r.systemKey
      ? automationPreview(r.systemKey, r.action, laneConfig, client.identity, client.primaryDomain)
      : null;
    return {
      id: `${r.action}-${r.seq}`,
      action: r.action,
      seq: r.seq,
      status: r.status,
      systemKey: r.systemKey,
      title: r.title,
      guess: r.guess,
      steps: r.steps,
      after,
      kbHref: kbUrl(r.kbArticle),
      kbNum: r.kbArticle,
      code,
      artifacts: asArtifacts(r.artifacts),
    };
  });

  const maxSeq: Record<"onboard" | "offboard", number> = { onboard: 0, offboard: 0 };
  for (const r of runbook) maxSeq[r.action] = Math.max(maxSeq[r.action], r.seq + 1);
  for (const action of ["onboard", "offboard"] as const) {
    unlisted[action].forEach((s, i) => {
      const cfg = (s.config ?? null) as { onboard?: unknown; offboard?: unknown; dependsOn?: Record<string, string[]> } | null;
      const laneDeps = cfg?.dependsOn?.[action];
      const laneConfig = cfg?.[action] ?? null;
      const automated = s.mode === "api";
      items.push({
        id: `${action}-sys-${s.systemKey}`,
        action,
        seq: maxSeq[action] + i,
        status: automated ? "automated" : "manual",
        systemKey: s.systemKey,
        title: MODULES.find((m) => m.key === s.systemKey)?.name ?? s.systemKey,
        guess: null,
        steps: [],
        after: (laneDeps ?? s.dependsOn ?? []).filter((d) => keysInAction[action].has(d)),
        kbHref: null,
        kbNum: null,
        code: automated ? automationPreview(s.systemKey, action, laneConfig, client.identity, client.primaryDomain) : null,
        artifacts: [],
        unlisted: true,
        when: whenLabel(laneOf(s, action)),
      });
    });
  }

  const onboardKb = items.find((i) => i.action === "onboard" && i.kbHref)?.kbHref ?? null;
  const offboardKb = items.find((i) => i.action === "offboard" && i.kbHref)?.kbHref ?? null;

  return (
    <main>
      <p className="note">
        <Link href="/clients">← Clients</Link>
      </p>
      <div className="row-between">
        <div>
          <h1>{client.name}</h1>
          <p className="note">
            {client.primaryDomain || "no domain"} ·{" "}
            {client.backbone ? `backbone: ${client.backbone}` : "not modeled"} ·{" "}
            {client.status}
          </p>
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          {canRestrict && <RestrictedToggle slug={client.slug} name={client.name} restricted={client.restricted} />}
          <EngineOptOutToggle slug={client.slug} name={client.name} on={client.engineOptOut} />
          {parent && (
            <ParentInheritanceControl
              slug={client.slug}
              parentName={parent.name}
              inherit={client.inheritParentSystems}
              ownSystemCount={client.systems.length}
              parentSystemCount={parent._count.systems}
            />
          )}
          {parent && (
            <ParentModelingToggle slug={client.slug} parentName={parent.name} on={client.inheritParentModeling} />
          )}
          <OwnAgentToggle slug={client.slug} on={client.runCloudOnOwnAgent} hasAgent={hasClientAgent} />
          <NoRunnerToggle slug={client.slug} on={client.noRunner} />
          <ClientActionsMenu
            slug={client.slug}
            personas={personaNames}
            locations={locationNames}
            knownGroups={cloudGroupList}
            ous={adOus}
            systemKeys={client.systems.map((s) => s.systemKey)}
            guidedSetupHref={readiness && readiness.tier !== "no_systems" ? `/clients/${client.slug}/setup` : null}
          />
        </div>
      </div>

      <table>
        <tbody>
          <Field label="CORE id" value={client.coreId} />
          <Field label="Region" value={client.region} />
          <Field label="Timezone" value={client.timezone} />
          <Field label="Support status" value={client.supportStatus} />
          <Field label="Co-managed IT" value={client.coManaged ? "yes" : "no"} />
          <Field
            label="Onboarding / offboarding rating"
            value={`${client.onboardingRating ?? "—"} / ${client.offboardingRating ?? "—"}`}
          />
          <Field
            label="Last synced"
            value={client.snLastSyncedAt ? new Date(client.snLastSyncedAt).toLocaleString() : null}
          />
        </tbody>
      </table>

      {/* Multi-domain clients: which email domains cases may onboard under (default = curated
          emailDomain). Pullable from the M365 tenant; the case page offers these before running. */}
      <EmailDomainsEditor slug={client.slug} domains={client.domains ?? []} defaultDomain={client.emailDomain ?? client.primaryDomain ?? null} />
      {/* Standalone clients ONLY. Rendered everywhere, this invited an operator on an ad-synced
          client to set a value the runtime correctly ignores — while still stamping the
          usernamePattern edited-field marker, which freezes that client's WHOLE identity blob
          (usernamePatterns, password, directorySync) against future profile reseeds. The label
          said "standalone only"; a label is advice, not a guard. */}
      {STANDALONE.has(String(client.backbone ?? "")) && (
        <AdDomainEditor slug={client.slug} initial={adDomain} />
      )}

      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <h2 style={{ marginRight: "auto" }}>Systems</h2>
        <SyncSystemsButton slug={client.slug} />
      </div>
      {sysByKey.has("active-directory") && (sysByKey.has("m365") || sysByKey.has("entra") || sysByKey.has("exchange")) && !sysByKey.has("directory-sync") && (
        <AddDirectorySyncButton slug={client.slug} hasExchange={sysByKey.has("exchange")} backbone={client.backbone} />
      )}
      {sysByKey.has("m365") && (
        <M365LicenseEditor
          slug={client.slug}
          current={(() => {
            const cfg = (sysByKey.get("m365")?.config ?? {}) as { onboard?: { licenses?: unknown; defaultLicenses?: unknown } };
            const lic = cfg.onboard?.licenses ?? cfg.onboard?.defaultLicenses ?? [];
            if (!Array.isArray(lic)) return [];
            // Preserve group-based entries; older { name, skuId } objects collapse to their name (direct).
            const parsed = parseLicenseEntries(lic);
            if (parsed.ok) return parsed.licenses;
            return lic.map((l) => (typeof l === "string" ? l : String((l as { name?: unknown })?.name ?? ""))).filter(Boolean);
          })()}
          groupOptions={[
            ...cloudGroupList.map((g) => ({ name: g.name, source: "entra" as const })),
            ...adGroupNames.map((name) => ({ name, source: "ad" as const })),
          ]}
          hasAdSystem={sysByKey.has("active-directory")}
        />
      )}
      {sysByKey.has("m365") && (
        <M365LicenseRulesEditor
          slug={client.slug}
          inherited={parentLicenseRules && !ownLicenseRulesSet ? { parentName: parent!.name, parentSlug: parent!.slug, rules: normalizeLicenseRules(parentLicenseRules) } : null}
          canInherit={parentLicenseRules && ownLicenseRulesSet ? parent!.name : null}
          current={(() => {
            const cfg = (sysByKey.get("m365")?.config ?? {}) as { onboard?: { licenseRules?: unknown } };
            return normalizeLicenseRules(cfg.onboard?.licenseRules);
          })()}
        />
      )}
      {sysByKey.has("m365") && (
        <M365GroupsEditor
          slug={client.slug}
          current={(() => {
            const cfg = (sysByKey.get("m365")?.config ?? {}) as { onboard?: { groups?: unknown; defaultGroups?: unknown } };
            const gs = cfg.onboard?.groups ?? cfg.onboard?.defaultGroups ?? [];
            return Array.isArray(gs)
              ? gs.map((x) => (typeof x === "string" ? { name: x } : { name: String((x as { name?: unknown })?.name ?? ""), type: (x as { type?: string })?.type })).filter((x) => x.name)
              : [];
          })()}
          everyUserGroups={everyUserM365Groups}
          knownGroups={knownGroups}
          cloudGroupsMeta={cloudGroupsMeta}
        />
      )}
      {sysByKey.has("m365") && (
        <MailboxAccessEditor
          slug={client.slug}
          current={(() => {
            const cfg = (sysByKey.get("m365")?.config ?? {}) as { onboard?: { defaultSharedMailboxes?: unknown } };
            const ms = cfg.onboard?.defaultSharedMailboxes ?? [];
            return Array.isArray(ms)
              ? ms.map((x) => ({
                  address: String((x as { address?: unknown })?.address ?? ""),
                  displayName: typeof (x as { displayName?: unknown })?.displayName === "string" ? (x as { displayName: string }).displayName : undefined,
                  access: typeof (x as { access?: unknown })?.access === "string" ? (x as { access: string }).access : undefined,
                })).filter((x) => x.address)
              : [];
          })()}
          discovered={cloudMailboxList}
          discoveredMeta={cloudMailboxesMeta}
        />
      )}
      {sysByKey.has("m365") && (
        <M365PasswordEditor
          slug={client.slug}
          current={(() => {
            const ob = ((sysByKey.get("m365")?.config ?? {}) as { onboard?: { initialPassword?: unknown; initialPasswordSecret?: unknown } }).onboard ?? {};
            if (typeof ob.initialPasswordSecret === "string" && ob.initialPasswordSecret) {
              // Surface the wired Delinea id so opening the editor shows the secret number already set.
              const delineaId = secretRows.find((r) => r.name === ob.initialPasswordSecret)?.externalId ?? "";
              return { mode: "secret" as const, delineaId };
            }
            if (typeof ob.initialPassword === "string" && ob.initialPassword) return { mode: "fixed" as const };
            return { mode: "generate" as const };
          })()}
        />
      )}
      {(onboardKb || offboardKb) && (
        <p className="note">
          Source KB:{" "}
          {onboardKb && <a href={onboardKb} target="_blank" rel="noreferrer">onboard →</a>}
          {onboardKb && offboardKb && " · "}
          {offboardKb && <a href={offboardKb} target="_blank" rel="noreferrer">offboard →</a>}
        </p>
      )}
      {client.systems.length === 0 ? (
        parentInfo && parentInfo._count.systems > 0 ? (
          <div style={{ border: "1px solid #bfdbfe", background: "#eff6ff", borderRadius: 6, padding: "0.7rem 0.9rem" }}>
            <b>Inherits the parent&rsquo;s runbook.</b>{" "}
            This client has no modeled systems of its own, so cases plan with the parent account&rsquo;s systems:{" "}
            <Link href={`/clients/${parentInfo.slug}`}>{parentInfo.name}</Link> ({parentInfo._count.systems} systems).
            {" "}Credentials still resolve on <i>this</i> client — wire its secrets (or override per case).
            {" "}Add systems here to diverge from the parent.
          </div>
        ) : (
          <p className="note">No profile applied yet — this client is roster-only.</p>
        )
      ) : (
        <>
        <p className="note" style={{ marginTop: 0 }}>
          Grouped by the module that runs each system — rows under one module (e.g. Entra / Exchange / M365) are different lanes of the same module. Hover a column or flag for what it means.
        </p>
        <table>
          <thead>
            <tr>
              <th className="help" title={HELP.module}>Module</th>
              <th>System</th>
              <th className="help" title={HELP.mode}>Mode</th>
              <th className="help" title={HELP.onboard}>Onboard</th>
              <th className="help" title={HELP.offboard}>Offboard</th>
              <th className="help" title={HELP.flags}>Flags</th>
              <th className="help" title={HELP.secrets}>Secrets</th>
            </tr>
          </thead>
          <tbody>
            {groupByModule(client.systems).map((g) =>
              g.systems.map((s, i) => (
                <tr key={s.id}>
                  {i === 0 && (
                    <td rowSpan={g.systems.length} className="module-cell" title={g.module ? `${g.systems.length} lane${g.systems.length > 1 ? "s" : ""} on ${g.module}` : "Standalone — no shared Coretelligent.* module"}>
                      {g.module ? g.module.replace(/^Coretelligent\./, "") : <span className="muted">—</span>}
                    </td>
                  )}
                  <td>
                    {s.system.name}
                    <span className="note"> ({s.systemKey})</span>
                  </td>
                  <td>
                    <span className="badge" title={`${s.mode} mode`}>{s.mode}</span>
                  </td>
                  <td className="muted help" title={laneHelp(s.onboardWhen)}>{s.onboardWhen.replace("_", " ")}</td>
                  <td className="muted help" title={laneHelp(s.offboardWhen)}>{s.offboardWhen.replace("_", " ")}</td>
                  <td className="muted">
                    {!s.requiresApproval && !s.captureEvidence && "—"}
                    {s.requiresApproval && <span className="badge help" title={HELP.approval}>approval</span>}
                    {s.captureEvidence && <span className="badge help" title={HELP.evidence} style={{ marginLeft: s.requiresApproval ? 4 : 0 }}>evidence</span>}
                  </td>
                  <td className="muted">{s.secretNames.join(", ") || "—"}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
        </>
      )}

      <div className="row-between" style={{ marginTop: "1.5rem" }} id="rules">
        <h2 style={{ margin: 0 }}>Roles &amp; rules</h2>
        <EditRulesButton slug={client.slug} />
      </div>
      <RolesRulesView
        personas={v21?.personas as never}
        globals={v21?.globals as never}
        locations={v21?.locations as never}
        slug={client.slug}
        groupSections={groupSections}
        discoveredNames={discoveredGroupNames}
      />

      <IntakeRulesEditor slug={client.slug} systemKeys={client.systems.map((s) => s.systemKey)} />

      {readiness && readiness.tier !== "no_systems" && (
        <>
          <h2 style={{ marginTop: "1.5rem" }}>Readiness</h2>
          {(() => {
            const c = readiness.tier === "ready" ? { fg: "#2e7d32", bg: "#eaf5ec", mark: "✓" }
              : readiness.tier === "partial" ? { fg: "#8a6d00", bg: "#fbf4e0", mark: "◑" }
              : { fg: "#b3261e", bg: "#fdeceb", mark: "✗" };
            return (
              <p style={{ marginTop: "-0.25rem" }}>
                <span className="badge" style={{ color: c.fg, background: c.bg, borderColor: "transparent", fontSize: 13, padding: "2px 8px" }}>
                  {c.mark} {readiness.label}
                </span>{" "}
                <span className="note">{readiness.summary}</span>
              </p>
            );
          })()}
          <table>
            <thead><tr><th style={{ width: 180 }}>System</th><th>Credentials</th><th>Connection test</th><th>Setup</th></tr></thead>
            <tbody>
              {readiness.systems.map((s) => (
                <tr key={s.systemKey}>
                  <td>{s.systemKey}</td>
                  <td>{s.notNeeded
                    ? <span className="muted">not needed</span>
                    : s.wired
                    ? <span style={{ color: "#2e7d32" }}>✓ wired</span>
                    : <span style={{ color: "#b3261e" }}>✗ missing: {s.missingSecrets.join(", ")}</span>}</td>
                  <td>{s.test === "ok"
                    ? <span style={{ color: "#2e7d32" }}>✓ passed</span>
                    : s.test === "fail" ? <span style={{ color: "#b3261e" }}>✗ failed</span>
                    : s.test === "not_needed" ? <span className="muted" title="Manual step — no credential to test">— not needed</span>
                    : <span className="muted">— untested</span>}</td>
                  <td><SetupStageChips slug={client.slug} systemKey={s.systemKey} vector={s.setup} attested={s.setup.rights === "attested"} /></td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="note">Computed from wired Delinea references + the latest connection-test results below. Run <b>Test</b> on the secrets to fill in the connection column. Setup chips: ✓* = attested manually, ? = not yet verifiable (older runner or no probe), — = manual step.</p>
        </>
      )}

      <div className="row-between" style={{ marginTop: "1.5rem", alignItems: "baseline" }}>
        <h2 style={{ margin: 0 }}>Secret wiring (Delinea)</h2>
        {secretRows.length > 0 && <Link href={`/clients/${client.slug}/setup`} className="note">Guided setup →</Link>}
      </div>
      <SecretsPanel
        slug={client.slug}
        initialRows={secretRows}
        delineaConfigured={delineaConfigured(delineaConfigFromEnv())}
        write={delineaWriteSummary({ slug: client.slug, clientFolderId: client.delineaFolderId, secretNames: secretRows.map((r) => r.name) })}
      />

      <h2 style={{ marginTop: "1.5rem" }}>Connection tests</h2>
      <ConnectionTestPanel slug={client.slug} systemNames={Object.fromEntries(client.systems.map((s) => [s.systemKey, s.system.name]))} />

      <h2 style={{ marginTop: "1.5rem" }}>Notifications</h2>
      <ClientNotifyOverride slug={client.slug} initial={notifyOverride} />

      <div className="row-between" style={{ marginTop: "1.5rem", alignItems: "baseline" }}>
        <h2 style={{ margin: 0 }}>Runbook — everything to do</h2>
        <GenerateRunbookButton slug={client.slug} />
      </div>
      <p className="note">
        From the ServiceNow KB, or <b>built from the modeled systems</b> (⚙ for internal/KB-less clients like
        Coretelligent). ✅ automated steps run via a module; ✋ human-interaction steps (manual, or not yet modeled)
        need a person. Expand to see the steps.
      </p>
      {items.length === 0 ? (
        <p className="note">No runbook yet. Click <b>⚙ Build from systems</b> to generate it from what&rsquo;s modeled on Edit systems, or paste/type a runbook below (parsed into steps; known systems are auto-wired).</p>
      ) : (
        <RunbookView items={items} slug={client.slug} />
      )}
      <RunbookEditor
        slug={client.slug}
        current={{
          onboard: runbook.filter((r) => r.action === "onboard").map((r) => ({ seq: r.seq, systemKey: r.systemKey, title: r.title, status: r.status, steps: r.steps })),
          offboard: runbook.filter((r) => r.action === "offboard").map((r) => ({ seq: r.seq, systemKey: r.systemKey, title: r.title, status: r.status, steps: r.steps })),
        }}
        kbArticles={Object.values(
          runbook.reduce<Record<string, { number: string; action: "onboard" | "offboard" }>>((acc, r) => {
            if (r.kbArticle && !acc[r.kbArticle]) acc[r.kbArticle] = { number: r.kbArticle, action: r.action };
            return acc;
          }, {})
        )}
      />
    </main>
  );
}

function Field({ label, value }: { label: string; value: string | null }) {
  return (
    <tr>
      <th style={{ width: "240px" }}>{label}</th>
      <td>{value ?? <span className="muted">—</span>}</td>
    </tr>
  );
}
