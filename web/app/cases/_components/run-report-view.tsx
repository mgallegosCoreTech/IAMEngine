"use client";

import React, { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { RunReport, StepVerdict } from "@/lib/cases/run-report";
import { resolveOutcomes, reopenOutcomes, dismissCaseWarnings, restoreCaseWarnings } from "@/app/runs/actions";
import { ResolutionModal } from "./resolution-modal";
import { CaseEggs } from "./case-eggs";
import { GeneratePasswordButton, RevealResetPasswordButton } from "./generate-password-button";
import { ForceSpanningSyncButton } from "./force-spanning-sync-button";
import { PASSWORD_RESET_KEY, PASSWORD_RESET_SYSTEM_KEYS } from "@/lib/jobs/password-reset";
import { ADHOC_SYSTEM_KEYS, SPANNING_FORCE_SYNC_KEY } from "@/lib/jobs/adhoc";
import { CopyButton } from "@/app/_components/copy-button";
import { parseMailboxOversize, parseMailboxNotConverted, canConvert, isDecisionMarker, parseSyncedUpnMismatch } from "@/lib/cases/decision-markers";

const VERDICT: Record<StepVerdict, { label: string; color: string }> = {
  verified: { label: "verified", color: "#15803d" },
  warning: { label: "warning", color: "#b45309" },
  failed: { label: "failed", color: "#b91c1c" },
  skipped: { label: "skipped", color: "#6b7280" },
  manual: { label: "manual", color: "#374151" },
  needs_approval: { label: "needs approval", color: "#7c3aed" },
  pending: { label: "pending", color: "#6b7280" },
  running: { label: "● running", color: "#1565c0" },
  verifying: { label: "🔎 verifying", color: "#1565c0" },
  retrying: { label: "⟳ waiting for sync", color: "#1565c0" },
};

const PRE: React.CSSProperties = {
  background: "#f6f8fa", border: "1px solid #e5e7eb", borderRadius: 4, padding: "0.6rem",
  overflowX: "auto", fontSize: 11, lineHeight: 1.45, margin: "0.25rem 0 0",
};

function Badge({ verdict }: { verdict: StepVerdict }) {
  const v = VERDICT[verdict];
  // hal-gate: egg-only hook, inert until the "hal" egg toggles body.hal-mode (case-eggs.tsx).
  return <span className={verdict === "needs_approval" ? "badge hal-gate" : "badge"} style={{ color: v.color, borderColor: v.color }}>{v.label}</span>;
}

// Procurement-case watch: shown on steps blocked on license seats (a WARN naming a Procurement
// Case). Saving a PC number starts a server-side watch (checked ~every 5 min via runner
// heartbeats); when the PC resolves in ServiceNow, the job re-queues and verifies automatically.
function ProcurementWatchRow({ step, refresh, forceShow = false }: { step: RunReport["steps"][number]; refresh: () => Promise<void> | void; forceShow?: boolean }) {
  const [num, setNum] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [editing, setEditing] = useState(false); // re-point the watch to a different PC (any state)
  const wantsWatch = step.actions.some((a) => /procurement case/i.test(a));
  if (!step.jobId || (!step.procurement && !wantsWatch && !forceShow)) return null;

  // POST upserts the watch — same call to SET or RE-POINT (it resets state to "watching" + clears the
  // note/last-check). Used by the initial "Watch" form and the "Watch a different case" editor.
  async function save(number: string) {
    setBusy(true); setErr(null);
    try {
      const r = await fetch(`/api/jobs/${step.jobId}/procurement`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ number }) });
      if (!r.ok) { setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? "failed"); return; }
      setNum(""); setEditing(false);
      await refresh();
    } catch (e) { setErr((e as Error).message); }
    finally { setBusy(false); }
  }

  // Inline editor to point the watch at a DIFFERENT procurement case — shown in any state (e.g. the
  // first PC resolved but someone grabbed the seat first, so you re-watch a new PC).
  const editor = (
    <span style={{ marginLeft: 8, display: "inline-flex", gap: 6, alignItems: "center" }}>
      <input value={num} onChange={(e) => setNum(e.target.value)} placeholder="PC0012345" style={{ width: 110, fontSize: 12 }} autoFocus />
      <button style={{ fontSize: 11 }} disabled={busy || !num.trim()} onClick={() => save(num)}>{busy ? "…" : "Save"}</button>
      <button style={{ fontSize: 11 }} disabled={busy} onClick={() => { setEditing(false); setNum(""); setErr(null); }}>Cancel</button>
    </span>
  );

  if (step.procurement) {
    const p = step.procurement;
    const when = p.lastCheckedAt ? new Date(p.lastCheckedAt).toLocaleTimeString() : "not yet";
    // The sweep re-checks a watch ~5 minutes after its last check (heartbeat-driven, so up to a
    // minute of jitter). The watch lives SERVER-SIDE — closing this page doesn't stop it.
    const next = p.lastCheckedAt ? `~${new Date(new Date(p.lastCheckedAt).getTime() + 5 * 60_000).toLocaleTimeString()}` : "within a minute";
    const color = p.state === "watching" ? "#8a6d00" : p.state === "resolved" ? "#15803d" : "#b91c1c";
    return (
      <div className="note" style={{ marginTop: 4 }} suppressHydrationWarning>
        <span style={{ color }}>
          {p.state === "watching" && `⏳ Watching procurement case ${p.number} — last checked ${when}${p.note ? ` (SN state: ${p.note})` : ""} · next check ${next}. Watched server-side (safe to close this page); on resolve the step re-runs and verifies automatically.`}
          {p.state === "resolved" && `✓ Procurement case ${p.number} resolved — the step was re-queued automatically.`}
          {p.state === "cancelled" && `✗ Procurement case ${p.number} was cancelled — license not procured, the step was NOT re-run.`}
          {p.state === "error" && `Procurement case ${p.number}: ${p.note ?? "error"}`}
        </span>
        {p.state === "watching" && !editing && (
          <>
            <button style={{ marginLeft: 8, fontSize: 11 }} disabled={busy} title="Check the PC's state in ServiceNow right now instead of waiting for the next 5-minute sweep"
              onClick={async () => {
                setBusy(true); setErr(null);
                try {
                  const r = await fetch(`/api/jobs/${step.jobId}/procurement/check`, { method: "POST" });
                  if (!r.ok) setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? "check failed");
                  await refresh();
                } catch (e) { setErr((e as Error).message); }
                finally { setBusy(false); }
              }}>
              {busy ? "…" : "Check now"}
            </button>
            <button style={{ marginLeft: 6, fontSize: 11 }} disabled={busy}
              onClick={async () => {
                setBusy(true);
                try { await fetch(`/api/jobs/${step.jobId}/procurement`, { method: "DELETE" }); await refresh(); }
                catch { /* network blip — button stays usable for a retry */ }
                finally { setBusy(false); }
              }}>
              Stop watching
            </button>
          </>
        )}
        {/* Re-point to a different case — available in EVERY state. Crucial when the watched PC resolved
            but the seat was taken first, so you need to watch a new procurement case. */}
        {!editing && (
          <button style={{ marginLeft: 6, fontSize: 11 }} disabled={busy}
            title="Point this watch at a different procurement case (e.g. the first one resolved but the license was assigned elsewhere)"
            onClick={() => { setEditing(true); setNum(""); setErr(null); }}>
            Watch a different case
          </button>
        )}
        {editing && editor}
        {err && <span style={{ marginLeft: 6, color: "#b91c1c" }}>{err}</span>}
      </div>
    );
  }
  return (
    <div className="note" style={{ marginTop: 4, display: "flex", gap: 6, alignItems: "center", flexWrap: "wrap" }}>
      <span>Procurement case:</span>
      <input value={num} onChange={(e) => setNum(e.target.value)} placeholder="PC0012345" style={{ width: 110, fontSize: 12 }} />
      <button disabled={busy || !num.trim()} style={{ fontSize: 11 }} onClick={() => save(num)}>
        {busy ? "…" : "Watch"}
      </button>
      <span className="muted" style={{ fontSize: 11 }}>checked every ~5 min — on resolve, this step re-runs + verifies automatically</span>
      {err && <span style={{ color: "#b91c1c" }}>{err}</span>}
    </div>
  );
}

// License picker — shown on an m365 step when an assignment failed for no seats. Lists the tenant's
// owned SKUs + free seat counts (multi-select); assigning writes the choice into the step config and
// re-runs it. A pick with 0 free seats is allowed but warned (it'll fall back to a Procurement Case).
function LicensePicker({ jobId, options, refresh, onWait, waiting }: { jobId: string; options: NonNullable<RunReport["steps"][number]["licenseOptions"]>; refresh: () => Promise<void> | void; onWait: () => void; waiting: boolean }) {
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [collapsed, setCollapsed] = useState(waiting);
  const chosen = options.filter((o) => sel.has(o.skuId));
  const noSeatPick = chosen.some((o) => o.available <= 0);

  // "I'll wait" — collapse the picker (so the failed step isn't cluttered) but keep it re-openable,
  // and reveal the procurement-case watcher so they can track the order. Choosing a license later
  // still works.
  if (collapsed) {
    return (
      <div className="note" style={{ marginTop: 4, color: "#8a6d00" }}>
        ⏳ Waiting on a license — order it and watch the procurement case below.{" "}
        <button style={{ fontSize: 12, marginLeft: 4 }} onClick={() => setCollapsed(false)}>Pick a license instead</button>
      </div>
    );
  }

  return (
    <div className="note" style={{ marginTop: 4, border: "1px solid #fde68a", background: "#fffbeb", borderRadius: 8, padding: "0.5rem 0.65rem" }}>
      <div style={{ fontWeight: 600, color: "#92400e" }}>No seats for the requested license — assign a different one, or wait for procurement:</div>
      <div style={{ display: "flex", flexDirection: "column", gap: 2, margin: "0.4rem 0" }}>
        {options.map((o) => (
          <label key={o.skuId} style={{ display: "flex", alignItems: "center", gap: 6, margin: 0, color: "var(--fg)", fontSize: 12 }}>
            <input type="checkbox" style={{ width: "auto" }} checked={sel.has(o.skuId)}
              onChange={(e) => setSel((s) => { const n = new Set(s); if (e.target.checked) n.add(o.skuId); else n.delete(o.skuId); return n; })} />
            <span>{o.name} <span className="muted">({o.skuPartNumber})</span></span>
            <span style={{ marginLeft: "auto", color: o.available > 0 ? "#15803d" : "#b91c1c", fontWeight: 600 }}>
              {o.available > 0 ? `${o.available} free` : "0 free"}
            </span>
            <span className="muted" style={{ width: 70, textAlign: "right" }}>{o.consumed}/{o.enabled} used</span>
          </label>
        ))}
      </div>
      {noSeatPick && <div style={{ color: "#92400e" }}>⚠ A selected license also has 0 free seats — it&rsquo;ll re-warn and you can open a Procurement Case to order it.</div>}
      {err && <div style={{ color: "#b91c1c" }}>{err}</div>}
      <div className="toolbar" style={{ marginTop: 4 }}>
        <button className="primary" style={{ fontSize: 12 }} disabled={busy || chosen.length === 0}
          onClick={async () => {
            setBusy(true); setErr(null);
            try {
              const r = await fetch(`/api/jobs/${jobId}/license`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ licenses: chosen.map((o) => ({ name: o.skuPartNumber, skuId: o.skuId })) }) });
              if (!r.ok) { setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? "failed"); return; }
              await refresh();
            } catch (e) { setErr((e as Error).message); }
            finally { setBusy(false); }
          }}>
          {busy ? "Assigning…" : `Assign ${chosen.length || ""} & re-run`}
        </button>
        <button style={{ fontSize: 12 }} disabled={busy} onClick={() => { setCollapsed(true); onWait(); }} title="Don't assign now — order the license and watch its procurement case">
          I&rsquo;ll wait
        </button>
      </div>
    </div>
  );
}

