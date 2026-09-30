// Plan-time resolution: for a v2.1 client (has personas/globals), flatten each job's config by
// merging globals + selected persona + the system's own lane config through the resolver. v2.0
// clients (no personas/globals) pass through unchanged. Onboard resolves the ONBOARD fragments
// (add groups / place OU / set attrs); offboard resolves the OFFBOARD fragments with offboard
// semantics (remove groups / move OU / set attrs).
import { buildPlanContext } from "./context";
import { resolveSystemConfig } from "./resolve";
import { evaluateLicenseRules } from "../m365/license-rules";
import { hideFromGalOptedOut, adLaneHidesViaAttribute, readHideFromGal } from "./hide-from-gal";
import type { PlannedJob } from "../orchestrator";

type PlanClient = {
  backbone?: string | null;
  personas?: unknown; globals?: unknown; globalsOffboard?: unknown; locations?: unknown;
  // Discovered group catalogs (see prisma schema): adObjects = { groups: string[] } from the DC,
  // cloudGroups = { groups: [{ name, type }] } from Entra/Graph. Used to route location groups.
  adObjects?: unknown; cloudGroups?: unknown;
};

// A location group is inherently multi-lane, but a group discovery proves is CLOUD-ONLY — present in
// the tenant's discovered Entra groups and absent from the DC's discovered AD groups — must never be
// pushed to the AD lane: AD can't find it and the runner warns "group not found in AD". Returns the
// lower-cased names of such groups. Only classifies with positive evidence — if either catalog is
// missing the set is empty and the legacy union (fan out to every directory lane) is preserved.
function cloudOnlyGroupNames(client: PlanClient): ReadonlySet<string> {
  const cg = (client.cloudGroups as { groups?: unknown } | null)?.groups;
  if (!Array.isArray(cg)) return new Set();
  const adRaw = (client.adObjects as { groups?: unknown } | null)?.groups;
  const adSet = new Set(
    (Array.isArray(adRaw) ? adRaw : [])
      .map((g) => (typeof g === "string" ? g.trim().toLowerCase() : ""))
      .filter(Boolean),
  );
  const out = new Set<string>();
  for (const g of cg) {
    const name = typeof g === "string"
      ? g
      : (g && typeof g === "object" && typeof (g as { name?: unknown }).name === "string" ? (g as { name: string }).name : "");
    const k = name.trim().toLowerCase();
    if (k && !adSet.has(k)) out.add(k);
  }
  return out;
}

// System keys the selected persona pulls in — feeds planCase's by_persona lane gate. Onboard: the
// persona's `systems` keys. Offboard: the UNION of `systems` + `offboardSystems`, so whatever a
// persona granted at onboard gets cleaned up even without an explicit offboard fragment. Selection
// goes through buildPlanContext, the same path as config resolution (and the persona-override hook),
// so inclusion and config can never disagree about which persona applies.
export function personaSystemKeys(client: PlanClient, payload: Record<string, unknown>, action: string): ReadonlySet<string> {
  const personas = (client.personas ?? null) as Record<string, unknown> | null;
  if (!personas) return new Set();
  const { persona } = buildPlanContext(payload, { personas: personas as never, locations: client.locations as never });
  if (!persona) return new Set();
  const def = persona.def as { systems?: Record<string, unknown>; offboardSystems?: Record<string, unknown> };
  const keys = Object.keys(def.systems ?? {});
  if (action === "offboard") keys.push(...Object.keys(def.offboardSystems ?? {}));
  return new Set(keys);
}

// Directory systems whose groups can be mirrored from a reference user (the runner resolves the
// reference user's live memberOf at execution time and unions it in). AD/entra mirror on-prem +
// synced groups; m365 mirrors the reference user's CLOUD-only Entra groups (cloud licensing groups,
// distribution/M365 groups) that AD sync never covers.
const DIRECTORY_SYSTEMS = new Set(["active-directory", "entra", "m365", "exchange"]);

