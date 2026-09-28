#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Coretelligent.SharePoint — connection tests (Task 4) + Grant-CtgSharePointSiteAccess and
# Get-CtgOneDriveSiteUrl tests (Task 5). PnP.PowerShell isn't installed here (fail-soft — see
# $pnpAvail in Start-IamRunner.ps1), so we stub the PnP cmdlets before mocking them, same pattern as
# Coretelligent.Exchange.Tests.ps1 stubbing the EXO V3 cmdlets.

BeforeAll {
    function global:Connect-PnPOnline { [CmdletBinding()] param($Url, $ClientId, $Tenant, $CertificatePath, $CertificatePassword, $Thumbprint) }
    function global:Add-PnPSiteCollectionAdmin { [CmdletBinding()] param($Owners) }
    function global:Get-PnPSiteCollectionAdmin { [CmdletBinding()] param() }
    # Test-CtgDelegateUnambiguous (offboard-review Fix 5) calls Get-MgUser directly for the
    # display-name ambiguity check — stub it the same way Coretelligent.M365.Tests.ps1 does.
    function global:Get-MgUser { param($UserId, $Filter, [switch]$All, $ConsistencyLevel, $Property, $Top) }
    # Invoke-CtgSharePointOffboardGrant (offboard-review Fix 2) calls Resolve-CtgEntraUser,
    # Resolve-CtgM365Upn and Get-CtgUserDrive, which live in Coretelligent.M365 — import the .psm1
    # directly (not the .psd1) so the manifest's Microsoft.Graph RequiredModules (not installed here)
    # don't block the import; same pattern as Coretelligent.M365.Tests.ps1. All three are mocked below,
    # so none of their own Graph dependencies need to be real.
    Import-Module "$PSScriptRoot/../modules/Coretelligent.M365/Coretelligent.M365.psm1" -Force
    Import-Module "$PSScriptRoot/../modules/Coretelligent.SharePoint/Coretelligent.SharePoint.psd1" -Force
}

Describe 'Connect-CtgSharePointPnP' {
    BeforeEach { Mock -CommandName Connect-PnPOnline -ModuleName Coretelligent.SharePoint -MockWith { } }

    It 'connects app-only with a base64 cert (writes a temp pfx, passes ClientId+Tenant)' {
        Connect-CtgSharePointPnP -Url 'https://x.sharepoint.com/sites/s' -AppId 'app-id' -Tenant 'x.onmicrosoft.com' -CertificateBase64 ([Convert]::ToBase64String([byte[]](1..10)))
        Should -Invoke Connect-PnPOnline -ModuleName Coretelligent.SharePoint -Times 1 -ParameterFilter { $ClientId -eq 'app-id' -and $Tenant -eq 'x.onmicrosoft.com' -and $Url -eq 'https://x.sharepoint.com/sites/s' }
    }

    It 'throws a clear error when no cert form is provided' {
        { Connect-CtgSharePointPnP -Url 'https://x/s' -AppId 'a' -Tenant 't' } | Should -Throw
    }
}

