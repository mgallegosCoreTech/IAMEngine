#Requires -Modules Pester

BeforeAll {
    # Stand-ins so the Cs cmdlets exist to be mocked (MicrosoftTeams isn't installed on a test host).
    function global:Get-CsOnlineUser { param($Identity) }
    function global:Get-CsPhoneNumberAssignment { param($AssignedPstnTargetId, $TelephoneNumber, $NumberType, $PstnAssignmentStatus, $CapabilitiesContain, $Top) }
    function global:Set-CsPhoneNumberAssignment { param($Identity, $PhoneNumber, $PhoneNumberType, $LocationId) }
    function global:Remove-CsPhoneNumberAssignment { param($Identity, [switch]$RemoveAll) }
    Import-Module "$PSScriptRoot/../modules/Coretelligent.Teams/Coretelligent.Teams.psd1" -Force

    $script:user = [pscustomobject]@{ UserPrincipalName = 'jdoe@61commodities.com' }
    $script:licensed = [pscustomobject]@{ UserPrincipalName = 'jdoe@61commodities.com'; FeatureTypes = @('Teams', 'PhoneSystem', 'CallingPlan') }
    $script:free = { param($tn, $loc = $null) [pscustomobject]@{ TelephoneNumber = $tn; NumberType = 'CallingPlan'; PstnAssignmentStatus = 'Unassigned'; ActivationState = 'Activated'; AssignedPstnTargetId = $null; LocationId = $loc } }
}

AfterAll {
    Remove-Item function:Get-CsOnlineUser, function:Get-CsPhoneNumberAssignment, function:Set-CsPhoneNumberAssignment, function:Remove-CsPhoneNumberAssignment -ErrorAction SilentlyContinue
}

Describe 'Teams number helpers' {
    It 'normalises what people type to E.164' {
        ConvertTo-CtgTeamsE164 '(203) 555-0123' | Should -Be '+12035550123'
        ConvertTo-CtgTeamsE164 '1-203-555-0123' | Should -Be '+12035550123'
        ConvertTo-CtgTeamsE164 '+65 6123 4567' | Should -Be '+6561234567'
        ConvertTo-CtgTeamsE164 'tel:+12035550123;ext=12' | Should -Be '+12035550123'
        ConvertTo-CtgTeamsE164 '555-0123' | Should -BeNullOrEmpty
        ConvertTo-CtgTeamsE164 '' | Should -BeNullOrEmpty
    }

    It 'turns an office area code into the prefix a number must start with' {
        ConvertTo-CtgTeamsAreaPrefix '203' | Should -Be '+1203'
        ConvertTo-CtgTeamsAreaPrefix '346' | Should -Be '+1346'
        ConvertTo-CtgTeamsAreaPrefix '+65' | Should -Be '+65'
        ConvertTo-CtgTeamsAreaPrefix '+44 20' | Should -Be '+4420'
        ConvertTo-CtgTeamsAreaPrefix '1203' | Should -Be '+1203'
        ConvertTo-CtgTeamsAreaPrefix $null | Should -BeNullOrEmpty
    }

    It 'is voice-ready only when Teams lists Phone System and, for a Calling Plan number, a Calling Plan' {
        (Test-CtgTeamsVoiceReady -OnlineUser $script:licensed).Ready | Should -BeTrue
        $noPlan = Test-CtgTeamsVoiceReady -OnlineUser ([pscustomobject]@{ FeatureTypes = @('Teams', 'PhoneSystem') })
        $noPlan.Ready | Should -BeFalse
        $noPlan.Missing | Should -Be @('CallingPlan')
        (Test-CtgTeamsVoiceReady -OnlineUser ([pscustomobject]@{ FeatureTypes = @('PhoneSystem') }) -NumberType 'OperatorConnect').Ready | Should -BeTrue
        (Test-CtgTeamsVoiceReady -OnlineUser $null).Ready | Should -BeFalse
    }

    It 'picks free, activated, unassigned numbers of the right type and prefix, lowest first' {
        $pool = @(
            (& $script:free '+12035550199'), (& $script:free '+12035550101'), (& $script:free '+13465550100'),
            [pscustomobject]@{ TelephoneNumber = '+12035550100'; NumberType = 'CallingPlan'; PstnAssignmentStatus = 'UserAssigned'; AssignedPstnTargetId = 'x@y' },
            [pscustomobject]@{ TelephoneNumber = '+12035550102'; NumberType = 'CallingPlan'; PstnAssignmentStatus = 'Unassigned'; ActivationState = 'AssignmentPending' },
            [pscustomobject]@{ TelephoneNumber = '+12035550103'; NumberType = 'DirectRouting'; PstnAssignmentStatus = 'Unassigned' }
        )
        @(Select-CtgTeamsFreeNumbers -Numbers $pool -Prefix '+1203' | ForEach-Object TelephoneNumber) | Should -Be @('+12035550101', '+12035550199')
        @(Select-CtgTeamsFreeNumbers -Numbers $pool -Prefix '+65').Count | Should -Be 0
    }
}

