// Renders the Exchange Online (EXO V3) cmdlets Coretelligent.Exchange intends to run (mirrors
// runner/modules/Coretelligent.Exchange — offboard only). Pure string templating; no side effects.
import { resolveUpn, type PreviewUser } from "./preview-helpers";

type ExchangeConfig = {
  convertToShared?: { skipIfMailboxOverGB?: number } | null;
  autoReply?: { message?: string } | null;
  forwarding?: { address?: string; keepCopy?: boolean } | null;
  blockMobileDevices?: boolean;
  // Profile-static: grant the MANAGER Full Access (true = case's manager; string = explicit address).
  delegateManagerFullAccess?: boolean | string | null;
  // Case-requested delegate from the intake ("Enable delegate: … access to <person>") — FR #7.
  grantFullAccessTo?: string | null;
  // FR #0000211: false = delegates get Full Access WITHOUT the mailbox being added to their Outlook.
  delegateAutoMapping?: boolean | null;
};

type ExchangeOnboardConfig = {
  enableRemoteMailbox?: { routingDomain?: string; emailAddressPolicyEnabled?: boolean } | null;
  regional?: { language?: string; timezone?: string; defaultTimezone?: string } | null;
  calendar?: { grantManagerReviewer?: boolean } | null;
  waitForSync?: boolean;
};

export function previewExchange(action: "onboard" | "offboard", config: unknown, _identity: unknown, _domain: string, user?: PreviewUser): string {
  if (action === "onboard") return onboard((config ?? {}) as ExchangeOnboardConfig, user);
  const cfg = (config ?? {}) as ExchangeConfig;
  const lines = [
    "# --- variables (resolved from the UM case) ---",
    `$Upn = "${resolveUpn(user)}"`,
    "",
    "# --- intended automation (Coretelligent.Exchange — runs BEFORE the m365 license removal) ---",
    "# mailbox size drives the keep-license threshold",
    `$SizeGB = Get-CtgMailboxSizeGB -Identity $Upn`,
  ];
  if (cfg.convertToShared) {
    const t = cfg.convertToShared.skipIfMailboxOverGB ?? 50;
    lines.push("", `# convert to shared unless over ${t} GB (then keep it a licensed user mailbox)`, `if ($SizeGB -le ${t}) { Set-Mailbox -Identity $Upn -Type Shared }`);
  }
  const autoMap = cfg.delegateAutoMapping !== false;
  const mapNote = autoMap ? "AutoMapping adds it to their Outlook" : "AutoMapping off: not added to their Outlook";
  if (cfg.delegateManagerFullAccess) {
    const who = typeof cfg.delegateManagerFullAccess === "string" ? `"${cfg.delegateManagerFullAccess}"` : "$ManagerEmail  # the case's manager";
    lines.push("", `# grant the manager Full Access (retrieve mail; ${mapNote})`, `Add-MailboxPermission -Identity $Upn -User ${who} -AccessRights FullAccess -AutoMapping:$${autoMap}`);
  }
  if (cfg.grantFullAccessTo) lines.push("", `# grant the CASE-REQUESTED delegate Full Access (name resolved to a mailbox at run time; ${mapNote})`, `Add-MailboxPermission -Identity $Upn -User "${cfg.grantFullAccessTo}" -AccessRights FullAccess -AutoMapping:$${autoMap}`);
  if (cfg.autoReply?.message) lines.push("", "# set out-of-office", `Set-MailboxAutoReplyConfiguration -Identity $Upn -AutoReplyState Enabled -InternalMessage "${cfg.autoReply.message}" -ExternalMessage "${cfg.autoReply.message}"`);
  if (cfg.forwarding?.address) lines.push("", "# forwarding", `Set-Mailbox -Identity $Upn -ForwardingSmtpAddress "${cfg.forwarding.address}" -DeliverToMailboxAndForward:$${cfg.forwarding.keepCopy ? "true" : "false"}`);
  if (cfg.blockMobileDevices !== false) lines.push("", "# block ActiveSync + OWA", `Set-CASMailbox -Identity $Upn -ActiveSyncEnabled $false -OWAEnabled $false`);
  return lines.join("\n");
}

// Hybrid onboard (mirrors Invoke-CtgExchangeHybridOnboard): enable the on-prem remote mailbox so
// AAD Connect provisions an EXO mailbox, wait for it to land, then finish regional + calendar.
function onboard(cfg: ExchangeOnboardConfig, user?: PreviewUser): string {
  if (!cfg.enableRemoteMailbox) return "# No remote-mailbox config — Exchange onboard step is skipped for this client.";
  const routing = cfg.enableRemoteMailbox.routingDomain ?? "<tenant>.mail.onmicrosoft.com";
  const sam = user && "samAccountName" in user ? String((user as Record<string, unknown>).samAccountName ?? "<sam>") : "<sam>";
  const lines = [
    "# --- variables (resolved from the case) ---",
    `$Sam   = "${sam}"`,
    `$Smtp  = "${resolveUpn(user)}"`,
    `$Route = "$Sam@${routing}"`,
    "",
    "# --- intended automation (Coretelligent.Exchange hybrid onboard, ON-PREM Exchange session) ---",
    "# 1. enable the remote mailbox (skips if already remote-enabled)",
    `Enable-RemoteMailbox -Identity $Sam -RemoteRoutingAddress $Route -PrimarySmtpAddress $Smtp`,
  ];
  if (cfg.enableRemoteMailbox.emailAddressPolicyEnabled !== false) lines.push(`Set-RemoteMailbox -Identity $Sam -EmailAddressPolicyEnabled $true`);
  if (cfg.waitForSync !== false) lines.push("", "# 2. wait for AAD Connect to sync the mailbox into Exchange Online (bounded poll)", `Wait-CtgMailbox -Identity $Sam`);
  if (cfg.regional) {
    const tz = cfg.regional.timezone && !/\{/.test(cfg.regional.timezone) ? cfg.regional.timezone : (cfg.regional.defaultTimezone ?? "Eastern Standard Time");
    lines.push("", "# 3. regional config (EXO)", `Set-MailboxRegionalConfiguration -Identity $Sam -Language "${cfg.regional.language ?? "en-us"}" -TimeZone "${tz}"`);
  }
  if (cfg.calendar?.grantManagerReviewer) lines.push("", "# grant the manager Reviewer on the calendar", `Add-MailboxFolderPermission -Identity "${"${Sam}"}:\\Calendar" -User $ManagerEmail -AccessRights Reviewer`);
  return lines.join("\n");
}
