import type { PlannedJob } from "../orchestrator";

// A case's steps follow the order the client's runbook documents them (FR #0000178). Dependencies
// still decide first (planCase); this is the tiebreak for everything they leave open, which used to
// come out in whatever order the database returned the client's systems.

export type DocumentedSection = { systemKey: string | null; seq: number };

// systemKey -> its position in this action's runbook. A system that appears in more than one section
// takes its FIRST one, the point where the engineer starts on it.
export function documentedRank(sections: DocumentedSection[]): Map<string, number> {
  const rank = new Map<string, number>();
  for (const s of sections) {
    if (!s.systemKey) continue;
    const cur = rank.get(s.systemKey);
    if (cur === undefined || s.seq < cur) rank.set(s.systemKey, s.seq);
  }
  return rank;
}

// The client's systems in runbook order, for planCase (which keeps the order it's given wherever
// dependencies leave it open). A system the runbook doesn't document goes after the documented ones,
// in the order it came in; planCase still pulls it forward if a documented step depends on it.
// Stable, so with no runbook imported the order is unchanged.
export function inDocumentedOrder<T extends { systemKey: string }>(systems: T[], rank: ReadonlyMap<string, number>): T[] {
  const r = (s: T) => rank.get(s.systemKey) ?? Number.MAX_SAFE_INTEGER;
  return [...systems].sort((a, b) => r(a) - r(b));
}

// Merge the unmodeled-section checklist steps into the planned systems at the point the runbook lists
// them, instead of all at the end. Each goes just before the first planned step documented AFTER it;
// one documented after every planned step stays at the end, as before. The planned steps keep their
// relative order (it is the dependency order), and the unmodeled steps depend on nothing and nothing
// depends on them, so moving them changes what an operator reads, not what can run. Sequences are
// renumbered 0..n in the merged order.
export function mergeInDocumentedOrder(
  planned: PlannedJob[],
  unmodeled: { job: PlannedJob; seq: number | undefined }[],
  rank: ReadonlyMap<string, number>
): PlannedJob[] {
  const pending = unmodeled
    .map((u, i) => ({ ...u, i }))
    // No position known (an older caller): keep today's behaviour and put it last.
    .map((u) => ({ ...u, seq: u.seq ?? Number.MAX_SAFE_INTEGER }))
    .sort((a, b) => a.seq - b.seq || a.i - b.i);
  const out: PlannedJob[] = [];
  let next = 0;
  for (const p of planned) {
    const r = rank.get(p.systemKey);
    if (r !== undefined) {
      while (next < pending.length && pending[next].seq < r) out.push(pending[next++].job);
    }
    out.push(p);
  }
  while (next < pending.length) out.push(pending[next++].job);
  return out.map((j, i) => ({ ...j, sequence: i }));
}
