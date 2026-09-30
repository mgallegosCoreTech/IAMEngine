import { test } from "node:test";
import assert from "node:assert/strict";
import { inheritsFromParent, inheritsParentModeling, applyParentInheritance } from "./parent-inheritance";

const parent = {
  systems: [{ systemKey: "m365" }, { systemKey: "exchange" }] as unknown[],
  identity: { usernamePatterns: ["{first}.{last}@{domain}"] },
  personas: { vet: {} }, globals: { m365: {} }, globalsOffboard: { m365: {} },
  locations: { rows: [] }, adObjects: { ous: [] }, cloudGroups: { groups: [] },
};

const emptyChild = () => ({
  systems: [] as unknown[], identity: null, personas: null, globals: null,
  globalsOffboard: null, locations: null, adObjects: null, cloudGroups: null,
});

const BOTH = { systems: true, modeling: true };

test("a child with no systems, a parent, and inheritance on DOES inherit", () => {
  assert.equal(inheritsFromParent({ systems: [], parentId: "p1", inheritParentSystems: true }), true);
});

test("a child with its own systems does NOT inherit (adding systems ends inheritance)", () => {
  assert.equal(inheritsFromParent({ systems: [{ systemKey: "m365" }], parentId: "p1", inheritParentSystems: true }), false);
});

test("a child with inheritance switched off does NOT inherit", () => {
  assert.equal(inheritsFromParent({ systems: [], parentId: "p1", inheritParentSystems: false }), false);
});

test("a top-level client never inherits", () => {
  assert.equal(inheritsFromParent({ systems: [], parentId: null, inheritParentSystems: true }), false);
});

test("systems come wholesale from the parent", () => {
  const out = applyParentInheritance(emptyChild(), parent, BOTH);
  assert.deepEqual(out.systems, parent.systems);
});

test("modeling inputs fall back INDIVIDUALLY — anything the child set still wins", () => {
  const child = { ...emptyChild(), personas: { own: {} } };
  const out = applyParentInheritance(child, parent, BOTH);
  assert.deepEqual(out.personas, { own: {} });   // child's own survives
  assert.deepEqual(out.globals, parent.globals); // unset falls back
  assert.deepEqual(out.identity, parent.identity);
});

test("a parent with no systems of its own changes nothing", () => {
  const out = applyParentInheritance(emptyChild(), { ...parent, systems: [] }, BOTH);
  assert.deepEqual(out.systems, []);
  assert.equal(out.personas, null);
});

test("a null parent changes nothing", () => {
  const child = emptyChild();
  assert.deepEqual(applyParentInheritance(child, null, BOTH), child);
});


test("modeling inheritance does NOT depend on having no systems (FR #0000041)", () => {
  // core847: five systems of its own, and its parent's four personas were unreachable.
  assert.equal(inheritsParentModeling({ parentId: "p1", inheritParentModeling: true }), true);
});

test("modeling inheritance is off when the child opted out", () => {
  assert.equal(inheritsParentModeling({ parentId: "p1", inheritParentModeling: false }), false);
});

test("a top-level client never inherits modeling", () => {
  assert.equal(inheritsParentModeling({ parentId: null, inheritParentModeling: true }), false);
});

test("modeling-only inheritance takes personas but NOT systems", () => {
  const child = { ...emptyChild(), systems: [{ systemKey: "m365" }] as unknown[] };
  const out = applyParentInheritance(child, parent, { systems: false, modeling: true });
  assert.deepEqual(out.systems, [{ systemKey: "m365" }]); // its own systems are kept
  assert.deepEqual(out.personas, parent.personas);        // the parent's personas arrive
});

test("systems-only inheritance takes systems but leaves modeling alone", () => {
  const out = applyParentInheritance(emptyChild(), parent, { systems: true, modeling: false });
  assert.deepEqual(out.systems, parent.systems);
  assert.equal(out.personas, null);
});

test("a child's OWN personas still win over the parent's", () => {
  // core860/core866 hold identical copies; they must keep using their own.
  const child = { ...emptyChild(), personas: { own: {} } };
  const out = applyParentInheritance(child, parent, BOTH);
  assert.deepEqual(out.personas, { own: {} });
});

test("an EMPTY personas object is not treated as unset", () => {
  // core2187 carries {}. Treating it as unset would hand it two personas nobody asked for.
  const child = { ...emptyChild(), personas: {} };
  const out = applyParentInheritance(child, parent, BOTH);
  assert.deepEqual(out.personas, {});
});

