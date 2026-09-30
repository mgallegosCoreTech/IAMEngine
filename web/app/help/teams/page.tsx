// In-app setup guide for Teams Phone (the `teams` system, runner/modules/Coretelligent.Teams): assign a
// Calling Plan number on onboarding, release it on offboarding. Linked from the step's errors.
import Link from "next/link";
import { Code } from "../_components/code";

export const metadata = { title: "Teams Phone setup" };

export default function TeamsPhoneSetupPage() {
  return (
    <main style={{ maxWidth: 820 }}>
      <p className="note"><Link href="/help">← Help</Link> · <Link href="/help/cloud-auth">M365 / Exchange cloud auth</Link></p>
      <h1>Teams Phone setup</h1>
      <p className="note">
        The <code>teams</code> step gives a new hire a Teams phone number once their licence reaches Teams, and
        releases it back to the tenant&rsquo;s pool when they leave. It signs in with the <b>same app as M365</b>
        {" "}(the <code>m365-admin</code> secret and its certificate), so there is no separate credential. It runs in a
        separate PowerShell process on the runner.
      </p>

      <h2>1. Give the app the Teams Administrator role</h2>
      <ol>
        <li>Entra admin center → <b>Roles &amp; admins</b> → <b>Teams Administrator</b> → <b>Add assignments</b>.</li>
        <li>Pick the app registration your <code>m365-admin</code> secret uses (search by its name or client id).</li>
      </ol>
      <p className="note">
        Without it the step fails signing in or on its first phone cmdlet with an access-denied error. The certificate
        must be on the secret as <code>CertificateBase64</code> (works on any runner) or <code>CertificateThumbprint</code>
        {" "}(Windows runners with the certificate installed).
      </p>

      <h2>2. Licences and numbers in the tenant</h2>
      <ul>
        <li>The user&rsquo;s M365 licences must include <b>Teams Phone</b> and a <b>Calling Plan</b> (for example
          {" "}&ldquo;Microsoft Teams Phone Standard&rdquo; + &ldquo;Microsoft Teams Domestic Calling Plan&rdquo;). The step waits,
          checking every 15 minutes, until Teams lists both for the user, which can take a while after the licence is assigned.</li>
        <li>The tenant needs free <b>Calling Plan</b> numbers for each office&rsquo;s area code (Teams admin center → Voice →
          Phone numbers). With none free the step says so and checks again every hour.</li>
        <li>US numbers need an emergency address. A number acquired with one uses it; otherwise set
          {" "}<code>emergencyLocationByOffice</code> below.</li>
      </ul>

      <h2>3. The client&rsquo;s Teams system</h2>
      <p>On the client page → <b>Edit systems</b> → <b>Teams Phone</b> (<code>teams</code>), onboard on request (it turns on
        when the ticket asks for an office or cell line) and offboard always. Its config:</p>
      <Code>{`{
  "onboard": {
    "phoneByAreaCode": { "Stamford": "203", "Houston": "346", "Singapore": "+65" },
    "emergencyLocationByOffice": { "Stamford": "<location id>" }
  }
}`}</Code>
      <ul>
        <li><code>phoneByAreaCode</code>: office (as the ticket names it) → area code. A 3-digit code is North American
          ({" "}<code>203</code> → numbers starting <code>+1203</code>); use <code>+</code> for anything else.</li>
        <li><code>emergencyLocationByOffice</code> (optional): office → Teams emergency location id
          {" "}(<code>Get-CsOnlineLisLocation</code>), for numbers that don&rsquo;t carry one.</li>
      </ul>

      <h2>On a case</h2>
      <ul>
        <li>The onboarding review lists <b>Teams phone number</b>. Leave it blank for the next free number for the office, or
          enter a specific one. The step never replaces a number the user already has.</li>
        <li>The number the step assigned is in its results (and the case notes). On an AD-synced client an
          {" "}<code>ad-phone-writeback</code> step then writes it to AD <code>telephoneNumber</code>.</li>
        <li>On an offboarding the number is released before the licence comes off, and the step records which one it was.</li>
      </ul>

      <h2>Runner host</h2>
      <p className="note">
        The step needs the <code>MicrosoftTeams</code> PowerShell module. If the runner host doesn&rsquo;t have it, the step
        installs it for the runner&rsquo;s account on first use.
      </p>
    </main>
  );
}
