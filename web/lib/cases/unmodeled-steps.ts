import type { PlannedJob } from "../orchestrator";

// A runbook section the extractor could not map to a known system (RunbookSection.status
// "unmodeled"): real work — Dropsuite, Box, Verizon, LogMeIn, SalesForce — that the planner never
// saw, because planCase reads ClientSystem rows and nothing read the sections. So it vanished off
// the case entirely (FR #0000096).
//
// Each one becomes a MANUAL job: a manual job holds the case at "needs_manual" until an operator
// ticks it off (runner-logic.ts), which is exactly the spec's "an untouched one holds the case
// open". Everything downstream already exists — the complete route, the undo, the Run Report's
// rendering of manual notes — so this is the only missing hop.
export const UNMODELED_PREFIX = "unmodeled:";

// seq = the section's position in the runbook, so the step can be placed where it's documented.
export type UnmodeledSection = { title: string; steps: string[]; guess: string | null; seq?: number };

// Job.systemKey is a plain String, not a foreign key, so a synthetic key is safe here. It must be
// STABLE across re-plans: replanCaseJobs keys kept jobs by systemKey, so a key that drifted would
// recreate a ticked-off checklist item as untouched work every time the case was re-planned.
export function unmodeledStepKey(title: string, taken: Set<string>): string {
  const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60);
  if (!slug) return "";
  let key = `${UNMODELED_PREFIX}${slug}`;
  for (let n = 2; taken.has(key); n++) key = `${UNMODELED_PREFIX}${slug}-${n}`;
  taken.add(key);
  return key;
}

// The section's own title, read back off a planned job — the Run Report shows this rather than the
// slugged key, so an operator sees "Visual Studio Subscriptions", not
// "unmodeled:visual-studio-subscriptions".
export function unmodeledStepTitle(request: unknown): string | null {
  const cfg = ((request ?? {}) as { config?: unknown }).config as { title?: unknown } | undefined;
  return typeof cfg?.title === "string" && cfg.title.trim() ? cfg.title.trim() : null;
}

export function unmodeledManualJobs(sections: UnmodeledSection[], startSequence: number): PlannedJob[] {
  return unmodeledManualSteps(sections, startSequence).map((u) => u.job);
}

// The same jobs, each with its section's runbook position (for mergeInDocumentedOrder).
export function unmodeledManualSteps(sections: UnmodeledSection[], startSequence: number): { job: PlannedJob; seq: number | undefined }[] {
  const taken = new Set<string>();
  const out: { job: PlannedJob; seq: number | undefined }[] = [];
  for (const s of sections) {
    const title = (s.title ?? "").trim();
    const systemKey = unmodeledStepKey(title, taken);
    if (!systemKey) continue; // nothing usable to key on — a heading of punctuation, not a step
    const steps = (s.steps ?? []).map((x) => String(x).trim()).filter(Boolean);
    out.push({ seq: s.seq, job: {
      systemKey,
      sequence: startSequence + out.length,
      mode: "manual",
      requiresApproval: false, // a checklist item, not destructive automation
      captureEvidence: false,
      intent: null,
      secretNames: [],
      dependsOn: [], // depends on nothing, and nothing depends on it
      // `notes` is what the Run Report renders for a manual step (manualNotesOf). With no steps the
      // title is the whole instruction, so it becomes the note itself rather than an empty line.
      config: { title, guess: s.guess ?? null, notes: steps.length ? steps : [title], unmodeled: true },
    } });
  }
  return out;
}
