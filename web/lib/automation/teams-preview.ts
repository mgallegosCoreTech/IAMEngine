// Renders the MicrosoftTeams cmdlets Coretelligent.Teams intends to run (mirrors
// runner/modules/Coretelligent.Teams). They run in a separate pwsh process on the runner, signed in
// with the client's m365-admin app. Pure string templating; no side effects.
import { resolveUpn, type PreviewUser } from "./preview-helpers";
import type { TeamsOnboardConfig } from "../teams/phone";

// "203" -> "+1203", "+65" -> "+65" (mirrors ConvertTo-CtgTeamsAreaPrefix).
function prefixOf(area: string): string {
  const digits = area.replace(/\D/g, "");
  if (area.trim().startsWith("+")) return `+${digits}`;
  return digits.length === 3 ? `+1${digits}` : `+${digits}`;
}

export function previewTeams(action: "onboard" | "offboard", config: unknown, _identity: unknown, _domain: string, user?: PreviewUser): string {
  const cfg = (config ?? {}) as TeamsOnboardConfig;
  const upn = resolveUpn(user, "<UM case>");
  const head = [`$Upn = "${upn}"`, "", "# --- intended automation (Coretelligent.Teams — separate process, m365-admin app) ---"];
  if (action === "offboard") {
    return [
      ...head,
      "# release every number the leaver has back to the tenant's pool (recorded on the case)",
      "$numbers = Get-CsPhoneNumberAssignment -AssignedPstnTargetId $Upn",
      "if ($numbers) { Remove-CsPhoneNumberAssignment -Identity $Upn -RemoveAll }",
    ].join("\n");
  }
  const type = cfg.numberType || "CallingPlan";
  const lines = [
    ...head,
    "# idempotent: a user who already has a number keeps it",
    "if (Get-CsPhoneNumberAssignment -AssignedPstnTargetId $Upn) { return }",
    `# wait (re-checked every 15 min) until Teams lists the licence: PhoneSystem${type === "CallingPlan" ? " + CallingPlan" : ""}`,
    "(Get-CsOnlineUser -Identity $Upn).FeatureTypes",
  ];
  if (cfg.phoneNumber) {
    lines.push("", "# the number entered on the case", `$Number = "${cfg.phoneNumber}"`);
  } else if (cfg.areaCode) {
    const p = prefixOf(cfg.areaCode);
    lines.push(
      "",
      `# next free number for ${cfg.office ? `the ${cfg.office} office` : "the office"} (area code ${cfg.areaCode})`,
      `$Number = (Get-CsPhoneNumberAssignment -NumberType ${type} -PstnAssignmentStatus Unassigned -CapabilitiesContain UserAssignment |`,
      `  Where-Object TelephoneNumber -like '${p}*' | Sort-Object TelephoneNumber | Select-Object -First 1).TelephoneNumber`,
    );
  } else {
    lines.push("", `# FAILS: no area code for ${cfg.office ? `office "${cfg.office}"` : "this user's office"} — add it to phoneByAreaCode, or enter a number on the case`);
  }
  const loc = cfg.emergencyLocationId ? ` -LocationId "${cfg.emergencyLocationId}"` : "";
  lines.push("", `Set-CsPhoneNumberAssignment -Identity $Upn -PhoneNumber $Number -PhoneNumberType ${type}${loc}`, "# then: AD telephoneNumber = $Number (ad-phone-writeback), and the number in the case notes");
  return lines.join("\n");
}
