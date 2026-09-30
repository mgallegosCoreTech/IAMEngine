#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Unit tests for Coretelligent.ActiveDirectory. The on-prem ActiveDirectory cmdlets aren't
# installed here, so we stub them globally and Mock in the module scope. Focus: OU placement,
# conditional groups, evidence-before-removal, and the do-not-move-ou guardrail (Six One).

BeforeAll {
    $ModulePath = "$PSScriptRoot/../modules/Coretelligent.ActiveDirectory/Coretelligent.ActiveDirectory.psm1"

    # Param blocks so Pester -ParameterFilter can see the bound args (e.g. $Path, $HomeDrive).
    # CmdletBinding gives -ErrorAction etc. for free; SupportsShouldProcess accepts -Confirm.
    # All stubs accept $Server/$Credential — the module splats @AdConnection (brokered ad-dc auth) onto every cmdlet.
    function global:Get-ADUser { [CmdletBinding()] param($Filter, $Identity, $Properties, $Server, $Credential) }
    function global:New-ADUser { [CmdletBinding()] param($Name, $SamAccountName, $UserPrincipalName, $GivenName, $Surname, $DisplayName, $Path, $Enabled, $OtherAttributes, $AccountPassword, $Server, $Credential) }
    function global:Set-ADUser { [CmdletBinding()] param($Identity, $HomeDrive, $HomeDirectory, $Replace, $Clear, $Add, $Remove, $Manager, $EmailAddress, $OfficePhone, $ChangePasswordAtLogon, $Server, $Credential) }
    function global:Add-ADGroupMember { [CmdletBinding()] param($Identity, $Members, $Server, $Credential) }
    function global:Remove-ADGroupMember { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Members, $Server, $Credential) }
    function global:Get-ADPrincipalGroupMembership { [CmdletBinding()] param($Identity, $Server, $Credential) }
    function global:Disable-ADAccount { [CmdletBinding()] param($Identity, $Server, $Credential) }
    function global:Move-ADObject { [CmdletBinding()] param($Identity, $TargetPath, $Server, $Credential) }
    function global:Set-ADAccountPassword { [CmdletBinding()] param($Identity, [switch]$Reset, $NewPassword, $Server, $Credential) }
    function global:Get-ADGroup { [CmdletBinding()] param($Identity, $Filter, $Properties, $Server, $Credential) }
    function global:Get-ADComputer { [CmdletBinding()] param($Identity, $Filter, $Properties, $Server, $Credential) }
    function global:Get-ADDomain { [CmdletBinding()] param($Server, $Credential) }  # Resolve-CtgAdDomain queries this for the real AD domain

    Import-Module $ModulePath -Force
}

