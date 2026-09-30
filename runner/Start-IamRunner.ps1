#Requires -Version 7.0
<#
.SYNOPSIS
    iam-engine runner. Polls the app, claims jobs, executes via Coretelligent.* modules,
    posts results. Same script runs as the central cloud runner or a client-network agent.
.NOTES
    Outbound HTTPS only. Authenticates with mTLS in production (omitted in this skeleton).
    See docs/RUNNER_PROTOCOL.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppUrl,        # https://iam-engine.internal
    [Parameter(Mandatory)][string]$AgentId,
    [string]$ApiToken = $env:RUNNER_API_TOKEN,    # interim shared bearer (until mTLS)
    [string]$AgentToken = $env:RUNNER_AGENT_TOKEN, # per-agent token (preferred); falls back to $ApiToken
    [int]$PollSeconds = 5,
    [int]$BatchSize   = 5,
    # ExchangeOnlineManagement 3.10.0's REST cmdlets break on PowerShell 7.6 ("[HttpResponseMessage]
    # does not contain a method named 'GetResponseHeader'"); 3.9.2 is the known-good build. Pin the
    # version the runner loads so it never auto-picks a broken one. Override per host if needed.
    [string]$ExoModuleVersion = '3.9.2',
    # Watchdog: restart the process if it makes no progress for this long (a hung inline job — the
    # only failure the loop can't self-heal). Default 600s; aligns with the app's 10-min stale-lease
    # reclaim so the orphaned job re-queues just as the fresh process comes up. Env: RUNNER_STALL_TIMEOUT.
    [int]$StallTimeoutSeconds = 600,
    # Heartbeat file the watchdog + -HealthCheck read; defaults to a temp path keyed by AgentId
    # (kept out of the bundle so it can't affect the build hash). Env: RUNNER_HEARTBEAT_FILE.
    [string]$HeartbeatFile = '',
    # Liveness-probe mode: report health from the heartbeat file and exit (0 healthy / 1 stale) WITHOUT
    # starting the runner. Backs an Azure Container Apps `exec` liveness probe in managed hosting.
    [switch]$HealthCheck
)

# The watchdog is lightweight and the -HealthCheck probe must be fast, so load it + resolve the
# heartbeat path BEFORE the heavy automation modules. A health probe never loads the rest.
Import-Module "$PSScriptRoot/lib/Coretelligent.Watchdog/Coretelligent.Watchdog.psm1" -Force
# Pure -AppUrl rewrite helpers (Set-CtgAppUrlInArgString / Set-CtgAppUrlInPlist), used by Invoke-CtgMigrate.
. (Join-Path $PSScriptRoot 'lib/CtgMigrate.ps1')
# Invoke-CtgManifestPull — the self-update file pull (no relaunch), shared with the pool supervisor.
. (Join-Path $PSScriptRoot 'lib/CtgUpdate.ps1')
# Get-CtgBearer (per-agent-preferred bearer accessor) + Set-CtgAgentToken (provisionToken adoption).
. (Join-Path $PSScriptRoot 'lib/CtgAgentAuth.ps1')
if (-not $PSBoundParameters.ContainsKey('StallTimeoutSeconds') -and $env:RUNNER_STALL_TIMEOUT) { $StallTimeoutSeconds = [int]$env:RUNNER_STALL_TIMEOUT }
$HeartbeatFile = Get-CtgHeartbeatPath -Explicit $HeartbeatFile -AgentId $AgentId
if ($HealthCheck) {
    $h = Test-CtgRunnerHealth -Path $HeartbeatFile -TimeoutSeconds $StallTimeoutSeconds
    if (-not $h.healthy) { Write-Error "runner unhealthy: $($h.reason)"; exit 1 }
    Write-Host "runner healthy: $($h.reason)"
    exit 0
}
$global:CtgHeartbeatFile = $HeartbeatFile

# FR #0000171: pin the working directory to the runner's own folder before anything else runs.
#
# A Store-installed pwsh starts with BOTH its PowerShell location and its process working directory at
# $PSHOME — C:\Program Files\WindowsApps\Microsoft.PowerShell_<ver>_x64__8wekyb3d8bbwe — which is
# read-only even to an administrator. Any relative path written from there fails with "Access to the
# path '...\WindowsApps\...\<name>' is denied", and the reporter of #171 saw exactly that for 'Scripts'
# while starting this script; moving the working directory somewhere writable by hand fixed it.
#
# The relative path is NOT ours. Every write in this repo is anchored ($PSScriptRoot, $InstallDir,
# GetTempPath) and a clean start from $PSHOME on a Store pwsh 7.6.6 does not reproduce it — so the
# culprit is inside a dependency we call during startup module installs, whose per-scope path
# computation degrades to a relative one on some hosts (an account with no resolvable MyDocuments/HOME,
# which is what a SYSTEM scheduled task is). We cannot anchor a path inside someone else's module. The
# working directory is the only lever we have over it, so we take it, once, here.
#
# BOTH have to be set and they are genuinely independent: PowerShell cmdlets (New-Item, Test-Path)
# resolve against the provider location that Set-Location moves, while .NET APIs
# ([System.IO.File], Directory.CreateDirectory) resolve against [Environment]::CurrentDirectory, which
# Set-Location does NOT touch. Setting only one leaves half the calls still pointing at WindowsApps.
#
# Best-effort by design: a runner that cannot set its own directory must still start, and $PSScriptRoot
# is empty when this file is dot-sourced rather than run, so there is nothing to anchor to then.
if ($PSScriptRoot) {
    try {
        Set-Location -LiteralPath $PSScriptRoot
        [Environment]::CurrentDirectory = $PSScriptRoot
    }
    catch { Write-Warning "could not set the working directory to $PSScriptRoot ($($_.Exception.Message)) - a relative path written by a dependency may fail if this process started somewhere read-only." }
}

$ErrorActionPreference = 'Stop'
# This is a non-interactive background service. Suppress progress bars + ANSI cursor control: writing
# a progress bar / colored output to a redirected or detached stdout (notably right after a self-update
# relaunch, when the old console is gone) throws "Out-LineOutput: Input/output error" and leaks
# cursor-position reports (the ;1R noise) into the log. PlainText output avoids the escape sequences.
$ProgressPreference = 'SilentlyContinue'
try { if (Get-Variable -Name PSStyle -ErrorAction SilentlyContinue) { $PSStyle.OutputRendering = 'PlainText' } } catch { }

# Non-interactive PSGallery bootstrap shared by the Graph skew guard below and the missing-module
# self-heal further down. The runner is detached (no stdin) — nothing here may ever prompt.
function Initialize-CtgGallery {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    }
}

# --- Microsoft.Graph version-skew guard ---------------------------------------------------------
# Graph submodules only load together when every resolved submodule carries the SAME version:
# mixing (say) Authentication 2.33 with Users 2.38 dies at Import-Module with "Assembly with same
# name is already loaded" — killing the runner before it ever polls (seen on the Six One DC agent).
# Skew accumulates because installs land in different scopes over time (the SYSTEM task's
# CurrentUser profile vs AllUsers). PowerShell resolves the HIGHEST version per submodule across
# PSModulePath, so repair = install the set's max version for every lagging submodule. No deletes:
# old copies may be file-locked by another process, and a higher version simply wins resolution.
# The Graph submodules the executors actually call into. Keep in lockstep with the installer's list
# (web/app/api/runner/install.ps1) — an agent enrolled BEFORE a name was added to that list never got
# it, and nothing installed it afterwards: Repair-CtgGraphVersionSkew below only ALIGNS submodules that
# are already present, it never adds a missing one. That gap is why offboards kept warning "the term
# 'Get-MgUserAuthenticationMethod' is not recognized" (Identity.SignIns absent) and left the leaver's
# second factors registered — on every run, forever, because the module's own catch downgraded the
# CommandNotFound to a warning and so the runner's per-job self-heal never saw it.
$script:CtgRequiredGraphModules = @(
    'Microsoft.Graph.Authentication'                  # Connect-MgGraph — the anchor version everything pins to
    'Microsoft.Graph.Users'                           # Get-MgUser / Update-MgUser
    'Microsoft.Graph.Users.Actions'                   # Revoke-MgUserSignInSession
    'Microsoft.Graph.Groups'                          # group membership
    'Microsoft.Graph.Identity.SignIns'                # MFA methods (offboard) + Temporary Access Pass (onboard)
    'Microsoft.Graph.Identity.DirectoryManagement'    # directory roles / org
)

# Install any REQUIRED Graph submodule that is missing, pinned to the version of the Authentication
# module already on the host — mixing versions across submodules is what produces "Assembly with the
# same name is already loaded", so a fresh install must join the set at its version, not the gallery's
# latest. Best-effort per module: a host with no gallery access keeps working (the executors that need
# the absent module still degrade to a warning), it just doesn't self-repair.
function Install-CtgMissingGraphModules {
    $missing = @($script:CtgRequiredGraphModules | Where-Object {
        -not (Get-Module -ListAvailable -Name $_ -ErrorAction SilentlyContinue)
    })
    if (-not $missing) { return }

    $auth = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    $pin = if ($auth) { $auth.Version.ToString() } else { $null }
    Write-Warning ("Microsoft.Graph submodule(s) missing on this host: {0} — installing{1}" -f ($missing -join ', '), $(if ($pin) { " (pinned to $pin)" } else { '' }))
    Initialize-CtgGallery
    foreach ($m in $missing) {
        try {
            if ($pin) { Install-Module $m -RequiredVersion $pin -Scope CurrentUser -Force -AllowClobber -Confirm:$false -AcceptLicense -ErrorAction Stop }
            else { Install-Module $m -Scope CurrentUser -Force -AllowClobber -Confirm:$false -AcceptLicense -ErrorAction Stop }
            Write-Host "  installed $m$(if ($pin) { " $pin" })" -ForegroundColor Yellow
        }
        catch {
            # The pinned version may not exist for this submodule — take the latest and let the skew
            # repair below pull the whole set back into line.
            try {
                Install-Module $m -Scope CurrentUser -Force -AllowClobber -Confirm:$false -AcceptLicense -ErrorAction Stop
                Write-Host "  installed $m (latest — no $pin available)" -ForegroundColor Yellow
            }
            catch { Write-Warning "  could not install ${m}: $($_.Exception.Message)" }
        }
    }
}

function Repair-CtgGraphVersionSkew {
    $avail = Get-Module -ListAvailable -Name 'Microsoft.Graph.*' -ErrorAction SilentlyContinue
    if (-not $avail) { return }
    $resolved = $avail | Group-Object Name | ForEach-Object { ($_.Group | Sort-Object Version -Descending)[0] }
    $versions = @($resolved | ForEach-Object Version | Sort-Object -Unique)
    if ($versions.Count -le 1) { return }
    $target = ($versions | Sort-Object -Descending)[0]
    $lagging = @($resolved | Where-Object { $_.Version -ne $target })
    Write-Warning ("Microsoft.Graph submodule versions are mixed ({0}) — aligning {1} module(s) to {2}" -f ($versions -join ', '), $lagging.Count, $target)
    Initialize-CtgGallery
    foreach ($m in $lagging) {
        try {
            Install-Module $m.Name -RequiredVersion $target -Scope CurrentUser -Force -AllowClobber -Confirm:$false -AcceptLicense -ErrorAction Stop
            Write-Host "  aligned $($m.Name) $($m.Version) -> $target" -ForegroundColor Yellow
        } catch {
            Write-Warning "  could not align $($m.Name) to ${target}: $($_.Exception.Message)"
        }
    }
}
# Add what's missing FIRST, then align the whole set — a freshly installed submodule joins at the
# pinned version, and anything that couldn't be pinned gets pulled into line by the skew repair.
Install-CtgMissingGraphModules
Repair-CtgGraphVersionSkew

Import-Module "$PSScriptRoot/modules/Coretelligent.M365/Coretelligent.M365.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Mimecast/Coretelligent.Mimecast.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.DirectorySync/Coretelligent.DirectorySync.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Zoom/Coretelligent.Zoom.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Slack/Coretelligent.Slack.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Adobe/Coretelligent.Adobe.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Perimeter81/Coretelligent.Perimeter81.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Spanning/Coretelligent.Spanning.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.1Password/Coretelligent.1Password.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Egnyte/Coretelligent.Egnyte.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.GoogleWorkspace/Coretelligent.GoogleWorkspace.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Salesforce/Coretelligent.Salesforce.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.KnowBe4/Coretelligent.KnowBe4.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Jira/Coretelligent.Jira.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.HubSpot/Coretelligent.HubSpot.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.SentinelOne/Coretelligent.SentinelOne.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Duo/Coretelligent.Duo.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.XMatters/Coretelligent.XMatters.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.LogicMonitor/Coretelligent.LogicMonitor.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Notify/Coretelligent.Notify.psd1" -Force
Import-Module "$PSScriptRoot/modules/Coretelligent.Proofpoint/Coretelligent.Proofpoint.psd1" -Force
# Teams Phone. Harmless to import: MicrosoftTeams itself only ever loads in the child process the step
# starts (Invoke-CtgTeamsOutOfProcess), never here.
Import-Module "$PSScriptRoot/modules/Coretelligent.Teams/Coretelligent.Teams.psd1" -Force
# Low-code connectors: ONE generic executor for every custom-* system — it interprets the declarative
# definition the app injects into the job as config.connector (docs/CONNECTOR_BUILDER.md).
Import-Module "$PSScriptRoot/modules/Coretelligent.Connector/Coretelligent.Connector.psd1" -Force
# Browser-automation bridge (shells out to the Node/Playwright sidecar in runner/browser). Loads
# unconditionally — Test-CtgBrowserAvailable reports whether Node+Playwright are actually installed,
# and the app's claim gate withholds browser jobs (e.g. spanning-force-sync) from agents that can't run them.
Import-Module "$PSScriptRoot/modules/Coretelligent.Browser/Coretelligent.Browser.psd1" -Force
# (Coretelligent.Secrets is no longer imported: the app now resolves the secret value and pushes it
# down in the credential response — the runner no longer talks to Delinea itself.)
# These modules depend on host-specific cmdlets: the AD module needs the on-prem ActiveDirectory
# module (client-network agent only); Exchange needs ExchangeOnlineManagement. Load each only
# where its dependency is present so the central cloud runner doesn't fail to import.
#
# Loading ActiveDirectory on a DC is subtle. It's a Windows PowerShell module, and pwsh 7 (what the
# runner runs) frequently CANNOT see it via Get-Module -ListAvailable — RSAT installs it off pwsh 7's
# PSModulePath, so only Windows PowerShell 5.1 enumerates it (verified on 61C-DC01: -ListAvailable blank
# in pwsh 7, but 5.1 has it and Import-Module ActiveDirectory -UseWindowsPowerShell works). pwsh 7 loads
# it through the Windows-compat proxy: a background 5.1 session that proxies the AD cmdlets. So try native
# in-proc first (fastest, when pwsh 7 can see it), then the compat proxy, and only self-heal-install RSAT
# when it's genuinely absent from BOTH. Whatever loads it, Coretelligent.ActiveDirectory's RequiredModules
# is then satisfied by the already-loaded 'ActiveDirectory' module (name match — no native re-resolve).
function Import-CtgActiveDirectory {
    if (Get-Command Get-ADUser -ErrorAction SilentlyContinue) { return $true }  # already loaded this process
    if (Get-Module -ListAvailable ActiveDirectory) {
        try { Import-Module ActiveDirectory -Force -ErrorAction Stop; return $true } catch { }
    }
    if ($IsWindows) {
        # Windows-compat proxy — the path that works on a DC where RSAT is visible only to WinPS 5.1.
        try { Import-Module ActiveDirectory -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop; return $true } catch { }
    }
    return $false
}
$adReady = Import-CtgActiveDirectory
if (-not $adReady -and $IsWindows) {
    # Not loadable natively OR via the compat proxy -> RSAT is genuinely absent. Self-heal: add it ONCE
    # (best-effort; needs elevation + Windows Update), then retry the load. Quiet where it doesn't apply.
    try {
        $adCap = Get-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($adCap -and $adCap.State -ne 'Installed') {
            Write-Host "ActiveDirectory module missing — installing RSAT capability ($($adCap.Name))…" -ForegroundColor Yellow
            Add-WindowsCapability -Online -Name $adCap.Name -ErrorAction Stop | Out-Null
        } elseif (-not $adCap -and (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue)) {
            # A server with the ServerManager module (e.g. a DC) exposes RSAT-AD-PowerShell as a feature.
            Write-Host "ActiveDirectory module missing — installing RSAT-AD-PowerShell feature…" -ForegroundColor Yellow
            Install-WindowsFeature RSAT-AD-PowerShell -ErrorAction Stop | Out-Null
        }
        $adReady = Import-CtgActiveDirectory
    } catch { Write-Warning "could not auto-install the ActiveDirectory RSAT module (install RSAT-AD-PowerShell manually + restart the runner): $($_.Exception.Message)" }
}
if ($adReady) {
    Import-Module "$PSScriptRoot/modules/Coretelligent.ActiveDirectory/Coretelligent.ActiveDirectory.psd1" -Force
} else {
    Write-Warning "ActiveDirectory module could not be loaded on this host — AD jobs will be withheld (this agent reports no 'active-directory' capability)."
}
# Install a module in a CLEAN child pwsh. By the time a self-heal runs, THIS process has imported
# Graph, ActiveDirectory and a dozen Coretelligent.* modules, and PowerShellGet then refuses outright:
# "The version '1.4.8.1' of module 'PackageManagement' is currently in use. Retry the operation after
# closing the applications." A child started with -NoProfile has none of that loaded, so the install
# proceeds. Returns { Code; Tail } (the shape Invoke-CtgToolProcess uses); a non-zero exit is data,
# not an exception — only a failure to START the child throws.
# $Version is OPTIONAL: the EXO pin needs an exact build (that is its whole purpose), but PnP.PowerShell
# deliberately tracks the gallery latest. Omitting -RequiredVersion is the honest way to say "latest" —
# the alternative, inventing a version to satisfy a mandatory parameter, pins a build nobody chose.
function Invoke-CtgPwshInstall {
    param([Parameter(Mandatory)][string]$Name,
          [string]$Version,
          [string]$Scope = 'CurrentUser')
    $pwshPath = (Get-Process -Id $PID).Path
    if (-not $pwshPath) { $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
    if (-not $pwshPath) { throw 'cannot locate pwsh to run the install in a clean process' }
    $verArg = if ($Version) { " -RequiredVersion '$Version'" } else { '' }
    $cmd = "Install-Module -Name '$Name'$verArg -Scope $Scope -Force -AllowClobber -Confirm:`$false -AcceptLicense -ErrorAction Stop"
    $out = & $pwshPath -NoProfile -NonInteractive -Command $cmd 2>&1
    $tail = (@($out) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Last 4) -join ' | '
    return [pscustomobject]@{ Code = [int]$LASTEXITCODE; Tail = $tail }
}

# Self-heal the pinned EXO build if it's absent — mirrors Install-CtgMissingGraphModules above. Without
# it, a host that only has the broken 3.10.0 (whose REST cmdlets call the removed
# HttpResponseMessage.GetResponseHeader() on PS7.6) silently falls back to it and EVERY Exchange job
# dies with "does not contain a method named 'GetResponseHeader'" — the failure puretech/core2104 hit.
# Best-effort: a host with no gallery access keeps the warn-and-fall-back path below.
function Install-CtgExoPin {
    param([Parameter(Mandatory)][string]$Version)
    $have = Get-Module -ListAvailable -Name ExchangeOnlineManagement -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -eq [version]$Version }
    # Having the pin outranks any reason we did not have it earlier — clear the recorded failure.
    if ($have) { $script:LastExoPinError = $null; return }
    Write-Warning "ExchangeOnlineManagement $Version (the PS7.6-safe pin) not installed — installing it so Exchange jobs don't fall back to a build that breaks on 'GetResponseHeader'."
    Initialize-CtgGallery
    $tail = ''
    try {
        $r = Invoke-CtgPwshInstall -Name 'ExchangeOnlineManagement' -Version $Version -Scope 'CurrentUser'
        $tail = [string]$r.Tail
    } catch {
        $tail = $_.Exception.Message
    }
    $now = Get-Module -ListAvailable -Name ExchangeOnlineManagement -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -eq [version]$Version }
    if ($now) {
        $script:LastExoPinError = $null
        Write-Host "  installed ExchangeOnlineManagement $Version" -ForegroundColor Yellow
        return
    }
    # Still absent. Say what will be loaded INSTEAD: that is the fact that decides whether Exchange
    # works at all, and it used to reach nobody — this warning goes to stdout, which a Windows SYSTEM
    # scheduled task discards. Reported on the heartbeat as exoPinError so the Agents page shows it.
    $others = @(Get-Module -ListAvailable -Name ExchangeOnlineManagement -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
    $fallback = if ($others.Count) { [string]$others[0].Version } else { 'none — Exchange steps cannot run at all' }
    $script:LastExoPinError = "could not install the ExchangeOnlineManagement $Version pin; Exchange jobs will load $fallback instead. Reason: $tail"
    Write-Warning "  $script:LastExoPinError"
}
# Pull the pin in before we resolve which build to load, so the healthy path below finds it present.
# Initialised HERE, not beside $script:LastMigrateError further down — that runs after this point and
# would erase the verdict the self-heal just recorded.
$script:LastExoPinError = $null
Install-CtgExoPin -Version $ExoModuleVersion
$exoAvail = Get-Module -ListAvailable ExchangeOnlineManagement
if ($exoAvail) {
    # Load the pinned EXO version FIRST (before Coretelligent.Exchange's RequiredModules auto-picks the
    # highest) so a broken build (3.10.0 on PS7.6) is never the one in scope. Fall back to the newest
    # available if the pin isn't installed — with a warning, since that may be the broken one.
    $exoPick = $exoAvail | Where-Object { $_.Version -eq [version]$ExoModuleVersion } | Select-Object -First 1
    if ($exoPick) {
        Import-Module ExchangeOnlineManagement -RequiredVersion $ExoModuleVersion -Force
    } else {
        $newest = ($exoAvail | Sort-Object Version -Descending | Select-Object -First 1).Version
        Write-Warning "ExchangeOnlineManagement $ExoModuleVersion not installed; using $newest (install the pin if EXO cmdlets fail with 'GetResponseHeader')."
        Import-Module ExchangeOnlineManagement -RequiredVersion $newest -Force
    }
    Import-Module "$PSScriptRoot/modules/Coretelligent.Exchange/Coretelligent.Exchange.psd1" -Force
}

# Self-heal PnP.PowerShell if it's absent — mirrors Install-CtgExoPin above. PnP powers
# Grant-CtgSharePointSiteAccess (offboard hand-off: a leaver's manager/delegate gets full access to
# their OneDrive/SharePoint content). Nothing ELSE in the runner depends on PnP being present, so a
# host that cannot get it keeps running every other system.
#
# There is no claim gate behind this, and a comment here used to say there was. $script:OnPremCapabilityProbe
# reports 'active-directory' and 'directory-sync' only; no PnP capability is reported anywhere, and the
# hand-off is not a job of its own — it rides inside the m365 offboard, which every cloud runner can
# claim. So a runner without PnP claims the offboard exactly as before and simply does not perform the
# grant. That is why the skip has to be reported on the case (see the Offboard dispatch block) and why
# a failure here is recorded rather than warned into a console nobody is attached to.
#
# Returns whether PnP.PowerShell is available once installation is attempted, so callers don't have
# to re-scan -ListAvailable themselves (Fix 3 — this used to run that scan, then the caller ran it
# again immediately after to set $pnpAvail).
function Install-CtgPnPModule {
    $avail = Get-Module -ListAvailable -Name PnP.PowerShell -ErrorAction SilentlyContinue
    # Having the module outranks any reason we did not have it earlier — clear the recorded failure.
    if ($avail) { $script:LastPnpError = $null; return $true }
    Write-Warning "PnP.PowerShell not installed — installing it so SharePoint/OneDrive full-access grants can run (offboard hand-off). Best-effort; a host with no gallery access will skip SharePoint grants."
    Initialize-CtgGallery
    # Out-of-process, for the reason Invoke-CtgPwshInstall documents: this call used to run in-session,
    # where PowerShellGet refuses while PackageManagement is loaded — and Initialize-CtgGallery loads it
    # one line above, every time. The install therefore failed at EVERY startup on any host that did not
    # already have PnP, which is the whole of FR #0000116: the site-collection-admin grant the request
    # asks for exists and had never once run.
    $tail = ''
    try {
        $r = Invoke-CtgPwshInstall -Name 'PnP.PowerShell' -Scope 'CurrentUser'
        $tail = [string]$r.Tail
    } catch {
        $tail = $_.Exception.Message
    }
    if (Get-Module -ListAvailable -Name PnP.PowerShell -ErrorAction SilentlyContinue) {
        $script:LastPnpError = $null
        Write-Host "  installed PnP.PowerShell" -ForegroundColor Yellow
        return $true
    }
    # Still absent. Name the CONSEQUENCE, not just the error: what stops working is the leaver's
    # manager getting at the leaver's files, and the case will otherwise report only the Graph invite.
    $script:LastPnpError = "could not install PnP.PowerShell; offboards on this runner cannot grant a delegate site-collection admin on the leaver's OneDrive/SharePoint — they get the per-item OneDrive invite only. Reason: $tail"
    Write-Warning "  $script:LastPnpError"
    return $false
}
# Initialised HERE, immediately before the call, for the same reason the EXO pin's is — anywhere later
# and it would erase the verdict the self-heal just recorded.
$script:LastPnpError = $null
$pnpAvail = Install-CtgPnPModule
if ($pnpAvail) { Import-Module "$PSScriptRoot/modules/Coretelligent.SharePoint/Coretelligent.SharePoint.psd1" -Force }