Describe 'Grant-CtgSharePointSiteAccess' {
    BeforeEach {
        Mock -CommandName Connect-CtgSharePointPnP -ModuleName Coretelligent.SharePoint -MockWith { }
        Mock -CommandName Add-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -MockWith { }
        Mock -CommandName Get-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -MockWith { @() }
    }
    It 'adds the delegate as a site collection admin' {
        $r = Grant-CtgSharePointSiteAccess -SiteUrl 'https://x.sharepoint.com/sites/s' -Delegate 'amelia@x.com' -AppId a -Tenant t -CertificateBase64 'Yg=='
        Should -Invoke Add-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -Times 1
        $r | Should -Match 'granted amelia@x.com site-collection admin'
    }
    It 'is idempotent when already an admin' {
        Mock -CommandName Get-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -MockWith { @([pscustomobject]@{ Email = 'amelia@x.com' }) }
        $r = Grant-CtgSharePointSiteAccess -SiteUrl 'https://x/s' -Delegate 'amelia@x.com' -AppId a -Tenant t -CertificateBase64 'Yg=='
        Should -Invoke Add-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -Times 0
        $r | Should -Match 'already'
    }
    It 'does NOT treat a lookalike email (substring) as already-admin — grants the real delegate' {
        # bsmith@x.com contains "smith@x.com": a -like "*$Delegate*" match would wrongly call this
        # "already admin" and skip the grant entirely. Exact match must reject this and still add.
        Mock -CommandName Get-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -MockWith { @([pscustomobject]@{ Email = 'bsmith@x.com' }) }
        $r = Grant-CtgSharePointSiteAccess -SiteUrl 'https://x/s' -Delegate 'smith@x.com' -AppId a -Tenant t -CertificateBase64 'Yg=='
        Should -Invoke Add-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -Times 1
        $r | Should -Match 'granted smith@x.com site-collection admin'
    }
    It 'is idempotent on an exact-match email (still no false negative)' {
        Mock -CommandName Get-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -MockWith { @([pscustomobject]@{ Email = 'smith@x.com' }) }
        $r = Grant-CtgSharePointSiteAccess -SiteUrl 'https://x/s' -Delegate 'smith@x.com' -AppId a -Tenant t -CertificateBase64 'Yg=='
        Should -Invoke Add-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -Times 0
        $r | Should -Match 'already'
    }
    It 'matches a claims-format LoginName (i:0#.f|membership|user@x.com) when Email is empty' {
        Mock -CommandName Get-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -MockWith { @([pscustomobject]@{ Email = ''; LoginName = 'i:0#.f|membership|smith@x.com' }) }
        $r = Grant-CtgSharePointSiteAccess -SiteUrl 'https://x/s' -Delegate 'smith@x.com' -AppId a -Tenant t -CertificateBase64 'Yg=='
        Should -Invoke Add-PnPSiteCollectionAdmin -ModuleName Coretelligent.SharePoint -Times 0
        $r | Should -Match 'already'
    }
}

Describe 'Get-CtgOneDriveSiteUrl' {
    It 'strips the document-library path down to the /personal/<user> site root' {
        Get-CtgOneDriveSiteUrl 'https://x-my.sharepoint.com/personal/a_b_com/Documents/f' | Should -Be 'https://x-my.sharepoint.com/personal/a_b_com'
    }
    It 'leaves a bare site root unchanged' {
        Get-CtgOneDriveSiteUrl 'https://x-my.sharepoint.com/personal/a_b_com' | Should -Be 'https://x-my.sharepoint.com/personal/a_b_com'
    }
    It 'returns $null for a non-OneDrive URL' {
        Get-CtgOneDriveSiteUrl 'https://x.sharepoint.com/sites/s' | Should -BeNullOrEmpty
    }
    It 'returns $null for an empty URL' {
        Get-CtgOneDriveSiteUrl '' | Should -BeNullOrEmpty
    }
}

# offboard-review Fix 1 (SECURITY): Invoke-CtgM365Offboarding (Coretelligent.M365.psm1) returns
# Status='ok' having done NOTHING when the leaver's name is ambiguous (2+ matches), a near-miss (no
# exact match but candidates), or matches nobody at all — every one of those early returns omits
# UserId; only the real teardown path (past `$existing = ...`) sets it. This is the discriminator the
# m365 Offboard dispatch block in Start-IamRunner.ps1 gates the SharePoint hand-off on.
Describe 'Test-CtgOffboardResolved' {
    It 'is $false for $null' {
        Test-CtgOffboardResolved $null | Should -BeFalse
    }
    It 'is $false for the ambiguous-match early return (no UserId, has CandidateReason)' {
        $r = [pscustomobject]@{ System = 'm365'; Status = 'ok'; Upn = 'jgoodmiller@x.com'; Actions = @('WARN 2 users match...'); Candidates = @(); CandidateQuery = 'James Goodmiller'; CandidateReason = 'ambiguous'; Evidence = @{ Groups = @(); Devices = @() } }
        Test-CtgOffboardResolved $r | Should -BeFalse
    }
    It 'is $false for the no-match early return (no UserId, has CandidateReason)' {
        $r = [pscustomobject]@{ System = 'm365'; Status = 'ok'; Upn = ''; Actions = @('WARN no exact match...'); Candidates = @(); CandidateQuery = 'Parth Shah'; CandidateReason = 'no-match'; Evidence = @{ Groups = @(); Devices = @() } }
        Test-CtgOffboardResolved $r | Should -BeFalse
    }
    It 'is $false for the user-not-found early return (no UserId, no CandidateReason either)' {
        $r = [pscustomobject]@{ System = 'm365'; Status = 'ok'; Upn = ''; Actions = @('user not found (nobody) — nothing to offboard'); Evidence = @{ Groups = @(); Devices = @() } }
        Test-CtgOffboardResolved $r | Should -BeFalse
    }
    It 'is $false when UserId is present but blank' {
        $r = [pscustomobject]@{ System = 'm365'; Status = 'ok'; UserId = ''; Upn = ''; Actions = @() }
        Test-CtgOffboardResolved $r | Should -BeFalse
    }
    It 'is $true for a genuinely resolved-and-acted offboard' {
        $r = [pscustomobject]@{ System = 'm365'; Status = 'ok'; UserId = 'aaaa-bbbb'; Upn = 'jdoe@x.com'; Evidence = @{ Groups = @(); Devices = @(); MfaMethods = @() }; Manager = $null; RetryAfterMinutes = $null; Actions = @('blocked sign-in') }
        Test-CtgOffboardResolved $r | Should -BeTrue
    }
}

