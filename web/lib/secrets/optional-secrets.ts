// WHICH secrets are optional. A leaf module (no imports) so both the wiring panel and the job/conn-test
// brokering can read it without an import cycle.
//
// An OPTIONAL secret backs ONE extra capability of a system, which most clients never wire and which
// must never be required to run that system's ordinary jobs.
//
// THE INVARIANT, learned the hard way: every name in a job's `request.secretNames` is REQUIRED —
//   - the claim gate skips any job with an unreferenced secret (missingRequiredSecrets, runner-service)
//   - the runner then brokers every listed name unconditionally, and a 404 fails the job
//   - readiness/run-report read the same list to decide "credential not set"
// so an optional secret listed there does NOT degrade gracefully: it makes the step UNCLAIMABLE for
// every client that hasn't wired it. (Attaching `spanning-portal` to the Spanning licensing lanes
// would have stalled backup licensing for the entire Spanning fleet.)
//
// Hence: an optional secret is attached ONLY to the specific job that needs it, ONLY when the client
// has actually wired it (see wiredOptionalSecrets), and on a connection test it lives in its own
// `optionalSecretNames` list so that failing to resolve it can't fail the test.
export const OPTIONAL_SECRETS: Record<string, string[]> = {
  // Spanning's force-sync signs in to the Spanning ADMIN CONSOLE, which is Microsoft 365 SSO — an
  // interactive M365 admin login, NOT the API credential (the runner refuses API-shaped creds at a
  // Microsoft sign-in box: they cannot authenticate, and repeated attempts walk a real admin account
  // toward smart lockout). Licensing — onboard AND offboard — is pure API and never needs this; only
  // the ad-hoc force-sync does. A client without it keeps working and simply can't force a sync.
  spanning: ["spanning-portal"],
  // ad-dc is OPTIONAL for the on-prem Active Directory systems. On a domain controller — where the
  // agent almost always runs — the runner authenticates as its own ambient SYSTEM identity (the
  // directory's SYSTEM principal, PR #69) and needs NO credential; requiring ad-dc there only breaks
  // things (a not-needed/empty ad-dc fails the up-front broker before the runner even runs). A wired
  // ad-dc is still attached and used as the fallback (a member-server agent that genuinely needs it).
  "active-directory": ["ad-dc"],
  "directory-sync": ["ad-dc"],
  "ad-email-writeback": ["ad-dc"],
  "ad-phone-writeback": ["ad-dc"],
  "ad-consistency-check": ["ad-dc"],
  "ad-hard-match": ["ad-dc"],
  "ad-password-reset": ["ad-dc"],
};

export const ALL_OPTIONAL_SECRET_NAMES: ReadonlySet<string> = new Set(Object.values(OPTIONAL_SECRETS).flat());

export function isOptionalSecret(name: string): boolean {
  return ALL_OPTIONAL_SECRET_NAMES.has(name);
}