// Some license service plans couldn't be enabled because a hard prerequisite was missing (e.g.
// Defender for Office 365 P2 needs an Exchange Online plan). The base license DID land — these plans
// are just off. Once the operator supplies the prerequisite (assign the base license / free a seat),
// "Retry license assignment" re-runs the step; the runner re-enables any plan whose prerequisite now
// exists. Mirrors LicensePicker: self-contained, re-uses the same in-place job re-run.
function LicenseRecoveryBox({ jobId, issues, refresh }: { jobId: string; issues: NonNullable<RunReport["steps"][number]["licenseIssues"]>; refresh: () => Promise<void> | void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  return (
    <div className="note" style={{ marginTop: 4, border: "1px solid #fde68a", background: "#fffbeb", borderRadius: 8, padding: "0.5rem 0.65rem" }}>
      <div style={{ fontWeight: 600, color: "#92400e" }}>
        Some licenses couldn&rsquo;t be fully assigned — {issues.length} service plan{issues.length > 1 ? "s were" : " was"} held back
      </div>
      <ul style={{ margin: "0.4rem 0", paddingLeft: "1.1rem", color: "var(--fg)", fontSize: 12 }}>
        {issues.map((iss, i) => (
          <li key={i} style={{ marginBottom: 2 }}>
            <strong>{iss.plan}</strong>{iss.sku ? <span className="muted"> (in {iss.sku})</span> : null} is <strong>off</strong>
            {iss.requires.length ? <> — needs {iss.requires.join(" or ")}</> : null}
          </li>
        ))}
      </ul>
      <div className="muted" style={{ fontSize: 12, marginBottom: 4 }}>
        The account and the rest of the license were assigned. Add/enable a prerequisite license (or free a seat for one), then retry — the plan turns on once its prerequisite exists.
      </div>
      {err && <div style={{ color: "#b91c1c" }}>{err}</div>}
      <div className="toolbar" style={{ marginTop: 4 }}>
        <button className="primary" style={{ fontSize: 12 }} disabled={busy}
          onClick={async () => {
            setBusy(true); setErr(null);
            try {
              const r = await fetch(`/api/jobs/${jobId}/rerun`, { method: "POST" });
              if (!r.ok) { setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? "failed"); return; }
              await refresh();
            } catch (e) { setErr((e as Error).message); }
            finally { setBusy(false); }
          }}>
          {busy ? "Retrying…" : "Retry license assignment"}
        </button>
      </div>
    </div>
  );
}

// The executor could not tell WHICH person to offboard — the ticket's name matched several people, or
// nobody. Rather than guess (offboarding the wrong person is not undoable) it returns the shortlist it
// found and stops. The operator picks; the pick goes on the CASE payload, so every system resolves the
// same person, and the whole case re-runs from the top so no step is missed.
function OffboardTargetPicker({ caseId, data, refresh }: { caseId: string; data: NonNullable<RunReport["steps"][number]["offboardCandidates"]>; refresh: () => Promise<void> | void }) {
  const [sel, setSel] = useState<string | null>(null);
  const [manual, setManual] = useState("");
  const [showManual, setShowManual] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const picked = data.candidates.find((c) => c.upn === sel) ?? null;
  const upn = showManual ? manual.trim() : (picked?.upn ?? "");
  const headline = data.reason === "no-match"
    ? <>No exact match for <b>{data.query ?? "the name on the ticket"}</b> — pick the person to offboard:</>
    : <>Several users match <b>{data.query ?? "the name on the ticket"}</b> — pick the person to offboard:</>;

  return (
    <div className="note" style={{ marginTop: 4, border: "1px solid #fecaca", background: "#fef2f2", borderRadius: 8, padding: "0.5rem 0.65rem" }}>
      <div style={{ fontWeight: 600, color: "#991b1b" }}>{headline}</div>
      <div className="muted" style={{ fontSize: 12, marginTop: 2 }}>Nothing has been changed. The whole case re-runs against whoever you pick.</div>
      <div style={{ display: "flex", flexDirection: "column", gap: 2, margin: "0.4rem 0" }}>
        {data.candidates.map((c) => (
          <label key={c.id} style={{ display: "flex", alignItems: "center", gap: 6, margin: 0, color: "var(--fg)", fontSize: 12 }}>
            <input type="radio" name={`offboard-target-${caseId}`} style={{ width: "auto" }}
              checked={!showManual && sel === c.upn}
              onChange={() => { setShowManual(false); setSel(c.upn); }} />
            <span style={{ fontWeight: 600 }}>{c.displayName}</span>
            <span className="muted">{c.upn}</span>
            {c.jobTitle && <span className="muted">· {c.jobTitle}</span>}
            {c.department && <span className="muted">· {c.department}</span>}
            <span style={{ marginLeft: "auto", color: c.enabled === false ? "#b91c1c" : "#15803d", fontWeight: 600 }}>
              {c.enabled === false ? "disabled" : "enabled"}
            </span>
          </label>
        ))}
        <label style={{ display: "flex", alignItems: "center", gap: 6, margin: 0, color: "var(--fg)", fontSize: 12 }}>
          <input type="radio" name={`offboard-target-${caseId}`} style={{ width: "auto" }} checked={showManual} onChange={() => { setShowManual(true); setSel(null); }} />
          <span>None of these —</span>
          <input type="text" placeholder="enter their UPN / email" value={manual} disabled={!showManual}
            onChange={(e) => setManual(e.target.value)} style={{ fontSize: 12, padding: "1px 4px", width: 220 }} />
        </label>
      </div>
      {err && <div style={{ color: "#b91c1c" }}>{err}</div>}
      <div className="toolbar" style={{ marginTop: 4 }}>
        <button className="primary" style={{ fontSize: 12 }} disabled={busy || !upn}
          onClick={async () => {
            setBusy(true); setErr(null);
            try {
              const r = await fetch(`/api/cases/${caseId}/offboard-target`, {
                method: "POST", headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ upn, displayName: picked?.displayName, samAccountName: picked?.samAccountName, mail: picked?.mail }),
              });
              if (!r.ok) { setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? "failed"); return; }
              await refresh();
            } catch (e) { setErr((e as Error).message); }
            finally { setBusy(false); }
          }}>
          {busy ? "Starting…" : "Offboard this user & re-run case"}
        </button>
      </div>
    </div>
  );
}

// A mailbox over the cap cannot become shared — past that size it needs a licence either way — so
// reclaiming the seat and keeping the mail genuinely conflict, and neither is a safe default. The
// runner asks instead of choosing, and this is the ask.
//
// Unlike CollisionDecision this reads the marker out of the step's ACTIONS, not its error, because
// the step SUCCEEDED: sign-in is blocked, sessions revoked, groups removed. Only the licence is
// unresolved. Failing the step to force a decision would throw away the record of the containment
// that already happened — and the containment is the part that must not wait for anyone.
function MailboxOversizeDecision({ caseId, jobId, actions, refresh }: { caseId: string; jobId: string; actions: string[]; refresh: () => Promise<void> | void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  // Parsed by lib/cases/decision-markers, whose test pins the runner's exact emitted string — the
  // only thing binding these two sides together.
  const decision = parseMailboxOversize(actions);
  if (!decision) return null;
  const msg = decision.message;
  const size = decision.sizeGB;
  async function decide(policy: "remove" | "keep") {
    setBusy(policy); setErr(null);
    try {
      const r = await fetch(`/api/cases/${caseId}/m365-override`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ mailboxOversizePolicy: policy }) });
      if (!r.ok) { setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? "failed"); return; }
      // The answer is recorded but nothing runs until this re-queue lands, so its refusal (409: the job
      // isn't in a finished state) has to surface. Unchecked, it read as a clean success with no re-run
      // queued — the operator walks away and the decision silently sits there.
      const rr = await fetch(`/api/jobs/${jobId}/rerun`, { method: "POST" });
      if (!rr.ok) {
        setErr(`Choice saved, but the re-run didn't start: ${((await rr.json().catch(() => ({}))) as { error?: string }).error ?? rr.status}. Use Re-run on this step.`);
        return;
      }
      await refresh();
    } catch (e) { setErr((e as Error).message); }
    finally { setBusy(null); }
  }
  return (
    <div style={{ border: "1px solid #fde68a", background: "#fffbeb", borderRadius: 8, padding: "0.6rem 0.8rem", marginTop: 6 }}>
      <div style={{ fontSize: 13, color: "#92400e" }}><b>Decision needed</b>{size ? <> — mailbox is <b>{size} GB</b></> : null}. {msg}</div>
      {/* Why there is no "Convert to shared" button here, said plainly next to the choices — the
          under-cap picker offers convert, so its absence needs a reason. Without it the two buttons
          read as the whole menu and nobody knows the size is what took the third option away. */}
      <p className="note" style={{ marginTop: 4, color: "#92400e" }}>
        Converting to a shared mailbox isn&apos;t an option: at {size ? <b>{size} GB</b> : "its size"} it&apos;s over the {decision.thresholdGB} GB cap, and a mailbox that large needs a licence either way.
      </p>
      <div className="toolbar" style={{ marginTop: 8 }}>
        {/* Neither is "primary": one costs money, the other destroys mail. Presenting a recommended
            button would be making the client's call for them, which is the thing we stopped doing. */}
        <button disabled={!!busy} onClick={() => decide("keep")}>{busy === "keep" ? "…" : "Keep the licence — retain the mail"}</button>
        <button disabled={!!busy} onClick={() => decide("remove")}>{busy === "remove" ? "…" : "Remove the licence — the mail will be lost"}</button>
      </div>
      {err && <p className="note danger" style={{ marginTop: 4 }}>{err}</p>}
    </div>
  );
}

