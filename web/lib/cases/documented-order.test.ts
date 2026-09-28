import { test } from "node:test";
import assert from "node:assert/strict";
import type { ClientSystem } from "@prisma/client";
import { planCase, type PlannedJob } from "../orchestrator";
import { documentedRank, inDocumentedOrder, mergeInDocumentedOrder } from "./documented-order";
import { unmodeledManualSteps } from "./unmodeled-steps";
import { createAndPlanCase } from "./planning-service";
import type { CaseRepository } from "./repository";

// FR #0000178: a case's steps follow the order the client's runbook documents them. Before, steps
// that didn't depend on each other came out in whatever order the database returned the systems.

function sys(over: Partial<ClientSystem>): ClientSystem {
  return {
    id: "id", clientId: "c", systemKey: "m365", mode: "api",
    onboardWhen: "always", offboardWhen: "always",
    dependsOn: [], requiresApproval: false, captureEvidence: false,
    secretNames: [], config: null,
    ...over,
  } as unknown as ClientSystem;
}
const keys = (jobs: PlannedJob[]) => jobs.map((j) => j.systemKey);
const rankOf = (...ks: string[]) => new Map(ks.map((k, i) => [k, i + 1]));
// What the planning services do: pass the systems in runbook order.
const planIn = (systems: ClientSystem[], action: "onboard" | "offboard", rank: ReadonlyMap<string, number>) =>
  planCase(inDocumentedOrder(systems, rank), action, {});

test("independent steps follow the documented order, whatever order the systems arrive in", () => {
  const systems = [sys({ systemKey: "zoom" }), sys({ systemKey: "m365" }), sys({ systemKey: "adobe" }), sys({ systemKey: "knowbe4" })];
  const plan = planIn(systems, "onboard", rankOf("m365", "knowbe4", "adobe", "zoom"));
  assert.deepEqual(keys(plan), ["m365", "knowbe4", "adobe", "zoom"]);
  assert.deepEqual(plan.map((j) => j.sequence), [0, 1, 2, 3]);
  // The same systems shuffled give the same plan: the database's row order no longer leaks through.
  const again = planIn([...systems].reverse(), "onboard", rankOf("m365", "knowbe4", "adobe", "zoom"));
  assert.deepEqual(keys(again), keys(plan));
});

test("without a runbook imported the plan is unchanged (the order the systems were passed)", () => {
  const systems = [sys({ systemKey: "zoom" }), sys({ systemKey: "m365" }), sys({ systemKey: "adobe" })];
  assert.deepEqual(keys(planIn(systems, "onboard", new Map())), ["zoom", "m365", "adobe"]);
});

test("a step's dependencies are pulled in runbook order, not the order its dependsOn lists them", () => {
  // Zoom is documented first and needs both; KnowBe4 is documented ahead of Adobe.
  const systems = [sys({ systemKey: "zoom", dependsOn: ["adobe", "knowbe4"] }), sys({ systemKey: "adobe" }), sys({ systemKey: "knowbe4" })];
  assert.deepEqual(keys(planIn(systems, "onboard", rankOf("zoom", "knowbe4", "adobe"))), ["knowbe4", "adobe", "zoom"]);
});

