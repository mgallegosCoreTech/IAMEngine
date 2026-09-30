import { test } from "node:test";
import assert from "node:assert/strict";
import type { ClientSystem } from "@prisma/client";
import { applyAutoMappingChoice, clientAutoMappingDefault, delegationOf, type DelegationJob } from "./delegate-automapping";
import { resolvePlannedConfigs } from "../profiles/plan-resolve";
import { planCase, type PlannedJob } from "../orchestrator";
import { previewExchange } from "../automation/exchange-preview";

// FR #0000211: offboarding mailbox delegates with or without AutoMapping. A client default, a per-case
// override, and on when neither is set (what every grant did before).

const exchangeJob = (config: Record<string, unknown>, status = "pending", id = "j1"): DelegationJob =>
  ({ id, systemKey: "exchange", status, request: { config } });
const exchangeSystem = (offboard: Record<string, unknown>) => ({
  id: "s", clientId: "c", systemKey: "exchange", mode: "api", onboardWhen: "never", offboardWhen: "always",
  dependsOn: [], requiresApproval: false, captureEvidence: false, secretNames: [], config: { offboard },
}) as unknown as ClientSystem;
const planned = (config: Record<string, unknown>): PlannedJob =>
  ({ systemKey: "exchange", sequence: 0, mode: "api", requiresApproval: false, captureEvidence: false, intent: null, secretNames: [], dependsOn: [], config });
const exCfg = (jobs: PlannedJob[]) => jobs.find((j) => j.systemKey === "exchange")!.config as Record<string, unknown>;

test("the client default: unset is on, only an explicit false turns it off", () => {
  assert.equal(clientAutoMappingDefault(null), true);
  assert.equal(clientAutoMappingDefault({ offboard: { convertToShared: {} } }), true);
  assert.equal(clientAutoMappingDefault({ offboard: { delegateAutoMapping: false } }), false);
  assert.equal(clientAutoMappingDefault({ offboard: { delegateAutoMapping: true } }), true);
});

test("the client default reaches the exchange offboard job through the plan", () => {
  const off = planCase([exchangeSystem({ delegateManagerFullAccess: true, delegateAutoMapping: false })], "offboard", {});
  assert.equal(exCfg(off).delegateAutoMapping, false);
  const unset = planCase([exchangeSystem({ delegateManagerFullAccess: true })], "offboard", {});
  assert.equal(exCfg(unset).delegateAutoMapping, undefined); // the runner reads unset as on
});

test("the case's choice overrides the client default at plan time, either way", () => {
  const offByCase = resolvePlannedConfigs({}, { provideMailboxAccessTo: "Peter Hegland", delegateAutoMapping: false }, "offboard", [planned({})]);
  assert.equal(exCfg(offByCase).delegateAutoMapping, false);
  assert.equal(exCfg(offByCase).grantFullAccessTo, "Peter Hegland");
  const onByCase = resolvePlannedConfigs({}, { delegateAutoMapping: true }, "offboard", [planned({ delegateAutoMapping: false })]);
  assert.equal(exCfg(onByCase).delegateAutoMapping, true);
  // No case choice: the client default on the job is left alone.
  const none = resolvePlannedConfigs({}, {}, "offboard", [planned({ delegateAutoMapping: false })]);
  assert.equal(exCfg(none).delegateAutoMapping, false);
});

test("the run report shows the delegation only on an offboard that delegates someone", () => {
  assert.equal(delegationOf("onboard", [exchangeJob({ grantFullAccessTo: "Peter" })], {}), null);
  assert.equal(delegationOf("offboard", [exchangeJob({})], {}), null);
  assert.equal(delegationOf("offboard", [], {}), null);
  const d = delegationOf("offboard", [exchangeJob({ grantFullAccessTo: ["Peter", " ", "Dana"], delegateManagerFullAccess: true, delegateAutoMapping: false })], { delegateAutoMapping: false });
  assert.deepEqual(d, { delegates: ["Peter", "Dana"], manager: true, autoMapping: false, override: false, locked: false });
  assert.equal(delegationOf("offboard", [exchangeJob({ delegateManagerFullAccess: true })], {})!.autoMapping, true);
  assert.equal(delegationOf("offboard", [exchangeJob({ delegateManagerFullAccess: true }, "succeeded")], {})!.locked, true);
});

test("a case choice writes the payload (kept on re-plan) and the exchange job (applies now)", () => {
  const payload = { userToOffboard: "Matt", fieldSource: { userToOffboard: "operator" } };
  const r = applyAutoMappingChoice(false, payload, [exchangeJob({ grantFullAccessTo: "Peter" })], true);
  assert.ok(r.ok);
  assert.equal(r.payload.delegateAutoMapping, false);
  // Marked as an operator edit, so a ServiceNow refresh on re-plan (mergeOperatorEdits) keeps it.
  assert.deepEqual(r.payload.fieldSource, { userToOffboard: "operator", delegateAutoMapping: "operator" });
  assert.deepEqual(r.jobs, [{ id: "j1", config: { grantFullAccessTo: "Peter", delegateAutoMapping: false } }]);
  assert.equal((payload as Record<string, unknown>).delegateAutoMapping, undefined); // input not mutated
});

test("going back to the client default clears the case's choice and applies the default", () => {
  const r = applyAutoMappingChoice(null, { delegateAutoMapping: true, fieldSource: { delegateAutoMapping: "operator" } }, [exchangeJob({ delegateAutoMapping: true })], false);
  assert.ok(r.ok);
  assert.equal("delegateAutoMapping" in r.payload, false);
  assert.deepEqual(r.payload.fieldSource, {});
  assert.equal(r.jobs[0].config.delegateAutoMapping, false);
});

test("refused once the exchange step has started, or when there is none", () => {
  for (const status of ["dispatched", "running", "succeeded", "failed"]) {
    const r = applyAutoMappingChoice(false, {}, [exchangeJob({}, status)], true);
    assert.equal(r.ok, false, status);
    if (!r.ok) assert.equal(r.status, 409);
  }
  const none = applyAutoMappingChoice(false, {}, [], true);
  assert.equal(none.ok, false);
  // Not started yet: fine.
  for (const status of ["pending", "manual", "skipped"]) assert.equal(applyAutoMappingChoice(false, {}, [exchangeJob({}, status)], true).ok, true, status);
});

test("the Exchange preview shows the AutoMapping choice", () => {
  const on = previewExchange("offboard", { delegateManagerFullAccess: true, grantFullAccessTo: "Peter" }, null, "x.com");
  assert.equal((on.match(/-AutoMapping:\$true/g) ?? []).length, 2);
  const off = previewExchange("offboard", { delegateManagerFullAccess: true, grantFullAccessTo: "Peter", delegateAutoMapping: false }, null, "x.com");
  assert.equal((off.match(/-AutoMapping:\$false/g) ?? []).length, 2);
  assert.doesNotMatch(off, /-AutoMapping:\$true/);
  assert.match(off, /not added to their Outlook/);
});
