// Account-hierarchy inheritance, in ONE place.
//
// A child with NO modeled systems of its own plans with its PARENT's runbook (e.g. CORE2181..89 inherit
// CORE1456). Systems come wholesale from the parent; the modeling inputs fall back individually, so
// anything the child HAS set still wins. Adding systems to the child later automatically ends the
// inheritance, and a child whose inheritParentSystems was switched off never inherits.
//
// This lived only in clientForPlanning (the INITIAL plan). replanInputs (the RE-PLAN) selected the
// child's own systems and had no fallback at all, so a re-plan on such a child planned ZERO jobs — 77%
// of their re-plans, against 2% everywhere else. Nothing planned meant nothing for the requested-groups
// merge to land on, which is how a ticket's distribution groups were pulled onto the case and then added
// to nobody (FR #0000042). Extracted rather than copied precisely because the two paths already drifted
// once.
export type InheritableChild = {
  systems: unknown[];
  identity: unknown; personas: unknown; globals: unknown; globalsOffboard: unknown;
  locations: unknown; adObjects: unknown; cloudGroups: unknown;
};
export type InheritableParent = Omit<InheritableChild, "systems"> & { systems: unknown[] };

export function inheritsFromParent(child: { systems: unknown[]; parentId: string | null; inheritParentSystems: boolean }): boolean {
  return child.systems.length === 0 && !!child.parentId && child.inheritParentSystems;
}

// Roles/personas + every-user rules follow the parent INDEPENDENTLY of systems. A child may
// legitimately run its own systems while still following the parent's people rules; gating this on
// "has no systems of its own" (as the systems link is) denied a child its parent's personas the moment
// it owned a single ClientSystem row (FR #0000041).
export function inheritsParentModeling(child: { parentId: string | null; inheritParentModeling: boolean }): boolean {
  return !!child.parentId && child.inheritParentModeling;
}

export function applyParentInheritance<C extends InheritableChild>(
  child: C,
  parent: InheritableParent | null,
  opts: { systems: boolean; modeling: boolean }
): C {
  // An UNMODELED parent (no systems of its own) has nothing to lend, for EITHER kind of inheritance —
  // it is a roster-only row, not a runbook. Guarding both keeps this change strictly about the gate on
  // the CHILD, which is what FR #0000041 is about.
  if (!parent || parent.systems.length === 0) return child;
  let out = child;
  // Systems come WHOLESALE.
  if (opts.systems) out = { ...out, systems: parent.systems };
  // Modeling falls back INDIVIDUALLY, so anything the child HAS set still wins. NULL means unset; an
  // empty object is a deliberate "none" and is left exactly as it is.
  if (opts.modeling) {
    out = {
      ...out,
      identity: out.identity ?? parent.identity,
      personas: out.personas ?? parent.personas,
      globals: out.globals ?? parent.globals,
      globalsOffboard: out.globalsOffboard ?? parent.globalsOffboard,
      locations: out.locations ?? parent.locations,
      adObjects: out.adObjects ?? parent.adObjects,
      cloudGroups: out.cloudGroups ?? parent.cloudGroups,
    };
    // M365 license rules live on the m365 SYSTEM, not the client, so the fallback above never saw
    // them: a child with its own m365 row planned with no rules at all, even while it followed the
    // parent's people rules. They fall back the same way (unset -> the parent's; an empty list is a
    // deliberate "none"). A child planning with the parent's systems already has them.
    if (!opts.systems) out = { ...out, systems: withParentLicenseRules(out.systems, parent.systems) };
  }
  return out;
}

// config.onboard.licenseRules on a system row, or undefined when that system has never set any.
export function licenseRulesOf(system: unknown): unknown[] | undefined {
  const cfg = ((system as { config?: unknown } | null)?.config ?? null) as { onboard?: { licenseRules?: unknown } } | null;
  const rules = cfg?.onboard?.licenseRules;
  return Array.isArray(rules) ? rules : undefined;
}

const m365Of = (systems: unknown[]) => systems.find((s) => (s as { systemKey?: unknown } | null)?.systemKey === "m365");

// The parent's license rules a child's m365 system inherits, or null when it doesn't: it set its own
// (even an empty list), or the parent has no m365 system or no rules. The client page shows these.
export function inheritedLicenseRules(childM365: unknown, parentSystems: unknown[]): unknown[] | null {
  if (licenseRulesOf(childM365) !== undefined) return null;
  const rules = licenseRulesOf(m365Of(parentSystems));
  return rules && rules.length > 0 ? rules : null;
}

function withParentLicenseRules(systems: unknown[], parentSystems: unknown[]): unknown[] {
  const child = m365Of(systems);
  const rules = child ? inheritedLicenseRules(child, parentSystems) : null;
  if (!child || !rules) return systems;
  return systems.map((s) => {
    if (s !== child) return s;
    const cfg = ((s as { config?: unknown }).config ?? {}) as Record<string, unknown>;
    const onboard = (cfg.onboard ?? {}) as Record<string, unknown>;
    return { ...(s as object), config: { ...cfg, onboard: { ...onboard, licenseRules: rules } } };
  });
}

// The parent columns both planning paths need to read.
export const PARENT_INHERIT_SELECT = {
  identity: true, personas: true, globals: true, globalsOffboard: true,
  locations: true, systems: true, adObjects: true, cloudGroups: true,
} as const;