// OFFBOARD resolution: resolve globalsOffboard + persona.offboardSystems and map the onboard-shaped
// keys to offboard semantics on the job config (groups -> removeGroups, ou -> moveToOu, attributes ->
// offboardAttributes). Additive — onboard config keys the runner already honors are untouched.
function resolveOffboardConfigs(client: PlanClient, payload: Record<string, unknown>, planned: PlannedJob[]): PlannedJob[] {
  const globalsOff = (client.globalsOffboard ?? null) as Record<string, Record<string, unknown>> | null;
  const personas = (client.personas ?? null) as Record<string, unknown> | null;
  const resolved = (() => {
    if (!globalsOff && !personas) return planned;
    const { context, persona } = buildPlanContext(payload, { personas: personas as never, locations: client.locations as never });
    const personaOff = (persona?.def as { offboardSystems?: Record<string, unknown> } | undefined)?.offboardSystems ?? null;
    return planned.map((j) => {
      const gOff = globalsOff?.[j.systemKey] ?? null;
      const pOff = (personaOff?.[j.systemKey] as Record<string, unknown> | undefined) ?? null;
      if (!gOff && !pOff) return j;
      const off = resolveSystemConfig(j.systemKey, { globals: gOff as never, persona: pOff as never, own: null }, context);
      const cfg: Record<string, unknown> = { ...((j.config as Record<string, unknown> | null) ?? {}) };
      if (Array.isArray(off.groups) && off.groups.length) cfg.removeGroups = off.groups;
      if (typeof off.ou === "string" && off.ou) cfg.moveToOu = off.ou;
      if (off.attributes && typeof off.attributes === "object" && Object.keys(off.attributes as object).length) cfg.offboardAttributes = off.attributes;
      return { ...j, config: cfg };
    });
  })();

  // Case-requested delegate (FR #7 + FR #8): the intake captures WHO should get access to the
  // leaver's mailbox (payload.provideMailboxAccessTo, a display name from "Enable delegate") but
  // nothing ever consumed it — only the profile-static manager delegate ran. Hand it to the
  // exchange step (Full Access, name resolved at run time) and to the m365/entra step (OneDrive
  // access — the same person the ticket named; opt out per client with
  // oneDriveDelegateAccess: false on the m365 offboard config).
  //
  // FR #0000084 widened this from ONE person to several. The intake field is a ServiceNow reference
  // list, so it arrives either as a single name (one delegate, or an older stored payload) or as an
  // array — both are accepted here.
  //
  // WIRE SHAPE follows the COUNT, not the input type: one delegate travels as a plain string, exactly
  // as it did before, so a runner that has not yet picked up the widened module behaves identically on
  // the overwhelmingly common case. The array shape appears only when there really is more than one
  // name — the new behaviour engages only when the new feature is actually used.
  const delegates = (Array.isArray(payload.provideMailboxAccessTo)
    ? payload.provideMailboxAccessTo
    : [payload.provideMailboxAccessTo])
    .filter((d): d is string => typeof d === "string")
    .map((d) => d.trim())
    .filter(Boolean)
    // De-duplicate case-insensitively: a repeated name would be granted twice and logged twice, which
    // reads on the case as two different people getting access.
    .filter((d, i, all) => all.findIndex((o) => o.toLowerCase() === d.toLowerCase()) === i);
  const delegate: string | string[] | null = delegates.length === 0 ? null : delegates.length === 1 ? delegates[0] : delegates;
  const withDelegate = !delegate ? resolved : resolved.map((j) => {
    if (j.systemKey === "exchange") {
      return { ...j, config: { ...((j.config as Record<string, unknown> | null) ?? {}), grantFullAccessTo: delegate } };
    }
    if (j.systemKey === "m365" || j.systemKey === "entra") {
      const cfg = (j.config as Record<string, unknown> | null) ?? {};
      if (cfg.oneDriveDelegateAccess === false) return j;
      return { ...j, config: { ...cfg, oneDriveGrantAccessTo: delegate } };
    }
    return j;
  });

  // Delegate AutoMapping (FR #0000211): whether a delegate's Full Access also adds the leaver's mailbox
  // to their Outlook. The client's default already rides on the exchange job (config.offboard is
  // flattened onto it as delegateAutoMapping; unset = on). An operator's per-case choice
  // (payload.delegateAutoMapping, set from the case page) overrides it, for BOTH delegate grants.
  const autoMapOverride = typeof payload.delegateAutoMapping === "boolean" ? payload.delegateAutoMapping : null;
  const withAutoMap = autoMapOverride === null ? withDelegate : withDelegate.map((j) =>
    j.systemKey === "exchange"
      ? { ...j, config: { ...((j.config as Record<string, unknown> | null) ?? {}), delegateAutoMapping: autoMapOverride } }
      : j);

  // Case out-of-office (FR #0000047): the intake captures the leaver's auto-reply text
  // (u_out_of_office_message -> payload.oooMessage) and NOTHING read it — the mapper wrote the field
  // and there was no consumer anywhere in the codebase, so a requestor who filled it in got silence.
  //
  // The Exchange executor has always implemented the destination (config.autoReply.message ->
  // Set-MailboxAutoReplyConfiguration), so the whole gap was plan-time and no runner change is needed.
  //
  // Exchange ONLY: it is the sole lane that can set a mailbox auto-reply. The ticket's text overrides a
  // profile-configured default (same rule as FR #87 — what the ticket says beats the standing default),
  // and an absent/blank message leaves the profile's own autoReply exactly as it was.
  const ooo = typeof payload.oooMessage === "string" && payload.oooMessage.trim() ? payload.oooMessage.trim() : null;
  const withOoo = !ooo ? withAutoMap : withAutoMap.map((j) => {
    if (j.systemKey !== "exchange") return j;
    const cfg = (j.config as Record<string, unknown> | null) ?? {};
    return { ...j, config: { ...cfg, autoReply: { ...((cfg.autoReply as Record<string, unknown> | null) ?? {}), message: ooo } } };
  });

  // Case-requested mail forwarding (FR #0000097, and #0000099 filed as the same defect): the intake
  // captures both halves — u_mail_forwarded -> payload.mailForwarded and u_forward_email_to ->
  // payload.forwardEmailTo — and NOTHING read either. The Exchange executor has always implemented the
  // destination (config.forwarding.address -> Set-Mailbox -ForwardingSmtpAddress), so like FR #47 above
  // the entire gap was plan-time and no runner change is needed.
  //
  // MERGE rather than replace, for the same reason the OOO block merges: a profile that configured
  // keepCopy keeps it, and the ticket supplies only the address. There is no intake field for keepCopy,
  // so inventing a policy here would be guessing with the leaver's mail.
  const fwd = caseForwardingAddress(payload);
  const withForwarding = !fwd ? withOoo : withOoo.map((j) => {
    if (j.systemKey !== "exchange") return j; // the only lane that can set mailbox forwarding
    const cfg = (j.config as Record<string, unknown> | null) ?? {};
    return { ...j, config: { ...cfg, forwarding: { ...((cfg.forwarding as Record<string, unknown> | null) ?? {}), address: fwd } } };
  });

  // Spanning, destructive offboard (FR #0000095): unassign the licence rather than attempt an Archive
  // conversion. The runner has always supported both (config.removeLicense -> /users/unassign) and
  // nothing ever set the flag, so every client took the Archive path — which Kaseya's API cannot
  // perform from a Standard licence ("Standard licenses cannot be converted to archived licenses").
  // Measured before shipping: 37 of the 60 most recent Spanning offboards failed the swap and left a
  // billable seat for a human to finish by hand, and three of the four destructive clients are in
  // that list.
  //
  // Only for the DESTRUCTIVE classification. For everyone else the Archive conversion is the intent,
  // and quietly unassigning their seats could delete backups nobody agreed to lose — Kaseya warn that
  // deactivating a licence can do exactly that, which is why the runner refuses to auto-unassign on
  // the default path. The gate here is that a destructive step already forces operator approval AND an
  // evidence snapshot at plan time (orchestrator.ts), whatever the stored requiresApproval says.
  //
  // Explicit client config wins: a deliberately configured swapLicense or removeLicense is untouched.
  const withSpanningDrop = withForwarding.map((j) => {
    if (j.systemKey !== "spanning" || j.intent !== "destructive") return j;
    const cfg = (j.config as Record<string, unknown> | null) ?? {};
    if ("removeLicense" in cfg || "unassign" in cfg || "swapLicense" in cfg) return j;
    return { ...j, config: { ...cfg, removeLicense: true } };
  });

  // AD offboard group removal (FR #0000109). The AD module has always been able to do this —
  // removeAllGroups strips every membership, skipping Domain Users, the new primary group, and any
  // protected/privileged group (well-known admin names, an *Privileged* OU, or the client's own
  // protectedGroups list), recording each skip as a manual-removal item rather than tearing it down.
  // Nothing ever set the flag: of 44 live AD clients, 2 removed all groups, 0 had named-group rules,
  // and 42 removed NOTHING. So a leaver kept every group — file-share, application and group-based
  // licensing access — and the case reported green. Silence meant "keep everything", which is the
  // wrong default for an offboard.
  //
  // The evidence half is NOT optional and is why these two are set together. 16 of those 44 captured
  // no evidence on offboard, and stripping memberships nobody recorded is a one-way door: the
  // snapshot is the only thing that makes this reversible.
  //
  // Explicit config wins in both directions — removeAllGroups:false is a deliberate opt-out, and a
  // client with named removeGroups rules chose specific groups and does not get the blanket default.
  const withAdGroups = withSpanningDrop.map((j) => {
    if (j.systemKey !== "active-directory") return j;
    const cfg = (j.config as Record<string, unknown> | null) ?? {};
    if ("removeAllGroups" in cfg) return j;
    const named = cfg.removeGroups;
    if (Array.isArray(named) && named.length > 0) return j;
    return {
      ...j,
      captureEvidence: true,
      config: { ...cfg, removeAllGroups: true, removeAllGroupsBy: "engine-default" },
    };
  });

  return injectHideFromGal(withAdGroups, payload, client.backbone);
}

