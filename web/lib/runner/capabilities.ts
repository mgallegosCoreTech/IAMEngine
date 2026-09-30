// Agent on-prem capabilities: which ALWAYS_ON_PREM system keys a runner host can actually execute (its
// host-specific Coretelligent module loaded). The runner reports them each heartbeat; the claim gate and
// the run-report reason use them so an incapable agent (e.g. a DC missing the ActiveDirectory/RSAT
// module) never gets dispatched an on-prem job it would hard-fail — it stays pending with a clear reason.
import { ALWAYS_ON_PREM_SYSTEMS } from "../cases/case-secrets";

// Normalize the reported value. The runner sends a JSON-array STRING (e.g. '["active-directory"]', or
// '[]' for "none") — tolerate a raw array or a bare scalar too. Returns the reported keys, or NULL when
// nothing was reported (a legacy pre-1.31 runner). NULL means "unknown → treat as capable" so routing is
// unchanged until a runner actually reports; [] is distinct and means "reports it can run no on-prem system".
export function parseCapabilities(v: unknown): string[] | null {
  if (v == null) return null;
  let arr: unknown[] | null;
  if (Array.isArray(v)) {
    arr = v;
  } else if (typeof v === "string") {
    const s = v.trim();
    if (!s) return null; // "" — not reported
    if (s.startsWith("[")) {
      try {
        const p: unknown = JSON.parse(s);
        arr = Array.isArray(p) ? p : null;
      } catch {
        arr = []; // malformed array string — reported, but nothing usable
      }
    } else {
      arr = [s]; // a single scalar key
    }
  } else {
    arr = null;
  }
  if (arr == null) return null;
  return arr.filter((x): x is string => typeof x === "string");
}

// The reported CAPABILITY that a given on-prem systemKey actually needs. Usually the key itself, but
// some steps ride another module: `ad-email-writeback` runs on the ActiveDirectory module (writes the
// `mail` attribute), so an agent that can run "active-directory" can run it too — no separate capability
// to report. Keeps a runner from having to advertise a new cap for the write-back step.
function capabilityKey(systemKey: string): string {
  return systemKey === "ad-email-writeback" || systemKey === "ad-phone-writeback" || systemKey === "ad-consistency-check" || systemKey === "ad-hard-match" || systemKey === "ad-password-reset" ? "active-directory" : systemKey;
}

// Can this agent claim/run a job for `systemKey`? Non-on-prem systems are always runnable here (the
// separate central-vs-client scope rule still applies). An on-prem system requires the agent to REPORT
// the needed capability; a legacy agent (caps === null) is treated as capable so rollout doesn't strand jobs.
export function agentCanRun(systemKey: string, caps: string[] | null): boolean {
  if (!ALWAYS_ON_PREM_SYSTEMS.includes(systemKey)) return true;
  if (caps === null) return true; // legacy runner — don't block during rollout
  return caps.includes(capabilityKey(systemKey));
}

// The on-prem system keys to WITHHOLD from a client agent's claim query given its reported caps. Legacy
// (null) withholds nothing (old behavior); a reporting agent withholds every on-prem key whose needed
// capability it didn't list.
export function onPremExclusions(caps: string[] | null): string[] {
  if (caps === null) return [];
  return ALWAYS_ON_PREM_SYSTEMS.filter((k) => !caps.includes(capabilityKey(k)));
}

// Browser-automation is a CROSS-CUTTING capability (not an on-prem system): a runner reports the
// "browser" capability only when the Node/Playwright sidecar is installed (Test-CtgBrowserAvailable).
// These systemKeys need a real headless browser, so they're withheld from any agent — central OR
// client — that doesn't report it. Unlike the on-prem gate, a legacy/non-reporting agent (caps null)
// is ALSO withheld: it definitionally lacks the (newer) browser harness, and these keys are new, so
// no rollout is stranded. Extend this set when a new browser flow is added.
export const BROWSER_SYSTEMS = ["spanning-force-sync", "entra-devicecode", "google-oauth-signin", "google-dwd-grant", "mimecast-console-setup", "spanning-console-setup", "zoom-console-setup", "adobe-console-setup", "slack-console-setup", "egnyte-console-setup", "knowbe4-console-setup"];

// The browser system keys to WITHHOLD from an agent's claim query: none if it reports "browser", else all.
export function browserExclusions(caps: string[] | null): string[] {
  if (caps && caps.includes("browser")) return [];
  return BROWSER_SYSTEMS;
}
