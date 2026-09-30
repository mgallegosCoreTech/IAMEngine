"use client";

// Per-client M365 licensing RULES: choose the onboarding license from intake facts (e.g. "needs a
// computer → E5, else E1"). Edits config.onboard.licenseRules. Rules are tried top-to-bottom — the
// FIRST match wins; a blank condition is a catch-all default (put it last). An explicit license on
// the ServiceNow ticket overrides these. After saving, re-plan open cases to apply to in-flight ones.
// A child client that follows its parent's rules and hasn't set its own uses the PARENT's license
// rules (`inherited`); saving rules here overrides them, and `canInherit` offers the way back.
import { useState } from "react";
import { useRouter } from "next/navigation";
import { COMMON_LICENSES as COMMON } from "@/lib/m365/license-catalog";
import { ConditionBuilder } from "./condition-builder";

type Rule = { when: string; licenses: string[] };

function LicensePicker({ value, onChange }: { value: string[]; onChange: (v: string[]) => void }) {
  const [custom, setCustom] = useState("");
  const add = (name: string) => { const t = name.trim(); if (t && !value.includes(t)) onChange([...value, t]); };
  return (
    <div>
      <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginBottom: 4 }}>
        {value.length === 0 && <span className="note">no license chosen</span>}
        {value.map((l) => (
          <span key={l} className="badge" style={{ display: "inline-flex", gap: 4, alignItems: "center" }}>
            {l}
            <button className="icon-btn" style={{ width: 16, height: 16, color: "#b3261e" }} title="remove" onClick={() => onChange(value.filter((x) => x !== l))}>×</button>
          </span>
        ))}
      </div>
      <div style={{ display: "flex", gap: 6 }}>
        <select className="inline" value="" onChange={(e) => { if (e.target.value) add(e.target.value); }} style={{ fontSize: 12 }}>
          <option value="">add a license…</option>
          {COMMON.filter((c) => !value.includes(c)).map((c) => <option key={c} value={c}>{c}</option>)}
        </select>
        <input value={custom} placeholder="or a custom name / SKU" onChange={(e) => setCustom(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); add(custom); setCustom(""); } }} style={{ fontSize: 12 }} />
      </div>
    </div>
  );
}

