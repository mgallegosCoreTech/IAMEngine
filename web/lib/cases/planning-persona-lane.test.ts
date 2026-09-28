import { test } from "node:test";
import assert from "node:assert/strict";
import { createAndPlanCase } from "./planning-service";
import type { CaseRepository } from "./repository";
import type { PlannedJob } from "../orchestrator";

// End-to-end through the planning SERVICE (no DB): a by_persona system is included/excluded by the
// matched persona's bundle, and the nickname drives the derived identity the case stores.
function fakeRepo(captured: { payload?: Record<string, unknown>; jobs?: PlannedJob[] }): CaseRepository {
  const sys = (over: Record<string, unknown>) => ({
    id: "s", clientId: "c1", mode: "api", onboardWhen: "always", offboardWhen: "never",
    dependsOn: [], requiresApproval: false, captureEvidence: false, secretNames: [], config: null,
    ...over,
  });
  return {
    // FR #0000096: the planner asks for unmodeled runbook sections to plan as manual steps.
    unmodeledSections: async () => [],
    documentedSections: async () => [],
    clientForPlanning: async () => ({
      id: "c1", name: "Acme", slug: "acme", emailDomain: "acme.com", primaryDomain: "acme.com",
      identity: { usernamePatterns: ["{firstInitial}{last}@{domain}"] },
      personas: {
        "On-Call": { titles: ["Ops Engineer"], systems: { xmatters: { site: "Boston" } } },
      },
      systems: [
        sys({ systemKey: "servicenow" }),
        sys({ systemKey: "xmatters", onboardWhen: "by_persona" }),
      ],
    }),
    createCaseWithJobs: async (input: { payload: Record<string, unknown> }, _cid: string, jobs: PlannedJob[]) => {
      captured.payload = input.payload;
      captured.jobs = jobs;
      return "case1";
    },
    setHold: async () => {},
    writeAudit: async () => {},
  } as unknown as CaseRepository;
}

test("by-persona system is planned for a matching hire, with the persona's config fragment resolved in", async () => {
  const captured: { payload?: Record<string, unknown>; jobs?: PlannedJob[] } = {};
  await createAndPlanCase(fakeRepo(captured), {
    clientSlug: "acme", action: "onboard",
    payload: { firstName: "William", lastName: "Smith", nickname: "Bill", jobTitle: "x", roles: ["On-Call"] },
  }, "tester");
  const xm = captured.jobs!.find((j) => j.systemKey === "xmatters");
  assert.ok(xm, "xmatters should be planned for the On-Call persona");
  // The persona's config fragment flows onto the included job via the normal v2.1 resolution.
  assert.equal((xm!.config as { site?: string }).site, "Boston");
  // Nickname-derived identity persisted on the case payload: Bill Smith -> bsmith, givenName Bill.
  assert.equal(captured.payload!.samAccountName, "bsmith");
  assert.equal(captured.payload!.userPrincipalName, "bsmith@acme.com");
  assert.equal(captured.payload!.firstName, "Bill");
  assert.equal(captured.payload!.legalFirstName, "William");
  assert.equal(captured.payload!.displayName, "Bill Smith");
});

test("by-persona system is NOT planned when no persona matches", async () => {
  const captured: { payload?: Record<string, unknown>; jobs?: PlannedJob[] } = {};
  await createAndPlanCase(fakeRepo(captured), {
    clientSlug: "acme", action: "onboard",
    payload: { firstName: "Jane", lastName: "Doe", roles: ["Finance"] },
  }, "tester");
  assert.equal(captured.jobs!.some((j) => j.systemKey === "xmatters"), false);
  assert.ok(captured.jobs!.some((j) => j.systemKey === "servicenow"));
});