Describe 'Invoke-CtgADOnboarding' {
    BeforeEach {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { $null }   # user absent
        Mock New-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        $user = [pscustomobject]@{ SamAccountName='jdoe'; FirstName='Jane'; LastName='Doe'; DisplayName='Jane Doe'; UserPrincipalName='jdoe@61commodities.com'; PrimaryDomain='61commodities.com' }
    }

    It 'creates the user in the configured OU when absent' {
        $config = [pscustomobject]@{ ou='Six One Users'; groups=@('Back Office Users') }
        $r = Invoke-CtgADOnboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        Should -Invoke New-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter { $Path -match 'Six One Users' }
    }

    It 'builds the OU DN from the ACTUAL AD domain, not the user email/UPN domain (Six One: AD corp.61commodities.com vs mail 61commodities.com)' {
        # Regression for UM0029655: the DN was built from PrimaryDomain (61commodities.com) so New-ADUser
        # targeted OU=...,DC=61commodities,DC=com — a naming context the DC (corp.61commodities.com) doesn't
        # own -> "The server is unwilling to process the request". The real AD domain must win.
        Mock Get-ADDomain -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DNSRoot='corp.61commodities.com' } }
        $r = Invoke-CtgADOnboarding -User $user -Config ([pscustomobject]@{ ou='Six One Users' })
        $r.Status | Should -Be 'ok'
        Should -Invoke New-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'OU=Six One Users,DC=corp,DC=61commodities,DC=com'
        }
    }

    It 'falls back to the email domain when the DC domain cannot be queried' {
        Mock Get-ADDomain -ModuleName Coretelligent.ActiveDirectory -MockWith { throw 'no ADWS' }
        $r = Invoke-CtgADOnboarding -User $user -Config ([pscustomobject]@{ ou='Six One Users' })
        Should -Invoke New-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'OU=Six One Users,DC=61commodities,DC=com'
        }
    }

    It 'adopts an existing account whose NAME matches (same person, re-run) without creating' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName='jdoe'; GivenName='Jane'; Surname='Doe'; DisplayName='Jane Doe' } }
        $r = Invoke-CtgADOnboarding -User $user -Config ([pscustomobject]@{ ou='Six One Users' })
        Should -Invoke New-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
        ($r.Actions -join ' ') | Should -Match 'same person'
    }

    It 'uses a FALLBACK SamAccountName when the primary is taken by a different person' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Filter -match "'jdoe'" } -MockWith { [pscustomobject]@{ SamAccountName='jdoe'; GivenName='John'; Surname='Doe'; DisplayName='John Doe' } }
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Filter -match "'jane.doe'" } -MockWith { $null }
        $u = $user | Select-Object *; $u | Add-Member UserPrincipalNameFallbacks @('jane.doe@61commodities.com') -Force
        $r = Invoke-CtgADOnboarding -User $u -Config ([pscustomobject]@{ ou='Six One Users' })
        Should -Invoke New-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $SamAccountName -eq 'jane.doe' -and $UserPrincipalName -eq 'jane.doe@61commodities.com' } -Times 1
        ($r.Actions -join ' ') | Should -Match 'fallback username'
    }

    It 'PAUSES for a decision when the only username is taken by a different person' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName='jdoe'; GivenName='John'; Surname='Doe'; DisplayName='John Doe' } }
        { Invoke-CtgADOnboarding -User $user -Config ([pscustomobject]@{ ou='Six One Users' }) } | Should -Throw -ExpectedMessage '*DECISION_NEEDED:username_collision*'
    }

    It 'resolves a group name that is off only by spacing (Perimeter81 Users -> Perimeter 81 Users)' {
        # UM0029655: the profile said "Perimeter81 Users" but the real AD group is "Perimeter 81 Users".
        # Exact add fails -> resolve by a space-insensitive match against AD and retry by DN.
        Mock Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { "$Identity" -eq 'Perimeter81 Users' } -MockWith { throw 'Cannot find an object with identity: Perimeter81 Users' }
        Mock Get-ADGroup -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity } -MockWith { $null }                 # exact miss
        Mock Get-ADGroup -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Filter } -MockWith { [pscustomobject]@{ Name='Perimeter 81 Users'; DistinguishedName='CN=Perimeter 81 Users,OU=Groups,DC=x' } }
        $r = Invoke-CtgADOnboarding -User $user -Config ([pscustomobject]@{ ou='SixOneUsers'; groups=@('Perimeter81 Users') })
        ($r.Actions -join ' ') | Should -Match "added to group: Perimeter 81 Users \(matched config 'Perimeter81 Users'\)"
    }

    It 'adds base groups and conditional groups only when their condition holds' {
        $config = [pscustomobject]@{
            ou='Six One Users'; groups=@('Back Office Users')
            conditionalGroups=@(
                [pscustomobject]@{ when='avd == true'; groups=@('61C-CORE_Users') }
                [pscustomobject]@{ when='perimeter == true'; groups=@('Perimeter 81 requested groups') }
            )
        }
        $withAvd = $user | Select-Object *; $withAvd | Add-Member avd $true -Force
        $r = Invoke-CtgADOnboarding -User $withAvd -Config $config
        # Back Office Users + 61C-CORE_Users (avd true); Perimeter NOT added (perimeter not set)
        ($r.Actions -join ' ') | Should -Match 'Back Office Users'
        ($r.Actions -join ' ') | Should -Match '61C-CORE_Users'
        ($r.Actions -join ' ') | Should -Not -Match 'Perimeter 81 requested groups'
    }

    It 'maps the home drive when configured' {
        $config = [pscustomobject]@{ ou='Six One Users'; homeDrive=[pscustomobject]@{ letter='H'; unc='\\61c-fs01\Users\<username>' } }
        $r = Invoke-CtgADOnboarding -User $user -Config $config
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $HomeDrive -eq 'H:' -and $HomeDirectory -match 'jdoe' }
    }

    It 'mirrors the reference user''s live groups (union with base groups)' {
        # New user absent (SamAccountName filter -> $null); the mirror reference resolves with 2 groups.
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {
            if ($Filter -like '*Christine Holleran*') {
                [pscustomobject]@{ MemberOf = @('CN=Finance-Team,OU=Groups,DC=x', 'CN=VPN-Users,OU=Groups,DC=x') }
            } else { $null }
        }
        $config = [pscustomobject]@{ ou='Finance'; groups=@('DEPT-Finance'); mirrorFromUser='Christine Holleran' }
        $r = Invoke-CtgADOnboarding -User $user -Config $config
        Should -Invoke Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'DEPT-Finance' } -Times 1
        Should -Invoke Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'CN=Finance-Team,OU=Groups,DC=x' } -Times 1
        Should -Invoke Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'CN=VPN-Users,OU=Groups,DC=x' } -Times 1
        ($r.Actions -join ' ') | Should -Match 'mirrored 2 group'
    }

    It 'mirrors from a reference user identified by EMAIL, not just by name (FR #0000126)' {
        # The intake field is free text and in practice is almost always an address: 36 of the last 40
        # mirror requests were emails. This used to try only DisplayName/Name/SamAccountName, so every
        # one of them missed and the step reported "mirror user not found" while the cloud lane — whose
        # resolver handles a UPN — mirrored the same person happily (UM0031004).
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {
            if ($Filter -like "UserPrincipalName -eq 'roxana@agostinofoods.com'") {
                [pscustomobject]@{ MemberOf = @('CN=Sales,OU=Groups,DC=x') }
            } else { $null }
        }
        $config = [pscustomobject]@{ ou='Finance'; mirrorFromUser='roxana@agostinofoods.com' }
        $r = Invoke-CtgADOnboarding -User $user -Config $config
        ($r.Actions -join ' ') | Should -Match 'mirrored 1 group'
        ($r.Actions -join ' ') | Should -Not -Match 'not found'
        Should -Invoke Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'CN=Sales,OU=Groups,DC=x' } -Times 1
    }

    It 'resolves a mirror user whose SMTP address differs from their UPN (mail attribute)' {
        # After a domain change the UPN and the mail address diverge; the address on the ticket is the
        # one people know, so it must still resolve.
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {
            if ($Filter -like "EmailAddress -eq 'old.name@legacy.com'") {
                [pscustomobject]@{ MemberOf = @('CN=Legacy,OU=Groups,DC=x') }
            } else { $null }
        }
        $config = [pscustomobject]@{ ou='Finance'; mirrorFromUser='old.name@legacy.com' }
        $r = Invoke-CtgADOnboarding -User $user -Config $config
        ($r.Actions -join ' ') | Should -Match 'mirrored 1 group'
    }

    It 'still mirrors from a plain display name (unchanged for the common non-email case)' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {
            if ($Filter -like "DisplayName -eq 'Christine Holleran'") {
                [pscustomobject]@{ MemberOf = @('CN=Finance-Team,OU=Groups,DC=x') }
            } else { $null }
        }
        $config = [pscustomobject]@{ ou='Finance'; mirrorFromUser='Christine Holleran' }
        $r = Invoke-CtgADOnboarding -User $user -Config $config
        ($r.Actions -join ' ') | Should -Match 'mirrored 1 group'
    }

    It 'threads the brokered ad-dc connection (Server + Credential) onto AD cmdlets' {
        $cred = [pscredential]::new('CORE\svc-ad', (ConvertTo-SecureString 'p' -AsPlainText -Force))
        $config = [pscustomobject]@{ ou='Finance'; groups=@('DEPT-Finance'); attributes=[pscustomobject]@{ title='Analyst' } }
        $r = Invoke-CtgADOnboarding -User $user -Config $config -AdConnection @{ Server='core-cce-dc01'; Credential=$cred }
        Should -Invoke New-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Server -eq 'core-cce-dc01' -and $Credential -eq $cred } -Times 1
        Should -Invoke Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Server -eq 'core-cce-dc01' -and $Credential } -Times 1
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Server -eq 'core-cce-dc01' } -Times 1  # attribute set
    }

    It 'flags a missing mirror user without failing the onboard' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { $null } # nobody matches
        $config = [pscustomobject]@{ ou='Finance'; groups=@('DEPT-Finance'); mirrorFromUser='Nobody Here' }
        $r = Invoke-CtgADOnboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        ($r.Actions -join ' ') | Should -Match "mirror user 'Nobody Here' not found"
    }
}