Describe 'Invoke-CtgTeamsOnboarding' {
    BeforeEach {
        Mock Get-CsOnlineUser -ModuleName Coretelligent.Teams -MockWith { $script:licensed }
        Mock Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { }
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith {
            if ($AssignedPstnTargetId) { return @() }
            @((& $script:free '+13465550100'), (& $script:free '+12035550142' 'loc-stamford'), (& $script:free '+12035550120'))
        }
    }

    It 'assigns the lowest free number matching the office area code' {
        $r = Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '203'; office = 'Stamford' })
        $r.PhoneNumber | Should -Be '+12035550120'
        $r.RetryAfterMinutes | Should -BeNullOrEmpty
        Should -Invoke Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'jdoe@61commodities.com' -and $PhoneNumber -eq '+12035550120' -and $PhoneNumberType -eq 'CallingPlan'
        }
        ($r.Actions -join ' ') | Should -Match 'assigned Teams number \+12035550120 to jdoe@61commodities.com'
    }

    It "passes the number's own emergency location, or the configured one over it" {
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { if ($AssignedPstnTargetId) { @() } else { @(& $script:free '+12035550142' 'loc-number') } }
        $null = Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '203' })
        Should -Invoke Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 1 -Exactly -ParameterFilter { $LocationId -eq 'loc-number' }
        $null = Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '203'; emergencyLocationId = 'loc-config' })
        Should -Invoke Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 1 -Exactly -ParameterFilter { $LocationId -eq 'loc-config' }
    }

    It 'uses the number entered on the case instead of the pool' {
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith {
            if ($AssignedPstnTargetId) { return @() }
            if ($TelephoneNumber -eq '+12035550777') { return @(& $script:free '+12035550777') }
            throw 'the pool should not be read'
        }
        $r = Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '203'; phoneNumber = '(203) 555-0777' })
        $r.PhoneNumber | Should -Be '+12035550777'
        Should -Invoke Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 1 -Exactly -ParameterFilter { $PhoneNumber -eq '+12035550777' }
    }

    It 'refuses a case number that is already assigned to someone else, or not in the tenant' {
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith {
            if ($AssignedPstnTargetId) { return @() }
            if ($TelephoneNumber -eq '+12035550777') { return @([pscustomobject]@{ TelephoneNumber = '+12035550777'; AssignedPstnTargetId = 'someone@61commodities.com' }) }
            @()
        }
        { Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ phoneNumber = '+12035550777' }) } | Should -Throw '*already assigned (to someone@61commodities.com)*'
        { Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ phoneNumber = '+12035550888' }) } | Should -Throw "*isn't in this tenant*"
        Should -Invoke Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 0 -Exactly
    }

    It 'waits (retry) until Teams sees the Phone System and Calling Plan licence' {
        Mock Get-CsOnlineUser -ModuleName Coretelligent.Teams -MockWith { [pscustomobject]@{ FeatureTypes = @('Teams') } }
        $r = Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '203' })
        $r.RetryAfterMinutes | Should -Be 15
        $r.PhoneNumber | Should -BeNullOrEmpty
        ($r.Actions -join ' ') | Should -Match 'waiting for Teams to pick up the licence — missing: PhoneSystem, CallingPlan'
        Should -Invoke Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 0 -Exactly
    }

    It 'waits (retry, and says so) when no free number has the area code' {
        $r = Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '+65' })
        $r.RetryAfterMinutes | Should -Be 60
        ($r.Actions -join ' ') | Should -Match 'WARN no free CallingPlan number starting \+65'
        Should -Invoke Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 0 -Exactly
    }

    It 'fails with the fix when the office has no area code and no number was entered' {
        { Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ office = 'Denver' }) } | Should -Throw "*no area code for this user's office ('Denver')*phoneByAreaCode*"
    }

    It 'is idempotent: a user who already has a number keeps it' {
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { if ($AssignedPstnTargetId) { @([pscustomobject]@{ TelephoneNumber = '+12035550100' }) } else { throw 'the pool should not be read' } }
        $r = Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '203' })
        $r.PhoneNumber | Should -Be '+12035550100'
        ($r.Actions -join ' ') | Should -Match 'already has Teams number \+12035550100 — no change'
        Should -Invoke Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 0 -Exactly
    }

    It 'does not replace an existing number with a different one entered on the case' {
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { if ($AssignedPstnTargetId) { @([pscustomobject]@{ TelephoneNumber = '+12035550100' }) } else { @() } }
        $r = Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ phoneNumber = '+12035550777' })
        ($r.Actions -join ' ') | Should -Match 'WARN .*already has Teams number \+12035550100; the case asks for \+12035550777 — not changed'
        Should -Invoke Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 0 -Exactly
    }

    It 'moves on to the next free number when another onboarding took the first one' {
        Mock Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { if ($PhoneNumber -eq '+12035550120') { throw 'The number is already assigned' } }
        $r = Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '203' })
        $r.PhoneNumber | Should -Be '+12035550142'
        ($r.Actions -join ' ') | Should -Match 'WARN could not assign \+12035550120'
    }

    It 'names the emergency-location fix when the assignment is refused for a missing location' {
        Mock Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { throw 'An emergency location is required for this number' }
        { Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '203' }) } | Should -Throw '*emergencyLocationByOffice*'
    }

    It 'under WhatIf, previews and assigns nothing' {
        $r = Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '203' }) -WhatIf
        ($r.Actions -join ' ') | Should -Match 'would assign Teams number \+12035550120 to jdoe@61commodities.com \(WhatIf\)'
        Should -Invoke Set-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 0 -Exactly
    }

    It 'refuses a number type it cannot assign yet' {
        { Invoke-CtgTeamsOnboarding -User $script:user -Config ([pscustomobject]@{ areaCode = '203'; numberType = 'DirectRouting' }) } | Should -Throw "*isn't supported yet*"
    }
}