export function M365LicenseRulesEditor({ slug, current, inherited = null, canInherit = null }: {
  slug: string;
  current: { when?: string; licenses: string[] }[];
  // The parent's rules this client plans with, because it hasn't set its own.
  inherited?: { parentName: string; parentSlug: string; rules: { when?: string; licenses: string[] }[] } | null;
  // The parent's name when this client has its own rules but could go back to the parent's.
  canInherit?: string | null;
}) {
  const router = useRouter();
  const norm = (rs: { when?: string; licenses: string[] }[]): Rule[] => rs.map((r) => ({ when: r.when ?? "", licenses: r.licenses }));
  const [open, setOpen] = useState(false);
  const [rules, setRules] = useState<Rule[]>(norm(current));
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  const set = (i: number, patch: Partial<Rule>) => setRules((rs) => rs.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  const move = (i: number, d: -1 | 1) => setRules((rs) => { const n = [...rs]; const t = i + d; if (t < 0 || t >= n.length) return rs; [n[i], n[t]] = [n[t], n[i]]; return n; });

  // Clear this client's own rules so it plans with the parent's again.
  const useParent = async () => {
    setBusy(true); setMsg(null);
    try {
      const r = await fetch(`/api/clients/${slug}/m365-license-rules`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ inherit: true }) });
      const d = await r.json().catch(() => ({}));
      if (!r.ok) { setMsg({ ok: false, text: d.error ?? `failed (${r.status})` }); return; }
      setOpen(false);
      router.refresh();
    } catch (e) { setMsg({ ok: false, text: (e as Error).message }); }
    finally { setBusy(false); }
  };

  if (!open && inherited) {
    return (
      <div className="note" style={{ marginTop: "0.4rem" }}>
        <div style={{ marginBottom: 4 }}>
          License rules: <b>uses <a href={`/clients/${inherited.parentSlug}`}>{inherited.parentName}</a>&rsquo;s</b> (this client hasn&rsquo;t set its own)
          <button style={{ fontSize: 12, marginLeft: 6 }} onClick={() => { setRules(norm(inherited.rules)); setMsg(null); setOpen(true); }}>Set this client&rsquo;s own rules</button>
        </div>
        <ol style={{ margin: "0 0 0 1.1rem", padding: 0 }}>
          {norm(inherited.rules).map((r, i) => (
            <li key={i} style={{ fontSize: 12 }}>
              {r.when.trim() ? <>if <code>{r.when}</code> → </> : <b>default → </b>}
              {r.licenses.join(", ") || <span className="muted">(no license)</span>}
            </li>
          ))}
        </ol>
      </div>
    );
  }

  if (!open) {
    return (
      <div className="note" style={{ marginTop: "0.4rem" }}>
        <div style={{ marginBottom: current.length ? 4 : 0 }}>
          License rules{current.length ? ":" : ": "}
          {!current.length && <b>(none — uses the fixed license above)</b>}
          <button style={{ fontSize: 12, marginLeft: 6 }} onClick={() => { setRules(norm(current)); setMsg(null); setOpen(true); }}>Edit license rules</button>
          {canInherit && (
            <button style={{ fontSize: 12, marginLeft: 6 }} disabled={busy} title="Clear this client's own rules" onClick={useParent}>Use {canInherit}&rsquo;s rules instead</button>
          )}
        </div>
        {msg && !msg.ok && <p className="note" style={{ color: "#b91c1c", margin: "2px 0" }}>{msg.text}</p>}
        {current.length > 0 && (
          <ol style={{ margin: "0 0 0 1.1rem", padding: 0 }}>
            {norm(current).map((r, i) => (
              <li key={i} style={{ fontSize: 12 }}>
                {r.when.trim() ? <>if <code>{r.when}</code> → </> : <b>default → </b>}
                {r.licenses.join(", ") || <span className="muted">(no license)</span>}
              </li>
            ))}
          </ol>
        )}
      </div>
    );
  }

  return (
    <div style={{ border: "1px solid var(--line)", borderRadius: 8, padding: "0.7rem 0.9rem", marginTop: "0.5rem", maxWidth: 560 }}>
      <b style={{ fontSize: 14 }}>M365 license rules</b>
      <p className="note" style={{ margin: "0.2rem 0 0.6rem" }}>
        Pick the license from the new hire&rsquo;s intake. Tried top-to-bottom — <b>first match wins</b>; leave the
        condition blank for a catch-all default (put it last). An explicit license on the ticket overrides these.
      </p>
      {inherited && (
        <p className="note" style={{ margin: "0 0 0.6rem" }}>
          Starting from {inherited.parentName}&rsquo;s rules. Saving makes these this client&rsquo;s own; saving an empty list means no rules at all.
        </p>
      )}

      {rules.map((r, i) => (
        <div key={i} style={{ border: "1px solid var(--line)", borderRadius: 6, padding: "0.5rem 0.6rem", marginBottom: 8 }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 4 }}>
            <b style={{ fontSize: 12 }}>#{i + 1} {r.when.trim() ? "if" : "default (always)"}</b>
            <span className="icon-stack" style={{ flexDirection: "row" }}>
              <button className="icon-btn" title="move up" disabled={i === 0} onClick={() => move(i, -1)}>↑</button>
              <button className="icon-btn" title="move down" disabled={i === rules.length - 1} onClick={() => move(i, 1)}>↓</button>
              <button className="icon-btn" title="delete rule" style={{ color: "#b3261e" }} onClick={() => setRules((rs) => rs.filter((_, j) => j !== i))}>×</button>
            </span>
          </div>
          <ConditionBuilder value={r.when} onChange={(when) => set(i, { when })} />
          <div className="note" style={{ margin: "6px 0 2px" }}>assign:</div>
          <LicensePicker value={r.licenses} onChange={(licenses) => set(i, { licenses })} />
        </div>
      ))}

      <div className="toolbar">
        <button onClick={() => setRules((rs) => [...rs, { when: "", licenses: [] }])}>+ Add rule</button>
      </div>
      {msg && <p className="note" style={{ color: msg.ok ? "#15803d" : "#b91c1c", marginTop: 6 }}>{msg.text}</p>}
      <div className="toolbar" style={{ marginTop: 8 }}>
        <button className="primary" disabled={busy} onClick={async () => {
          setBusy(true); setMsg(null);
          try {
            const clean = rules.filter((r) => r.licenses.length > 0);
            const r = await fetch(`/api/clients/${slug}/m365-license-rules`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ rules: clean }) });
            const d = await r.json().catch(() => ({}));
            if (!r.ok) { setMsg({ ok: false, text: d.error ?? `failed (${r.status})` }); return; }
            setRules(d.rules ?? clean);
            setMsg({ ok: true, text: "✓ Saved. Re-plan this client's open cases to apply to in-flight onboardings." });
            router.refresh();
          } catch (e) { setMsg({ ok: false, text: (e as Error).message }); }
          finally { setBusy(false); }
        }}>{busy ? "Saving…" : "Save rules"}</button>
        <button disabled={busy} onClick={() => setOpen(false)}>Close</button>
        {canInherit && (
          <button disabled={busy} title="Clear this client's own rules" onClick={useParent}>Use {canInherit}&rsquo;s rules instead</button>
        )}
      </div>
    </div>
  );
}