Describe 'Invoke-CtgADOffboarding' {
    BeforeEach {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {
            [pscustomobject]@{ SamAccountName='jdoe'; DistinguishedName='CN=Jane Doe,OU=Six One Users,DC=x'; Enabled=$true }
        }
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith {
            @([pscustomobject]@{ Name='Back Office Users'; DistinguishedName='CN=Back Office Users,OU=Groups,DC=x' },
              [pscustomobject]@{ Name='VPN Users'; DistinguishedName='CN=VPN Users,OU=Groups,DC=x' },
              [pscustomobject]@{ Name='Domain Users'; DistinguishedName='CN=Domain Users,CN=Users,DC=x' })
        }
        Mock Set-ADAccountPassword -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Move-ADObject -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        $user = [pscustomobject]@{ SamAccountName='jdoe' }
    }

    It 'captures group evidence, removes groups (except primary), hides from GAL, and disables' {
        $config = [pscustomobject]@{
            resetPassword=$true; removeAllGroups=$true; disableAccount=$true
            hideFromGal=[pscustomobject]@{ attribute='msDS-cloudExtensionAttribute1'; value='HideFromGAL' }
            guardrails=@('do-not-move-ou')
        }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        $r.Evidence.Groups | Should -Contain 'Back Office Users'
        # Domain Users (primary group) must not be removed
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -Times 2 -Exactly
        Should -Invoke Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -Times 1
        ($r.Actions -join ' ') | Should -Match 'HideFromGAL'
    }

    It 'does NOT move the user OU when the do-not-move-ou guardrail is set (the 365-delete trap)' {
        $config = [pscustomobject]@{ disableAccount=$true; guardrails=@('do-not-move-ou'); disabledUsersOu='OU=Disabled,DC=x' }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Move-ADObject -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
        ($r.Actions -join ' ') | Should -Match 'did not move'
    }

    It 'moves the user to the Disabled Users OU when no guardrail blocks it' {
        $config = [pscustomobject]@{ disableAccount=$true; disabledUsersOu='OU=Disabled Users,DC=x' }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Move-ADObject -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter { $TargetPath -match 'Disabled Users' }
    }

    It 'captures the manager it clears (name + email) — Exchange grants them the shared mailbox' {
        # Without this, an Exchange step that runs AFTER the AD step (a re-run) finds the manager link
        # already gone and silently skips the Full Access delegate.
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { "$Identity" -eq 'jdoe' } -MockWith {
            [pscustomobject]@{ SamAccountName='jdoe'; DistinguishedName='CN=Jane Doe,OU=Six One Users,DC=x'; Enabled=$true; Manager='CN=Boss Person,OU=Users,DC=x' }
        }
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { "$Identity" -eq 'CN=Boss Person,OU=Users,DC=x' } -MockWith {
            [pscustomobject]@{ DisplayName='Boss Person'; EmailAddress='boss@core.tech'; UserPrincipalName='boss@core.tech' }
        }
        $r = Invoke-CtgADOffboarding -User $user -Config ([pscustomobject]@{ disableAccount=$true; guardrails=@('do-not-move-ou') })
        $r.Manager.Name | Should -Be 'Boss Person'
        $r.Manager.Email | Should -Be 'boss@core.tech'
        $r.Evidence.Manager.Email | Should -Be 'boss@core.tech'
        ($r.Actions -join ' ') | Should -Match 'cleared manager: Boss Person <boss@core.tech>'
    }

    It 'says so when there was no manager to clear' {
        $r = Invoke-CtgADOffboarding -User $user -Config ([pscustomobject]@{ disableAccount=$true; guardrails=@('do-not-move-ou') })
        $r.Manager | Should -BeNullOrEmpty
        ($r.Actions -join ' ') | Should -Match 'cleared manager \(none set\)'
    }

    It 'removes a group whose display Name differs from its sAMAccountName (Teams/M365 group) — by DN, not Name' {
        # The bug: Remove-ADGroupMember -Identity $g.Name failed "cannot find an object with identity"
        # for groups whose Name != sAMAccountName (e.g. a Teams group "Chatsoft-Contracts Team_<hex>"),
        # even though the user is a member. Removal must target the DistinguishedName.
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith {
            @([pscustomobject]@{ Name='Chatsoft-Contracts Team'; SamAccountName='Chatsoft-Contracts Team_640a4c12864f'; DistinguishedName='CN=Chatsoft-Contracts Team_640a4c12864f,OU=M365 Groups,DC=x' })
        }
        $config = [pscustomobject]@{ removeAllGroups=$true; disableAccount=$true; guardrails=@('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter { $Identity -eq 'CN=Chatsoft-Contracts Team_640a4c12864f,OU=M365 Groups,DC=x' }
        ($r.Actions -join ' ') | Should -Match 'removed from group: Chatsoft-Contracts Team'
    }

    It 'offboard rules: removes only the specific rule-named groups the user belongs to (config.removeGroups)' {
        $config = [pscustomobject]@{ disableAccount=$true; removeGroups=@('VPN Users','Nonexistent Group'); guardrails=@('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        # member of 'VPN Users' -> removed by DN; not a member of 'Nonexistent Group' -> skipped
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter { $Identity -eq 'CN=VPN Users,OU=Groups,DC=x' }
        ($r.Actions -join ' ') | Should -Match 'not a member of Nonexistent Group'
    }

    It 'offboard rules: moveToOu wins over the system default disabledUsersOu' {
        $config = [pscustomobject]@{ disableAccount=$true; moveToOu='OU=Rule Disabled,DC=x'; disabledUsersOu='OU=Default Disabled,DC=x' }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Move-ADObject -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter { $TargetPath -eq 'OU=Rule Disabled,DC=x' }
    }

    It 'offboard rules: sets offboard attributes (config.offboardAttributes)' {
        $config = [pscustomobject]@{ disableAccount=$true; offboardAttributes=[pscustomobject]@{ description='Offboarded' }; guardrails=@('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Replace -and $Replace.description -eq 'Offboarded' }
        ($r.Actions -join ' ') | Should -Match 'description=Offboarded'
    }

    It 'does NOT try to remove the primary group (Disabled Users) — keeps it cleanly, no warn' {
        Mock Get-ADGroup -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ Name='Disabled Users'; primaryGroupToken=1234 } }
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Properties -contains 'primaryGroupID' } -MockWith { [pscustomobject]@{ primaryGroupID=1234 } }
        # User already in Disabled Users (a prior step / run) AND a normal group.
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith {
            @([pscustomobject]@{ Name='Disabled Users'; DistinguishedName='CN=Disabled Users,OU=x,DC=x' },
              [pscustomobject]@{ Name='VPN Users'; DistinguishedName='CN=VPN Users,OU=Groups,DC=x' })
        }
        $config = [pscustomobject]@{ removeAllGroups=$true; disableAccount=$true; disabledUsersPrimaryGroup='Disabled Users'; guardrails=@('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'CN=Disabled Users,OU=x,DC=x' } -Times 0 -Exactly
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'CN=VPN Users,OU=Groups,DC=x' } -Times 1
        $a = $r.Actions -join ' '
        $a | Should -Match "kept 'Disabled Users' — the user's primary group"
        $a | Should -Not -Match 'could not remove from group Disabled Users'
    }

    It 'sets the Disabled Users group as the primary group before stripping groups' {
        Mock Get-ADGroup -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ Name='Disabled Users'; primaryGroupToken=1234 } }
        # The second Get-ADUser (reading primaryGroupID) returns a different current primary -> a change is made.
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Properties -contains 'primaryGroupID' } -MockWith { [pscustomobject]@{ primaryGroupID=513 } }
        $config = [pscustomobject]@{ disableAccount=$true; removeAllGroups=$true; disabledUsersPrimaryGroup='Disabled Users'; guardrails=@('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Members -eq 'jdoe' } -Times 1
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Replace -and $Replace.primaryGroupID -eq 1234 } -Times 1
        ($r.Actions -join ' ') | Should -Match "set 'Disabled Users' as the primary group"
    }

    It 'disables and moves the computer object when disableComputer is set (machine from the case)' {
        Mock Get-ADComputer -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ Name='LT-JDOE'; DistinguishedName='CN=LT-JDOE,OU=Computers,DC=x'; Enabled=$true } }
        $config = [pscustomobject]@{ disableAccount=$true; disableComputer=$true; computerName='LT-JDOE'; disabledComputersOu='OU=Disabled Computers,DC=x'; guardrails=@('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'CN=LT-JDOE,OU=Computers,DC=x' } -Times 1
        Should -Invoke Move-ADObject -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $TargetPath -eq 'OU=Disabled Computers,DC=x' } -Times 1
        $r.Evidence.Computer.Name | Should -Be 'LT-JDOE'
        ($r.Actions -join ' ') | Should -Match 'disabled computer: LT-JDOE'
    }

    It 'notes when the computer object is not found (no machine in AD)' {
        Mock Get-ADComputer -ModuleName Coretelligent.ActiveDirectory -MockWith { $null }
        $config = [pscustomobject]@{ disableAccount=$true; disableComputer=$true; computerName='GONE-PC'; guardrails=@('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        ($r.Actions -join ' ') | Should -Match "computer 'GONE-PC' not found"
    }

    # This used to return Status='ok' — a GREEN offboard step for an account still enabled. An offboard
    # that cannot even identify who to disable must fail loudly, and must still touch nothing.
    It 'fails loudly (touching nothing) when the case has no user identity' {
        { Invoke-CtgADOffboarding -User ([pscustomobject]@{ SamAccountName = '' }) -Config ([pscustomobject]@{ disableAccount = $true }) } |
            Should -Throw -ExpectedMessage '*no SamAccountName, UPN, email or name*'
        Should -Invoke Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }

    # The UM payload shape: only `userToOffboard`. It must resolve by name, not no-op.
    # The name on the ticket is not the name in AD. Offer a shortlist instead of reporting "user not
    # found" on an account that is still enabled.
    It 'offers candidates (does not no-op) when the name matches no AD user exactly' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Filter -match 'DisplayName -eq' } -MockWith { @() }
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Filter -match '-like' } -MockWith {
            @([pscustomobject]@{ SamAccountName = 'pshah'; UserPrincipalName = 'pshah@x.com'; DisplayName = 'Parth K. Shah'; Title = 'Analyst'; Department = 'Sales'; Enabled = $true; EmailAddress = 'pshah@x.com'; DistinguishedName = 'CN=Parth K. Shah,OU=Users,DC=x,DC=com' })
        }
        $r = Invoke-CtgADOffboarding -User ([pscustomobject]@{ userToOffboard = 'Parth Shah' }) -Config ([pscustomobject]@{ disableAccount = $true })
        $r.CandidateReason | Should -Be 'no-match'
        $r.Candidates[0].samAccountName | Should -Be 'pshah'
        $r.Candidates[0].upn | Should -Be 'pshah@x.com'
        Should -Invoke Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }

    It 'resolves a UM-shaped payload (userToOffboard only) by display name' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Filter -match 'DisplayName' } -MockWith {
            [pscustomobject]@{ SamAccountName = 'pshah'; DistinguishedName = 'CN=Parth Shah,OU=Users,DC=x,DC=com'; MemberOf = @(); Manager = $null }
        }
        $r = Invoke-CtgADOffboarding -User ([pscustomobject]@{ userToOffboard = 'Parth Shah' }) -Config ([pscustomobject]@{ disableAccount = $true })
        $r.Status | Should -Be 'ok'
        ($r.Actions -join ' ') | Should -Match "resolved offboard target by display name 'Parth Shah'"
    }

    It 'resolves the offboard target by display name when the case has no SamAccountName' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { "$Filter" -match 'DisplayName' } -MockWith { [pscustomobject]@{ SamAccountName = 'jpark'; DistinguishedName = 'CN=Jordan Park,OU=Users,DC=x'; Enabled = $true } }
        $r = Invoke-CtgADOffboarding -User ([pscustomobject]@{ SamAccountName = ''; DisplayName = 'Jordan Park' }) -Config ([pscustomobject]@{ disableAccount = $true; guardrails = @('do-not-move-ou') })
        ($r.Actions -join ' ') | Should -Match "resolved offboard target by display name 'Jordan Park'"
        Should -Invoke Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -Times 1
    }

    It 'does not crash when the payload has NO SamAccountName property (display name only)' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { "$Filter" -match 'DisplayName' } -MockWith { [pscustomobject]@{ SamAccountName = 'esack'; DistinguishedName = 'CN=Evan,OU=Users,DC=x'; Enabled = $true } }
        # NOTE: the user object intentionally has NO SamAccountName key — direct access would throw under StrictMode.
        $r = Invoke-CtgADOffboarding -User ([pscustomobject]@{ DisplayName = 'Evan Sacksner' }) -Config ([pscustomobject]@{ disableAccount = $true; guardrails = @('do-not-move-ou') })
        $r.Status | Should -Be 'ok'
        ($r.Actions -join ' ') | Should -Match "resolved offboard target by display name 'Evan Sacksner'"
    }

    It 'does NOT remove a well-known privileged group (Domain Admins) — flags it for manual removal' {
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith {
            @([pscustomobject]@{ Name='Domain Admins'; DistinguishedName='CN=Domain Admins,CN=Users,DC=x' },
              [pscustomobject]@{ Name='VPN Users'; DistinguishedName='CN=VPN Users,OU=Groups,DC=x' })
        }
        $config = [pscustomobject]@{ removeAllGroups=$true; disableAccount=$true; guardrails=@('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'CN=Domain Admins,CN=Users,DC=x' } -Times 0 -Exactly
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'CN=VPN Users,OU=Groups,DC=x' } -Times 1
        ($r.Actions -join ' ') | Should -Match 'protected/privileged group NOT removed.*Domain Admins'
        $r.Evidence.ProtectedGroups | Should -Contain 'Domain Admins'
    }

    It 'does NOT remove a group under a *Privileged* OU (matches the script pattern)' {
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith {
            @([pscustomobject]@{ Name='Tier0 Admins'; DistinguishedName='CN=Tier0 Admins,OU=T0 Privileged,OU=Groups,DC=x' },
              [pscustomobject]@{ Name='VPN Users'; DistinguishedName='CN=VPN Users,OU=Groups,DC=x' })
        }
        $config = [pscustomobject]@{ removeAllGroups=$true; disableAccount=$true; guardrails=@('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'Tier0 Admins' } -Times 0 -Exactly
        $r.Evidence.ProtectedGroups | Should -Contain 'Tier0 Admins'
    }

    # FR #36: the planner now injects hideFromGal={attribute,value} on ad_synced clients, so the
    # hide write must be idempotent and must never abort the offboard on an AD without the
    # on-prem Exchange schema (msExchHideFromAddressLists absent -> "properties are invalid").
    It 'FR#36: skips the GAL write when the attribute already carries the value (idempotent re-run)' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Properties -contains 'msExchHideFromAddressLists' } -MockWith {
            [pscustomobject]@{ SamAccountName='jdoe'; msExchHideFromAddressLists=$true }
        }
        $config = [pscustomobject]@{ disableAccount=$true; guardrails=@('do-not-move-ou'); hideFromGal=[pscustomobject]@{ attribute='msExchHideFromAddressLists'; value='TRUE' } }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        ($r.Actions -join ' ') | Should -Match 'already hidden from GAL'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Replace -and $Replace.ContainsKey('msExchHideFromAddressLists') } -Times 0 -Exactly
    }

    It 'FR#36: writes the hide attribute when not yet hidden' {
        $config = [pscustomobject]@{ disableAccount=$true; guardrails=@('do-not-move-ou'); hideFromGal=[pscustomobject]@{ attribute='msExchHideFromAddressLists'; value='TRUE' } }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Replace -and $Replace.ContainsKey('msExchHideFromAddressLists') } -Times 1 -Exactly
        ($r.Actions -join ' ') | Should -Match 'hid from GAL: msExchHideFromAddressLists=TRUE'
    }

    It 'FR#36: a schema-missing hide attribute WARNs and continues — the disable still runs' {
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Replace -and $Replace.ContainsKey('msExchHideFromAddressLists') } -MockWith { throw 'Set-ADUser : One or more properties are invalid.' }
        $config = [pscustomobject]@{ disableAccount=$true; guardrails=@('do-not-move-ou'); hideFromGal=[pscustomobject]@{ attribute='msExchHideFromAddressLists'; value='TRUE' } }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        ($r.Actions -join ' ') | Should -Match "WARN could not hide from GAL — msExchHideFromAddressLists isn't in this AD schema"
        Should -Invoke Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -Times 1
    }

    It 'FR#36: defaults the hide value to TRUE when the config carries no value' {
        $config = [pscustomobject]@{ disableAccount=$true; guardrails=@('do-not-move-ou'); hideFromGal=[pscustomobject]@{ attribute='msExchHideFromAddressLists' } }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Replace -and $Replace['msExchHideFromAddressLists'] -eq 'TRUE' } -Times 1 -Exactly
        ($r.Actions -join ' ') | Should -Match 'hid from GAL: msExchHideFromAddressLists=TRUE'
    }

    It 'protectPrivilegedGroups:false strips even privileged groups (opt-out)' {
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith {
            @([pscustomobject]@{ Name='Domain Admins'; DistinguishedName='CN=Domain Admins,CN=Users,DC=x' })
        }
        $config = [pscustomobject]@{ removeAllGroups=$true; protectPrivilegedGroups=$false; disableAccount=$true; guardrails=@('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -eq 'CN=Domain Admins,CN=Users,DC=x' } -Times 1
    }
}

Describe 'Confirm-CtgAD' {
    It 'onboard: passes when the user is in the OU with the expected group' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DistinguishedName='CN=Jane Doe,OU=Six One Users,DC=61commodities,DC=com'; Enabled=$true; HomeDirectory='\\srv\home\jdoe' } }
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith { @([pscustomobject]@{ Name='Back Office Users' }, [pscustomobject]@{ Name='Domain Users' }) }
        $user = [pscustomobject]@{ SamAccountName='jdoe'; PrimaryDomain='61commodities.com' }
        $config = [pscustomobject]@{ ou='Six One Users'; groups=@('Back Office Users'); homeDrive=[pscustomobject]@{ unc='\\srv\home\<username>'; letter='H' } }
        $r = Confirm-CtgAD -User $user -Config $config -Action 'onboard'
        $r.ok | Should -BeTrue
        ($r.checks | Where-Object { $_.name -eq 'group: Back Office Users' }).pass | Should -BeTrue
        ($r.checks | Where-Object { $_.name -eq 'home drive mapped' }).pass | Should -BeTrue
    }

    It 'onboard: still validates on an AD WITHOUT the Exchange schema (msExch property errors the call)' {
        # Regression (Six One): the shared read-back requested msExchHideFromAddressLists. On an EXO-only
        # tenant (no on-prem Exchange schema) that fails the WHOLE Get-ADUser call, so a fully-onboarded
        # user validated as ABSENT (all 4 checks failed). The core read-back must not request that attr.
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DistinguishedName='CN=Laura Munder,OU=SixOneUsers,DC=corp,DC=61commodities,DC=com'; Enabled=$true; HomeDirectory='\\61c-fs01\Users\lauramunder' } }
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Properties -contains 'msExchHideFromAddressLists' } -MockWith { throw 'Get-ADUser : One or more properties are invalid.' }
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith { @([pscustomobject]@{ Name='Back Office Users' }) }
        Mock Get-ADDomain -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DNSRoot='corp.61commodities.com' } }
        $user = [pscustomobject]@{ SamAccountName='lauramunder'; PrimaryDomain='61commodities.com' }
        $config = [pscustomobject]@{ ou='SixOneUsers'; groups=@('Back Office Users'); homeDrive=[pscustomobject]@{ unc='\\61c-fs01\Users\<username>'; letter='H' } }
        $r = Confirm-CtgAD -User $user -Config $config -Action 'onboard'
        $r.ok | Should -BeTrue
        ($r.checks | Where-Object { $_.name -eq 'user exists' }).pass | Should -BeTrue
        ($r.checks | Where-Object { $_.name -match 'in OU' }).pass | Should -BeTrue
    }

    It 'offboard: passes when disabled, groups gone, hidden, and NOT moved (guardrail)' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DistinguishedName='CN=Jane Doe,OU=Six One Users,DC=x'; Enabled=$false; msExchHideFromAddressLists=$true } }
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith { @([pscustomobject]@{ Name='Domain Users' }) }
        $user = [pscustomobject]@{ SamAccountName='jdoe' }
        $config = [pscustomobject]@{ removeAllGroups=$true; disableAccount=$true; hideFromGal=[pscustomobject]@{ attribute='msExchHideFromAddressLists' }; guardrails=@('do-not-move-ou'); disabledUsersOu='OU=Disabled,DC=x' }
        $r = Confirm-CtgAD -User $user -Config $config -Action 'offboard'
        $r.ok | Should -BeTrue
        ($r.checks | Where-Object { $_.name -eq 'not moved (do-not-move-ou)' }).pass | Should -BeTrue
    }

    It 'offboard: fails the not-moved check when the user sits under the Disabled OU' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DistinguishedName='CN=Jane Doe,OU=Disabled,DC=x'; Enabled=$false } }
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith { @() }
        $user = [pscustomobject]@{ SamAccountName='jdoe' }
        $config = [pscustomobject]@{ disableAccount=$true; guardrails=@('do-not-move-ou'); disabledUsersOu='OU=Disabled,DC=x' }
        $r = Confirm-CtgAD -User $user -Config $config -Action 'offboard'
        ($r.checks | Where-Object { $_.name -eq 'not moved (do-not-move-ou)' }).pass | Should -BeFalse
    }

    It 'offboard: verifies hide-from-GAL against the CONFIGURED attribute, not a hardcoded msExch one (FR#36)' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DistinguishedName='CN=Jane Doe,OU=Users,DC=x'; Enabled=$false } }
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Properties -contains 'msDS-cloudExtensionAttribute1' } -MockWith {
            [pscustomobject]@{ 'msDS-cloudExtensionAttribute1'='HideFromGAL' }
        }
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith { @() }
        $config = [pscustomobject]@{ disableAccount=$true; hideFromGal=[pscustomobject]@{ attribute='msDS-cloudExtensionAttribute1'; value='HideFromGAL' }; guardrails=@('do-not-move-ou') }
        $r = Confirm-CtgAD -User ([pscustomobject]@{ SamAccountName='jdoe' }) -Config $config -Action 'offboard'
        $r.ok | Should -BeTrue
        ($r.checks | Where-Object { $_.name -eq 'hidden from GAL' }).pass | Should -BeTrue
        Should -Invoke Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Properties -contains 'msDS-cloudExtensionAttribute1' } -Times 1
        Should -Invoke Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Properties -contains 'msExchHideFromAddressLists' } -Times 0 -Exactly
    }

    It 'offboard: a TRANSIENT hide-attribute read error stays FAIL-CLOSED — the check records a miss, not a skip (FR#36)' {
        # Only a schema-missing read may skip the check; a DC timeout / ADWS hiccup must not
        # green-light a leaver who may still be visible in the GAL.
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DistinguishedName='CN=Jane Doe,OU=Users,DC=x'; Enabled=$false } }
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Properties -contains 'msExchHideFromAddressLists' } -MockWith { throw 'The server is not operational' }
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith { @() }
        $config = [pscustomobject]@{ disableAccount=$true; hideFromGal=[pscustomobject]@{ attribute='msExchHideFromAddressLists'; value='TRUE' }; guardrails=@('do-not-move-ou') }
        $r = Confirm-CtgAD -User ([pscustomobject]@{ SamAccountName='jdoe' }) -Config $config -Action 'offboard'
        $r.ok | Should -BeFalse
        ($r.checks | Where-Object { $_.name -eq 'hidden from GAL' }).pass | Should -BeFalse
    }

    It 'offboard: SKIPS the hide check when the attribute is not in the schema (read throws) — verify must not loop the case (FR#36)' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DistinguishedName='CN=Jane Doe,OU=Users,DC=x'; Enabled=$false } }
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Properties -contains 'msExchHideFromAddressLists' } -MockWith { throw 'Get-ADUser : One or more properties are invalid.' }
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith { @() }
        $config = [pscustomobject]@{ disableAccount=$true; hideFromGal=[pscustomobject]@{ attribute='msExchHideFromAddressLists'; value='TRUE' }; guardrails=@('do-not-move-ou') }
        $r = Confirm-CtgAD -User ([pscustomobject]@{ SamAccountName='jdoe' }) -Config $config -Action 'offboard'
        $r.ok | Should -BeTrue
        @($r.checks | Where-Object { $_.name -eq 'hidden from GAL' }).Count | Should -Be 0
    }

    It 'offboard: a kept privileged group does NOT fail the groups-removed check' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DistinguishedName='CN=Jane Doe,OU=Six One Users,DC=x'; Enabled=$false } }
        # Only "Domain Admins" (privileged, intentionally kept) + Domain Users remain — must still pass.
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith {
            @([pscustomobject]@{ Name='Domain Admins'; DistinguishedName='CN=Domain Admins,CN=Users,DC=x' },
              [pscustomobject]@{ Name='Domain Users'; DistinguishedName='CN=Domain Users,CN=Users,DC=x' })
        }
        $config = [pscustomobject]@{ removeAllGroups=$true; disableAccount=$true; guardrails=@('do-not-move-ou') }
        $r = Confirm-CtgAD -User ([pscustomobject]@{ SamAccountName='jdoe' }) -Config $config -Action 'offboard'
        ($r.checks | Where-Object { $_.name -eq 'groups removed' }).pass | Should -BeTrue
    }
}

