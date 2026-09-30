// Teams Phone (runner/modules/Coretelligent.Teams): the plan-time half. The runner assigns the number;
// the app decides WHICH one it should be (the office's area code, or a number an operator entered on
// the case) and afterwards hands the assigned number on to the AD write-back. Pure — tested without a
// database.
import { jobResultEnvelope } from "../jobs/job-result";

export type TeamsOnboardConfig = {
  // Profile config: office -> area code ("Stamford": "203", "Singapore": "+65").
  phoneByAreaCode?: Record<string, string> | null;
  // Optional office -> Teams emergency location id, for numbers that don't carry one of their own.
  emergencyLocationByOffice?: Record<string, string> | null;
  numberType?: string | null;
  // Resolved here for the runner:
  office?: string | null;
  areaCode?: string | null;
  emergencyLocationId?: string | null;
  phoneNumber?: string | null;
};

// The map entry for an office. Exact (ignoring case) first; else the longest key the office name
// contains, so "Stamford, CT" and "Stamford Office" still find "Stamford". null when nothing matches.
export function officeEntry(map: Record<string, string> | null | undefined, office: unknown): { office: string; value: string } | null {
  if (!map || typeof office !== "string" || !office.trim()) return null;
  const o = office.trim().toLowerCase();
  const entries = Object.entries(map).filter(([k, v]) => k.trim() && typeof v === "string" && v.trim());
  const exact = entries.find(([k]) => k.trim().toLowerCase() === o);
  if (exact) return { office: exact[0], value: exact[1].trim() };
  const contained = entries.filter(([k]) => o.includes(k.trim().toLowerCase())).sort((a, b) => b[0].length - a[0].length)[0];
  return contained ? { office: contained[0], value: contained[1].trim() } : null;
}

// The teams onboard job's config with the runner's inputs filled in from the case. The number an
// operator entered on the case (payload.teamsPhoneNumber) wins over the area-code pick.
export function resolveTeamsOnboardConfig(config: unknown, payload: Record<string, unknown>): TeamsOnboardConfig {
  const cfg = ((config ?? {}) as TeamsOnboardConfig);
  const office = typeof payload.officeLocation === "string" && payload.officeLocation.trim() ? payload.officeLocation.trim() : null;
  const area = officeEntry(cfg.phoneByAreaCode, office);
  const location = officeEntry(cfg.emergencyLocationByOffice, office);
  const typed = typeof payload.teamsPhoneNumber === "string" && payload.teamsPhoneNumber.trim() ? payload.teamsPhoneNumber.trim() : null;
  return {
    ...cfg,
    office,
    areaCode: area?.value ?? cfg.areaCode ?? null,
    ...(location ? { emergencyLocationId: location.value } : {}),
    phoneNumber: typed ?? cfg.phoneNumber ?? null,
  };
}

// The number a succeeded teams onboard step assigned (its result's PhoneNumber), or null.
export function teamsPhoneNumberOf(result: unknown): string | null {
  const r = jobResultEnvelope(result) as { PhoneNumber?: unknown; phoneNumber?: unknown } | null;
  const n = r?.PhoneNumber ?? r?.phoneNumber;
  return typeof n === "string" && n.trim() ? n.trim() : null;
}
