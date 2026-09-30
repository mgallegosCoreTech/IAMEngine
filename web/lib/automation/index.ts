// Registry of per-system "intended automation" code-preview templaters. Add a system by
// adding its previewer here (mirrors the generator's extractor registry). Used by the client
// page (placeholder form) and the case playbook (resolved values from the planned case).
import type { PreviewUser } from "./preview-helpers";
import { previewM365 } from "./m365-preview";
import { previewActiveDirectory } from "./active-directory-preview";
import { previewMimecast } from "./mimecast-preview";
import { previewExchange } from "./exchange-preview";
import { previewDirectorySync } from "./directory-sync-preview";
import { previewZoom } from "./zoom-preview";
import { previewAdobe } from "./adobe-preview";
import { previewPerimeter81 } from "./perimeter81-preview";
import { previewSpanning } from "./spanning-preview";
import { previewEgnyte } from "./egnyte-preview";
import { previewGoogleWorkspace } from "./google-workspace-preview";
import { previewTeams } from "./teams-preview";

export type Action = "onboard" | "offboard";
// `user` (optional) is the planned case payload; when present the preview substitutes its
// resolved identity/config values inline instead of `<UM case>` placeholders.
export type Previewer = (
  action: Action,
  config: unknown,
  identity: unknown,
  primaryDomain: string,
  user?: PreviewUser
) => string;

const PREVIEWERS: Record<string, Previewer> = {
  m365: previewM365,
  // entra is the Entra-ID slice of the M365 module (catalog moduleName = Coretelligent.M365);
  // it shares the M365 executor + read-backs so an entra job isn't left without an executor.
  entra: previewM365,
  "active-directory": previewActiveDirectory,
  mimecast: previewMimecast,
  exchange: previewExchange,
  "directory-sync": previewDirectorySync,
  zoom: previewZoom,
  adobe: previewAdobe,
  perimeter81: previewPerimeter81,
  spanning: previewSpanning,
  egnyte: previewEgnyte,
  "google-workspace": previewGoogleWorkspace,
  teams: previewTeams,
};

export function automationPreview(
  systemKey: string,
  action: Action,
  config: unknown,
  identity: unknown,
  primaryDomain: string,
  user?: PreviewUser
): string | null {
  const fn = PREVIEWERS[systemKey];
  return fn ? fn(action, config, identity, primaryDomain, user) : null;
}

// The single source of truth for "is there an executor for this system". These keys match
// the runner's DISPATCH table (runner/Start-IamRunner.ps1) exactly. A planned `api` job for
// a system not in this set has no executor: the runner (and the simulated executor) resolve
// it as `skipped` — a manual follow-up — rather than failing the case.
export const SUPPORTED_SYSTEMS = new Set(Object.keys(PREVIEWERS));

export function hasExecutor(systemKey: string): boolean {
  return SUPPORTED_SYSTEMS.has(systemKey);
}

// The read-back checks each system's Confirm-Ctg<System> validator runs after the action, by
// (systemKey, action). Surfaced in the playbook so a reviewer sees what "verified" will mean.
// Kept here next to the previewer registry so the two stay in sync.
const VALIDATES: Record<string, Record<Action, string[]>> = {
  m365: {
    onboard: ["user exists", "AccountEnabled = true", "each license assigned", "each group present"],
    offboard: ["AccountEnabled = false", "groups removed", "license removed/kept per threshold"],
  },
  entra: {
    onboard: ["user exists", "AccountEnabled = true", "each license assigned", "each group present"],
    offboard: ["AccountEnabled = false", "groups removed", "license removed/kept per threshold"],
  },
  "google-workspace": {
    onboard: ["user exists", "in target OU (not Root)", "each group present", "mail flow ok"],
    offboard: ["user suspended (not deleted)", "groups removed", "moved to Inactive OU"],
  },
  "active-directory": {
    onboard: ["user in target OU", "groups present", "home drive mapped"],
    offboard: ["account disabled", "groups removed", "hidden from GAL", "not moved (do-not-move-ou)"],
  },
  mimecast: {
    onboard: ["Mimecast user profile visible", "internal domain registered (if configured)"],
    offboard: ["removed from configured Mimecast groups"],
  },
  exchange: {
    onboard: [],
    offboard: ["mailbox shared (or kept > threshold)", "ActiveSync + OWA disabled"],
  },
  "directory-sync": {
    onboard: ["delta sync completed (no cycle in progress)"],
    offboard: ["delta sync completed (no cycle in progress)"],
  },
  zoom: {
    onboard: ["Zoom user present"],
    offboard: ["Zoom user absent / deactivated"],
  },
  adobe: {
    onboard: ["user present in product profile(s)"],
    offboard: ["user absent from the organization"],
  },
  perimeter81: {
    onboard: ["license headroom available"],
    offboard: ["Perimeter 81 user absent (seat freed)"],
  },
  spanning: {
    onboard: ["Spanning user present", "Standard backup license assigned"],
    offboard: ["backups retained (never deleted)", "Archive license (or removed, per config)"],
  },
  egnyte: {
    onboard: ["Egnyte user present + active", "license tier matches config (e.g. power)"],
    offboard: ["Egnyte user deactivated (or deleted, per config)"],
  },
  teams: {
    onboard: ["a Teams number assigned (the one entered on the case, when there is one)"],
    offboard: ["no Teams number left assigned"],
  },
};

export function validationChecks(systemKey: string, action: Action): string[] {
  return VALIDATES[systemKey]?.[action] ?? [];
}