Describe 'Set-CtgADAttributes' {
    It 'Set-ADUser -Replace each non-empty attribute' {
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {}
        $applied = Set-CtgADAttributes -Identity 'jdoe' -Attributes @{ title='Engineer'; department='Field Services'; c='US' }
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 3
        ($applied -join '|') | Should -Match 'title=Engineer'
    }

    It 'skips empty / null values' {
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {}
        $applied = Set-CtgADAttributes -Identity 'jdoe' -Attributes @{ title=''; st=$null; department='X' }
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 1
        ($applied -join '|') | Should -Not -Match 'title'
    }

    It 'resolves a manager NAME to a DN and sets -Manager' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ DistinguishedName='CN=Jane Boss,OU=Users,DC=x' } }
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {}
        Set-CtgADAttributes -Identity 'jdoe' -Attributes @{ manager='Jane Boss' }
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Manager -eq 'CN=Jane Boss,OU=Users,DC=x' } -Times 1
    }

    It 'uses a manager DN as-is (no lookup)' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {}
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {}
        Set-CtgADAttributes -Identity 'jdoe' -Attributes @{ manager='CN=Boss,OU=Users,DC=x' }
        Should -Invoke Get-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Manager -eq 'CN=Boss,OU=Users,DC=x' } -Times 1
    }

    It 'onboarding applies the resolved attribute map' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { $null }
        Mock New-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {}
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {}
        Mock Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -MockWith {}
        $user = [pscustomobject]@{ SamAccountName='jdoe'; DisplayName='John Doe'; FirstName='John'; LastName='Doe'; UserPrincipalName='jdoe@core.tech'; PrimaryDomain='core.tech' }
        $config = [pscustomobject]@{ ou='OU=Field,DC=x'; attributes=[pscustomobject]@{ title='Engineer'; department='Field Services' } }
        $r = Invoke-CtgADOnboarding -User $user -Config $config
        ($r.Actions -join '|') | Should -Match 'set attribute: title=Engineer'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Replace -and $Replace.department -eq 'Field Services' } -Times 1
    }
}