# offboard-review Fix 2: oneDriveGrantAccessTo may be a DISPLAY NAME (ServiceNow intake), which
# Add-PnPSiteCollectionAdmin -Owners cannot use — it needs an email/UPN. Invoke-CtgSharePointOffboardGrant
# must resolve it via Resolve-CtgEntraUser BEFORE calling Grant-CtgSharePointSiteAccess.
Describe 'Invoke-CtgSharePointOffboardGrant' {
    BeforeEach {
        Mock -CommandName Resolve-CtgEntraUser -ModuleName Coretelligent.SharePoint -MockWith { [pscustomobject]@{ Mail = 'amelia@x.com'; UserPrincipalName = 'amelia@x.com' } }
        Mock -CommandName Resolve-CtgM365Upn -ModuleName Coretelligent.SharePoint -MockWith { $null }
        Mock -CommandName Get-CtgUserDrive -ModuleName Coretelligent.SharePoint -MockWith { $null }
        # The hand-off no longer calls Grant-CtgSharePointSiteAccess in this process — every grant goes
        # to a child (see 'the PnP grants never run in the runner process'). Mock the seam instead and
        # record what it was handed, so these tests still assert the same thing: WHICH grants get planned.
        $script:PnpGrants = @()
        Mock -CommandName Invoke-CtgPnPGrantOutOfProcess -ModuleName Coretelligent.SharePoint -MockWith {
            $script:PnpGrants += @($Grants)
            @($Grants | ForEach-Object { "granted $($_.Delegate) site-collection admin on $($_.SiteUrl)" })
        }
    }

    It 'grants EVERY delegate when the ticket named several (FR #0000120)' {
        # FR #84 widened the case-requested delegate to a list, and this reader was missed: [string] on
        # an ARRAY joins with a space, so two delegates became one nonexistent person
        # ("Rachel Thompson Nicole Hayes") and the grant WARNed instead of running. UM0030521 is the
        # case — the mailbox side worked and this did not.
        Mock -CommandName Resolve-CtgEntraUser -ModuleName Coretelligent.SharePoint -MockWith {
            param($Identity)
            switch ($Identity) {
                'Rachel Thompson' { [pscustomobject]@{ Mail = 'rachel@x.com'; UserPrincipalName = 'rachel@x.com' } }
                'Nicole Hayes'    { [pscustomobject]@{ Mail = 'nicole@x.com'; UserPrincipalName = 'nicole@x.com' } }
                default           { $null }
            }
        }
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{}
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = @('Rachel Thompson', 'Nicole Hayes')
                                         sharePointDelegateSites = @('https://x.sharepoint.com/sites/finance') }
        }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app-id' -Tenant 'x.onmicrosoft.com' -CertArgs @{ CertificateBase64 = 'Yg==' }
        $joined = $actions -join '|'
        # BOTH are granted, and the space-joined phantom never appears.
        $joined | Should -Match 'rachel@x.com'
        $joined | Should -Match 'nicole@x.com'
        $joined | Should -Not -Match 'Rachel Thompson Nicole Hayes'
        @($script:PnpGrants).Count | Should -Be 2
    }

    It 'a single delegate still travels as a plain string (unchanged for the common case)' {
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{}
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = 'Amelia Jones'; sharePointDelegateSites = @('https://x.sharepoint.com/sites/finance') }
        }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app-id' -Tenant 'x.onmicrosoft.com' -CertArgs @{ CertificateBase64 = 'Yg==' }
        ($actions -join '|') | Should -Match 'amelia@x.com'
        @($script:PnpGrants).Count | Should -Be 1
    }

    It 'one unresolvable delegate does not cost the others their access' {
        # Per-delegate isolation, the same rule the mailbox and OneDrive-invite paths follow.
        Mock -CommandName Resolve-CtgEntraUser -ModuleName Coretelligent.SharePoint -MockWith {
            param($Identity)
            if ($Identity -eq 'Real Person') { [pscustomobject]@{ Mail = 'real@x.com'; UserPrincipalName = 'real@x.com' } } else { $null }
        }
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{}
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = @('Typo Name', 'Real Person')
                                         sharePointDelegateSites = @('https://x.sharepoint.com/sites/finance') }
        }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app-id' -Tenant 'x.onmicrosoft.com' -CertArgs @{ CertificateBase64 = 'Yg==' }
        $joined = $actions -join '|'
        $joined | Should -Match "delegate 'Typo Name' was not found"
        $joined | Should -Match 'real@x.com'
        @($script:PnpGrants).Count | Should -Be 1
    }

    It 'blanks and empty entries plan no grant at all' {
        $job = [pscustomobject]@{ payload = [pscustomobject]@{}; config = [pscustomobject]@{ oneDriveGrantAccessTo = @('', '   ') } }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'a' -Tenant 't' -CertArgs @{ CertificateBase64 = 'Yg==' }
        @($actions).Count | Should -Be 0
        @($script:PnpGrants).Count | Should -Be 0
    }

    It 'resolves a display-name delegate to an email BEFORE granting SharePoint site access' {
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{}
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = 'Amelia Jones'; sharePointDelegateSites = @('https://x.sharepoint.com/sites/finance') }
        }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app-id' -Tenant 'x.onmicrosoft.com' -CertArgs @{ CertificateBase64 = 'Yg==' }

        Should -Invoke Resolve-CtgEntraUser -ModuleName Coretelligent.SharePoint -Times 1 -ParameterFilter { $Identity -eq 'Amelia Jones' }
        @($script:PnpGrants | Where-Object { $_.Delegate -eq 'amelia@x.com' -and $_.SiteUrl -eq 'https://x.sharepoint.com/sites/finance' }).Count | Should -Be 1
        $actions | Should -Contain 'granted amelia@x.com site-collection admin on https://x.sharepoint.com/sites/finance'
    }

    It 'WARNs and skips — never hands PnP a bare display name — when the delegate cannot be resolved in Entra' {
        Mock -CommandName Resolve-CtgEntraUser -ModuleName Coretelligent.SharePoint -MockWith { $null }
        $job = [pscustomobject]@{ payload = [pscustomobject]@{}; config = [pscustomobject]@{ oneDriveGrantAccessTo = 'Nobody Here' } }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app-id' -Tenant 't' -CertArgs @{}

        @($script:PnpGrants).Count | Should -Be 0
        $actions | Should -Match "WARN.*Nobody Here.*not found"
    }

    It 'does nothing (and never resolves) when no delegate is configured' {
        $job = [pscustomobject]@{ payload = [pscustomobject]@{}; config = [pscustomobject]@{} }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app-id' -Tenant 't' -CertArgs @{}

        $actions.Count | Should -Be 0
        Should -Invoke Resolve-CtgEntraUser -ModuleName Coretelligent.SharePoint -Times 0
    }

    # offboard-review Fix 5 (SECURITY): Resolve-CtgEntraUser's own display-name lookup is `-Top 1` — an
    # ambiguous name (2+ "Chris Lee"s) would otherwise silently resolve to whichever ONE Graph returns,
    # who then gets FULL CONTROL of the leaver's OneDrive/SharePoint site. The SharePoint hand-off must
    # fail safe (skip + WARN) rather than grant off a guess.
    It 'fails safe — skips the grant and WARNs — when a display-name delegate matches 2+ Entra users' {
        Mock -CommandName Get-MgUser -ModuleName Coretelligent.SharePoint -MockWith {
            @([pscustomobject]@{ Id = 'u1'; DisplayName = 'Chris Lee' }, [pscustomobject]@{ Id = 'u2'; DisplayName = 'Chris Lee' })
        }
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{}
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = 'Chris Lee'; sharePointDelegateSites = @('https://x.sharepoint.com/sites/finance') }
        }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app-id' -Tenant 't' -CertArgs @{}

        Should -Invoke Get-MgUser -ModuleName Coretelligent.SharePoint -Times 1 -ParameterFilter { $Filter -match "displayName eq 'Chris Lee'" -and $Top -eq 2 }
        @($script:PnpGrants).Count | Should -Be 0
        $actions | Should -Match "WARN.*Chris Lee.*matches multiple users"
    }

    It 'proceeds without an ambiguity query when the delegate is already an email/UPN' {
        Mock -CommandName Get-MgUser -ModuleName Coretelligent.SharePoint -MockWith { throw 'ambiguity check should not run for an exact email/UPN identifier' }
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{}
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = 'amelia@x.com'; sharePointDelegateSites = @('https://x.sharepoint.com/sites/finance') }
        }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app-id' -Tenant 't' -CertArgs @{}

        Should -Invoke Get-MgUser -ModuleName Coretelligent.SharePoint -Times 0
        @($script:PnpGrants).Count | Should -Be 1
        $actions | Should -Contain 'granted amelia@x.com site-collection admin on https://x.sharepoint.com/sites/finance'
    }

    It 'proceeds when a display-name delegate matches exactly one Entra user' {
        Mock -CommandName Get-MgUser -ModuleName Coretelligent.SharePoint -MockWith { @([pscustomobject]@{ Id = 'u1'; DisplayName = 'Amelia Jones' }) }
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{}
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = 'Amelia Jones'; sharePointDelegateSites = @('https://x.sharepoint.com/sites/finance') }
        }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app-id' -Tenant 't' -CertArgs @{}

        @($script:PnpGrants).Count | Should -Be 1
        $actions | Should -Contain 'granted amelia@x.com site-collection admin on https://x.sharepoint.com/sites/finance'
    }

    It 'grants every configured site, and one failing site does not cost the others' {
        # Per-site failure now comes back from the CHILD as its own line rather than from a try/catch
        # around each in-process call, so the mock returns what the child would. The ERR -> WARN mapping
        # itself is covered directly in 'ConvertFrom-CtgPnPGrantOutput'.
        Mock -CommandName Invoke-CtgPnPGrantOutOfProcess -ModuleName Coretelligent.SharePoint -MockWith {
            $script:PnpGrants += @($Grants)
            @($Grants | ForEach-Object {
                if ($_.SiteUrl -like '*sites/bad') { "WARN could not grant $($_.Label): itemNotFound site not found" }
                else { "granted $($_.Delegate) site-collection admin on $($_.SiteUrl)" }
            })
        }
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{}
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = 'amelia@x.com'; sharePointDelegateSites = @('https://x.sharepoint.com/sites/good', 'https://x.sharepoint.com/sites/bad') }
        }
        $actions = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app-id' -Tenant 't' -CertArgs @{}

        @($script:PnpGrants).Count | Should -Be 2
        $actions | Should -Contain 'granted amelia@x.com site-collection admin on https://x.sharepoint.com/sites/good'
        ($actions | Where-Object { $_ -match 'sites/bad' }) | Should -Match 'WARN'
        ($actions | Where-Object { $_ -match 'sites/bad' }) | Should -Match 'itemNotFound'
    }
}

