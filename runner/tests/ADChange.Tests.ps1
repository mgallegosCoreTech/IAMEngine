#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Unit tests for Invoke-CtgADChange (the AD "change/mover" lane). The on-prem ActiveDirectory
# cmdlets aren't installed here, so we stub them globally and Mock in the module scope — same
# pattern as Coretelligent.ActiveDirectory.Tests.ps1. Focus: add groups, remove-by-name with a
# protected-group refusal, reconcile-to-desired, OU move, and attribute passthrough.

BeforeAll {
    $ModulePath = "$PSScriptRoot/../modules/Coretelligent.ActiveDirectory/Coretelligent.ActiveDirectory.psm1"

    # Param blocks so Pester -ParameterFilter can see the bound args. All stubs accept
    # $Server/$Credential — the module splats @AdConnection (brokered ad-dc auth) onto every cmdlet.
    function global:Get-ADUser { [CmdletBinding()] param($Filter, $Identity, $Properties, $Server, $Credential) }
    function global:Set-ADUser { [CmdletBinding()] param($Identity, $HomeDrive, $HomeDirectory, $Replace, $Clear, $Add, $Remove, $Manager, $EmailAddress, $OfficePhone, $ChangePasswordAtLogon, $Server, $Credential) }
    function global:Add-ADGroupMember { [CmdletBinding()] param($Identity, $Members, $Server, $Credential) }
    function global:Remove-ADGroupMember { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Members, $Server, $Credential) }
    function global:Get-ADPrincipalGroupMembership { [CmdletBinding()] param($Identity, $Server, $Credential) }
    function global:Get-ADGroup { [CmdletBinding()] param($Identity, $Filter, $Properties, $Server, $Credential) }
    function global:Move-ADObject { [CmdletBinding()] param($Identity, $TargetPath, $Server, $Credential) }

    Import-Module $ModulePath -Force
}