Describe 'Invoke-CtgADEmailWriteback' {
    BeforeEach {
        # An existing user whose mail is currently unset.
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName='jdoe'; mail=$null } }
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { }
    }

    It 'writes AD mail from the app-injected writebackEmail' {
        $user = [pscustomobject]@{ SamAccountName='jdoe'; UserPrincipalName='jdoe@corp.example.com'; DisplayName='Jane Doe'; workEmail='jdoe@corp.example.com'; writebackEmail='jane.doe@example.com' }
        $r = Invoke-CtgADEmailWriteback -User $user -Config ([pscustomobject]@{})
        $r.Status | Should -Be 'ok'
        $r.Mail | Should -Be 'jane.doe@example.com'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter { $EmailAddress -eq 'jane.doe@example.com' }
    }

    It 'falls back to workEmail when the app injected no writebackEmail' {
        $user = [pscustomobject]@{ SamAccountName='jdoe'; UserPrincipalName='jdoe@example.com'; workEmail='jdoe@example.com'; writebackEmail=$null }
        $r = Invoke-CtgADEmailWriteback -User $user -Config ([pscustomobject]@{})
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter { $EmailAddress -eq 'jdoe@example.com' }
    }

    It 'is idempotent — no write when mail already matches' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName='jdoe'; mail='jdoe@example.com' } }
        $user = [pscustomobject]@{ SamAccountName='jdoe'; writebackEmail='jdoe@example.com' }
        $r = Invoke-CtgADEmailWriteback -User $user -Config ([pscustomobject]@{})
        ($r.Actions -join '|') | Should -Match 'already'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }

    It 'does nothing when there is no email anywhere on the case' {
        $user = [pscustomobject]@{ SamAccountName='jdoe' }
        $r = Invoke-CtgADEmailWriteback -User $user -Config ([pscustomobject]@{})
        $r.Status | Should -Be 'ok'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }
}

