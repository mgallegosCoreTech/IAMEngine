// The setup-guide index. Every /help/<slug> page is AUTO-DISCOVERED by scanning app/help/ — add a
// guide and it appears here with no edit here at all. (The Modules page answers a DIFFERENT question:
// "which systems does the platform automate, and is the executor built?" This one answers "how do I
// set this up?" — so they stay separate and cross-link.)
import Link from "next/link";
import { readdirSync } from "node:fs";
import { join } from "node:path";

export const dynamic = "force-dynamic";
export const metadata = { title: "Help" };

// Titles + grouping for the guides we know about. Anything NOT listed still shows (under "Other"),
// so a new page is never invisible — it just gets a prettified slug until someone titles it here.
const GUIDES: Record<string, { title: string; blurb: string; group: string }> = {
  "runner-troubleshooting": { title: "Runner troubleshooting", blurb: "An agent won't come online, is stuck “updating”, or gets a 401. Start here.", group: "Runners & platform" },
  "delinea-write": { title: "Creating secrets in Delinea", blurb: "Author a credential from the app: the write account, folder ids, and template map.", group: "Runners & platform" },

  "cloud-auth": { title: "Microsoft 365 / Exchange auth", blurb: "The app registration, certificate, and Graph permissions the M365 + Exchange steps need.", group: "Core identity" },
  "active-directory": { title: "Active Directory", blurb: "The service account, its OU rights, and what the on-prem agent needs.", group: "Core identity" },
  "directory-sync": { title: "Directory sync", blurb: "Entra Connect / hybrid sync — what the runner can and can't force.", group: "Core identity" },
  google: { title: "Google Workspace", blurb: "Service account + domain-wide delegation scopes.", group: "Core identity" },
  "exchange-onprem": { title: "Exchange on-prem", blurb: "Hybrid mailbox steps against an on-prem Exchange.", group: "Core identity" },
  tap: { title: "Temporary Access Pass", blurb: "Entra TAP for a passwordless first sign-in.", group: "Core identity" },
  teams: { title: "Teams Phone", blurb: "Assign and release Teams Calling Plan numbers with the m365-admin app.", group: "Core identity" },

  mimecast: { title: "Mimecast", blurb: "API 2.0 app + the permissions onboarding actually exercises.", group: "Email security" },
  proofpoint: { title: "Proofpoint Essentials", blurb: "Admin auth + the Entra/Azure sync the onboarding lane waits on.", group: "Email security" },
  spanning: { title: "Spanning Backup", blurb: "Backup licensing on onboard, archive-retain on offboard — plus the portal force-sync.", group: "Email security" },

  "1password": { title: "1Password", blurb: "SCIM vs API vs manual provisioning.", group: "Apps & access" },
  adobe: { title: "Adobe", blurb: "Adobe Admin Console user lifecycle.", group: "Apps & access" },
  egnyte: { title: "Egnyte", blurb: "User provisioning + the sync server.", group: "Apps & access" },
  hubspot: { title: "HubSpot", blurb: "Private-app token for user lifecycle.", group: "Apps & access" },
  jira: { title: "Jira", blurb: "Atlassian API token + site URL.", group: "Apps & access" },
  salesforce: { title: "Salesforce", blurb: "Connected App JWT bearer flow.", group: "Apps & access" },
  zoom: { title: "Zoom", blurb: "Server-to-server OAuth app and the scopes it needs.", group: "Apps & access" },
  perimeter81: { title: "Perimeter 81", blurb: "Network access provisioning.", group: "Apps & access" },
  xmatters: { title: "xMatters", blurb: "On-call / people provisioning.", group: "Apps & access" },

  sentinelone: { title: "SentinelOne", blurb: "API token + the role offboarding needs for agent actions.", group: "Security & endpoint" },
  knowbe4: { title: "KnowBe4", blurb: "Security-awareness training enrolment.", group: "Security & endpoint" },
  duo: { title: "Duo", blurb: "MFA enrolment / removal.", group: "Security & endpoint" },
  logicmonitor: { title: "LogicMonitor", blurb: "Monitoring account lifecycle.", group: "Security & endpoint" },
};

const GROUP_ORDER = ["Runners & platform", "Core identity", "Email security", "Apps & access", "Security & endpoint", "Other"];
const prettify = (slug: string) => slug.replace(/-/g, " ").replace(/^./, (c) => c.toUpperCase());

function discoverGuides(): string[] {
  try {
    return readdirSync(join(process.cwd(), "app", "help"), { withFileTypes: true })
      .filter((d) => d.isDirectory() && !d.name.startsWith("_"))
      .map((d) => d.name)
      .sort();
  } catch {
    return [];
  }
}

export default function HelpIndexPage() {
  const byGroup = new Map<string, { slug: string; title: string; blurb: string }[]>();
  for (const slug of discoverGuides()) {
    const meta = GUIDES[slug];
    const group = meta?.group ?? "Other";
    const list = byGroup.get(group) ?? [];
    list.push({ slug, title: meta?.title ?? prettify(slug), blurb: meta?.blurb ?? "" });
    byGroup.set(group, list);
  }

  return (
    <main style={{ maxWidth: 900 }}>
      <h1>Help</h1>
      <p className="note" style={{ marginBottom: "1.25rem" }}>
        Setup guides — one per system, plus the platform ones. Each says what credential the step needs,
        where to create it, and which permissions it must carry.{" "}
        <Link href="/modules">Modules</Link> is the companion view: which systems have a built executor.
      </p>

      {GROUP_ORDER.filter((g) => byGroup.has(g)).map((group) => (
        <section key={group} style={{ marginBottom: "1.6rem" }}>
          <h2 style={{ fontSize: 15, marginBottom: "0.5rem" }}>{group}</h2>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(260px, 1fr))", gap: "0.6rem" }}>
            {byGroup.get(group)!.map((g) => (
              <Link
                key={g.slug}
                href={`/help/${g.slug}`}
                style={{ display: "block", border: "1px solid var(--line, #e5e7eb)", borderRadius: 6, padding: "0.6rem 0.75rem", textDecoration: "none" }}
              >
                <div style={{ fontWeight: 600 }}>{g.title}</div>
                {g.blurb && <div className="note" style={{ marginTop: 2 }}>{g.blurb}</div>}
              </Link>
            ))}
          </div>
        </section>
      ))}
    </main>
  );
}