# Fix 1's dispatch-level wiring: Start-IamRunner.ps1 has a mandatory param block and a main polling
# loop, so it cannot be dot-sourced for Pester (see ConnectionCache.Tests.ps1's header comment for the
# same constraint) — assert the wiring textually instead, same technique that file already uses.
Describe 'm365 Offboard dispatch — SharePoint hand-off wiring' {
    BeforeAll {
        $script:Runner = Get-Content "$PSScriptRoot/../Start-IamRunner.ps1" -Raw
        $m = [regex]::Match($script:Runner, "Offboard\s*=\s*\{.*?\n\s*\}\s*\n\s*Change\s*=", 'Singleline')
        $m.Success | Should -BeTrue -Because 'the m365 Offboard dispatch scriptblock must be found (ends right before Change =)'
        $script:OffboardBlock = $m.Value
    }
    It 'checks Test-CtgOffboardResolved before calling Invoke-CtgSharePointOffboardGrant' {
        $iResolved = $script:OffboardBlock.IndexOf('Test-CtgOffboardResolved')
        $iGrant = $script:OffboardBlock.IndexOf('Invoke-CtgSharePointOffboardGrant')
        $iResolved | Should -BeGreaterThan -1
        $iGrant | Should -BeGreaterThan -1
        $iResolved | Should -BeLessThan $iGrant
    }
    It 'never calls Grant-CtgSharePointSiteAccess directly — only through Invoke-CtgSharePointOffboardGrant, which resolves the delegate first' {
        $script:OffboardBlock | Should -Not -Match 'Grant-CtgSharePointSiteAccess'
    }
}