# The teams step's assigned number, written to AD telephoneNumber (injected as writebackPhone).
Describe 'Invoke-CtgADPhoneWriteback' {
    BeforeEach {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName = 'jdoe'; telephoneNumber = $null } }
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { }
    }

    It 'writes the Teams number into telephoneNumber' {
        $r = Invoke-CtgADPhoneWriteback -User ([pscustomobject]@{ SamAccountName = 'jdoe'; writebackPhone = '+12035550120' }) -Config ([pscustomobject]@{})
        $r.TelephoneNumber | Should -Be '+12035550120'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter { $Identity -eq 'jdoe' -and $OfficePhone -eq '+12035550120' }
        ($r.Actions -join ' ') | Should -Match "set AD telephoneNumber: '\(unset\)' -> '\+12035550120'"
    }

    It 'is idempotent' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName = 'jdoe'; telephoneNumber = '+12035550120' } }
        $r = Invoke-CtgADPhoneWriteback -User ([pscustomobject]@{ SamAccountName = 'jdoe'; writebackPhone = '+12035550120' }) -Config ([pscustomobject]@{})
        ($r.Actions -join ' ') | Should -Match 'already'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }

    It 'does nothing when the Teams step assigned no number' {
        $r = Invoke-CtgADPhoneWriteback -User ([pscustomobject]@{ SamAccountName = 'jdoe'; writebackPhone = $null }) -Config ([pscustomobject]@{})
        ($r.Actions -join ' ') | Should -Match 'no Teams number'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }

    It 'warns (and writes nothing) when the user is not in AD' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { $null }
        $r = Invoke-CtgADPhoneWriteback -User ([pscustomobject]@{ SamAccountName = 'ghost'; writebackPhone = '+12035550120' }) -Config ([pscustomobject]@{})
        ($r.Actions -join ' ') | Should -Match "WARN the user wasn't found in AD"
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }

    It 'under WhatIf, writes nothing' {
        $r = Invoke-CtgADPhoneWriteback -User ([pscustomobject]@{ SamAccountName = 'jdoe'; writebackPhone = '+12035550120' }) -Config ([pscustomobject]@{}) -WhatIf
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }

    It 'validates telephoneNumber against the injected number' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName = 'jdoe'; telephoneNumber = '+12035550120' } }
        (Confirm-CtgADPhoneWriteback -User ([pscustomobject]@{ SamAccountName = 'jdoe'; writebackPhone = '+12035550120' }) -Config ([pscustomobject]@{})).ok | Should -BeTrue
        (Confirm-CtgADPhoneWriteback -User ([pscustomobject]@{ SamAccountName = 'jdoe'; writebackPhone = '+12035550999' }) -Config ([pscustomobject]@{})).ok | Should -BeFalse
        (Confirm-CtgADPhoneWriteback -User ([pscustomobject]@{ SamAccountName = 'jdoe' }) -Config ([pscustomobject]@{})).ok | Should -BeTrue
    }
}

Describe 'Confirm-CtgADEmailWriteback' {
    It 'passes via the UPN fallback when the case has no SamAccountName (INC0858516)' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName='mgallant'; mail='mgallant@core.tech' } }
        $user = [pscustomobject]@{ UserPrincipalName='mgallant@core.tech'; DisplayName='M Gallant'; workEmail='mgallant@core.tech' }
        $v = Confirm-CtgADEmailWriteback -User $user -Config ([pscustomobject]@{})
        $v.ok | Should -BeTrue
        $v.checks[0].actual | Should -Be 'mgallant@core.tech'
    }

    It 'passes when there is no email on the case — the executor deliberately wrote nothing' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { $null }
        $v = Confirm-CtgADEmailWriteback -User ([pscustomobject]@{ SamAccountName='jdoe' }) -Config ([pscustomobject]@{})
        $v.ok | Should -BeTrue
        Should -Invoke Get-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }

    It 'misses when the AD mail differs from the target' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName='jdoe'; mail='old@example.com' } }
        $v = Confirm-CtgADEmailWriteback -User ([pscustomobject]@{ SamAccountName='jdoe'; writebackEmail='new@example.com' }) -Config ([pscustomobject]@{})
        $v.ok | Should -BeFalse
        $v.checks[0].actual | Should -Be 'old@example.com'
    }
}