# Safe property/key read at the RUNNER scope. Each Coretelligent module has its own private copy of
# this helper, but those aren't exported — so a script-scope call (e.g. reading $job.config) must use
# this one. Without it, the call is an unresolved command that the dependency guard below mistakes for
# a missing host-specific module ("the Coretelligent module providing 'Get-CtgProp' isn't loaded…").
function Get-CtgProp {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# Persistent troubleshooting log: errors/warnings/failures append to runner.log next to the
# script (build-id + bundle walks skip *.log), rotating at 5 MB. Pull a line from here when
# reporting an issue — it has the timestamp, job id and full error the console may have scrolled.
$script:CtgLogPath = Join-Path $PSScriptRoot 'runner.log'
# Message is FIRST positionally: `Write-CtgLog "..." 'WARN'` is how every call site here reads, and
# with $Level first that bound the message to $Level and died on its ValidateSet — a terminating
# error raised from inside the very catch blocks that were trying to warn. Named calls
# (-Level/-Message) are unaffected by the order.
function Write-CtgLog {
    param([Parameter(Mandatory, Position = 0)][string]$Message,
          [Parameter(Position = 1)][ValidateSet('ERROR', 'WARN', 'INFO')][string]$Level = 'INFO')
    try {
        if ((Test-Path $script:CtgLogPath) -and (Get-Item $script:CtgLogPath).Length -gt 5MB) {
            Move-Item $script:CtgLogPath "$($script:CtgLogPath).1" -Force
        }
        Add-Content -Path $script:CtgLogPath -Value "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [$Level] $Message"
    } catch { }  # logging must never break the runner
}

# --- How the runner authenticates to Active Directory ---------------------------------------------
#
# The runner installs as a SYSTEM scheduled task (install-task.ps1). ON A WRITABLE DOMAIN CONTROLLER —
# where the agent nearly always lives — SYSTEM's network identity IS the directory's own SYSTEM
# principal: full control, over a Kerberos-sealed channel, needing no credential at all. Attaching the
# brokered -Credential from that host is what BREAKS it. Delinea's "Active Directory Account" template
# keeps the domain in its own field, so the stored Username is usually a BARE sAMAccountName; a bare
# name carries no realm, so SSPI can't get a Kerberos ticket for it, the connection degrades to NTLM,
# and a DC with LDAP signing / channel binding enforced refuses the bind — surfacing as "Authentication
# failed on the remote side", or LDAP 8 strongerAuthRequired ("the user has not been authenticated").
# We were handing AD a strictly worse identity than the process already had. (Case UM0029763.)
#
# Two rules keep the fix from creating worse bugs than it fixes:
#
# 1. AMBIENT IS ONLY PREFERRED WHERE IT IS KNOWN-PRIVILEGED — SYSTEM, on a WRITABLE DC. It is not
#    enough that a probe passes: Get-ADDomain is a READ, and every authenticated principal passes it.
#    A member server's SYSTEM is only the machine account (reads the directory fine, cannot create a
#    user); an RODC cannot be written at all; a task re-pointed at some domain service account has
#    whatever rights it was given. Preferring ambient on a read probe in any of those cases would go
#    green and then fail Access-Denied halfway through a case. So the preference is decided by what
#    the host IS, and ambient is never a silent fallback for a credential that was refused — off a
#    privileged DC we use the brokered account and FAIL LOUDLY if AD won't take it.
#
# 2. AT MOST ONE CREDENTIAL BIND PER CALL. Never probe several forms of the same password looking for
#    one that sticks: every refused bind increments the account's badPwdCount, and ad-dc is a shared
#    account (several clients reuse it for exchange-onprem/directory-sync), so a stale vault password
#    would march it straight into a domain lockout. We derive ONE qualified username and try it once.

function Test-CtgAdAmbientIsPrivileged {
    # Is this process's own identity one we KNOW holds directory write rights — i.e. SYSTEM on a
    # writable DC? Anything else ($false) means the brokered ad-dc account must lead.
    if (-not $IsWindows) { return $false }
    # SYSTEM specifically. install-task.ps1 registers the task as SYSTEM, but an operator may have
    # re-pointed it at a service account, and we cannot assume anything about that account's rights.
    try { if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { return $false } }
    catch { return $false }
    # Win32_ComputerSystem.DomainRole: 4 = backup DC, 5 = primary DC.
    try { if (([int](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole) -notin @(4, 5)) { return $false } }
    catch { return $false }
    # An RODC reports as a DC but holds no writable copy — writes route to a writable DC, where this
    # host is just an unprivileged machine account. Best-effort: if we can't tell, assume writable.
    try { if ((Get-ADDomainController -Identity $env:COMPUTERNAME -ErrorAction Stop).IsReadOnly) { return $false } }
    catch { }
    return $true
}

# The cheapest authenticated read there is. Returns $null when the splat authenticates, else the
# failure message — so the caller can report exactly what the identity it tried was told.
function Test-CtgAdConnection {
    param([hashtable]$AdConnection = @{})
    try { $null = Get-ADDomain @AdConnection -ErrorAction Stop; return $null }
    catch { return [string]$_.Exception.Message }
}

# THE one credential to try for the brokered ad-dc account — never a ladder of variants (see rule 2).
# A username that already carries a domain (DOMAIN\user or user@domain) is trusted verbatim. A bare one
# is qualified from the secret's Domain field: a DNS domain goes in the UPN slot (user@dns.domain), a
# NetBIOS name in the down-level slot (DOMAIN\user). With no Domain field there is nothing to qualify
# with, so the bare name goes as-is — the same bind we've always made, no worse.
function Get-CtgAdCredential {
    param($Secret)
    if (-not $Secret -or -not $Secret.Credential) { return $null }
    $user = [string]$Secret.Credential.UserName
    if (-not $user) { return $null }
    if ($user -match '[\\@]') { return $Secret.Credential }
    $fields = if ($Secret.Fields) { $Secret.Fields } else { @{} }
    $dom = Select-CtgCredField $fields @('Domain', 'DomainName', 'NetBIOSName', 'DNSDomainName', 'FQDN')
    if (-not $dom) { return $Secret.Credential }
    $dom = ([string]$dom).Trim()
    $qualified = if ($dom -like '*.*') { "$user@$dom" } else { "$dom\$user" }
    return [pscredential]::new($qualified, $Secret.Credential.Password)
}

# The sAMAccountName inside DOMAIN\user / user@domain / user — what an ACL check resolves SIDs from.
function Get-CtgSamFromUserName {
    param([string]$UserName)
    if (-not $UserName) { return $null }
    if ($UserName -match '\\') { return ($UserName -split '\\')[-1] }
    if ($UserName -match '@') { return ($UserName -split '@')[0] }
    return $UserName
}

# Which identity New-CtgAdConnection last selected. The splat itself can't carry this (it is splatted
# straight onto AD cmdlets, so a stray key would bind to a real parameter), and the connection test has
# to evaluate the OU ACL of the account we ACTUALLY authenticate as — not whatever ad-dc happens to
# hold. Same $script:-scope idiom as $script:ConnTestRights.
$script:CtgAdIdentity = @{ kind = 'ambient'; sam = $null; label = "the agent's own identity" }

# The brokered ad-dc PSCredential, or $null when it isn't brokered. ad-dc is now OPTIONAL (a DC agent
# authenticates as ambient SYSTEM and never receives it), so callers must tolerate its absence rather
# than deref $creds['ad-dc'].Credential blindly.
function Get-CtgAdDcCredential($creds) {
    $s = $creds['ad-dc']
    if ($s) { $s.Credential } else { $null }
}

function New-CtgAdConnection($creds) {
    if (-not (Get-Command Get-ADDomain -ErrorAction SilentlyContinue)) {
        throw "the ActiveDirectory PowerShell module is not loaded on this agent — install RSAT (Rsat.ActiveDirectory.DS-LDS.Tools) on the agent host, or route this client's AD steps to an agent that has it."
    }
    $s = $creds['ad-dc']

    # The DC to target (-Server). The "Active Directory Account" Delinea template has no Server field,
    # so the DC name is stored in its "Documentation Link" field — accept that (and a few aliases; the
    # list mirrors the app's ad-dc field-requirements so the secret Test agrees with the runner). Ignore
    # a value that looks like a URL (a genuine doc link) so it can't be mistaken for a server. Omitted
    # entirely when unset: the cmdlets then target the agent's own domain, which is what we want on a DC.
    $base = @{}
    if ($s -and $s.Fields) {
        $server = Select-CtgCredField $s.Fields @('Server', 'Host', 'DomainController', 'DC')
        if (-not $server) {
            $docLink = Select-CtgCredField $s.Fields @('Documentation Link', 'DocumentationLink', 'Document Link', 'DocLink')
            if ($docLink -and $docLink -notmatch '^\s*https?://') { $server = $docLink }
        }
        if ($server) { $base.Server = ([string]$server).Trim() }
    }

    $cred = Get-CtgAdCredential $s
    $withCred = $null
    if ($cred) { $withCred = $base.Clone(); $withCred.Credential = $cred }

    $useAmbient = {
        $script:CtgAdIdentity = @{ kind = 'ambient'; sam = $null; label = "the agent's own identity" }
        $base
    }
    $useCred = {
        $script:CtgAdIdentity = @{ kind = 'credential'; sam = (Get-CtgSamFromUserName $cred.UserName); label = "the brokered ad-dc account '$($cred.UserName)'" }
        $withCred
    }

    if (Test-CtgAdAmbientIsPrivileged) {
        # SYSTEM on a writable DC: the directory's own SYSTEM principal. This is the Brock Built shape.
        $ambientErr = Test-CtgAdConnection $base
        if (-not $ambientErr) { return & $useAmbient }
        if (-not $cred) {
            throw "Active Directory refused this agent's own identity (SYSTEM on this domain controller) — $ambientErr — and no ad-dc credential was brokered to fall back on. If the DC is simply unreachable this is not a credential problem; otherwise wire the ad-dc secret with a username and password."
        }
        $credErr = Test-CtgAdConnection $withCred
        if (-not $credErr) {
            Write-CtgLog "AD: this agent's own identity was refused ($ambientErr) — fell back to the brokered ad-dc account '$($cred.UserName)'" 'WARN'
            return & $useCred
        }
        throw ("Active Directory refused both identities this agent can offer — as SYSTEM on this domain controller: $ambientErr; as the brokered ad-dc account '$($cred.UserName)': $credErr. " +
            "If the DC is unreachable, neither message is about the credential. If they are authentication failures, note that a BARE ad-dc username cannot use Kerberos and a DC with LDAP signing / channel binding enforced rejects the NTLM fallback — store it DOMAIN-QUALIFIED (DOMAIN\user or user@domain), or add a Domain field for the runner to qualify it with.")
    }

    # Not a known-privileged host. Ambient here is the machine account (or an unknown service account):
    # it can READ the directory but almost certainly cannot create a user — so it must NOT be a silent
    # fallback for a credential AD refused. That would turn a clear auth error into a half-applied case.
    if (-not $cred) {
        # Nothing brokered, so the agent's own identity is all there is — the pre-existing behaviour for
        # a client with no ad-dc secret wired.
        $ambientErr = Test-CtgAdConnection $base
        if ($ambientErr) {
            throw "Active Directory refused this agent's own identity — $ambientErr — and no ad-dc credential was brokered. This agent is not a domain controller, so it has no privileged identity of its own: wire the client's ad-dc secret (a domain-qualified username + password), or install the agent on a DC."
        }
        return & $useAmbient
    }
    $credErr = Test-CtgAdConnection $withCred
    if ($credErr) {
        throw ("Active Directory refused the brokered ad-dc account '$($cred.UserName)' — $credErr. " +
            "This agent is not a domain controller, so there is no privileged identity to fall back to (its machine account could read the directory but not write it, which would fail halfway through the case). " +
            "If this is an authentication failure: a BARE username cannot use Kerberos and a DC with LDAP signing / channel binding enforced rejects the NTLM fallback — store it DOMAIN-QUALIFIED (DOMAIN\user or user@domain), or add a Domain field for the runner to qualify it with.")
    }
    return & $useCred
}

# Point the Spanning module at this job's brokered secret. The verified API authenticates with
# Basic clientId:clientSecret against o365-api-{region}.spanningbackup.com/external — so with the
# "Automation - API" template, ClientID is the Basic USERNAME and ClientSecret the password. Legacy
# tenants (domain:access-token) still work: Domain/AccountID, or the client's primary domain, fill
# the username slot when no ClientID is present. Reads PLAIN values from .Fields (.Password is a
# SecureString). Called at the START OF EVERY spanning lane (not a cached Connect) so a rotated
# credential takes effect on the next job, no restart needed.
function Use-CtgSpanningSecret {
    param($Job, $Creds)
    $s = $Creds['spanning']
    if (-not $s) { throw "the job did not broker a 'spanning' secret — make sure the client's spanning system lists 'spanning' in its secrets" }
    $pick = { param($names) foreach ($k in $names) { if ($s.Fields.ContainsKey($k) -and $s.Fields[$k]) { return $s.Fields[$k] } } $null }
    $tokenNames = @('ClientSecret', 'AccessToken', 'Access Token', 'ApiToken', 'API Key', 'APIKey', 'Api Key', 'ApiKey', 'Token', 'Key', 'Password')
    $token = & $pick $tokenNames
    # Fail actionably, not with an opaque parameter-binding error: name the fields we looked
    # for AND the ones the secret actually has, so the fix (rename a Delinea field) is obvious.
    if (-not $token) { throw "the 'spanning' secret has no client-secret/token field — looked for $($tokenNames -join ', '); the secret has: $(@($s.Fields.Keys) -join ', '). Put the Spanning client secret in one of those fields (see /help/spanning)." }
    $user = & $pick @('ClientID', 'ClientId', 'Client ID', 'Domain', 'AccountID', 'AccountId', 'Account', 'Tenant')
    if (-not $user) { $user = if ($s.Username) { $s.Username } else { $Job.client.primaryDomain } }
    $baseUrl = & $pick @('apiURL', 'ApiUrl', 'ApiURL', 'BaseUrl', 'Url')
    if ($baseUrl) { Connect-CtgSpanning -Username $user -AccessToken $token -BaseUrl $baseUrl }
    else          { Connect-CtgSpanning -Username $user -AccessToken $token -Region $s.Fields['Region'] }
}

# Point the Proofpoint module at this job's brokered secret. Proofpoint Essentials authenticates with
# the admin email + password as X-User / X-Password headers (admin accounts only). The org domain for
# the /orgs/{domain} path comes from a Domain field, else the client's primary domain. Region/BaseUrl
# select the tenant's pod (us1..us5/eu1/au1). Reads PLAIN field values (.Password is also a SecureString,
# but the API needs the cleartext header). Called at the start of every proofpoint lane (no cached Connect).
function Use-CtgProofpointSecret {
    param($Job, $Creds)
    $s = $Creds['proofpoint']
    if (-not $s) { throw "the job did not broker a 'proofpoint' secret — make sure the client's proofpoint system lists 'proofpoint' in its secrets" }
    $pick = { param($names) foreach ($k in $names) { if ($s.Fields.ContainsKey($k) -and $s.Fields[$k]) { return $s.Fields[$k] } } $null }
    $user = & $pick @('X-User', 'Username', 'AdminUser', 'Admin', 'Email', 'User')
    if (-not $user) { $user = $s.Username }
    if (-not $user) { throw "the 'proofpoint' secret has no admin-email field — looked for X-User, Username, AdminUser, Email; the secret has: $(@($s.Fields.Keys) -join ', '). Put the Proofpoint admin email in one of those." }
    $pass = & $pick @('X-Password', 'Password', 'AdminPassword', 'Secret', 'ApiKey', 'API Key', 'Token')
    if (-not $pass) { throw "the 'proofpoint' secret has no admin-password field — looked for X-Password, Password, AdminPassword; the secret has: $(@($s.Fields.Keys) -join ', '). Put the Proofpoint admin password in one of those." }
    $domain = & $pick @('Domain', 'OrgDomain', 'Org', 'Tenant')
    if (-not $domain) { $domain = $Job.client.primaryDomain }
    if (-not $domain) { throw "the 'proofpoint' secret has no Domain field and the client has no primary domain — Proofpoint needs the org domain for the /orgs/{domain} path." }
    $baseUrl = & $pick @('BaseUrl', 'Base URL', 'ApiUrl', 'apiURL', 'Url', 'URL')
    if ($baseUrl) { Connect-CtgProofpoint -User ([string]$user) -Password ([string]$pass) -Domain ([string]$domain) -BaseUrl $baseUrl }
    else {
        $region = & $pick @('Region', 'Pod')
        Connect-CtgProofpoint -User ([string]$user) -Password ([string]$pass) -Domain ([string]$domain) -Region ([string]($region ?? 'us1'))
    }
}

# Sign in to 1Password with the brokered admin account so `op` can provision/suspend users. Only the
# api/auto/scim methods need this; field-tolerant like the others. Returns $true on success. The CALLER
# decides whether a failure is fatal (api) or a fallback-to-manual signal (auto) — so this throws and
# the dispatch wraps it.
function Use-Ctg1PasswordSecret {
    param($Job, $Creds)
    $s = $Creds['1password']
    if (-not $s) { throw "the job did not broker a '1password' secret — list '1password' in the client's 1password system secrets (the api/scim methods need an admin sign-in). See /help/1password." }
    $pick = { param($names) foreach ($k in $names) { if ($s.Fields.ContainsKey($k) -and $s.Fields[$k]) { return [string]$s.Fields[$k] } } $null }
    $cfg = if ($Job.config) { $Job.config } else { [pscustomobject]@{} }
    $address = (& $pick @('SignInAddress', 'Sign In Address', 'Account', 'Url', 'apiURL', 'Domain'))
    if (-not $address) { $address = [string](Get-CtgProp $cfg 'signInAddress') }
    $email = (& $pick @('Email', 'Username', 'User', 'AdminEmail'))
    if (-not $email -and $s.Username) { $email = [string]$s.Username }
    $secretKey = (& $pick @('SecretKey', 'Secret Key', 'SecretKey ', 'Key'))
    $password = (& $pick @('Password', 'Pass'))
    foreach ($pair in @(@('sign-in address', $address), @('email', $email), @('Secret Key', $secretKey), @('password', $password))) {
        if (-not $pair[1]) { throw "the '1password' secret is missing $($pair[0]) — the api method needs SignInAddress + Email + SecretKey + Password (an admin/owner account, MFA-exempt). The secret has: $(@($s.Fields.Keys) -join ', '). See /help/1password." }
    }
    Connect-Ctg1Password -SignInAddress $address -Email $email -SecretKey $secretKey -Password $password
}

# Establish an `op` admin session for this job IF the method needs/wants one, returning $connected.
# api REQUIRES it (a failure throws); auto/scim treat it as best-effort (a failure -> $false, and the
# module falls back to a manual checklist / skips the optional verify); manual/browser never connect.
function Connect-Ctg1PasswordForJob {
    param($Job, $Creds)
    $method = ([string](Get-CtgProp $Job.config 'method')); if (-not $method) { $method = 'auto' }
    if ($method -in @('manual', 'browser')) { return $false }
    try { Use-Ctg1PasswordSecret -Job $Job -Creds $Creds; return $true }
    catch {
        if ($method -eq 'api') { throw }
        Set-CtgPhase $Job.id "1Password ($method): admin sign-in unavailable — $($_.Exception.Message)"
        return $false
    }
}

# Connect Google Workspace from the brokered 'google-admin' secret. Domain-wide-delegated SERVICE
# ACCOUNT. The fleet shape is Delinea's stock "Automation - API" template (the same one the app's
# auto-vault writes): ClientSecret = base64 of the downloaded JSON key (Delinea-safe for the
# multi-line private_key), accountid = the SA's client email (needed only for a bare-PEM key),
# apiURL = the super-admin email to impersonate (repurposed — never a URL here), ClientID = the
# Workspace customer id. Custom templates keep working via the lenient picks below:
# ServiceAccountJson/ServiceAccountKeyBase64 or ClientEmail+PrivateKey for the key, and
# Impersonate (else the secret's Username) for the admin. Connect-CtgGoogle mints a fresh OAuth
# token each call, so a rotated key takes effect next job. See /help/google.
function Use-CtgGoogleSecret {
    param($Job, $Creds)
    $s = $Creds['google-admin']
    if (-not $s) { throw "the job did not broker a 'google-admin' secret — make sure the client's google-workspace system lists 'google-admin' in its secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    $clientEmail = & $pick @('ClientEmail', 'ServiceAccountEmail', 'client_email')
    $privateKey  = & $pick @('PrivateKey', 'private_key')
    $json = & $pick @('ServiceAccountJson', 'ServiceAccountKeyJson', 'KeyJson')
    $b64  = & $pick @('ServiceAccountKeyBase64', 'ServiceAccountJsonBase64', 'KeyBase64')
    if ($b64 -and -not $json) { $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
    if ($json) {
        $sa = $json | ConvertFrom-Json
        if (-not $clientEmail) { $clientEmail = [string]$sa.client_email }
        if (-not $privateKey)  { $privateKey  = [string]$sa.private_key }
    }
    # Additive fallback: Secret Server's stock "Automation - API" template (no key/email/subject
    # fields of its own) repurposed for google-admin — ClientSecret carries the key material
    # (base64 of the full SA JSON, base64 of a bare PEM, or either un-encoded), accountid carries
    # the SA's client email (only needed for the bare-PEM shape — a JSON key already has one).
    # Only consulted when the shapes above didn't resolve both an email and a key.
    if (-not $clientEmail -or -not $privateKey) {
        $clientSecretField = & $pick @('ClientSecret')
        if ($clientSecretField) {
            $accountId = & $pick @('accountid')
            $resolveKeyValue = {
                param($value, $email)
                if ($value -match '^\s*-----BEGIN') {
                    if (-not $email) { return $null }
                    return [pscustomobject]@{ Email = $email; Key = $value.Trim() }
                }
                if ($value -match '^\s*\{') {
                    $sa2 = $value | ConvertFrom-Json
                    return [pscustomobject]@{ Email = [string]$sa2.client_email; Key = [string]$sa2.private_key }
                }
                return $null
            }
            $resolved = & $resolveKeyValue $clientSecretField $accountId
            if (-not $resolved) {
                $decodedOnce = $null
                try { $decodedOnce = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($clientSecretField)) } catch {}
                if ($decodedOnce) { $resolved = & $resolveKeyValue $decodedOnce $accountId }
            }
            if ($resolved -and $resolved.Email -and $resolved.Key) {
                $clientEmail = $resolved.Email
                $privateKey  = $resolved.Key
            }
        }
    }
    if (-not $clientEmail -or -not $privateKey) {
        throw "the 'google-admin' secret has no service-account key — put the base64 of the downloaded JSON key in ClientSecret (the stock Automation - API template), or on a custom template set ServiceAccountKeyBase64/ServiceAccountJson or split ClientEmail+PrivateKey. The secret has: $(@($f.Keys) -join ', '). See /help/google."
    }
    $impersonate = & $pick @('Impersonate', 'AdminEmail', 'Admin', 'Subject', 'DelegatedAdmin', 'AdminUser')
    if (-not $impersonate -and $s.Username) { $impersonate = [string]$s.Username }
    if (-not $impersonate) {
        # Automation - API template fallback: apiURL repurposed to carry the impersonate email
        # (never a real URL for this secret, so the '@' check disambiguates from stray Adobe/other-style values).
        $apiUrlField = & $pick @('apiURL')
        if ($apiUrlField -and $apiUrlField -match '@') { $impersonate = $apiUrlField }
    }
    if (-not $impersonate) { throw "the 'google-admin' secret has no admin to impersonate — put a Workspace super-admin's email in the apiURL field (the stock Automation - API template; the runner reads an email there), or in Impersonate/Username on a custom template. Domain-wide delegation acts as a real admin. See /help/google." }
    $customer = & $pick @('CustomerId', 'Customer')
    if (-not $customer) {
        # Automation - API template fallback: ClientID holds the Workspace customer id.
        $clientIdField = & $pick @('ClientID')
        if ($clientIdField) { $customer = $clientIdField }
    }
    $script:GoogleCustomerAdvisory = $null   # cleared every connect; the conn-test probe reports it
    if ($customer) {
        # Validate what we resolved: a real Workspace customer id is C + alphanumerics (C0123abcd;
        # Admin Console → Account settings), or the literal my_customer. In the wild the template's
        # ClientID field frequently holds the service account's NUMERIC OAuth client_id instead
        # (FR#35, UOVO Art secret 57051) — a value the Directory API would 400 on. Fall back to
        # my_customer with a WARN so the fleet self-heals; a genuine reseller-style C… value still
        # passes through. Never log the full raw value.
        $customer = ([string]$customer).Trim()
        if ($customer -ne 'my_customer' -and $customer -notmatch '^[Cc][0-9a-zA-Z]{4,}$') {
            $scrub = if ($customer.Length -gt 4) { $customer.Substring(0, 4) } else { $customer }
            $advisory = "the google-admin secret's ClientID/CustomerId value '$scrub…' ($($customer.Length) chars) doesn't look like a Workspace customer id (C0… from Admin Console → Account settings) — using my_customer instead. The service account's numeric OAuth client ID belongs on the DWD authorization screen, not in this field."
            Write-CtgLog "google: $advisory" 'WARN'
            $script:GoogleCustomerAdvisory = $advisory
            $customer = 'my_customer'
        }
    }
    if (-not $customer) { $customer = 'my_customer' }
    $scopesRaw = & $pick @('Scopes', 'Scope')
    $scopes = if ($scopesRaw) { @($scopesRaw -split '[,\s]+' | Where-Object { $_ }) } else { @() }
    if ($scopes.Count) { Connect-CtgGoogle -ClientEmail $clientEmail -PrivateKey $privateKey -Impersonate $impersonate -CustomerId $customer -Scopes $scopes }
    else               { Connect-CtgGoogle -ClientEmail $clientEmail -PrivateKey $privateKey -Impersonate $impersonate -CustomerId $customer }
}

# Connect Salesforce from the brokered 'salesforce' secret. Connected App JWT bearer: ConsumerKey
# (the app's client_id), the integration Username to act as, and the cert PrivateKey (PEM, or
# PrivateKeyBase64 — Delinea-safe). Sandbox tenants set LoginUrl/IsSandbox. Each lane re-connects so
# a rotated cert applies next job. See /help/salesforce.
function Use-CtgSalesforceSecret {
    param($Job, $Creds)
    $s = $Creds['salesforce']
    if (-not $s) { throw "the job did not broker a 'salesforce' secret — list 'salesforce' in the client's salesforce system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    $consumerKey = & $pick @('ConsumerKey', 'ClientID', 'ClientId', 'ConsumerId')
    $username    = & $pick @('Username', 'IntegrationUser', 'AdminUser', 'Subject'); if (-not $username -and $s.Username) { $username = [string]$s.Username }
    $privateKey  = & $pick @('PrivateKey', 'private_key')
    $b64         = & $pick @('PrivateKeyBase64', 'CertificateBase64', 'KeyBase64')
    if ($b64 -and -not $privateKey) { $privateKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
    if (-not $consumerKey -or -not $username -or -not $privateKey) {
        throw "the 'salesforce' secret needs ConsumerKey + Username + PrivateKey (or PrivateKeyBase64). The secret has: $(@($f.Keys) -join ', '). See /help/salesforce."
    }
    $loginUrl = & $pick @('LoginUrl', 'LoginURL', 'InstanceUrl')
    if (-not $loginUrl) { $loginUrl = if ((& $pick @('IsSandbox', 'Sandbox')) -match '^(true|1|yes)$') { 'https://test.salesforce.com' } else { 'https://login.salesforce.com' } }
    Connect-CtgSalesforce -ConsumerKey $consumerKey -Username $username -PrivateKey $privateKey -LoginUrl $loginUrl
}

# Connect KnowBe4 from the brokered 'knowbe4' secret — the SCIM bearer token (+ optional region BaseUrl).
function Use-CtgKnowBe4Secret {
    param($Job, $Creds)
    $s = $Creds['knowbe4']
    if (-not $s) { throw "the job did not broker a 'knowbe4' secret — list 'knowbe4' in the client's knowbe4 system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    $token = & $pick @('ScimToken', 'SCIMToken', 'Token', 'ApiToken', 'Key', 'Password')
    if (-not $token) { throw "the 'knowbe4' secret has no SCIM token — set ScimToken (Account Settings > User Management > SCIM). The secret has: $(@($f.Keys) -join ', '). See /help/knowbe4." }
    $baseUrl = & $pick @('BaseUrl', 'ScimUrl', 'Url')
    if ($baseUrl) { Connect-CtgKnowBe4 -Token $token -BaseUrl $baseUrl } else { Connect-CtgKnowBe4 -Token $token }
}

# Connect Jira from the brokered 'jira' secret — Basic (admin email : API token) + the site URL.
function Use-CtgJiraSecret {
    param($Job, $Creds)
    $s = $Creds['jira']
    if (-not $s) { throw "the job did not broker a 'jira' secret — list 'jira' in the client's jira system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    $email = & $pick @('Email', 'AdminEmail', 'Username'); if (-not $email -and $s.Username) { $email = [string]$s.Username }
    $token = & $pick @('ApiToken', 'Token', 'Key', 'Password')
    $site  = & $pick @('SiteUrl', 'Site', 'Url', 'BaseUrl')
    if (-not $email -or -not $token -or -not $site) { throw "the 'jira' secret needs Email + ApiToken + SiteUrl (https://<site>.atlassian.net). The secret has: $(@($f.Keys) -join ', '). See /help/jira." }
    Connect-CtgJira -Email $email -ApiToken $token -SiteUrl $site
}

# Connect HubSpot from the brokered 'hubspot' secret — a private-app access token (Bearer).
function Use-CtgHubSpotSecret {
    param($Job, $Creds)
    $s = $Creds['hubspot']
    if (-not $s) { throw "the job did not broker a 'hubspot' secret — list 'hubspot' in the client's hubspot system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    $token = & $pick @('AccessToken', 'Token', 'PrivateAppToken', 'ApiKey', 'Key', 'Password')
    if (-not $token) { throw "the 'hubspot' secret has no access token — set AccessToken (a private-app token). The secret has: $(@($f.Keys) -join ', '). See /help/hubspot." }
    $baseUrl = & $pick @('BaseUrl', 'Url')
    if ($baseUrl) { Connect-CtgHubSpot -Token $token -BaseUrl $baseUrl } else { Connect-CtgHubSpot -Token $token }
}

# Connect SentinelOne from the brokered 'sentinelone' secret — the management console URL + an API
# token (service user). ApiToken auth. Re-broker each lane so a rotated token applies next job.
function Use-CtgSentinelOneSecret {
    param($Job, $Creds)
    $s = $Creds['sentinelone']
    if (-not $s) { throw "the job did not broker a 'sentinelone' secret — list 'sentinelone' in the client's sentinelone system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    $baseUrl = & $pick @('BaseUrl', 'ConsoleUrl', 'MgmtUrl', 'ManagementUrl', 'Url', 'ApiUrl')
    if (-not $baseUrl) { throw "the 'sentinelone' secret has no console URL — set BaseUrl to the management console (e.g. https://usea1-partners.sentinelone.net). The secret has: $(@($f.Keys) -join ', '). See /help/sentinelone." }
    $token = & $pick @('ApiToken', 'Token', 'ApiKey', 'API Key', 'Key', 'Password')
    if (-not $token) { throw "the 'sentinelone' secret has no API token — set ApiToken (a service-user token). The secret has: $(@($f.Keys) -join ', '). See /help/sentinelone." }
    Connect-CtgSentinelOne -BaseUrl $baseUrl -Token $token
}

# The machine names the SentinelOne offboard should isolate = the user's Entra-registered devices,
# resolved via the brokered 'm365-admin' app (the same single source the M365 step captures). Returns
# @() when m365-admin isn't brokered or nothing resolves — the S1 module then falls back to the
# config/payload machineName. Best-effort: a Graph hiccup logs a note and falls back, never blocks the
# isolate. (Connects Graph here on the m365-admin app; harmless alongside the S1 connection.)
function Get-CtgSentinelOneMachines {
    param($Job, $Creds)
    if (-not $Creds['m365-admin']) { return @() }
    try {
        Connect-CtgM365 -Credential $Creds['m365-admin'].Credential -TenantId (Get-CtgTenantDomain $Job $Creds)
        $upn = Resolve-CtgM365Upn -User $Job.payload
        if (-not $upn) { return @() }
        @(Get-CtgM365UserDevices -UserId $upn | ForEach-Object { [string]$_.DisplayName } | Where-Object { $_ })
    } catch {
        Send-CtgProgress "could not resolve Entra devices for SentinelOne ($($_.Exception.Message)) — falling back to the configured machine name"
        @()
    }
}

# Connect Duo from the brokered 'duo' secret — the Admin API host + integration key + secret key.
function Use-CtgDuoSecret {
    param($Job, $Creds)
    $s = $Creds['duo']
    if (-not $s) { throw "the job did not broker a 'duo' secret — list 'duo' in the client's duo system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    $apiHost = & $pick @('ApiHost', 'Host', 'Hostname', 'ApiHostname', 'BaseUrl', 'Url')
    $ikey    = & $pick @('IntegrationKey', 'IKey', 'ClientID', 'ClientId', 'Username'); if (-not $ikey -and $s.Username) { $ikey = [string]$s.Username }
    $skey    = & $pick @('SecretKey', 'SKey', 'ClientSecret', 'Secret', 'ApiKey', 'Key', 'Password')
    if (-not $apiHost -or -not $ikey -or -not $skey) { throw "the 'duo' secret needs ApiHost (api-XXXX.duosecurity.com) + IntegrationKey + SecretKey from a Duo Admin API application. The secret has: $(@($f.Keys) -join ', '). See /help/duo." }
    Connect-CtgDuo -ApiHost $apiHost -IntegrationKey $ikey -SecretKey $skey
}

# Connect xMatters from the brokered 'xmatters' secret — the company URL + a REST web-service user
# (Basic). The credential is the secret's pscredential, or Username/Password fields.
function Use-CtgXMattersSecret {
    param($Job, $Creds)
    $s = $Creds['xmatters']
    if (-not $s) { throw "the job did not broker an 'xmatters' secret — list 'xmatters' in the client's xmatters system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    $baseUrl = & $pick @('apiURL', 'ApiUrl', 'BaseUrl', 'CompanyUrl', 'Url', 'Instance')
    if (-not $baseUrl) { throw "the 'xmatters' secret has no company URL — set apiURL (https://{company}.xmatters.com). The secret has: $(@($f.Keys) -join ', '). See /help/xmatters." }
    # xMatters API KEY + SECRET as Basic auth (key = username, secret = password). The Delinea
    # "Automation API" template stores them as clientID + ClientSecret; a REST user's Username +
    # Password works too. Prefer explicit fields, else the stored credential. (accountId is unused.)
    $u = & $pick @('ClientID', 'ClientId', 'ApiKey', 'AccessKey', 'Key', 'Username', 'User')
    $p = & $pick @('ClientSecret', 'Secret', 'ApiSecret', 'Password', 'Token', 'ApiToken')
    if (-not $u -and $s.Credential -and $s.Credential.UserName) { $u = [string]$s.Credential.UserName }
    if (-not $u -and $s.Username) { $u = [string]$s.Username }
    if (-not $p -and $s.Credential -and $s.Credential.Password) { $p = ConvertFrom-SecureString $s.Credential.Password -AsPlainText }
    if (-not $u -or -not $p) { throw "the 'xmatters' secret needs an API key + secret (clientID/ClientSecret) or a REST user Username + Password. The secret has: $(@($f.Keys) -join ', '). See /help/xmatters." }
    $cred = [pscredential]::new(([string]$u).Trim(), (ConvertTo-SecureString (([string]$p).Trim()) -AsPlainText -Force))
    Connect-CtgXMatters -BaseUrl $baseUrl -Credential $cred
}

# Connect LogicMonitor from the brokered 'logicmonitor' secret — the portal account + LMv1 access id +
# access key (an API-token, not a user password).
function Use-CtgLogicMonitorSecret {
    param($Job, $Creds)
    $s = $Creds['logicmonitor']
    if (-not $s) { throw "the job did not broker a 'logicmonitor' secret — list 'logicmonitor' in the client's logicmonitor system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    $account = & $pick @('Account', 'Portal', 'Company', 'Subdomain', 'BaseUrl', 'Url')
    if (-not $account) { throw "the 'logicmonitor' secret has no Account — set Account to the portal subdomain (e.g. 'coretelligent'). The secret has: $(@($f.Keys) -join ', '). See /help/logicmonitor." }
    $accessId  = & $pick @('AccessId', 'AccessID', 'ClientID', 'ClientId', 'Username'); if (-not $accessId -and $s.Username) { $accessId = [string]$s.Username }
    $accessKey = & $pick @('AccessKey', 'ClientSecret', 'Secret', 'ApiKey', 'Key', 'Password')
    if (-not $accessId -or -not $accessKey) { throw "the 'logicmonitor' secret needs AccessId + AccessKey (an LMv1 API token from Settings > User Access > API Tokens). The secret has: $(@($f.Keys) -join ', '). See /help/logicmonitor." }
    Connect-CtgLogicMonitor -Account $account -AccessId $accessId -AccessKey $accessKey
}

# Connect Zoom from the brokered 'zoom' secret — a Server-to-Server OAuth app: Client ID (the
# credential's username, or a Client* field), Client Secret (the password / *Secret field), and the
# Account ID. Tolerant of field-name variants and fails actionably (names what it looked for + what
# the secret has) instead of an opaque parameter-bind error.
# Point the Slack module at this job's brokered secret. Slack SCIM authenticates with a Bearer token
# carrying the `admin` scope (generated by a Slack Owner/Admin; needs a Business+ / Enterprise Grid
# plan). Reads PLAIN field values. Called at the start of every slack lane (Connect-CtgSlack is a pure
# local assignment, no network), so a rotated token applies on the very next job — no restart.
function Use-CtgSlackSecret {
    param($Job, $Creds)
    $s = $Creds['slack']
    if (-not $s) { throw "the job did not broker a 'slack' secret — list 'slack' in the client's slack system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    $tokenNames = @('Token', 'ApiToken', 'API Token', 'AccessToken', 'Access Token', 'ApiKey', 'API Key', 'SCIMToken', 'SCIM Token', 'Password')
    $token = & $pick $tokenNames
    # The secret's own password field is a legitimate place for a token; a pscredential too.
    if (-not $token -and $s.Credential) { try { $token = $s.Credential.GetNetworkCredential().Password } catch { } }
    # Fail actionably, not with an opaque parameter-binding error: name what we looked for AND what the
    # secret actually has, so the fix (rename a Delinea field) is obvious.
    if (-not $token) { throw "the 'slack' secret has no token field — looked for $($tokenNames -join ', '); the secret has: $(@($f.Keys) -join ', '). Put the Slack SCIM token (admin scope) in one of those. See /help/slack." }
    $baseUrl = & $pick @('BaseUrl', 'Base URL', 'Url', 'URL', 'apiURL')
    if ($baseUrl) { Connect-CtgSlack -Token $token -BaseUrl $baseUrl } else { Connect-CtgSlack -Token $token }
}

# Point the Adobe module at this job's brokered secret. Adobe UMAPI v2 uses an OAuth
# Server-to-Server app: Username = Client ID, Password = Client Secret, plus the organization id
# (XXXXXXXXXXXX@AdobeOrg), which every call needs in the URL path.
#
# The org id has no natural home in Delinea's stock templates — "Automation - API" has clientID /
# ClientSecret / accountid / apiURL and NO OrgId field — so in practice it lands in `accountid`.
# We therefore find it by the SHAPE OF ITS VALUE first (an Adobe org id always ends @AdobeOrg), which
# works whatever the field is called, and only fall back to a name list. That's the same
# match-on-value idiom used for the m365 app-id-vs-UPN check and the AD doc-link-vs-server check:
# a field NAME is a convention an operator can get wrong; the value's format is not.
#
# Scopes are NOT read from the secret (they're fixed: openid,AdobeID,user_management_sdk) and neither
# is an access token (the module mints a short-lived one per connect). A technical-account id/email
# belongs to Adobe's DEPRECATED Service Account (JWT) flow and is never used here — if a secret
# carries one, the credential was created as the wrong integration type.
function Use-CtgAdobeSecret {
    param($Job, $Creds)
    $s = $Creds['adobe']
    if (-not $s) { throw "the job did not broker an 'adobe' secret — list 'adobe' in the client's adobe system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }

    # 1. By value shape — any field holding something that ends @AdobeOrg IS the org id.
    $orgId = $null
    foreach ($k in $f.Keys) {
        $v = ([string]$f[$k]).Trim()
        if ($v -match '@AdobeOrg\s*$') { $orgId = $v; break }
    }
    # 2. By name — including accountid, which is where the stock template puts it.
    $orgNames = @('OrgId', 'OrgID', 'Org ID', 'Org', 'OrganizationId', 'OrganizationID', 'Organization ID',
                  'accountid', 'AccountId', 'AccountID', 'Account ID', 'Account')
    if (-not $orgId) { $orgId = & $pick $orgNames }

    $clientId     = & $pick @('ClientId', 'ClientID', 'Client ID')
    $clientSecret = & $pick @('ClientSecret', 'Client Secret', 'Secret', 'ApiKey', 'Key')
    if (-not $clientId -and $s.Credential -and $s.Credential.UserName) { $clientId = [string]$s.Credential.UserName }
    if (-not $clientId -and $s.Username) { $clientId = [string]$s.Username }
    if (-not $clientSecret -and $s.Credential -and $s.Credential.Password) { $clientSecret = ConvertFrom-SecureString $s.Credential.Password -AsPlainText }
    if (-not $clientSecret) { $clientSecret = & $pick @('Password') }

    # Trim copy-paste whitespace — a stray newline in the id/secret surfaces as Adobe's opaque
    # invalid_client, and a stray space in the org id as a 403 on a URL that "looks right".
    $orgId = ([string]$orgId).Trim(); $clientId = ([string]$clientId).Trim(); $clientSecret = ([string]$clientSecret).Trim()

    # Fail actionably: name what we looked for AND what the secret actually has, so the fix is obvious.
    if (-not $clientId -or -not $clientSecret) {
        throw "the 'adobe' secret needs an OAuth Server-to-Server app — Username = Client ID, Password = Client Secret. The secret has: $(@($f.Keys) -join ', '). See /help/adobe."
    }
    if (-not $orgId) {
        throw "the 'adobe' secret has no organization id — looked for a value ending @AdobeOrg in any field, then the fields $($orgNames -join ', '); the secret has: $(@($f.Keys) -join ', '). Put the org id (XXXXXXXXXXXX@AdobeOrg) in accountid (the 'Automation - API' template has no OrgId field). See /help/adobe."
    }
    # Found by name but the value doesn't look like an org id — warn, don't block: Adobe owns this
    # format and could change it. The UMAPI call will reject it clearly enough if we're wrong.
    if ($orgId -notmatch '@AdobeOrg\s*$') {
        Write-CtgLog "adobe: org id '$orgId' does not end @AdobeOrg — if UMAPI returns 403, check the org id in the Adobe Admin Console." 'WARN'
    }

    $cred = [pscredential]::new($clientId, (ConvertTo-SecureString $clientSecret -AsPlainText -Force))
    Connect-CtgAdobe -Credential $cred -OrgId $orgId
}

function Use-CtgZoomSecret {
    param($Job, $Creds)
    $s = $Creds['zoom']
    if (-not $s) { throw "the job did not broker a 'zoom' secret — list 'zoom' in the client's zoom system secrets" }
    $f = $s.Fields
    $pick = { param($names) foreach ($k in $names) { if ($f.ContainsKey($k) -and $f[$k]) { return [string]$f[$k] } } $null }
    # Accept the S2S app creds from EITHER explicit custom fields OR the secret's username/password —
    # whichever is set. Prefer a non-empty custom field, then fall back to the credential, so an
    # operator who put the Client ID in the Username slot AND one who used a ClientId field both work.
    $accountId    = & $pick @('AccountId', 'AccountID', 'Account ID', 'Account')
    $clientId     = & $pick @('ClientId', 'ClientID', 'Client ID')
    $clientSecret = & $pick @('ClientSecret', 'Client Secret', 'Secret', 'ApiKey', 'Key')
    if (-not $clientId -and $s.Credential -and $s.Credential.UserName) { $clientId = [string]$s.Credential.UserName }
    if (-not $clientId -and $s.Username) { $clientId = [string]$s.Username }
    if (-not $clientSecret -and $s.Credential -and $s.Credential.Password) { $clientSecret = ConvertFrom-SecureString $s.Credential.Password -AsPlainText }
    if (-not $clientSecret) { $clientSecret = & $pick @('Password') }
    # Trim copy-paste whitespace/newlines — a trailing space in the id/secret is a common cause of
    # Zoom's invalid_client (the value "looks right" but the Basic header carries the stray char).
    $accountId = ([string]$accountId).Trim(); $clientId = ([string]$clientId).Trim(); $clientSecret = ([string]$clientSecret).Trim()
    if (-not $accountId -or -not $clientId -or -not $clientSecret) { throw "the 'zoom' secret needs a Server-to-Server OAuth app — Username = Client ID, Password = Client Secret, plus an AccountId field (or ClientId/ClientSecret/AccountId custom fields). The secret has: $(@($f.Keys) -join ', '). See /help/zoom." }
    $cred = [pscredential]::new($clientId, (ConvertTo-SecureString $clientSecret -AsPlainText -Force))
    Connect-CtgZoom -Credential $cred -AccountId $accountId
}

# The M365/Exchange tenant identifier for this job, in priority order:
#   1. the m365-admin secret's TenantId field — the Directory (tenant) ID GUID from the app
#      registration; unambiguous and ALWAYS accepted by Entra, even when domain names are mis-set
#   2. the client's primary domain (set on the client page)
#   3. the m365-admin secret's Domain field (the cloud-auth guide's table includes it)
# A newly added client can have all three blank — without this guard that surfaced as the opaque
# "Cannot bind argument to parameter 'TenantId' because it is an empty string".
function Get-CtgTenantDomain {
    param($Job, $Creds)
    $s = $Creds['m365-admin']
    $t = if ($s -and $s.Fields['TenantId']) { $s.Fields['TenantId'] }
         elseif ($Job.client.primaryDomain) { $Job.client.primaryDomain }
         elseif ($s) { $s.Fields['Domain'] }
    if (-not $t) {
        $have = if ($s) { @($s.Fields.Keys) -join ', ' } else { 'no m365-admin secret brokered' }
        throw "no tenant for client '$($Job.client.slug)': client.primaryDomain is empty and the m365-admin secret has no TenantId/Domain field (its fields: $have). Best fix: put the Directory (tenant) ID from the app registration in a TenantId field on the secret, or set the client's primary domain (see /help/cloud-auth)."
    }
    $t
}

# What the Teams child process signs in with: the m365-admin app (id, tenant, certificate). The app's
# service principal needs the Entra "Teams Administrator" role (see /help/teams).
function Get-CtgTeamsAuth {
    param($Job, $Creds)
    $s = $Creds['m365-admin']
    if (-not $s) { throw "the job did not broker the m365-admin secret — Teams Phone signs in with the client's m365-admin app" }
    $cert = Get-CtgExoCertArgs $s
    if ($cert.Count -eq 0) { throw "the m365-admin secret has no certificate — Teams app-only sign-in needs CertificateBase64 (a .pfx) or CertificateThumbprint (see /help/teams)" }
    $tenant = Get-CtgTenantDomain $Job $Creds
    Set-CtgPhase $Job.id "Teams Phone (separate process; tenant $tenant, app $($s.Credential.UserName))"
    @{ AppId = [string]$s.Credential.UserName; Tenant = [string]$tenant; CertArgs = $cert }
}

# The app id this job's Graph/EXO work must run as — the m365-admin secret's Username.
function Get-CtgM365AppId {
    param($Creds)
    $s = $Creds['m365-admin']
    if (-not $s) { return '' }
    try { [string]$s.Credential.UserName } catch { '' }
}

# The authoritative Directory (tenant) ID GUID from the m365-admin secret, or '' when unset.
function Get-CtgM365TenantId {
    param($Creds)
    $s = $Creds['m365-admin']
    if (-not $s -or -not $s.Fields) { return '' }
    [string]$s.Fields['TenantId']
}

# True only when the process-wide Graph session belongs to THIS job's client.
#
# Connect-MgGraph holds ONE context for the WHOLE PROCESS, and the central runner serves the whole
# fleet from one long-lived process. So a Graph session left behind by ANOTHER client's job is worse
# than no session at all: anything read off it (notably the tenant's verified domains) describes the
# OTHER client's directory, and pairing that with this client's app id yields AADSTS700016 "app not
# found in the directory '<the other client>'". Identity, not liveness, is what matters here.
function Test-CtgGraphBoundTo {
    param([string]$AppId, [string]$TenantId)
    if (-not $AppId) { return $false }
    $ctx = try { Get-MgContext -ErrorAction Stop } catch { $null }
    if (-not $ctx) { return $false }
    if ([string]$ctx.ClientId -ne $AppId) { return $false }
    # A TenantId on the secret is the authoritative GUID — when present it must match too, because one
    # app registration can be shared across sibling clients (a child inherits its parent's m365-admin),
    # so a matching ClientId alone does NOT prove the session is bound to THIS client's tenant.
    # Only a GUID is comparable: Get-MgContext always reports the tenant as a GUID, so an operator who
    # typed a DOMAIN into the TenantId field would never match and we'd reject our own session forever
    # (falling back to the configured domains on every run — the JAMS path). Compare when we can,
    # rely on the app id when we can't. String -ne is case-insensitive, so GUID casing is a non-issue.
    if ($TenantId -match '^[0-9a-fA-F-]{36}$' -and [string]$ctx.TenantId -ne $TenantId) { return $false }
    $true
}

# Bind Graph to THIS job's client, unless it already is. Best-effort: returns $false (rather than
# throwing) when the client's m365-admin can't drive Graph — e.g. a cert-only app with no client
# secret — so callers fall back to configured domains exactly as they did before.
function Connect-CtgGraphForJob {
    param($Job, $Creds)
    $s = $Creds['m365-admin']
    if (-not $s) { return $false }
    if (Test-CtgGraphBoundTo -AppId (Get-CtgM365AppId $Creds) -TenantId (Get-CtgM365TenantId $Creds)) { return $true }
    try {
        # Out-Null, not bare: a PowerShell function returns EVERY uncaptured value, so anything the
        # connect emits would ride out alongside $true and make the result an array.
        Connect-CtgM365 -Credential $s.Credential -TenantId (Get-CtgTenantDomain $Job $Creds) | Out-Null
        # We just REBOUND the one process-wide Graph session, displacing whoever held it. Every cached
        # key that rides Graph now describes a session that no longer exists, so forget them all — or
        # the next m365/entra job for the client we displaced sees its key intact, SKIPS Connect, and
        # runs inside THIS client's tenant. That is the same defect $script:ConnectionGroups exists to
        # prevent; it lives here, at the rebind, because only this call knows a rebind happened.
        Clear-CtgConnectionSiblings -SystemKey 'm365' -IncludeSelf
        $true
    }
    catch { $false }
}

function Get-CtgExoOrganization {
    # Exchange Online's -Organization needs a DOMAIN (e.g. dcg.co / dcg.onmicrosoft.com), NOT the
    # tenant GUID that Graph -TenantId uses ("Organization cannot be a Guid").
    #
    # CRITICAL: EXO must operate on the tenant this client's OWN credentials belong to. Deriving the
    # domain from the client's primaryDomain can resolve to a DIFFERENT directory (e.g. JAMS'
    # primaryDomain newcoinc.com resolved to a separate "Newco, Inc." tenant while Graph used the real
    # app tenant) → AADSTS700016 "app not found in directory". primaryDomain is the SN `website` value
    # and explicitly informational (schema.prisma) — it is a hint, never an authority. The only
    # authoritative answer to "what domain is this tenant?" is the tenant itself, so PREFER its own
    # default verified domain read over Graph.
    #
    # EQUALLY CRITICAL: only trust a Graph session that is THIS client's (Test-CtgGraphBoundTo). The
    # session is process-wide and the central runner is fleet-wide, so an m365/entra job or conn-test
    # for another client leaves Graph bound to THEIR tenant. Inheriting it silently sends this client's
    # app id to a foreign directory — UM0029840: Olympus Cosmetic's conn tests bound Graph, then
    # Easterseals' exchange step (which since the offboard reorder runs BEFORE m365/entra, so it has no
    # session of its own) read olympuscosmetic.com off it. Callers that need Graph bind it themselves
    # via Connect-CtgGraphForJob; here we only ever READ a session already proven to be ours.
    param($Job, $Creds)
    if (Test-CtgGraphBoundTo -AppId (Get-CtgM365AppId $Creds) -TenantId (Get-CtgM365TenantId $Creds)) {
        try {
            $org = @(Get-MgOrganization -ErrorAction Stop)[0]
            if ($org -and $org.VerifiedDomains) {
                $def = @($org.VerifiedDomains | Where-Object { $_.IsDefault } | ForEach-Object { [string]$_.Name } | Where-Object { $_ })
                if ($def.Count) { return $def[0] }
                $any = @($org.VerifiedDomains | ForEach-Object { [string]$_.Name } | Where-Object { $_ -and $_ -match '\.' })
                if ($any.Count) { return $any[0] }
            }
        }
        catch { } # Graph is ours but unreadable (throttle/perms) — fall back to configured domains
    }
    # Fallbacks, most-explicit first. An operator-set Domain field on the secret outranks primaryDomain:
    # it was typed to name THIS tenant, whereas primaryDomain is the marketing website's domain and is
    # what sent JAMS to the wrong directory in the first place.
    $cand = [System.Collections.Generic.List[string]]::new()
    $s = $Creds['m365-admin']
    if ($s -and $s.Fields) { foreach ($k in @('Domain', 'TenantDomain', 'Organization')) { if ($s.Fields[$k]) { $cand.Add([string]$s.Fields[$k]) } } }
    if ($Job.client -and $Job.client.primaryDomain) { $cand.Add([string]$Job.client.primaryDomain) }
    if ($Job.payload -and $Job.payload.UserPrincipalName -and ([string]$Job.payload.UserPrincipalName) -match '@') { $cand.Add(([string]$Job.payload.UserPrincipalName -split '@')[1]) }
    foreach ($c in $cand) { $d = ([string]$c).Trim(); if ($d -and $d -notmatch '^[0-9a-fA-F-]{36}$') { return $d } }
    throw "no Exchange Online organization DOMAIN for '$($Job.client.slug)' — EXO needs a domain (e.g. <tenant>.onmicrosoft.com), not the tenant GUID. Set the client's primary domain, or add a Domain field to the m365-admin secret."
}

# systemKey -> { Connect?; Onboard; Offboard }. Connect (optional) runs once per tenant before
# the first job for that system; the action lanes receive ($job, $creds) where $creds maps each
# The initial password for a new user, in priority order:
#   1. A brokered Delinea secret — named by config.initialPasswordSecret, else a 'default-password'
#      secret if one was brokered (the app resolved + pushed it down like any credential).
#   2. A literal config.initialPassword (a default typed into the KB).
#   3. A generated policy-compliant password (the default).
# Always returns a SecureString. No StrictMode at runner scope, so missing config props read $null.
function Resolve-CtgInitialPassword {
    param($Job, $Creds)
    $cfg = $Job.config
    $secretName = if ($cfg) { [string]$cfg.initialPasswordSecret } else { $null }
    if ([string]::IsNullOrWhiteSpace($secretName) -and $Creds -and $Creds.ContainsKey('default-password')) { $secretName = 'default-password' }
    if (-not [string]::IsNullOrWhiteSpace($secretName) -and $Creds -and $Creds.ContainsKey($secretName) -and $Creds[$secretName]) {
        $s = $Creds[$secretName]
        $val = $null
        if ($s.Password) { $val = ConvertFrom-SecureString $s.Password -AsPlainText }
        if ([string]::IsNullOrWhiteSpace($val) -and $s.Fields) {
            foreach ($k in @('Password', 'InitialPassword', 'Value', 'Key', 'Secret')) { if ($s.Fields.ContainsKey($k) -and $s.Fields[$k]) { $val = [string]$s.Fields[$k]; break } }
        }
        if (-not [string]::IsNullOrWhiteSpace($val)) { return (ConvertTo-SecureString $val -AsPlainText -Force) }
    }
    $literal = if ($cfg) { [string]$cfg.initialPassword } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($literal)) { return (ConvertTo-SecureString $literal -AsPlainText -Force) }
    return (New-CtgCompliantPassword)
}

# Build the app-only Exchange Online cert args from a brokered secret's Fields — prefer a base64 PFX
# (cross-platform: macOS/Linux/Windows), else a Windows cert-store thumbprint. Empty when neither set.
function Get-CtgExoCertArgs {
    param($Secret)
    $a = @{}
    $f = if ($Secret) { $Secret.Fields } else { $null }
    if ($f) {
        $b64 = if ($f['CertificateBase64']) { $f['CertificateBase64'] } elseif ($f['CertificatePfxBase64']) { $f['CertificatePfxBase64'] } else { $null }
        if ($b64) {
            $a['CertificateBase64'] = [string]$b64
            if ($f['CertificatePassword']) { $a['CertificatePassword'] = [string]$f['CertificatePassword'] }
        }
        elseif ($f['CertificateThumbprint']) { $a['CertificateThumbprint'] = [string]$f['CertificateThumbprint'] }
    }
    $a
}

function Invoke-CtgM365ExoFinish {
    # Finish the m365 onboard over Exchange Online with the SAME m365-admin app cert (no separate
    # Exchange system): (1) add the distribution / mail-enabled groups Graph couldn't write; and when
    # MIRRORING, (2) copy the mirror user's cloud DLs and (3) their SHARED-MAILBOX permissions
    # (FullAccess / SendAs / SendOnBehalf) — the part Graph can't do. One EXO connection for all of it.
    # Idempotent + best-effort; returns action lines.
    param($Job, $Creds, [string[]]$Names, [string]$MirrorUser, $DefaultMailboxes, $MailboxAudit, $CalendarReviewers)
    $out = [System.Collections.Generic.List[string]]::new()
    $names = @($Names | Where-Object { $_ })
    $mirror = if ([string]::IsNullOrWhiteSpace($MirrorUser)) { $null } else { [string]$MirrorUser }
    # Per-client "add everyone to these shared mailboxes by default" list (FR #15): [{ address, access }].
    $defaultMbx = @($DefaultMailboxes | Where-Object { $_ })
    # FR #34: CVP-documented mailbox-auditing config ({ enabled, auditAdmin/auditDelegate/auditOwner }).
    $audit = $MailboxAudit
    # FR #33: per-client FIXED calendar reviewers ([{ user, accessRights }]) granted on every new user's
    # calendar — allowlisted config, same idea as the audit flags above.
    $calReviewers = @($CalendarReviewers | Where-Object { $_ })
    if ($names.Count -eq 0 -and -not $mirror -and $defaultMbx.Count -eq 0 -and -not $audit -and $calReviewers.Count -eq 0) { return $out.ToArray() }

    if (-not (Get-Command Invoke-CtgExchangeNamedGroups -ErrorAction SilentlyContinue)) {
        if ($names.Count) { $out.Add("note: $($names.Count) distribution list(s) not added — ExchangeOnlineManagement isn't installed on this runner, so the Coretelligent.Exchange module didn't load. Install it (or run this client on a runner that has it).") }
        if ($mirror) { $out.Add("note: shared mailboxes / DLs not mirrored — ExchangeOnlineManagement isn't installed on this runner.") }
        if ($defaultMbx.Count) { $out.Add("note: $($defaultMbx.Count) default shared mailbox grant(s) skipped — ExchangeOnlineManagement isn't installed on this runner.") }
        if ($audit) { $out.Add("note: mailbox auditing not applied — ExchangeOnlineManagement isn't installed on this runner.") }
        if ($calReviewers.Count) { $out.Add("note: calendar reviewer grant(s) skipped — ExchangeOnlineManagement isn't installed on this runner.") }
        return $out.ToArray()
    }
    $s = $Creds['m365-admin']
    $certArgs = Get-CtgExoCertArgs $s
    if ($certArgs.Count -eq 0) {
        $out.Add("note: Exchange Online steps skipped — the m365-admin secret has no EXO cert: set CertificateBase64 (a .pfx, cross-platform) or CertificateThumbprint (Windows), and grant the app Exchange.ManageAsApp.")
        return $out.ToArray()
    }
    try {
        $what = @($(if ($names.Count) { 'distribution lists' }), $(if ($mirror) { 'mirror (DLs + shared mailboxes)' }), $(if ($defaultMbx.Count) { "$($defaultMbx.Count) default shared mailbox(es)" }), $(if ($audit) { 'mailbox auditing' }), $(if ($calReviewers.Count) { 'calendar reviewer grants' }) | Where-Object { $_ }) -join ' + '
        # Graph is already this client's here (the m365 lane's own Connect bound it just upstream), so
        # this is normally a no-op — but bind explicitly rather than trusting a caller two lanes away.
        # Depending on distant ordering for tenant correctness is exactly what produced UM0029840.
        [void](Connect-CtgGraphForJob $Job $Creds)
        $exoOrg = Get-CtgExoOrganization $Job $Creds
        Set-CtgPhase $Job.id "finishing over Exchange Online (app-only) for $exoOrg`: $what"
        Connect-CtgExchange -AppId $s.Credential.UserName -Organization $exoOrg @certArgs
        $upn = [string]$Job.payload.UserPrincipalName
        if ($names.Count) { foreach ($a in (Invoke-CtgExchangeNamedGroups -NewUser $upn -Groups $names)) { $out.Add($a) } }
        if ($mirror) {
            foreach ($a in (Invoke-CtgExchangeDistListMirror -MirrorUser $mirror -NewUser $upn)) { $out.Add($a) }
            # BEST-EFFORT + BOUNDED: the shared-mailbox scan does one un-timed EXO read per mailbox; a
            # single stalled session there used to wedge the whole onboard (and everything that dependsOn
            # m365) until the process watchdog restarted the runner. Run it time-bounded in its own
            # runspace so it can never hold the onboard hostage — heartbeat while we wait so the run report
            # keeps moving. Budget via RUNNER_MIRROR_BUDGET_SECONDS (default 300).
            $mirrorBudget = if ($env:RUNNER_MIRROR_BUDGET_SECONDS) { [int]$env:RUNNER_MIRROR_BUDGET_SECONDS } else { 300 }
            $mirrorHeartbeat = { Set-CtgPhase $Job.id "mirroring shared-mailbox permissions from $mirror (bounded scan — up to ${mirrorBudget}s)" }.GetNewClosure()
            foreach ($a in (Invoke-CtgExchangeSharedMailboxMirrorBounded -MirrorUser $mirror -NewUser $upn -AppId $s.Credential.UserName -Organization $exoOrg -CertArgs $certArgs -TimeBudgetSeconds $mirrorBudget -Heartbeat $mirrorHeartbeat)) { $out.Add($a) }
        }
        # FR #15: grant the per-client default shared mailboxes at their chosen level (list-driven,
        # independent of any mirror). Idempotent — a re-run only fills gaps.
        if ($defaultMbx.Count) { foreach ($a in (Invoke-CtgExchangeDefaultMailboxAccess -NewUser $upn -Mailboxes $defaultMbx)) { $out.Add($a) } }
        # FR #34: CVP-documented mailbox-auditing settings — allowlisted config, applied every onboard.
        if ($audit) { foreach ($a in (Invoke-CtgExchangeMailboxAudit -Upn $upn -Config $audit)) { $out.Add($a) } }
        # FR #33: per-client FIXED calendar reviewers — allowlisted config, applied every onboard.
        if ($calReviewers.Count) { foreach ($a in (Invoke-CtgExchangeCalendarReviewers -Identity $upn -Reviewers $calReviewers)) { $out.Add($a) } }
    } catch {
        # The AAD error tells you WHICH problem it is — don't always blame "grant Exchange.ManageAsApp".
        $emsg = [string]$_.Exception.Message
        $appId = try { [string]$s.Credential.UserName } catch { '' }
        $org = try { [string](Get-CtgExoOrganization $Job $Creds) } catch { '' }
        $hint =
            if ($emsg -match 'AADSTS700016|was not found in the directory|AADSTS90002|AADSTS70011|Invalid scope') {
                # TWO different faults produce this, and blaming the app id is wrong half the time:
                # the app may be absent from the right tenant, OR the app is fine and we resolved the
                # WRONG tenant (a domain naming another client's directory). Name the client and the
                # tenant we used so whoever reads this — operator or fix-lane model — can tell which,
                # instead of being steered straight at the secret's app id.
                "the EXO app '$appId' (client '$($Job.client.slug)') isn't registered/consented in the tenant we connected to, '$org'. EITHER (a) '$org' is the WRONG TENANT for this client — if that domain belongs to a DIFFERENT client, the app id is fine and the organization resolved wrong: check the m365-admin secret's TenantId/Domain fields and the client's primary domain; OR (b) '$org' is correct and the app simply isn't there — use an app that EXISTS in this tenant and admin-consent it (a multi-tenant app must be consented in the tenant to create its service principal)."
            }
            elseif ($emsg -match 'AADSTS7000215|invalid client secret|AADSTS700027|AADSTS500011|certificate|Key was not found') {
                "EXO app-only is CERTIFICATE auth (not a client secret): set CertificateBase64 (a .pfx, cross-platform) or CertificateThumbprint (Windows) on the m365-admin secret, and upload that same cert to the app registration."
            }
            elseif ($emsg -match 'Unauthorized|Access.?Denied|do(es)? not have permission|ManageAsApp|insufficient|forbidden') {
                "grant the m365-admin app the Exchange.ManageAsApp APPLICATION permission (admin consent), AND add its service principal to the Exchange Administrator role in '$org' — EXO app-only needs both."
            }
            elseif ($emsg -match "GetResponseHeader|does not contain a method named") {
                # NOT a permissions or certificate problem — the loaded ExchangeOnlineManagement build is
                # the broken 3.10.0, whose REST cmdlets call a method PS7.6 removed. Saying "grant
                # Exchange.ManageAsApp" here sent an operator to re-consent an app that was already
                # fine (FR #0000130). Name the real cause and the real fix.
                "this is NOT a permissions or certificate problem — the ExchangeOnlineManagement module loaded on this runner is a build that breaks on PowerShell 7.6 (its REST cmdlets call a method that was removed). The runner pins $ExoModuleVersion for exactly this reason; install it on this host (Install-Module ExchangeOnlineManagement -RequiredVersion $ExoModuleVersion -Force) and restart the runner."
            }
            else {
                "grant the m365-admin app Exchange.ManageAsApp + set its cert (CertificateBase64 or CertificateThumbprint) on the secret."
            }
        $out.Add("WARN Exchange Online finish failed ($emsg) — $hint")
    }
    return $out.ToArray()
}

# named secret to its resolved credential object (.Credential is a pscredential).
$DISPATCH = @{
    'm365' = @{
        Connect  = { param($job, $creds)
            $tenant = Get-CtgTenantDomain $job $creds
            # Phase carries WHAT we're attempting (tenant + app id, never the secret) so a failure
            # reads "while connecting to m365 (tenant X, app Y): <error>" instead of a bare error.
            Set-CtgPhase $job.id "connecting to m365 (tenant $tenant, app $($creds['m365-admin'].Credential.UserName))"
            Connect-CtgM365 -Credential $creds['m365-admin'].Credential -TenantId $tenant
        }
        Onboard  = { param($job, $creds)
            # Per-client password policy: profile password.requireChangeAtSignIn (injected by the app
            # as config.requireChangeAtSignIn; default true). FR #14 — some clients set up equipment
            # logged in AS the user before handover, so force-change-at-first-sign-in is optional.
            $rcas = (Get-CtgProp $job.config 'requireChangeAtSignIn') -ne $false
            $r = Invoke-CtgM365Onboarding -User $job.payload -Config $job.config -InitialPassword (Resolve-CtgInitialPassword -Job $job -Creds $creds) -RequireChangeAtSignIn:$rcas
            # Finish over Exchange Online with the SAME m365-admin app (cert) — no separate Exchange
            # system needed: the DLs Graph couldn't write, plus (when mirroring) the mirror user's DLs
            # and shared-mailbox permissions. One EXO connection, best-effort.
            $dls = @(if ($r.PSObject.Properties['DeferredDistributionGroups']) { $r.DeferredDistributionGroups })
            $mirror = [string](Get-CtgProp $job.config 'mirrorFromUser')
            # FR #15: per-client default shared-mailbox grants ([{ address, access }]) — added to every
            # new user regardless of mirror. Read here and handed to the same one EXO connection.
            $defaultMbx = @(Get-CtgProp $job.config 'defaultSharedMailboxes')
            # FR #34: CVP-documented mailbox-auditing config ({ enabled, auditAdmin/auditDelegate/auditOwner }).
            $audit = Get-CtgProp $job.config 'mailboxAudit'
            # FR #33: per-client FIXED calendar reviewers — [{ user, accessRights }] granted on every
            # onboarded user's calendar (e.g. Logicsource's calendar.delegate.reviewer@... -> Reviewer).
            $calReviewers = @(Get-CtgProp (Get-CtgProp $job.config 'calendar') 'reviewers')
            # skipExoFinish: set by the planner on the entra lane when m365 is ALSO modeled (same module),
            # so the costly EXO mirror runs once on m365 instead of twice. Skip it here when set.
            if ((Get-CtgProp $job.config 'skipExoFinish')) {
                $r.Actions = @($r.Actions) + "EXO finish skipped — handled by the m365 lane (entra is the same module)"
            }
            elseif ($dls.Count -gt 0 -or $mirror -or $defaultMbx.Count -gt 0 -or $audit -or $calReviewers.Count -gt 0) {
                foreach ($a in (Invoke-CtgM365ExoFinish -Job $job -Creds $creds -Names $dls -MirrorUser $mirror -DefaultMailboxes $defaultMbx -MailboxAudit $audit -CalendarReviewers $calReviewers)) { $r.Actions = @($r.Actions) + $a }
            }
            $r
        }
        # -MailboxSizeGB is what makes the executor's "keep the license on a big mailbox" rule work.
        # The app hands the size down from the Exchange step's result at claim time
        # (config.mailboxSizeGB). Absent means NOT READ and must stay $null — coercing it to 0 made a
        # real empty mailbox indistinguishable from an unreadable one, and the report hid the Convert
        # answer for both. The [System.Nullable[double]] parameter binds $null and JSON numbers as-is.
        Offboard = { param($job, $creds)
            $r = Invoke-CtgM365Offboarding -User $job.payload -Config $job.config -SystemKey ([string]$job.systemKey) -MailboxSizeGB (Get-CtgProp $job.config 'mailboxSizeGB')
            # SharePoint/OneDrive full-access hand-off (Task 5): the named delegate becomes a
            # site-collection admin on the leaver's OneDrive site + any configured SharePoint sites,
            # via PnP app-only auth with the SAME m365-admin cert the EXO lane uses. That cert +
            # AppId + tenant only exist HERE at dispatch level — Invoke-CtgM365Offboarding gets no
            # creds — so this runs AFTER the offboard executor returns and its action lines are
            # merged into the executor's own $r.Actions (mind the result shape: $r is a
            # pscustomobject with an Actions array; append and reassign, don't replace).
            # ENTIRELY fail-soft: PnP.PowerShell being absent ($pnpAvail, set by Task 4's
            # Install-CtgPnPModule gate above) or any grant failing must never fail the offboard —
            # the containment work above (block sign-in, remove groups/license) already ran.
            #
            # offboard-review Fix 1 (SECURITY): Invoke-CtgM365Offboarding can return Status='ok' having
            # done NOTHING — an ambiguous display-name match (2+ users), a near-miss, or no match at
            # all all return early without a UserId, because a human has to pick the right person
            # first. Granting SharePoint/OneDrive access off THAT would hand a leaver's site to the
            # delegate for the wrong (or no) person — gate the whole hand-off on a genuinely resolved
            # offboard. Test-CtgOffboardResolved / Invoke-CtgSharePointOffboardGrant live in the
            # Coretelligent.SharePoint module, which is only IMPORTED when $pnpAvail is true (see the
            # Install-CtgPnPModule gate above) — so the $pnpAvail check must stay the OUTER gate; calling
            # either function first would throw "term not recognized" on a host with no PnP.
            $spDelegate = [string](Get-CtgProp $job.config 'oneDriveGrantAccessTo')
            if ($pnpAvail -and $spDelegate) {
                if (-not (Test-CtgOffboardResolved $r)) {
                    $r.Actions = @($r.Actions) + "SharePoint hand-off skipped — offboard unresolved (ambiguous match, no match, or user not found; pick the right user on the case, then re-run)"
                }
                else {
                    $spActions = [System.Collections.Generic.List[string]]::new()
                    try {
                        $certArgs = Get-CtgExoCertArgs $creds['m365-admin']
                        $appId = Get-CtgM365AppId $creds
                        $tenant = Get-CtgTenantDomain $job $creds
                        # offboard-review Fix 2: delegate-name resolution + the OneDrive/site grants
                        # themselves live in Invoke-CtgSharePointOffboardGrant (Coretelligent.SharePoint.psm1)
                        # so they're unit-testable — Start-IamRunner.ps1 has a mandatory param block and a
                        # main polling loop and can't be dot-sourced for Pester.
                        foreach ($a in (Invoke-CtgSharePointOffboardGrant -Job $job -AppId $appId -Tenant $tenant -CertArgs $certArgs)) { $spActions.Add($a) }
                    }
                    catch { $spActions.Add("WARN SharePoint/OneDrive full-access grant did not run: $($_.Exception.Message)") }
                    if ($spActions.Count -gt 0) { $r.Actions = @($r.Actions) + $spActions.ToArray() }
                }
            }
            # FR #0000116: a named delegate and no PnP used to skip in SILENCE — no action line, no
            # warning, nothing on the case. What the run report then showed was the Graph /invite line
            # from Invoke-CtgM365Offboarding ("granted delegate X access to …'s OneDrive"), green, and
            # the operator had no way to know the full-access grant never happened. The invite is a
            # per-item 'write' permission on the drive root; it is NOT the site-collection admin the
            # hand-off exists to give. Say which one the delegate actually got.
            elseif ($spDelegate) {
                # $spDelegate above is [string] on a value that may be an ARRAY, which joins with a space
                # and turns two people into one nonexistent name — the FR #0000120 bug. It is fine as the
                # gate (any delegate at all), but this line NAMES them, so normalise the same way the
                # M365, Exchange and SharePoint modules do rather than reprinting that mistake.
                $spNames = (@(@(Get-CtgProp $job.config 'oneDriveGrantAccessTo') | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }) -join ', ')
                $r.Actions = @($r.Actions) + "WARN SharePoint hand-off skipped — PnP.PowerShell is not installed on this runner, so $spNames was NOT made site-collection admin on the leaver's OneDrive/SharePoint (the per-item OneDrive invite above is all they have). Install PnP.PowerShell on the runner host, then re-run this step, or grant site access by hand."
            }
            $r
        }
        Change   = { param($job, $creds) Invoke-CtgM365Change -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Confirm-CtgM365 -User $job.payload -Config $job.config -Action $job.action }
    }
    'active-directory' = @{
        Onboard  = { param($job, $creds) Invoke-CtgADOnboarding  -User (Add-ClientContext $job) -Config $job.config -AdConnection (New-CtgAdConnection $creds) }
        Offboard = { param($job, $creds) Invoke-CtgADOffboarding -User (Add-ClientContext $job) -Config $job.config -AdConnection (New-CtgAdConnection $creds) }
        Change   = { param($job, $creds) Invoke-CtgADChange -User (Add-ClientContext $job) -Config $job.config -AdConnection (New-CtgAdConnection $creds) }
        Validate = { param($job, $creds) Confirm-CtgAD -User (Add-ClientContext $job) -Config $job.config -Action $job.action -AdConnection (New-CtgAdConnection $creds) }
    }
    # Write the cloud-assigned email back into AD's `mail` attribute (onboard only). Runs on the client
    # agent via the ActiveDirectory module; the app injects `writebackEmail` into the payload at dispatch.
    'ad-email-writeback' = @{
        Onboard  = { param($job, $creds) Invoke-CtgADEmailWriteback -User (Add-ClientContext $job) -Config $job.config -AdConnection (New-CtgAdConnection $creds) }
        Validate = { param($job, $creds) Confirm-CtgADEmailWriteback -User (Add-ClientContext $job) -Config $job.config -AdConnection (New-CtgAdConnection $creds) }
    }
    # Write the Teams number back into AD's telephoneNumber (onboard only). Runs on the client agent via
    # the ActiveDirectory module; the app injects `writebackPhone` (the teams step's PhoneNumber) at dispatch.
    'ad-phone-writeback' = @{
        Onboard  = { param($job, $creds) Invoke-CtgADPhoneWriteback -User (Add-ClientContext $job) -Config $job.config -AdConnection (New-CtgAdConnection $creds) }
        Validate = { param($job, $creds) Confirm-CtgADPhoneWriteback -User (Add-ClientContext $job) -Config $job.config -AdConnection (New-CtgAdConnection $creds) }
    }
    # Hybrid identity-link check (onboard only, DETECT-ONLY): does the on-prem object's source anchor
    # match the Entra immutableId, or would it duplicate? The app injects the Entra object's anchor data.
    'ad-consistency-check' = @{
        Onboard = { param($job, $creds) Invoke-CtgADConsistencyCheck -User (Add-ClientContext $job) -Config $job.config -AdConnection (New-CtgAdConnection $creds) }
    }
    # Operator-confirmed hard-match: write mS-DS-ConsistencyGuid = the Entra immutableId (app-injected)
    # so AAD Connect links the objects. Dispatched on demand by the "Link" action, not part of a plan.
    'ad-hard-match' = @{
        Onboard = { param($job, $creds) Invoke-CtgADHardMatch -User (Add-ClientContext $job) -Config $job.config -AdConnection (New-CtgAdConnection $creds) }
    }
    'mimecast' = @{
        # Mimecast API 2.0: OAuth2 client-credentials. Template-tolerant — the client id can live in
        # Username OR a ClientID-style field ("Automation - API" template), the client secret in
        # Password OR a ClientSecret-style field. Fails with the fields it saw, never a null-binding.
        Connect  = { param($job, $creds)
            $s = $creds['mimecast']
            if (-not $s) { throw "the job did not broker a 'mimecast' secret — make sure the client's mimecast system lists 'mimecast' in its secrets" }
            $pick = { param($names) foreach ($k in $names) { if ($s.Fields.ContainsKey($k) -and $s.Fields[$k]) { return $s.Fields[$k] } } $null }
            $id = & $pick @('ClientID', 'ClientId', 'Client ID', 'AppId', 'Application ID', 'Username')
            $secret = & $pick @('ClientSecret', 'Client Secret', 'Secret', 'API Key', 'ApiKey', 'AccessToken', 'Token', 'Password')
            if (-not $id -or -not $secret) {
                throw "the 'mimecast' secret needs a CLIENT ID (Username or ClientID field) + CLIENT SECRET (Password or ClientSecret field) from the API 2.0 application; the secret has: $(@($s.Fields.Keys) -join ', ') (see /help/mimecast)"
            }
            Connect-CtgMimecast -Credential ([pscredential]::new([string]$id, (ConvertTo-SecureString ([string]$secret) -AsPlainText -Force)))
        }
        Onboard  = { param($job, $creds) Invoke-CtgMimecastOnboarding  -User $job.payload -Config $job.config -InitialPassword (ConvertFrom-SecureString (Resolve-CtgInitialPassword -Job $job -Creds $creds) -AsPlainText) }
        Offboard = { param($job, $creds) Invoke-CtgMimecastOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Confirm-CtgMimecast -User $job.payload -Config $job.config -Action $job.action }
    }
    'directory-sync' = @{
        # ad-dc credential lets the runner remote into the Entra Connect host (config.host) when the
        # ADSync module isn't on this agent's box (Model A: one DC runner remotes to Core-CCE-AzSync).
        # ad-dc is OPTIONAL now (a DC agent runs ADSync locally, no credential), so it may not be
        # brokered — take .Credential only when present, else $null (Invoke-/Confirm- run locally).
        Onboard  = { param($job, $creds) Invoke-CtgDirectorySync -Config $job.config -Credential (Get-CtgAdDcCredential $creds) }
        Offboard = { param($job, $creds) Invoke-CtgDirectorySync -Config $job.config -Credential (Get-CtgAdDcCredential $creds) }
        Change   = { param($job, $creds) Invoke-CtgDirectorySync -Config $job.config -Credential (Get-CtgAdDcCredential $creds) }
        Validate = { param($job, $creds) Confirm-CtgDirectorySync -User $job.payload -Config $job.config -Action $job.action -Credential (Get-CtgAdDcCredential $creds) }
    }
    'exchange' = @{
        # EXO app-only needs certificate auth (m365-admin carries the cert thumbprint). A hybrid
        # onboard ALSO needs an on-prem Exchange session for Enable-RemoteMailbox — established only
        # when the job brokered the `exchange-onprem` secret (its Fields carry the PowerShell URI).
        Connect  = { param($job, $creds)
            $s = $creds['m365-admin']
            Set-CtgPhase $job.id "connecting to Exchange Online (app-only cert auth, app $($s.Credential.UserName))"
            $exoCert = Get-CtgExoCertArgs $s
            if ($exoCert.Count -eq 0) { throw "the m365-admin secret has no Exchange Online cert — set CertificateBase64 (a .pfx, cross-platform) or CertificateThumbprint (Windows store), and grant the app Exchange.ManageAsApp." }
            # Bind Graph to THIS client before resolving -Organization, so the domain comes from this
            # tenant's own verified domains rather than whatever tenant the (process-wide, fleet-shared)
            # Graph session was last left on. On an offboard this lane runs BEFORE m365/entra, so there
            # is no same-client session to inherit — without this the resolver would fall back to the
            # informational primaryDomain, which is exactly what sent JAMS to the wrong directory.
            # Best-effort: a client whose m365-admin can't drive Graph still falls back as before.
            [void](Connect-CtgGraphForJob $job $creds)
            # Connect-CtgExchange closes any existing session itself — that teardown lives inside the
            # module so it can't fail to resolve, which is what an unguarded call from here did in
            # 1.66.0 (it threw before we ever connected, breaking exchange for every client).
            Connect-CtgExchange -AppId $s.Credential.UserName -Organization (Get-CtgExoOrganization $job $creds) @exoCert
            # On-prem session for BOTH lanes when the `exchange-onprem` secret is brokered: onboard
            # needs Enable-RemoteMailbox; a HYBRID offboard needs Set-RemoteMailbox -Type Shared
            # (an EXO Set-Mailbox would be overwritten by AD Connect on an on-prem-mastered mailbox).
            # The credential may reuse the ad-dc Delinea id (the domain admin already has Exchange
            # rights). The PowerShell URI comes from the secret's ConnectionUri field if present, else
            # the system config (`onPremExchangeUri`) — so reusing ad-dc needs no extra Delinea field.
            $op = $creds['exchange-onprem']
            if ($op) {
                # The PowerShell endpoint URI can live in any of these secret fields (so an existing
                # "Document Link"/"URL" field can be reused instead of adding a ConnectionUri one),
                # else falls back to the exchange system config's onPremExchangeUri.
                $pickUri = { param($names) foreach ($k in $names) { if ($op.Fields.ContainsKey($k) -and $op.Fields[$k]) { return [string]$op.Fields[$k] } } $null }
                $opUri = & $pickUri @('ConnectionUri', 'ConnectionUrl', 'ConnectionURL', 'Uri', 'Url', 'URL', 'PowerShellUri', 'PowerShellUrl', 'Link', 'DocumentLink', 'Document Link')
                # System config: a real job's config is the action sub-object (top-level key); a
                # connection test passes the whole config, so also look under onboard/offboard.
                if (-not $opUri) {
                    $cfg = $job.config
                    $opUri = [string]((Get-CtgProp $cfg 'onPremExchangeUri') ?? (Get-CtgProp (Get-CtgProp $cfg 'offboard') 'onPremExchangeUri') ?? (Get-CtgProp (Get-CtgProp $cfg 'onboard') 'onPremExchangeUri'))
                }
                if (-not $opUri) { throw "the on-prem Exchange session needs a PowerShell URI — set ConnectionUri (or a Document Link / URL field) on the exchange-onprem secret, or onPremExchangeUri on the exchange system. e.g. http://core-cce1-ex01.core.tech/PowerShell/" }
                Set-CtgPhase $job.id "connecting to on-prem Exchange ($opUri)"
                Connect-CtgExchangeOnPrem -ConnectionUri $opUri -Credential $op.Credential
            }
        }
        # Close the EXO session once this client's onboard/offboard is done, so the next client starts
        # from nothing instead of inheriting a live session bound to someone else's tenant. The job
        # loop calls this in a finally and forgets the cache key in the same breath.
        Disconnect = { Disconnect-CtgExchange }
        # Hybrid onboard, one pass across the sync boundary: enable remote mailbox -> trigger an Entra
        # Connect delta sync (so the mailbox provisions now) -> wait for it -> regional/calendar. The
        # sync trigger reuses the on-prem (ad-dc) credential and auto-discovers the Entra Connect host.
        Onboard  = { param($job, $creds)
            # CLOUD client (no on-prem Exchange session brokered): the M365 license already made the
            # mailbox, so skip Enable-RemoteMailbox and just do the EXO-only work — add the requested
            # distribution lists by name. HYBRID (on-prem session present): the full remote-mailbox pass.
            if (-not $creds['exchange-onprem']) {
                Invoke-CtgExchangeCloudOnboard -User $job.payload -Config $job.config
            }
            else {
                $syncCred = ($creds['exchange-onprem']).Credential
                $trigger = if ($syncCred) { { Invoke-CtgDirectorySync -Config ([pscustomobject]@{}) -Credential $syncCred | Out-Null }.GetNewClosure() } else { $null }
                Invoke-CtgExchangeHybridOnboard -User $job.payload -Config $job.config -TriggerSync $trigger
            }
        }
        Offboard = { param($job, $creds)
            # Pass a delta-sync trigger (reusing the on-prem credential) so a HYBRID convert-to-shared
            # via Set-RemoteMailbox is pushed to the cloud immediately; cloud-only offboards ignore it.
            $op = $creds['exchange-onprem']
            $syncCred = if ($op) { $op.Credential } else { $null }
            $trigger = if ($syncCred) { { Invoke-CtgDirectorySync -Config ([pscustomobject]@{}) -Credential $syncCred | Out-Null }.GetNewClosure() } else { $null }
            Invoke-CtgExchangeOffboarding -User $job.payload -Config $job.config -TriggerSync $trigger
        }
        Validate = { param($job, $creds) Confirm-CtgExchange -User $job.payload -Config $job.config -Action $job.action }
        Change   = { param($job, $creds) Invoke-CtgExchangeChange -User $job.payload -Config $job.config }
    }
    # Teams Phone: assign a Calling Plan number on onboard, release it on offboard. MicrosoftTeams
    # ships the same identity assemblies Graph and EXO already loaded here, so ALL of it runs in a child
    # pwsh (Invoke-CtgTeamsOutOfProcess) signed in with the m365-admin app certificate — no Connect key,
    # and nothing Teams ever loads into this process. A dry run reaches the child as WhatIf.
    'teams' = @{
        Onboard  = { param($job, $creds) $a = Get-CtgTeamsAuth $job $creds; Invoke-CtgTeamsOutOfProcess -Action onboard  -User $job.payload -Config $job.config @a }
        Offboard = { param($job, $creds) $a = Get-CtgTeamsAuth $job $creds; Invoke-CtgTeamsOutOfProcess -Action offboard -User $job.payload -Config $job.config @a }
        Validate = { param($job, $creds) $a = Get-CtgTeamsAuth $job $creds; Invoke-CtgTeamsOutOfProcess -Action validate -ValidateAction $job.action -User $job.payload -Config $job.config @a }
    }
    'zoom' = @{
        Connect  = { param($job, $creds) Use-CtgZoomSecret -Job $job -Creds $creds }
        Onboard  = { param($job, $creds) Invoke-CtgZoomOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Invoke-CtgZoomOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Confirm-CtgZoom -User $job.payload -Config $job.config -Action $job.action }
    }
    'adobe' = @{
        Connect  = { param($job, $creds) Use-CtgAdobeSecret -Job $job -Creds $creds }
        Onboard  = { param($job, $creds) Invoke-CtgAdobeOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Invoke-CtgAdobeOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Confirm-CtgAdobe -User $job.payload -Config $job.config -Action $job.action }
    }
    'perimeter81' = @{
        Connect  = { param($job, $creds) Connect-CtgPerimeter81 -ApiKey $creds['perimeter81'].Fields['ApiKey'] }
        Onboard  = { param($job, $creds) Invoke-CtgPerimeter81Onboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Invoke-CtgPerimeter81Offboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Confirm-CtgPerimeter81 -User $job.payload -Config $job.config -Action $job.action }
    }
    'egnyte' = @{
        # Egnyte: per-tenant host https://{Domain}.egnyte.com, OAuth2 bearer. The runner mints a token via
        # the Resource Owner Password grant from ClientID (the API Key) + ClientSecret (the API Secret) +
        # AccountID/Username (the admin login EMAIL, the OAuth username) + Password. A pre-minted long-lived
        # Token stands in for all four. Domain is the tenant subdomain (e.g. "drakestar"); when absent it's
        # derived from the login email's domain label. NB the login email lives in AccountID (the stock
        # "Automation - API" template's accountid slot), which CRED_USERNAME_FIELDS does NOT pick — so this
        # block reads username/password off $s.Fields directly rather than relying on $s.Credential.
        # Template-tolerant field matching; actionable errors.
        Connect  = { param($job, $creds)
            $s = $creds['egnyte']
            if (-not $s) { throw "the job did not broker an 'egnyte' secret — make sure the client's egnyte system lists 'egnyte' in its secrets" }
            $pick = { param($names) foreach ($k in $names) { if ($s.Fields.ContainsKey($k) -and $s.Fields[$k]) { return $s.Fields[$k] } } $null }
            $account = & $pick @('accountid', 'AccountID', 'AccountId', 'Account ID', 'Account', 'Username', 'Email', 'Login', 'User')
            $domain = & $pick @('Domain', 'EgnyteDomain', 'Egnyte Domain', 'Tenant')
            # Derive the tenant subdomain from the login email's domain label when no explicit Domain field.
            if (-not $domain -and $account -match '@') { $domain = (($account -split '@')[1] -split '\.')[0] }
            if (-not $domain) { throw "the 'egnyte' secret has no Domain field and no login email to derive it from — set Domain to the tenant subdomain (e.g. 'drakestar' for drakestar.egnyte.com), or an AccountID/Username email; the secret has: $(@($s.Fields.Keys) -join ', ') (see /help/egnyte)" }
            $token = & $pick @('Token', 'AccessToken', 'Access Token', 'ApiToken', 'Api Token', 'Bearer')
            if ($token) { Connect-CtgEgnyte -Domain $domain -Token $token; return }
            $clientId = & $pick @('ClientID', 'ClientId', 'Client ID', 'Key', 'APIKey', 'API Key', 'Api Key', 'ApiKey')
            $clientSecret = & $pick @('ClientSecret', 'Client Secret', 'Secret', 'API Secret', 'APISecret')
            $password = & $pick @('Password', 'Pass')
            if (-not $clientId -or -not $clientSecret -or -not $account -or -not $password) {
                throw "the 'egnyte' secret needs a long-lived Token, OR all four of ClientID (key) + ClientSecret + AccountID/Username (the admin login email) + Password for the password grant; the secret has: $(@($s.Fields.Keys) -join ', ') (see /help/egnyte)"
            }
            $cred = [pscredential]::new([string]$account, (ConvertTo-SecureString ([string]$password) -AsPlainText -Force))
            Connect-CtgEgnyte -Domain $domain -ClientId $clientId -ClientSecret $clientSecret -Credential $cred
        }
        Onboard  = { param($job, $creds) Invoke-CtgEgnyteOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Invoke-CtgEgnyteOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Confirm-CtgEgnyte -User $job.payload -Config $job.config -Action $job.action }
    }
    'spanning' = @{
        # Spanning Backup: HTTP Basic auth, username = the CLIENT ID, password = the CLIENT SECRET
        # (see Use-CtgSpanningSecret). NO Connect block ON PURPOSE: Connect-CtgSpanning is a pure
        # local assignment (no network), so each lane just re-reads the brokered secret (free) —
        # which also means a rotated credential applies on the very next job.
        Onboard  = { param($job, $creds) Use-CtgSpanningSecret $job $creds; Invoke-CtgSpanningOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Use-CtgSpanningSecret $job $creds; Invoke-CtgSpanningOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Use-CtgSpanningSecret $job $creds; Confirm-CtgSpanning -User $job.payload -Config $job.config -Action $job.action }
    }
    'slack' = @{
        # Slack SCIM: onboard invites/creates, offboard DEACTIVATES (SCIM DELETE switches the account
        # off and keeps messages/files — it does not erase the member). No Connect block: Connect-CtgSlack
        # is a pure local assignment (no network), so each lane re-reads the brokered secret for free —
        # which also means a rotated token applies on the very next job.
        Onboard  = { param($job, $creds) Use-CtgSlackSecret $job $creds; Invoke-CtgSlackOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Use-CtgSlackSecret $job $creds; Invoke-CtgSlackOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Use-CtgSlackSecret $job $creds; Confirm-CtgSlack -User $job.payload -Config $job.config -Action $job.action }
    }
    'proofpoint' = @{
        # Proofpoint Essentials: read-only sync verification (X-User/X-Password admin auth). No Connect
        # block — Connect-CtgProofpoint is a pure local assignment, so each lane re-reads the brokered
        # secret (a rotated credential applies on the next job). Provisioning is sync-driven; the lanes
        # verify presence and (on onboard) auto-retry until Proofpoint's scheduled sync imports the user.
        Onboard  = { param($job, $creds) Use-CtgProofpointSecret $job $creds; Invoke-CtgProofpointOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Use-CtgProofpointSecret $job $creds; Invoke-CtgProofpointOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Use-CtgProofpointSecret $job $creds; Confirm-CtgProofpoint -User $job.payload -Config $job.config -Action $job.action }
    }
    '1password' = @{
        # Method-aware (config.method: auto|api|scim|manual|browser). No standing Connect block: each lane
        # decides via Connect-Ctg1PasswordForJob whether to establish an `op` admin session (api requires
        # it; auto/scim are best-effort -> $connected drives the module's manual fallback / verify).
        Onboard  = { param($job, $creds) $c = Connect-Ctg1PasswordForJob $job $creds; Invoke-Ctg1PasswordOnboarding  -User $job.payload -Config $job.config -Connected $c }
        Offboard = { param($job, $creds) $c = Connect-Ctg1PasswordForJob $job $creds; Invoke-Ctg1PasswordOffboarding -User $job.payload -Config $job.config -Connected $c }
        Validate = { param($job, $creds) $c = Connect-Ctg1PasswordForJob $job $creds; Confirm-Ctg1Password -User $job.payload -Config $job.config -Action $job.action -Connected $c }
    }
    'google-workspace' = @{
        Connect  = { param($job, $creds) Use-CtgGoogleSecret -Job $job -Creds $creds }
        Onboard  = { param($job, $creds) Invoke-CtgGoogleOnboarding  -User $job.payload -Config $job.config -InitialPassword (New-CtgCompliantPassword) }
        Offboard = { param($job, $creds) Invoke-CtgGoogleOffboarding -User $job.payload -Config $job.config }
        Change   = { param($job, $creds) Invoke-CtgGoogleChange -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Confirm-CtgGoogle -User $job.payload -Config $job.config -Action $job.action }
    }
    'salesforce' = @{
        Connect  = { param($job, $creds) Use-CtgSalesforceSecret $job $creds }
        Onboard  = { param($job, $creds) Invoke-CtgSalesforceOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Invoke-CtgSalesforceOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Confirm-CtgSalesforce -User $job.payload -Config $job.config -Action $job.action }
    }
    'knowbe4' = @{
        # No network in Connect — re-broker the SCIM token each lane (a rotated token applies next job).
        Onboard  = { param($job, $creds) Use-CtgKnowBe4Secret $job $creds; Invoke-CtgKnowBe4Onboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Use-CtgKnowBe4Secret $job $creds; Invoke-CtgKnowBe4Offboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Use-CtgKnowBe4Secret $job $creds; Confirm-CtgKnowBe4 -User $job.payload -Config $job.config -Action $job.action }
    }
    'jira' = @{
        Onboard  = { param($job, $creds) Use-CtgJiraSecret $job $creds; Invoke-CtgJiraOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Use-CtgJiraSecret $job $creds; Invoke-CtgJiraOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Use-CtgJiraSecret $job $creds; Confirm-CtgJira -User $job.payload -Config $job.config -Action $job.action }
    }
    'hubspot' = @{
        Onboard  = { param($job, $creds) Use-CtgHubSpotSecret $job $creds; Invoke-CtgHubSpotOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Use-CtgHubSpotSecret $job $creds; Invoke-CtgHubSpotOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Use-CtgHubSpotSecret $job $creds; Confirm-CtgHubSpot -User $job.payload -Config $job.config -Action $job.action }
    }
    'sentinelone' = @{
        # Connect key (vs inline) so the connection-test harness can exercise it; the job loop's
        # connect-cache re-brokers when the credential fingerprint changes (rotated token next job).
        Connect  = { param($job, $creds) Use-CtgSentinelOneSecret $job $creds }
        Onboard  = { param($job, $creds) Invoke-CtgSentinelOneOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds)
            # In-app "Reconnect": a one-off job carrying config.reconnect = @{ agentId; machine } — undo an
            # isolation rather than create one.
            $rc = Get-CtgProp $job.config 'reconnect'
            if ($rc) { return Invoke-CtgSentinelOneReconnect -AgentId ([string](Get-CtgProp $rc 'agentId')) -Machine ([string](Get-CtgProp $rc 'machine')) }
            # Normal offboard: network-isolate EVERY one of the user's Entra-registered devices.
            Invoke-CtgSentinelOneOffboarding -User $job.payload -Config $job.config -Machines (Get-CtgSentinelOneMachines $job $creds)
        }
        Validate = { param($job, $creds) Confirm-CtgSentinelOne -User $job.payload -Config $job.config -Action $job.action -Machines (Get-CtgSentinelOneMachines $job $creds) }
    }
    'duo' = @{
        Onboard  = { param($job, $creds) Use-CtgDuoSecret $job $creds; Invoke-CtgDuoOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Use-CtgDuoSecret $job $creds; Invoke-CtgDuoOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Use-CtgDuoSecret $job $creds; Confirm-CtgDuo -User $job.payload -Config $job.config -Action $job.action }
    }
    'xmatters' = @{
        Connect  = { param($job, $creds) Use-CtgXMattersSecret $job $creds }
        Onboard  = { param($job, $creds) Invoke-CtgXMattersOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Invoke-CtgXMattersOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Confirm-CtgXMatters -User $job.payload -Config $job.config -Action $job.action }
    }
    'logicmonitor' = @{
        Onboard  = { param($job, $creds) Use-CtgLogicMonitorSecret $job $creds; Invoke-CtgLogicMonitorOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Use-CtgLogicMonitorSecret $job $creds; Invoke-CtgLogicMonitorOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Use-CtgLogicMonitorSecret $job $creds; Confirm-CtgLogicMonitor -User $job.payload -Config $job.config -Action $job.action }
    }
    'notify' = @{
        # Sends offboard emails via Graph sendMail using the m365-admin app — reuse the m365 Connect so
        # the ambient Microsoft.Graph context (Send-MgUserMail) is established. Runs last in the offboard.
        Connect  = { param($job, $creds)
            $tenant = Get-CtgTenantDomain $job $creds
            Set-CtgPhase $job.id "connecting to Graph for notifications (tenant $tenant, app $($creds['m365-admin'].Credential.UserName))"
            Connect-CtgM365 -Credential $creds['m365-admin'].Credential -TenantId $tenant
        }
        Onboard  = { param($job, $creds) Invoke-CtgNotifyOnboarding  -User $job.payload -Config $job.config }
        Offboard = { param($job, $creds) Invoke-CtgNotifyOffboarding -User $job.payload -Config $job.config }
        Validate = { param($job, $creds) Confirm-CtgNotify -User $job.payload -Config $job.config -Action $job.action }
    }
}

# entra is the Entra-ID slice of the M365 module — same executor + read-backs (catalog
# moduleName = Coretelligent.M365). Alias it so an `entra` job isn't left without an executor.
$DISPATCH['entra'] = $DISPATCH['m365']

# Ad-hoc "Generate random password" (INC0855142): dispatched on demand from a case's account line,
# never planned. The app generates the value, injects it as config.newPassword at claim, and reveals
# it once operator-side — the executors never return it. One executor per system serves both lanes
# (the wire `action` is the CASE's, and a reset can ride either kind of case); Connect lanes are
# aliased from the owning system so a connection fix reaches the reset automatically.
$DISPATCH['ad-password-reset'] = @{
    Onboard = { param($job, $creds) Invoke-CtgADPasswordReset -User (Add-ClientContext $job) -Config $job.config -AdConnection (New-CtgAdConnection $creds) }
}
$DISPATCH['m365-password-reset'] = @{
    Connect = $DISPATCH['m365'].Connect
    Onboard = { param($job, $creds) Invoke-CtgM365PasswordReset -User $job.payload -Config $job.config }
}
$DISPATCH['google-password-reset'] = @{
    Connect = $DISPATCH['google-workspace'].Connect
    Onboard = { param($job, $creds) Invoke-CtgGooglePasswordReset -User $job.payload -Config $job.config }
}
foreach ($k in 'ad-password-reset', 'm365-password-reset', 'google-password-reset') { $DISPATCH[$k].Offboard = $DISPATCH[$k].Onboard }

# Ad-hoc "force Spanning sync" (browser automation): dispatched on demand from a case's Spanning step
# to make Spanning discover a just-created M365 user NOW (the Spanning API has no sync endpoint). Rides
# the Spanning line's brokered secret; no Connect lane (the browser flow does its own portal login).
# One executor serves both lanes (a force-sync can ride an onboard or an offboard case). Withheld from
# agents that don't report the 'browser' capability (see $script:RunnerCapabilities below).
$DISPATCH['spanning-force-sync'] = @{
    # OtpRequest is a REQUEST SPEC the browser flow itself calls when the MFA box is actually visible,
    # so the 30-second Delinea-minted code can't go stale in transit (browser launch + portal load +
    # the SSO hop routinely outlive a TOTP window). The seed stays in Delinea; we only ever hold a code.
    Onboard = { param($job, $creds)
        # The console is Microsoft 365 SSO, so this signs in with the client's PORTAL secret (an M365
        # admin), NOT the Spanning API credential. Older clients wired only 'spanning' — fall back to it
        # so they get the actionable "wire a spanning-portal secret" warning from the module rather than
        # an opaque null-secret crash. The OTP MUST be minted from the SAME secret we sign in with:
        # the one-time password is enrolled on the portal login, not on the API credential.
        $secretName = if ($creds.ContainsKey('spanning-portal') -and $creds['spanning-portal']) { 'spanning-portal' } else { 'spanning' }
        Invoke-CtgSpanningForceSync -User $job.payload -Config $job.config -Secret $creds[$secretName] -SecretName $secretName `
            -OtpRequest @{ url = "$AppUrl/api/jobs/$($job.id)/credential"; token = (Get-CtgBearer); agentId = $AgentId; secretName = $secretName }
    }
}
$DISPATCH['spanning-force-sync'].Offboard = $DISPATCH['spanning-force-sync'].Onboard

# Ad-hoc "complete an Entra device-code sign-in" (browser automation): drives microsoft.com/devicelogin
# as a Global Admin to complete a device-code OAuth flow headlessly, reusing the SAME MS-SSO login
# machinery spanning-force-sync's browser flow uses (runner/browser/lib/ms-sso-login.mjs) — only the
# page before it (device-code entry vs a portal's "Log in with Microsoft" button) differs. Rides the
# 'm365-global-admin' secret (an interactive GA email + password, NOT the Graph app registration); no
# Connect lane (the browser flow does its own Microsoft sign-in). One executor serves both lanes.
# Withheld from agents that don't report the 'browser' capability (see $script:RunnerCapabilities
# below). LIVE-VALIDATION PENDING (see runner/browser/flows/entra-devicecode.mjs header) — faithful,
# parse-clean code exercised against Microsoft's documented device-login page, not yet the live console.
$DISPATCH['entra-devicecode'] = @{
    Onboard = { param($job, $creds)
        $secretName = 'm365-global-admin'
        Invoke-CtgEntraDeviceCode -Config $job.config -Secret $creds[$secretName] -SecretName $secretName `
            -UserCode (Get-CtgProp $job.config 'userCode') `
            -OtpRequest @{ url = "$AppUrl/api/jobs/$($job.id)/credential"; token = (Get-CtgBearer); agentId = $AgentId; secretName = $secretName }
    }
}
$DISPATCH['entra-devicecode'].Offboard = $DISPATCH['entra-devicecode'].Onboard

# Ad-hoc "Google super-admin OAuth sign-in" (browser automation): drives Google's own sign-in + OAuth
# consent as the interactive Workspace SUPER-ADMIN to capture the authorization code the app needs to
# provision a GCP project + service account for the automated Google Workspace setup. Rides the
# 'google-super-admin' secret (an interactive super-admin email + password + One-Time Password), NOT
# the 'google-admin' service-account key the API lane uses; no Connect lane (the browser flow does its
# own Google sign-in). One executor serves both lanes. Withheld from agents without the 'browser'
# capability (BROWSER_SYSTEMS app-side). LIVE-VALIDATION PENDING (see the flow file header).
$DISPATCH['google-oauth-signin'] = @{
    Onboard = { param($job, $creds)
        $secretName = 'google-super-admin'
        Invoke-CtgGoogleOAuthSignin -Config $job.config -Secret $creds[$secretName] -SecretName $secretName `
            -OtpRequest @{ url = "$AppUrl/api/jobs/$($job.id)/credential"; token = (Get-CtgBearer); agentId = $AgentId; secretName = $secretName }
    }
}
$DISPATCH['google-oauth-signin'].Offboard = $DISPATCH['google-oauth-signin'].Onboard

# Ad-hoc "Google domain-wide delegation grant" (browser automation): with the super-admin signed in,
# grant/reconcile DWD scopes for the just-provisioned service account in the Admin console. Same secret
# and gating as google-oauth-signin; a grant that can't be confirmed FAILS the job so the app falls
# back to a manual grant (the DWD app path keys off job success, not a result line). One executor
# serves both lanes. LIVE-VALIDATION PENDING (see the flow file header).
$DISPATCH['google-dwd-grant'] = @{
    Onboard = { param($job, $creds)
        $secretName = 'google-super-admin'
        Invoke-CtgGoogleDwdGrant -Config $job.config -Secret $creds[$secretName] -SecretName $secretName `
            -OtpRequest @{ url = "$AppUrl/api/jobs/$($job.id)/credential"; token = (Get-CtgBearer); agentId = $AgentId; secretName = $secretName }
    }
}
$DISPATCH['google-dwd-grant'].Offboard = $DISPATCH['google-dwd-grant'].Onboard

# Ad-hoc "Mimecast console setup" (browser automation): sign into the Mimecast Administration Console
# (login.mimecast.com) to set up the API 2.0 credential. Phase 1 is a SIGN-IN TEST (config.signInOnly)
# — prove the console login + MFA work. Rides the 'mimecast-console' secret (a Mimecast admin email +
# password + One-Time Password), NOT the 'mimecast' API 2.0 clientId/secret; no Connect lane (the
# browser flow does its own Mimecast sign-in). One executor serves both lanes. Withheld from agents
# without the 'browser' capability (BROWSER_SYSTEMS app-side). LIVE-VALIDATION PENDING (see the flow
# file header) — the Mimecast console DOM/MFA is unverified.
$DISPATCH['mimecast-console-setup'] = @{
    Onboard = { param($job, $creds)
        $secretName = 'mimecast-console'
        Invoke-CtgMimecastConsoleSetup -Config $job.config -Secret $creds[$secretName] -SecretName $secretName `
            -OtpRequest @{ url = "$AppUrl/api/jobs/$($job.id)/credential"; token = (Get-CtgBearer); agentId = $AgentId; secretName = $secretName }
    }
}
$DISPATCH['mimecast-console-setup'].Offboard = $DISPATCH['mimecast-console-setup'].Onboard

# Ad-hoc "Spanning console setup" (browser automation): sign into the Spanning admin console (M365 SSO)
# and generate + harvest the Settings → API Token, which the app vaults as the `spanning` credential.
# Rides the 'spanning-portal' secret (the M365 admin login for the console, OTP enabled), NOT the
# 'spanning' API credential we're creating; no Connect lane (the browser flow does its own MS sign-in,
# reusing lib/ms-sso-login.mjs). One executor serves both lanes. Withheld from agents without the
# 'browser' capability. LIVE-VALIDATION PENDING (see runner/browser/flows/spanning-console-setup.mjs).
$DISPATCH['spanning-console-setup'] = @{
    Onboard = { param($job, $creds)
        $secretName = 'spanning-portal'
        Invoke-CtgSpanningConsoleSetup -Config $job.config -Secret $creds[$secretName] -SecretName $secretName `
            -OtpRequest @{ url = "$AppUrl/api/jobs/$($job.id)/credential"; token = (Get-CtgBearer); agentId = $AgentId; secretName = $secretName }
    }
}
$DISPATCH['spanning-console-setup'].Offboard = $DISPATCH['spanning-console-setup'].Onboard

# zoom-console-setup — sign in to Zoom + create/harvest the Server-to-Server OAuth app (the 'zoom' API
# credential). Browser-only; claimable solely by a browser-capable agent (BROWSER_SYSTEMS app-side).
# LIVE-VALIDATION PENDING (see the flow file header) — the Zoom sign-in + Marketplace DOM are unverified.
$DISPATCH['zoom-console-setup'] = @{
    Onboard = { param($job, $creds)
        $secretName = 'zoom-console'
        Invoke-CtgZoomConsoleSetup -Config $job.config -Secret $creds[$secretName] -SecretName $secretName
    }
}
$DISPATCH['zoom-console-setup'].Offboard = $DISPATCH['zoom-console-setup'].Onboard
# Ad-hoc "Adobe console setup" (browser automation): sign into the Adobe Developer Console
# (developer.adobe.com/console) to create the User Management API OAuth Server-to-Server credential and
# harvest its Client ID / Client Secret / Org ID. Rides the 'adobe-console' secret (an Adobe admin email
# + password + One-Time Password), NOT the 'adobe' API clientId/secret it PRODUCES; no Connect lane (the
# browser flow does its own Adobe sign-in). Withheld from agents without the 'browser' capability
# (BROWSER_SYSTEMS app-side). LIVE-VALIDATION PENDING — the Adobe login + Developer Console DOM are
# unverified (see runner/browser/flows/adobe-console-setup.mjs header).
$DISPATCH['adobe-console-setup'] = @{
    Onboard = { param($job, $creds)
        $secretName = 'adobe-console'
        Invoke-CtgAdobeConsoleSetup -Config $job.config -Secret $creds[$secretName] -SecretName $secretName `
            -OtpRequest @{ url = "$AppUrl/api/jobs/$($job.id)/credential"; token = (Get-CtgBearer); agentId = $AgentId; secretName = $secretName }
    }
}
$DISPATCH['adobe-console-setup'].Offboard = $DISPATCH['adobe-console-setup'].Onboard
# slack-console-setup — sign in to Slack + BEST-EFFORT harvest a SCIM token (the 'slack' API cred).
# Browser-only; claimable solely by a browser-capable agent (BROWSER_SYSTEMS app-side). Slack SCIM
# tokens usually are NOT console-harvestable (they come from an app install with the admin scope), so
# a "signed in, no token" result is expected and the operator pastes the token instead.
# LIVE-VALIDATION PENDING (see the flow file header) — the Slack sign-in + console DOM are unverified.
$DISPATCH['slack-console-setup'] = @{
    Onboard = { param($job, $creds)
        $secretName = 'slack-console'
        Invoke-CtgSlackConsoleSetup -Config $job.config -Secret $creds[$secretName] -SecretName $secretName
    }
}
$DISPATCH['slack-console-setup'].Offboard = $DISPATCH['slack-console-setup'].Onboard
# egnyte-console-setup — sign in to a client's Egnyte admin + harvest the domain API token (the 'egnyte'
# API credential). Browser-only; claimable solely by a browser-capable agent (BROWSER_SYSTEMS app-side).
# LIVE-VALIDATION PENDING (see the flow file header) — the Egnyte sign-in + API-token DOM are unverified.
$DISPATCH['egnyte-console-setup'] = @{
    Onboard = { param($job, $creds)
        $secretName = 'egnyte-console'
        Invoke-CtgEgnyteConsoleSetup -Config $job.config -Secret $creds[$secretName] -SecretName $secretName
    }
}
$DISPATCH['egnyte-console-setup'].Offboard = $DISPATCH['egnyte-console-setup'].Onboard
# knowbe4-console-setup — sign in to KnowBe4 + enable/harvest the SCIM provisioning token (the 'knowbe4'
# API credential). Browser-only; claimable solely by a browser-capable agent (BROWSER_SYSTEMS app-side).
# Rides the 'knowbe4-console' secret (admin email + password + optional OTP), NOT the SCIM token it
# creates. LIVE-VALIDATION PENDING (see the flow file header) — the KnowBe4 console DOM is unverified.
$DISPATCH['knowbe4-console-setup'] = @{
    Onboard = { param($job, $creds)
        $secretName = 'knowbe4-console'
        Invoke-CtgKnowBe4ConsoleSetup -Config $job.config -Secret $creds[$secretName] -SecretName $secretName
    }
}
$DISPATCH['knowbe4-console-setup'].Offboard = $DISPATCH['knowbe4-console-setup'].Onboard

# tap issues an Entra Temporary Access Pass — same Graph connection as m365, its own onboard executor.
# Offboard/Validate are no-ops (the TAP is short-lived and self-expires; nothing to tear down/verify).
$DISPATCH['tap'] = @{
    Connect  = $DISPATCH['m365'].Connect
    Onboard  = { param($job, $creds) Invoke-CtgEntraTap -User (Add-ClientContext $job) -Config $job.config }
    Offboard = { param($job, $creds) [pscustomobject]@{ System = 'tap'; Status = 'ok'; Actions = @('no TAP teardown needed (it self-expires)') } }
    Validate = { param($job, $creds) [pscustomobject]@{ System = 'tap'; Ok = $true; Detail = 'TAP is issue-only (self-expiring); nothing to verify' } }
}

# LOW-CODE CONNECTORS (docs/CONNECTOR_BUILDER.md): a custom-* systemKey has no $DISPATCH entry of its
# own — the job carries its PUBLISHED definition (config.connector, injected by the app at claim) and
# this ONE generic handler interprets it. Looked up as the FALLBACK below, after the built-in table,
# so a connector key can never shadow a hand-written executor. No Connect block: auth is declared in
# the definition and applied per request (bearer/basic/header/oauth2), so there is no session to pin.
$CONNECTOR_HANDLER = @{
    Onboard  = { param($job, $creds)
        $kind = [string](Get-CtgProp (Get-CtgProp $job.config 'connector') 'kind')
        if ($kind -eq 'browser') { Invoke-CtgConnectorBrowserLane -Job $job -Creds $creds -Lane 'onboard' }
        else { Invoke-CtgConnectorOnboarding -User $job.payload -Config $job.config -Credentials $creds -Client $job.client -SystemKey ([string]$job.systemKey) }
    }
    Offboard = { param($job, $creds)
        $kind = [string](Get-CtgProp (Get-CtgProp $job.config 'connector') 'kind')
        if ($kind -eq 'browser') { Invoke-CtgConnectorBrowserLane -Job $job -Creds $creds -Lane 'offboard' }
        else { Invoke-CtgConnectorOffboarding -User $job.payload -Config $job.config -Credentials $creds -Client $job.client -SystemKey ([string]$job.systemKey) }
    }
}

# Action -> validate, with idempotent auto-retry. On a validation miss we re-run the (idempotent)
# action and re-validate up to $MaxRevalidate times — this self-heals eventual-consistency lags.
# A persistent miss is NOT a failure: the job still succeeds; the validation block (ok=$false)
# rides along on the result and the app's run report flags it as a warning.
$MaxRevalidate = 2

function Invoke-JobWithValidation {
    param($Job, $Handler, [scriptblock]$Fn, $Creds, [bool]$DryRun)

    # Dry run: set WhatIf so every module's SupportsShouldProcess short-circuits the mutations, then
    # run the validators read-only. MUST be $global: — module functions (Coretelligent.*) resolve
    # preference variables from their own/module/GLOBAL scope, NOT the caller's, so a local
    # $WhatIfPreference here would be ignored and the executors would run LIVE despite dry-run.
    if ($DryRun) { $global:WhatIfPreference = $true }
    try { $result = & $Fn $Job $Creds }
    finally { if ($DryRun) { $global:WhatIfPreference = $false } }

    $validate = if ($Handler.ContainsKey('Validate')) { $Handler['Validate'] } else { $null }
    $validation = $null
    if ($validate) {
        $validation = & $validate $Job $Creds
        $attempt = 0
        while ($validation -and -not $validation.ok -and -not $DryRun -and $attempt -lt $MaxRevalidate) {
            Start-Sleep -Seconds (2 * ($attempt + 1))
            $result = & $Fn $Job $Creds          # idempotent re-run
            $validation = & $validate $Job $Creds
            $attempt++
        }
    }
    [pscustomobject]@{ Result = $result; Validation = $validation }
}

# Track which tenant+credential each system's Connect block is CURRENTLY connected with. The
# Coretelligent.* modules hold exactly one connection in module state (Connect-Ctg* overwrites it),
# so a per-(system|tenant) "already connected" set is wrong on a multi-client runner: an A->B->A
# job interleave would skip A's reconnect and silently run A's job against B's tenant. Keying
# system -> "tenant|credential-fingerprint" reconnects on every tenant switch AND on credential
# rotation (and keeps blank-domain clients with different secret TenantIds apart).
$script:ConnectedTenant = @{}

# ...but the cache is keyed per systemKey, and several systemKeys drive the SAME ambient connection:
#   graph  — m365, its 'entra' alias, m365-password-reset, tap and notify all Connect-CtgM365 with
#            the m365-admin credential (Connect-MgGraph holds ONE process-wide context).
#   google — google-workspace + google-password-reset share one Google session.
# 'exchange' is deliberately NOT a member, even though it now binds Graph too (to read its tenant's
# authoritative verified domain — see Get-CtgExoOrganization). Membership is SYMMETRIC, and only one
# direction is true here: exchange rebinding Graph must invalidate the riders (Connect-CtgGraphForJob
# does that itself, at the point it rebinds), but the reverse does NOT hold — exchange's cache key
# already encodes its client, so a hit means its EXO session is that client's and is still valid, and
# it re-binds Graph on any miss anyway. Making it a member would let every m365/entra job on this
# fleet-wide runner evict exchange's key, forcing a Connect-ExchangeOnline that isn't needed.
# So the A->B->A interleave above reappears ACROSS keys: an m365 job for client A connects Graph to A;
# an entra job for client B rebinds that same Graph session to B; a second m365 job for A then finds
# ConnectedTenant['m365'] still == A's key, SKIPS Connect, and provisions/offboards A's user inside
# B's tenant. Whenever a shared session is (re)bound, forget the SIBLING keys so they reconnect.
$script:ConnectionGroups = @{
    graph  = @('m365', 'entra', 'm365-password-reset', 'tap', 'notify')
    google = @('google-workspace', 'google-password-reset')
}

# The other systemKeys that share an ambient connection with this one ('' when it owns its session).
function Get-CtgConnectionSiblings {
    param([string]$SystemKey)
    foreach ($group in $script:ConnectionGroups.Values) {
        if ($group -contains $SystemKey) { return @($group | Where-Object { $_ -ne $SystemKey }) }
    }
    return @()
}

# Drop the connect-cache entries that no longer describe the ambient connection. Call AFTER any
# Connect that (re)binds a shared session. -IncludeSelf when the connection was established outside
# the cached path (a conn-test, cloud-group discovery) so no real job may reuse it.
function Clear-CtgConnectionSiblings {
    param([string]$SystemKey, [switch]$IncludeSelf)
    if (-not $script:ConnectedTenant) { return }
    foreach ($sibling in (Get-CtgConnectionSiblings $SystemKey)) { [void]$script:ConnectedTenant.Remove($sibling) }
    if ($IncludeSelf) { [void]$script:ConnectedTenant.Remove($SystemKey) }
}

# Every cloud session this runner holds is PROCESS-WIDE (Connect-MgGraph keeps exactly one context;
# Exchange Online stacks sessions), and this one process serves the whole fleet. Tear them all down.
function Disconnect-CtgAllCloud {
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
    # The Exchange module only loads on hosts that have ExchangeOnlineManagement — absent on an
    # AD-only client agent, where there is no EXO session to close anyway.
    if (Get-Command Disconnect-CtgExchange -ErrorAction SilentlyContinue) { Disconnect-CtgExchange }
    # The cache describes sessions that no longer exist. Leaving a key behind would make the next job
    # skip Connect and run unconnected — worse than the leak we just closed.
    if ($script:ConnectedTenant) { $script:ConnectedTenant.Clear() }
}

$script:CurrentClientKey = $null

# A HARD session boundary between clients: nothing bound for client A may still be live when client
# B's work starts. Called before every job and every connection test, across both loops, so the
# boundary holds no matter which kind of work crosses it.
#
# This is the primary defence for UM0029840, and it is deliberately dumber than the per-lane checks
# it backs up: those depend on a lane NOTICING it holds someone else's session, and the whole bug was
# a lane that didn't notice (the exchange lane read its tenant off Olympus Cosmetic's Graph session
# and never suspected a thing). Disconnecting unconditionally can't fail to notice. The identity
# guard (Test-CtgGraphBoundTo) stays as the second layer, for anything bound WITHIN a client's run.
#
# On CHANGE, not per job: within one client's own jobs there is nothing to leak FROM, and Exchange
# reconnects cost seconds each — so a per-job teardown would buy no safety and slow every case.
function Reset-CtgCloudSessionsOnClientChange {
    param($Job)
    $key = if ($Job.client -and $Job.client.slug) { [string]$Job.client.slug } else { '(no client)' }
    if ($script:CurrentClientKey -eq $key) { return $false }
    if ($script:CurrentClientKey) {  # not the first job of the process — someone else's sessions are live
        Write-CtgLog -Level INFO -Message "client boundary $($script:CurrentClientKey) -> ${key}: disconnecting all cloud sessions so nothing is inherited"
        Disconnect-CtgAllCloud
    }
    $script:CurrentClientKey = $key
    $true
}

# A short, non-reversible fingerprint of every brokered secret's fields for this job. Used ONLY as
# a connect-cache key component — never logged, never sent anywhere. SHA-256 over sorted
# name.field=value pairs, truncated.
function Get-CtgCredFingerprint {
    param($Creds)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($name in (@($Creds.Keys) | Sort-Object)) {
        $c = $Creds[$name]
        if (-not $c -or -not $c.Fields) { continue }
        foreach ($k in (@($c.Fields.Keys) | Sort-Object)) { [void]$sb.Append("$name.$k=$($c.Fields[$k]);") }
    }
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))
    ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 16)
}

# The on-prem AD module needs the client's primary domain to build the OU DN; fold it in from
# the job's client context if the intake payload didn't carry it.
function Add-ClientContext {
    param($Job)
    $u = $Job.payload
    if ($u -and -not $u.PSObject.Properties['PrimaryDomain']) {
        $u | Add-Member -NotePropertyName PrimaryDomain -NotePropertyValue $Job.client.primaryDomain -Force
    }
    $u
}

# ONE shared HttpClient for every app call — reuses TCP connections (keep-alive) instead of opening a
# new socket per request. PowerShell's Invoke-RestMethod creates + disposes a fresh HttpClient PER CALL,
# so a long-running poller churns a connection per heartbeat/claim/progress; the host's ephemeral ports
# fill with TIME_WAIT sockets and every outbound connect eventually fails ("Can't assign requested
# address" / "can't reach the database"). A pooled client keeps it to a handful of reused connections.
# GLOBAL so the module-scope Send-CtgProgress can reuse the same client.
$global:CtgHttp = $null
function global:Get-CtgHttpClient {
    if ($null -eq $global:CtgHttp) {
        $h = [System.Net.Http.SocketsHttpHandler]::new()
        $h.PooledConnectionLifetime    = [TimeSpan]::FromMinutes(5)
        $h.PooledConnectionIdleTimeout = [TimeSpan]::FromMinutes(2)
        $h.MaxConnectionsPerServer     = 8
        $c = [System.Net.Http.HttpClient]::new($h)
        $c.Timeout = [TimeSpan]::FromSeconds(300)
        $global:CtgHttp = $c
    }
    $global:CtgHttp
}

function global:Invoke-CtgHttp {
    # Shared-client request → parsed JSON (or $null). Throws "HTTP <code> — <body>" on non-2xx, matching
    # the Invoke-RestMethod behaviour callers relied on. Disposes the request/response, NOT the client.
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [string]$Body)
    $msg = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
    try {
        if ($Headers) {
            foreach ($k in $Headers.Keys) {
                if ($k -ieq 'Authorization') { $msg.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::Parse([string]$Headers[$k]) }
                else { [void]$msg.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) }
            }
        }
        if ($Body) { $msg.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json') }
        # SendAsync throws on timeout/network failure — the finally still disposes $msg (it previously
        # leaked the request message, incl. its StringContent, on every failed heartbeat/poll ~17k/day).
        $resp = (Get-CtgHttpClient).SendAsync($msg).GetAwaiter().GetResult()
        try {
            $code = [int]$resp.StatusCode
            $ok   = $resp.IsSuccessStatusCode
            $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $ok) { throw "HTTP ${code}: $Method $Uri$(if ($text) { " — $text" })" }
            if ($text) { return ($text | ConvertFrom-Json) }
            return $null
        }
        finally { $resp.Dispose() }
    }
    finally { $msg.Dispose() }
}

function Invoke-AppApi {
    param([string]$Method, [string]$Path, $Body)
    # ngrok-skip-browser-warning bypasses ngrok-free's HTML interstitial (harmless on other hosts).
    $headers = @{ 'ngrok-skip-browser-warning' = 'true' }
    $bearer = Get-CtgBearer
    if ($bearer) { $headers['Authorization'] = "Bearer $bearer" }
    $json = if ($Body) { ($Body | ConvertTo-Json -Depth 12) } else { $null }
    Invoke-CtgHttp -Method $Method -Uri "$AppUrl$Path" -Headers $headers -Body $json  # mTLS replaces the bearer in production
}

function global:Send-CtgProgress {
    # Post one progress line for the current job. GLOBAL on purpose: the Coretelligent.* modules run in
    # their own scope and can't see the runner's script functions — only global ones — so a long module
    # operation (e.g. the Exchange mailbox sync-wait) can call this to emit a "still trying" heartbeat.
    # Reads per-job globals; best-effort (a failed post never breaks the job).
    param([string]$Message)
    # Touch the watchdog heartbeat first: a narration means the runner made progress just now, so the
    # stall watchdog must not restart it. mtime is the signal (body is human-readable). Inlined rather
    # than calling the module's Update-CtgHeartbeat so it's reachable from module scope with no
    # cross-scope lookup (same reason this function is global). Best-effort.
    if ($global:CtgHeartbeatFile) { try { [System.IO.File]::WriteAllText($global:CtgHeartbeatFile, "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())`n$Message") } catch { } }
    $jid = $global:CtgProgressJobId
    if (-not $jid) { return }
    $h = @{ 'ngrok-skip-browser-warning' = 'true' }
    if ($global:CtgProgressToken) { $h['Authorization'] = "Bearer $($global:CtgProgressToken)" }
    # Shared pooled client (Invoke-CtgHttp) — NOT Invoke-RestMethod. Progress is the highest-frequency
    # call (every narration line during a job), so a fresh socket each time was the worst port-churn.
    try { Invoke-CtgHttp -Method POST -Uri "$($global:CtgProgressUrl)/api/jobs/$jid/progress" -Headers $h -Body (@{ agentId = $global:CtgProgressAgent; phase = $Message } | ConvertTo-Json) | Out-Null } catch { }
}

function global:Send-CtgStage {
    # Post one coarse setup-stage marker (signin|create|harvest|vault) for the current browser-based
    # credential-setup job, so the guided-setup wizard's run checklist advances live. Same endpoint as
    # Send-CtgProgress but a distinct `stage` field the app stores on a SCALAR Job.stage column, kept
    # apart from the free-text narration trail. GLOBAL for the same reason as Send-CtgProgress (module
    # scope can't see script functions). Best-effort; a stage change is progress, so touch the watchdog.
    param([string]$Stage)
    if (-not $Stage) { return }
    if ($global:CtgHeartbeatFile) { try { [System.IO.File]::WriteAllText($global:CtgHeartbeatFile, "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())`nstage:$Stage") } catch { } }
    $jid = $global:CtgProgressJobId
    if (-not $jid) { return }
    $h = @{ 'ngrok-skip-browser-warning' = 'true' }
    if ($global:CtgProgressToken) { $h['Authorization'] = "Bearer $($global:CtgProgressToken)" }
    try { Invoke-CtgHttp -Method POST -Uri "$($global:CtgProgressUrl)/api/jobs/$jid/progress" -Headers $h -Body (@{ agentId = $global:CtgProgressAgent; stage = $Stage } | ConvertTo-Json) | Out-Null } catch { }
}

function Set-CtgPhase {
    # Record what we're doing right now: keep it in $script:Phase (so a thrown error can say WHICH
    # phase failed instead of a bare "Unauthorized"), and beacon it to the app so the run report can
    # show live progress. Routes through the global poster so module + runner share one path.
    param([string]$JobId, [string]$Phase)
    $script:Phase = $Phase
    if ($JobId) { $global:CtgProgressJobId = $JobId }
    Write-Host "  · $Phase" -ForegroundColor DarkGray
    Send-CtgProgress $Phase
}

# Self-heal: only auto-install modules that are part of our trusted IAM toolchain — never an arbitrary
# gallery module conjured from a typo'd cmdlet name.
$script:CtgAutoInstallModules = @('Microsoft.Graph.*', 'ExchangeOnlineManagement', 'MSOnline', 'AzureAD', 'AzureADPreview', 'Az.*', 'ADSync', 'ActiveDirectory')

# Set by the self-heal when it installs something that must not be imported into THIS process; the
# poll loop restarts once the current job is finished (never mid-job — that would strand it).
$script:CtgRestartReason = $null

# RESTART-LOOP GUARD.
#
# Invoke-CtgRelaunch on a SUPERVISED host just `exit 0`s and trusts the service manager to bring us
# back. If that relaunch does not happen — a supervisor set to restart only on FAILURE reads exit 0 as
# a clean shutdown — the runner stays down until a human starts it. So an automatic restart that keeps
# being requested does not loop: it takes the fleet offline, once, and quietly.
#
# That is what the self-heal restart introduced (2026-09-08/09): each poll cycle repaired the same
# missing module, asked for a restart, and exited. Recorded on disk rather than in memory precisely
# because the process does not survive to remember.
$script:CtgSelfHealRestartFile = Join-Path $PSScriptRoot 'selfheal-restart.json'
$script:CtgSelfHealRestartWindowMinutes = 60

function Test-CtgSelfHealRestartAllowed {
    # Have we ALREADY restarted for this module recently? If so the restart plainly did not fix it —
    # restarting again just takes us down again. Report and keep running instead: the step that needs
    # the module fails with an actionable message, and every other system keeps working.
    param([Parameter(Mandatory)][string]$Reason, [string]$Path = $script:CtgSelfHealRestartFile,
          [datetime]$Now = (Get-Date), [int]$WindowMinutes = $script:CtgSelfHealRestartWindowMinutes)
    if (-not (Test-Path $Path)) { return $true }
    $m = $null
    try { $m = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return $true }
    if (-not $m -or -not $m.reason -or -not $m.at) { return $true }
    if ([string]$m.reason -ne $Reason) { return $true }   # a DIFFERENT repair — worth one restart
    $age = ($Now - [datetime]$m.at).TotalMinutes
    return ($age -ge $WindowMinutes)
}

function Set-CtgSelfHealRestart {
    param([Parameter(Mandatory)][string]$Reason, [string]$Path = $script:CtgSelfHealRestartFile, [datetime]$Now = (Get-Date))
    try { @{ reason = $Reason; at = $Now.ToString('o') } | ConvertTo-Json -Compress | Set-Content -Path $Path -Encoding utf8 -ErrorAction Stop } catch { }
}

# IN-FLIGHT MARKER — what this process is running right now, on disk.
#
# The stall watchdog kills a wedged process, but the JOB it was running is left mid-air: the app only
# learns anything when the 10-minute claim lease expires, re-queues it once, and eventually fails it.
# From an operator's seat that is half an hour of a step sitting at "running" with no explanation —
# which is exactly how the 2026-09-03 EXO wedge presented.
#
# So: stamp the job on disk while it runs, clear it when it finishes, and on the next start report any
# marker still lying there as a failure with a real reason. A killed process therefore turns into an
# explained failure within one restart, not a silent 30-minute gap.
# Keyed by AGENT, and dot-prefixed, for three separate reasons — all of which bit core1748:
#   1. A runner POOL and any second runner share one folder. The lock (.runner.<agentId>.lock) and the
#      heartbeat (temp/iam-runner-<agentId>.heartbeat) are already per agent; this was not, so a second
#      runner read the first one's marker at startup and posted its LIVE job to the app as failed.
#   2. Get-CtgBuildId hashes every file in the folder except dot-segments, tests/dist/node_modules/
#      scripts and *.log. A bare 'inflight.json' is none of those, so a runner that died mid-job came
#      back hashing a build the app's bundle can never equal — and was told to self-update forever,
#      which EXITS the process each time. The dot prefix takes it out of the hash entirely.
#   3. The self-update prune skips dot-segments too, so the marker now survives a self-update instead
#      of being deleted with the abandoned job still unreported.
function Get-CtgInFlightPath {
    param([Parameter(Mandatory)][string]$RunnerDir, [Parameter(Mandatory)][string]$AgentId)
    return (Join-Path $RunnerDir ".inflight.$AgentId.json")
}

# Delete the pre-1.123 shared marker if this host still has one. It must go BEFORE Get-CtgBuildId runs
# or it keeps skewing the build id (defect 2) for the life of the install. It is deliberately NOT
# reported: the file carries no agent id, so on the very shared-folder host this fixes we cannot tell
# whether it is ours or belongs to a runner still executing that job — reporting it would BE the bug.
# Unreported, the job ages out of its claim lease, which is the pre-existing and safe behaviour.
function Remove-CtgLegacyInFlight {
    param([Parameter(Mandatory)][string]$RunnerDir)
    $legacy = Join-Path $RunnerDir 'inflight.json'
    try {
        if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Force -ErrorAction Stop; return $true }
    } catch { }
    return $false
}

$script:CtgInFlightFile = Get-CtgInFlightPath -RunnerDir $PSScriptRoot -AgentId $AgentId

# "Install browser automation" is a ONE-SHOT delivery: runner-service.ts clears browserInstallRequested
# in the same statement that stamps browserInstallDeliveredAt, and never re-emits it. Holding that in
# memory is not enough — the install is a Start-Job child that dies with its parent, and the poll loop
# sits downstream of update/restart, both of which end in Invoke-CtgRelaunch. So the request is written
# to DISK the moment it arrives and startup resumes it. Dot-prefixed + per agent for the same two
# reasons as the in-flight marker above: out of the build-id hash and the prune, and un-stealable by a
# second runner sharing the folder.
function Get-CtgBrowserRequestPath {
    param([Parameter(Mandatory)][string]$RunnerDir, [Parameter(Mandatory)][string]$AgentId)
    return (Join-Path $RunnerDir ".browser-install.$AgentId.request")
}

function Set-CtgBrowserInstallRequest {
    param([Parameter(Mandatory)][string]$RunnerDir, [Parameter(Mandatory)][string]$AgentId)
    try {
        [System.IO.File]::WriteAllText((Get-CtgBrowserRequestPath -RunnerDir $RunnerDir -AgentId $AgentId),
            [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
    } catch { }   # best-effort: bookkeeping must never fail a heartbeat
}

function Test-CtgBrowserInstallRequest {
    param([Parameter(Mandatory)][string]$RunnerDir, [Parameter(Mandatory)][string]$AgentId)
    return (Test-Path -LiteralPath (Get-CtgBrowserRequestPath -RunnerDir $RunnerDir -AgentId $AgentId))
}

function Clear-CtgBrowserInstallRequest {
    param([Parameter(Mandatory)][string]$RunnerDir, [Parameter(Mandatory)][string]$AgentId)
    $p = Get-CtgBrowserRequestPath -RunnerDir $RunnerDir -AgentId $AgentId
    try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction Stop } } catch { }
}

function Set-CtgInFlight {
    param([Parameter(Mandatory)]$Job)
    try {
        @{ jobId = [string]$Job.id; systemKey = [string]$Job.systemKey; action = [string]$Job.action
           caseNumber = [string]$Job.caseNumber; at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } |
            ConvertTo-Json -Compress | Set-Content -Path $script:CtgInFlightFile -Encoding utf8 -ErrorAction Stop
    } catch { }   # best-effort: never let bookkeeping fail a job
}

function Clear-CtgInFlight {
    try { if (Test-Path $script:CtgInFlightFile) { Remove-Item $script:CtgInFlightFile -Force -ErrorAction Stop } } catch { }
}

function Report-CtgAbandonedJob {
    # Called ONCE at startup. A marker here means the previous process died while running that job —
    # watchdog kill, host reboot, or an operator restart. Tell the app so the step fails with a reason
    # instead of ageing out of its lease.
    param([Parameter(Mandatory)][scriptblock]$Post)
    if (-not (Test-Path $script:CtgInFlightFile)) { return $null }
    $m = $null
    try { $m = Get-Content $script:CtgInFlightFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
    Clear-CtgInFlight   # clear FIRST: a marker we cannot parse must not be retried on every boot
    if (-not $m -or -not $m.jobId) { return $null }
    $ageS = if ($m.at) { [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$m.at) } else { 0 }
    $why = "the runner stopped while this step was running (it had been running for ${ageS}s) — most likely the stall watchdog restarted a wedged process. Nothing is known to have completed; re-run this step."
    Write-CtgLog -Level WARN -Message "abandoned job $($m.jobId) [$($m.systemKey)] from the previous process — reporting it failed"
    try { & $Post ([string]$m.jobId) $why } catch { }
    return [string]$m.jobId
}

# Modules that share .NET assemblies (Azure.Core, Microsoft.Identity.Client, System.IdentityModel) and
# therefore must never be imported into a process that has already loaded a sibling: the second import
# binds an incompatible copy and the first module's calls stop returning. Grouped rather than
# hardcoded as "EXO vs Graph" so the next auth-stack module added to the allowlist is covered too.
# Modules that share .NET assemblies (Azure.Core, Microsoft.Identity.Client) and therefore must never
# be imported into a process that has already loaded a sibling: the second import binds an
# incompatible copy and the FIRST module's calls stop returning. A flat pattern -> group map, not a
# nested array: @( @(...) ) flattens in PowerShell, which silently turned the membership test into a
# scan of single characters' worth of pattern and never matched anything.
$script:CtgAssemblySharingGroups = @{
    'Microsoft.Graph.*'        = 'entra-auth-stack'
    'ExchangeOnlineManagement' = 'entra-auth-stack'
    'MSOnline'                 = 'entra-auth-stack'
    'AzureAD'                  = 'entra-auth-stack'
    'AzureADPreview'           = 'entra-auth-stack'
    'Az.*'                     = 'entra-auth-stack'
    # PnP.PowerShell ships Microsoft.Identity.Client, Microsoft.IdentityModel.* and
    # System.IdentityModel.Tokens.Jwt — it belongs here and was missing, which is how it came to be
    # loaded alongside Graph and wedge it (2026-09-23..25). The SharePoint hand-off now runs in a child
    # process (Invoke-CtgPnPGrantOutOfProcess) so nothing loads it here at all; this entry is the
    # backstop for any OTHER path — a self-heal install, a future caller — that tries to.
    'PnP.PowerShell'           = 'entra-auth-stack'
    # MicrosoftTeams bundles Microsoft.Identity.Client too. Teams Phone runs it in a child process
    # (Invoke-CtgTeamsOutOfProcess); this is the backstop for anything else that tries to load it here.
    'MicrosoftTeams'           = 'entra-auth-stack'
}

function Test-CtgModuleConflictsWithLoaded {
    # Would importing $Name into THIS process collide with a module already loaded in it?
    # True only when a module matching a DIFFERENT pattern in the same group is loaded — a
    # Microsoft.Graph submodule joining its own siblings shares one version line (the skew guard keeps
    # them aligned) and stays allowed, which is the case the self-heal was built for.
    #
    # Loaded/Groups are parameters with live defaults so the decision is unit-testable without mocking
    # the host's module list: tests pass both explicitly, production passes neither.
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Loaded = @(Get-Module | ForEach-Object { $_.Name }),
        [hashtable]$Groups = $script:CtgAssemblySharingGroups
    )
    if (-not $Groups) { return $false }
    $myPattern = $null
    $myGroup = $null
    foreach ($p in $Groups.Keys) { if ($Name -like $p) { $myPattern = $p; $myGroup = $Groups[$p]; break } }
    if (-not $myGroup) { return $false }   # not part of any shared-assembly stack
    foreach ($p in $Groups.Keys) {
        if ($p -eq $myPattern) { continue }          # same pattern = siblings, safe together
        if ($Groups[$p] -ne $myGroup) { continue }   # a different stack entirely
        foreach ($l in $Loaded) { if ($l -like $p) { return $true } }
    }
    return $false
}

function Get-CtgMissingCommandName {
    # Pull the unresolved command name out of a CommandNotFoundException (or its "The term 'X' is not
    # recognized" message). Returns $null when the error isn't a missing-command.
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex -is [System.Management.Automation.CommandNotFoundException]) { return $ex.CommandName }
        $ex = $ex.InnerException
    }
    $m = "$($ErrorRecord.Exception.Message)"
    if ($m -match "[Tt]he term '([^']+)' is not recognized") { return $matches[1] }
    return $null
}

function Repair-CtgMissingModule {
    # Given a missing cmdlet, find the gallery module that provides it and install+import it — but only
    # if that module is in our trusted allowlist. Returns the module name on success, else $null.
    param([string]$CommandName)
    if (-not $CommandName) { return $null }
    if (-not (Get-Command Find-Command -ErrorAction SilentlyContinue)) { return $null }  # needs PowerShellGet
    $mod = $null
    try { $mod = (Find-Command -Name $CommandName -ErrorAction Stop | Select-Object -First 1).ModuleName } catch { return $null }
    if (-not $mod) { return $null }
    $trusted = $false
    foreach ($p in $script:CtgAutoInstallModules) { if ($mod -like $p) { $trusted = $true; break } }
    if (-not $trusted) { Write-Warning "self-heal: '$CommandName' is in module '$mod', not on the auto-install allowlist — skipping"; return $null }
    try {
        # The runner is detached (no stdin), so Install-Module must NEVER prompt or it hangs forever.
        Initialize-CtgGallery
        # Microsoft.Graph submodules must all carry the SAME version or the next import dies with
        # "Assembly with same name is already loaded" (see Repair-CtgGraphVersionSkew). Pin a new
        # Graph submodule to the version already on the host instead of grabbing the gallery latest.
        $reqVer = $null
        # ExchangeOnlineManagement is PINNED for a reason: 3.10.0's REST cmdlets call the removed
        # HttpResponseMessage.GetResponseHeader() and every Exchange job then dies with "does not
        # contain a method named 'GetResponseHeader'" on PS7.6 (core2104 2026-07-15; core1748 again on
        # 2026-09-08 — FR #0000129/#0000130). Startup installs and imports the pin, but THIS function
        # used to install the gallery LATEST, which put the broken build on the host permanently — so
        # the moment the pin was missing, the startup fallback picked 3.10.0 and Exchange broke fleet-
        # wide for that agent. Install the pin here too.
        if ($mod -eq 'ExchangeOnlineManagement') { $reqVer = $ExoModuleVersion }
        if ($mod -like 'Microsoft.Graph*') {
            $auth = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' -ErrorAction SilentlyContinue |
                Sort-Object Version -Descending | Select-Object -First 1
            if ($auth) { $reqVer = $auth.Version }
        }
        if ($reqVer) {
            # The pinned version may not exist for this submodule (older set; unlisted release) —
            # fall back to the gallery latest rather than failing the self-heal permanently. The
            # startup skew guard then aligns the rest of the set upward on the next boot.
            try { Install-Module $mod -RequiredVersion $reqVer -Scope CurrentUser -Force -AllowClobber -Confirm:$false -AcceptLicense -ErrorAction Stop }
            catch {
                Write-Warning "self-heal: $mod has no version $reqVer — installing latest instead (the skew guard re-aligns at next start)"
                Install-Module $mod -Scope CurrentUser -Force -AllowClobber -Confirm:$false -AcceptLicense -ErrorAction Stop
            }
        }
        else { Install-Module $mod -Scope CurrentUser -Force -AllowClobber -Confirm:$false -AcceptLicense -ErrorAction Stop }

        # DO NOT Import-Module here when the new module shares .NET assemblies with one already loaded.
        # ExchangeOnlineManagement and Microsoft.Graph both carry Azure.Core and Microsoft.Identity.Client;
        # importing the second into a process that already bound the first loads a SECOND, incompatible
        # copy, and from then on Graph calls never return — no error, no timeout, just a dead process
        # holding a job.
        #
        # That is what wedged the central runner on 2026-09-02/03. ExchangeOnlineManagement went missing
        # on CORE-CCE-DC01, this self-heal installed AND imported it mid-run, and the next Get-MgUser on
        # the following job hung forever. The 600s stall watchdog then respawned the process, the app
        # re-dispatched the job, and it wedged again — a loop that reads as "the runner keeps crashing".
        #
        # Installing is still right: the module IS missing and the next start needs it. Loading it is
        # what we must not do here. Ask for a restart instead — a fresh process imports the full set
        # cleanly at boot, which is the only safe order.
        if (Test-CtgModuleConflictsWithLoaded $mod) {
            $script:CtgRestartReason = "self-heal installed '$mod' (for '$CommandName'), which shares .NET assemblies with an already-loaded module — restarting so it loads cleanly"
            Write-CtgLog -Level WARN -Message "self-heal: $script:CtgRestartReason"
            return $null
        }
        Import-Module $mod -Force -ErrorAction Stop
        return $mod
    } catch { Write-Warning "self-heal: failed to install '$mod' for '$CommandName': $($_.Exception.Message)"; return $null }
}

function Update-CtgRunner {
    # Operator clicked "Update" (or auto-update): re-pull every runner file from the app's manifest
    # into our own folder, then relaunch this script (new pwsh process = new code) and exit. The pull
    # itself lives in Invoke-CtgManifestPull (lib/CtgUpdate.ps1) so the pool supervisor can reuse it
    # once for the whole pool; here we pull then relaunch, exactly as before.
    # INTEGRATION (#226 ⇄ #229): authenticate the pull with Get-CtgBearer, NOT the raw $ApiToken —
    # after a per-agent-token adoption $ApiToken is nulled, so passing it would 401 a migrated runner.
    $m = Invoke-CtgManifestPull -AppUrl $AppUrl -ApiToken (Get-CtgBearer) -RunnerDir $PSScriptRoot
    Write-Host "self-update: pulled $($m.count) files (build $($m.buildId)) — restarting" -ForegroundColor Green
    Invoke-CtgRelaunch -Reason 'self-update'
}

# Re-exec the runner: under a supervisor (RUNNER_SUPERVISED — launchd/systemd/Scheduled Task) just EXIT
# and let it relaunch us (the robust path, no self-spawn double-runner); UNSUPERVISED, spawn our own
# replacement first, then exit. Shared by self-update (after pulling files) and an operator restart
# (heartbeat restart:true — no file pull). Never returns.
function Invoke-CtgRelaunch {
    param([string]$Reason = 'restart')
    if ($env:RUNNER_SUPERVISED) {
        Write-Host "${Reason}: supervised — exiting so the service manager relaunches" -ForegroundColor Green
        exit 0
    }
    # UNSUPERVISED (a hand-started launch): spawn a fresh process on this same script, then exit. On
    # Windows use WMI (Win32_Process.Create) so the child BREAKS AWAY from a SYSTEM Scheduled Task's job
    # object (a Start-Process child would be killed when we exit — the runner would never come back).
    $pwshPath = (Get-Process -Id $PID).Path
    if (-not $pwshPath) { $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
    $self = Join-Path $PSScriptRoot 'Start-IamRunner.ps1'
    $qq = { param([string]$s) '"' + ($s -replace '"', '\"') + '"' }  # quote args (paths may have spaces)
    $cmd = (& $qq $pwshPath) + ' -NoProfile -ExecutionPolicy Bypass -File ' + (& $qq $self) +
           ' -AppUrl ' + (& $qq $AppUrl) + ' -AgentId ' + (& $qq $AgentId) +
           ' -PollSeconds ' + $PollSeconds + ' -BatchSize ' + $BatchSize +
           ' -ExoModuleVersion ' + (& $qq $ExoModuleVersion)
    # Once a per-agent token is adopted, the shared token is dropped — never re-embed it in the
    # rewritten launcher, or a migrated agent could fall back to a token it no longer holds.
    if ($script:AgentToken) { $cmd += ' -AgentToken ' + (& $qq $script:AgentToken) }
    elseif ($ApiToken) { $cmd += ' -ApiToken ' + (& $qq $ApiToken) }
    if ($IsWindows) {
        try {
            $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd } -ErrorAction Stop
            if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($r.ReturnValue)" }
            Write-Host "${Reason}: relaunched (pid $($r.ProcessId))" -ForegroundColor Green
        }
        catch {
            Write-Warning "${Reason} relaunch via WMI failed ($($_.Exception.Message)); using Start-Process"
            $fbArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$self,'-AppUrl',$AppUrl,'-AgentId',$AgentId,'-PollSeconds',$PollSeconds,'-BatchSize',$BatchSize,'-ExoModuleVersion',$ExoModuleVersion)
            if ($script:AgentToken) { $fbArgs += @('-AgentToken', $script:AgentToken) }
            elseif ($ApiToken) { $fbArgs += @('-ApiToken', $ApiToken) }
            Start-Process -FilePath $pwshPath -ArgumentList $fbArgs | Out-Null
        }
    }
    else {
        # macOS/Linux: relaunch DETACHED via a tiny launcher script (`exec … >> log 2>&1` takes pwsh off
        # the dead tty; the Start-Process child survives our exit on Unix).
        $log = if ($env:RUNNER_LOG) { $env:RUNNER_LOG } else { Join-Path $HOME 'iam-runner.log' }
        $a = @($pwshPath, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self, '-AppUrl', $AppUrl, '-AgentId', $AgentId, '-PollSeconds', "$PollSeconds", '-BatchSize', "$BatchSize", '-ExoModuleVersion', $ExoModuleVersion)
        if ($script:AgentToken) { $a += @('-AgentToken', $script:AgentToken) }
        elseif ($ApiToken) { $a += @('-ApiToken', $ApiToken) }
        $q = { param($s) "'" + ([string]$s -replace "'", "'\''") + "'" }
        $line = (($a | ForEach-Object { & $q $_ }) -join ' ') + " >> $(& $q $log) 2>&1"
        # The launcher embeds -AgentToken/-ApiToken, so it must NOT be world-readable. Put it in a private per-launch
        # dir (0700) so it's unreadable even during the brief window before the file's own 0600 lands,
        # and have the launcher delete itself before exec so the token doesn't linger on disk.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("iam-runner-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        & chmod 700 $dir 2>$null
        $launcher = Join-Path $dir 'relaunch.sh'
        [System.IO.File]::WriteAllText($launcher, "#!/bin/sh`nrm -f `"`$0`" 2>/dev/null; rmdir -- `"$dir`" 2>/dev/null`nexec $line`n")
        & chmod 600 $launcher 2>$null
        Start-Process -FilePath '/bin/sh' -ArgumentList $launcher | Out-Null
        Write-Host "${Reason}: relaunched detached (log: $log)" -ForegroundColor Green
    }
    exit 0
}

# Operator-requested restart (heartbeat restart:true): re-exec WITHOUT pulling new files. Clears a
# wedged claim/work loop while the heartbeat thread stayed alive — the exact "heartbeats but won't
# claim" case. Needs a supervisor to come back cleanly (or the unsupervised self-spawn above).
function Restart-CtgRunner {
    Write-Host "restart: operator requested a restart" -ForegroundColor Yellow
    if (-not $env:RUNNER_SUPERVISED) { Write-Warning "restart requested but RUNNER_SUPERVISED is not set — attempting a self-spawn relaunch; install the supervisor (install-launchd.sh / install-systemd.sh / install-task.ps1) for reliable remote restarts." }
    Invoke-CtgRelaunch -Reason 'restart'
}

function Invoke-CtgMigrate {
    # Operator moved the app to a new hostname (heartbeat migrate:{appUrl}). VERIFY we can reach the new
    # URL, REWRITE our own supervisor entry (Scheduled Task / launchd plist / systemd unit) replacing
    # -AppUrl (old URL removed, not appended), then relaunch on the new URL. On ANY failure: record it
    # (reported on the next heartbeat) and DO NOT relaunch — a half-migrated agent must never loop. The
    # verify de-risks removing the old URL up front: we only switch once the new host actually answers.
    param([Parameter(Mandatory)][string]$NewAppUrl)
    if ($NewAppUrl.TrimEnd('/') -ieq ([string]$AppUrl).TrimEnd('/')) { $script:LastMigrateError = $null; return }  # already there
    Write-Host "migrate: requested move to $NewAppUrl — verifying reachability" -ForegroundColor Yellow

    # 1) VERIFY: an authenticated GET of the manifest on the NEW host must succeed (same backend, our
    #    existing token validates). Anything else → stay put and report.
    try {
        $H = @{ 'ngrok-skip-browser-warning' = 'true' }
        $bearer = Get-CtgBearer
        if ($bearer) { $H['Authorization'] = "Bearer $bearer" }
        $null = Invoke-RestMethod -Uri "$NewAppUrl/api/runner/manifest" -Headers $H -TimeoutSec 30 -ErrorAction Stop
    } catch {
        $script:LastMigrateError = "unreachable: $($_.Exception.Message)"
        Write-Warning "migrate: new URL not reachable — staying on $AppUrl ($script:LastMigrateError)"
        return
    }

    # 2) REWRITE the supervisor entry (old URL removed).
    try {
        if ($IsWindows) {
            $task = Get-ScheduledTask -TaskName 'iam-runner' -ErrorAction Stop
            $act = $task.Actions[0]
            $newArgs = Set-CtgAppUrlInArgString -ArgString $act.Arguments -NewUrl $NewAppUrl
            # New-ScheduledTaskAction's -WorkingDirectory is [ValidateNotNullOrEmpty]: a task whose
            # action has no WorkingDirectory (older install-task.ps1 builds, or a hand-made task) would
            # throw "argument is null or empty" and abort the whole migrate. Only pass it when we have a
            # value, falling back to the install dir ($PSScriptRoot, = install-task.ps1's $InstallDir).
            $actionParams = @{ Execute = $act.Execute; Argument = $newArgs }
            $wd = if ($act.WorkingDirectory) { $act.WorkingDirectory } else { $PSScriptRoot }
            if ($wd) { $actionParams['WorkingDirectory'] = $wd }
            $newAction = New-ScheduledTaskAction @actionParams
            Set-ScheduledTask -TaskName 'iam-runner' -Action $newAction -ErrorAction Stop | Out-Null
        }
        elseif ($IsMacOS) {
            $plist = Join-Path $HOME 'Library/LaunchAgents/com.coretelligent.iam-runner.plist'
            if (-not (Test-Path $plist)) { throw "launchd plist not found at $plist" }
            $xml = [System.IO.File]::ReadAllText($plist)
            [System.IO.File]::WriteAllText($plist, (Set-CtgAppUrlInPlist -PlistXml $xml -NewUrl $NewAppUrl))
            & launchctl unload $plist 2>$null; & launchctl load $plist 2>$null
        }
        else {
            $unit = '/etc/systemd/system/iam-runner.service'
            if (-not (Test-Path $unit)) { throw "systemd unit not found at $unit" }
            $lines = [System.IO.File]::ReadAllLines($unit)
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*ExecStart=') { $lines[$i] = Set-CtgAppUrlInArgString -ArgString $lines[$i] -NewUrl $NewAppUrl } }
            [System.IO.File]::WriteAllLines($unit, $lines)
            & systemctl daemon-reload 2>$null
        }
    } catch {
        $script:LastMigrateError = "rewrite failed: $($_.Exception.Message)"
        Write-Warning "migrate: could not rewrite the supervisor entry — staying on $AppUrl ($script:LastMigrateError)"
        return
    }

    # 3) SWITCH: point this process (and every relaunch surface built from $AppUrl) at the new URL, then
    #    relaunch. Supervised → exit (the rewritten entry brings us back on the new URL); unsupervised →
    #    the self-spawn in Invoke-CtgRelaunch reads $script:AppUrl, now updated.
    $script:LastMigrateError = $null
    $script:AppUrl = $NewAppUrl
    $global:CtgProgressUrl = $NewAppUrl
    Write-Host "migrate: verified + supervisor rewritten — switching to $NewAppUrl" -ForegroundColor Green
    Invoke-CtgRelaunch -Reason 'migrate'
}

function Protect-CtgSecretsInText {
    # Redact brokered secret VALUES out of free text (a failure message) before it's posted to the
    # app — Job.error is persisted and shown in the run report + ServiceNow work note + audit, and a
    # failing API call can echo a key/token/password in its exception. Only values of secret-named
    # fields are scrubbed, so usernames/servers stay visible for diagnosis.
    # -ExtraValues: additional plaintexts to scrub that aren't brokered fields — e.g. the app-injected
    # config.newPassword/initialPassword of a password-reset/onboard job echoed by a provider error.
    param([string]$Text, [hashtable]$Creds, [string[]]$ExtraValues = @())
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    foreach ($v in $ExtraValues) {
        if ($v -and $v.Length -ge 4 -and $Text.Contains($v)) { $Text = $Text.Replace($v, '***') }
    }
    if ($Creds) {
        foreach ($c in $Creds.Values) {
            if (-not $c -or -not $c.Fields) { continue }
            foreach ($k in @($c.Fields.Keys)) {
                $v = [string]$c.Fields[$k]
                if ($v.Length -lt 4) { continue }
                # (1) name-matched secret fields — widened to catch cert/PEM/JSON/private-key fields
                # (e.g. ServiceAccountJson, CertificateBase64) that the old pass|secret|key|token set missed.
                $named = $k -match '(?i)pass|secret|key|token|credential|json|cert|pem|private|account'
                # (2) any value carrying structural chars (/, +, =, {, ", whitespace) is a base64/JSON/PEM
                # BLOB, never a hostname/username/email — scrub it whatever the field is named, so a secret
                # in an unrecognized field can't ride along. Plain identifiers stay visible for diagnosis.
                $blob = $v.Length -ge 8 -and ($v -match '[^A-Za-z0-9._@\-]')
                if (($named -or $blob) -and $Text.Contains($v)) { $Text = $Text.Replace($v, '***') }
            }
        }
    }
    # Never leak the runner's OWN bearer / per-job progress token into a persisted error.
    $prog = if (Get-Variable -Name CtgProgressToken -Scope Global -ErrorAction SilentlyContinue) { $global:CtgProgressToken } else { $null }
    foreach ($t in @($ApiToken, $AgentToken, $prog)) {
        $ts = [string]$t
        if ($ts.Length -ge 4 -and $Text.Contains($ts)) { $Text = $Text.Replace($ts, '***') }
    }
    return $Text
}

function Get-CtgBuildId {
    # This runner's build id = SHA-256 over its own files (raw bytes, ordinal-sorted POSIX relpaths),
    # truncated to 12 hex. EXACTLY the hash the app computes over the bundle it serves (lib/runner/
    # bundle.ts runnerBuildId), so the app can show "up to date" vs "update available" with no version
    # string to bump and no marker file to keep in sync. 'unknown' if anything goes wrong.
    $root = $PSScriptRoot
    # Keep in lockstep with SKIP_DIRS in web/lib/runner/bundle.ts. 'scripts' holds operator/diagnostic
    # helpers that never ship to a deployed runner (and so must not move the build hash).
    $skip = 'tests', 'dist', 'node_modules', 'scripts'
    try {
        # -Force so dot-entries are enumerated on EVERY platform (PowerShell hides them on Unix but not
        # Windows — that divergence is exactly what made a stray .claude/.remember in the bundle loop the
        # Mac agent forever). Then skip any dot-segment + build/test dirs + logs/test files, matching
        # bundle.ts so the runner's self-computed hash equals the app's bundle hash on all platforms.
        $rels = foreach ($f in Get-ChildItem -Force -LiteralPath $root -Recurse -File) {
            $rel = ([System.IO.Path]::GetRelativePath($root, $f.FullName)) -replace '\\', '/'
            if ($rel.Split('/') | Where-Object { $skip -contains $_ -or $_.StartsWith('.') }) { continue }
            if ($f.Name -like '*.Tests.ps1' -or $f.Name -like '*.log') { continue }
            $rel
        }
        $arr = @($rels); [Array]::Sort($arr, [System.StringComparer]::Ordinal)
        $ms = New-Object System.IO.MemoryStream
        foreach ($rel in $arr) {
            $rb = [System.Text.Encoding]::UTF8.GetBytes($rel)
            $cb = [System.IO.File]::ReadAllBytes((Join-Path $root $rel))
            $ms.Write($rb, 0, $rb.Length); $ms.WriteByte(0); $ms.Write($cb, 0, $cb.Length); $ms.WriteByte(0)
        }
        $ms.Position = 0
        $h = [System.Security.Cryptography.SHA256]::HashData($ms)   # static — no disposable instance to leak
        $ms.Dispose()
        return (-join ($h | ForEach-Object { $_.ToString('x2') })).Substring(0, 12)
    }
    catch { return 'unknown' }
}

function Invoke-CtgAdDiscovery {
    # Operator clicked "Refresh AD objects": read the DC's folders + groups (read-only; the agent's own
    # domain context can read the directory — no brokered credential needed) and report them back so
    # the editors can offer real folder/group pickers instead of hand-typed DNs.
    #
    # "Folders" = every node a user can be created under: organizationalUnit (OU=…), container
    # (CN=Users, CN=Computers, CN=Managed Service Accounts, …), builtinDomain (CN=Builtin) and the
    # domainDNS root itself — so the picker shows the WHOLE tree, not just OUs. Get-ADOrganizationalUnit
    # returns ONLY OUs, so a client whose users live in the default CN=Users container (no user OU) had
    # nothing to pick; Get-ADObject over those classes fixes that. Reported in the `ous` field for
    # backward compatibility (the app treats it as an arbitrary folder-DN list; the tree nests by DN).
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { Write-Warning "AD discovery skipped — no ActiveDirectory module on this host"; return }
    try {
        $folderFilter = '(|(objectClass=organizationalUnit)(objectClass=container)(objectClass=builtinDomain)(objectClass=domainDNS))'
        $ous = @(Get-ADObject -LDAPFilter $folderFilter -ErrorAction Stop | Select-Object -ExpandProperty DistinguishedName)
        $groups = @(Get-ADGroup -Filter * -ErrorAction Stop | Select-Object -ExpandProperty Name)
        Invoke-AppApi POST '/api/agents/ad-objects' @{ agentId = $AgentId; ous = $ous; groups = $groups } | Out-Null
        Write-Host "AD discovery: reported $($ous.Count) folders, $($groups.Count) groups" -ForegroundColor Green
    }
    catch {
        Write-Warning "AD discovery failed: $($_.Exception.Message)"
    }
}

# Ask the app for a CURRENT one-time password for this job's secret. Delinea holds the authenticator
# seed (one-time-password enabled on the secret) and mints the code; the SEED is never sent to us.
# NOTE: this is the PRE-MINT variant — anything fetched here still has to survive until the consumer
# uses it. Browser flows must NOT use this (browser launch + SSO outlive a 30s code): they get an
# -OtpRequest spec and mint at the MFA prompt instead. Kept for non-browser MFA needs and tests.
function Get-JobOtp {
    param($JobId, $SecretName)
    try {
        $ref = Invoke-AppApi POST "/api/jobs/$JobId/credential" @{ agentId = $AgentId; secretName = $SecretName; otp = $true }
    } catch {
        Write-CtgLog "could not fetch a one-time password from the app: $($_.Exception.Message)" 'WARN'
        return $null
    }
    $code = [string](Get-CtgProp $ref 'otpCode')
    if (-not $code) {
        $why = [string](Get-CtgProp $ref 'otpError')
        if ($why) { Write-CtgLog "no one-time password available: $why" 'WARN' }
        return $null
    }
    [pscustomobject]@{ Code = $code; RemainingSeconds = (Get-CtgProp $ref 'otpRemainingSeconds') }
}

# Field-name SYNONYMS for the two values every brokered credential reduces to.
#
# Delinea templates disagree on what they call the SAME app-registration credential: the "Entra Azure
# AD Account" template stores it as Username/Password, while "Automation - Azure App" stores it as
# appID/Secret (+ tenantID). Both are the client-credentials pair Connect-CtgM365 needs — it connects
# with -ClientSecretCredential, where UserName IS the app id and Password IS the client secret. Reading
# only 'Username'/'Password' handed those clients a $null credential and failed at connect time with an
# opaque bind error, so the broker accepts either spelling.
#
# $fields is a case-INSENSITIVE PowerShell hashtable, so only the SPELLING matters here, not the case
# (that's also why 'tenantID' already satisfies Get-CtgTenantDomain's $s.Fields['TenantId'] lookup).
$script:CRED_USERNAME_FIELDS = @('Username', 'appID', 'AppId', 'ApplicationId', 'ClientId')
$script:CRED_PASSWORD_FIELDS = @('Password', 'Secret', 'ClientSecret', 'AppSecret')

function Select-CtgCredField {
    # First NON-EMPTY value among $Names, or $null. A field that exists but is blank must not win over
    # a later synonym that actually carries the value.
    param([hashtable]$Fields, [string[]]$Names)
    foreach ($n in $Names) {
        if ($Fields.ContainsKey($n)) {
            $v = [string]$Fields[$n]
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
        }
    }
    return $null
}

function Get-JobCredential {
    # Push-down model: ask the app to broker secret $SecretName for this job. The app resolves the
    # VALUE from Delinea and returns the fields (Username/Password/Server/...), so the runner needs
    # no Delinea creds of its own. We rebuild the same shape the executors expect
    # (.Username/.Password/.Credential/.Fields) from those fields.
    param($JobId, $SecretName)
    $ref = Invoke-AppApi POST "/api/jobs/$JobId/credential" @{ agentId = $AgentId; secretName = $SecretName }
    # $ref.fields is a JSON object -> PSCustomObject; flatten to a hashtable.
    $fields = @{}
    if ($ref.fields) { foreach ($p in $ref.fields.PSObject.Properties) { $fields[$p.Name] = $p.Value } }
    # Treat an absent OR empty field set as unresolved — an empty {} is truthy in PS and would
    # otherwise slip through and surface much later as an opaque null-credential bind error.
    if ($fields.Count -eq 0) {
        $why = if ($ref.note) { $ref.note } else { "the app returned no secret fields" }
        throw "secret '$SecretName' was not resolved by the app — $why"
    }
    $username = Select-CtgCredField $fields $script:CRED_USERNAME_FIELDS
    $pw = Select-CtgCredField $fields $script:CRED_PASSWORD_FIELDS
    $password = if ($pw) { ConvertTo-SecureString $pw -AsPlainText -Force } else { $null }
    $cred = if ($username -and $password) { [pscredential]::new([string]$username, $password) } else { $null }
    [pscustomobject]@{ Username = $username; Password = $password; Credential = $cred; Fields = $fields }
}

function Get-ConnTestCredential {
    # Same push-down broker as Get-JobCredential, but for a connection test (no job). Rebuilds the
    # .Username/.Password/.Credential/.Fields shape the $DISPATCH Connect blocks expect.
    param($TestId, $SecretName)
    $ref = Invoke-AppApi POST "/api/runner/conn-tests/$TestId/credential" @{ agentId = $AgentId; secretName = $SecretName }
    $fields = @{}
    if ($ref.fields) { foreach ($p in $ref.fields.PSObject.Properties) { $fields[$p.Name] = $p.Value } }
    if ($fields.Count -eq 0) {
        $why = if ($ref.note) { $ref.note } else { "the app returned no secret fields" }
        throw "secret '$SecretName' was not resolved by the app — $why"
    }
    $username = Select-CtgCredField $fields $script:CRED_USERNAME_FIELDS
    $pw = Select-CtgCredField $fields $script:CRED_PASSWORD_FIELDS
    $password = if ($pw) { ConvertTo-SecureString $pw -AsPlainText -Force } else { $null }
    $cred = if ($username -and $password) { [pscredential]::new([string]$username, $password) } else { $null }
    [pscustomobject]@{ Username = $username; Password = $password; Credential = $cred; Fields = $fields }
}

# Which Graph permissions the M365 onboarder actually exercises, each satisfied by ANY of the listed
# scopes. Compared against the connection's GRANTED scopes (Get-MgContext) so the test can name the
# exact permission someone forgot to grant + admin-consent, instead of a bare "Insufficient privileges".
# One declaration, two consumers: the human gap strings AND the structured rights rows the probe posts.
$script:GRAPH_REQUIRED_CAPS = @(
    @{ need = 'create / update users + assign licenses'; anyOf = @('User.ReadWrite.All', 'Directory.ReadWrite.All') }
    @{ need = 'add users to groups';                      anyOf = @('Group.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Directory.ReadWrite.All') }
    @{ need = 'read licenses / groups (SKUs)';            anyOf = @('Organization.Read.All', 'Directory.Read.All', 'Directory.ReadWrite.All', 'User.Read.All', 'Group.Read.All') }
)
# OPTIONAL Graph permissions: reported alongside the required ones so a gap is VISIBLE, but a miss
# NEVER fails the test (they're not in Get-CtgGraphScopeGaps, which drives the throw). Each degrades
# gracefully — the feature that needs it warns and carries on. Matches the client-facing consent list
# in web/app/help/cloud-auth (Domain.Read.All + UserAuthenticationMethod.ReadWrite.All).
$script:GRAPH_OPTIONAL_CAPS = @(
    # Also covers ISSUING a Temporary Access Pass on onboard (Invoke-CtgEntraTap) — same app role,
    # opposite lane: the offboard half warns, a TAP-issuing onboard FAILS.
    # NOT modelled: revoking sign-in sessions. Microsoft's docs say app-only revoke needs
    # User.RevokeSessions.All with no higher-privileged alternative, but that is stale — 12 production
    # offboards revoked sessions with User.ReadWrite.All and zero warnings.
    @{ need = 'remove MFA methods on offboard, and issue a Temporary Access Pass on onboard'; anyOf = @('UserAuthenticationMethod.ReadWrite.All')
       why  = "without it a leaver's registered second factors (phone / Authenticator / FIDO2) stay on the account and go live again the moment it is re-enabled; offboard warns and continues. A TAP-issuing onboard fails outright" }
    # Directory.Read.All / the Domain write roles are HIGHER-privileged alternatives Microsoft documents
    # for GET /domains, and they were missing here: a tenant holding Directory.Read.All reads domains
    # fine and was still told to grant Domain.Read.All (verified live on core1390 — 200, no Domain role).
    @{ need = "read the tenant's verified email domains (multi-domain clients)"; anyOf = @('Domain.Read.All', 'Domain.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All')
       why  = 'needed only when a client has more than one verified email domain, to pick the right one; single-domain clients are unaffected' }
    # The leaked-seat scan reads mailboxSettings.userPurpose to tell whether a disabled-but-licensed
    # user's mailbox was converted to shared (licence safe to remove) — mirrors the web table's cap.
    # Without this entry the surplus scan flagged a GRANTED MailboxSettings.Read as "not needed",
    # which the UI renders red and reads as a missing permission (core1787).
    @{ need = "read whether a leaver's mailbox was converted to shared"; anyOf = @('MailboxSettings.Read', 'MailboxSettings.ReadWrite')
       why  = "without it the leaked-seat scan can still see that a disabled user is still licensed, but cannot say whether their mailbox was converted to shared — so it can't tell you whether the licence is safe to remove yet" }
    # Get-CtgAppCredentialExpiry reads this app's own passwordCredentials/keyCredentials to warn before
    # the secret lapses. Degrades to a note, but nothing modelled it.
    @{ need = "warn before this app registration's own secret/certificate expires"; anyOf = @('Application.Read.All', 'Application.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All')
       why  = "without it the connection test cannot read the credential's expiry date, so it can't warn you in advance — the first sign is every M365 step failing at once on the day it lapses" }
    # Send-CtgGraphMail POSTs /users/{from}/sendMail. Same miss as the password reset: shipped, never
    # asked for, no tenant in the fleet has it.
    @{ need = 'send an offboard notification email as a mailbox'; anyOf = @('Mail.Send')
       why  = 'without it any configured onboard/offboard notification fails to send — the case still completes, so the mail simply never arrives. Only clients with a notification configured are affected' }
    # Update-MgDevice -AccountEnabled:$false. The device READ is fine on Directory.Read.All (Microsoft's
    # docs claim app-only is unsupported there; verified 200 against two live tenants) — this is the write.
    @{ need = "disable a leaver's Entra-joined devices"; anyOf = @('Device.ReadWrite.All', 'Directory.ReadWrite.All')
       why  = "without it the leaver's Entra device objects stay enabled; the offboard warns and continues. Only clients with disableDevices configured are affected" }
    # Graph treats passwordProfile as a PRIVILEGED write with its own app role: User.ReadWrite.All sets
    # a password as part of CREATING a user, but changing one afterwards is denied without this. That
    # split is why onboarding looks healthy while a reset fails on the same credential — only the reset
    # issues a passwordProfile UPDATE. Adopting is how you MEET this, not a cause: the adopt branch
    # never touches the password, so the operator follows up with "Generate random password" — the call
    # that gets denied. Optional because a client who never resets a cloud password is unaffected; it
    # does NOT degrade gracefully like the caps above — the step fails outright.
    @{ need = "reset a cloud user's password (the 'Generate random password' action)"; anyOf = @('User-PasswordProfile.ReadWrite.All')
       why  = "without it Graph denies the reset with 'Authorization_RequestDenied'; an onboard that CREATES the account sets its password as part of the create and is not affected" }
    # Grants a delegate access to a leaver's OneDrive on offboard.
    @{ need = "grant a delegate access to a leaver's OneDrive on offboard"; anyOf = @('Files.ReadWrite.All', 'Sites.ReadWrite.All')
       why  = "without it the offboard OneDrive delegate hand-off fails with a permission error; the step warns and continues" }
)
function Get-CtgGraphScopeGaps {
    param([string[]]$Granted)
    $gaps = @()
    foreach ($r in $script:GRAPH_REQUIRED_CAPS) {
        $have = $false
        foreach ($s in $r.anyOf) { if ($Granted -contains $s) { $have = $true; break } }
        if (-not $have) { $gaps += "$($r.need) — grant one of: $($r.anyOf -join ', ')" }
    }
    $gaps
}
# Roles that let a credential EXPAND ITS OWN AUTHORITY or reach the whole tenant's content. None is
# ever needed by this engine. Mirrors $GRAPH_ESCALATION_ROLES in web/lib/secrets/graph-caps.ts.
$script:GRAPH_ESCALATION_ROLES = @{
    'RoleManagement.ReadWrite.Directory'     = 'can assign directory roles — including making itself Global Administrator. This single role is a route to full tenant takeover'
    'AppRoleAssignment.ReadWrite.All'        = 'can consent app roles to itself — whatever it is missing, it can grant. It makes every other permission boundary advisory'
    'Application.ReadWrite.All'              = 'can add credentials to ANY app registration in the tenant, and so authenticate as any of them'
    'DelegatedPermissionGrant.ReadWrite.All' = "can grant delegated permissions on users' behalf, without those users consenting"
    'full_access_as_app'                     = 'full access to EVERY mailbox in the tenant — the engine only ever needs the mailboxes in a case'
    'Sites.FullControl.All'                  = 'full control of every SharePoint site in the tenant'
}
# Roles on OTHER resources the engine genuinely uses, so the surplus check doesn't call them unused.
#
# Sites.FullControl.All is deliberately NOT here. The Office 365 SharePoint Online app role of that
# name is what the offboard PnP site-collection-admin hand-off needs (Graph can't make a user a
# site-collection admin), and clients who wire that up genuinely grant it — but this model matches
# granted roles by NAME only, with no idea which API resource (Graph vs SharePoint Online) issued the
# grant. Microsoft Graph also exposes an app role literally named "Sites.FullControl.All" that grants
# full control of every SharePoint site via Graph — a real escalation, unrelated to the narrower
# SharePoint-resource grant. Moving this here (as a prior change did) makes the surplus scan blind to
# that Graph-resource escalation wherever it's actually present. Leaving it in
# $script:GRAPH_ESCALATION_ROLES is the safe default: clients using the SharePoint hand-off will see it
# flagged as extra-access (a known false positive documented in web/app/help/cloud-auth) — verify
# against the offboard result rather than removing it from escalation again.
$script:USED_NON_GRAPH_ROLES = @('Exchange.ManageAsApp')

# What is granted that the engine does NOT need — the opposite question to Get-CtgGraphScopeGaps, and
# the one a client's security team asks. "Needed" per capability is the FIRST granted role in its
# anyOf (least-privilege-first), so holding both User.ReadWrite.All and the broader
# Directory.ReadWrite.All reports the BROAD one, never the narrow one the engine runs on.
# ADVISORY: never feeds Get-CtgGraphScopeGaps, so it can never fail a test. The app registration may
# be shared with tooling that is none of our business — report it, don't presume to revoke it.
function Get-CtgGraphSurplusRoles {
    param([string[]]$Granted)
    $needed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in @($script:GRAPH_REQUIRED_CAPS) + @($script:GRAPH_OPTIONAL_CAPS)) {
        foreach ($s in $r.anyOf) { if ($Granted -contains $s) { [void]$needed.Add($s); break } }
    }
    foreach ($s in $script:USED_NON_GRAPH_ROLES) { [void]$needed.Add($s) }
    $out = @()
    foreach ($g in $Granted) {
        $esc = $script:GRAPH_ESCALATION_ROLES.Keys | Where-Object { $_ -ieq $g } | Select-Object -First 1
        if ($esc) { $out += @{ role = [string]$g; escalation = $true; why = [string]$script:GRAPH_ESCALATION_ROLES[$esc] }; continue }
        if ($needed.Contains($g)) { continue }
        $covered = @($script:GRAPH_REQUIRED_CAPS) + @($script:GRAPH_OPTIONAL_CAPS) | Where-Object { $_.anyOf -icontains $g } | Select-Object -First 1
        $narrower = if ($covered) { $covered.anyOf | Where-Object { $Granted -contains $_ } | Select-Object -First 1 }
        $out += @{
            role = [string]$g; escalation = $false
            why  = if ($narrower) { "redundant — $narrower is also granted and already covers `"$($covered.need)`", with less authority" }
                   else           { 'the engine never calls anything that needs this' }
        }
    }
    # Escalation first: that's what a security review needs to see.
    @($out | Sort-Object @{ Expression = { -[int][bool]$_.escalation } }, @{ Expression = { $_.role } })
}

# The same requirement map as structured per-operation rows for the conn-test result:
# @{ op; ok ($true/$false/$null = unverifiable); detail }.
function Get-CtgGraphRightsRows {
    param([string[]]$Granted)
    $rows = @()
    foreach ($r in $script:GRAPH_REQUIRED_CAPS) {
        $match = $null
        foreach ($s in $r.anyOf) { if ($Granted -contains $s) { $match = $s; break } }
        $rows += if ($match) { @{ op = [string]$r.need; ok = $true; detail = "granted via $match" } }
                 else        { @{ op = [string]$r.need; ok = $false; detail = "grant one of: $($r.anyOf -join ', ')" } }
    }
    # Optional caps carry optional=$true so the app shows a miss as a note, not a red failure — and
    # they're absent from Get-CtgGraphScopeGaps, so a missing one can never fail the test.
    foreach ($r in $script:GRAPH_OPTIONAL_CAPS) {
        $match = $null
        foreach ($s in $r.anyOf) { if ($Granted -contains $s) { $match = $s; break } }
        $rows += if ($match) { @{ op = [string]$r.need; ok = $true;  optional = $true; detail = "granted via $match" } }
                 else        { @{ op = [string]$r.need; ok = $false; optional = $true; detail = "optional — grant $($r.anyOf -join ' or ') — $($r.why)" } }
    }
    # ...and the other direction: authority granted that the engine never uses. Reported as rows like
    # any other so it shows up in the same table, but ALWAYS optional=$true — being over-permissioned
    # is a finding for the client's security team, not a fault in our setup, and must never fail the
    # test. ok=$false so it reads as "needs attention" rather than a tick.
    foreach ($s in Get-CtgGraphSurplusRoles $Granted) {
        $rows += @{
            op       = if ($s.escalation) { "OVER-PERMISSIONED: $($s.role)" } else { "not needed: $($s.role)" }
            ok       = $false
            optional = $true
            surplus  = $true
            detail   = if ($s.escalation) { "the engine never needs this — $($s.why). Raise it with the client; removing it is their call (the app registration may be shared)" }
                       else               { $s.why }
        }
    }
    $rows
}

# Rebuild rights rows for the result POST: every detail goes through the secret scrub, and the
# row's CLASSIFICATION flags ride along untouched. `optional`/`surplus` MUST survive this rebuild —
# a scrub that whitelists only op/ok/detail strips them, and the app then counts a missing OPTIONAL
# cap as a REQUIRED miss, turning "✓ ops +6 optional" into a red "✗ missing 6" (core1747).
function ConvertTo-CtgConnTestWireRights {
    param($Rows, $Creds)
    # Leading comma: a one-row result must stay an ARRAY through the function boundary, or it
    # serializes as a bare object and the app's parseRights (Array.isArray) drops it entirely.
    , @($Rows | ForEach-Object {
        $row = @{ op = [string]$_.op; ok = $_.ok; detail = Protect-CtgSecretsInText ([string]$_.detail) $Creds }
        if ($_.optional) { $row.optional = $true }
        if ($_.surplus) { $row.surplus = $true }
        $row
    })
}

# The app-only blind spot: Get-MgContext.Scopes is EMPTY for client-credentials auth (app perms ride
# the token's `roles` claim, not scopes), so the scope-gap check above can't see what's granted. This
# reads the ACTUAL consented application permissions from the directory: the app's service principal
# appRoleAssignments in THIS tenant, resolved to names (User.ReadWrite.All, …). Uses Invoke-MgGraphRequest
# (ships with the Authentication module — no extra Graph submodule). Returns:
#   @{ ok=$true;  roles=@('User.ReadWrite.All', …) }   when it could read them
#   @{ ok=$false; reason='…' }                          when it couldn't (usually the app lacks
#                                                        Application.Read.All / Directory.Read.All)
# A read-only Graph GET that survives transient throttling. When several M365 conn-tests run from the
# same app registration back-to-back (entra + m365 + exchange fire together), Graph 429s the later
# ones — which is precisely how the SAME credential could pass 'entra' and fail 'm365' seconds apart.
# Read-only, so retrying is always safe. Rethrows the last error once the retries are exhausted.
function Invoke-CtgGraphReadRetry {
    param([string]$Uri, [int]$MaxAttempts = 4)
    $attempt = 0
    while ($true) {
        try { return Invoke-MgGraphRequest -Method GET -ErrorAction Stop -Uri $Uri }
        catch {
            $attempt++
            $msg = [string]$_.Exception.Message
            $transient = $msg -match '(?i)\b429\b|throttl|too many request|tim(e|ed).?out|temporarily|\b50[0234]\b|gateway|unavailable|cancel(l)?ed'
            if (-not $transient -or $attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ([math]::Min(8, [math]::Pow(2, $attempt)))
        }
    }
}
function Get-CtgGrantedGraphAppRoles {
    $ctx = Get-MgContext
    if (-not $ctx -or -not $ctx.ClientId) { return @{ ok = $false; reason = 'no Graph context (not connected app-only)' } }
    $appId = [string]$ctx.ClientId
    try {
        $resp = Invoke-CtgGraphReadRetry "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$appId')/appRoleAssignments?`$top=200"
    }
    catch {
        return @{ ok = $false; reason = "couldn't read this app's granted application permissions — the app registration likely lacks Application.Read.All or Directory.Read.All (grant one so this check can verify the rest), or verify manually in Entra > App registrations > API permissions. ($([string]$_.Exception.Message))" }
    }
    $assignments = @($resp.value)
    if ($assignments.Count -eq 0) { return @{ ok = $true; roles = @(); complete = $true; unresolved = 0 } } # consented to NOTHING
    $rolesByResource = @{}  # resourceSpId -> @{ appRoleId -> value }  OR $null when that SP's read failed
    $names = [System.Collections.Generic.List[string]]::new()
    $unresolved = 0         # assignments whose role NAME we couldn't read — a partial view, NOT proof of absence
    foreach ($a in $assignments) {
        $rid = [string]$a.resourceId
        if (-not $rolesByResource.ContainsKey($rid)) {
            $map = $null
            try {
                $r = Invoke-CtgGraphReadRetry "https://graph.microsoft.com/v1.0/servicePrincipals/${rid}?`$select=appRoles"
                $map = @{}
                foreach ($ar in @($r.appRoles)) { $map[[string]$ar.id] = [string]$ar.value }
            }
            catch { $map = $null }  # $null (not empty) = couldn't resolve this SP's roles; must NOT be read as "granted nothing"
            $rolesByResource[$rid] = $map
        }
        $map = $rolesByResource[$rid]
        if ($null -eq $map) { $unresolved++; continue }  # the old bug: this used to silently drop the role
        $v = $map[[string]$a.appRoleId]
        if ($v) { $names.Add($v) } else { $unresolved++ }
    }
    return @{ ok = $true; roles = @($names | Sort-Object -Unique); complete = ($unresolved -eq 0); unresolved = $unresolved }
}

# Connection-test probes: after Connect (auth), one cheap authorized READ proves real access — not
# just that the credential authenticates. The m365 probe ALSO diffs the granted Graph scopes against
# what onboarding needs, so a permissions gap is reported by name. Systems with a $DISPATCH Connect
# but no probe here are connect-only. AD/dir-sync have no session Connect, so their probe binds with
# the ad-dc credential. Extend freely — keep reads cheap + read-only.
$CONNTEST_PROBE = @{
    'm365'             = { param($job, $creds)
        $org = $null; try { $org = @(Get-MgOrganization -ErrorAction Stop)[0] } catch { }
        # Show the tenant DISPLAY NAME + its default domain together — the display name (e.g.
        # "Newco, Inc.") often differs from the client name + the domain, which surprises operators.
        $dom = ''
        if ($org -and $org.VerifiedDomains) { $d = @($org.VerifiedDomains | Where-Object { $_.IsDefault }); if ($d.Count) { $dom = [string]$d[0].Name } }
        $base = if ($org) { "tenant: $($org.DisplayName)$(if ($dom) { " ($dom)" })" } else { "connected" }
        # Read the ACTUAL consented application permissions from the directory (app-only doesn't expose
        # them via Get-MgContext.Scopes). Falls back to delegated scopes if that's how we're connected.
        $granted = @(); $how = ''
        $real = Get-CtgGrantedGraphAppRoles
        if ($real.ok) { $granted = @($real.roles); $how = 'application permissions (consented in this tenant)' }
        else {
            $ctx = Get-MgContext
            if ($ctx -and $ctx.Scopes) { $granted = @($ctx.Scopes); $how = 'delegated scopes' }
        }
        if ($granted.Count -eq 0 -and -not $real.ok) {
            $script:ConnTestRights = @(@{ op = 'verify Graph permissions'; ok = $null; detail = [string]$real.reason })
            return "$base · connected, but couldn't verify permissions: $($real.reason)"
        }
        $script:ConnTestRights = @(Get-CtgGraphRightsRows $granted)
        # Warn before the app's own secret/cert expires (best-effort; needs Application.Read.All).
        try { $exp = Get-CtgAppCredentialExpiry; if ($exp -and $exp.expiresAt) { $script:ConnTestCredExpiresAt = [string]$exp.expiresAt } } catch { }
        $gaps = Get-CtgGraphScopeGaps $granted   # REQUIRED-only — optional caps never appear here
        if ($gaps.Count) {
            # A PARTIAL read (Graph throttled some appRole lookups) can make a granted permission look
            # missing. Never fail on a permission we couldn't fully read: downgrade the apparent gaps
            # to "unverifiable" and pass the test with a re-test nudge, instead of a false red.
            if ($real.ok -and -not $real.complete) {
                foreach ($row in $script:ConnTestRights) {
                    if ($row.ok -eq $false -and -not $row.optional) {
                        $row.ok = $null
                        $row.detail = "couldn't verify — the granted-permission read was incomplete (Graph throttled it; $($real.unresolved) assignment(s) unresolved). Re-test; this is NOT a confirmed gap."
                    }
                }
                return "$base · connected, but couldn't fully read the app's granted Graph permissions (throttled — $($real.unresolved) unresolved). Re-test to verify. Partial: $(@($granted) -join ', ')"
            }
            throw "$base · consented ${how}: [$(@($granted) -join ', ')] — but MISSING: $($gaps -join ' || '). Add these as APPLICATION permissions on the app registration and grant admin consent IN THIS TENANT, then re-test."
        }
        "$base · all required Graph permissions present — ${how}: $(@($granted) -join ', ')"
    }
    'exchange'         = { param($job, $creds)
        $o = Get-OrganizationConfig -ErrorAction Stop
        # A successful app-only connect + org read PROVES the app holds Exchange.ManageAsApp + the
        # Exchange Administrator role — Connect-ExchangeOnline app-only cannot mint a token without both,
        # and any Exchange cmdlet (this one included) would 401/403 without them. So report the one
        # Exchange right as satisfied: an Exchange-Online client with Exchange.ManageAsApp granted now
        # reads 1/1 in the rights panel, instead of a blank/no-rights row.
        $script:ConnTestRights = @(@{ op = 'run Exchange Online cmdlets app-only (Exchange.ManageAsApp + Exchange Administrator role)'; ok = $true; detail = "connected app-only to $($o.Name)" })
        "org: $($o.Name)"
    }
    'mimecast'         = { param($job, $creds)
        # Probe the actual operations onboarding needs and report which the API 2.0 app is permitted
        # to do — so "Test connections" shows the app's real permission map (Mimecast has no API to
        # list an app's granted permissions; this infers them from what works). Each op is also
        # posted as a structured rights row.
        $ops = [System.Collections.Generic.List[hashtable]]::new()
        $try = {
            param($label, $path)
            try { Invoke-CtgMimecastApi -Path $path | Out-Null; @{ op = $label; ok = $true; detail = 'allowed' } }
            catch {
                if ([string]$_.Exception.Message -match 'forbidden|not .{0,6}permitted|denied|unauthoriz|\b403\b') { @{ op = $label; ok = $false; detail = 'FORBIDDEN — grant it on the API 2.0 app' } }
                else { @{ op = $label; ok = $null; detail = "error: $(([string]$_.Exception.Message).Substring(0, [Math]::Min(120, ([string]$_.Exception.Message).Length)))" } }
            }
        }
        $ops.Add((& $try 'account read'           '/api/account/get-account'))
        $ops.Add((& $try 'directory/domains read' '/api/domain/get-internal-domain'))
        $ops.Add((& $try 'directory-sync read'    '/api/directory/get-connection'))
        # USER read is what onboarding actually needs (get-profile). Probe a benign address in an internal
        # domain. A PER-ADDRESS forbidden (postmaster@ isn't a managed user) is NOT a permission gap — the
        # app was allowed to CALL get-profile, which is what we're testing. Only a genuine app permission gap
        # (app_forbidden — User & Group Management not assigned) counts. Test-CtgMimecastPermissionForbidden
        # makes that distinction, matching Get-CtgMimecastProfile, so this test can't false-flag a correctly
        # permissioned app as FORBIDDEN (which used to fail the whole test).
        $dom = $null
        try { $idr = @(Invoke-CtgMimecastApi -Path '/api/domain/get-internal-domain'); $dom = @($idr | ForEach-Object { $d = Get-CtgProp $_ 'domain'; if (-not $d) { $d = Get-CtgProp $_ 'domainName' }; $d } | Where-Object { $_ })[0] } catch { }
        if ($dom) {
            try {
                $resp = Invoke-CtgMimecastApi -Path '/api/user/get-profile' -Data @{ emailAddress = "postmaster@$dom" } -AllowFail
                $failText = @(@(Get-CtgProp $resp 'fail') | ForEach-Object { @(Get-CtgProp $_ 'errors') | ForEach-Object { "$(Get-CtgProp $_ 'code'): $(Get-CtgProp $_ 'message')" } }) -join '; '
                if (Test-CtgMimecastPermissionForbidden $failText) { $ops.Add(@{ op = 'user read (get-profile)'; ok = $false; detail = 'FORBIDDEN — grant the API 2.0 app User & Group Management (Directory + User read)' }) }
                else { $ops.Add(@{ op = 'user read (get-profile)'; ok = $true; detail = 'allowed' }) }
            } catch { $ops.Add(@{ op = 'user read (get-profile)'; ok = $null; detail = 'error probing' }) }
        }
        $script:ConnTestRights = @($ops)
        $report = @($ops | ForEach-Object { "$($_.op): $(if ($_.ok -eq $true) { 'allowed' } elseif ($_.ok -eq $false) { 'FORBIDDEN' } else { 'error' })" })
        $detail = "app permissions -> $($report -join ' | ')"
        # Fail the test (visibly red) when a permission onboarding needs is missing.
        if (@($ops | Where-Object { $_.ok -eq $false }).Count) { throw $detail }
        $detail
    }
    'active-directory' = { param($job, $creds)
        $c = New-CtgAdConnection $creds; $d = Get-ADDomain @c -ErrorAction Stop
        # Rights: can the service account CREATE USERS in the OUs this client's config targets?
        # Evaluated from the OU ACLs (read-only) via the pure helper in Coretelligent.ActiveDirectory;
        # anything unreadable degrades to "verify manually", never a false failure.
        $ous = @()
        foreach ($pair in @(@('onboard', 'ou'), @('offboard', 'moveToOu'), @('offboard', 'disabledUsersOu'))) {
            $lane = Get-CtgProp $job.config $pair[0]
            $v = if ($lane) { [string](Get-CtgProp $lane $pair[1]) } else { $null }
            if ($v -and $v -match '(?i)dc=') { $ous += $v }
        }
        $ous = @($ous | Select-Object -Unique)
        if ($ous.Count -and $script:CtgAdIdentity.kind -eq 'ambient') {
            # We bind as the agent's OWN identity here, not the ad-dc account — so there is no service
            # account whose OU ACL means anything. Evaluating ad-dc's ACL anyway would report on a
            # principal the jobs never use: a false red when ad-dc was never delegated (SYSTEM always
            # could), or the more dangerous false green in reverse.
            if (Test-CtgAdAmbientIsPrivileged) {
                $script:ConnTestRights = @(@{ op = 'create users in target OU'; ok = $true
                        detail = 'the agent runs as SYSTEM on this domain controller — the directory''s own SYSTEM principal, full control. No ad-dc credential is used'
                    })
            }
            else {
                $script:ConnTestRights = @(@{ op = 'create users in target OU'; ok = $null
                        detail = 'no ad-dc credential is wired, so the agent binds as its own machine account — verify manually that it can create users here, or wire the ad-dc secret'
                    })
            }
        }
        elseif ($ous.Count) {
            $sids = Get-CtgAdAccountSids -AdConnection $c -SamAccountName $script:CtgAdIdentity.sam
            $rows = @()
            foreach ($ou in $ous) {
                $rows += Test-CtgAdOuCreateUserRight -AdConnection $c -OuDn $ou -Sids $sids
            }
            $script:ConnTestRights = @($rows)
            $denied = @($rows | Where-Object { $_.ok -eq $false })
            if ($denied.Count) { throw "domain: $($d.DNSRoot) — $($script:CtgAdIdentity.label) cannot create users in: $(@($denied | ForEach-Object { $_.op }) -join '; ')" }
        }
        else {
            $script:ConnTestRights = @(@{ op = 'create users in target OU'; ok = $null; detail = 'no OU DN in this client''s config — set onboard.ou to verify the ACL' })
        }
        "domain: $($d.DNSRoot)"
    }
    'directory-sync'   = { param($job, $creds) $c = New-CtgAdConnection $creds; $d = Get-ADDomain @c -ErrorAction Stop; "AD reachable: $($d.DNSRoot)" }
}
$CONNTEST_PROBE['entra'] = $CONNTEST_PROBE['m365']  # entra is the M365 module's Entra slice — same Graph perms
# Cloud REST systems: after Connect (above), do one read so the test validates the credential +
# read scope against the live API (not just that Connect assembled an auth header).
$CONNTEST_PROBE['zoom']        = { param($job, $creds)
    Invoke-CtgZoomApi -Method GET -Path '/users?page_size=1' | Out-Null
    # The S2S token response names the app's granted scopes (Connect captures them) — compare
    # against what the on/offboarders actually call: user reads, user writes (create/update/
    # deactivate), and — only when the client's config assigns phone — phone writes.
    $scopes = @(Get-CtgZoomGrantedScopes)
    if ($scopes.Count -eq 0) {
        $script:ConnTestRights = @(@{ op = 'verify Zoom scopes'; ok = $null; detail = 'token response carried no scope list — verify the S2S app scopes in the Zoom marketplace' })
        return 'zoom: users readable'
    }
    $capOf = { param($label, $pattern, $hint)
        if (@($scopes | Where-Object { $_ -match $pattern }).Count) { @{ op = $label; ok = $true; detail = "granted ($(@($scopes | Where-Object { $_ -match $pattern }) -join ', '))" } }
        else { @{ op = $label; ok = $false; detail = $hint } }
    }
    $rows = @(
        (& $capOf 'read users'                  '^user:read'   'grant user:read:admin (or the granular read scopes) on the S2S app')
        (& $capOf 'create / update / deactivate users' '^user:write' 'grant user:write:admin (or the granular write scopes) on the S2S app')
    )
    $wantsPhone = $false
    foreach ($lane in @('onboard', 'offboard')) { $c = Get-CtgProp $job.config $lane; if ($c -and (Get-CtgProp $c 'phone')) { $wantsPhone = $true } }
    if ($wantsPhone) { $rows += (& $capOf 'assign phone' '^phone:write' 'grant phone:write:admin — this client''s config assigns Zoom Phone') }
    $script:ConnTestRights = @($rows)
    $missing = @($rows | Where-Object { $_.ok -eq $false })
    if ($missing.Count) { throw "zoom: users readable, but the S2S app is missing scopes -> $(@($missing | ForEach-Object { $_.op }) -join ', '). $(@($missing | ForEach-Object { $_.detail }) -join ' | ')" }
    "zoom: users readable — scopes cover $(@($rows | ForEach-Object { $_.op }) -join ', ')"
}
$CONNTEST_PROBE['sentinelone'] = { param($job, $creds)
    Invoke-CtgSentinelOneApi -Method GET -Path '/web/api/v2.1/agents?limit=1' | Out-Null
    # Offboarding needs more than a read: try to name the API token's role. S1 has no clean
    # "what can I do" endpoint, so an unreadable role is reported as unverifiable, not a failure.
    $role = $null
    try { $me = Invoke-CtgSentinelOneApi -Method GET -Path '/web/api/v2.1/user'; $role = [string](Get-CtgProp (Get-CtgProp $me 'data') 'scopeRoles') } catch { }
    $roleDetail = if ($role) { "API user roles: $role — confirm they allow agent actions" } else { 'no role introspection API — verify the token''s role allows agent actions' }
    $script:ConnTestRights = @(@{ op = 'agent actions (offboard disconnect/shutdown)'; ok = $null; detail = $roleDetail })
    'sentinelone: agents readable'
}
$CONNTEST_PROBE['xmatters']    = { param($job, $creds)
    Invoke-CtgXMattersApi -Method GET -Path '/people?limit=1' | Out-Null
    $script:ConnTestRights = @(@{ op = 'create / delete people'; ok = $null; detail = 'xMatters has no permission introspection — verify the API user has the "REST Web Service User" role' })
    'xmatters: people readable'
}
# Google Workspace: domain-wide-delegation token minting is all-or-nothing — the exchange itself
# fails (unauthorized_client) if ANY requested scope isn't authorized for the service account's
# client ID. So a successful Connect PROVES every requested scope; one live read then proves the
# impersonated admin works. That turns the token grant into a real per-scope rights check.
$CONNTEST_PROBE['google-workspace'] = { param($job, $creds)
    # The customer id lives in the MODULE's script scope — from here $script:GoogleCustomer is a
    # different (never-assigned) variable, so interpolating it sent an EMPTY customer= param and
    # Google 400'd every probe (FR#35). Read it through the module's exported seam instead.
    $customer = Get-CtgGoogleCustomer
    $resp = Invoke-CtgGoogleApi -Method GET -Path "/users?customer=$customer&maxResults=1"
    $scopes = @(Get-CtgGoogleSessionScopes)
    $script:ConnTestRights = @($scopes | ForEach-Object {
        @{ op = "scope $((($_ -split '/')[-1]))"; ok = $true; detail = 'authorized via domain-wide delegation (token minted with this scope)' }
    })
    # Connect-CtgGoogle ASKS for admin.directory.user.security and falls back without it, so a
    # connected session does NOT imply the domain authorized it. Report its absence explicitly —
    # otherwise every scope row is green while offboarding silently cannot revoke a leaver's
    # sessions/refresh tokens, and the operator has no way to see that from here.
    $securityScope = 'https://www.googleapis.com/auth/admin.directory.user.security'
    if ($scopes.Count -and ($scopes -notcontains $securityScope)) {
        $script:ConnTestRights += @{
            op = 'scope admin.directory.user.security'; ok = $false
            detail = 'NOT authorized — offboarding cannot sign a leaver out (their sessions and refresh tokens survive the suspend). Add this scope in Admin Console -> Security -> API controls -> Domain-wide delegation.'
        }
    }
    if ($scopes.Count -eq 0) { $script:ConnTestRights = @(@{ op = 'verify delegation scopes'; ok = $null; detail = 'session did not record its scopes (token passed directly?)' }) }
    # Use-CtgGoogleSecret self-healed a bad customer id to my_customer — say so HERE, where the
    # operator who can fix the Delinea secret actually looks; the runner host's log file is not it.
    if ($script:GoogleCustomerAdvisory) {
        $script:ConnTestRights += @(@{ op = 'workspace customer id'; ok = $null; detail = $script:GoogleCustomerAdvisory })
    }
    "google: users readable (delegation scopes verified: $($scopes.Count))"
}
# Spanning has NO Connect in $DISPATCH (Connect-CtgSpanning is a pure local assignment), so the probe
# reads the brokered secret itself (Use-CtgSpanningSecret) then does one live LIST read. The /users
# LIST route is the VERIFIED one (the /users/{email} route 400s on some tenants), so listing a single
# user proves the Basic clientId:clientSecret actually authorizes a read against the live API.
$CONNTEST_PROBE['spanning']    = { param($job, $creds)
    Use-CtgSpanningSecret $job $creds
    $resp  = Invoke-CtgSpanningApi -Method GET -Path '/users?size=1'
    $users = Get-CtgProp $resp 'users'; if ($null -eq $users) { $users = Get-CtgProp $resp 'items' }; if ($null -eq $users) { $users = $resp }
    # Rights: license assign/unassign is the only WRITE onboarding does. Probe authz without
    # touching a user — an EMPTY userPrincipalNames list either 400s (validation ran => the request
    # passed authn/authz) or no-ops; a 401/403 means the token can't assign. NEVER send a real UPN.
    $assign = try {
        Invoke-CtgSpanningApi -Method POST -Path '/users/assign' -Body @{ userPrincipalNames = @(); licenseType = 'STANDARD' } | Out-Null
        @{ op = 'license assign/unassign'; ok = $true; detail = 'authorized (empty-list probe accepted)' }
    } catch {
        $m = [string]$_.Exception.Message
        if ($m -match 'HTTP 400')            { @{ op = 'license assign/unassign'; ok = $true;  detail = 'authorized (empty-list probe reached validation)' } }
        elseif ($m -match 'HTTP 40[13]')     { @{ op = 'license assign/unassign'; ok = $false; detail = 'token cannot assign licenses (401/403) — generate the API token as a Spanning admin' } }
        else                                 { @{ op = 'license assign/unassign'; ok = $null;  detail = 'cannot verify without licensing a user — verify manually' } }
    }
    $rights = [System.Collections.Generic.List[hashtable]]::new()
    $rights.Add(@{ op = 'read users'; ok = $true; detail = 'list read works' })
    $rights.Add($assign)
    $script:ConnTestRights = @($rights)
    if ($assign.ok -eq $false) { throw "spanning: users readable, but $($assign.detail)" }
    $detail = "spanning: users readable (sample returned $(@($users).Count))"

    # The CONSOLE sign-in is a second, independent credential: the browser force-sync signs in to the
    # Spanning admin console through Microsoft 365 SSO, which the API clientId/secret cannot do. It is
    # brokered as its own 'spanning-portal' secret and is OPTIONAL — licensing (both lanes) is pure API,
    # so a client that never force-syncs needs none of this and must stay green.
    $portal = if ($creds.ContainsKey('spanning-portal')) { $creds['spanning-portal'] } else { $null }
    if (-not $portal) {
        # Say it in the DETAIL line, not as a rights row: a row with ok=$null would drag every Spanning
        # client that only does licensing from "verified" to "unverified" — a fleet-wide false alarm for
        # a capability they don't use. This is the honest middle: visible, not alarming.
        return "$detail · no 'spanning-portal' secret wired, so force-sync is unavailable (licensing is unaffected)"
    }
    # A real sign-in is expensive and INTERACTIVE, so only a targeted single-system retest runs it —
    # never a sweep, which would fire one M365 sign-in per client per run.
    if (-not $job.deep) {
        return "$detail · a 'spanning-portal' secret is wired; use Test on the Spanning system to verify the console sign-in"
    }
    if (-not (Test-CtgBrowserAvailable)) {
        $rights.Add(@{ op = 'console sign-in (browser)'; ok = $null; detail = 'this agent has no browser runtime (Node/Playwright) — cannot verify the console sign-in from here' })
        $script:ConnTestRights = @($rights)
        return "$detail · console sign-in not checked (no browser runtime on this agent)"
    }
    # Mint the MFA code from the CONN-TEST credential endpoint, at the prompt (same contract as a job).
    $otpReq = @{ url = "$AppUrl/api/runner/conn-tests/$($job.connTestId)/credential"; token = (Get-CtgBearer); agentId = $AgentId; secretName = 'spanning-portal' }
    $signin = Test-CtgSpanningPortalLogin -Secret $portal -SecretName 'spanning-portal' -OtpRequest $otpReq
    $rights.Add(@{ op = 'console sign-in (browser)'; ok = $signin.Ok; detail = [string]$signin.Detail })
    $script:ConnTestRights = @($rights)
    # A broken console sign-in must NOT fail the test: the API — which is all that licensing needs — is
    # demonstrably fine. It surfaces as a red rights row, which is what "partial" is for.
    if (-not $signin.Ok) { return "$detail · console sign-in FAILED: $($signin.Detail)" }
    "$detail · console sign-in OK ($($signin.Detail))"
}
# Proofpoint Essentials: read the org's Azure sync settings (also proves the X-User/X-Password admin
# auth + org-path domain). Reports whether sync is on, its frequency, and the last successful sync —
# the same signal the onboarding lane uses to decide "wait for the next sync" vs. "sync isn't enabled".
# Slack SCIM: one cheap authorized read proves the token has the `admin` scope AND that the workspace's
# plan actually includes SCIM — the two things that stop this working, and which are indistinguishable
# from each other (and from a bad token) unless the probe names them.
$CONNTEST_PROBE['slack']       = { param($job, $creds)
    Use-CtgSlackSecret $job $creds
    try {
        $resp  = Invoke-CtgSlackScim -Method GET -Path '/Users' -Query @{ count = 1 }
        $total = Get-CtgProp $resp 'totalResults'
        $script:ConnTestRights = @(
            @{ op = 'read members (SCIM)'; ok = $true; detail = 'list read works' },
            # Deactivation is the only WRITE the offboard does. There is no way to probe it without
            # actually deactivating somebody, so say that plainly rather than implying it's verified.
            @{ op = 'deactivate a member'; ok = $null; detail = "cannot verify without deactivating a real member — the same 'admin'-scoped token does both, so a passing read is a strong signal" }
        )
        "slack: SCIM reachable, members readable$(if ($null -ne $total) { " (workspace has $total)" })"
    }
    catch {
        $m = [string]$_.Exception.Message
        if (Test-CtgSlackNoScim $m) {
            $script:ConnTestRights = @(@{ op = 'read members (SCIM)'; ok = $false; detail = 'SCIM not available — needs a Business+/Enterprise Grid plan' })
            throw "slack: the SCIM API is not available for this workspace ($m). SCIM needs a Business+ or Enterprise Grid plan, and the token must carry the 'admin' scope and be generated by an Owner/Admin. See /help/slack."
        }
        throw
    }
}
$CONNTEST_PROBE['proofpoint']  = { param($job, $creds)
    Use-CtgProofpointSecret $job $creds
    $az = Get-CtgProofpointAzureSync
    if ($null -eq $az) { return 'proofpoint: connected (admin auth OK) — but Azure/Entra sync is not configured for this org' }
    $freq = Get-CtgProp $az 'sync_frequency'; $last = Get-CtgProp $az 'last_successful_sync'
    $script:ConnTestRights = @(@{ op = 'user create / deactivate'; ok = $null; detail = 'Proofpoint has no permission introspection — verify the API account''s admin role allows user management' })
    "proofpoint: connected — Azure sync $(if ($freq -and "$freq" -ne '0') { "on (every ${freq}h)" } else { 'OFF' })$(if ($last) { ", last sync $last" })"
}
# 1Password: only the api method has a credential to test — prove the admin `op` sign-in works + can
# read users. scim/manual/browser have no app credential, so report that there's nothing to probe.
$CONNTEST_PROBE['1password']   = { param($job, $creds)
    $method = ([string](Get-CtgProp $job.config 'method')); if (-not $method) { $method = 'auto' }
    if ($method -in @('scim', 'manual', 'browser')) { return "1password: method '$method' uses no API credential — nothing to test (provisioning is $(if ($method -eq 'scim') { 'IdP/SCIM-driven' } else { 'manual' }))" }
    Use-Ctg1PasswordSecret -Job $job -Creds $creds
    $who = Invoke-Ctg1PasswordCli -OpArgs @('whoami') -AllowFail
    Invoke-Ctg1PasswordCli -OpArgs @('user', 'list') -AllowFail | Out-Null
    $script:ConnTestRights = @(@{ op = 'provision / suspend users'; ok = $null; detail = '1Password has no permission introspection — verify the account is in the Provision Managers group (or is an owner/admin)' })
    "1password: signed in + users readable$(if ($who) { " (as $([string](Get-CtgProp $who 'email')))" })"
}

function Invoke-CtgConnectionTests {
    # Claim + run any queued connection tests for this agent. Fully isolated from the job pipeline:
    # connect with the brokered credential, run the read probe, report pass/fail + a one-line detail.
    $tests = @()
    try { $tests = Invoke-AppApi POST '/api/runner/conn-tests/claim' @{ agentId = $AgentId; max = 5 } } catch { return }
    # Flatten an exception chain to a one-line, secret-redacted message.
    $errLine = { param($e, $c) $ex = $e.Exception; $ch = [System.Collections.Generic.List[string]]::new(); while ($ex) { if ($ex.Message) { [void]$ch.Add($ex.Message) }; $ex = $ex.InnerException }; Protect-CtgSecretsInText (($ch | Select-Object -Unique) -join ' <- ') $c }
    foreach ($t in @($tests)) {
        $global:CtgProgressJobId = $null   # no job -> keep Connect's Set-CtgPhase from posting progress
        # TWO STAGES, reported separately: (1) ACCESS — can the runner resolve the secret(s) from the
        # app/Delinea; (2) API — connect + one live read against the vendor. A failed access skips API.
        $accessOk = $true; $accessDetail = ''
        $apiOk = $true; $apiDetail = ''
        $creds = @{}
        # Probes may fill this with per-operation rights rows (@{ op; ok; detail }); it survives a
        # probe THROW so a definite permission gap still reports which ops passed/failed.
        $script:ConnTestRights = $null
        $script:ConnTestCredExpiresAt = $null   # a probe may set the credential's own expiry (ISO)
        # Pass the system's config so a Connect that reads it (e.g. exchange's onPremExchangeUri) works
        # in the test. It's the whole ClientSystem.config (onboard/offboard sub-objects), not a lane.
        # connTestId + deep let a probe run an INTERACTIVE check (a real browser sign-in) and mint its
        # MFA code from the conn-test credential endpoint. `deep` is true only when an operator retested
        # this one system by hand — never on a sweep, which must not fire a real portal login per client.
        $job = [pscustomobject]@{ id = ''; systemKey = $t.systemKey; action = 'onboard'; config = $t.config; client = [pscustomobject]@{ slug = $t.clientSlug; primaryDomain = $t.primaryDomain }; connTestId = $t.id; deep = [bool]$t.deep }

        # Same client boundary the job loop enforces — the two loops share this process's sessions and
        # the same $script:CurrentClientKey, so the boundary holds whichever kind of work crosses it.
        # This is not hypothetical: in UM0029840 it was Olympus Cosmetic's CONN TESTS that bound Graph,
        # and an Easterseals JOB twelve minutes later that inherited it.
        [void](Reset-CtgCloudSessionsOnClientChange $job)

        try {
            $names = @(@($t.secretNames) | Where-Object { $_ })
            foreach ($sn in $names) { $creds[$sn] = Get-ConnTestCredential $t.id $sn }
            $accessDetail = if ($names.Count) { "resolved $($names.Count) secret$(if ($names.Count -ne 1) { 's' }): $($names -join ', ')" } else { 'no secret required' }
        }
        catch {
            $accessOk = $false; $accessDetail = & $errLine $_ $creds
            $apiOk = $false; $apiDetail = 'skipped — secret not resolved from Delinea'
        }

        # OPTIONAL secrets (e.g. spanning-portal, the console sign-in behind force-sync) are brokered
        # BEST-EFFORT, each in its own try: they back a capability the client may not use, so a missing
        # or unresolvable one must NOT fail the test. Failing here would report the whole system red —
        # and with the setup gate in enforce mode that would withhold its real jobs — because an extra,
        # optional credential is broken. The probe sees the secret simply absent and says so.
        if ($accessOk) {
            foreach ($sn in @(@($t.optionalSecretNames) | Where-Object { $_ })) {
                try { $creds[$sn] = Get-ConnTestCredential $t.id $sn }
                catch { Write-CtgLog "conn-test: optional secret '$sn' could not be brokered — $($_.Exception.Message)" 'WARN' }
            }
        }

        if ($accessOk) {
            try {
                $handler = $DISPATCH[$t.systemKey]
                $probe = $CONNTEST_PROBE[$t.systemKey]
                # Low-code connector: no built-in probe, but the claim injected the published
                # definition — run its `test` lane as the probe (config.connector, like the job path).
                if (-not $handler -and -not $probe -and (Get-CtgProp (Get-CtgProp $t.config 'connector') 'definition')) {
                    $probe = { param($job, $creds)
                        $r = Test-CtgConnectorConnection -Config $job.config -Credentials $creds -Client $job.client
                        if (-not $r.ok) { throw ([string]$r.detail) }
                        [string]$r.detail
                    }
                }
                $hasConnect = $handler -and $handler.ContainsKey('Connect')
                if (-not $hasConnect -and -not $probe) { throw "no automated connection test available for '$($t.systemKey)' — verify it manually" }
                if ($hasConnect) { & $handler.Connect $job $creds; $apiDetail = 'connected' }
                if ($probe) { $apiDetail = & $probe $job $creds }
            }
            catch { $apiOk = $false; $apiDetail = & $errLine $_ $creds }
            finally {
                # A conn-test connects OUTSIDE the cached-connection path — drop this system's cache key
                # so the next REAL job reconnects with its own tenant/creds (never reuses this session).
                # Siblings too: an m365 conn-test rebinds the one Graph session that entra/tap/notify/
                # m365-password-reset also ride, so their cache keys are stale as well.
                Clear-CtgConnectionSiblings -SystemKey $t.systemKey -IncludeSelf
            }
        }
        $body = @{ agentId = $AgentId; accessOk = $accessOk; accessDetail = "$accessDetail"; ok = $apiOk; detail = "$apiDetail" }
        if ($script:ConnTestRights) {
            # Scrub each row's detail like the top-level details — never a secret in a rights row.
            $body.rights = ConvertTo-CtgConnTestWireRights $script:ConnTestRights $creds
        }
        if ($script:ConnTestCredExpiresAt) { $body.credExpiresAt = [string]$script:ConnTestCredExpiresAt }
        $script:ConnTestRights = $null
        $script:ConnTestCredExpiresAt = $null
        try { $null = Invoke-AppApi POST "/api/runner/conn-tests/$($t.id)/result" $body } catch { }
    }
}

function Invoke-CtgCloudGroupDiscovery {
    # Central runner only (the claim endpoint returns nothing to client agents). For each client that
    # requested it, connect to M365 with the brokered m365 secret and read the tenant's groups, tagged
    # DL / Security / M365 Group, so the app's pickers can offer cloud groups AD sync never covers.
    $work = @()
    try { $work = Invoke-AppApi POST '/api/runner/cloud-groups/claim' @{ agentId = $AgentId } } catch { return }
    foreach ($w in @($work)) {
        $global:CtgProgressJobId = $null
        try {
            # Rebuild $creds from the pushed fields (push-down model — no Delinea creds on the runner).
            $creds = @{}
            if ($w.creds) {
                foreach ($p in $w.creds.PSObject.Properties) {
                    $f = @{}
                    if ($p.Value.fields) { foreach ($q in $p.Value.fields.PSObject.Properties) { $f[$q.Name] = $q.Value } }
                    $username = Select-CtgCredField $f $script:CRED_USERNAME_FIELDS
                    $pw = Select-CtgCredField $f $script:CRED_PASSWORD_FIELDS
                    $password = if ($pw) { ConvertTo-SecureString $pw -AsPlainText -Force } else { $null }
                    $cred = if ($username -and $password) { [pscredential]::new([string]$username, $password) } else { $null }
                    $creds[$p.Name] = [pscustomobject]@{ Username = $username; Password = $password; Credential = $cred; Fields = $f }
                }
            }
            $job = [pscustomobject]@{ id = ''; systemKey = 'm365'; client = [pscustomobject]@{ slug = $w.clientSlug; primaryDomain = $w.primaryDomain } }
            & $DISPATCH['m365'].Connect $job $creds
            # Don't let a real job reuse this connection — and not just an m365 job: this Connect bound
            # the shared Graph session, so entra/tap/notify/m365-password-reset are stale too.
            Clear-CtgConnectionSiblings -SystemKey 'm365' -IncludeSelf
            $groups = @()
            foreach ($g in (Get-MgGroup -All -Property 'DisplayName,GroupTypes,MailEnabled,SecurityEnabled' -ErrorAction Stop)) {
                $type = if ($g.GroupTypes -contains 'Unified') { 'm365' }
                        elseif ($g.MailEnabled -and -not $g.SecurityEnabled) { 'dl' }
                        else { 'security' }
                if ($g.DisplayName) { $groups += @{ name = [string]$g.DisplayName; type = $type } }
            }
            $null = Invoke-AppApi POST '/api/runner/cloud-groups/result' @{ agentId = $AgentId; clientSlug = $w.clientSlug; groups = $groups }
            Write-Host "  cloud groups: reported $($groups.Count) for $($w.clientSlug)" -ForegroundColor Green

            # Also enumerate the tenant's SHARED MAILBOXES so the per-client "default shared-mailbox
            # access" picker (FR #15) can offer a real list. Best-effort + separate from groups: this
            # needs Exchange Online (app-only cert on the m365-admin secret); a client whose secret has
            # no EXO cert just gets no mailbox list (the operator can still type an address). Groups were
            # already reported above, so a failure here never loses them.
            try {
                $exoCert = Get-CtgExoCertArgs $creds['m365-admin']
                if ($exoCert.Count -eq 0) {
                    Write-Host "  shared mailboxes: skipped for $($w.clientSlug) — m365-admin secret has no EXO cert" -ForegroundColor DarkGray
                } else {
                    & $DISPATCH['exchange'].Connect $job $creds
                    $mailboxes = @()
                    foreach ($mb in (Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited -ErrorAction Stop)) {
                        $addr = [string](Get-CtgProp $mb 'PrimarySmtpAddress')
                        if ($addr) { $mailboxes += @{ address = $addr; displayName = [string](Get-CtgProp $mb 'DisplayName') } }
                    }
                    $null = Invoke-AppApi POST '/api/runner/cloud-mailboxes/result' @{ agentId = $AgentId; clientSlug = $w.clientSlug; mailboxes = $mailboxes }
                    Write-Host "  shared mailboxes: reported $($mailboxes.Count) for $($w.clientSlug)" -ForegroundColor Green
                }
            } catch {
                Write-Warning "shared mailbox discovery failed for $($w.clientSlug): $($_.Exception.Message)"
            } finally {
                try { Disconnect-CtgExchange } catch { }
                Clear-CtgConnectionSiblings -SystemKey 'm365' -IncludeSelf
            }
        } catch {
            Write-Warning "cloud group discovery failed for $($w.clientSlug): $($_.Exception.Message)"
        }
    }
}

# Build id of the code we're actually running = hash of our own files (matches the app's hash of the
# bundle it serves). Reported on every heartbeat → accurate even if a past restart half-landed, with
# no marker file to keep in sync.
# Before the hash: a leftover pre-1.123 inflight.json would otherwise be folded into this runner's
# build id, which the app's bundle can never match — the "told to update, never converges" loop.
if (Remove-CtgLegacyInFlight -RunnerDir $PSScriptRoot) {
    Write-CtgLog -Level INFO -Message "removed the legacy shared inflight.json (superseded by a per-agent marker; not reported — it carries no agent id)"
}
$script:RunnerBuild = Get-CtgBuildId

# Human-readable release version from VERSION (e.g. "1.0.0"), reported alongside the build id so the
# Agents page can show "v1.0.0 · build <hash>". Display only — the hash stays the up-to-date check.
$script:RunnerSemver = try { (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw -ErrorAction Stop).Trim() } catch { $null }

# This process's start time (ISO-8601 UTC), reported on every heartbeat so the Agents page can show
# UPTIME (now - bootAt). Re-exec on update/restart is a new process, so uptime correctly resets then.
$script:RunnerStartedAt = (Get-Date).ToUniversalTime().ToString("o")
# Last app-URL migration failure (unreachable / rewrite failed). Reported on the heartbeat so the
# Agents page can show it; cleared on a successful migrate. Defined here so the heartbeat ref is always set.
$script:LastMigrateError = $null

# On-prem CAPABILITY probe: which ALWAYS_ON_PREM system keys THIS host can actually execute — i.e. the
# host-specific Coretelligent entry function is loaded (its dependency module imported above). Reported
# each heartbeat so the app WITHHOLDS on-prem jobs from agents that can't run them (they stay pending
# with a clear reason) instead of dispatching a step that hard-fails with "module not loaded". Extend
# this map when a new ALWAYS_ON_PREM system is added. (directory-sync's module loads unconditionally and
# remotes to the sync host, so it's ~always capable; active-directory needs the ActiveDirectory module.)
$script:OnPremCapabilityProbe = [ordered]@{
    'active-directory' = 'Invoke-CtgADOnboarding'
    'directory-sync'   = 'Invoke-CtgDirectorySync'
}
$script:RunnerCapabilities = @(
    $script:OnPremCapabilityProbe.Keys | Where-Object { Get-Command $script:OnPremCapabilityProbe[$_] -ErrorAction SilentlyContinue }
)
# What a finished background job actually SAID. Receive-Job returns only the success stream, and
# `2>&1` merges only the ERROR stream -- so a job whose diagnosis is written with Write-Warning and
# Write-Host (which is every Coretelligent.* installer) returns nothing but its scriptblock's return
# value. For a failed install that value is $false, which then reads as "no output at all".
#
# That is not hypothetical: it is why every failed browser install reported "finished without a
# usable sidecar and gave no output" instead of the npm exit code the runner had in hand. Read the
# job's OWN stream collections instead -- Warning, Error and Information are all held on the child
# job object -- and deliberately ignore Output, because a bare True/False is not a diagnosis.
# Never throws: this runs while reporting a failure and must not become one.
function Get-CtgJobDiagnostic {
    param($Job, [int]$Lines = 4)
    try {
        if (-not $Job) { return '' }
        $cj = if ($Job.ChildJobs -and $Job.ChildJobs.Count) { $Job.ChildJobs[0] } else { $Job }
        $all = New-Object System.Collections.Generic.List[string]
        foreach ($i in @($cj.Information)) { if ($i) { $all.Add([string]$i.MessageData) } }
        foreach ($w in @($cj.Warning))     { if ($w) { $all.Add([string]$w.Message) } }
        foreach ($e in @($cj.Error))       { if ($e) { $all.Add([string]$e) } }
        # A job killed by a THROW puts nothing in .Error — the exception is on JobStateInfo.Reason,
        # and without this a crashed installer still looks like it said nothing.
        if ($cj.JobStateInfo -and $cj.JobStateInfo.Reason) { $all.Add([string]$cj.JobStateInfo.Reason.Message) }
        $kept = @($all | Where-Object { $_ -and $_.Trim() })
        if (-not $kept.Count) { return '' }
        return (($kept | Select-Object -Last $Lines) -join ' | ')
    } catch { return '' }
}

# Self-heal the browser sidecar ONCE at startup (mirrors the RSAT block above). Capabilities are
# computed here, once per process, and the claim gate WITHHOLDS browser jobs from agents not reporting
# 'browser' — so a lazy first-use install could never happen (the agent would never receive the job).
# The install (npm install + a ~170MB Chromium download) MUST NOT run inline: it takes minutes on a
# cold host and, on one with no egress to npmjs.org / the Playwright CDN, blocks until its timeout.
# Inline, that delays the FIRST heartbeat — the agent goes silent, the app shows it stuck "updating",
# and an operator debugs a phantom install/auth problem. So: kick it off in the BACKGROUND, heartbeat
# immediately, and start advertising 'browser' on a later beat once it finishes (the poll loop's
# capability refresh below). Opt out with IAM_RUNNER_NO_BROWSER_INSTALL=1 — the installer sets that
# for client-network agents, which have no business running headless Chromium on a DC.
$script:BrowserInstallJob = $null
# An operator's "Install browser" click, persisted by the poll loop below and resumed here. It
# outranks IAM_RUNNER_NO_BROWSER_INSTALL (the operator is opting this host in, exactly as the
# in-loop handler does) and it bootstraps a portable Node, which is the whole point: on a host with
# no Node the plain self-heal below is gated off by Resolve-CtgNodeTool and can never fire.
$script:BrowserInstallWanted = Test-CtgBrowserInstallRequest -RunnerDir $PSScriptRoot -AgentId $AgentId
if ($env:IAM_RUNNER_NO_BROWSER_INSTALL -eq '1' -and -not $script:BrowserInstallWanted) {
    Write-Host "Browser sidecar: install disabled (IAM_RUNNER_NO_BROWSER_INSTALL=1) — browser jobs are withheld from this agent." -ForegroundColor DarkGray
}
elseif (-not (Test-CtgBrowserAvailable) -and ($script:BrowserInstallWanted -or (Resolve-CtgNodeTool 'node'))) {
    if ($script:BrowserInstallWanted) { Write-Host "Resuming the operator's browser-automation install (requested earlier, not yet finished)…" -ForegroundColor Yellow }
    else { Write-Host "Browser sidecar not fully installed — installing Playwright + Chromium in the BACKGROUND (the runner keeps polling)…" -ForegroundColor Yellow }
    try {
        $script:BrowserModulePath = (Get-Module Coretelligent.Browser).Path
        $script:BrowserInstallJob = Start-Job -Name 'ctg-browser-install' -ScriptBlock {
            param($m, $boot)
            Import-Module $m -Force
            $r = if ($boot) { Install-CtgBrowser -BootstrapNode } else { Install-CtgBrowser }
            [bool]$r
        } -ArgumentList $script:BrowserModulePath, ([bool]$script:BrowserInstallWanted)
    } catch {
        Write-Warning "browser sidecar: could not start the background install: $($_.Exception.Message) — browser jobs will be withheld"
    }
}
# Browser automation is a CROSS-CUTTING capability (not an on-prem system): report 'browser' when the
# Node/Playwright sidecar is installed on this host, so the app's claim gate hands browser jobs (e.g.
# spanning-force-sync) only to agents that can actually run them. The server ignores 'browser' in the
# on-prem exclusion (it's not in ALWAYS_ON_PREM_SYSTEMS) and keys the separate browser gate off it.
if (Test-CtgBrowserAvailable) {
    $script:RunnerCapabilities += 'browser'
    Clear-CtgBrowserInstallRequest -RunnerDir $PSScriptRoot -AgentId $AgentId   # done — stop resuming it
}
# Serialize as a JSON-array STRING so 0- and 1-element lists stay arrays over the wire — a bare
# @('active-directory') would ConvertTo-Json to a scalar and @() would pipe nothing (empty output),
# making the server unable to tell "reported, none" (withhold all on-prem) from "legacy runner, not
# reported" (allow, old behavior). Empty is forced to the literal '[]' (an empty pipe emits nothing).
$script:RunnerCapabilitiesJson = if ($script:RunnerCapabilities.Count -eq 0) { '[]' } else { ($script:RunnerCapabilities | ConvertTo-Json -Compress -AsArray) }
Write-Host "on-prem capabilities: $script:RunnerCapabilitiesJson" -ForegroundColor DarkGray

# The PnP install runs at line ~353, long before Write-CtgLog exists, so its failure is RECORDED there
# and reported here — the first point in startup where it can reach a file that outlives the process.
# This matters because the runner is typically a Windows SYSTEM scheduled task: the Write-Warning that
# install emits goes to a console nobody is attached to, which is exactly how FR #0000116 stayed
# invisible from July to September. Logged once at startup, not per job.
if ($script:LastPnpError) { Write-CtgLog -Level WARN -Message "PnP.PowerShell unavailable: $script:LastPnpError" }

# Single-instance guard, keyed PER AGENT. The newest runner process for THIS agentId claims
# .runner.<agentId>.lock with its PID at startup; an OLDER process for the same agent (e.g. one a
# half-landed self-update failed to replace) sees a different PID on its next loop and exits. Without
# this, a stale process keeps claiming jobs with OLD in-memory modules while a newer process reports
# the new build — "agent up to date but running old code", which silently ran outdated executors.
# The agentId in the filename is what lets a runner POOL (Start-IamRunnerPool.ps1) run N members in
# one folder without them evicting each other — each member owns its own lock; the newest-PID-wins
# eviction still fires WITHIN one agentId. (Keep this format in lockstep with Get-CtgPoolLockPath in
# lib/Coretelligent.Pool.) Lock I/O is best-effort (never fatal).
$script:LockPath = Join-Path $PSScriptRoot ".runner.$AgentId.lock"
try { [System.IO.File]::WriteAllText($script:LockPath, [string]$PID) } catch { }

Write-Host "iam-engine runner $AgentId (build $script:RunnerBuild, pid $PID) polling $AppUrl every ${PollSeconds}s" -ForegroundColor Cyan
# Per-process progress globals, read by Send-CtgProgress (callable from the Coretelligent.* modules).
$global:CtgProgressUrl   = $AppUrl
$global:CtgProgressToken = Get-CtgBearer
$global:CtgProgressAgent = $AgentId

# Arm the stall watchdog (lib/Coretelligent.Watchdog) on its own thread: if no progress for
# $StallTimeoutSeconds it self-respawns + hard-exits, recovering from a hung inline job the main loop
# can't escape. Build the same relaunch spec the self-update uses (cross-platform Start-Process).
Update-CtgHeartbeat -Path $global:CtgHeartbeatFile -Phase 'starting'
$wdPwsh = (Get-Process -Id $PID).Path
if (-not $wdPwsh) { $wdPwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
$wdSelf = Join-Path $PSScriptRoot 'Start-IamRunner.ps1'
$wdArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$wdSelf,'-AppUrl',$AppUrl,'-AgentId',$AgentId,'-PollSeconds',$PollSeconds,'-BatchSize',$BatchSize,'-ExoModuleVersion',$ExoModuleVersion)
if ($AgentToken) { $wdArgs += @('-AgentToken',$AgentToken) }
elseif ($ApiToken) { $wdArgs += @('-ApiToken',$ApiToken) }
$script:Watchdog = Start-CtgWatchdog -HeartbeatFile $global:CtgHeartbeatFile -TimeoutSeconds $StallTimeoutSeconds -PwshPath $wdPwsh -RelaunchArgs $wdArgs
Write-Host "watchdog armed: restart if no progress for ${StallTimeoutSeconds}s (heartbeat $global:CtgHeartbeatFile)" -ForegroundColor DarkGray

# Did the PREVIOUS process die mid-job? Report it before claiming anything new, so the step fails with
# a reason now rather than ageing out of its claim lease half an hour later. Runs once, here, because
# by this point Invoke-AppApi and the agent token are both live.
try {
    $recovered = Report-CtgAbandonedJob -Post {
        param([string]$JobId, [string]$Why)
        $null = Invoke-AppApi POST "/api/jobs/$JobId/result" @{ agentId = $AgentId; status = 'failed'; error = $Why }
    }
    if ($recovered) { Write-Host "recovered abandoned job $recovered from the previous process — reported as failed" -ForegroundColor Yellow }
} catch { Write-Warning "abandoned-job recovery: $($_.Exception.Message)" }

while ($true) {
    # Liveness tick: the loop is alive (idle or between jobs). A long job keeps this fresh via
    # Send-CtgProgress; only a TRUE hang (no progress) lets it go stale and trips the watchdog.
    Update-CtgHeartbeat -Path $global:CtgHeartbeatFile -Phase 'polling'
    $jobs = @()   # reset BEFORE try: a heartbeat/claim throw must not leave a stale value driving the drain check below
    # Superseded by a newer instance? It overwrote .runner.lock with its PID at startup. Exit so this
    # (older) process stops heartbeating + claiming jobs with stale modules. Best-effort; on any lock
    # read error we just continue (fail open — better to keep running than to wrongly self-terminate).
    try {
        if (Test-Path -LiteralPath $script:LockPath) {
            $owner = ([System.IO.File]::ReadAllText($script:LockPath)).Trim()
            if ($owner -and $owner -ne [string]$PID) {
                Write-Warning "a newer runner instance (pid $owner) has taken over; exiting this one (pid $PID)."
                exit 0
            }
        }
    } catch { }
    # Capability refresh: the browser sidecar installs in the BACKGROUND (see startup), so 'browser'
    # isn't known at first heartbeat. When that job finishes, re-probe once and fold the capability in
    # so the NEXT heartbeat advertises it and the app's gate starts routing browser jobs here.
    if ($script:BrowserInstallJob) {
        $st = $script:BrowserInstallJob.State
        if ($st -in @('Completed', 'Failed', 'Stopped')) {
            # KEEP what the job said. Install-CtgBrowser warns with the actual reason (npm exit code and
            # its output tail, a missing node, an absent sidecar directory) and this used to pipe all of
            # it to Out-Null — so a failed install left the operator a guess ("no egress?") in a local
            # log file and nothing at all in the app. Two installs failed that way unnoticed.
            # Read the job's streams BEFORE Receive-Job drains them. Warning/Information is where
            # Install-CtgBrowser's reason lives; Receive-Job's success output is just a bool.
            $detail = Get-CtgJobDiagnostic -Job $script:BrowserInstallJob
            try { $null = Receive-Job -Job $script:BrowserInstallJob -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $script:BrowserInstallJob -Force -ErrorAction SilentlyContinue } catch { }
            $script:BrowserInstallJob = $null
            if (Test-CtgBrowserAvailable) {
                if ($script:RunnerCapabilities -notcontains 'browser') { $script:RunnerCapabilities += 'browser' }
                $script:RunnerCapabilitiesJson = ($script:RunnerCapabilities | ConvertTo-Json -Compress -AsArray)
                $script:LastBrowserInstallError = $null
                Clear-CtgBrowserInstallRequest -RunnerDir $PSScriptRoot -AgentId $AgentId   # done — stop resuming it
                Write-Host "Browser sidecar ready — now advertising 'browser' ($script:RunnerCapabilitiesJson)" -ForegroundColor Green
            } else {
                # Reported on the next heartbeat (see $hbBody) so the Agents page shows the reason
                # instead of a spinner that never resolves.
                $script:LastBrowserInstallError = if ($detail) { $detail } else { "the install finished without a usable sidecar and reported nothing at all. runner.log will not have it either (that file holds only Write-CtgLog lines, and on a Windows SYSTEM task there is no stdout log). Run this on the host to see it directly: Import-Module <runner>/modules/Coretelligent.Browser -Force; Install-CtgBrowser -BootstrapNode" }
                Write-Warning "browser sidecar install did not complete: $script:LastBrowserInstallError — browser jobs stay withheld from this agent. Set IAM_RUNNER_NO_BROWSER_INSTALL=1 to stop retrying."
            }
        }
    }
    try {
        # Report the app URL we're polling (so the app knows where each agent lives + can detect a
        # completed migration) and any last migrate failure (surfaced on the Agents page).
        $hbBody = @{ agentId = $AgentId; version = $script:RunnerBuild; semver = $script:RunnerSemver; startedAt = $script:RunnerStartedAt; capabilities = $script:RunnerCapabilitiesJson; appUrl = $AppUrl; authMode = $(if ($script:AgentToken) { 'per-agent' } else { 'shared' }) }
        if ($script:LastMigrateError) { $hbBody['migrateError'] = $script:LastMigrateError }
        if ($script:LastBrowserInstallError) { $hbBody['browserInstallError'] = $script:LastBrowserInstallError }
        # The EXO pin has no capability to key off, so health is STATED rather than inferred: exoPinOk
        # clears any recorded reason server-side, exactly as reporting 'browser' does for the sidecar.
        $hbBody['exoPinOk'] = [bool](-not $script:LastExoPinError)
        if ($script:LastExoPinError) { $hbBody['exoPinError'] = $script:LastExoPinError }
        $hb = Invoke-AppApi POST '/api/agents/heartbeat' $hbBody
        if ($hb.enabled -eq $false) { Write-Warning "agent disabled server-side; stopping."; break }
        # Adopt a delivered per-agent token BEFORE update/restart handling below: the token is a
        # one-shot delivery (see runner-service.ts heartbeat/provisionToken), so if it lands on the
        # same heartbeat as a pending update or restart and we processed those first, we'd never
        # return from Update-CtgRunner/Restart-CtgRunner and the token would be discarded forever.
        # Ordering it first is harmless the other way: a pending auto-update simply re-emits on the
        # runner's NEXT heartbeat (a plain relaunch here doesn't change the reported build, so the
        # app still sees it as stale), and a missed one-shot restart is harmless because the adopt's
        # own relaunch already restarted the process.
        if ($hb.provisionToken) {
            # The app is arming (or completing) our migration to a per-agent token. Adopt it (persist +
            # switch bearer + drop the shared token — see lib/CtgAgentAuth.ps1), then re-exec via the
            # same self-rewrite path a plain restart uses so the launcher/env is clean going forward.
            Write-Host "token: received a per-agent token — adopting and restarting" -ForegroundColor Yellow
            Set-CtgAgentToken -Token ([string]$hb.provisionToken)
            Invoke-CtgRelaunch -Reason 'token-adopt'  # never returns
        }
        # Operator requested "Install browser automation" (Agents page). Handled HERE, ahead of update
        # and restart, for the same reason provisionToken is: installBrowser is a ONE-SHOT server-side
        # consume (runner-service.ts clears the flag as it stamps the delivery) and BOTH of those
        # branches end in Invoke-CtgRelaunch, which never returns. Handled after them, a click that
        # arrived on the same heartbeat as an update was consumed and thrown away -- delivered, never
        # acted on, no error ever recorded, and the Agents page stuck on "installed but this runner
        # still does not report it" forever.
        #
        # Ordering alone would not be enough: the install is a background job that dies with this
        # process, so an update seconds later still kills it. So the request is PERSISTED first and
        # startup resumes it -- which also covers a watchdog restart mid-download. An explicit click
        # outranks IAM_RUNNER_NO_BROWSER_INSTALL: the operator is opting this host in.
        if ($hb.PSObject.Properties['installBrowser'] -and $hb.installBrowser -eq $true) {
            Set-CtgBrowserInstallRequest -RunnerDir $PSScriptRoot -AgentId $AgentId
            if (-not $script:BrowserInstallJob -and -not (Test-CtgBrowserAvailable)) {
                Write-Host "Operator requested browser automation — installing Node (if needed) + Playwright + Chromium in the BACKGROUND…" -ForegroundColor Yellow
                try {
                    $script:BrowserModulePath = (Get-Module Coretelligent.Browser).Path
                    $script:BrowserInstallJob = Start-Job -Name 'ctg-browser-install' -ScriptBlock {
                        param($m)
                        Import-Module $m -Force
                        [bool](Install-CtgBrowser -BootstrapNode)
                    } -ArgumentList $script:BrowserModulePath
                } catch {
                    Write-Warning "browser sidecar: could not start the operator-requested install: $($_.Exception.Message)"
                }
            }
        }
        if ($hb.update -eq $true) {
            # Self-update. A STANDALONE runner (single-agent install, RUNNER_POOL_MEMBER unset) pulls +
            # relaunches itself, exactly as before. A POOL MEMBER yields: it must NOT pull, because N
            # members sharing one folder all pulling at once races (half-written files) and stampedes
            # the relaunch. Instead it drops a sentinel the supervisor sees and exits; the supervisor
            # pulls ONCE for the whole pool and respawns members staggered (Start-IamRunnerPool.ps1).
            if ($env:RUNNER_POOL_MEMBER) {
                try { [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot '.runner-pool.update'), [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())) } catch { }
                Write-Host "self-update requested — pooled member: signaling the supervisor to pull once + exiting" -ForegroundColor Yellow
                Invoke-CtgRelaunch -Reason 'pool-update-yield'  # supervised -> exit 0; the supervisor pulls + respawns
            }
            Update-CtgRunner  # standalone: re-pull + restart (never returns)
        }
        if ($hb.restart -eq $true) { Restart-CtgRunner }  # operator requested a plain restart — re-exec (never returns)
        if ($hb.discover -eq $true) { Invoke-CtgAdDiscovery }  # operator requested AD OU/group discovery
        if ($hb.migrate -and $hb.migrate.appUrl) { Invoke-CtgMigrate -NewAppUrl ([string]$hb.migrate.appUrl) }  # operator moved the app — verify + rewrite supervisor + switch
        # Maintenance drain (feature #7): the app is quiescing the fleet (e.g. an Azure host cutover).
        # Any job already in hand finished normally in the foreach below on a prior cycle (with its
        # -finally teardown); we simply CLAIM NOTHING NEW and idle until the operator clears maintenance.
        # Honored AFTER update/restart/migrate (each of those re-execs/moves and never returns, so this
        # only fires when none of them did — the correct precedence). Named $script:Draining /
        # 'maintenanceDrain' to avoid colliding with the local "drain the queue" idiom in the sleep-tail.
        # Backward-compatible: a runner that never learns this field just keeps claiming, but the app's
        # claim() gate returns [] during a global drain, so it is still starved of work (defense in depth).
        $script:Draining = ($hb.PSObject.Properties['drain'] -and $hb.drain -eq $true)
        if ($script:Draining) {
            Update-CtgHeartbeat -Path $global:CtgHeartbeatFile -Phase 'draining'  # keep the watchdog armed while idle
            Write-Host "maintenance drain active — claiming nothing new; idling until it clears" -ForegroundColor Yellow
            $jobs = @()            # nothing claimed this cycle (keeps the sleep-tail invariant intact)
            Start-Sleep -Seconds $PollSeconds
            continue               # skip claim + the job foreach; loop back to the heartbeat next cycle
        }
        # Send our build id so the app refuses to dispatch to a STALE runner (a half-landed update can
        # leave an old process alive; this stops it claiming jobs with old modules in memory).
        $jobs = Invoke-AppApi POST '/api/jobs/claim' @{ agentId = $AgentId; batchSize = $BatchSize; version = $script:RunnerBuild }

        foreach ($job in @($jobs)) {
            $creds = @{}  # in scope for the catch's secret-scrub even if broking/execution throws early
            $script:Phase = 'starting'  # what we're doing now — the catch reports WHICH phase failed
            $global:CtgProgressJobId = $job.id  # so module-level Send-CtgProgress targets this job
            Set-CtgInFlight $job                # on disk, so a killed process can report it next start
            # Header line so the console shows WHICH CASE this job is for (not just the opaque job id).
            $caseNo = if ($job.PSObject.Properties['caseNumber'] -and $job.caseNumber) { [string]$job.caseNumber } else { '(no case #)' }
            Write-Host "[$caseNo] $($job.action) $($job.systemKey)  (job $($job.id))" -ForegroundColor Cyan
            # A system with no per-user config (mimecast, spanning, …) is planned with config=null; the
            # executors take a [Mandatory] -Config, which a null fails to bind ("Cannot bind argument to
            # parameter 'Config' because it is null"). Normalize to an empty object — Get-CtgProp on it
            # just returns null for absent keys, so base onboarding runs.
            if ($null -eq $job.config) { $job.config = [pscustomobject]@{} }
            try {
                $handler = $DISPATCH[$job.systemKey]
                # Low-code connector fallback: no built-in executor, but the app injected a published
                # definition at claim — the generic interpreter runs it. Built-ins ALWAYS win above.
                if (-not $handler -and (Get-CtgProp (Get-CtgProp $job.config 'connector') 'definition')) {
                    $handler = $CONNECTOR_HANDLER
                }
                if (-not $handler) {
                    # No executor for this system: resolve as a manual follow-up, not a failure,
                    # so an uncovered `api` system doesn't kill the whole case.
                    $null = Invoke-AppApi POST "/api/jobs/$($job.id)/result" @{ agentId = $AgentId; status = 'skipped'; error = "no executor for $($job.systemKey) — manual follow-up" }
                    continue
                }
                $fn = switch ($job.action) {
                    'offboard' { $handler.Offboard }
                    'change'   { if ($handler.ContainsKey('Change')) { $handler.Change } else { $null } }
                    default    { $handler.Onboard }
                }
                if (-not $fn) {
                    $null = Invoke-AppApi POST "/api/jobs/$($job.id)/result" @{ agentId = $AgentId; status = 'skipped'; error = "no $($job.action) lane for $($job.systemKey) — manual follow-up" }
                    continue
                }

                # First thing the operator sees for this step — it has started.
                Set-CtgPhase $job.id "starting $($job.action) $($job.systemKey)"

                # Broker every secret the job names (least-privilege, one call each), keyed by name.
                # Before anything connects: if the last work this process did was for a DIFFERENT
                # client, drop every session it left bound. Nothing downstream then has to be clever
                # about whose tenant it is talking to.
                [void](Reset-CtgCloudSessionsOnClientChange $job)

                Set-CtgPhase $job.id 'brokering credentials'
                foreach ($sn in @($job.secretNames)) { if ($sn) { $creds[$sn] = Get-JobCredential $job.id $sn } }

                # Connect before the first job for this system, and RE-connect whenever the job's
                # tenant OR its brokered credentials differ from what the module is currently
                # connected with (modules hold one connection; see $script:ConnectedTenant). The key
                # includes a fingerprint of the brokered secret fields so that (a) two clients that
                # both lack a primaryDomain but carry different secret TenantIds can NEVER share a
                # connection (the raw-domain key would collide on ''), and (b) rotating a credential
                # in Delinea reconnects on the very next job — no runner restart. Record the key ONLY
                # after Connect succeeds — a throw here (bad cred, unreachable on-prem Exchange,
                # transient) must NOT poison the cache, or every later job in this long-lived process
                # would skip Connect and run unconnected (e.g. "Get-RemoteMailbox not recognized").
                if ($handler.ContainsKey('Connect')) {
                    $tenant = if ($job.client) { $job.client.primaryDomain } else { '' }
                    $connectKey = "$tenant|$(Get-CtgCredFingerprint $creds)"
                    if ($script:ConnectedTenant[$job.systemKey] -ne $connectKey) {
                        Set-CtgPhase $job.id "connecting to $($job.systemKey)"
                        & $handler.Connect $job $creds
                        $script:ConnectedTenant[$job.systemKey] = $connectKey
                        # This Connect just rebound any session shared with sibling keys (Graph/Google),
                        # so their cached keys no longer describe the live connection — drop them or the
                        # next sibling job skips Connect and runs against THIS job's tenant.
                        Clear-CtgConnectionSiblings -SystemKey $job.systemKey
                    }
                }

                # Verify pass: run ONLY the read-only validator (Confirm-Ctg*), no executor/mutation.
                if ([bool]$job.validateOnly) {
                    Set-CtgPhase $job.id "verifying $($job.systemKey)"
                    $vfn = $handler.Validate
                    $vbody = @{ agentId = $AgentId; status = 'succeeded' }
                    if ($vfn) {
                        $validation = & $vfn $job $creds
                        if ($null -ne $validation) { $vbody.validation = $validation }
                    } else {
                        # No validator: report a passing validation, NOT a result — posting a result
                        # here would REPLACE the executor's stored result (and its WARN action lines)
                        # when the auto-verify sweep re-runs a succeeded job.
                        $vbody.validation = @{ ok = $true; checks = @(@{ name = 'no validator for this system — nothing to verify'; expected = $true; actual = $true; pass = $true }) }
                    }
                    $null = Invoke-AppApi POST "/api/jobs/$($job.id)/result" $vbody
                    continue
                }

                $dryRun = [bool]$job.dryRun
                Set-CtgPhase $job.id "$($job.action) $($job.systemKey)$(if ($dryRun) { ' (dry run)' })"
                # Self-heal once: if execution fails because a cmdlet's module isn't installed, find +
                # install it (trusted modules only) and retry — so a missing Graph/EXO submodule fixes
                # itself instead of failing the step.
                $outcome = $null
                for ($try = 0; $try -lt 2; $try++) {
                    try { $outcome = Invoke-JobWithValidation -Job $job -Handler $handler -Fn $fn -Creds $creds -DryRun $dryRun; break }
                    catch {
                        $missing = Get-CtgMissingCommandName $_
                        # A missing '*-Ctg*' function is one of OUR bundled module functions, NOT a
                        # gallery module to install. Two causes, distinguished so the operator isn't
                        # sent chasing RSAT on a host where the module loaded fine (INC0858516):
                        # loaded-but-unexported = the module's .psd1 FunctionsToExport filters out
                        # whatever Export-ModuleMember says; not loaded = missing host dependency.
                        if ($missing -like '*-Ctg*') {
                            $owner = Get-Module Coretelligent.* | Where-Object { $_.ExportedFunctions.Keys -notcontains $missing -and (Get-Content -Raw "$($_.ModuleBase)/$($_.Name).psm1" -ErrorAction SilentlyContinue) -match "function\s+$([regex]::Escape($missing))\b" } | Select-Object -First 1
                            if ($owner) {
                                throw "'$missing' exists in the $($owner.Name) module (loaded on this host) but is NOT exported — its .psd1 FunctionsToExport is missing it (manifest drift). Fix the manifest and update the runner; nothing needs installing on this host."
                            }
                            throw "the Coretelligent module providing '$missing' isn't loaded on this host — it needs a host-specific dependency (the ActiveDirectory/RSAT module for AD, ExchangeOnlineManagement for Exchange, the ADSync module for directory-sync). This step must run on the client-network agent that has it, not the central/cloud runner."
                        }
                        if ($try -eq 0 -and $missing) {
                            Set-CtgPhase $job.id "missing command '$missing' — locating + installing its module"
                            $mod = Repair-CtgMissingModule $missing
                            if ($mod) { Set-CtgPhase $job.id "installed $mod — retrying $($job.systemKey)"; continue }
                            # Installed, but deliberately not loaded into this process (assembly clash).
                            # Fail the step with something an operator can act on, rather than the bare
                            # "not recognized" — the restart happens as soon as this job is off the box.
                            if ($script:CtgRestartReason) {
                                throw "'$missing' needs a module that was just installed but CANNOT be loaded into the running runner without hanging it (it shares .NET assemblies with an already-loaded module). The runner is restarting now — re-run this step once it is back up."
                            }
                        }
                        # Self-heal a STALE app-only Graph token: a RequestDenied on a Graph-backed step is
                        # often a token minted BEFORE consent was granted (the runner connects once per
                        # tenant and reuses it). Force a fresh token — disconnect (clears the MSAL cache),
                        # drop the cached connection, reconnect — and retry ONCE. If it's a genuinely
                        # missing permission this just fails again and the accurate hint below fires.
                        #
                        # Gate on the Graph connection GROUP, not a hardcoded @('m365','entra'): every key
                        # in that group shares the one Graph session, so every one of them can hold the
                        # stale token — but m365-password-reset, tap and notify were excluded and never
                        # healed. That bit exactly when it was needed most: an admin grants
                        # User-PasswordProfile.ReadWrite.All, the operator retries the reset, and it is
                        # denied by the pre-consent token with no way forward but a manual runner restart.
                        if ($try -eq 0 -and ($script:ConnectionGroups.graph -contains $job.systemKey) -and $handler.ContainsKey('Connect') -and
                            ([string]$_.Exception.Message -match 'Insufficient privileges|Authorization_RequestDenied|Access(Denied| is denied)')) {
                            Set-CtgPhase $job.id "RequestDenied — refreshing the Graph token (new app-only token) and retrying once"
                            try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
                            if ($script:ConnectedTenant) { [void]$script:ConnectedTenant.Remove($job.systemKey) }
                            & $handler.Connect $job $creds
                            $script:ConnectedTenant[$job.systemKey] = "$(if ($job.client) { $job.client.primaryDomain } else { '' })|$(Get-CtgCredFingerprint $creds)"
                            # Disconnect-MgGraph tore down the session entra/tap/notify/m365-password-reset
                            # share, and the reconnect above bound it to THIS job's tenant — their cached
                            # keys describe a connection that no longer exists. Forget them.
                            Clear-CtgConnectionSiblings -SystemKey $job.systemKey
                            continue
                        }
                        throw
                    }
                }
                $body = @{ agentId = $AgentId; status = 'succeeded'; result = $outcome.Result }
                if ($null -ne $outcome.Validation) { $body.validation = $outcome.Validation }
                # Surface the module's evidence snapshot (e.g. group memberships captured before an
                # offboard removes them) so it's persisted with the job and shown in the run report.
                if ($outcome.Result -and $outcome.Result.PSObject.Properties['Evidence'] -and $null -ne $outcome.Result.Evidence) {
                    $body.evidence = $outcome.Result.Evidence
                }
                # Retry a TRANSIENT failure of the success post (network blip) before giving up. If it
                # still won't post, do NOT fall through to the catch — that would record a false 'failed'
                # for a job that actually SUCCEEDED. Leave it for the app's stale-lease reclaim +
                # idempotent re-run instead.
                $posted = $false
                for ($rp = 0; $rp -lt 3; $rp++) {
                    try { $null = Invoke-AppApi POST "/api/jobs/$($job.id)/result" $body; $posted = $true; break }
                    catch { if ($rp -lt 2) { Start-Sleep -Seconds 5 } }
                }
                if (-not $posted) {
                    Write-Warning "job $($job.id) SUCCEEDED but the result post failed after 3 tries — leaving it for lease-reclaim + idempotent re-run (not recording a false failure)"
                    Write-CtgLog -Level WARN -Message "job $($job.id) [$($job.systemKey)] succeeded; result post failed 3x — will be reclaimed and re-run"
                }
            }
            catch {
                # Walk the FULL inner-exception chain (deduped) so the real cause surfaces — a generic
                # outer like "Authentication failed, see inner exception" usually wraps the actual
                # logon/LDAP error (e.g. "The user name or password is incorrect", "account locked").
                $chain = [System.Collections.Generic.List[string]]::new()
                $exObj = $_.Exception  # keep the top exception object for provider-specific enrichment below
                $ex = $exObj
                while ($ex) { if ($ex.Message) { [void]$chain.Add($ex.Message) }; $ex = $ex.InnerException }
                $msg = (($chain | Select-Object -Unique) -join ' <- ')
                if (-not $msg) { $msg = $_.Exception.GetType().Name }
                # A Graph "Insufficient privileges" tells you nothing about WHICH permission is missing.
                # Always append the permission the FAILING PHASE needs (reliable across auth modes), and
                # refine it with the precise gap from granted scopes when we can read them. Best-effort —
                # never let this enrichment break the real error report.
                if (($job.systemKey -in @('m365', 'entra')) -and ($msg -match 'Insufficient privileges|Authorization_RequestDenied|Access(Denied| is denied)')) {
                    $ph = [string]$script:Phase
                    $need = if ($ph -match 'group') { 'Group.ReadWrite.All (or GroupMember.ReadWrite.All)' }
                            elseif ($ph -match 'licen') { 'User.ReadWrite.All + Organization.Read.All' }
                            elseif ($ph -match 'user|creat|onboard|attribute|disable') { 'User.ReadWrite.All' }
                            else { 'User.ReadWrite.All, Group.ReadWrite.All, Organization.Read.All' }
                    $hint = "the app registration is missing a Graph APPLICATION permission for this step ($ph) — grant + admin-consent: $need"
                    try {
                        # Prefer the REAL consented application permissions (read from the directory) over the
                        # phase heuristic — app-only auth hides them from Get-MgContext.Scopes.
                        $real = Get-CtgGrantedGraphAppRoles
                        $granted = @()
                        if ($real.ok) { $granted = @($real.roles) }
                        else { $ctx = Get-MgContext; if ($ctx -and $ctx.Scopes) { $granted = @($ctx.Scopes) } }
                        if ($real.ok) {
                            $gaps = Get-CtgGraphScopeGaps $granted
                            $hint = if ($gaps.Count) {
                                "missing Graph permission(s): $($gaps -join ' || '). Consented in this tenant: [$(@($granted) -join ', ')]. Grant + admin-consent the missing ones (APPLICATION permissions) IN THIS TENANT."
                            } else {
                                "the app HAS the expected Graph permissions in this tenant ([$(@($granted) -join ', ')]). 'RequestDenied' here usually means a STALE TOKEN (runner connected before consent — restart the runner), recent consent not yet propagated, or the target object is protected (role-assignable/admin user). It is NOT a missing User.ReadWrite.All."
                            }
                        }
                        elseif ($granted.Count -gt 0) {
                            $gaps = Get-CtgGraphScopeGaps $granted
                            if ($gaps.Count) { $hint = "missing Graph permission(s): $($gaps -join ' || '). Grant + admin-consent (Application permissions on the app registration)." }
                        }
                        else { $hint = "$hint — note: couldn't read the app's consented permissions to confirm ($($real.reason))." }
                    } catch { }
                    $msg += " — $hint"
                }
                # An AD failure ("unwilling to process the request" = LDAP 53, "access is denied", a
                # referral, a constraint violation) names no DC and no reason. Append the ACTIONABLE
                # context so the operator sees the cause without hand-running DC tests: which DC the
                # connection targeted, whether that DC is WRITABLE (a read-only DC / RODC refuses EVERY
                # write — it returns exactly this error), the identity used, and any richer server-side AD
                # error message. Best-effort + read-only; never let the enrichment mask the real failure.
                if (($job.systemKey -in @('active-directory', 'directory-sync')) -and
                    ($msg -match 'unwilling to process|will not perform|[Aa]ccess is denied|referral was returned|constraint violation|not a valid')) {
                    try {
                        $bits = [System.Collections.Generic.List[string]]::new()
                        $adc = New-CtgAdConnection $creds
                        $srv = if ($adc.Server) { [string]$adc.Server } else { $env:COMPUTERNAME }
                        [void]$bits.Add("target DC: $srv")
                        $dc = Get-ADDomainController -Identity $srv -ErrorAction SilentlyContinue
                        if ($dc) {
                            [void]$bits.Add("writable: $(-not [bool]$dc.IsReadOnly)")
                            if ($dc.IsReadOnly) { [void]$bits.Add("*** READ-ONLY DC (RODC) — it refuses ALL writes; point the ad-dc secret's Server/DomainController at a WRITABLE DC ***") }
                        }
                        [void]$bits.Add("as: $(if ($adc.Credential) { $adc.Credential.UserName } else { "$env:USERDOMAIN\$env:USERNAME (agent SYSTEM identity)" })")
                        # ADException carries a richer server reason than .Message (survives remoting as a note property).
                        $adEx = $exObj
                        while ($adEx) {
                            foreach ($p in 'ServerErrorMessage', 'ExtendedErrorMessage') {
                                $pv = $adEx.PSObject.Properties[$p]
                                if ($pv -and $pv.Value) { [void]$bits.Add("${p}: $($pv.Value)") }
                            }
                            $adEx = $adEx.InnerException
                        }
                        if ($msg -match 'unwilling to process|will not perform') {
                            [void]$bits.Add("LDAP 53 usually = read-only/RODC target, RID pool exhausted, or the account can't create the object in the target OU — verify the target DC is writable and the ad-dc account can create in that OU")
                        }
                        $msg += " — [$($bits -join ' | ')]"
                    } catch { }
                }
                # Name the phase that failed ("while connecting to on-prem Exchange (…): Unauthorized")
                # so the operator sees WHAT broke, not just the bare provider message.
                $where = if ($script:Phase) { " while $($script:Phase)" } else { "" }
                # Scrub any brokered secret value the exception may have echoed before it's persisted.
                $err = Protect-CtgSecretsInText "[$($job.systemKey)]$($where): $msg" $creds -ExtraValues @([string](Get-CtgProp $job.config 'newPassword'), [string](Get-CtgProp $job.config 'initialPassword'))
                Write-Warning "job $($job.id) failed: $err"
                Write-CtgLog -Level ERROR -Message "job $($job.id) [$($job.systemKey)] $($job.action) FAILED: $err"
                $null = Invoke-AppApi POST "/api/jobs/$($job.id)/result" @{ agentId = $AgentId; status = 'failed'; error = $err }
            }
            finally {
                Clear-CtgInFlight                 # this job is accounted for — nothing to recover
                $global:CtgProgressJobId = $null  # don't let a stray post target a finished job
                # Leave nothing bound behind. These sessions are process-wide and this runner serves the
                # whole fleet, so a session this job leaves open is one the NEXT client's job can
                # silently inherit — which is how an Easterseals offboard came to authenticate against
                # Olympus Cosmetic's directory (UM0029840, AADSTS700016). Tearing down at the END of a
                # job is what makes "each client runs separately" true rather than merely usual.
                #
                # The connect cache MUST forget the key in the same breath (-IncludeSelf): a cached
                # "still connected" pointing at a session we just closed would make the next job skip
                # Connect entirely and run unconnected — the very poisoning the cache gate warns about.
                #
                # Runs for a FAILED job too (that's the point of a finally): a job that died mid-flight
                # is exactly the one most likely to leave a session bound to the wrong tenant.
                if ($handler -and $handler.ContainsKey('Disconnect')) {
                    try { & $handler.Disconnect }
                    catch { Write-CtgLog -Level WARN -Message "job $($job.id) [$($job.systemKey)]: disconnect failed — $($_.Exception.Message)" }
                    Clear-CtgConnectionSiblings -SystemKey $job.systemKey -IncludeSelf
                }
            }
        }

        # Separate, isolated lane: operator-requested connection/permission tests (cloud here on the
        # central runner; on-prem on the client agent). Never affects the job pipeline above.
        Invoke-CtgConnectionTests
        Invoke-CtgCloudGroupDiscovery
    }
    catch {
        Write-Warning "poll cycle error: $($_.Exception.Message)"
        Write-CtgLog -Level WARN -Message "poll cycle error: $($_.Exception.Message)"
    }
    # A self-heal installed a module this process must not import (assembly clash — see
    # Repair-CtgMissingModule). Restart NOW that the cycle's jobs are finished and their results are
    # posted: a fresh process imports the whole set cleanly at boot, which is the only safe order.
    # Deliberately here and not mid-job — restarting with a job in flight would strand it until the
    # app's lease reclaim, which is the very loop this fix exists to end.
    if ($script:CtgRestartReason) {
        $reason = $script:CtgRestartReason
        $script:CtgRestartReason = $null
        if (Test-CtgSelfHealRestartAllowed -Reason $reason) {
            Set-CtgSelfHealRestart -Reason $reason
            Write-CtgLog -Level WARN -Message "restarting: $reason"
            Restart-CtgRunner   # re-execs (or exits for the supervisor); never returns
        }
        else {
            # We already restarted for this and it did not take. Restarting again would only take the
            # runner down a second time — on a supervised host Invoke-CtgRelaunch exits and trusts the
            # service manager, and if that relaunch is not happening we simply stay down.
            Write-CtgLog -Level WARN -Message "NOT restarting again for: $reason — a restart was already tried within the last $($script:CtgSelfHealRestartWindowMinutes)m and the module is still missing. Install it on this host by hand; every other system keeps running meanwhile."
            Write-Warning "self-heal restart suppressed (already tried recently): $reason"
        }
    }
    # Drain: if this cycle claimed work, more may have just unblocked (dependency chains, an
    # operator's re-run) — poll again immediately and only sleep once the queue is empty.
    if (@($jobs).Count -eq 0) { Start-Sleep -Seconds $PollSeconds }
}