// The mailbox is UNDER the cap and nothing converted it. Unlike the oversize decision, converting is a
// real answer here — so this offers three, and posts to ONE endpoint that owns the whole thing: the
// convert answer has to re-queue exchange BEFORE the licence step or a runner claims the licence step
// against the stale exchange result and just asks again. That ordering does not belong in a browser.
function MailboxNotConvertedDecision({ caseId, actions, refresh }: { caseId: string; actions: string[]; refresh: () => Promise<void> | void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  // Arming the destructive answer rather than window.confirm: it keeps the consequence on screen next
  // to the button instead of in a modal that reads as chrome to click past.
  const [armed, setArmed] = useState(false);
  const decision = parseMailboxNotConverted(actions);
  if (!decision) return null;
  const size = decision.sizeGB;
  // Exchange refuses to convert a mailbox whose size it could not read (it cannot prove it is under
  // the cap), so offering Convert there would be a button guaranteed to fail.
  const convertible = canConvert(decision);

  async function decide(policy: "convert" | "remove" | "keep") {
    setBusy(policy); setErr(null);
    try {
      const r = await fetch(`/api/cases/${caseId}/mailbox-decision`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ policy }),
      });
      // Checked, unlike the oversize picker's fire-and-forget re-run: a refusal here (nothing to record
      // the answer on, no exchange step to convert with) must not read as a success with nothing queued.
      if (!r.ok) { setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? `failed (${r.status})`); return; }
      await refresh();
    } catch (e) { setErr((e as Error).message); }
    finally { setBusy(null); setArmed(false); }
  }

  return (
    <div style={{ border: "1px solid #fde68a", background: "#fffbeb", borderRadius: 8, padding: "0.6rem 0.8rem", marginTop: 6 }}>
      <div style={{ fontSize: 13, color: "#92400e" }}>
        <b>Decision needed</b>{size && size !== "unknown" ? <> — mailbox is <b>{size} GB</b></> : null}. {decision.message}
      </div>
      <div className="toolbar" style={{ marginTop: 8 }}>
        {/* Same restraint as the oversize picker: no "primary". One costs money and one destroys mail,
            and styling a recommendation would be making the client's call for them. */}
        {convertible && (
          <button disabled={!!busy} onClick={() => decide("convert")}>
            {busy === "convert" ? "…" : "Convert to shared, then remove the licence"}
          </button>
        )}
        {!armed ? (
          <button disabled={!!busy} onClick={() => { setArmed(true); setErr(null); }}>Remove the licence — the mailbox will be deleted</button>
        ) : (
          <button disabled={!!busy} onClick={() => decide("remove")} style={{ borderColor: "#b91c1c", color: "#b91c1c" }}>
            {busy === "remove" ? "…" : "Confirm: remove it — the mail is unrecoverable after 30 days"}
          </button>
        )}
        <button disabled={!!busy} onClick={() => decide("keep")}>{busy === "keep" ? "…" : "Leave the licence and the mailbox"}</button>
        {armed && <button disabled={!!busy} onClick={() => setArmed(false)}>Cancel</button>}
      </div>
      {!convertible && (
        <p className="note" style={{ marginTop: 4, color: "#92400e" }}>
          Converting isn&apos;t offered: the mailbox size couldn&apos;t be read, so Exchange can&apos;t prove it is under the {decision.thresholdGB} GB cap and will refuse. Re-run the Exchange step first if the mail matters.
        </p>
      )}
      {err && <p className="note danger" style={{ marginTop: 4 }}>{err}</p>}
    </div>
  );
}

// The follow-up to a one-off Convert: this case is fixed, but the CLIENT still has no conversion
// configured, so the next offboard parks on the same warning. Self-gating on the server's answer —
// which is derived, not stored, so there is no dismissal state and nothing to migrate.
function ExchangeConvertDefaultOffer({ caseId, systemKey }: { caseId: string; systemKey: string }) {
  const [state, setState] = useState<{ offer: boolean; clientName: string | null } | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const isExchange = systemKey === "exchange";
  useEffect(() => {
    if (!isExchange) return;
    let alive = true;
    fetch(`/api/cases/${caseId}/exchange-convert-default`, { cache: "no-store" })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => { if (alive && d) setState({ offer: Boolean(d.offer), clientName: d.clientName ?? null }); })
      .catch(() => { /* the offer is a nicety — never surface its fetch as a case error */ });
    return () => { alive = false; };
  }, [caseId, isExchange]);
  if (!isExchange || !state?.offer) return null;
  if (done) return <p className="note" style={{ marginTop: 6, color: "#15803d" }}>✓ Convert-to-shared is now the default for future offboards.</p>;

  async function apply() {
    setBusy(true); setErr(null);
    try {
      const r = await fetch(`/api/cases/${caseId}/exchange-convert-default`, { method: "POST" });
      if (!r.ok) { setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? `failed (${r.status})`); return; }
      setDone(true);
    } catch (e) { setErr((e as Error).message); }
    finally { setBusy(false); }
  }
  return (
    <div style={{ border: "1px solid #bfdbfe", background: "#eff6ff", borderRadius: 8, padding: "0.6rem 0.8rem", marginTop: 6 }}>
      <div style={{ fontSize: 13, color: "#1e40af" }}>
        This case converted the mailbox as a one-off. {state.clientName ?? "This client"} has no convert-to-shared configured, so the next offboard will stop on the same warning.
      </div>
      <div className="toolbar" style={{ marginTop: 8 }}>
        <button disabled={busy} onClick={apply}>{busy ? "…" : "Convert to shared by default from now on"}</button>
      </div>
      {err && <p className="note danger" style={{ marginTop: 4 }}>{err}</p>}
    </div>
  );
}

// When the runner can't tell a re-run from a same-name stranger, it pauses the step with a
// DECISION_NEEDED error. The operator decides here: Adopt (it's this person — a re-run) writes
// the choice to the m365 job and re-runs; Different person uses a new username (a fallback).
function CollisionDecision({ caseId, jobId, error, refresh }: { caseId: string; jobId: string; error: string; refresh: () => Promise<void> | void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const m = /DECISION_NEEDED:username_collision \| ([^|]+?) \| upn=([^|]+?) \| name=(.+)$/.exec(error);
  const msg = m?.[1]?.trim() ?? "An account with the same name already exists — is this a re-run of the same person, or a different person?";
  const upn = m?.[2]?.trim();
  async function decide(policy: "adopt" | "new") {
    setBusy(policy); setErr(null);
    try {
      const r = await fetch(`/api/cases/${caseId}/m365-override`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ usernameCollisionPolicy: policy }) });
      if (!r.ok) { setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? "failed"); return; }
      await fetch(`/api/jobs/${jobId}/rerun`, { method: "POST" });
      await refresh();
    } catch (e) { setErr((e as Error).message); }
    finally { setBusy(null); }
  }
  return (
    <div style={{ border: "1px solid #fde68a", background: "#fffbeb", borderRadius: 8, padding: "0.6rem 0.8rem", marginTop: 6 }}>
      <div style={{ fontSize: 13, color: "#92400e" }}><b>Decision needed</b> — {msg}{upn ? <> (<code>{upn}</code>)</> : null}</div>
      <div className="toolbar" style={{ marginTop: 8 }}>
        <button className="primary" disabled={!!busy} onClick={() => decide("adopt")}>{busy === "adopt" ? "Adopting…" : "Adopt — it's this person (re-run)"}</button>
        <button disabled={!!busy} onClick={() => decide("new")}>{busy === "new" ? "…" : "Different person — use a new username"}</button>
      </div>
      {err && <p className="note danger" style={{ marginTop: 4 }}>{err}</p>}
    </div>
  );
}

// AD-synced client: the runner found a synced account under a different UPN (or none) and refused to
// create a cloud duplicate. The operator either fixes the on-prem AD email and re-syncs (then re-runs),
// or — if this hire legitimately needs a cloud-created account — allows creation for this case.
function SyncedMismatchDecision({ caseId, jobId, error, refresh }: { caseId: string; jobId: string; error: string; refresh: () => Promise<void> | void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const d = parseSyncedUpnMismatch(error);
  if (!d) return null;
  async function allowCreate() {
    setBusy(true); setErr(null);
    try {
      const r = await fetch(`/api/cases/${caseId}/m365-override`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ allowCloudCreate: true }) });
      if (!r.ok) { setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? "failed"); return; }
      await fetch(`/api/jobs/${jobId}/rerun`, { method: "POST" });
      await refresh();
    } catch (e) { setErr((e as Error).message); }
    finally { setBusy(false); }
  }
  return (
    <div style={{ border: "1px solid #fde68a", background: "#fffbeb", borderRadius: 8, padding: "0.6rem 0.8rem", marginTop: 6 }}>
      <div style={{ fontSize: 13, color: "#92400e" }}>
        <b>Decision needed</b> — this AD-synced client&apos;s account should come from on-prem AD, so nothing was created in the cloud.
        {d.found ? <> A synced account for <b>{d.name}</b> exists at <code>{d.found}</code> but onboarding expected <code>{d.expected}</code>.</> : null}
      </div>
      <div className="note" style={{ marginTop: 4 }}>Fix the on-prem AD email/UPN and re-sync (then re-run this step), or allow a cloud account for this case:</div>
      <div className="toolbar" style={{ marginTop: 8 }}>
        <button className="primary" disabled={busy} onClick={allowCreate}>{busy ? "Allowing…" : "Allow cloud account for this case & re-run"}</button>
      </div>
      {err && <p className="note danger" style={{ marginTop: 4 }}>{err}</p>}
    </div>
  );
}