Describe 'Invoke-CtgTeamsOffboarding' {
    BeforeEach { Mock Remove-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { } }

    It 'releases the leaver''s number and records which one' {
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { @([pscustomobject]@{ TelephoneNumber = '+12035550100' }) }
        $r = Invoke-CtgTeamsOffboarding -User ([pscustomobject]@{ userToOffboard = 'leaver@61commodities.com' }) -Config $null
        @($r.ReleasedNumbers) | Should -Be @('+12035550100')
        Should -Invoke Remove-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 1 -Exactly -ParameterFilter { $Identity -eq 'leaver@61commodities.com' -and $RemoveAll }
        ($r.Actions -join ' ') | Should -Match 'released Teams number \+12035550100 from leaver@61commodities.com'
    }

    It 'is a no-op for a leaver with no number' {
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { @() }
        $r = Invoke-CtgTeamsOffboarding -User $script:user -Config $null
        @($r.ReleasedNumbers).Count | Should -Be 0
        Should -Invoke Remove-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 0 -Exactly
    }

    It 'under WhatIf, previews and releases nothing' {
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { @([pscustomobject]@{ TelephoneNumber = '+12035550100' }) }
        $r = Invoke-CtgTeamsOffboarding -User $script:user -Config $null -WhatIf
        ($r.Actions -join ' ') | Should -Match 'would release Teams number \+12035550100'
        Should -Invoke Remove-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -Times 0 -Exactly
    }
}