# PRODUCTION INCIDENT 2026-09-23..25: the central runner appeared to "keep crashing" after 1.127.0.
# It was not crashing at startup. PnP.PowerShell ships its own Microsoft.Identity.Client,
# Microsoft.IdentityModel.* and System.IdentityModel.Tokens.Jwt; Microsoft.Graph is already loaded in
# the runner with its own copies. Start-IamRunner.ps1's $script:CtgAssemblySharingGroups comment says
# what follows: "the second import binds an incompatible copy and the FIRST module's calls stop
# returning". Graph went silent, the next m365 job wedged, and the stall watchdog restarted the process
# 600s later — which is why runner.log showed "abandoned job ... from the previous process" and no error.
#
# FR #116 is what made it reachable: before it, Install-CtgPnPModule failed in-process on that host, so
# $pnpAvail was false and the hand-off never ran. Fixing the install made the hand-off run, and calling
# a PnP cmdlet auto-loads the assemblies.
#
# The invariant these tests hold: the RUNNER PROCESS never calls a PnP cmdlet. All Graph-side resolution
# stays in-process (it needs Graph, which works there); only the grants cross into a child.
Describe 'the PnP grants never run in the runner process' {
    BeforeAll {
        $script:SpSrc = Get-Content "$PSScriptRoot/../modules/Coretelligent.SharePoint/Coretelligent.SharePoint.psm1" -Raw
        $script:RunnerSrc = Get-Content "$PSScriptRoot/../Start-IamRunner.ps1" -Raw
    }

    It 'routes every grant through the out-of-process seam, not Grant-CtgSharePointSiteAccess directly' {
        # The hand-off used to call the granting function inline, inside the delegate loop.
        $fn = [regex]::Match($script:SpSrc, '(?ms)^function Invoke-CtgSharePointOffboardGrant \{.*?^\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Not -Match 'Grant-CtgSharePointSiteAccess'
        $fn | Should -Match '\$GrantInvoker'
    }

    It 'spawns a child pwsh for the grants' {
        # Asserted against the whole module source, not a function-body regex: the child script is a
        # here-string whose own closing brace sits in column 0, so '.*?^\}' stops inside it and silently
        # matches a fragment. That is a trap worth not re-setting for the next person.
        $script:SpSrc | Should -Match '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \$childPath'
        $script:SpSrc | Should -Match 'Grant-CtgSharePointSiteAccess -SiteUrl \$g\.SiteUrl'   # the CHILD calls it
    }

    It 'never puts the certificate on the child command line' {
        # A process list is world-readable; the pfx and its password are not. They go through a file the
        # child deletes before it does anything else.
        $script:SpSrc | Should -Not -Match 'ArgumentList.*CertificateBase64'
        $script:SpSrc | Should -Match 'Remove-Item -LiteralPath \$PayloadPath -Force'
    }

    It 'always removes the temp directory holding the certificate' {
        # .NET, not Remove-Item, which a dry run's WhatIf would skip, leaving the certificate behind.
        $script:SpSrc | Should -Match 'finally \{ try \{ \[System\.IO\.Directory\]::Delete\(\$dir, \$true\) \}'
    }

    It 'lists PnP.PowerShell in the assembly-sharing guard' {
        # The guard existed and PnP was not in it. It only gates the self-heal installer, so it is a
        # backstop rather than the fix — but a module that wedges Graph must be named there.
        $grp = [regex]::Match($script:RunnerSrc, '(?ms)\$script:CtgAssemblySharingGroups = @\{.*?\n\}').Value
        $grp | Should -Match "'PnP\.PowerShell'\s*=\s*'entra-auth-stack'"
    }
}

Describe 'Invoke-CtgSharePointOffboardGrant hands the right grants to the seam' {
    BeforeEach {
        Mock Resolve-CtgM365Upn -ModuleName Coretelligent.SharePoint -MockWith { 'leaver@x.com' }
        Mock Get-CtgUserDrive -ModuleName Coretelligent.SharePoint -MockWith { [pscustomobject]@{ Id='d1'; WebUrl='https://t-my.sharepoint.com/personal/leaver_x_com/Documents' } }
        Mock Resolve-CtgEntraUser -ModuleName Coretelligent.SharePoint -MockWith { [pscustomobject]@{ Mail='amelia@x.com'; UserPrincipalName='amelia@x.com' } }
        Mock Test-CtgDelegateUnambiguous -ModuleName Coretelligent.SharePoint -MockWith { $true }
    }

    It 'collects the OneDrive site and every configured SharePoint site into ONE child call' {
        # One process start for the whole hand-off, not one per delegate-site pair.
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{ userPrincipalName = 'leaver@x.com' }
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = 'amelia@x.com'; sharePointDelegateSites = @('https://t.sharepoint.com/sites/finance') }
        }
        $script:calls = 0
        $captured = $null
        $acts = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app' -Tenant 't' -GrantInvoker {
            param($g, $a, $t, $c) $script:calls++; $script:captured = $g; @("granted $($g.Count) sites")
        }
        $script:calls | Should -Be 1
        @($script:captured).Count | Should -Be 2
        @($script:captured)[0].SiteUrl | Should -Be 'https://t-my.sharepoint.com/personal/leaver_x_com'
        @($script:captured)[1].SiteUrl | Should -Be 'https://t.sharepoint.com/sites/finance'
        ($acts -join ' ') | Should -Match 'granted 2 sites'
    }

    It 'WARNs instead of throwing when the child itself fails' {
        # A SharePoint problem must never fail the offboard — the containment work already ran.
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{ userPrincipalName = 'leaver@x.com' }
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = 'amelia@x.com' }
        }
        $acts = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app' -Tenant 't' -GrantInvoker { throw 'pwsh not found' }
        ($acts -join ' ') | Should -Match 'WARN the SharePoint/OneDrive grants did not run: pwsh not found'
    }

    It 'does not start a child at all when no delegate resolves' {
        $job = [pscustomobject]@{
            payload = [pscustomobject]@{ userPrincipalName = 'leaver@x.com' }
            config  = [pscustomobject]@{ oneDriveGrantAccessTo = 'nobody@x.com' }
        }
        Mock Resolve-CtgEntraUser -ModuleName Coretelligent.SharePoint -MockWith { $null }
        $script:calls = 0
        $acts = Invoke-CtgSharePointOffboardGrant -Job $job -AppId 'app' -Tenant 't' -GrantInvoker { param($g,$a,$t,$c) $script:calls++; @() }
        $script:calls | Should -Be 0
        ($acts -join ' ') | Should -Match 'was not found in Entra'
    }
}