// Dry-run review: the resolved fields that will be set (editable), plus the groups (with type) and
// licenses the plan will apply. Editing a field PATCHes the case payload (read by the runner at
// claim time) — so an operator can correct anything before/while it runs.
function ReviewPanel({ caseId, review, refresh }: { caseId: string; review: NonNullable<RunReport["review"]>; refresh: () => Promise<void> | void }) {
  const [open, setOpen] = useState(false);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [lic, setLic] = useState(review.licenses.join(", "));
  const [fbk, setFbk] = useState(review.fallbacks.join(", "));
  const [extraGroups, setExtraGroups] = useState(review.extraGroups);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const dirty = Object.keys(edits).length > 0 || lic !== review.licenses.join(", ") || fbk !== review.fallbacks.join(", ") || extraGroups !== review.extraGroups;
  const SRC: Record<string, { label: string; color: string }> = { ai: { label: "AI", color: "#1e40af" }, operator: { label: "edited", color: "#15803d" }, derived: { label: "", color: "" } };

  return (
    <details open={open} onToggle={(e) => setOpen((e.target as HTMLDetailsElement).open)} style={{ margin: "0 0 0.5rem", border: "1px solid var(--line)", borderRadius: 8, padding: "0.5rem 0.75rem" }}>
      <summary style={{ cursor: "pointer", fontWeight: 600, fontSize: 14 }}>Fields to be set (dry run) — review &amp; edit</summary>
      <div style={{ display: "grid", gridTemplateColumns: "160px 1fr", gap: "0.3rem 0.6rem", alignItems: "center", margin: "0.6rem 0" }}>
        {review.fields.map((f) => (
          <React.Fragment key={f.key}>
            <label style={{ margin: 0, fontSize: 12, color: "var(--muted)" }}>
              {f.label}{f.source !== "derived" && SRC[f.source]?.label && <span className="badge" style={{ marginLeft: 5, fontSize: 9, color: SRC[f.source]?.color }}>{SRC[f.source]?.label}</span>}
            </label>
            <input value={edits[f.key] ?? f.value} onChange={(e) => setEdits((s) => ({ ...s, [f.key]: e.target.value }))} style={{ fontSize: 13, maxWidth: 360 }} />
          </React.Fragment>
        ))}
      </div>
      {/* M365 overrides — editable for THIS case in case the imported defaults are wrong. */}
      <div style={{ borderTop: "1px solid var(--line)", paddingTop: "0.5rem", marginTop: "0.3rem" }}>
        <div style={{ display: "grid", gridTemplateColumns: "160px 1fr", gap: "0.3rem 0.6rem", alignItems: "center" }}>
          <label style={{ margin: 0, fontSize: 12, color: "var(--muted)" }}>License(s)</label>
          <input value={lic} onChange={(e) => setLic(e.target.value)} placeholder="comma-separated, e.g. Microsoft 365 Business Premium" style={{ fontSize: 13, maxWidth: 420 }} />
          <label style={{ margin: 0, fontSize: 12, color: "var(--muted)" }}>Fallback username(s)</label>
          <input value={fbk} onChange={(e) => setFbk(e.target.value)} placeholder="comma-separated UPNs used if the primary is taken" style={{ fontSize: 13, maxWidth: 420 }} />
        </div>
        {review.groups.length > 0 && <div className="note" style={{ marginTop: 4 }}>Groups: {review.groups.map((g) => `${g.name}${g.type ? ` (${g.type})` : ""}`).join(", ")} <span className="muted">— type confirmed at run time; edit on the client page</span></div>}
        <div style={{ display: "grid", gridTemplateColumns: "160px 1fr", gap: "0.3rem 0.6rem", alignItems: "center", marginTop: 4 }}>
          <label style={{ margin: 0, fontSize: 12, color: "var(--muted)" }}>Additional groups (comma-separated)</label>
          <input value={extraGroups} onChange={(e) => setExtraGroups(e.target.value)} placeholder="e.g. GIS Users, Finance Share" style={{ fontSize: 13, maxWidth: 420 }} />
        </div>
      </div>
      {msg && <p className="note" style={{ color: "#15803d" }}>{msg}</p>}
      <button className="primary" disabled={busy || !dirty} style={{ fontSize: 12 }} onClick={async () => {
        setBusy(true); setMsg(null);
        try {
          // Generic field edits (incl. extraGroups) -> /fields; m365 license/UPN/fallback -> /m365-override.
          const extraGroupsChanged = extraGroups !== review.extraGroups;
          const fieldEdits = extraGroupsChanged ? { ...edits, extraGroups } : edits;
          if (Object.keys(fieldEdits).length) {
            const r = await fetch(`/api/cases/${caseId}/fields`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ fields: fieldEdits }) });
            if (!r.ok) { setMsg(((await r.json().catch(() => ({}))) as { error?: string }).error ?? "failed"); return; }
          }
          const licArr = lic.split(",").map((s) => s.trim()).filter(Boolean);
          const fbArr = fbk.split(",").map((s) => s.trim()).filter(Boolean);
          const licChanged = JSON.stringify(licArr) !== JSON.stringify(review.licenses);
          const fbChanged = JSON.stringify(fbArr) !== JSON.stringify(review.fallbacks);
          const upn = edits.userPrincipalName;
          if (licChanged || fbChanged) {
            const r = await fetch(`/api/cases/${caseId}/m365-override`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...(licChanged ? { licenses: licArr } : {}), ...(fbChanged ? { fallbacks: fbArr } : {}), ...(upn ? { userPrincipalName: upn } : {}) }) });
            if (!r.ok) { setMsg(((await r.json().catch(() => ({}))) as { error?: string }).error ?? "failed"); return; }
          }
          // Additional groups only take effect on (re-)plan — re-plan immediately so they land on
          // the AD/cloud step config right away instead of waiting for someone to notice and re-plan
          // manually (same endpoint the Re-plan button uses).
          let saveMsg = "✓ Saved — applies on the next run/claim.";
          if (extraGroupsChanged) {
            const r = await fetch(`/api/cases/${caseId}/replan`, { method: "POST" });
            const d = (await r.json().catch(() => ({}))) as { error?: string; mode?: string; kept?: number; added?: number; rerun?: number };
            if (!r.ok) { setMsg(d.error ?? "saved, but re-plan failed"); return; }
            saveMsg = d.mode === "incremental"
              ? `✓ Saved — re-plan kept ${d.kept} step${d.kept === 1 ? "" : "s"}, added ${d.added} new${d.rerun ? `, re-running ${d.rerun}` : ""}.`
              : "✓ Saved — re-plan complete.";
          }
          setEdits({}); setMsg(saveMsg);
          await refresh();
        } catch (e) { setMsg((e as Error).message); }
        finally { setBusy(false); }
      }}>{busy ? "Saving…" : "Save edits"}</button>
    </details>
  );
}

// Offboard mailbox delegates (FR #0000211): who gets Full Access to the leaver's mailbox, and whether
// that also adds it to their Outlook (AutoMapping). The client sets the default; this case can differ
// until the Exchange step starts, when the access is granted and the choice is fixed.
function DelegationPanel({ caseId, d, refresh }: { caseId: string; d: NonNullable<RunReport["delegation"]>; refresh: () => Promise<void> | void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const who = [...(d.manager ? ["the leaver's manager"] : []), ...d.delegates].join(", ");
  const onOff = (v: boolean) => (v ? "on" : "off");
  const value = d.override === null ? "default" : d.override ? "on" : "off";
  return (
    <div className="note" style={{ margin: "0 0 0.6rem", padding: "0.55rem 0.75rem", borderRadius: 8, border: "1px solid var(--line)" }}>
      <div><b>Mailbox delegates</b> (Full Access to the leaver&rsquo;s mailbox): {who}</div>
      <div style={{ display: "flex", gap: 8, alignItems: "center", marginTop: 4, flexWrap: "wrap" }}>
        <label style={{ margin: 0 }} htmlFor={`automap-${caseId}`}>Add it to their Outlook automatically (AutoMapping):</label>
        <select id={`automap-${caseId}`} value={value} disabled={busy || d.locked} style={{ fontSize: 12 }} onChange={async (e) => {
          const v = e.target.value;
          setBusy(true); setErr(null);
          try {
            const r = await fetch(`/api/cases/${caseId}/delegate-automapping`, {
              method: "PATCH", headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ autoMapping: v === "default" ? null : v === "on" }),
            });
            if (!r.ok) { setErr(((await r.json().catch(() => ({}))) as { error?: string }).error ?? `failed (${r.status})`); return; }
            await refresh();
          } catch (ex) { setErr((ex as Error).message); }
          finally { setBusy(false); }
        }}>
          <option value="default">Client default{d.clientDefault === undefined ? "" : ` (${onOff(d.clientDefault)})`}</option>
          <option value="on">On for this case</option>
          <option value="off">Off for this case: access only</option>
        </select>
        {d.locked && <span className="muted">The Exchange step has started, so this was decided when it ran (AutoMapping {onOff(d.autoMapping)}).</span>}
      </div>
      {err && <div style={{ color: "#b91c1c", marginTop: 4 }}>{err}</div>}
    </div>
  );
}

// "Needs Information": the intake left fields it couldn't determine. When held, the case is paused
// until they're filled in; saving releases it so it can run.
function NeedsInfoPanel({ caseId, info, refresh }: { caseId: string; info: NonNullable<RunReport["needsInfo"]>; refresh: () => Promise<void> | void }) {
  const [vals, setVals] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  return (
    <div style={{ margin: "0 0 0.6rem", padding: "0.7rem 0.85rem", borderRadius: 8, border: "1px solid #fcd34d", background: "#fffbeb" }}>
      <div style={{ fontWeight: 600, color: "#92400e" }}>
        {info.held ? "⏸ Needs information — case is held until these are filled in" : "Some fields couldn't be determined automatically"}
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 8, margin: "0.55rem 0" }}>
        {info.fields.map((f) => (
          <div key={f.field}>
            <label style={{ margin: 0, fontWeight: 500, color: "var(--fg)", fontSize: 13 }}>{f.label}</label>
            <div className="note" style={{ margin: "1px 0 3px" }}>{f.note}</div>
            <input value={vals[f.field] ?? ""} onChange={(e) => setVals((v) => ({ ...v, [f.field]: e.target.value }))} placeholder={f.field} style={{ maxWidth: 280, fontSize: 13 }} />
          </div>
        ))}
      </div>
      {err && <div className="note" style={{ color: "#b91c1c" }}>{err}</div>}
      <button className="primary" disabled={busy || info.fields.every((f) => !(vals[f.field] ?? "").trim())} onClick={async () => {
        setBusy(true); setErr(null);
        try {
          const r = await fetch(`/api/cases/${caseId}/fields`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ fields: vals }) });
          const d = await r.json().catch(() => ({}));
          if (!r.ok) { setErr(d.error ?? `failed (${r.status})`); return; }
          await refresh();
        } catch (e) { setErr((e as Error).message); }
        finally { setBusy(false); }
      }}>{busy ? "Saving…" : "Save & continue"}</button>
    </div>
  );
}