Describe 'Confirm-CtgTeams' {
    It 'onboard passes when the user has a number (the one entered on the case, when there is one)' {
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { @([pscustomobject]@{ TelephoneNumber = '+12035550100' }) }
        (Confirm-CtgTeams -User $script:user -Config $null -Action onboard).ok | Should -BeTrue
        (Confirm-CtgTeams -User $script:user -Config ([pscustomobject]@{ phoneNumber = '203-555-0100' }) -Action onboard).ok | Should -BeTrue
        (Confirm-CtgTeams -User $script:user -Config ([pscustomobject]@{ phoneNumber = '203-555-0777' }) -Action onboard).ok | Should -BeFalse
    }
    It 'offboard passes only when no number is left' {
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { @() }
        (Confirm-CtgTeams -User $script:user -Config $null -Action offboard).ok | Should -BeTrue
        Mock Get-CsPhoneNumberAssignment -ModuleName Coretelligent.Teams -MockWith { @([pscustomobject]@{ TelephoneNumber = '+12035550100' }) }
        (Confirm-CtgTeams -User $script:user -Config $null -Action offboard).ok | Should -BeFalse
    }
}

Describe 'ConvertFrom-CtgTeamsChildOutput' {
    It 'returns the result line, throws the failure line, and never reads silence as success' {
        $enc = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
        (ConvertFrom-CtgTeamsChildOutput -Lines @('progress', ("RESULT`t" + (& $enc '{"PhoneNumber":"+12035550100"}')))).PhoneNumber | Should -Be '+12035550100'
        { ConvertFrom-CtgTeamsChildOutput -Lines @("FAIL`t" + (& $enc 'Teams said no')) } | Should -Throw 'Teams said no'
        { ConvertFrom-CtgTeamsChildOutput -Lines @('Import-Module: MicrosoftTeams not found') -ExitCode 1 } | Should -Throw '*exited (1) without a result: Import-Module: MicrosoftTeams not found*'
        { ConvertFrom-CtgTeamsChildOutput -Lines @() } | Should -Throw '*printed nothing*'
    }
}

