"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { CATALOG } from "@/lib/generator/system-map";
import { withOnboardOu } from "@/lib/clients/ad-folders";
import { OuTreePicker } from "./ad-pickers";
import { copyText } from "@/lib/clipboard";

type Lane = "always" | "on_request" | "never" | "by_persona";
type Mode = "api" | "browser" | "manual" | "scim";
type GalMode = "default" | "off" | "attribute";
// Systems where "hide from GAL on offboard" is meaningful (FR #21).
const GAL_SYSTEMS = new Set(["exchange", "google-workspace", "active-directory"]);
type Row = {
  systemKey: string;
  mode: Mode;
  onboardWhen: Lane;
  offboardWhen: Lane;
  dependsOn: string[];
  requiresApproval: boolean;
  captureEvidence: boolean;
  offboardIntent: "disable" | "destructive"; // offboard classification (config.intent.offboard)
  onboardOu: string; // AD onboarding target DN (config.onboard.ou) — the field the runner actually uses
  galMode: GalMode; // hide-from-GAL deviation (config.offboard.hideFromGal) — default is hide, this only records opt-outs
  galAttribute: string; // AD-only: the attribute name when galMode === "attribute"
  // Exchange-only: offboard delegates' Full Access adds the mailbox to their Outlook (AutoMapping).
  // config.offboard.delegateAutoMapping — only `false` is stored; unset is on (FR #0000211).
  delegateAutoMap: boolean;
  secretNames: string[];
  configText: string; // JSON text; parsed on save
};

const BACKBONES = [
  { v: "", label: "— not modeled —" },
  { v: "entra", label: "Entra" },
  { v: "google", label: "Google" },
  { v: "ad_synced", label: "AD synced" },
  { v: "ad_standalone", label: "AD standalone" },
];
const LANES: Lane[] = ["always", "on_request", "by_persona", "never"];
const MODES: Mode[] = ["api", "browser", "manual", "scim"];
// Color the lane selects so onboard/offboard participation is scannable at a glance: green = runs,
// amber = only on request, grey = off. (Flat tints, no gradients — matches the host design system.)
const LANE_STYLE: Record<Lane, CSSProperties> = {
  always: { background: "#e8f5ee", color: "#15803d", borderColor: "#bbf7d0" },
  on_request: { background: "#fef6e7", color: "#92400e", borderColor: "#fde9c8" },
  by_persona: { background: "#f2ecfd", color: "#6d28d9", borderColor: "#e4d9fb" },
  never: { background: "#f4f4f5", color: "#9ca3af", borderColor: "#e5e7eb" },
};
// Hover help for each field — the ⓘ next to every label (sentence case, plain English).
const HELP = {
  mode: "How the step runs — api: automated via a Coretelligent.* module · browser: Playwright automation · manual: a human checklist item recorded on the case.",
  onboard: "When this system runs on ONBOARDING — always · on request (only when the intake asks for it) · by persona (only when the matched persona's systems list includes it — edit personas under Roles & rules) · never (not part of onboarding).",
  offboard: "When this system runs on OFFBOARDING — always · on request · by persona (only when the matched persona granted it) · never. Onboard and Offboard are the two runbooks; set each independently.",
  depends: "System keys that must finish first (comma-separated). Drives run order — e.g. directory-sync depends on exchange, active-directory.",
  approval: "Destructive step — gated server-side. The job won't run until an operator approves it on the case (offboarding deletes/disables).",
  evidence: "Before doing anything, snapshot the user's current state (group memberships, license/app assignments) and attach it to the case — so there's an audit trail and you can restore if needed. Mainly used on offboarding.",
  intent: "How destructive this system's OFFBOARD step is. disable = reversible containment (lock the account, isolate the device, revoke sessions) — undoable, and a candidate for future automation. destructive = actually deletes data (e.g. delete a mailbox) — always requires operator approval AND snapshots state first so it's redoable.",
  secrets: "The Delinea secret references this system needs at run time (comma-separated names, e.g. m365-admin). Names only — never the values.",
  config: 'Per-lane JSON settings, nested under onboard / offboard. e.g. { "offboard": { "delete": true } }. Leave blank for defaults.',
  onboardOu: "Where new AD accounts are created (config.onboard.ou). This is the value the runner uses — it overrides any OU set in Roles & rules. Type a full DN or 📁 Browse the folders discovered from the DC. Leave blank to create at the domain default. Refresh the folder list under Roles & rules → “Refresh AD objects from DC”.",
  hideFromGal: "Hiding offboarded users from the Global Address List is the default (FR #21). Use this only to record a deviation: “Do NOT hide” opts this client out entirely; “Hide via AD attribute…” (AD only) hides by setting a named attribute (e.g. msExchHideFromAddressLists) to TRUE instead of the default mechanism.",
  delegateAutoMap: "Offboarding: when a delegate (the manager, or someone named on the ticket) is given Full Access to the leaver's mailbox, whether the mailbox is also added to their Outlook automatically. This is the client's default; a case can change it before the Exchange step runs.",
};