# Where a failed grant is either reported or lost. Tested directly because the spawn around it cannot
# be exercised without PnP and a live tenant, and this is the part that decides what the case says.
Describe 'ConvertFrom-CtgPnPGrantOutput' {
    It 'passes an OK line through as the action it is' {
        $r = ConvertFrom-CtgPnPGrantOutput -Lines @("OK`tgranted amelia@x.com site-collection admin on https://x/s")
        $r | Should -Contain 'granted amelia@x.com site-collection admin on https://x/s'
    }

    It 'turns an ERR line into a WARN naming the grant and the reason' {
        $r = ConvertFrom-CtgPnPGrantOutput -Lines @("ERR`tamelia@x.com on the leaver's OneDrive`taccess denied")
        ($r -join ' ') | Should -Match "WARN could not grant amelia@x.com on the leaver's OneDrive: access denied"
    }

    It 'reports BOTH when one grant worked and another did not' {
        $r = ConvertFrom-CtgPnPGrantOutput -Lines @("OK`tgranted a on s1", "ERR`tb on s2`tboom")
        @($r).Count | Should -Be 2
        ($r -join '|') | Should -Match 'granted a on s1'
        ($r -join '|') | Should -Match 'WARN could not grant b on s2: boom'
    }

    It 'never reports silence as success' {
        # The failure this whole file keeps re-learning: a helper that said nothing must not read as
        # "nothing went wrong". Exit code and whatever it did say are carried into the warning.
        $r = ConvertFrom-CtgPnPGrantOutput -Lines @('Import-Module: PnP.PowerShell not found') -ExitCode 1
        @($r).Count | Should -Be 1
        @($r)[0] | Should -Match 'WARN the SharePoint grant helper exited \(1\) without reporting any grant'
        @($r)[0] | Should -Match 'PnP.PowerShell not found'
    }

    It 'says so when the helper produced no output at all' {
        $r = ConvertFrom-CtgPnPGrantOutput -Lines @() -ExitCode 0
        @($r)[0] | Should -Match 'produced no output'
    }

    It 'tolerates an ERR line with no reason rather than emitting a bare colon' {
        $r = ConvertFrom-CtgPnPGrantOutput -Lines @("ERR`tsome grant")
        @($r)[0] | Should -Match 'WARN could not grant some grant: no reason given'
    }
}