// M365 license rules live on the m365 SYSTEM's config, so the modeling fallback above never reached
// them: a child with its own m365 row planned with no license rules, even while following its parent.
const m365With = (licenseRules?: unknown[]) => ({
  systemKey: "m365",
  config: { onboard: { licenses: ["Defender"], ...(licenseRules ? { licenseRules } : {}) }, offboard: { keep: true } },
});
const RULES = [{ when: "needsComputer == true", licenses: ["E5"] }, { when: "", licenses: ["E1"] }];
const parentWithRules = { ...parent, systems: [m365With(RULES), { systemKey: "exchange" }] as unknown[] };
const rulesOn = (c: { systems: unknown[] }) =>
  ((c.systems.find((s) => (s as { systemKey: string }).systemKey === "m365") as { config: { onboard: { licenseRules?: unknown } } }).config.onboard.licenseRules);
const OWN = { systems: false, modeling: true };

test("license rules: a child's own m365 with none set uses the parent's, keeping its other config", () => {
  const child = { ...emptyChild(), systems: [m365With(), { systemKey: "zoom" }] as unknown[] };
  const out = applyParentInheritance(child, parentWithRules, OWN);
  assert.deepEqual(rulesOn(out), RULES);
  const cfg = (out.systems[0] as { config: { onboard: { licenses: string[] }; offboard: unknown } }).config;
  assert.deepEqual(cfg.onboard.licenses, ["Defender"]);
  assert.deepEqual(cfg.offboard, { keep: true });
  assert.equal((out.systems[1] as { systemKey: string }).systemKey, "zoom");
  // The child's row itself is untouched.
  assert.equal(rulesOn(child), undefined);
});

test("license rules: the child's own rules win, and an empty list is a deliberate none", () => {
  const own = [{ when: "", licenses: ["Business Premium"] }];
  assert.deepEqual(rulesOn(applyParentInheritance({ ...emptyChild(), systems: [m365With(own)] as unknown[] }, parentWithRules, OWN)), own);
  assert.deepEqual(rulesOn(applyParentInheritance({ ...emptyChild(), systems: [m365With([])] as unknown[] }, parentWithRules, OWN)), []);
});

test("license rules: not inherited when the child doesn't follow the parent's rules", () => {
  const child = { ...emptyChild(), systems: [m365With()] as unknown[] };
  assert.equal(rulesOn(applyParentInheritance(child, parentWithRules, { systems: false, modeling: false })), undefined);
});

test("license rules: nothing to inherit when the parent has no m365 rules, or the child has no m365", () => {
  const child = { ...emptyChild(), systems: [m365With()] as unknown[] };
  assert.equal(rulesOn(applyParentInheritance(child, { ...parent, systems: [m365With()] }, OWN)), undefined);
  const noM365 = { ...emptyChild(), systems: [{ systemKey: "zoom" }] as unknown[] };
  assert.deepEqual(applyParentInheritance(noM365, parentWithRules, OWN).systems, noM365.systems);
});

test("license rules: a child planning with the parent's systems has them already", () => {
  assert.deepEqual(rulesOn(applyParentInheritance(emptyChild(), parentWithRules, BOTH)), RULES);
});

test("license rules: an inherited rule picks the child's license at plan time", async () => {
  const { planCase } = await import("../orchestrator");
  const { resolvePlannedConfigs } = await import("../profiles/plan-resolve");
  const row = (config: unknown) => ({ id: "s", clientId: "c", systemKey: "m365", mode: "api", onboardWhen: "always", offboardWhen: "never",
    dependsOn: [], requiresApproval: false, captureEvidence: false, secretNames: [], config });
  const child = applyParentInheritance({ ...emptyChild(), systems: [row({ onboard: { licenses: [] } })] as unknown[] },
    { ...parent, globals: null, personas: null, systems: [row({ onboard: { licenses: [], licenseRules: RULES } })] as unknown[] }, OWN);
  for (const [needsComputer, want] of [[true, ["E5"]], [false, ["E1"]]] as const) {
    const payload = { firstName: "Jane", lastName: "Doe", needsComputer };
    const jobs = resolvePlannedConfigs(child as never, payload, "onboard", planCase(child.systems as never, "onboard", payload));
    assert.deepEqual((jobs.find((j) => j.systemKey === "m365")!.config as { licenses: string[] }).licenses, [...want]);
  }
});