function Field({ label, help, children, grow }: { label: string; help: string; children: ReactNode; grow?: boolean }) {
  return (
    <label style={{ display: "flex", flexDirection: "column", gap: 3, ...(grow ? { flex: "1 1 280px" } : {}) }}>
      <span style={{ fontSize: 11, fontWeight: 600, color: "var(--muted, #6b7280)", whiteSpace: "nowrap" }}>
        {label}{" "}
        <span title={help} style={{ cursor: "help", color: "var(--faint, #9ca3af)", borderBottom: "1px dotted currentColor" }}>ⓘ</span>
      </span>
      {children}
    </label>
  );
}

// A credential the app found sitting in this client's Delinea folder for a secret slot it now needs.
type Suggestion = {
  secretName: string;
  externalId: string;
  label: string;
  template: string | null;
  folderPath: string;
  confidence: "high" | "medium";
  reason: string;
  alternatives: { externalId: string; label: string }[];
};

const ALL_KEYS = Object.keys(CATALOG).sort();
const mapLane = (l: string | null): Lane => (l === "on-request" ? "on_request" : l === "by-persona" ? "by_persona" : l === "always" ? "always" : "never");

function rowFromCatalog(key: string): Row {
  const c = CATALOG[key];
  return {
    systemKey: key,
    mode: (c?.mode ?? "api") as Mode,
    onboardWhen: mapLane(c?.onboard ?? null),
    offboardWhen: mapLane(c?.offboard ?? null),
    dependsOn: [],
    requiresApproval: false,
    captureEvidence: false,
    offboardIntent: "disable",
    onboardOu: "",
    galMode: "default",
    galAttribute: "",
    delegateAutoMap: true,
    secretNames: c?.secret ? [c.secret] : [],
    configText: "",
  };
}

// Reads the GAL deviation out of a system's parsed config.offboard.hideFromGal. Handles both the
// canonical casing and the "hideFromGAL" variant seen in some hand-edited configs.
function galFromConfig(config: unknown): { galMode: GalMode; galAttribute: string } {
  const offboard = (config as { offboard?: Record<string, unknown> } | null)?.offboard;
  const raw = offboard?.hideFromGal ?? offboard?.hideFromGAL;
  if (raw === false) return { galMode: "off", galAttribute: "" };
  if (raw && typeof raw === "object" && typeof (raw as { attribute?: unknown }).attribute === "string") {
    return { galMode: "attribute", galAttribute: (raw as { attribute: string }).attribute };
  }
  return { galMode: "default", galAttribute: "" };
}