Describe 'Invoke-CtgADConsistencyCheck' {
    BeforeEach {
        $script:guid = [guid]'00112233-4455-6677-8899-aabbccddeeff'
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {
            [pscustomobject]@{ SamAccountName = 'jdoe'; objectGUID = $script:guid; 'mS-DS-ConsistencyGuid' = $null }
        }
    }

    It 'passes (linked) when the Entra immutableId matches the objectGUID source anchor' {
        $b64 = [Convert]::ToBase64String($script:guid.ToByteArray())
        $u = [pscustomobject]@{ SamAccountName = 'jdoe'; cloudObject = [pscustomobject]@{ immutableId = $b64; syncEnabled = $true; userId = 'c1' } }
        $r = Invoke-CtgADConsistencyCheck -User $u -Config ([pscustomobject]@{})
        $r.Flagged | Should -BeFalse
        ($r.Actions -join '|') | Should -Match 'linked'
    }

    It 'flags a CLOUD-ONLY Entra object (syncEnabled false) as a duplicate risk' {
        $u = [pscustomobject]@{ SamAccountName = 'jdoe'; cloudObject = [pscustomobject]@{ immutableId = $null; syncEnabled = $false; userId = 'c1' } }
        $r = Invoke-CtgADConsistencyCheck -User $u -Config ([pscustomobject]@{})
        $r.Flagged | Should -BeTrue
        ($r.Actions -join '|') | Should -Match 'CLOUD-ONLY'
    }

    It 'flags a mismatched immutableId (possible duplicate / unlinked)' {
        $u = [pscustomobject]@{ SamAccountName = 'jdoe'; cloudObject = [pscustomobject]@{ immutableId = 'AAAAAAAAAAAAAAAAAAAAAA=='; syncEnabled = $true; userId = 'c1' } }
        $r = Invoke-CtgADConsistencyCheck -User $u -Config ([pscustomobject]@{})
        $r.Flagged | Should -BeTrue
        ($r.Actions -join '|') | Should -Match 'does NOT match'
    }

    It 'is clean when no Entra object was reported (fresh sync)' {
        $u = [pscustomobject]@{ SamAccountName = 'jdoe'; cloudObject = [pscustomobject]@{ immutableId = $null; syncEnabled = $null; userId = $null } }
        $r = Invoke-CtgADConsistencyCheck -User $u -Config ([pscustomobject]@{})
        $r.Flagged | Should -BeFalse
    }

    It 'WARNS that it could not verify when the app reports the Entra object was never read (FR #0000093)' {
        # The blank cloudObject used to be indistinguishable from a genuine 'no cloud object yet', so the
        # check reported an all-clear for a comparison it never performed. The app now says WHY.
        $u = [pscustomobject]@{ SamAccountName = 'jdoe'; cloudObject = [pscustomobject]@{ immutableId = $null; syncEnabled = $null; userId = $null
                                                                                          read = $false; reason = 'the Microsoft 365 step failed - its Entra object was never reported' } }
        $r = Invoke-CtgADConsistencyCheck -User $u -Config ([pscustomobject]@{})
        ($r.Actions -join '|') | Should -Match 'WARN'
        ($r.Actions -join '|') | Should -Match 'could NOT verify'
        ($r.Actions -join '|') | Should -Match 'Microsoft 365 step failed'
        ($r.Actions -join '|') | Should -Not -Match 'a fresh sync will create'
        $r.Flagged | Should -BeTrue
    }

    It 'still reports the genuine no-cloud-object case as ok when the app DID read it' {
        $u = [pscustomobject]@{ SamAccountName = 'jdoe'; cloudObject = [pscustomobject]@{ immutableId = $null; syncEnabled = $null; userId = $null; read = $true } }
        $r = Invoke-CtgADConsistencyCheck -User $u -Config ([pscustomobject]@{})
        ($r.Actions -join '|') | Should -Match 'a fresh sync will create'
        ($r.Actions -join '|') | Should -Not -Match 'WARN'
        $r.Flagged | Should -BeFalse
    }

    It 'an OLDER app that sends no read flag behaves exactly as before (backward compatible)' {
        # A runner that has picked up this module while the app has not must not start crying wolf.
        $u = [pscustomobject]@{ SamAccountName = 'jdoe'; cloudObject = [pscustomobject]@{ immutableId = $null; syncEnabled = $null; userId = $null } }
        $r = Invoke-CtgADConsistencyCheck -User $u -Config ([pscustomobject]@{})
        ($r.Actions -join '|') | Should -Match 'a fresh sync will create'
        $r.Flagged | Should -BeFalse
    }
}

Describe 'Invoke-CtgADHardMatch' {
    BeforeEach {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName = 'jdoe'; 'mS-DS-ConsistencyGuid' = $null } }
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { }
    }
    It 'writes mS-DS-ConsistencyGuid = the injected immutableId (16-byte base64)' {
        $b64 = [Convert]::ToBase64String(([guid]::NewGuid()).ToByteArray())
        $r = Invoke-CtgADHardMatch -User ([pscustomobject]@{ SamAccountName = 'jdoe' }) -Config ([pscustomobject]@{ immutableId = $b64 })
        $r.Status | Should -Be 'ok'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter { $Replace['mS-DS-ConsistencyGuid'].Length -eq 16 }
    }
    It 'REFUSES a non-16-byte base64 value (never writes garbage into the anchor)' {
        $r = Invoke-CtgADHardMatch -User ([pscustomobject]@{ SamAccountName = 'jdoe' }) -Config ([pscustomobject]@{ immutableId = 'bm90LWEtZ3VpZA==' })
        $r.Status | Should -Be 'error'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }
    It 'is idempotent — no write when the anchor already matches' {
        $g = [guid]::NewGuid(); $b64 = [Convert]::ToBase64String($g.ToByteArray())
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName = 'jdoe'; 'mS-DS-ConsistencyGuid' = $g.ToByteArray() } }
        $r = Invoke-CtgADHardMatch -User ([pscustomobject]@{ SamAccountName = 'jdoe' }) -Config ([pscustomobject]@{ immutableId = $b64 })
        ($r.Actions -join '|') | Should -Match 'already'
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }
}