# A dry run sets $WhatIfPreference. The grant helper's file work used the cmdlets, which honour it, so
# the child never got its request and every dry-run offboard naming a delegate came back with a WARN.
# And the child is its own process: the dry run has to be handed to it, or a fixed helper would make a
# REAL site-collection-admin grant during a dry run. These start real children, with a stand-in module
# for the grant (PnP isn't on a test host).
Describe 'Invoke-CtgPnPGrantOutOfProcess under a dry run' {
    BeforeAll {
        $script:DryDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ctg-pnp-drytest-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DryDir | Out-Null
        $script:FakeGrant = Join-Path $script:DryDir 'fake.psm1'
        Set-Content -LiteralPath $script:FakeGrant -Encoding utf8 -Value @'
function Grant-CtgSharePointSiteAccess {
    [CmdletBinding(SupportsShouldProcess)]
    param($SiteUrl, $Delegate, $AppId, $Tenant, $CertificateBase64, $CertificatePassword, $CertificateThumbprint)
    if ($CertificateBase64 -ne 'U0VDUkVU') { throw 'certificate did not arrive' }
    if ($PSCmdlet.ShouldProcess($SiteUrl, "Add $Delegate as site-collection admin")) { return "granted $Delegate site-collection admin on $SiteUrl" }
    "would grant $Delegate site-collection admin on $SiteUrl (WhatIf)"
}
'@
        $script:Grants = @(@{ SiteUrl = 'https://contoso-my.sharepoint.com/personal/leaver'; Delegate = 'boss@contoso.com'; Label = "boss@contoso.com SharePoint access to the leaver's OneDrive site" })
        $script:Leftovers = { @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'ctg-pnp-*' -Directory | Where-Object Name -NotLike 'ctg-pnp-drytest-*').Count }
    }
    AfterAll { Remove-Item -LiteralPath $script:DryDir -Recurse -Force -ErrorAction SilentlyContinue }

    # The way the runner sets a dry run: the GLOBAL preference (Invoke-JobWithValidation).
    It 'a dry run reaches the child and PREVIEWS the grant, instead of warning (and never makes it)' {
        $global:WhatIfPreference = $true
        try { $r = Invoke-CtgPnPGrantOutOfProcess -Grants $script:Grants -AppId app -Tenant contoso.onmicrosoft.com -CertArgs @{ CertificateBase64 = 'U0VDUkVU' } -ModulePath $script:FakeGrant }
        finally { $global:WhatIfPreference = $false }
        $r | Should -Be @('would grant boss@contoso.com site-collection admin on https://contoso-my.sharepoint.com/personal/leaver (WhatIf)')
    }

    It 'a live run still grants' {
        Invoke-CtgPnPGrantOutOfProcess -Grants $script:Grants -AppId app -Tenant contoso.onmicrosoft.com -CertArgs @{ CertificateBase64 = 'U0VDUkVU' } -ModulePath $script:FakeGrant |
            Should -Be @('granted boss@contoso.com site-collection admin on https://contoso-my.sharepoint.com/personal/leaver')
    }

    It 'a dry run leaves no request (certificate) directory behind' {
        $before = & $script:Leftovers
        $global:WhatIfPreference = $true
        try { $null = Invoke-CtgPnPGrantOutOfProcess -Grants $script:Grants -AppId app -Tenant contoso.onmicrosoft.com -CertArgs @{ CertificateBase64 = 'U0VDUkVU' } -ModulePath $script:FakeGrant }
        finally { $global:WhatIfPreference = $false }
        & $script:Leftovers | Should -Be $before
    }
}