// One-click copy for error text — pasting a step's full error into chat/tickets shouldn't require
// careful drag-selecting inside a scrollable <pre>. The local implementation this replaces did
// `navigator.clipboard?.writeText(text); setCopied(true);` — which on a plain-HTTP LAN origin wrote
// nothing and said "Copied ✓" anyway, so operators kept drag-selecting after all. @/app/_components
// reports what actually happened; see lib/clipboard.ts.
const REPORT_COPY_STYLE = { padding: "1px 8px", marginTop: 3 } as const;

// The "expected X, got Y" tail for a check — but ONLY when it adds information. For a boolean check
// the ✓/✗ already says pass/fail, so "(expected true, got false)" is just noise; show the detail
// only on a FAILURE whose expected/actual carry a real value (a name, count, string).
function checkDetail(c: { expected?: unknown; actual?: unknown; pass: boolean }): string {
  if (c.pass) return "";
  const trivial = (val: unknown) => typeof val === "boolean" || val === null || val === undefined;
  if (trivial(c.expected) && trivial(c.actual)) return "";
  return ` — expected ${String(c.expected)}, got ${String(c.actual)}`;
}

// Plain-text dump of a step's full log (actions + validation + error + progress) — for the "Copy
// log" buttons, so an operator can paste exactly what they see straight into a report or chat.
function stepLogText(step: RunReport["steps"][number]): string {
  const L: string[] = [`${step.systemName} (${step.systemKey}) — ${step.verdict}`];
  if (step.actions.length) { L.push("Actions:"); for (const a of step.actions) L.push(a); }
  const v = step.validation as { ok?: boolean; checks?: { name: string; expected: unknown; actual: unknown; pass: boolean }[] } | null;
  if (v?.checks?.length) {
    const failed = v.checks.filter((c) => !c.pass).length;
    L.push(`Validation: ${failed ? `${failed} of ${v.checks.length} failed` : "passed"}`);
    for (const c of v.checks) L.push(`${c.pass ? "✓" : "✗"} ${c.name}${checkDetail(c)}`);
  }
  if (step.error) L.push(`Error: ${step.error}`);
  if (step.phaseTrail?.length) { L.push("Progress:"); for (const p of step.phaseTrail) L.push(`${new Date(p.ts).toLocaleTimeString()} ${p.phase}`); }
  return L.join("\n");
}