Describe 'Invoke-CtgADChange' {
    BeforeEach {
        Mock -CommandName Get-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { [pscustomobject]@{ SamAccountName = 'jdoe'; DistinguishedName = 'CN=jdoe,OU=Users,DC=x,DC=com' } }
        Mock -CommandName Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock -CommandName Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock -CommandName Set-ADUser -ModuleName Coretelligent.ActiveDirectory -MockWith { }
        Mock -CommandName Move-ADObject -ModuleName Coretelligent.ActiveDirectory -MockWith { }
    }

    It 'adds groups from config.groups' {
        $u = [pscustomobject]@{ SamAccountName = 'jdoe' }
        $c = [pscustomobject]@{ groups = @('Sales'); removeGroups = @() }
        $r = Invoke-CtgADChange -User $u -Config $c
        Should -Invoke Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -Times 1
        $r.Actions -join ';' | Should -Match 'added to group: Sales'
        $r.System | Should -Be 'active-directory'
        $r.Status | Should -Be 'ok'
    }

    It 'removes named groups but refuses a protected group' {
        Mock -CommandName Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith { @([pscustomobject]@{ Name = 'Support'; DistinguishedName = 'CN=Support,DC=x,DC=com' }, [pscustomobject]@{ Name = 'Domain Admins'; DistinguishedName = 'CN=Domain Admins,DC=x,DC=com' }) }
        $u = [pscustomobject]@{ SamAccountName = 'jdoe' }
        $c = [pscustomobject]@{ groups = @(); removeGroups = @('Support', 'Domain Admins') }
        $r = Invoke-CtgADChange -User $u -Config $c
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -Times 1  # only Support
        $r.Actions -join ';' | Should -Match 'refused protected group: Domain Admins'
    }

    It 'refuses to add a protected group from config.groups' {
        $u = [pscustomobject]@{ SamAccountName = 'jdoe' }
        $c = [pscustomobject]@{ groups = @('Domain Admins'); removeGroups = @() }
        $r = Invoke-CtgADChange -User $u -Config $c
        Should -Invoke Add-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -Times 0
        $r.Actions -join ';' | Should -Match 'refused protected group: Domain Admins'
    }

    It 'reconcile mode removes any current group not in desiredGroups (minus protected + Domain Users)' {
        Mock -CommandName Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith {
            @(
                [pscustomobject]@{ Name = 'Domain Users'; DistinguishedName = 'CN=Domain Users,DC=x,DC=com' },
                [pscustomobject]@{ Name = 'Sales'; DistinguishedName = 'CN=Sales,DC=x,DC=com' },
                [pscustomobject]@{ Name = 'Old Team'; DistinguishedName = 'CN=Old Team,DC=x,DC=com' },
                [pscustomobject]@{ Name = 'Domain Admins'; DistinguishedName = 'CN=Domain Admins,DC=x,DC=com' }
            )
        }
        $u = [pscustomobject]@{ SamAccountName = 'jdoe' }
        $c = [pscustomobject]@{ reconcileGroups = $true; desiredGroups = @('Sales') }
        $r = Invoke-CtgADChange -User $u -Config $c
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -Times 1 -ParameterFilter { $Identity -eq 'CN=Old Team,DC=x,DC=com' }
        Should -Invoke Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -ParameterFilter { $Identity -match 'Domain Admins' } -Times 0
        $r.Actions -join ';' | Should -Match 'removed from group: Old Team'
        $r.Actions -join ';' | Should -Not -Match 'removed from group: Sales'
        $r.Actions -join ';' | Should -Not -Match 'removed from group: Domain Users'
    }

    It 'logs a WARN (not a false success) when Remove-ADGroupMember throws' {
        Mock -CommandName Get-ADPrincipalGroupMembership -ModuleName Coretelligent.ActiveDirectory -MockWith { @([pscustomobject]@{ Name = 'Support'; DistinguishedName = 'CN=Support,DC=x,DC=com' }) }
        Mock -CommandName Remove-ADGroupMember -ModuleName Coretelligent.ActiveDirectory -MockWith { throw 'Access is denied' }
        $u = [pscustomobject]@{ SamAccountName = 'jdoe' }
        $c = [pscustomobject]@{ groups = @(); removeGroups = @('Support') }
        $r = Invoke-CtgADChange -User $u -Config $c
        $r.Actions -join ';' | Should -Match 'WARN could not remove from group Support: Access is denied'
        $r.Actions -join ';' | Should -Not -Match 'removed from group: Support'
    }

    It 'moves the user to moveToOu when it is a full DN' {
        $u = [pscustomobject]@{ SamAccountName = 'jdoe' }
        $c = [pscustomobject]@{ moveToOu = 'OU=NewTeam,DC=x,DC=com' }
        $r = Invoke-CtgADChange -User $u -Config $c
        Should -Invoke Move-ADObject -ModuleName Coretelligent.ActiveDirectory -Times 1 -ParameterFilter { $TargetPath -eq 'OU=NewTeam,DC=x,DC=com' -and $Identity -eq 'CN=jdoe,OU=Users,DC=x,DC=com' }
        $r.Actions -join ';' | Should -Match 'moved to OU=NewTeam,DC=x,DC=com'
    }

    It 'skips the move when moveToOu is not a full DN' {
        $u = [pscustomobject]@{ SamAccountName = 'jdoe' }
        $c = [pscustomobject]@{ moveToOu = 'NewTeam' }
        $r = Invoke-CtgADChange -User $u -Config $c
        Should -Invoke Move-ADObject -ModuleName Coretelligent.ActiveDirectory -Times 0
        $r.Actions -join ';' | Should -Match "skipped move: 'NewTeam' is not a full OU DN"
    }

    It 'applies attributes via Set-CtgADAttributes' {
        $u = [pscustomobject]@{ SamAccountName = 'jdoe' }
        $c = [pscustomobject]@{ attributes = [pscustomobject]@{ title = 'Senior Engineer' } }
        $r = Invoke-CtgADChange -User $u -Config $c
        Should -Invoke Set-ADUser -ModuleName Coretelligent.ActiveDirectory -Times 1 -ParameterFilter { $Identity -eq 'jdoe' -and $Replace.title -eq 'Senior Engineer' }
        $r.Actions -join ';' | Should -Match 'title=Senior Engineer'
    }
}
