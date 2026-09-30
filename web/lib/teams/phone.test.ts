import { test } from "node:test";
import assert from "node:assert/strict";
import type { ClientSystem } from "@prisma/client";
import { officeEntry, resolveTeamsOnboardConfig, teamsPhoneNumberOf } from "./phone";
import { planCase, type PlannedJob } from "../orchestrator";
import { resolvePlannedConfigs } from "../profiles/plan-resolve";
import { automationPreview, hasExecutor, validationChecks } from "../automation";

// Teams Phone (runner/modules/Coretelligent.Teams): the app decides which number, the runner assigns it.

const AREA = { Stamford: "203", Houston: "346", Singapore: "+65" };

test("an office finds its area code exactly, ignoring case, or by the office name containing it", () => {
  assert.deepEqual(officeEntry(AREA, "Stamford"), { office: "Stamford", value: "203" });
  assert.deepEqual(officeEntry(AREA, "houston"), { office: "Houston", value: "346" });
  assert.deepEqual(officeEntry(AREA, "Singapore Office"), { office: "Singapore", value: "+65" });
  assert.equal(officeEntry(AREA, "Denver"), null);
  assert.equal(officeEntry(AREA, ""), null);
  assert.equal(officeEntry(null, "Stamford"), null);
  // The longest match wins, so "New York" doesn't lose to a shorter key it also contains.
  assert.equal(officeEntry({ York: "717", "New York": "212" }, "New York City")!.value, "212");
});

test("the teams onboard config gets the office's area code, emergency location and any typed number", () => {
  const cfg = { phoneByAreaCode: AREA, emergencyLocationByOffice: { Stamford: "loc-1" } };
  const r = resolveTeamsOnboardConfig(cfg, { officeLocation: "Stamford" });
  assert.equal(r.areaCode, "203");
  assert.equal(r.office, "Stamford");
  assert.equal(r.emergencyLocationId, "loc-1");
  assert.equal(r.phoneNumber, null);
  assert.deepEqual(r.phoneByAreaCode, AREA); // the profile config is kept
  const typed = resolveTeamsOnboardConfig(cfg, { officeLocation: "Houston", teamsPhoneNumber: " (346) 555-0100 " });
  assert.equal(typed.phoneNumber, "(346) 555-0100");
  assert.equal(typed.areaCode, "346");
  assert.equal("emergencyLocationId" in typed, false);
  const unknownOffice = resolveTeamsOnboardConfig(cfg, { officeLocation: "Denver" });
  assert.equal(unknownOffice.areaCode, null);
});

test("the assigned number is read off the teams result", () => {
  assert.equal(teamsPhoneNumberOf({ PhoneNumber: "+12035550120", Actions: [] }), "+12035550120");
  assert.equal(teamsPhoneNumberOf({ phoneNumber: "+12035550120" }), "+12035550120");
  assert.equal(teamsPhoneNumberOf({ PhoneNumber: null, RetryAfterMinutes: 15 }), null);
  assert.equal(teamsPhoneNumberOf(null), null);
});

const sys = (over: Partial<ClientSystem>): ClientSystem => ({
  id: "id", clientId: "c", systemKey: "m365", mode: "api", onboardWhen: "always", offboardWhen: "always",
  dependsOn: [], requiresApproval: false, captureEvidence: false, secretNames: [], config: null, ...over,
}) as unknown as ClientSystem;
const keys = (jobs: PlannedJob[]) => jobs.map((j) => j.systemKey);
const at = (jobs: PlannedJob[], k: string) => keys(jobs).indexOf(k);

test("an AD-synced onboard with Teams writes the number back to AD, after teams", () => {
  const systems = [
    sys({ systemKey: "active-directory" }), sys({ systemKey: "directory-sync", dependsOn: ["active-directory"] }),
    sys({ systemKey: "m365", dependsOn: ["directory-sync"] }), sys({ systemKey: "teams", dependsOn: ["m365"] }),
  ];
  const plan = planCase(systems, "onboard", {});
  const wb = plan.find((j) => j.systemKey === "ad-phone-writeback");
  assert.ok(wb, keys(plan).join(","));
  assert.deepEqual(wb!.dependsOn, ["teams"]);
  assert.ok(at(plan, "teams") < at(plan, "ad-phone-writeback"));
  // Not on an offboard, not without AD, and not for a standalone-AD client.
  assert.equal(keys(planCase(systems, "offboard", {})).includes("ad-phone-writeback"), false);
  assert.equal(keys(planCase(systems.slice(2).map((s) => ({ ...s, dependsOn: [] })), "onboard", {})).includes("ad-phone-writeback"), false);
  assert.equal(keys(planCase(systems, "onboard", {}, undefined, undefined, undefined, undefined, "ad-standalone")).includes("ad-phone-writeback"), false);
});

