// FR #0000211: an offboarding's mailbox delegates can be given Full Access WITH AutoMapping (the
// leaver's mailbox appears in their Outlook on its own, as it always did) or WITHOUT it (access only;
// they open it by hand). Applies to both delegate grants on the exchange step: the client's manager
// delegate (delegateManagerFullAccess) and the people named on the ticket (grantFullAccessTo).
//
// Three layers, most specific wins:
//   - unset anywhere       -> on (the runner's default, so nothing changes for existing clients)
//   - the client's default -> ClientSystem(exchange).config.offboard.delegateAutoMapping, flattened onto
//                             the exchange offboard job at plan time
//   - this case's choice   -> payload.delegateAutoMapping, set from the case page; plan-resolve puts it
//                             on the exchange job over the client default, so a re-plan keeps it
// Pure: the route and the run report both use this, and it's tested without a database.

// Once the exchange step has been handed to a runner the grant may already have happened, and
// AutoMapping is fixed when access is granted — so the choice stops being editable there.
const STARTED = new Set(["dispatched", "running", "succeeded", "failed"]);

export type DelegationJob = { id?: string; systemKey: string; status: string; request: unknown };

export type Delegation = {
  delegates: string[]; // the people named on the ticket (grantFullAccessTo)
  manager: boolean; // the client grants the manager Full Access too
  autoMapping: boolean; // what the exchange step will do
  override: boolean | null; // this case's own choice, or null when it follows the client default
  clientDefault?: boolean; // filled in by loadRunReport (needs the client's exchange config)
  locked: boolean; // the exchange step has started, so it can't be changed here any more
};

const configOf = (j: DelegationJob) => (((j.request ?? {}) as { config?: unknown }).config ?? {}) as Record<string, unknown>;

// The client default stored on its exchange system (unset = on).
export function clientAutoMappingDefault(exchangeSystemConfig: unknown): boolean {
  const offboard = ((exchangeSystemConfig ?? {}) as { offboard?: { delegateAutoMapping?: unknown } | null }).offboard;
  return offboard?.delegateAutoMapping !== false;
}

// What the run report shows about this case's delegation; null when there's no delegation to decide.
export function delegationOf(action: string, jobs: DelegationJob[], payload: Record<string, unknown>): Delegation | null {
  if (action !== "offboard") return null;
  const exchange = jobs.filter((j) => j.systemKey === "exchange");
  if (exchange.length === 0) return null;
  const cfg = configOf(exchange[0]);
  const delegates = [cfg.grantFullAccessTo].flat().filter((d): d is string => typeof d === "string" && d.trim() !== "").map((d) => d.trim());
  const manager = Boolean(cfg.delegateManagerFullAccess);
  if (delegates.length === 0 && !manager) return null;
  return {
    delegates,
    manager,
    autoMapping: cfg.delegateAutoMapping !== false,
    override: typeof payload.delegateAutoMapping === "boolean" ? payload.delegateAutoMapping : null,
    locked: exchange.some((j) => STARTED.has(j.status)),
  };
}

export type AutoMappingChange =
  | { ok: true; payload: Record<string, unknown>; jobs: { id: string; config: Record<string, unknown> }[] }
  | { ok: false; error: string; status: number };

// Record a case's choice. `choice` null = go back to the client default. Writes the payload (so a
// re-plan keeps it, marked as an operator edit so a ServiceNow refresh doesn't drop it) and the
// exchange job's config directly (so it applies without a re-plan, even mid-run, while the exchange
// step itself hasn't started).
export function applyAutoMappingChoice(
  choice: boolean | null,
  payload: Record<string, unknown>,
  jobs: DelegationJob[],
  clientDefault: boolean
): AutoMappingChange {
  const exchange = jobs.filter((j) => j.systemKey === "exchange");
  if (exchange.length === 0) return { ok: false, error: "this case has no Exchange step", status: 422 };
  if (exchange.some((j) => STARTED.has(j.status))) {
    return { ok: false, error: "the Exchange step has already started, so its delegate access is already decided", status: 409 };
  }
  const next = { ...payload };
  const fieldSource = { ...((next.fieldSource ?? {}) as Record<string, string>) };
  if (choice === null) {
    delete next.delegateAutoMapping;
    delete fieldSource.delegateAutoMapping;
  } else {
    next.delegateAutoMapping = choice;
    fieldSource.delegateAutoMapping = "operator";
  }
  next.fieldSource = fieldSource;
  const value = choice ?? clientDefault;
  return {
    ok: true,
    payload: next,
    jobs: exchange.filter((j): j is DelegationJob & { id: string } => typeof j.id === "string")
      .map((j) => ({ id: j.id, config: { ...configOf(j), delegateAutoMapping: value } })),
  };
}