// FR #0000021: hide the leaver from the GAL by default on every offboard. Precedence:
// per-case skip (payload.skipGalHide) > per-client opt-out (hideFromGal:false on the lane) > default-on.
// Cloud GAL hide runs ONLY on the exchange lane — Graph can't set HiddenFromAddressListsEnabled, so
// m365/entra are never touched here. When the AD lane carries a concrete hide ATTRIBUTE, AD owns the
// hide (correct for directory-synced mailboxes) and exchange stands down to avoid the synced-object error.
// FR #0000036: on an ad_synced client EXO can't modify the directory-synced mailbox at all ("could not
// hide from GAL — the mailbox is directory-synced" WARN), so the planner injects the AD attribute shape
// the runner already honors — the hide happens on-prem and Entra Connect syncs it up. INSTEAD of the
// EXO hide, not in addition: adOwnsHide is computed on the post-injection list.
function injectHideFromGal(planned: PlannedJob[], payload: Record<string, unknown>, backbone?: string | null): PlannedJob[] {
  if (payload.skipGalHide === true) return planned;
  // First pass (ad_synced only): stamp the attribute shape on the AD job. An explicit client-configured
  // attribute wins (never overwrite it); an opt-out on EITHER the AD or the exchange lane suppresses the
  // injection (an exchange-lane opt-out must not be re-opted-in via AD); a bare `hideFromGal: true`
  // already on the AD config is upgraded to the concrete shape (the only shape the AD module acts on).
  const exchangeOptedOut = planned.some((j) => j.systemKey === "exchange" && hideFromGalOptedOut(j.config));
  const withAdHide = backbone !== "ad_synced" ? planned : planned.map((j) => {
    if (j.systemKey !== "active-directory") return j;
    const cfg = (j.config as Record<string, unknown> | null) ?? {};
    if (hideFromGalOptedOut(cfg) || exchangeOptedOut) return j;
    if (adLaneHidesViaAttribute(cfg)) return j;
    return { ...j, config: { ...cfg, hideFromGal: { attribute: "msExchHideFromAddressLists", value: "TRUE" } } };
  });
  const adOwnsHide = withAdHide.some((j) => j.systemKey === "active-directory" && adLaneHidesViaAttribute(j.config));
  return withAdHide.map((j) => {
    if (j.systemKey === "exchange") {
      const cfg = (j.config as Record<string, unknown> | null) ?? {};
      if (adOwnsHide) {
        // AD owns the hide — but an explicit truthy hideFromGal left on the exchange lane would
        // still fire a guaranteed-failing EXO attempt on the synced mailbox (WARN noise every
        // offboard). Stamp it false so the runner skips it; both web and runner read `hideFromGal`
        // before the `hideFromGAL` spelling, so this single key wins. An absent or already-false
        // value needs nothing.
        const explicit = readHideFromGal(cfg);
        if (explicit === undefined || hideFromGalOptedOut(cfg)) return j;
        return { ...j, config: { ...cfg, hideFromGal: false } };
      }
      if (hideFromGalOptedOut(cfg)) return j;
      return { ...j, config: { ...cfg, hideFromGal: true } };
    }
    if (j.systemKey === "google-workspace") {
      const cfg = (j.config as Record<string, unknown> | null) ?? {};
      if (hideFromGalOptedOut(cfg)) return j;
      return { ...j, config: { ...cfg, hideFromGal: true } };
    }
    return j;
  });
}