test("an offboard releases the Teams number before the licence comes off", () => {
  // Declared the other way round, as an onboard-shaped profile would.
  const systems = [sys({ systemKey: "m365" }), sys({ systemKey: "teams", dependsOn: ["m365"] })];
  const plan = planCase(systems, "offboard", {});
  assert.ok(at(plan, "teams") < at(plan, "m365"), keys(plan).join(","));
  assert.deepEqual(plan.find((j) => j.systemKey === "m365")!.dependsOn, ["teams"]);
  assert.deepEqual(plan.find((j) => j.systemKey === "teams")!.dependsOn, []);
  // With exchange too, the licence waits for both.
  const both = planCase([...systems, sys({ systemKey: "exchange" })], "offboard", {});
  assert.deepEqual([...both.find((j) => j.systemKey === "m365")!.dependsOn].sort(), ["exchange", "teams"]);
  // The onboard order is untouched: teams still follows m365.
  const on = planCase(systems, "onboard", {});
  assert.ok(at(on, "m365") < at(on, "teams"));
});

test("Teams signs in with m365-admin, not the old teams-admin placeholder", () => {
  const [t] = planCase([sys({ systemKey: "teams", secretNames: ["teams-admin"] })], "onboard", {});
  assert.deepEqual(t.secretNames, ["m365-admin"]);
  const [kept] = planCase([sys({ systemKey: "teams", secretNames: ["m365-admin"] })], "onboard", {});
  assert.deepEqual(kept.secretNames, ["m365-admin"]);
  // A manual Teams step is left alone (a person does it, with whatever login the client listed).
  const [manual] = planCase([sys({ systemKey: "teams", mode: "manual", secretNames: ["teams-admin"] })], "onboard", {});
  assert.deepEqual(manual.secretNames, ["teams-admin"]);
});

test("plan-resolve fills the teams onboard job from the case", () => {
  const teams: PlannedJob = { systemKey: "teams", sequence: 0, mode: "api", requiresApproval: false, captureEvidence: false, intent: null, secretNames: ["m365-admin"], dependsOn: [], config: { phoneByAreaCode: AREA } };
  const [j] = resolvePlannedConfigs({}, { officeLocation: "Singapore", teamsPhoneNumber: "" }, "onboard", [teams]);
  const cfg = j.config as Record<string, unknown>;
  assert.equal(cfg.areaCode, "+65");
  assert.equal(cfg.phoneNumber, null);
  const [typed] = resolvePlannedConfigs({}, { officeLocation: "Singapore", teamsPhoneNumber: "+6561234567" }, "onboard", [teams]);
  assert.equal((typed.config as Record<string, unknown>).phoneNumber, "+6561234567");
});

test("teams has an executor, a preview and read-back checks", () => {
  assert.equal(hasExecutor("teams"), true);
  const on = automationPreview("teams", "onboard", { areaCode: "203", office: "Stamford" }, null, "x.com", { userPrincipalName: "jdoe@x.com" })!;
  assert.match(on, /\$Upn = "jdoe@x\.com"/);
  assert.match(on, /TelephoneNumber -like '\+1203\*'/);
  assert.match(on, /Set-CsPhoneNumberAssignment -Identity \$Upn -PhoneNumber \$Number -PhoneNumberType CallingPlan/);
  assert.match(automationPreview("teams", "onboard", { phoneNumber: "+12035550777" }, null, "x.com")!, /\$Number = "\+12035550777"/);
  assert.match(automationPreview("teams", "onboard", { office: "Denver" }, null, "x.com")!, /FAILS: no area code for office "Denver"/);
  assert.match(automationPreview("teams", "offboard", {}, null, "x.com")!, /Remove-CsPhoneNumberAssignment -Identity \$Upn -RemoveAll/);
  assert.equal(validationChecks("teams", "offboard").length, 1);
});