export function SystemsEditor({ slug, open, onClose }: { slug: string | null; open: boolean; onClose: () => void }) {
  const router = useRouter();
  const ref = useRef<HTMLDialogElement>(null);
  const [tab, setTab] = useState<"manual" | "parse" | "kb">("manual");
  const [loading, setLoading] = useState(false);
  const [name, setName] = useState("");
  const [backbone, setBackbone] = useState("");
  const [rows, setRows] = useState<Row[]>([]);
  // AD folders the agent discovered from the DC (client.adObjects.ous) — feeds the onboarding-OU tree
  // picker on the active-directory row. `ouPickerRow` tracks which row has its Browse tree open.
  const [adOus, setAdOus] = useState<string[]>([]);
  const [ouPickerRow, setOuPickerRow] = useState<number | null>(null);
  const [addKey, setAddKey] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  // Whether this client has a parent — enables the per-system "revert to parent" affordance (FR #23).
  const [hasParent, setHasParent] = useState(false);
  // parse tab
  const [paste, setPaste] = useState("");
  const [useAI, setUseAI] = useState(false);
  const [parsing, setParsing] = useState(false);
  const [parsed, setParsed] = useState<{ systems: string[]; backbone: string; unmodeled: string[]; usedAI: boolean } | null>(null);
  // kb tab
  const [kb, setKb] = useState<{ onboard: { html: string; markdown: string }; offboard: { html: string; markdown: string } } | null>(null);

  useEffect(() => {
    if (open && slug) {
      if (!ref.current?.open) ref.current?.showModal();
      void load(slug);
    } else if (!open) {
      ref.current?.open && ref.current.close();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, slug]);

  async function load(s: string) {
    setLoading(true); setError(null); setTab("manual"); setParsed(null); setKb(null); setPaste("");
    try {
      const res = await fetch(`/api/clients/${s}`);
      const c = await res.json();
      setName(c.name ?? s);
      setBackbone(c.backbone ?? "");
      setHasParent(Boolean(c.parentId));
      const ad = (c.adObjects ?? {}) as { ous?: unknown };
      setAdOus(Array.isArray(ad.ous) ? (ad.ous as string[]) : []);
      setOuPickerRow(null);
      setRows(
        (c.systems ?? []).map((sys: Record<string, unknown>) => ({
          systemKey: sys.systemKey,
          mode: sys.mode,
          onboardWhen: sys.onboardWhen,
          offboardWhen: sys.offboardWhen,
          // round-trip dependsOn — without this, every save wiped it and broke topo-ordering
          dependsOn: Array.isArray(sys.dependsOn) ? sys.dependsOn : [],
          requiresApproval: Boolean(sys.requiresApproval),
          captureEvidence: Boolean(sys.captureEvidence),
          offboardIntent: ((sys.config as { intent?: { offboard?: unknown } } | null)?.intent?.offboard) === "destructive" ? "destructive" : "disable",
          onboardOu: String((sys.config as { onboard?: { ou?: unknown } } | null)?.onboard?.ou ?? ""),
          ...galFromConfig(sys.config),
          delegateAutoMap: (sys.config as { offboard?: { delegateAutoMapping?: unknown } } | null)?.offboard?.delegateAutoMapping !== false,
          secretNames: Array.isArray(sys.secretNames) ? sys.secretNames : [],
          configText: sys.config ? JSON.stringify(sys.config, null, 2) : "",
        }))
      );
    } finally {
      setLoading(false);
    }
  }

  function update(i: number, patch: Partial<Row>) {
    setRows((rs) => rs.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  }
  function remove(i: number) {
    setRows((rs) => rs.filter((_, j) => j !== i));
  }
  // Revert ONE system to the parent's version (FR #23) — overwrites this client's row for it and clears
  // its own credential wiring so the parent's brokers. Applies immediately server-side and reloads.
  async function revertSystem(systemKey: string) {
    if (!slug) return;
    if (!confirm(`Revert ${systemKey} on ${name} to the parent's version?\n\nOverwrites this system with the parent's and deletes this client's own Delinea credential references for it, so the parent's broker. The vault secrets aren't deleted, but re-wiring is manual. Applies immediately and reloads this dialog (discarding unsaved edits). This can't be undone.`)) return;
    setSaving(true); setError(null);
    try {
      const res = await fetch(`/api/clients/${slug}`, {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ action: "reset-to-parent", scope: "full", systemKey }),
      });
      if (!res.ok) { setError((await res.json().catch(() => ({}))).error ?? "could not revert"); return; }
      await load(slug);
      router.refresh();
    } finally {
      setSaving(false);
    }
  }
  function addSystem(key: string) {
    if (!key || rows.some((r) => r.systemKey === key)) return;
    const row = rowFromCatalog(key);
    setRows((rs) => [...rs, row]);
    setAddKey("");
    // The system knows which secret it brokers the moment it's added, so scan this client's Delinea
    // folder for a credential that fits and offer it — rather than leaving the operator to hunt for
    // the id. Fire-and-forget: a failed or slow scan must never block adding the system.
    void suggestFor(row.secretNames);
  }

  // Delinea credential suggestions, keyed by secret name (e.g. "sentinelone" -> the folder's
  // "S1_API integration" secret). Dismissed suggestions stay dismissed for the session.
  const [suggestions, setSuggestions] = useState<Record<string, Suggestion>>({});
  const [scanning, setScanning] = useState(false);

  async function suggestFor(secretNames: string[]) {
    const names = secretNames.filter((n) => n && !(n in suggestions));
    if (names.length === 0) return;
    setScanning(true);
    try {
      const res = await fetch(`/api/clients/${slug}/secrets/suggest`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ secretNames: names }),
      });
      if (!res.ok) return;
      const data = (await res.json()) as { suggestions?: Suggestion[] };
      if (!data.suggestions?.length) return;
      setSuggestions((s) => ({ ...s, ...Object.fromEntries(data.suggestions!.map((x) => [x.secretName, x])) }));
    } catch {
      // an assist, not a gate — stay silent
    } finally {
      setScanning(false);
    }
  }

  function dismissSuggestion(secretName: string) {
    setSuggestions((s) => {
      const next = { ...s };
      delete next[secretName];
      return next;
    });
  }

  // Accepting a suggestion wires the Delinea REFERENCE (the secret id) on the client — the same write
  // the Secrets panel's save does. The systems editor itself only carries secret NAMES, so this can't
  // ride along with the systems save; it's persisted immediately and surfaced on the Secrets panel,
  // where the operator can Test it.
  async function setSecretRef(secretName: string, externalId: string) {
    setError(null);
    try {
      const res = await fetch(`/api/clients/${slug}/secrets`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ secrets: [{ name: secretName, externalId }] }),
      });
      if (!res.ok) {
        const d = (await res.json().catch(() => null)) as { error?: string } | null;
        setError(d?.error ?? `could not wire ${secretName} (HTTP ${res.status})`);
        return;
      }
      setWired((w) => ({ ...w, [secretName]: externalId }));
      router.refresh(); // the Secrets panel on the page behind reflects the new reference
    } catch (e) {
      setError((e as Error).message);
    }
  }
  // Secret refs wired from a suggestion during this session — so the banner can confirm rather than
  // silently vanish.
  const [wired, setWired] = useState<Record<string, string>>({});

  async function save() {
    setSaving(true); setError(null);
    // validate config JSON
    const systems = [];
    for (const r of rows) {
      let config: Record<string, unknown> | null = null;
      if (r.configText.trim()) {
        try { config = JSON.parse(r.configText); }
        catch { setError(`Invalid JSON config for ${r.systemKey}`); setSaving(false); return; }
      }
      // The Offboard-intent select is authoritative: merge it into config.intent.offboard so a
      // destructive step is auto-gated (approval + evidence) by the orchestrator at plan time.
      if (config === null) config = {};
      const intent = { ...((config.intent as Record<string, unknown> | undefined) ?? {}), offboard: r.offboardIntent };
      config = { ...config, intent };
      // The delegate AutoMapping control is authoritative for config.offboard.delegateAutoMapping, the
      // client default the planner flattens onto the exchange offboard job (a case can override it).
      if (r.systemKey === "exchange") {
        const offboard = { ...((config.offboard as Record<string, unknown> | undefined) ?? {}) };
        if (r.delegateAutoMap) delete offboard.delegateAutoMapping;
        else offboard.delegateAutoMapping = false;
        if (Object.keys(offboard).length === 0) {
          const { offboard: _drop, ...rest } = config;
          config = rest;
        } else {
          config = { ...config, offboard };
        }
      }
      // The onboarding-OU control is authoritative for the AD create target: merge it into
      // config.onboard.ou (the field the runner reads), so it wins over the raw JSON textarea — the
      // same "structured control beats the blob" contract as offboardIntent above.
      if (r.systemKey === "active-directory") config = withOnboardOu(config, r.onboardOu.trim());
      // The GAL control is authoritative for the offboard hide-from-GAL deviation: merge it into
      // config.offboard.hideFromGal (the planner flattens config.offboard onto the offboard job, so
      // this becomes the top-level config.hideFromGal the planner/runner read). Preserve any other
      // offboard siblings (e.g. convertToShared) already in the JSON blob; drop offboard entirely if
      // this was the only key.
      if (GAL_SYSTEMS.has(r.systemKey)) {
        const offboard = { ...((config.offboard as Record<string, unknown> | undefined) ?? {}) };
        if (r.galMode === "off") {
          offboard.hideFromGal = false;
        } else if (r.galMode === "attribute" && r.galAttribute.trim()) {
          offboard.hideFromGal = { attribute: r.galAttribute.trim(), value: "TRUE" };
        } else {
          delete offboard.hideFromGal;
          delete offboard.hideFromGAL; // clear the casing variant if present
        }
        if (Object.keys(offboard).length === 0) {
          const { offboard: _drop, ...rest } = config;
          config = rest;
        } else {
          config = { ...config, offboard };
        }
      }
      systems.push({ ...r, secretNames: r.secretNames, config });
    }
    try {
      const res = await fetch(`/api/clients/${slug}/systems`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ systems, backbone: backbone || null }),
      });
      const data = await res.json();
      if (!res.ok) { setError(data.error ?? res.statusText); }
      else { router.refresh(); onClose(); }
    } finally {
      setSaving(false);
    }
  }

  async function runParse() {
    setParsing(true); setParsed(null);
    try {
      const res = await fetch(`/api/clients/${slug}/parse`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: paste, useAI }),
      });
      setParsed(await res.json());
    } finally {
      setParsing(false);
    }
  }
  function applyParsed() {
    if (!parsed) return;
    setRows((rs) => {
      const have = new Set(rs.map((r) => r.systemKey));
      const add = parsed.systems.filter((k) => CATALOG[k] && !have.has(k)).map(rowFromCatalog);
      return [...rs, ...add];
    });
    if (parsed.backbone) setBackbone(mapBackbone(parsed.backbone));
    setTab("manual");
  }

  async function genKb() {
    const res = await fetch(`/api/clients/${slug}/kb`);
    setKb(await res.json());
  }

  return (
    <dialog ref={ref} onClose={onClose} style={{ width: 1080, maxWidth: "96vw" }}>
      <div className="row-between">
        <h2>Edit systems — {name}</h2>
        <button onClick={onClose}>Close</button>
      </div>

      <div className="toolbar" style={{ marginTop: "0.5rem" }}>
        <button className={tab === "manual" ? "primary" : ""} onClick={() => setTab("manual")}>Manual</button>
        <button className={tab === "parse" ? "primary" : ""} onClick={() => setTab("parse")}>Parse instructions</button>
        <button className={tab === "kb" ? "primary" : ""} onClick={() => { setTab("kb"); if (!kb) void genKb(); }}>KB article</button>
      </div>

      {loading && <p className="note"><span className="spinner" />Loading…</p>}

      {!loading && tab === "manual" && (
        <div>
          <div className="filters">
            <label style={{ margin: 0 }}>Backbone</label>
            <select className="inline" value={backbone} onChange={(e) => setBackbone(e.target.value)}>
              {BACKBONES.map((b) => <option key={b.v} value={b.v}>{b.label}</option>)}
            </select>
            <span className="grow" />
            <select className="inline" value={addKey} onChange={(e) => setAddKey(e.target.value)}>
              <option value="">add system…</option>
              {ALL_KEYS.filter((k) => !rows.some((r) => r.systemKey === k)).map((k) => <option key={k} value={k}>{k}</option>)}
            </select>
            <button onClick={() => addSystem(addKey)} disabled={!addKey}>Add</button>
          </div>

          {scanning && <p className="note" style={{ margin: "0.4rem 0 0" }}><span className="spinner" />Scanning this client&apos;s Delinea folder for a matching credential…</p>}

          {/* A credential for the system just added is already sitting in the client's Delinea folder —
              offer it rather than making the operator hunt for the id. Wiring it fills the secret ref;
              it still has to be saved (and tested) like any other edit. */}
          {Object.entries(wired).map(([name, id]) => (
            <p key={name} className="note" style={{ margin: "0.4rem 0 0", color: "#15803d" }}>
              Wired <b style={{ fontFamily: "monospace" }}>{name}</b> to Delinea #{id} — test it on the Secrets panel.
            </p>
          ))}

          {Object.values(suggestions).map((s) => (
            <div
              key={s.secretName}
              style={{
                margin: "0.5rem 0 0",
                border: "1px solid #bbf7d0",
                background: "#e8f5ee",
                color: "#15803d",
                borderRadius: 10,
                padding: "0.6rem 0.75rem",
                display: "flex",
                alignItems: "center",
                gap: 10,
                flexWrap: "wrap",
              }}
            >
              <span style={{ flex: "1 1 320px", fontSize: 13 }}>
                Found a credential for <b style={{ fontFamily: "monospace" }}>{s.secretName}</b> in this client&apos;s Delinea
                folder: <b>{s.label}</b> (#{s.externalId}){s.template ? <> · {s.template}</> : null}
                {s.confidence === "medium" && (
                  <> — <b>a guess</b>, so check it before saving.</>
                )}
              </span>
              <button
                onClick={() => {
                  setSecretRef(s.secretName, s.externalId);
                  dismissSuggestion(s.secretName);
                }}
              >
                Use #{s.externalId}
              </button>
              <button className="ghost" onClick={() => dismissSuggestion(s.secretName)}>Dismiss</button>
            </div>
          ))}

          <p className="note" style={{ margin: "0.4rem 0 0.3rem" }}>
            <b>Onboard</b> and <b>Offboard</b> are the two runbooks — set when each system runs:{" "}
            <span className="badge" style={LANE_STYLE.always}>always</span>{" "}
            <span className="badge" style={LANE_STYLE.on_request}>on request</span>{" "}
            <span className="badge" style={LANE_STYLE.by_persona}>by persona</span>{" "}
            <span className="badge" style={LANE_STYLE.never}>never</span>. by persona = only when the matched
            persona lists the system (e.g. xMatters for on-call departments — add it to those personas under Roles & rules).
          </p>
          <div style={{ display: "grid", gap: 10 }}>
            {rows.map((r, i) => (
              <div key={r.systemKey} style={{ border: "1px solid var(--line, #e5e7eb)", borderRadius: 10, padding: "0.7rem 0.85rem" }}>
                <div className="row-between" style={{ alignItems: "center" }}>
                  <b style={{ fontFamily: "monospace", fontSize: 14 }}>{r.systemKey}</b>
                  <span style={{ display: "inline-flex", gap: 8, alignItems: "center" }}>
                    {hasParent && (
                      <button title={`Revert ${r.systemKey} to the parent's version (overwrites it + clears its own credential wiring)`} onClick={() => revertSystem(r.systemKey)} disabled={saving} className="note" style={{ fontSize: 12 }}>↩ revert to parent</button>
                    )}
                    <button title={`Remove ${r.systemKey}`} onClick={() => remove(i)} style={{ fontSize: 12 }}>✕ remove</button>
                  </span>
                </div>
                {/* Row 1 — what & when */}
                <div style={{ display: "flex", flexWrap: "wrap", gap: 16, marginTop: "0.55rem", alignItems: "flex-end" }}>
                  <Field label="Mode" help={HELP.mode}>
                    <select value={r.mode} onChange={(e) => update(i, { mode: e.target.value as Mode })}>{MODES.map((m) => <option key={m}>{m}</option>)}</select>
                  </Field>
                  <Field label="Onboard" help={HELP.onboard}>
                    <select value={r.onboardWhen} onChange={(e) => update(i, { onboardWhen: e.target.value as Lane })} style={{ ...LANE_STYLE[r.onboardWhen], fontWeight: 600 }}>{LANES.map((l) => <option key={l} value={l}>{l.replace("_", " ")}</option>)}</select>
                  </Field>
                  <Field label="Offboard" help={HELP.offboard}>
                    <select value={r.offboardWhen} onChange={(e) => update(i, { offboardWhen: e.target.value as Lane })} style={{ ...LANE_STYLE[r.offboardWhen], fontWeight: 600 }}>{LANES.map((l) => <option key={l} value={l}>{l.replace("_", " ")}</option>)}</select>
                  </Field>
                  <Field label="Depends on" help={HELP.depends}>
                    <input value={r.dependsOn.join(", ")} onChange={(e) => update(i, { dependsOn: e.target.value.split(",").map((x) => x.trim()).filter(Boolean) })} placeholder="—" style={{ width: 150 }} />
                  </Field>
                  <Field label="Approval" help={HELP.approval}>
                    <input type="checkbox" style={{ width: "auto", height: 18 }} checked={r.requiresApproval} onChange={(e) => update(i, { requiresApproval: e.target.checked })} />
                  </Field>
                </div>
                {/* Row 2 — evidence, secrets, config */}
                <div style={{ display: "flex", flexWrap: "wrap", gap: 16, marginTop: "0.55rem", alignItems: "flex-start" }}>
                  <Field label="Evidence" help={HELP.evidence}>
                    <input type="checkbox" style={{ width: "auto", height: 18 }} checked={r.captureEvidence} onChange={(e) => update(i, { captureEvidence: e.target.checked })} />
                  </Field>
                  <Field label="Offboard intent" help={HELP.intent}>
                    <select value={r.offboardIntent} onChange={(e) => update(i, { offboardIntent: e.target.value as Row["offboardIntent"] })}
                      style={r.offboardIntent === "destructive" ? { color: "#b3261e", borderColor: "#f3c0bb", fontWeight: 600 } : { color: "#1d4ed8" }}
                      disabled={r.offboardWhen === "never"}>
                      <option value="disable">disable (reversible)</option>
                      <option value="destructive">destructive (delete)</option>
                    </select>
                  </Field>
                  {GAL_SYSTEMS.has(r.systemKey) && (
                    <Field label="Hide from GAL" help={HELP.hideFromGal}>
                      <select value={r.galMode} onChange={(e) => update(i, { galMode: e.target.value as GalMode })}>
                        <option value="default">Default — hide from GAL</option>
                        <option value="off">Do NOT hide (client opts out)</option>
                        {r.systemKey === "active-directory" && <option value="attribute">Hide via AD attribute…</option>}
                      </select>
                      {r.galMode === "attribute" && (
                        <input
                          value={r.galAttribute}
                          onChange={(e) => update(i, { galAttribute: e.target.value })}
                          placeholder="msExchHideFromAddressLists"
                          style={{ marginTop: 4, fontFamily: "monospace", fontSize: 12 }}
                        />
                      )}
                    </Field>
                  )}
                  {r.systemKey === "exchange" && (
                    <Field label="Delegate AutoMapping" help={HELP.delegateAutoMap}>
                      <select value={r.delegateAutoMap ? "on" : "off"} onChange={(e) => update(i, { delegateAutoMap: e.target.value === "on" })} disabled={r.offboardWhen === "never"}>
                        <option value="on">On — add the mailbox to the delegate&rsquo;s Outlook</option>
                        <option value="off">Off — access only, not added to Outlook</option>
                      </select>
                    </Field>
                  )}
                  <Field label="Secrets" help={HELP.secrets}>
                    <input value={r.secretNames.join(", ")} onChange={(e) => update(i, { secretNames: e.target.value.split(",").map((x) => x.trim()).filter(Boolean) })} placeholder="—" style={{ width: 200 }} />
                  </Field>
                  <Field label="Config (JSON)" help={HELP.config} grow>
                    <textarea value={r.configText} onChange={(e) => update(i, { configText: e.target.value })} placeholder={'{ "offboard": { } }'} rows={2} style={{ width: "100%", minWidth: 260, fontFamily: "monospace", fontSize: 12 }} />
                  </Field>
                </div>
                {/* Row 3 — AD onboarding OU/folder picker (writes config.onboard.ou, the field the runner uses) */}
                {r.systemKey === "active-directory" && (
                  <div style={{ marginTop: "0.55rem", maxWidth: 520 }}>
                    <Field label="Onboarding OU / folder" help={HELP.onboardOu} grow>
                      <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
                        <input value={r.onboardOu} onChange={(e) => update(i, { onboardOu: e.target.value })}
                          placeholder="CN=Users,DC=… or OU=…,DC=…" style={{ flex: 1, minWidth: 240, fontFamily: "monospace", fontSize: 12 }} />
                        <button type="button" onClick={() => setOuPickerRow(ouPickerRow === i ? null : i)}>
                          {ouPickerRow === i ? "Close" : "📁 Browse"}
                        </button>
                      </div>
                    </Field>
                    {ouPickerRow === i && (
                      <div style={{ marginTop: 6 }}>
                        <OuTreePicker ous={adOus} onPick={(dn) => { update(i, { onboardOu: dn }); setOuPickerRow(null); }} />
                      </div>
                    )}
                  </div>
                )}
              </div>
            ))}
            {rows.length === 0 && <p className="muted" style={{ textAlign: "center", padding: "1rem", border: "1px dashed var(--line, #e5e7eb)", borderRadius: 10 }}>No systems. Add one above or use “Parse instructions”.</p>}
          </div>

          {error && <p className="note danger">{error}</p>}
          <div className="dialog-actions">
            <button onClick={onClose} disabled={saving}>Cancel</button>
            <button className="primary" onClick={save} disabled={saving}>{saving ? "Saving…" : "Save changes"}</button>
          </div>
        </div>
      )}

      {!loading && tab === "parse" && (
        <div>
          <p className="note">Paste the runbook (HTML or text). Detected systems are merged into the manual editor — review before saving.</p>
          <textarea value={paste} onChange={(e) => setPaste(e.target.value)} rows={8} placeholder="Paste ServiceNow KB runbook…" style={{ width: "100%", fontFamily: "monospace", fontSize: 12 }} />
          <div className="toolbar" style={{ marginTop: "0.5rem" }}>
            <label style={{ display: "flex", gap: "0.4rem", alignItems: "center", margin: 0 }}>
              <input type="checkbox" style={{ width: "auto" }} checked={useAI} onChange={(e) => setUseAI(e.target.checked)} /> use AI
            </label>
            <button className="primary" onClick={runParse} disabled={parsing || !paste.trim()}>{parsing ? "Detecting…" : "Detect systems"}</button>
          </div>
          {parsed && (
            <div style={{ marginTop: "0.75rem" }}>
              <p className="note">Backbone: <strong>{parsed.backbone}</strong> · detected {parsed.systems.length} systems {parsed.usedAI ? "(AI)" : "(heuristic)"}</p>
              <p>{parsed.systems.map((s) => <span key={s} className="badge" style={{ marginRight: 4 }}>{s}</span>)}</p>
              {parsed.unmodeled.length > 0 && <p className="note">not modeled: {parsed.unmodeled.slice(0, 12).join(", ")}</p>}
              <button className="primary" onClick={applyParsed}>Add detected → manual</button>
            </div>
          )}
        </div>
      )}

      {!loading && tab === "kb" && (
        <div>
          <p className="note">Rendered from the <em>saved</em> systems. Save first to reflect edits. Paste into a ServiceNow KB article.</p>
          {!kb ? <p className="note"><span className="spinner" />Rendering…</p> : (
            <div style={{ display: "grid", gap: "0.75rem" }}>
              {(["onboard", "offboard"] as const).map((action) => (
                <div key={action}>
                  <strong>{action}</strong>
                  <CopyBox label="HTML" text={kb[action].html} />
                  <CopyBox label="Markdown" text={kb[action].markdown} />
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </dialog>
  );
}

function CopyBox({ label, text }: { label: string; text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div style={{ marginTop: "0.25rem" }}>
      <div className="row-between">
        <span className="note">{label}</span>
        <button onClick={() => { void copyText(text).then((ok) => setCopied(ok)); setTimeout(() => setCopied(false), 1200); }}>
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <textarea readOnly value={text} rows={5} style={{ width: "100%", fontFamily: "monospace", fontSize: 11 }} />
    </div>
  );
}

function mapBackbone(b: string): string {
  return b === "ad-synced" ? "ad_synced" : b === "ad-standalone" ? "ad_standalone" : b;
}