// The after-action run report: per-step verdicts, actions, validation read-backs, and errors.
// Auto-refreshes while the case is still running; offers per-step re-run + a gated SN write-back.
export function RunReportView({ initial, caseId, writeEnabled }: { initial: RunReport; caseId: string; writeEnabled: boolean }) {
  const [report, setReport] = useState<RunReport>(initial);
  const [open, setOpen] = useState<Set<number>>(new Set());
  const [waiting, setWaiting] = useState<Set<number>>(new Set()); // steps where the operator chose "I'll wait" on a license
  const [busy, setBusy] = useState<string | null>(null);
  const [writeBack, setWriteBack] = useState(false);
  const [writeMsg, setWriteMsg] = useState<string | null>(null);
  const [resolveOpen, setResolveOpen] = useState(false);
  const [now, setNow] = useState(() => Date.now()); // ticks while live so the "no progress for Ns" badge updates
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);
  // Sticky page-top banner: the current step is portaled into a slot right under the case title so it's
  // visible no matter where you've scrolled (the slot lives high on the page; this component is far down).
  // We look the slot up FRESH each render (not cached) so it can't go stale if the server component
  // re-renders and replaces that DOM node — that stale reference is what made the banner vanish.
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  const refresh = useCallback(async () => {
    const res = await fetch(`/api/cases/${caseId}/report`, { cache: "no-store" });
    if (res.ok) setReport((await res.json()) as RunReport);
  }, [caseId]);

  // Keep the report live without a manual refresh — including when SOMEONE ELSE starts a step on a
  // case you're viewing. Fast (2s) while a step is actively executing; 4s while in flight; a slow 12s
  // background poll otherwise so an externally-started run appears on its own. Stops only when terminal
  // (completed/failed) to avoid polling forever on a finished case.
  const live = ["queued", "planning", "running"].includes(report.caseStatus);
  const active = report.steps.some((s) => s.currentPhase);
  const terminal = ["completed", "failed"].includes(report.caseStatus);
  useEffect(() => {
    if (terminal) { if (timer.current) clearInterval(timer.current); return; }
    const period = active ? 2000 : live ? 4000 : 12000;
    timer.current = setInterval(refresh, period);
    return () => { if (timer.current) clearInterval(timer.current); };
  }, [terminal, live, active, refresh]);

  // Tick `now` every 5s while live so the per-step "no progress for Ns" badge counts up between polls.
  useEffect(() => {
    if (!live) return;
    const t = setInterval(() => setNow(Date.now()), 5000);
    return () => clearInterval(t);
  }, [live]);

  const toggle = (n: number) => setOpen((s) => { const x = new Set(s); x.has(n) ? x.delete(n) : x.add(n); return x; });

  // Auto-expand any step that's actively running so its live progress is visible without a click.
  // Once opened it stays open (we never auto-collapse) so the operator keeps the context.
  useEffect(() => {
    const running = report.steps.filter((s) => s.currentPhase).map((s) => s.seq);
    if (running.length) setOpen((prev) => { const x = new Set(prev); running.forEach((n) => x.add(n)); return x; });
  }, [report]);

  async function rerun(stepSeq: number, jobId: string | undefined) {
    if (!jobId) return;
    setBusy(`rerun-${stepSeq}`);
    setOpen((s) => new Set(s).add(stepSeq)); // expand immediately so the operator sees it start
    try {
      await fetch(`/api/jobs/${jobId}/rerun`, { method: "POST" });
      await refresh();
    } finally {
      setBusy(null);
    }
  }

  // Run ONLY this step, in isolation: the case is paused so nothing else cascades. If the step's
  // prerequisites aren't done the server returns 409 + blockedBy, and we warn-then-confirm (force).
  async function runSingle(stepSeq: number, jobId: string | undefined, force = false) {
    if (!jobId) return;
    setBusy(`single-${stepSeq}`);
    setOpen((s) => new Set(s).add(stepSeq));
    try {
      const r = await fetch(`/api/jobs/${jobId}/run-single`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ force }),
      });
      if (r.status === 409) {
        const data = await r.json().catch(() => null);
        const deps = (data?.blockedBy ?? []).map((b: { systemKey: string; status: string }) => `${b.systemKey} (${b.status})`).join(", ");
        if (confirm(`The step(s) this depends on aren't complete: ${deps || "unknown"}.\n\nRunning this step now may fail. Do you wish to continue?`)) {
          await runSingle(stepSeq, jobId, true); // re-issue forced
        }
        return;
      }
      if (!r.ok) alert((await r.json().catch(() => null))?.error ?? "could not run the step");
      await refresh();
    } finally {
      setBusy(null);
    }
  }

  // Run a step that's waiting on a vendor sync (request.autoRetry) right now, instead of at its
  // scheduled time. Same re-queue the timer would do; reschedules normally if it still needs to wait.
  async function retryNow(stepSeq: number, jobId: string | undefined) {
    if (!jobId) return;
    setBusy(`retrynow-${stepSeq}`);
    setOpen((s) => new Set(s).add(stepSeq));
    try {
      const r = await fetch(`/api/jobs/${jobId}/retry-now`, { method: "POST" });
      if (!r.ok) alert((await r.json().catch(() => null))?.error ?? "could not retry now");
      await refresh();
    } finally {
      setBusy(null);
    }
  }

  async function stopStep(stepSeq: number, jobId: string | undefined) {
    if (!jobId) return;
    if (!confirm("Stop this step? It'll be marked failed and the case stops waiting on it (a late result from the runner is ignored). You can re-run it after.")) return;
    setBusy(`stop-${stepSeq}`);
    try {
      const r = await fetch(`/api/jobs/${jobId}/stop`, { method: "POST" });
      if (!r.ok) alert((await r.json().catch(() => null))?.error ?? "could not stop the step");
      await refresh();
    } finally {
      setBusy(null);
    }
  }

  async function markComplete(stepSeq: number, jobId: string | undefined, done: boolean) {
    if (!jobId) return;
    setBusy(`complete-${stepSeq}`);
    try {
      await fetch(`/api/jobs/${jobId}/complete`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ done }) });
      await refresh();
    } finally {
      setBusy(null);
    }
  }

  // Ignore a warning/failed step the operator deems acceptable (e.g. a group that's intentionally
  // kept). Resolves its run-log fingerprint — sticky: re-runs of the same line inherit the
  // resolution. "↺ un-ignore" reverses it.
  async function ignoreWarning(stepSeq: number, fingerprint: string | null, undo: boolean) {
    if (!fingerprint) return;
    setBusy(`ignore-${stepSeq}`);
    try {
      undo ? await reopenOutcomes(fingerprint) : await resolveOutcomes(fingerprint);
      await refresh();
    } finally {
      setBusy(null);
    }
  }

  // Release an approval-gated (destructive) step so a runner can claim it. approvedBy defaults to the
  // signed-in operator server-side.
  async function approve(stepSeq: number, jobId: string | undefined) {
    if (!jobId) return;
    setBusy(`approve-${stepSeq}`);
    try {
      const r = await fetch(`/api/jobs/${jobId}/approve`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
      // Surface a refusal — middleware 503s approvals while operator auth is off, and a silent
      // swallow here would make the Approve button read as broken with the step still gated.
      if (!r.ok) alert((await r.json().catch(() => null))?.error ?? "could not approve the step");
      await refresh();
    } finally {
      setBusy(null);
    }
  }

  async function verifyAll() {
    setBusy("verify");
    try {
      const r = await fetch(`/api/cases/${caseId}/verify`, { method: "POST" });
      const d = (await r.json().catch(() => null)) as { error?: string; verifying?: number; note?: string } | null;
      // A silent no-op reads as "checked and fine" — say when nothing was verifiable (e.g. every
      // automated step was skipped), and surface refusals.
      if (!r.ok) alert(d?.error ?? "could not start the verify pass");
      else if (d?.verifying === 0) alert(d?.note ?? "no automated steps to verify — nothing was re-checked");
      await refresh();
    } finally {
      setBusy(null);
    }
  }

  async function postWorkNote() {
    setBusy("worknote");
    setWriteMsg(null);
    try {
      const res = await fetch(`/api/cases/${caseId}/worknote`, { method: "POST" });
      const body = (await res.json()) as { ok?: boolean; error?: string };
      setWriteMsg(res.ok ? "Work note posted to the UM ticket." : body.error ?? "Write-back failed.");
    } catch (e) {
      setWriteMsg((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  const s = report.summary;
  // Verification banner: the case auto-runs a read-only validation sweep once the automated work
  // finishes (and the operator can re-run it). `verifying` is server-driven (a validate-only job is
  // in flight) so the banner stays put across the gaps between steps instead of flickering.
  const verifying = report.verifying;
  // The step executing right now (for a prominent "what's happening" banner) — easier to follow than
  // scanning the per-step trails.
  const running = report.steps.find((st) => st.currentPhase);
  const pendingCount = report.steps.filter((st) => ["pending", "needs_approval", "running", "verifying"].includes(st.verdict)).length;
  // Pull the cross-lane mirror-coverage check (from the m365 validator) up to the banner so the
  // person handling the case sees mirror completeness without expanding a step.
  const mirrorCheck = report.steps.flatMap((st) => st.validation?.checks ?? []).find((c) => /mirror coverage/i.test(c.name));
  return (
    <div>
      <style>{`@keyframes pulse { 0%,100% { opacity: 0.35 } 50% { opacity: 1 } }`}</style>
      {/* Easter eggs: typed-word modes riding the egg-only class hooks below (see case-eggs.tsx). */}
      <CaseEggs offboard={report.action === "offboard"} />
      {report.credsMissing.length > 0 && (
        <div className="yswp-banner" style={{ margin: "0 0 0.6rem", padding: "0.5rem 0.7rem", borderRadius: 6, border: "1px solid #fde68a", background: "#fffbeb", color: "#92400e", fontSize: 13 }}>
          ⚠ <b>Client credentials not set up</b> for this case:{" "}
          {report.credsMissing.map((m) => `${m.secretName} (${m.systems.join(", ")})`).join("; ")}.{" "}
          Set them on the client&rsquo;s <a href={`/clients/${report.client.slug}`}>Credentials panel</a> — these steps stay blocked until they resolve.
        </div>
      )}
      {report.needsInfo && <NeedsInfoPanel caseId={caseId} info={report.needsInfo} refresh={refresh} />}
      {report.review && <ReviewPanel caseId={caseId} review={report.review} refresh={refresh} />}
      {report.delegation && <DelegationPanel caseId={caseId} d={report.delegation} refresh={refresh} />}
      {report.aiResolved && (
        <div className="note" style={{ margin: "0 0 0.5rem", padding: "0.45rem 0.65rem", borderRadius: 8, border: "1px solid #bfdbfe", background: "#eff6ff", color: "#1e40af" }}>
          ✨ AI-filled (please verify): {report.aiResolved.map((a) => `${a.field} — ${a.note}`).join(" · ")}
        </div>
      )}
      {running && mounted && (() => {
        const slot = typeof document !== "undefined" ? document.getElementById("case-running-banner-slot") : null;
        const banner = (
          <div style={{ padding: "0.5rem 0.8rem", fontSize: 13, borderBottom: "1px solid #bfdbfe", background: "#eff6ff", color: "#1d4ed8", display: "flex", alignItems: "center", gap: 8 }}>
            <span style={{ animation: "pulse 1.1s ease-in-out infinite", fontSize: 16 }}>▶</span>
            <span suppressHydrationWarning><b>{running.systemName}</b> — {running.currentPhase}…{pendingCount > 1 ? ` (${pendingCount} steps remaining)` : ""}</span>
          </div>
        );
        // Portal into the sticky page-top slot when present; otherwise fall back to rendering inline
        // here so the banner NEVER just disappears.
        return slot ? createPortal(banner, slot) : <div style={{ margin: "0 0 0.5rem" }}>{banner}</div>;
      })()}
      {(verifying || report.verifiedAt) && (
        <div style={{ margin: "0 0 0.5rem", padding: "0.45rem 0.6rem", borderRadius: 4, fontSize: 13, border: "1px solid", borderColor: verifying ? "#bfdbfe" : "#bbf7d0", background: verifying ? "#eff6ff" : "#f0fdf4", color: verifying ? "#1d4ed8" : "#15803d" }}>
          <div suppressHydrationWarning>
            {verifying
              ? <><span style={{ display: "inline-block", animation: "pulse 1.2s ease-in-out infinite" }}>🔎</span> Verifying the account — re-checking accounts, licensing, mirroring & access…</>
              : <>🔎 Account verified {report.verifiedAt && new Date(report.verifiedAt).toLocaleString()} — {s.failed > 0 || s.warnings > 0
                  ? `${s.failed} failed, ${s.warnings} warning to review before resolving`
                  : s.skipped > 0
                    // Skipped steps never ran and are deliberately NOT re-validated (a validator pass
                    // must not launder a never-executed teardown into green) — so a green verify can't
                    // claim "all checks passed" over them.
                    ? `the checks that ran passed, but ${s.skipped} step(s) were SKIPPED and never ran — review them before resolving`
                    : "all checks passed; safe to resolve the case"}</>}
          </div>
          {/* Mirror coverage only makes sense once the sweep has produced fresh validation. */}
          {!verifying && mirrorCheck && (
            <div style={{ marginTop: 4, fontWeight: 600, color: mirrorCheck.pass ? "#15803d" : "#b45309" }}>
              👥 {mirrorCheck.pass ? "✓" : "⚠"} {mirrorCheck.name}
            </div>
          )}
        </div>
      )}
      {(() => {
        // "All automated steps done" = every non-manual step reached a terminal non-failed state
        // (verified / warning / skipped); none pending, approval-gated, or failed. The remaining
        // work is then purely the manual checklist — listed here so the case can be closed by hand.
        const auto = report.steps.filter((st) => st.verdict !== "manual");
        const blocking = auto.filter((st) => ["pending", "needs_approval", "failed", "running", "verifying"].includes(st.verdict));
        const warns = auto.filter((st) => st.verdict === "warning");
        const retrying = report.steps.filter((st) => st.autoRetry);
        const manualLeft = report.steps.filter((st) => st.verdict === "manual" && !st.manualCompleted);
        if (auto.length === 0 || blocking.length > 0) return null;
        const clean = warns.length === 0 && retrying.length === 0;
        return (
          <div style={{ margin: "0 0 0.5rem", padding: "0.5rem 0.7rem", borderRadius: 4, fontSize: 13, border: "1px solid", borderColor: clean ? "#bbf7d0" : "#fde68a", background: clean ? "#f0fdf4" : "#fffbeb", color: clean ? "#15803d" : "#92400e" }}>
            <div style={{ fontWeight: 600 }}>
              ✓ All automated steps completed{clean ? " successfully" : ""}
              {warns.length > 0 && ` — ${warns.length} with warning${warns.length > 1 ? "s" : ""} to review`}
              {retrying.length > 0 && ` · ${retrying.length} auto-retrying for vendor sync`}
            </div>
            <div style={{ marginTop: 4, color: "#374151" }}>
              {manualLeft.length === 0
                ? "No manual steps remaining — the case can be resolved."
                : <>Remaining manual step{manualLeft.length > 1 ? "s" : ""} (do by hand, then ✓ mark complete): <b>{manualLeft.map((m) => m.systemName).join(", ")}</b></>}
            </div>
            {/* All automated work is done — let the operator review the full resolution + write it back. */}
            <button className="primary" style={{ marginTop: 8 }} onClick={() => setResolveOpen(true)}
              title="Review everything this case did (every step + manual notes) and post it as the ServiceNow work note">
              📋 Review resolution{manualLeft.length === 0 ? " & write back" : " notes"}
            </button>
          </div>
        );
      })()}
      <ResolutionModal report={report} caseId={caseId} writeEnabled={writeEnabled} open={resolveOpen} onClose={() => setResolveOpen(false)} />
      <div className="row-between" style={{ alignItems: "baseline" }}>
        <p className="note" style={{ margin: 0 }}>
          {s.succeeded} verified · {s.warnings} warning · {s.failed} failed · {s.skipped} skipped · {s.manual} manual
          {s.needsApproval > 0 && ` · ${s.needsApproval} needs approval`}
          {s.pending > 0 && ` · ${s.pending} pending`}
          {live && <span className="muted"> · refreshing…</span>}
        </p>
        <div className="toolbar">
          {/* FR #13: on a done case with leftover warnings the operator answered by hand, dismiss
              them all at once — the case stops reading orange here and on the list. A new real
              result clears the dismissal server-side, so fresh problems resurface. */}
          {s.warnings > 0 && !report.warningsDismissed && ["completed", "failed"].includes(report.caseStatus) && (
            <button
              onClick={async () => { await dismissCaseWarnings(caseId); await refresh(); }}
              title="Mark every warning on this case as handled — you finished the remaining steps manually. The case stops showing orange; a new run re-opens warnings."
            >
              ✓ Dismiss warnings
            </button>
          )}
          {report.warningsDismissed && (
            <span className="note" title={`dismissed by ${report.warningsDismissed.by ?? "unknown"}`}>
              warnings dismissed{" "}
              <button onClick={async () => { await restoreCaseWarnings(caseId); await refresh(); }} title="Bring the dismissed warnings back">↺ restore</button>
            </span>
          )}
          <button onClick={() => setOpen(new Set(report.steps.map((st) => st.seq)))} title="Expand every step">Expand all</button>
          <button onClick={() => setOpen(new Set())} title="Collapse every step">Collapse all</button>
          <button onClick={verifyAll} disabled={busy === "verify"} title="Re-run every step's read-only validation to confirm the whole account is correct — no changes are made">
            {busy === "verify" ? "verifying…" : "✓ Verify everything"}
          </button>
          <button onClick={refresh}>Refresh</button>
          <CopyButton text={report.steps.map(stepLogText).join("\n\n")} label="Copy log" title="Copy the whole run report (all steps' actions, validation + progress) as text" style={REPORT_COPY_STYLE} />
          <a href={`/api/cases/${caseId}/report?format=md`} download className="note">download .md →</a>
        </div>
      </div>

      {report.steps.map((step) => {
        // The ad-hoc "force Spanning sync" job is rendered nested UNDER the Spanning step (below), so
        // skip it at the top level — it appears exactly once, as a child of Spanning, not as its own
        // bare, duplicated line. Guard on a Spanning step actually being present so an orphan force-sync
        // (no Spanning line to parent to) still shows rather than vanishing.
        if (step.systemKey === SPANNING_FORCE_SYNC_KEY && report.steps.some((s) => s.systemKey === "spanning")) return null;
        const isOpen = open.has(step.seq);
        const hasDetail = step.actions.length > 0 || step.validation || step.error || step.phaseTrail.length > 0;
        const spanningChildren = step.systemKey === "spanning" ? report.steps.filter((s) => s.systemKey === SPANNING_FORCE_SYNC_KEY) : [];
        return (
          <React.Fragment key={step.seq}>
          {/* os-printer / t800-done: egg-only hooks, inert until their modes are on (case-eggs.tsx). */}
          <details open={isOpen} className={step.systemKey === "printers" ? "os-printer" : undefined} style={{ margin: "0.2rem 0" }}>
            {/* hm-wait: egg-only hook for the holdmusic egg, inert until body.hm-mode (case-eggs.tsx). */}
            <summary className={[step.intent && step.verdict === "verified" ? "t800-done" : null, ["pending", "needs_approval", "running", "verifying"].includes(step.verdict) ? "hm-wait" : null].filter(Boolean).join(" ") || undefined} onClick={(e) => { e.preventDefault(); if (hasDetail) toggle(step.seq); }} style={{ cursor: hasDetail ? "pointer" : "default" }}>
              <strong style={{ marginRight: 6 }}>{step.seq}.</strong>
              <Badge verdict={step.verdict} /> {step.systemName} <span className="note">({step.systemKey})</span>
              {step.intent === "destructive" && (
                <span className="badge" style={{ marginLeft: 8, color: "#b3261e", borderColor: "#f3c0bb", background: "#fdecea" }}
                  title="Destructive — deletes data. Always requires approval, and state is snapshotted first.">⚠ destructive</span>
              )}
              {step.intent === "disable" && (
                <span className="badge" style={{ marginLeft: 8, color: "#1d4ed8", borderColor: "#bfdbfe", background: "#eff6ff" }}
                  title="Reversible containment (lockout / isolate / revoke sessions) — undoable by re-enabling.">disable</span>
              )}
              {step.expectedLicenses && (
                <span style={{ marginLeft: 8, fontSize: 12 }} title={step.expectedLicenses.fromTicket ? "From the ticket's product licenses — overrides the client's license rules" : "Resolved from the client's M365 license rules at plan time"}>
                  · license: <b>{step.expectedLicenses.names.join(", ")}</b>
                  <span className="note"> {step.expectedLicenses.fromTicket ? "(ticket)" : "(rule)"}</span>
                </span>
              )}
              {step.currentPhase && (
                <span style={{ marginLeft: 8, color: "#2563eb", fontSize: 12 }} suppressHydrationWarning>
                  <span style={{ display: "inline-block", animation: "pulse 1.2s ease-in-out infinite" }}>▸</span> {step.currentPhase}…
                </span>
              )}
              {/* No-progress warning: a running step that's been silent too long may be stalling. The
                  server auto-stops a truly wedged step at 20 min; this is the EARLY visual heads-up. */}
              {(() => {
                if (step.verdict !== "running" && step.verdict !== "verifying") return null;
                if (!step.lastProgressAt) return null;
                const secs = Math.floor((now - new Date(step.lastProgressAt).getTime()) / 1000);
                if (secs < 90) return null;
                const human = secs >= 120 ? `${Math.floor(secs / 60)}m` : `${secs}s`;
                return (
                  <span className="badge" style={{ marginLeft: 8, color: "#92400e", borderColor: "#fde68a", background: "#fffbeb" }} suppressHydrationWarning
                    title="This step hasn't reported progress recently — it may be on a slow call or stalling. The server auto-stops a wedged step after 20 minutes; you can also Stop it now.">
                    ⏳ no progress for {human}
                  </span>
                );
              })()}
              {step.autoStopped && (
                <span className="badge" style={{ marginLeft: 8, color: "#92400e", borderColor: "#fde68a", background: "#fffbeb" }}
                  title="The server auto-stopped this step after it made no progress for 20 minutes (wedged). The case continued; re-run this step to retry.">
                  ⏱ auto-stopped — no progress
                </span>
              )}
              {/* A pending step says WHY it hasn't started — waiting on predecessors, a missing
                  credential, or no runner — right on the row, no expanding needed. */}
              {step.pendingReason && (
                <span className={step.pendingReason.startsWith("blocked") ? "yswp-blocked" : undefined} style={{ marginLeft: 8, fontSize: 12, color: step.pendingReason.startsWith("blocked") ? "#b3261e" : "#8a6d00" }}>
                  ⏳ {step.pendingReason}
                </span>
              )}
              {/* Waiting on a vendor sync (Spanning/Mimecast self-scheduled retry): show when the next
                  attempt is due + a "retry now" button so the operator needn't wait for the timer. */}
              {step.autoRetry && (
                <>
                  <span style={{ marginLeft: 8, fontSize: 12, color: "#1565c0" }} suppressHydrationWarning>
                    next try {new Date(step.autoRetry.at).toLocaleTimeString()}
                  </span>
                  <button
                    style={{ marginLeft: 6, fontSize: 11 }}
                    disabled={busy === `retrynow-${step.seq}`}
                    title="Run this waiting step now instead of at its scheduled time. If the vendor still hasn't synced, it reschedules the next attempt as normal."
                    onClick={(e) => { e.preventDefault(); retryNow(step.seq, step.jobId); }}
                  >
                    {busy === `retrynow-${step.seq}` ? "retrying…" : "↻ retry now"}
                  </button>
                </>
              )}
              {/* Stop an in-flight step that looks wedged: marks it failed so the case stops waiting on
                  it (a late runner result is then ignored). For the UM0029280 class — a hung vendor call. */}
              {["running", "retrying", "pending"].includes(step.verdict) && step.jobId && (
                <button
                  style={{ marginLeft: 8, fontSize: 11, color: "#b3261e" }}
                  disabled={busy === `stop-${step.seq}`}
                  title="Abort this step — mark it failed and stop the case waiting on it (the runner's late result is ignored). You can re-run it after."
                  onClick={(e) => { e.preventDefault(); stopStep(step.seq, step.jobId); }}
                >
                  {busy === `stop-${step.seq}` ? "stopping…" : "■ stop step"}
                </button>
              )}
              {/* Any finished automated step can be re-run — incl. "verified" (e.g. re-run exchange to
                  finish regional/calendar deferred when the mailbox hadn't synced yet). */}
              {["verified", "warning", "failed", "skipped"].includes(step.verdict) && step.jobId && !ADHOC_SYSTEM_KEYS.includes(step.systemKey) && (
                <button
                  style={{ marginLeft: 8, fontSize: 11 }}
                  disabled={busy === `rerun-${step.seq}`}
                  onClick={(e) => { e.preventDefault(); rerun(step.seq, step.jobId); }}
                >
                  {busy === `rerun-${step.seq}` ? "re-running…" : "re-run / re-validate"}
                </button>
              )}
              {/* Run ONLY this step (no cascade): the case is paused so the rest of the run is held.
                  For testing or fixing a single step. Hidden while it's in flight / awaiting approval. */}
              {["pending", "verified", "warning", "failed", "skipped"].includes(step.verdict) && step.jobId && !ADHOC_SYSTEM_KEYS.includes(step.systemKey) && (
                <button
                  style={{ marginLeft: 8, fontSize: 11 }}
                  disabled={busy === `single-${step.seq}`}
                  title="Run just this step now and hold the rest of the run (the case is paused). Use Resume to continue the full run."
                  onClick={(e) => { e.preventDefault(); runSingle(step.seq, step.jobId); }}
                >
                  {busy === `single-${step.seq}` ? "running…" : "▶ run this step only"}
                </button>
              )}
              {/* Generate a fresh random password on this account and show it once (INC0855142) —
                  offered on the AD / M365 / Entra / Google Workspace lines once the account exists. */}
              {["verified", "warning"].includes(step.verdict) && step.jobId && PASSWORD_RESET_KEY[step.systemKey] && (
                <GeneratePasswordButton jobId={step.jobId} systemName={step.systemName} refresh={refresh} />
              )}
              {/* On the reset line itself: the one-time reveal, for a popup closed before it showed. */}
              {step.verdict === "verified" && step.jobId && PASSWORD_RESET_SYSTEM_KEYS.includes(step.systemKey) && (
                <RevealResetPasswordButton jobId={step.jobId} systemName={step.systemName} />
              )}
              {/* Force Spanning sync (browser automation) — offered on the Spanning line once it's run,
                  to make Spanning discover a just-created user now instead of on its own schedule. */}
              {["verified", "warning"].includes(step.verdict) && step.jobId && step.systemKey === "spanning" && (
                <ForceSpanningSyncButton jobId={step.jobId} refresh={refresh} />
              )}
              {/* Ignore an intentional warning/failure ("mark as complete") — or un-ignore it. */}
              {(step.verdict === "warning" || step.verdict === "failed") && step.fingerprint && (
                <button
                  style={{ marginLeft: 8, fontSize: 11, color: "#92400e" }}
                  disabled={busy === `ignore-${step.seq}`}
                  title="Mark this warning acceptable — clears it here and in the run log, and stays cleared on re-runs"
                  onClick={(e) => { e.preventDefault(); ignoreWarning(step.seq, step.fingerprint, false); }}
                >
                  {busy === `ignore-${step.seq}` ? "…" : "✓ ignore warning — mark complete"}
                </button>
              )}
              {step.accepted && step.fingerprint && (
                <>
                  <span style={{ marginLeft: 8, fontSize: 11, color: "#15803d" }}>✓ accepted (ignored)</span>
                  <button
                    style={{ marginLeft: 6, fontSize: 11 }}
                    disabled={busy === `ignore-${step.seq}`}
                    onClick={(e) => { e.preventDefault(); ignoreWarning(step.seq, step.fingerprint, true); }}
                  >
                    {busy === `ignore-${step.seq}` ? "…" : "↺ un-ignore"}
                  </button>
                </>
              )}
              {/* An approval-gated (destructive) step — release it so a runner can claim it. */}
              {step.verdict === "needs_approval" && step.jobId && (
                <button
                  className="primary"
                  style={{ marginLeft: 8, fontSize: 11 }}
                  disabled={busy === `approve-${step.seq}`}
                  onClick={(e) => { e.preventDefault(); approve(step.seq, step.jobId); }}
                >
                  {busy === `approve-${step.seq}` ? "approving…" : "✓ Approve step"}
                </button>
              )}
              {/* Manual / skipped steps an operator does by hand — mark them done so the case can
                  reach "completed"; unmark if it was closed by mistake. */}
              {(step.verdict === "manual" || step.verdict === "skipped") && step.jobId && (
                <button
                  style={{ marginLeft: 8, fontSize: 11 }}
                  disabled={busy === `complete-${step.seq}`}
                  onClick={(e) => { e.preventDefault(); markComplete(step.seq, step.jobId, true); }}
                >
                  {busy === `complete-${step.seq}` ? "marking…" : "✓ mark complete"}
                </button>
              )}
              {step.manualCompleted && step.jobId && (
                <>
                  <span style={{ marginLeft: 8, fontSize: 11, color: "#15803d" }}>done by hand</span>
                  <button
                    style={{ marginLeft: 6, fontSize: 11 }}
                    disabled={busy === `complete-${step.seq}`}
                    onClick={(e) => { e.preventDefault(); markComplete(step.seq, step.jobId, false); }}
                  >
                    {busy === `complete-${step.seq}` ? "…" : "unmark"}
                  </button>
                </>
              )}
            </summary>
            <div style={{ margin: "0.4rem 0 0.6rem 0.8rem" }}>
              {hasDetail && (
                <div style={{ marginBottom: 4 }}>
                  <CopyButton text={stepLogText(step)} label="Copy this step's log" title="Copy this step's actions, validation + progress as text" style={REPORT_COPY_STYLE} />
                </div>
              )}
              {step.actions.length > 0 && (
                <div>
                  <div className="note">Actions:</div>
                  <ul className="muted" style={{ margin: "0.2rem 0 0" }}>
                    {/* This report polls live; an actively-running step appends to its action lines
                        (e.g. "username available: <upn>") between the server snapshot and hydration.
                        That benign churn is expected — suppress the hydration text-diff warning. */}
                    {/* DECISION_NEEDED:* lines are a marker for the picker below, not prose — the
                        runner emits a human-readable WARN alongside each one, which is what belongs
                        in the log. Rendering the raw marker would just be the same thing twice, in
                        machine syntax. */}
                    {step.actions.filter((a) => !isDecisionMarker(a)).map((a, i) => {
                      // A "WARN …" action line renders orange so it stands out when scanning the log;
                      // a TAP line (with the passcode) renders in a highlighted, monospaced box so it's
                      // easy to spot and copy for the new hire.
                      // Match WARN anywhere in the line — some are prefixed, e.g. "license: WARN …".
                      const warn = /\bWARN\b/.test(a);
                      const tap = /^TAP for /i.test(a);
                      return (
                        <li key={i} suppressHydrationWarning
                          style={warn ? { color: "#b45309", fontWeight: 500 }
                            : tap ? { color: "#1d4ed8", fontWeight: 600, fontFamily: "var(--mono, monospace)", background: "#eff6ff", borderRadius: 4, padding: "1px 6px", listStyle: "none", marginLeft: "-1.1rem" }
                            : undefined}>
                          {a}
                        </li>
                      );
                    })}
                  </ul>
                </div>
              )}
              {step.validation && (() => {
                const checks = step.validation.checks;
                const failed = checks.filter((c) => !c.pass).length;
                // A retrying step's failing checks are EXPECTED (the vendor hasn't synced yet) — show
                // them as benign "pending, will re-check" (⟳ blue), not alarming ✗ "needs review".
                const retrying = step.verdict === "retrying";
                return (
                  <div style={{ marginTop: "0.4rem" }}>
                    <div className="note" style={{ color: retrying ? "#1565c0" : failed ? "#b45309" : "#15803d", fontWeight: 600 }}>
                      {retrying
                        ? `Validation: ${failed} of ${checks.length} pending — waiting for the vendor to sync, re-checks automatically`
                        : `Validation: ${failed ? `${failed} of ${checks.length} need${failed === 1 ? "s" : ""} review` : "passed"}`}
                    </div>
                    <ul style={{ margin: "0.2rem 0 0", padding: 0, listStyle: "none", fontSize: 13 }}>
                      {checks.map((c, i) => (
                        <li key={i} style={{ display: "flex", gap: 6, alignItems: "baseline", padding: "1px 0" }}>
                          <span style={{ color: c.pass ? "#15803d" : retrying ? "#1565c0" : "#b91c1c", fontWeight: 700, flexShrink: 0 }}>{c.pass ? "✓" : retrying ? "⟳" : "✗"}</span>
                          <span style={{ color: c.pass ? "var(--muted, #6b7280)" : retrying ? "#1565c0" : "#b91c1c" }}>
                            {c.name}<span className="muted">{checkDetail(c)}</span>
                          </span>
                        </li>
                      ))}
                    </ul>
                  </div>
                );
              })()}
              {step.singleRun && step.status === "pending" && (
                <div className="note" style={{ marginTop: 6, color: "#1d4ed8" }}>
                  ⏳ Queued to run on its own — waiting for a runner to pick it up. The case stays paused
                  until you resume it. A runner won&apos;t look for new work until it finishes what it is
                  already running, so this can take a few minutes; nothing is stuck.
                </div>
              )}
              {step.error && (
                <div>
                  <pre style={{ ...PRE, color: "#b91c1c" }}>{step.error}</pre>
                  <CopyButton text={step.error} label="Copy error" title="Copy the full error text" style={REPORT_COPY_STYLE} />
                </div>
              )}
              {step.error?.includes("DECISION_NEEDED:username_collision") && step.jobId && (
                <CollisionDecision caseId={caseId} jobId={step.jobId} error={step.error} refresh={refresh} />
              )}
              {step.error?.includes("DECISION_NEEDED:synced_upn_mismatch") && step.jobId && (
                <SyncedMismatchDecision caseId={caseId} jobId={step.jobId} error={step.error} refresh={refresh} />
              )}
              {/* Gated on the ACTIONS, not the error: this step succeeded — only the licence is
                  unresolved. The component returns null when its marker isn't present. */}
              {step.jobId && <MailboxOversizeDecision caseId={caseId} jobId={step.jobId} actions={step.actions} refresh={refresh} />}
              {/* Same gating, different question: the mailbox is under the cap and nothing converted
                  it, so converting is a real answer and this one owns its own re-queue ordering. */}
              {step.jobId && <MailboxNotConvertedDecision caseId={caseId} actions={step.actions} refresh={refresh} />}
              <ExchangeConvertDefaultOffer caseId={caseId} systemKey={step.systemKey} />
              {step.autoRetry && (
                <div className="note gh-retry" data-attempt={step.autoRetry.count} style={{ marginTop: 4, color: "#8a6d00" }} suppressHydrationWarning>
                  {/* gh-orig: the groundhog egg hides this span and reads data-attempt instead. */}
                  <span className="gh-orig">
                    ⟳ auto-retry scheduled ~{new Date(step.autoRetry.at).toLocaleTimeString()} (attempt {step.autoRetry.count}, waiting since {new Date(step.autoRetry.firstAt).toLocaleTimeString()}) — server-side, safe to close this page
                  </span>
                </div>
              )}
              {step.licenseOptions && step.jobId && <LicensePicker jobId={step.jobId} options={step.licenseOptions} refresh={refresh} waiting={waiting.has(step.seq)} onWait={() => setWaiting((s) => new Set(s).add(step.seq))} />}
              {step.licenseIssues && step.jobId && <LicenseRecoveryBox jobId={step.jobId} issues={step.licenseIssues} refresh={refresh} />}
              {step.offboardCandidates && <OffboardTargetPicker caseId={report.caseId} data={step.offboardCandidates} refresh={refresh} />}
              <ProcurementWatchRow step={step} refresh={refresh} forceShow={waiting.has(step.seq)} />
              {step.phaseTrail.length > 0 && (
                <div style={{ marginTop: "0.4rem" }}>
                  <div className="note">Progress:</div>
                  <ul className="muted" style={{ margin: "0.2rem 0 0", listStyle: "none", paddingLeft: 0 }}>
                    {step.phaseTrail.map((p, i) => (
                      <li key={i}>
                        <span style={{ color: "#9ca3af", marginRight: 6 }} suppressHydrationWarning>{p.ts ? new Date(p.ts).toLocaleTimeString() : ""}</span>
                        {p.phase}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
            </div>
          </details>
          {/* Force Spanning sync (ad-hoc browser job) folded in under the Spanning step — indented,
              with a ↳ connector — so it reads as a sub-action of Spanning rather than a duplicated
              top-level warning. There's a single one per case (the trigger re-queues it in place). */}
          {spanningChildren.map((child) => {
            const childOpen = open.has(child.seq);
            const childHasDetail = child.actions.length > 0 || Boolean(child.error) || child.phaseTrail.length > 0;
            return (
              <details key={child.seq} open={childOpen} style={{ margin: "0 0 0.2rem 1.6rem" }}>
                <summary onClick={(e) => { e.preventDefault(); if (childHasDetail) toggle(child.seq); }} style={{ cursor: childHasDetail ? "pointer" : "default" }}>
                  <span className="note" style={{ marginRight: 6 }}>↳</span>
                  <Badge verdict={child.verdict} /> {child.systemName}
                  {child.autoRetry && (
                    <span style={{ marginLeft: 8, fontSize: 12, color: "#1565c0" }} suppressHydrationWarning>
                      next try {new Date(child.autoRetry.at).toLocaleTimeString()}
                    </span>
                  )}
                </summary>
                <div style={{ margin: "0.4rem 0 0.6rem 2.2rem" }}>
                  {child.actions.length > 0 && (
                    <ul className="muted" style={{ margin: "0.2rem 0 0" }}>
                      {child.actions.map((a, i) => (
                        <li key={i} suppressHydrationWarning style={/\bWARN\b/.test(a) ? { color: "#b45309", fontWeight: 500 } : undefined}>{a}</li>
                      ))}
                    </ul>
                  )}
                  {child.error && (
                    <div><pre style={{ ...PRE, color: "#b91c1c" }}>{child.error}</pre><CopyButton text={child.error} label="Copy error" title="Copy the full error text" style={REPORT_COPY_STYLE} /></div>
                  )}
                </div>
              </details>
            );
          })}
          </React.Fragment>
        );
      })}

      <div style={{ marginTop: "0.8rem", paddingTop: "0.6rem", borderTop: "1px solid #e5e7eb" }}>
        <label className="note" title={writeEnabled ? undefined : "Disabled — the ServiceNow key is read-only (SN_WRITE_ENABLED is off)"}>
          <input type="checkbox" checked={writeBack} disabled={!writeEnabled} onChange={(e) => setWriteBack(e.target.checked)} style={{ marginRight: 6 }} />
          Write back to UM
        </label>
        <button
          style={{ marginLeft: 8 }}
          disabled={!writeEnabled || !writeBack || busy === "worknote"}
          onClick={postWorkNote}
        >
          {busy === "worknote" ? "posting…" : "Post work note"}
        </button>
        {writeMsg && <span className="note" style={{ marginLeft: 8 }}>{writeMsg}</span>}
      </div>
    </div>
  );
}