# Real child processes, with a stand-in module in place of MicrosoftTeams (no tenant here). These are
# the part that matters: the request actually reaches the child, a dry run stays a dry run across the
# process boundary, and the certificate never outlives the call.
Describe 'Invoke-CtgTeamsOutOfProcess' {
    BeforeAll {
        $script:TDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ctg-teamstest-" + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:TDir)
        $script:FakeTeams = Join-Path $script:TDir 'FakeTeams.psm1'
        Set-Content -LiteralPath $script:FakeTeams -Encoding utf8 -Value @'
function Connect-MicrosoftTeams { param($TenantId, $ApplicationId, $Certificate)
    if (-not $Certificate -or -not $Certificate.HasPrivateKey) { throw 'no usable certificate reached Connect-MicrosoftTeams' }
    if ($ApplicationId -ne 'app-1' -or $TenantId -ne 'tenant-1') { throw "wrong app/tenant: $ApplicationId / $TenantId" } }
function Disconnect-MicrosoftTeams { }
function Get-CsOnlineUser { param($Identity) [pscustomobject]@{ FeatureTypes = @('PhoneSystem', 'CallingPlan') } }
function Get-CsPhoneNumberAssignment { param($AssignedPstnTargetId, $TelephoneNumber, $NumberType, $PstnAssignmentStatus, $CapabilitiesContain, $Top)
    if ($AssignedPstnTargetId -eq 'leaver@x.com') { return @([pscustomobject]@{ TelephoneNumber = '+12035550100' }) }
    if ($AssignedPstnTargetId) { return @() }
    if ($AssignedPstnTargetId -eq $null -and $env:CTG_FAKE_SLOW) { Start-Sleep -Seconds 30 }
    @([pscustomobject]@{ TelephoneNumber = '+12035550120'; NumberType = 'CallingPlan'; PstnAssignmentStatus = 'Unassigned'; ActivationState = 'Activated' }) }
function Set-CsPhoneNumberAssignment { param($Identity, $PhoneNumber, $PhoneNumberType, $LocationId) if ($env:CTG_FAKE_REFUSE) { throw 'Teams refused the assignment' } }
function Remove-CsPhoneNumberAssignment { param($Identity, [switch]$RemoveAll) }
'@
        # A throwaway self-signed certificate, exported the way the m365-admin secret carries it.
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=ctg-teams-test', $rsa, 'SHA256', [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $c = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        $script:CertArgs = @{ CertificateBase64 = [Convert]::ToBase64String($c.Export('Pfx', 'pw')); CertificatePassword = 'pw' }
        $script:Common = @{ AppId = 'app-1'; Tenant = 'tenant-1'; CertArgs = $script:CertArgs; TeamsModulePath = $script:FakeTeams }
        $script:Leftovers = { @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'ctg-teams-*' -Directory | Where-Object Name -NotLike 'ctg-teamstest-*').Count }
    }
    AfterAll { Remove-Item -LiteralPath $script:TDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'assigns a number in the child and returns it' {
        $r = Invoke-CtgTeamsOutOfProcess -Action onboard -User $script:user -Config ([pscustomobject]@{ areaCode = '203' }) @script:Common
        $r.PhoneNumber | Should -Be '+12035550120'
        ($r.Actions -join ' ') | Should -Match 'assigned Teams number \+12035550120'
    }

    It 'releases a number in the child and returns which one' {
        $r = Invoke-CtgTeamsOutOfProcess -Action offboard -User ([pscustomobject]@{ userToOffboard = 'leaver@x.com' }) -Config $null @script:Common
        @($r.ReleasedNumbers) | Should -Be @('+12035550100')
    }

    It 'a dry run (the global preference, as the runner sets it) previews in the child and changes nothing' {
        $global:WhatIfPreference = $true
        try { $r = Invoke-CtgTeamsOutOfProcess -Action onboard -User $script:user -Config ([pscustomobject]@{ areaCode = '203' }) @script:Common }
        finally { $global:WhatIfPreference = $false }
        ($r.Actions -join ' ') | Should -Match 'would assign Teams number \+12035550120 .*\(WhatIf\)'
        ($r.Actions -join ' ') | Should -Not -Match '(^| )assigned Teams number'
    }

    It "reports the child's failure as the step's error" {
        $env:CTG_FAKE_REFUSE = '1'
        try { { Invoke-CtgTeamsOutOfProcess -Action onboard -User $script:user -Config ([pscustomobject]@{ areaCode = '203' }) @script:Common } | Should -Throw '*Teams refused the assignment*' }
        finally { Remove-Item env:CTG_FAKE_REFUSE }
    }

    It 'stops a child that runs past the timeout' {
        $env:CTG_FAKE_SLOW = '1'
        try { { Invoke-CtgTeamsOutOfProcess -Action onboard -User $script:user -Config ([pscustomobject]@{ areaCode = '203' }) -TimeoutSeconds 5 @script:Common } | Should -Throw "*didn't finish within 5 seconds*" }
        finally { Remove-Item env:CTG_FAKE_SLOW }
    }

    It 'leaves no request (certificate) directory behind, dry run or not' {
        $before = & $script:Leftovers
        $null = Invoke-CtgTeamsOutOfProcess -Action onboard -User $script:user -Config ([pscustomobject]@{ areaCode = '203' }) @script:Common
        $global:WhatIfPreference = $true
        try { $null = Invoke-CtgTeamsOutOfProcess -Action onboard -User $script:user -Config ([pscustomobject]@{ areaCode = '203' }) @script:Common }
        finally { $global:WhatIfPreference = $false }
        & $script:Leftovers | Should -Be $before
    }
}
