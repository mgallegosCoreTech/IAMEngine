import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCapabilities, agentCanRun, onPremExclusions, browserExclusions, BROWSER_SYSTEMS } from "./capabilities";
import { ALWAYS_ON_PREM_SYSTEMS } from "../cases/case-secrets";

// The whole point of the feature hinges on parseCapabilities distinguishing "not reported" (null,
// legacy runner -> capable) from "reports none" ([] -> withhold all on-prem). These cover the wire
// formats the runner can send (JSON-array string is the real one; array/scalar are tolerated).
test("parseCapabilities: not reported -> null (legacy runner)", () => {
  assert.equal(parseCapabilities(undefined), null);
  assert.equal(parseCapabilities(null), null);
  assert.equal(parseCapabilities(""), null);
  assert.equal(parseCapabilities("   "), null);
});

test("parseCapabilities: JSON-array string (the runner's real format)", () => {
  assert.deepEqual(parseCapabilities("[]"), []); // reported "none" — distinct from null
  assert.deepEqual(parseCapabilities('["active-directory"]'), ["active-directory"]);
  assert.deepEqual(parseCapabilities('["active-directory","directory-sync"]'), ["active-directory", "directory-sync"]);
});

test("parseCapabilities: tolerates a raw array or a bare scalar", () => {
  assert.deepEqual(parseCapabilities(["active-directory"]), ["active-directory"]);
  assert.deepEqual(parseCapabilities("active-directory"), ["active-directory"]);
});

test("parseCapabilities: drops non-strings; malformed array string -> [] (reported, nothing usable)", () => {
  assert.deepEqual(parseCapabilities(["active-directory", 3, null]), ["active-directory"]);
  assert.deepEqual(parseCapabilities("[not json"), []);
});

test("agentCanRun: non-on-prem systems are always runnable here", () => {
  assert.equal(agentCanRun("m365", null), true);
  assert.equal(agentCanRun("m365", []), true);
  assert.equal(agentCanRun("mimecast", ["active-directory"]), true);
});

test("agentCanRun: on-prem requires the reported capability; legacy (null) is treated as capable", () => {
  // active-directory is the system that hard-failed in UM0029655.
  assert.equal(agentCanRun("active-directory", null), true); // legacy runner — don't strand jobs
  assert.equal(agentCanRun("active-directory", ["active-directory"]), true);
  assert.equal(agentCanRun("active-directory", ["directory-sync"]), false); // reports it can't -> withhold
  assert.equal(agentCanRun("active-directory", []), false);
});

test("onPremExclusions: legacy withholds nothing; a report withholds every unlisted on-prem key", () => {
  assert.deepEqual(onPremExclusions(null), []); // legacy — old behavior
  assert.deepEqual(onPremExclusions([...ALWAYS_ON_PREM_SYSTEMS]).sort(), []); // fully capable -> withhold nothing
  assert.deepEqual(onPremExclusions([]).sort(), [...ALWAYS_ON_PREM_SYSTEMS].sort()); // capable of none -> withhold all
  // The reported bug's shape: an agent that can do directory-sync but NOT active-directory. It also
  // can't do the AD email write-back (that rides the ActiveDirectory module).
  assert.deepEqual(onPremExclusions(["directory-sync"]), ["active-directory", "ad-email-writeback", "ad-phone-writeback", "ad-consistency-check", "ad-hard-match", "ad-password-reset"]);
});

test("ad-email-writeback rides the active-directory capability (no separate cap to report)", () => {
  // An AD-capable agent can run the write-back without advertising a new capability.
  assert.equal(agentCanRun("ad-email-writeback", ["active-directory"]), true);
  assert.equal(agentCanRun("ad-email-writeback", ["directory-sync"]), false); // can sync but not write AD
  assert.equal(agentCanRun("ad-email-writeback", null), true); // legacy — don't strand
  assert.equal(agentCanRun("ad-phone-writeback", ["active-directory"]), true); // the Teams number, written by the AD agent
  assert.equal(agentCanRun("ad-phone-writeback", ["directory-sync"]), false);
  // An AD-capable agent has the write-back NOT withheld.
  assert.equal(onPremExclusions(["active-directory"]).includes("ad-email-writeback"), false);
});

test("sanity: active-directory is in the on-prem set (guards the gate against a rename)", () => {
  assert.ok(ALWAYS_ON_PREM_SYSTEMS.includes("active-directory"));
});

test("ad-password-reset rides the active-directory capability and is on-prem", () => {
  assert.ok(ALWAYS_ON_PREM_SYSTEMS.includes("ad-password-reset"));
  assert.equal(agentCanRun("ad-password-reset", ["active-directory"]), true);
  assert.equal(agentCanRun("ad-password-reset", ["directory-sync"]), false);
  assert.equal(agentCanRun("ad-password-reset", null), true); // legacy — don't strand
  assert.equal(onPremExclusions(["active-directory"]).includes("ad-password-reset"), false);
});

test("browser gate: spanning-force-sync withheld unless the agent reports 'browser'", () => {
  assert.deepEqual(browserExclusions(["browser"]), []); // reports it -> nothing withheld
  assert.deepEqual(browserExclusions(["active-directory", "browser"]), []); // alongside on-prem caps
  assert.deepEqual(browserExclusions(["active-directory"]), BROWSER_SYSTEMS); // no browser cap -> withhold
  assert.deepEqual(browserExclusions([]), BROWSER_SYSTEMS); // reports none -> withhold
  assert.deepEqual(browserExclusions(null), BROWSER_SYSTEMS); // legacy/non-reporting -> withhold too
  assert.ok(BROWSER_SYSTEMS.includes("spanning-force-sync"));
});

test("browser systems are NOT on-prem (so the on-prem gate leaves them to the browser gate)", () => {
  // spanning-force-sync must not accidentally be treated as on-prem — otherwise the central runner,
  // which reports 'browser', could never claim it.
  assert.equal(ALWAYS_ON_PREM_SYSTEMS.includes("spanning-force-sync"), false);
});

test("browser gate: the Mimecast console key is gated on 'browser' and is not on-prem", () => {
  assert.ok(BROWSER_SYSTEMS.includes("mimecast-console-setup"));
  assert.equal(browserExclusions(["browser"]).includes("mimecast-console-setup"), false); // browser agent can claim
  assert.ok(browserExclusions(null).includes("mimecast-console-setup")); // legacy/non-browser -> withheld
  assert.equal(ALWAYS_ON_PREM_SYSTEMS.includes("mimecast-console-setup"), false); // central runner runs it
});