// The intake stores a reference field for DISPLAY: "lyao@aleto.co (55ebb6d8…)" — refLabel appends the
// sys_id so the record stays lookup-able. -ForwardingSmtpAddress needs the address on its own.
const SYS_ID_SUFFIX = /\s*\([^()]*\)\s*$/;
// Deliberately strict: a DISPLAY NAME is not an SMTP address, and handing one to Exchange would fail
// the step. local@domain.tld, no whitespace.
const LOOKS_LIKE_EMAIL = /^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/;

// The forwarding target an offboard ticket asked for, or null when it asked for none.
export function caseForwardingAddress(payload: Record<string, unknown>): string | null {
  // An address alone is NOT a request. Real cases (UM0030515, UM0030178) carry a populated target with
  // mailForwarded=false — forwarding a leaver's mail against an explicit "no" would be worse than the
  // bug this fixes.
  if (payload.mailForwarded !== true) return null;
  const raw = typeof payload.forwardEmailTo === "string" ? payload.forwardEmailTo.trim() : "";
  if (!raw) return null;
  const addr = raw.replace(SYS_ID_SUFFIX, "").trim();
  return LOOKS_LIKE_EMAIL.test(addr) ? addr : null;
}

export function resolvePlannedConfigs(
  client: PlanClient,
  payload: Record<string, unknown>,
  action: string,
  planned: PlannedJob[]
): PlannedJob[] {
  if (action === "offboard") return resolveOffboardConfigs(client, payload, planned);
  if (action !== "onboard") return planned;

  const personas = (client.personas ?? null) as Record<string, unknown> | null;
  const globals = (client.globals ?? null) as Record<string, Record<string, unknown>> | null;
  // "mirror <user>": copy a reference user's group memberships (live AD state → resolved by the
  // runner). Applies to v2.0 and v2.1 clients alike, so it's injected independently of personas.
  const mirror = typeof payload.mirrorPermissionsFromUser === "string" && payload.mirrorPermissionsFromUser.trim()
    ? payload.mirrorPermissionsFromUser.trim() : null;

  // One context for everything below (persona select + condition eval). Safe for v2.0 clients too —
  // selectPersona just returns null with no personas.
  const { context, persona, location } = buildPlanContext(payload, { personas: personas as never, locations: client.locations as never });

  // v2.1 resolution (persona/globals → flattened config) only when the client has those blocks.
  const resolved = (!personas && !globals)
    ? planned
    : planned.map((j) => ({
        ...j,
        config: resolveSystemConfig(
          j.systemKey,
          {
            globals: globals?.[j.systemKey] ?? null,
            persona: (persona?.def?.systems?.[j.systemKey] as Record<string, unknown> | undefined) ?? null,
            own: (j.config as Record<string, unknown> | null) ?? null,
          },
          context
        ),
      }));

  // Location-driven targets: a matched location can carry groups (+ an OU / address attributes) that
  // apply to the directory systems — e.g. a Boston hire gets FalconBOS + the floor-printer groups.
  // Groups are UNIONED into each directory job (the runner adds the ones each system actually has); an
  // OU is a default for AD only (a persona OU already set wins); attributes merge with the location
  // winning (they're office-specific, e.g. physicalDeliveryOfficeName / streetAddress).
  const locGroups = Array.isArray(location?.groups) ? (location!.groups as string[]).filter((g) => typeof g === "string" && g.trim()) : [];
  const locOu = typeof location?.ou === "string" ? location.ou : null;
  const locAttrs = location?.attributes && typeof location.attributes === "object" ? location.attributes as Record<string, unknown> : null;
  // Groups discovery proves are cloud-only are dropped from the AD lane only (kept on entra/m365/
  // exchange). Without discovery data this set is empty and every directory lane gets the full union.
  const cloudOnly = cloudOnlyGroupNames(client);
  const withLoc = (locGroups.length === 0 && !locOu && !locAttrs)
    ? resolved
    : resolved.map((j) => {
        if (!DIRECTORY_SYSTEMS.has(j.systemKey)) return j;
        const cfg = { ...((j.config as Record<string, unknown> | null) ?? {}) };
        if (locGroups.length) {
          const applicable = (j.systemKey === "active-directory" && cloudOnly.size)
            ? locGroups.filter((g) => !cloudOnly.has(g.toLowerCase()))
            : locGroups;
          const base = Array.isArray(cfg.groups) ? [...(cfg.groups as unknown[])] : [];
          const seen = new Set(base.map((g) => String(g).toLowerCase()));
          for (const g of applicable) { const k = g.toLowerCase(); if (!seen.has(k)) { seen.add(k); base.push(g); } }
          cfg.groups = base;
        }
        if (j.systemKey === "active-directory" && locOu && !cfg.ou) cfg.ou = locOu;
        if (locAttrs && Object.keys(locAttrs).length) cfg.attributes = { ...((cfg.attributes as Record<string, unknown> | undefined) ?? {}), ...locAttrs };
        return { ...j, config: cfg };
      });

  // Printers attached to the matched location become one manual checklist step (there is no
  // print-deployment executor). Only the PERSISTED split is honored — location.printers as an
  // array — never re-classify here: a real-but-undiscovered group must not be demoted to a
  // printer and dropped from the directory group-add. Un-migrated locations (no printers key)
  // keep the legacy behavior (typed printers still ride in `groups`) until edited once in the UI.
  const locPrinters = Array.isArray((location as { printers?: unknown } | null)?.printers)
    ? ((location as { printers: unknown[] }).printers).filter((x): x is string => typeof x === "string" && x.trim() !== "").map((x) => x.trim())
    : [];
  const printersJobs: PlannedJob[] = locPrinters.length === 0 ? [] : [{
    systemKey: "printers",
    sequence: 0, // filled in below relative to the final job list
    mode: "manual",
    requiresApproval: false,
    captureEvidence: false,
    intent: null,
    secretNames: [],
    dependsOn: [],
    config: {
      note: `Map printers at ${
        client.locations && typeof client.locations === "object"
          ? (Object.entries(client.locations as Record<string, unknown>).find(([, v]) => v === location)?.[0] ?? "the location")
          : "the location"
      }: ${locPrinters.join(", ")}`,
    },
  }];
  // Append the printers step to the final job list, giving it a sequence past every real job.
  const appendPrinters = (jobs: PlannedJob[]): PlannedJob[] => {
    if (printersJobs.length === 0) return jobs;
    const nextSeq = jobs.reduce((m, j) => Math.max(m, j.sequence), 0) + 1;
    return [...jobs, ...printersJobs.map((p) => ({ ...p, sequence: nextSeq }))];
  };

  // Requestor-picked groups from the ticket (FR #4): email distribution lists + security groups.
  // The intake captured them (payload.emailDistroGroups / payload.securityGroups) and the preview
  // showed them, but nothing ever merged them into a job's config — a non-default DL the requestor
  // added to the case was silently dropped. Same union rule as location groups. DLs go to the
  // m365/entra lane (the exchange namedGroups handoff below routes mail-enabled ones to EXO, which
  // is the only lane that can add DL members); security groups go to every directory lane — they
  // may live on-prem (AD) or in the cloud (Graph), and each runner adds the ones it actually has.
  const strList = (v: unknown): string[] =>
    Array.isArray(v) ? v.map((x) => (typeof x === "string" ? x.trim() : "")).filter((x) => x !== "")
    : typeof v === "string" ? v.split(/[,;]/).map((x) => x.trim()).filter((x) => x !== "")
    : [];
  // Requestor free-text must NEVER add someone to a privileged group: the runner binds as SYSTEM on
  // a DC, and a form field saying "Domain Admins" would otherwise make the hire a domain admin on
  // day one with no approval gate. Same well-known list the AD offboard's Test-CtgADProtectedGroup
  // refuses to strip — the add path has to be at least as careful as the remove path.
  const PROTECTED_GROUPS = new Set([
    "domain admins", "enterprise admins", "schema admins", "administrators",
    "account operators", "backup operators", "server operators", "print operators",
    "group policy creator owners", "dnsadmins", "key admins", "enterprise key admins",
  ].map((g) => g.toLowerCase()));
  const safeGroups = (list: string[]): string[] => list.filter((g) => !PROTECTED_GROUPS.has(g.toLowerCase()));
  const unionGroups = (cfg: Record<string, unknown>, add: string[]): void => {
    const base = Array.isArray(cfg.groups) ? [...(cfg.groups as unknown[])] : [];
    const seen = new Set(base.map((g) => String(g).toLowerCase()));
    for (const g of add) { const k = g.toLowerCase(); if (!seen.has(k)) { seen.add(k); base.push(g); } }
    cfg.groups = base;
  };
  const reqDls = safeGroups(strList(payload.emailDistroGroups));
  // FR #30: operator-typed "additional groups" on the case review panel (payload.extraGroups) merge
  // into the same mastering-lane routing as ticket-picked security groups — AD lane if the client
  // has one, else m365/entra — and pass the same protected-groups filter.
  const reqSec = safeGroups([...strList(payload.securityGroups), ...strList(payload.extraGroups)]);
  // No Graph lane planned (exchange-only client): the namedGroups handoff below has nothing to read
  // from, so hand the DLs to the exchange job directly.
  const hasGraphLane = withLoc.some((j) => j.systemKey === "m365" || j.systemKey === "entra");
  // Security groups go to ONE lane — the directory that masters them. On an AD-synced client that's
  // AD (the membership syncs up); adding them to the Graph lane too made every such onboard land
  // orange, because Graph refuses the write on an on-prem-synced group and the WARN parks the case.
  const hasAdLane = withLoc.some((j) => j.systemKey === "active-directory");
  const withRequested = (reqDls.length === 0 && reqSec.length === 0)
    ? withLoc
    : withLoc.map((j) => {
        const wantsDls = reqDls.length > 0 && (j.systemKey === "m365" || j.systemKey === "entra");
        const wantsSec = reqSec.length > 0 && (hasAdLane
          ? j.systemKey === "active-directory"
          : (j.systemKey === "m365" || j.systemKey === "entra"));
        const exchangeFallback = reqDls.length > 0 && !hasGraphLane && j.systemKey === "exchange";
        if (!wantsDls && !wantsSec && !exchangeFallback) return j;
        const cfg = { ...((j.config as Record<string, unknown> | null) ?? {}) };
        if (wantsDls || wantsSec) unionGroups(cfg, [...(wantsSec ? reqSec : []), ...(wantsDls ? reqDls : [])]);
        if (exchangeFallback) {
          const base = Array.isArray(cfg.namedGroups) ? [...(cfg.namedGroups as unknown[])] : [];
          const seen = new Set(base.map((g) => String(g).toLowerCase()));
          for (const g of reqDls) { const k = g.toLowerCase(); if (!seen.has(k)) { seen.add(k); base.push(g); } }
          cfg.namedGroups = base;
        }
        return { ...j, config: cfg };
      });

  // Case-requested SHARED MAILBOXES (FR #0000115). The intake captured them
  // (u_shared_resource_mailboxes -> payload.sharedMailboxes) and nothing planned them — the FOURTH
  // field of this exact shape, after #47 (out-of-office), #84 (delegates) and #97 (forwarding).
  //
  // The destination already exists: the m365/entra lane's defaultSharedMailboxes list, which the
  // Exchange finish grants at FullAccess by default (Invoke-CtgExchangeDefaultMailboxAccess, FR #15).
  // That is why the requester saw per-client defaults working while ticket-named ones did nothing —
  // the client list is profile config, and the ticket had no route to the same place.
  //
  // UNION, never replace: a client's standing list and the ticket's request are both wanted. Entries
  // may be bare strings (FullAccess) or { address, access }, so compare on the address either way — a
  // duplicate would be granted twice and logged twice, reading on the case as two separate grants.
  const reqMailboxes = strList(payload.sharedMailboxes);
  const withSharedMailboxes = reqMailboxes.length === 0 ? withRequested : withRequested.map((j) => {
    if (j.systemKey !== "m365" && j.systemKey !== "entra") return j;
    const cfg = (j.config as Record<string, unknown> | null) ?? {};
    const base = Array.isArray(cfg.defaultSharedMailboxes) ? [...(cfg.defaultSharedMailboxes as unknown[])] : [];
    const addressOf = (e: unknown): string =>
      (typeof e === "string" ? e : String((e as { address?: unknown })?.address ?? "")).trim().toLowerCase();
    const seen = new Set(base.map(addressOf).filter(Boolean));
    for (const m of reqMailboxes) {
      const k = m.toLowerCase();
      if (!seen.has(k)) { seen.add(k); base.push(m); }
    }
    return { ...j, config: { ...cfg, defaultSharedMailboxes: base } };
  });

  const withMirror = !mirror
    ? withSharedMailboxes
    : withSharedMailboxes.map((j) =>
        DIRECTORY_SYSTEMS.has(j.systemKey)
          ? { ...j, config: { ...((j.config as Record<string, unknown> | null) ?? {}), mirrorFromUser: mirror } }
          : j
      );

  // Re-hire (FR #3): "Is this a Re-Hire = Yes" means the person USED to exist here, so an executor
  // finding a same-name account is the EXPECTED outcome — adopt it (enable, stamp, reconcile)
  // instead of pausing the case with a username-collision decision. m365/entra ONLY: there, the
  // executor consults the policy strictly INSIDE its name-matched branch, so "adopt" can never take
  // over a different person's account. AD and Google already auto-adopt a name-matched account with
  // no policy at all — for them "adopt" is the operator's FORCE override that skips the name check
  // entirely, and a plan-injected default would let a rehire hijack an unrelated live account.
  // A policy the client or an operator already set wins over this default.
  const ADOPTING_SYSTEMS = new Set(["m365", "entra"]);
  const withRehire = payload.isRehire !== true
    ? withMirror
    : withMirror.map((j) => {
        if (!ADOPTING_SYSTEMS.has(j.systemKey)) return j;
        const cfg = (j.config as Record<string, unknown> | null) ?? {};
        if (cfg.usernameCollisionPolicy) return j;
        return { ...j, config: { ...cfg, usernameCollisionPolicy: "adopt" } };
      });

  // AD-synced clients (FR #25): the M365/Entra account originates on-prem via Entra Connect, so the
  // cloud lane must ADOPT the synced user, never create one. Stamp a create policy the runner enforces
  // at its create gate. Absent key = allow (every non-ad-synced client + pre-existing plan is
  // unchanged). Overrides that flip it back to allow: a persistent `allowCloudCreate` on the m365/entra
  // config, or the per-case `payload.allowCloudCreate` (set via /api/cases/[id]/m365-override).
  const CLOUD_CREATE_SYSTEMS = new Set(["m365", "entra"]);
  const caseAllowsCloudCreate = payload.allowCloudCreate === true;
  const withCloudCreate = client.backbone !== "ad_synced"
    ? withRehire
    : withRehire.map((j) => {
        if (!CLOUD_CREATE_SYSTEMS.has(j.systemKey)) return j;
        const cfg = (j.config as Record<string, unknown> | null) ?? {};
        const allow = caseAllowsCloudCreate || cfg.allowCloudCreate === true;
        return { ...j, config: { ...cfg, cloudCreate: allow ? "allow" : "deny" } };
      });

  // Per-client M365 licensing rules: ADD the intake-selected license(s) (e.g. needsComputer → E5 else
  // E1) to the client's base config.licenses — UNION, so a static add-on like "Defender for Office 365"
  // is kept alongside the rule-chosen tier. v2.0 + v2.1 alike. SKIP when the ticket explicitly listed
  // product licenses — a deliberate request overrides (the runner prefers payload.productLicenses).
  const explicitLicenses = Array.isArray(payload.productLicenses)
    && payload.productLicenses.some((x) => typeof x === "string" && x.trim() !== "");
  const licenseName = (l: unknown): string => (typeof l === "string" ? l : String((l as { name?: unknown; skuId?: unknown })?.name ?? (l as { skuId?: unknown })?.skuId ?? ""));
  const withLicenses = explicitLicenses
    ? withCloudCreate
    : withCloudCreate.map((j) => {
        if (j.systemKey !== "m365") return j;
        const cfg = (j.config as Record<string, unknown> | null) ?? {};
        const ruleLicenses = evaluateLicenseRules((cfg as { licenseRules?: unknown }).licenseRules, context);
        if (!ruleLicenses) return j;
        // base (static) licenses first, then append the rule-selected ones not already present (case-insensitive)
        const base = Array.isArray(cfg.licenses) ? [...cfg.licenses] : [];
        const seen = new Set(base.map((l) => licenseName(l).toLowerCase()).filter(Boolean));
        for (const r of ruleLicenses) { const k = r.toLowerCase(); if (!seen.has(k)) { seen.add(k); base.push(r); } }
        return { ...j, config: { ...cfg, licenses: base } };
      });

  // A group-based license entry with groupSource 'ad' is carried by an ON-PREM group the m365
  // (Graph) lane can't write. Append those groups to the active-directory job's groups here, at
  // PLAN time — the AD lane adds groups idempotently and runs before m365. (Deliberately not a
  // runtime handoff: seat-aware's LicenseFallbackAdGroup result field is consumed by nothing —
  // plan-time keeps the add visible in the plan preview and impossible to drop.)
  const adLicenseGroups: string[] = [];
  for (const j of withLicenses) {
    if (j.systemKey !== "m365" && j.systemKey !== "entra") continue;
    const cfg = j.config as { licenses?: unknown; defaultLicenses?: unknown } | null;
    for (const lics of [cfg?.licenses, cfg?.defaultLicenses]) {
      if (!Array.isArray(lics)) continue;
      for (const l of lics) {
        const o = l as { assignVia?: unknown; groupSource?: unknown; group?: unknown } | null;
        if (o && typeof o === "object" && o.assignVia === "group" && o.groupSource === "ad" && typeof o.group === "string" && o.group.trim()) {
          adLicenseGroups.push(o.group.trim());
        }
      }
    }
  }
  const withAdLicenseGroups = adLicenseGroups.length === 0 ? withLicenses : withLicenses.map((j) => {
    if (j.systemKey !== "active-directory") return j;
    const cfg = { ...((j.config as Record<string, unknown> | null) ?? {}) };
    const base = Array.isArray(cfg.groups) ? [...(cfg.groups as unknown[])] : [];
    const seen = new Set(base.map((g) => String(g).toLowerCase()));
    for (const g of adLicenseGroups) { const k = g.toLowerCase(); if (!seen.has(k)) { seen.add(k); base.push(g); } }
    return { ...j, config: { ...cfg, groups: base } };
  });

  // m365 and entra are the SAME Graph module ($DISPATCH['entra'] = $DISPATCH['m365']). When a client
  // models BOTH, the entra job would re-run the entire M365 onboard the m365 job already did — incl.
  // the expensive shared-mailbox/DL EXO mirror (hundreds of mailboxes). De-dupe: the entra lane skips
  // the EXO finish + group mirror (the m365 lane owns them). A client with ONLY entra is untouched.
  const hasM365 = withAdLicenseGroups.some((j) => j.systemKey === "m365");
  const deduped = !hasM365 ? withAdLicenseGroups : withAdLicenseGroups.map((j) => {
    if (j.systemKey !== "entra") return j;
    const cfg = { ...((j.config as Record<string, unknown> | null) ?? {}) };
    delete cfg.mirrorFromUser; // the m365 lane does the Graph group-mirror + EXO mirror
    return { ...j, config: { ...cfg, skipExoFinish: true } };
  });

  // Distribution lists requested on m365 can only be written by the Exchange Online lane (Graph
  // can't add DL members). Flow the m365/entra requested groups onto the exchange job's config so the
  // EXO step adds the distribution ones by name (it only sees its own config). It picks the DLs and
  // skips security/365 groups (those stay Graph's job).
  const m365Groups = deduped.find((j) => j.systemKey === "m365" || j.systemKey === "entra")?.config as { groups?: unknown } | null;
  const reqGroups = m365Groups && Array.isArray(m365Groups.groups) ? m365Groups.groups : null;
  if (!reqGroups || reqGroups.length === 0) return appendPrinters(deduped);
  return appendPrinters(deduped.map((j) =>
    j.systemKey === "exchange"
      ? { ...j, config: { ...((j.config as Record<string, unknown> | null) ?? {}), namedGroups: reqGroups } }
      : j
  ));
}