Describe 'Invoke-CtgADPasswordReset' {
    # Ad-hoc "Generate random password" (INC0855142): the app generates the value, injects it as
    # config.newPassword at claim, and reveals it once to the operator. The executor only sets it —
    # and must never echo it into the result.
    BeforeEach {
        Mock Set-ADAccountPassword -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        $user = [pscustomobject]@{ SamAccountName = 'jdoe'; UserPrincipalName = 'jdoe@x.com'; DisplayName = 'Jane Doe' }
        $config = [pscustomobject]@{ newPassword = 'Xy7#kQ9pLm2$Wn4v' }
    }

    It 'resets the password and requires a change at next logon' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName = 'jdoe' } }
        $r = Invoke-CtgADPasswordReset -User $user -Config $config
        $r.Status | Should -Be 'ok'
        Should -Invoke Set-ADAccountPassword -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter {
            $Reset -and $Identity -eq 'jdoe' -and $NewPassword -is [securestring]
        }
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'jdoe' -and $ChangePasswordAtLogon -eq $true
        }
    }

    It 'never echoes the password into the result' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName = 'jdoe' } }
        $r = Invoke-CtgADPasswordReset -User $user -Config $config
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape('Xy7#kQ9pLm2$Wn4v'))
    }

    It 'throws when the app did not inject newPassword (a wiped value is never re-usable)' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName = 'jdoe' } }
        { Invoke-CtgADPasswordReset -User $user -Config ([pscustomobject]@{}) } | Should -Throw '*newPassword*'
        Should -Invoke Set-ADAccountPassword -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }

    It 'throws when the user is not found — a reset must never silently no-op' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { $null }
        { Invoke-CtgADPasswordReset -User $user -Config $config } | Should -Throw '*not found*'
        Should -Invoke Set-ADAccountPassword -ModuleName Coretelligent.ActiveDirectory -Times 0 -Exactly
    }

    It 'falls back to the UPN lookup when the case has no SamAccountName' {
        $noSam = [pscustomobject]@{ UserPrincipalName = 'jdoe@x.com' }
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {
            param($Filter, $Identity, $Properties, $Server, $Credential)
            if ($Filter -like "*UserPrincipalName*") { [pscustomobject]@{ SamAccountName = 'jdoe' } }
        }
        $r = Invoke-CtgADPasswordReset -User $noSam -Config $config
        $r.Status | Should -Be 'ok'
        Should -Invoke Set-ADAccountPassword -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly -ParameterFilter { $Identity -eq 'jdoe' }
    }

    It 'a change-at-logon failure is a WARN action, not a failed reset (the password DID change)' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName = 'jdoe' } }
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { throw 'policy forbids' }
        $r = Invoke-CtgADPasswordReset -User $user -Config $config
        $r.Status | Should -Be 'ok'
        ($r.Actions -join '|') | Should -Match 'WARN'
    }
}

Describe 'Test-CtgAdCreateUserAce' {
    BeforeAll {
        $script:userGuid = 'bf967aba-0de6-11d0-a285-00aa003049e2'
        $script:me = 'S-1-5-21-1-1-1-1111'
        $script:myGroup = 'S-1-5-21-1-1-1-2222'
    }

    It 'allows via CreateChild scoped to the user class' {
        $rules = @(@{ Type = 'Allow'; Sid = $myGroup; Rights = 'CreateChild'; ObjectType = $userGuid })
        Test-CtgAdCreateUserAce -Rules $rules -Sids @($me, $myGroup) | Should -BeTrue
    }

    It 'allows via unscoped CreateChild (all child classes) and GenericAll' {
        Test-CtgAdCreateUserAce -Rules @(@{ Type = 'Allow'; Sid = $me; Rights = 'CreateChild'; ObjectType = '' }) -Sids @($me) | Should -BeTrue
        Test-CtgAdCreateUserAce -Rules @(@{ Type = 'Allow'; Sid = $me; Rights = 'GenericAll'; ObjectType = '' }) -Sids @($me) | Should -BeTrue
    }

    It 'ignores ACEs for other SIDs and CreateChild scoped to a different class' {
        $other = 'S-1-5-21-9-9-9-9999'
        Test-CtgAdCreateUserAce -Rules @(@{ Type = 'Allow'; Sid = $other; Rights = 'GenericAll'; ObjectType = '' }) -Sids @($me) | Should -BeFalse
        $groupGuid = 'bf967a9c-0de6-11d0-a285-00aa003049e2' # group class — not user
        Test-CtgAdCreateUserAce -Rules @(@{ Type = 'Allow'; Sid = $me; Rights = 'CreateChild'; ObjectType = $groupGuid }) -Sids @($me) | Should -BeFalse
    }

    It 'an explicit deny wins over an allow' {
        $rules = @(
            @{ Type = 'Allow'; Sid = $myGroup; Rights = 'GenericAll'; ObjectType = '' }
            @{ Type = 'Deny';  Sid = $me;      Rights = 'CreateChild'; ObjectType = $userGuid }
        )
        Test-CtgAdCreateUserAce -Rules $rules -Sids @($me, $myGroup) | Should -BeFalse
    }

    It 'ReadProperty-only rules never grant create' {
        Test-CtgAdCreateUserAce -Rules @(@{ Type = 'Allow'; Sid = $me; Rights = 'ReadProperty, ListChildren'; ObjectType = '' }) -Sids @($me) | Should -BeFalse
    }
}

Describe 'Invoke-CtgADOffboarding admin-account (-a) sweep' {
    BeforeEach {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith {
            [pscustomobject]@{ SamAccountName='jdoe'; DistinguishedName='CN=Jane Doe,OU=Users,DC=x'; Enabled=$true; UserPrincipalName='jdoe@x.com' }
        }
        Mock Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith { @() }
        Mock Set-ADAccountPassword -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Move-ADObject -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock Get-ADComputer -ModuleName Coretelligent.ActiveDirectory -MockWith { $null }
        $user = [pscustomobject]@{ SamAccountName = 'jdoe' }
        $config = [pscustomobject]@{ disableAccount = $true; adminAccountSuffix = '-a'; guardrails = @('do-not-move-ou') }
    }

    It 'disables the -a account the same way when it exists' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { "$Filter" -match 'jdoe-a' } -MockWith {
            [pscustomobject]@{ SamAccountName='jdoe-a'; DistinguishedName='CN=Jane Doe (admin),OU=Users,DC=x'; Enabled=$true }
        }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        $r.Sam | Should -Be 'jdoe'   # the primary stays authoritative on the result
        ($r.Actions -join "`n") | Should -Match 'admin account check: found jdoe-a'
        ($r.Actions -join "`n") | Should -Match '\[jdoe-a\] disabled account'
        Should -Invoke Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -Times 2 -Exactly
    }

    It 'reports plainly when there is no -a account, and never offers candidates for it' {
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { "$Filter" -match 'jdoe-a' } -MockWith { @() }
        $r = Invoke-CtgADOffboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        ($r.Actions -join "`n") | Should -Match 'admin account check: no jdoe-a'
        $r.PSObject.Properties['Candidates'] | Should -BeNullOrEmpty
        Should -Invoke Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly
    }

    It 'does nothing extra when adminAccountSuffix is not configured' {
        $plain = [pscustomobject]@{ disableAccount = $true; guardrails = @('do-not-move-ou') }
        $r = Invoke-CtgADOffboarding -User $user -Config $plain
        ($r.Actions -join "`n") | Should -Not -Match 'admin account'
        Should -Invoke Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly
    }

    It 'refuses a suffix that is not a valid sam/UPN fragment' {
        $bad = [pscustomobject]@{ disableAccount = $true; adminAccountSuffix = "-a' OR x" }
        $r = Invoke-CtgADOffboarding -User $user -Config $bad
        ($r.Actions -join "`n") | Should -Match 'WARN admin-account check skipped'
        Should -Invoke Disable-ADAccount -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly
    }

    It 'strips the computer keys from the -a pass (the workstation is only handled once)' {
        Mock Get-ADComputer -ModuleName Coretelligent.ActiveDirectory -MockWith {
            [pscustomobject]@{ Name='PC1'; DistinguishedName='CN=PC1,OU=Comp,DC=x'; Enabled=$true }
        }
        Mock Get-ADUser -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { "$Filter" -match 'jdoe-a' } -MockWith {
            [pscustomobject]@{ SamAccountName='jdoe-a'; DistinguishedName='CN=Jane Doe (admin),OU=Users,DC=x'; Enabled=$true }
        }
        $cfg = [pscustomobject]@{ disableAccount = $true; adminAccountSuffix = '-a'; guardrails = @('do-not-move-ou'); disableComputer = $true; computerName = 'PC1' }
        $r = Invoke-CtgADOffboarding -User $user -Config $cfg
        Should -Invoke Get-ADComputer -ModuleName Coretelligent.ActiveDirectory -Times 1 -Exactly
    }
}
