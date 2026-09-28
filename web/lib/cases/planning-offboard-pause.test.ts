import { test } from "node:test";
import assert from "node:assert/strict";
import { createAndPlanCase } from "./planning-service";
import type { CaseRepository } from "./repository";

// A minimal fake repo (no DB) that records setHold calls — enough to exercise createAndPlanCase's
// hold logic. The client has no systems, so planCase returns [] and no real planning runs.
function fakeRepo(holds: Array<[string, string | null]>): CaseRepository {
  return {
    // FR #0000096: the planner asks for unmodeled runbook sections to plan as manual steps.
    unmodeledSections: async () => [],
    documentedSections: async () => [],
    clientForPlanning: async () => ({
      id: "c1", name: "Acme", slug: "acme", identity: {}, emailDomain: "acme.com",
      primaryDomain: "acme.com", systems: [],
    }),
    createCaseWithJobs: async () => "case1",
    setHold: async (id: string, reason: string | null) => { holds.push([id, reason]); },
    writeAudit: async () => {},
  } as unknown as CaseRepository;
}

test("an imported offboard is auto-held as 'scheduled' (may be future-dated)", async () => {
  const holds: Array<[string, string | null]> = [];
  await createAndPlanCase(fakeRepo(holds), { clientSlug: "acme", action: "offboard", payload: {} }, "tester");
  assert.deepEqual(holds, [["case1", "scheduled"]]);
});

test("a dry-run offboard is NOT auto-held (the operator wants the read-only preview to run now)", async () => {
  const holds: Array<[string, string | null]> = [];
  await createAndPlanCase(fakeRepo(holds), { clientSlug: "acme", action: "offboard", payload: {}, dryRun: true }, "tester");
  assert.equal(holds.length, 0);
});

test("an imported onboard is auto-held as 'review' (nothing auto-runs — an operator resumes it)", async () => {
  const holds: Array<[string, string | null]> = [];
  await createAndPlanCase(fakeRepo(holds), { clientSlug: "acme", action: "onboard", payload: {} }, "tester");
  assert.deepEqual(holds, [["case1", "review"]]);
});

test("an onboard with intake unknowns is held as 'needs_info' (the more specific reason wins)", async () => {
  const holds: Array<[string, string | null]> = [];
  await createAndPlanCase(fakeRepo(holds), { clientSlug: "acme", action: "onboard", payload: { unknownFields: ["manager"] } }, "tester");
  assert.deepEqual(holds, [["case1", "needs_info"]]);
});

test("a dry-run onboard is NOT auto-held (the read-only preview runs now)", async () => {
  const holds: Array<[string, string | null]> = [];
  await createAndPlanCase(fakeRepo(holds), { clientSlug: "acme", action: "onboard", payload: {}, dryRun: true }, "tester");
  assert.equal(holds.length, 0);
});