test("the re-plan puts the client's systems in runbook order too", async () => {
  const src = await import("node:fs").then((fs) => fs.readFileSync(new URL("./replan-service.ts", import.meta.url), "utf8"));
  assert.match(src, /info\.client\.systems = inDocumentedOrder\(info\.client\.systems, rank\)/);
  assert.match(src, /mergeInDocumentedOrder\(plannedSystems,/);
});

test("a dependency still wins over the documented order", () => {
  // The runbook lists Adobe first, but Adobe needs the M365 account to exist.
  const systems = [sys({ systemKey: "m365" }), sys({ systemKey: "adobe", dependsOn: ["m365"] }), sys({ systemKey: "zoom" })];
  const plan = planIn(systems, "onboard", rankOf("adobe", "zoom", "m365"));
  const at = (k: string) => keys(plan).indexOf(k);
  assert.ok(at("m365") < at("adobe"), keys(plan).join(","));
  assert.deepEqual(plan.find((j) => j.systemKey === "adobe")!.dependsOn, ["m365"]);
});

test("the closing step stays last even if the runbook lists it earlier", () => {
  const systems = [sys({ systemKey: "case-resolution", mode: "manual" }), sys({ systemKey: "m365" }), sys({ systemKey: "zoom" })];
  const plan = planIn(systems, "onboard", rankOf("case-resolution", "zoom", "m365"));
  assert.deepEqual(keys(plan), ["zoom", "m365", "case-resolution"]);
});

test("the offboard mailbox-before-licence rule still holds against the documented order", () => {
  const systems = [sys({ systemKey: "m365" }), sys({ systemKey: "exchange", dependsOn: ["m365"] }), sys({ systemKey: "zoom" })];
  const plan = planIn(systems, "offboard", rankOf("m365", "zoom", "exchange"));
  const at = (k: string) => keys(plan).indexOf(k);
  assert.ok(at("exchange") < at("m365"), keys(plan).join(","));
});

test("steps the runbook doesn't document come after the documented ones, unless a documented one needs them", () => {
  // ad-email-writeback / ad-consistency-check are synthetic (no runbook section); duo isn't in this
  // runbook either, but the documented m365 depends on it, so it's pulled forward.
  const systems = [
    sys({ systemKey: "active-directory" }), sys({ systemKey: "directory-sync", dependsOn: ["active-directory"] }),
    sys({ systemKey: "duo" }), sys({ systemKey: "m365", dependsOn: ["directory-sync", "duo"] }),
    sys({ systemKey: "sentinelone", dependsOn: ["duo"] }), sys({ systemKey: "zoom" }), sys({ systemKey: "adobe" }),
  ];
  const plan = planIn(systems, "onboard", rankOf("active-directory", "directory-sync", "m365", "zoom", "adobe"));
  assert.deepEqual(keys(plan), [
    "active-directory", "directory-sync", "duo", "m365", "zoom", "adobe", "sentinelone", "ad-email-writeback", "ad-consistency-check",
  ]);
});

test("documentedRank takes a system's first section and ignores unmapped ones", () => {
  const r = documentedRank([
    { systemKey: "m365", seq: 2 }, { systemKey: null, seq: 3 }, { systemKey: "zoom", seq: 4 }, { systemKey: "m365", seq: 7 },
  ]);
  assert.deepEqual([...r], [["m365", 2], ["zoom", 4]]);
});

test("unmodeled checklist steps go where the runbook lists them, and sequences are renumbered", () => {
  const planned = planIn([sys({ systemKey: "m365" }), sys({ systemKey: "zoom" }), sys({ systemKey: "case-resolution", mode: "manual" })],
    "onboard", new Map([["m365", 1], ["zoom", 4], ["case-resolution", 9]]));
  const extra = unmodeledManualSteps([
    { title: "Visual Studio", steps: [], guess: null, seq: 10 }, // documented after the closing step
    { title: "Dropsuite", steps: [], guess: null, seq: 2 },
    { title: "Box", steps: [], guess: null, seq: 3 },
    { title: "Verizon", steps: [], guess: null }, // no position known: last, as before
  ], planned.length);
  const merged = mergeInDocumentedOrder(planned, extra, new Map([["m365", 1], ["zoom", 4], ["case-resolution", 9]]));
  assert.deepEqual(keys(merged), [
    "m365", "unmodeled:dropsuite", "unmodeled:box", "zoom", "case-resolution", "unmodeled:visual-studio", "unmodeled:verizon",
  ]);
  assert.deepEqual(merged.map((j) => j.sequence), [0, 1, 2, 3, 4, 5, 6]);
});

test("the planning service plans a case in runbook order (systems returned out of order)", async () => {
  let jobs: PlannedJob[] = [];
  const s = (over: Record<string, unknown>) => ({
    id: "s", clientId: "c1", mode: "api", onboardWhen: "always", offboardWhen: "never",
    dependsOn: [], requiresApproval: false, captureEvidence: false, secretNames: [], config: null, ...over,
  });
  const repo = {
    unmodeledSections: async () => [{ title: "Dropsuite", steps: ["Add the user"], guess: null, seq: 2 }],
    documentedSections: async () => [{ systemKey: "m365", seq: 1 }, { systemKey: "knowbe4", seq: 3 }, { systemKey: "zoom", seq: 4 }],
    clientForPlanning: async () => ({
      id: "c1", name: "Acme", slug: "acme", emailDomain: "acme.com", primaryDomain: "acme.com",
      identity: { usernamePatterns: ["{first}.{last}@{domain}"] },
      systems: [s({ systemKey: "zoom" }), s({ systemKey: "knowbe4" }), s({ systemKey: "m365" })],
    }),
    createCaseWithJobs: async (_i: unknown, _c: string, planned: PlannedJob[]) => { jobs = planned; return "case1"; },
    setHold: async () => {},
    writeAudit: async () => {},
  } as unknown as CaseRepository;
  await createAndPlanCase(repo, { clientSlug: "acme", action: "onboard", payload: { firstName: "Jane", lastName: "Doe" } }, "tester");
  assert.deepEqual(keys(jobs), ["m365", "unmodeled:dropsuite", "knowbe4", "zoom"]);
  assert.deepEqual(jobs.map((j) => j.sequence), [0, 1, 2, 3]);
});
