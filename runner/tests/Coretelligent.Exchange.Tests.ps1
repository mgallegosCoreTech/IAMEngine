#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Unit tests for Coretelligent.Exchange. The Exchange Online (EXO V3) cmdlets aren't installed
# here, so we stub + mock them. Focus: convert-to-shared honoring the >50 GB skip, CAS disable,
# and the on-request OOO message.

BeforeAll {
    function global:Connect-ExchangeOnline { [CmdletBinding()] param($AppId, $Organization, $CertificateThumbprint, $CertificateFilePath, $CertificatePassword, [switch]$ShowBanner) }
    function global:Get-MailboxStatistics { [CmdletBinding()] param($Identity) }
    function global:Set-Mailbox { [CmdletBinding()] param($Identity, $Type, $ForwardingSmtpAddress, [switch]$DeliverToMailboxAndForward, $GrantSendOnBehalfTo, $HiddenFromAddressListsEnabled, [switch]$Confirm, $AuditEnabled, $AuditAdmin, $AuditDelegate, $AuditOwner) }
    # shared-mailbox permission mirror (EXO)
    function global:Get-MailboxPermission { [CmdletBinding()] param($Identity) }
    function global:Add-MailboxPermission { [CmdletBinding()] param($Identity, $User, $AccessRights, $InheritanceType, [switch]$AutoMapping, [switch]$Confirm) }
    function global:Get-RecipientPermission { [CmdletBinding()] param($Identity) }
    function global:Add-RecipientPermission { [CmdletBinding()] param($Identity, $Trustee, $AccessRights, [switch]$Confirm) }
    function global:Set-CASMailbox { [CmdletBinding()] param($Identity, $ActiveSyncEnabled, $OWAEnabled) }
    function global:Set-MailboxAutoReplyConfiguration { [CmdletBinding()] param($Identity, $AutoReplyState, $InternalMessage, $ExternalMessage) }
    # on-prem hybrid remote-mailbox + post-sync EXO finishing
    function global:Get-RemoteMailbox { [CmdletBinding()] param($Identity) }
    function global:Enable-RemoteMailbox { [CmdletBinding()] param($Identity, $RemoteRoutingAddress, $Alias, $DisplayName, $PrimarySmtpAddress) }
    function global:Set-RemoteMailbox { [CmdletBinding()] param($Identity, $EmailAddressPolicyEnabled, $Type) }
    function global:Set-MailboxRegionalConfiguration { [CmdletBinding()] param($Identity, $Language, $TimeZone) }
    function global:Add-MailboxFolderPermission { [CmdletBinding()] param($Identity, $User, $AccessRights, [switch]$Confirm) }
    function global:Set-MailboxFolderPermission { [CmdletBinding()] param($Identity, $User, $AccessRights, [switch]$Confirm) }
    function global:Get-MailboxFolderPermission { [CmdletBinding()] param($Identity, $User) }
    function global:Get-Mailbox { [CmdletBinding()] param($Identity, $RecipientTypeDetails, $ResultSize) }
    # distribution-list mirror (EXO)
    function global:Get-Recipient { [CmdletBinding()] param($Identity, $Filter, $ResultSize) }
    function global:Get-User { [CmdletBinding()] param($Identity) }
    function global:Get-MgUserManager { [CmdletBinding()] param($UserId) } # Entra manager link (Graph)
    function global:Add-DistributionGroupMember { [CmdletBinding()] param($Identity, $Member, [switch]$BypassSecurityGroupManagerCheck) }
    function global:Get-DistributionGroup { [CmdletBinding()] param($Identity, $ResultSize, $Filter) }
    function global:Get-DistributionGroupMember { [CmdletBinding()] param($Identity, $ResultSize) }
    function global:Remove-DistributionGroupMember { [CmdletBinding()] param($Identity, $Member, [switch]$BypassSecurityGroupManagerCheck, [switch]$Confirm) }
    function global:Add-UnifiedGroupLinks { [CmdletBinding()] param($Identity, $LinkType, $Links) }

    Import-Module "$PSScriptRoot/../modules/Coretelligent.Exchange/Coretelligent.Exchange.psm1" -Force
}

Describe 'Invoke-CtgExchangeSharedMailboxMirror' {
    It 'grants the new user the FullAccess / SendAs / SendOnBehalf the mirror user has' {
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'mirror@x.com' } -MockWith { [pscustomobject]@{ DisplayName='Mirror User'; PrimarySmtpAddress='mirror@x.com'; UserPrincipalName='mirror@x.com'; Name='Mirror User'; DistinguishedName='CN=Mirror,DC=x' } }
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'new@x.com' } -MockWith { [pscustomobject]@{ DisplayName='New User'; PrimarySmtpAddress='new@x.com'; UserPrincipalName='new@x.com'; Name='New User'; DistinguishedName='CN=New,DC=x' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $RecipientTypeDetails -eq 'SharedMailbox' } -MockWith {
            @(
                [pscustomobject]@{ DisplayName='Sales'; Identity='sales@x.com'; GrantSendOnBehalfTo=@('mirror@x.com') }
                [pscustomobject]@{ DisplayName='IT';    Identity='it@x.com';    GrantSendOnBehalfTo=@() }
            )
        }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { param($Identity) if ($Identity -eq 'sales@x.com') { @([pscustomobject]@{ User='mirror@x.com'; AccessRights=@('FullAccess'); IsInherited=$false }) } else { @() } }
        Mock Get-RecipientPermission -ModuleName Coretelligent.Exchange -MockWith { param($Identity) if ($Identity -eq 'sales@x.com') { @([pscustomobject]@{ Trustee='mirror@x.com'; AccessRights=@('SendAs') }) } else { @() } }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Add-RecipientPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Set-Mailbox -ModuleName Coretelligent.Exchange -MockWith { }

        $acts = Invoke-CtgExchangeSharedMailboxMirror -MirrorUser 'mirror@x.com' -NewUser 'new@x.com'

        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'sales@x.com' -and $User -eq 'new@x.com' -and ($AccessRights -contains 'FullAccess') } -Times 1
        Should -Invoke Add-RecipientPermission -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'sales@x.com' -and $Trustee -eq 'new@x.com' } -Times 1
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'sales@x.com' -and $GrantSendOnBehalfTo['Add'] -eq 'new@x.com' } -Times 1
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'it@x.com' } -Times 0 -Exactly  # mirror had nothing on IT
        ($acts -join ' ') | Should -Match 'granted FullAccess on shared mailbox sales@x.com \(Sales\) — mirrored from mirror@x.com'
    }

    It 'is idempotent — skips a permission the target already holds' {
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'mirror@x.com' } -MockWith { [pscustomobject]@{ DisplayName='Mirror'; PrimarySmtpAddress='mirror@x.com'; UserPrincipalName='mirror@x.com' } }
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'new@x.com' } -MockWith { [pscustomobject]@{ DisplayName='New'; PrimarySmtpAddress='new@x.com'; UserPrincipalName='new@x.com' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $RecipientTypeDetails -eq 'SharedMailbox' } -MockWith { @([pscustomobject]@{ DisplayName='Sales'; Identity='sales@x.com'; GrantSendOnBehalfTo=@() }) }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @(
            [pscustomobject]@{ User='mirror@x.com'; AccessRights=@('FullAccess'); IsInherited=$false }
            [pscustomobject]@{ User='new@x.com';    AccessRights=@('FullAccess'); IsInherited=$false }
        ) }
        Mock Get-RecipientPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }

        $acts = Invoke-CtgExchangeSharedMailboxMirror -MirrorUser 'mirror@x.com' -NewUser 'new@x.com'
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        ($acts -join ' ') | Should -Match 'already FullAccess: Sales'
    }
}

Describe 'Invoke-CtgExchangeSharedMailboxMirrorBounded' {
    It 'returns the mirror actions when the bounded run finishes within the budget' {
        # Stand in a REAL, already-finished job (a Start-Job avoids the real EXO-reconnecting child
        # scriptblock while still being a genuine Job the real Receive-/Remove-Job can bind + read).
        Mock Start-ThreadJob -ModuleName Coretelligent.Exchange -MockWith {
            Start-Job -ScriptBlock { 'granted FullAccess on shared mailbox sales@x.com (Sales) — mirrored from mirror@x.com' } | Wait-Job
        }
        $acts = Invoke-CtgExchangeSharedMailboxMirrorBounded -MirrorUser 'mirror@x.com' -NewUser 'new@x.com' -AppId 'app' -Organization 'x.com' -TimeBudgetSeconds 30 -PollSeconds 0
        ($acts -join ' ') | Should -Match 'granted FullAccess on shared mailbox sales@x.com'
    }

    It 'abandons the run and WARNs (never blocks the onboard) when the budget is exceeded' {
        # A REAL long-running job + a zero budget -> the wait falls straight through to the abandon branch,
        # which Stop/Remove-Jobs it. Asserts the onboard is handed a best-effort WARN, never left blocking.
        Mock Start-ThreadJob -ModuleName Coretelligent.Exchange -MockWith { Start-Job -ScriptBlock { Start-Sleep -Seconds 999 } }
        $acts = Invoke-CtgExchangeSharedMailboxMirrorBounded -MirrorUser 'mirror@x.com' -NewUser 'new@x.com' -AppId 'app' -Organization 'x.com' -TimeBudgetSeconds 0 -PollSeconds 0
        ($acts -join ' ') | Should -Match 'exceeded 0s and was abandoned'
    }

    It 'falls back to the inline mirror when no connection args are supplied (no regression)' {
        Mock Start-ThreadJob -ModuleName Coretelligent.Exchange -MockWith { throw 'ThreadJob should not be used on the inline fallback' }
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ DisplayName='Mirror'; PrimarySmtpAddress='mirror@x.com'; UserPrincipalName='mirror@x.com' } }
        Mock Get-Mailbox   -ModuleName Coretelligent.Exchange -ParameterFilter { $RecipientTypeDetails -eq 'SharedMailbox' } -MockWith { @() }

        # No -AppId / -Organization -> inline path (calls the real mirror, which finds 0 shared mailboxes).
        $acts = Invoke-CtgExchangeSharedMailboxMirrorBounded -MirrorUser 'mirror@x.com' -NewUser 'new@x.com'

        ($acts -join ' ') | Should -Match 'shared-mailbox mirror from mirror@x.com: 0 FullAccess'
        Should -Invoke Start-ThreadJob -ModuleName Coretelligent.Exchange -Times 0 -Exactly
    }
}

Describe 'Invoke-CtgExchangeDefaultMailboxAccess' {
    BeforeEach {
        # Target user (the new hire) — one Get-Recipient lookup by NewUser.
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'new@x.com' } -MockWith { [pscustomobject]@{ DisplayName='New User'; PrimarySmtpAddress='new@x.com'; UserPrincipalName='new@x.com' } }
        # Named-mailbox lookups by -Identity (address).
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'finance@x.com' } -MockWith { [pscustomobject]@{ DisplayName='Finance'; PrimarySmtpAddress='finance@x.com'; ExchangeGuid='11111111-1111-1111-1111-111111111111'; Identity='finance@x.com'; GrantSendOnBehalfTo=@() } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'vacation@x.com' } -MockWith { [pscustomobject]@{ DisplayName='Global Vacation Calendar'; PrimarySmtpAddress='vacation@x.com'; ExchangeGuid='22222222-2222-2222-2222-222222222222'; Identity='vacation@x.com'; GrantSendOnBehalfTo=@() } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'missing@x.com' } -MockWith { $null }
        # The bare-string entry. Its mock was missing, so the call matched no filter and — since Pester 6
        # removed the fall-through to the real command — threw "No mock for command 'Get-Mailbox'
        # matched the call". That is why this Describe's first test failed; the product was never
        # involved. Worth keeping distinct from 'missing@x.com': that one returns $null on purpose to
        # exercise the not-found WARN, so reusing it would have hidden the bare-string case behind a
        # warning instead of granting anything.
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'plainstring@x.com' } -MockWith { [pscustomobject]@{ DisplayName='Plain String'; PrimarySmtpAddress='plainstring@x.com'; ExchangeGuid='33333333-3333-3333-3333-333333333333'; Identity='plainstring@x.com'; GrantSendOnBehalfTo=@() } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Get-RecipientPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Add-RecipientPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Set-Mailbox -ModuleName Coretelligent.Exchange -MockWith { }
    }

    It 'grants FullAccess by default and routes SendAs / SendOnBehalf by the access field' {
        $acts = Invoke-CtgExchangeDefaultMailboxAccess -NewUser 'new@x.com' -Mailboxes @(
            @{ address='finance@x.com'; access='FullAccess' }
            @{ address='vacation@x.com'; access='SendAs' }
            'plainstring@x.com'  # a bare string defaults to FullAccess
        )
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq '11111111-1111-1111-1111-111111111111' -and $User -eq 'new@x.com' -and ($AccessRights -contains 'FullAccess') } -Times 1
        Should -Invoke Add-RecipientPermission -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq '22222222-2222-2222-2222-222222222222' -and $Trustee -eq 'new@x.com' } -Times 1
        ($acts -join ' ') | Should -Match 'default shared mailbox FullAccess: Finance'
        ($acts -join ' ') | Should -Match 'default shared mailbox SendAs: Global Vacation Calendar'
        # The bare string. The test named this case and passed it in, then asserted nothing about it —
        # so "a bare string defaults to FullAccess", stated here and in the function's own .NOTES, was
        # documented in two places and verified in none. It is a real branch: $entry -is [string] picks
        # both the address AND the access level, and nothing else exercises that pair.
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq '33333333-3333-3333-3333-333333333333' -and $User -eq 'new@x.com' -and ($AccessRights -contains 'FullAccess') } -Times 1
        ($acts -join ' ') | Should -Match 'default shared mailbox FullAccess: Plain String'
    }

    It 'grants SendOnBehalf via Set-Mailbox' {
        $acts = Invoke-CtgExchangeDefaultMailboxAccess -NewUser 'new@x.com' -Mailboxes @(@{ address='finance@x.com'; access='SendOnBehalf' })
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $GrantSendOnBehalfTo['Add'] -eq 'new@x.com' } -Times 1
        ($acts -join ' ') | Should -Match 'default shared mailbox SendOnBehalf: Finance'
    }

    It 'is idempotent — skips a mailbox the target already has FullAccess on' {
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @([pscustomobject]@{ User='new@x.com'; AccessRights=@('FullAccess'); IsInherited=$false }) }
        $acts = Invoke-CtgExchangeDefaultMailboxAccess -NewUser 'new@x.com' -Mailboxes @(@{ address='finance@x.com'; access='FullAccess' })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        ($acts -join ' ') | Should -Match 'already FullAccess: Finance'
    }

    It 'warns (does not throw) when a named mailbox is not found' {
        $acts = Invoke-CtgExchangeDefaultMailboxAccess -NewUser 'new@x.com' -Mailboxes @(@{ address='missing@x.com'; access='FullAccess' })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        ($acts -join ' ') | Should -Match 'WARN default shared mailbox not found in Exchange Online: missing@x.com'
    }

    It 'returns nothing for an empty list' {
        $acts = Invoke-CtgExchangeDefaultMailboxAccess -NewUser 'new@x.com' -Mailboxes @()
        @($acts).Count | Should -Be 0
    }
}

Describe 'Invoke-CtgExchangeMailboxAudit' {
    BeforeEach {
        Mock Set-Mailbox -ModuleName Coretelligent.Exchange -MockWith { }
    }

    It 'applies the configured audit flags' {
        $cfg = [pscustomobject]@{ enabled = $true; auditAdmin = @('copy', 'create'); auditDelegate = @('create'); auditOwner = @('create', 'mailboxlogin') }
        $r = Invoke-CtgExchangeMailboxAudit -Upn 'new.user@x.com' -Config $cfg
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $AuditEnabled -eq $true -and ($AuditAdmin -contains 'copy') -and ($AuditOwner -contains 'mailboxlogin') }
        ($r -join "`n") | Should -Match 'enabled mailbox auditing'
    }

    It 'refuses unknown audit actions (allowlist)' {
        $cfg = [pscustomobject]@{ enabled = $true; auditOwner = @('create', 'Invoke-Expression') }
        $r = Invoke-CtgExchangeMailboxAudit -Upn 'new.user@x.com' -Config $cfg
        ($r -join "`n") | Should -Match 'WARN'
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { -not ($AuditOwner -contains 'Invoke-Expression') }
    }

    It 'does nothing when not enabled' {
        (Invoke-CtgExchangeMailboxAudit -Upn 'x@x.com' -Config ([pscustomobject]@{ enabled = $false })).Count | Should -Be 0
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 0
    }

    It 'WARNs and skips Set-Mailbox entirely when a configured list is empty after allowlist filtering' {
        $cfg = [pscustomobject]@{ enabled = $true; auditOwner = @('Invoke-Expression', 'rm-rf') }
        $r = Invoke-CtgExchangeMailboxAudit -Upn 'new.user@x.com' -Config $cfg
        ($r -join "`n") | Should -Match 'WARN'
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 0
    }
}

Describe 'Invoke-CtgExchangeCalendarReviewers' {
    BeforeEach {
        Mock Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Set-MailboxFolderPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Get-MailboxFolderPermission -ModuleName Coretelligent.Exchange -MockWith { $null }
    }

    It 'grants each configured reviewer on the calendar' {
        $rs = @([pscustomobject]@{ user = 'calendar.delegate.reviewer@logicsource.com'; accessRights = 'Reviewer' })
        $r = Invoke-CtgExchangeCalendarReviewers -Identity 'new.user@logicsource.com' -Reviewers $rs
        Should -Invoke Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $Identity -eq 'new.user@logicsource.com:\Calendar' -and $User -eq 'calendar.delegate.reviewer@logicsource.com' -and $AccessRights -eq 'Reviewer' }
        ($r -join "`n") | Should -Match 'granted calendar.delegate.reviewer@logicsource.com Reviewer on calendar'
    }

    It 'skips a grant the user already holds (idempotent)' {
        Mock Get-MailboxFolderPermission -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ User = 'calendar.delegate.reviewer@logicsource.com'; AccessRights = @('Reviewer') } }
        $r = Invoke-CtgExchangeCalendarReviewers -Identity 'u@x.com' -Reviewers @([pscustomobject]@{ user = 'calendar.delegate.reviewer@logicsource.com' })
        Should -Invoke Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -Times 0
        ($r -join "`n") | Should -Match 'already holds Reviewer on calendar'
    }

    It 'CHANGES an existing permission at a different right instead of failing the grant (FR #0000135)' {
        # Add- refuses outright when any entry already exists ("An existing permission entry was found
        # for user"), and AvailabilityOnly is a right plenty of mailboxes already carry, so this was
        # the ordinary case rather than an edge one.
        Mock Get-MailboxFolderPermission -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ User = 'd@x.com'; AccessRights = @('AvailabilityOnly') } }
        $r = Invoke-CtgExchangeCalendarReviewers -Identity 'u@x.com' -Reviewers @([pscustomobject]@{ user = 'd@x.com'; accessRights = 'Reviewer' })
        Should -Invoke Set-MailboxFolderPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $Identity -eq 'u@x.com:\Calendar' -and $User -eq 'd@x.com' -and $AccessRights -eq 'Reviewer' }
        Should -Invoke Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -Times 0
        ($r -join "`n") | Should -Match 'changed d@x.com from AvailabilityOnly to Reviewer'
        ($r -join "`n") | Should -Not -Match 'WARN'
    }

    It 'recovers when the pre-read misses an entry that Add- then rejects' {
        # The read says nothing is there; Add- disagrees. A denied/filtered read or a concurrent change
        # both look like this, and a re-run must not fail on it.
        Mock Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -MockWith { throw 'An existing permission entry was found for user: d@x.com.' }
        $r = Invoke-CtgExchangeCalendarReviewers -Identity 'u@x.com' -Reviewers @([pscustomobject]@{ user = 'd@x.com'; accessRights = 'Editor' })
        Should -Invoke Set-MailboxFolderPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $AccessRights -eq 'Editor' }
        ($r -join "`n") | Should -Match 'set d@x.com to Editor on calendar \(an entry already existed\)'
        ($r -join "`n") | Should -Not -Match 'WARN'
    }

    It 'still WARNs (does not silently pass) when Add- fails for a real reason' {
        Mock Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -MockWith { throw 'The user d@x.com was not found.' }
        $r = Invoke-CtgExchangeCalendarReviewers -Identity 'u@x.com' -Reviewers @([pscustomobject]@{ user = 'd@x.com' })
        Should -Invoke Set-MailboxFolderPermission -ModuleName Coretelligent.Exchange -Times 0
        ($r -join "`n") | Should -Match 'WARN calendar reviewer grant failed for d@x.com'
    }

    It 'falls back to Reviewer for an unlisted accessRights value' {
        $r = Invoke-CtgExchangeCalendarReviewers -Identity 'u@x.com' -Reviewers @([pscustomobject]@{ user = 'd@x.com'; accessRights = 'Owner' })
        Should -Invoke Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $AccessRights -eq 'Reviewer' }
        ($r -join "`n") | Should -Match 'WARN.*unrecognized accessRights .Owner.'
    }

    It 'accepts a bare-string entry as a user with the default right' {
        $r = Invoke-CtgExchangeCalendarReviewers -Identity 'u@x.com' -Reviewers @('plain@x.com')
        Should -Invoke Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $User -eq 'plain@x.com' -and $AccessRights -eq 'Reviewer' }
    }

    It 'does nothing when Reviewers is empty or absent' {
        (Invoke-CtgExchangeCalendarReviewers -Identity 'u@x.com' -Reviewers @()).Count | Should -Be 0
        (Invoke-CtgExchangeCalendarReviewers -Identity 'u@x.com').Count | Should -Be 0
        Should -Invoke Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -Times 0
    }

    It 'WARNs (not throws) when the grant fails' {
        Mock Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -MockWith { throw 'user not found' }
        $r = Invoke-CtgExchangeCalendarReviewers -Identity 'u@x.com' -Reviewers @([pscustomobject]@{ user = 'ghost@x.com' })
        ($r -join "`n") | Should -Match 'WARN calendar reviewer grant failed for ghost@x.com'
    }
}

Describe 'Invoke-CtgExchangeDistListMirror' {
    It 'adds the new user to the reference user''s distribution + mail-enabled security groups (static only)' {
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'Christine Holleran' } -MockWith { [pscustomobject]@{ DisplayName = 'Christine Holleran'; DistinguishedName = 'CN=Christine,DC=x' } }
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Filter -like '*Members*' } -MockWith {
            @(
                [pscustomobject]@{ DisplayName = 'Billing Team'; Identity = 'Billing Team'; RecipientTypeDetails = 'MailUniversalDistributionGroup'; IsDirSynced = $false }
                [pscustomobject]@{ DisplayName = 'Sec Mail';     Identity = 'Sec Mail';     RecipientTypeDetails = 'MailUniversalSecurityGroup'; IsDirSynced = $false }
                [pscustomobject]@{ DisplayName = 'Dynamic DL';   Identity = 'Dynamic DL';   RecipientTypeDetails = 'DynamicDistributionGroup'; IsDirSynced = $false }
                [pscustomobject]@{ DisplayName = 'Core-ALL';     Identity = 'Core-ALL';     RecipientTypeDetails = 'MailUniversalDistributionGroup'; IsDirSynced = $true }
            )
        }
        Mock Add-DistributionGroupMember -ModuleName Coretelligent.Exchange -MockWith { }
        $acts = Invoke-CtgExchangeDistListMirror -MirrorUser 'Christine Holleran' -NewUser 'aanand@core.tech'
        # 2 cloud-only static groups added; the dynamic one is filtered, the dir-synced one is the AD lane's.
        Should -Invoke Add-DistributionGroupMember -ModuleName Coretelligent.Exchange -Times 2 -Exactly
        ($acts -join ' ') | Should -Match 'mirrored group: Billing Team'
        ($acts -join ' ') | Should -Not -Match 'Core-ALL'
        ($acts -join ' ') | Should -Match '2 added,'
    }

    It 'warns when the mirror user is not found in Exchange' {
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -MockWith { $null }
        $acts = Invoke-CtgExchangeDistListMirror -MirrorUser 'Ghost' -NewUser 'aanand@core.tech'
        ($acts -join ' ') | Should -Match 'mirror user not found in Exchange'
    }
}

Describe 'Invoke-CtgExchangeOffboarding' {
    BeforeEach {
        $user = [pscustomobject]@{ UserPrincipalName = 'jdoe@61commodities.com' }
        Mock Set-Mailbox -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Set-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Set-MailboxAutoReplyConfiguration -ModuleName Coretelligent.Exchange -MockWith { }
        # Default: the target HAS an EXO mailbox (so the EXO-only steps run). A MailUser test overrides this.
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox' } }
    }

    It 'converts the mailbox to shared when under the size threshold' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '10 GB (10,737,418,240 bytes)' } }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        $r.MailboxSizeGB | Should -Be 10
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 1 -Exactly -ParameterFilter { $Type -eq 'Shared' }
        Should -Invoke Set-CASMailbox -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $ActiveSyncEnabled -eq $false }
    }

    It 'MailUser (on-prem mailbox): converts on-prem, SKIPS the EXO-only steps, does not crash' {
        # EXO sees a MailUser (no mailbox) — the EXO cmdlets would throw "does not support this recipient
        # type". Convert runs on-prem (Set-RemoteMailbox); CAS/autoreply/delegate are skipped with a note.
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { $null }   # MailUser -> no EXO mailbox
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '0 GB (0 bytes)' } }
        Mock Get-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Identity = 'jdoe@61commodities.com' } }
        Mock Set-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true; delegateManagerFullAccess = $true; removeDistributionGroups = $false }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        Should -Invoke Set-RemoteMailbox -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $Type -eq 'Shared' }
        Should -Invoke Set-CASMailbox -ModuleName Coretelligent.Exchange -Times 0 -Exactly   # EXO-only, skipped
        ($r.Actions -join ' ') | Should -Match 'MailUser'
    }

    # This used to return Status='ok' — a GREEN offboard step for a mailbox nobody touched. An offboard
    # that cannot even identify whose mailbox to convert must fail loudly, and must still touch nothing.
    It 'fails loudly (touching nothing) when the case has no user identity' {
        { Invoke-CtgExchangeOffboarding -User ([pscustomobject]@{ UserPrincipalName = '' }) -Config ([pscustomobject]@{ convertToShared = [pscustomobject]@{} }) } |
            Should -Throw -ExpectedMessage '*no UPN, email or name*'
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 0 -Exactly
    }

    It 'resolves the offboard target by display name (Get-Recipient) when the case has no UPN' {
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ PrimarySmtpAddress = 'jpark@61commodities.com'; DisplayName = 'Jordan Park' } }
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '5 GB (5,368,709,120 bytes)' } }
        $r = Invoke-CtgExchangeOffboarding -User ([pscustomobject]@{ UserPrincipalName = ''; DisplayName = 'Jordan Park' }) -Config ([pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 } })
        ($r.Actions -join ' ') | Should -Match "resolved offboard target by display name 'Jordan Park'"
        $r.Upn | Should -Be 'jpark@61commodities.com'
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $Type -eq 'Shared' }
    }

    It 'converts a HYBRID (on-prem-mastered) mailbox via Set-RemoteMailbox + triggers a delta sync' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '10 GB (10,737,418,240 bytes)' } }
        # On-prem session present: Get-RemoteMailbox returns the object -> the on-prem path.
        Mock Get-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Identity = 'jdoe@61commodities.com' } }
        Mock Set-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { }
        $state = @{ synced = $false }                              # mutated by the trigger (a closure)
        $trigger = { $state.synced = $true }.GetNewClosure()
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 } }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config $config -TriggerSync $trigger
        Should -Invoke Set-RemoteMailbox -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $Type -eq 'Shared' }
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 0 -Exactly -ParameterFilter { $Type -eq 'Shared' }
        $state.synced | Should -BeTrue
        ($r.Actions -join ' ') | Should -Match 'on-prem'
    }

    It 'does NOT convert when the mailbox is over the threshold (keeps it + license)' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '75 GB (80,530,636,800 bytes)' } }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 } }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config $config
        $r.MailboxSizeGB | Should -Be 75
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 0 -Exactly -ParameterFilter { $Type -eq 'Shared' }
        ($r.Actions -join ' ') | Should -Match 'over threshold'
    }

    # FR #27: a mailbox that is ALREADY shared must unblock the license step (which keys off this exact
    # phrase) even when convertToShared isn't configured at all on the case — offboard payloads carry
    # only `userToOffboard` (no UPN), so this exercises that shape directly.
    It 'reports an already-shared mailbox as converted and does not convert again (no convert config at all)' {
        # -Config is Mandatory typed [pscustomobject] — an explicit $null fails parameter binding, so
        # "no convert config at all" is expressed the same way the rest of this suite does: an empty
        # object. Get-CtgProp reads 'convertToShared' off it as $null either way.
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'SharedMailbox' } }
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '10 GB (10,737,418,240 bytes)' } }
        $r = Invoke-CtgExchangeOffboarding -User ([pscustomobject]@{ userToOffboard = 'jane.doe@x.com' }) -Config ([pscustomobject]@{})
        ($r.Actions -join "`n") | Should -Match 'already a shared mailbox'
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 0 -ParameterFilter { $Type -eq 'Shared' }
    }

    It 'skips the redundant convert-to-shared call when the mailbox is already shared, even though convertToShared IS configured' {
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'SharedMailbox' } }
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '10 GB (10,737,418,240 bytes)' } }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 } }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config $config
        ($r.Actions -join "`n") | Should -Match 'already a shared mailbox'
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 0 -Exactly -ParameterFilter { $Type -eq 'Shared' }
    }

    It 'sets an out-of-office message when one is provided (on request)' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        $config = [pscustomobject]@{ autoReply = [pscustomobject]@{ message = 'No longer with the company.' } }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config $config
        Should -Invoke Set-MailboxAutoReplyConfiguration -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $AutoReplyState -eq 'Enabled' }
    }

    It 'grants the case manager Full Access (AutoMapping) when delegateManagerFullAccess is set' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }   # not yet delegated
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        $u = [pscustomobject]@{ UserPrincipalName = 'jdoe@61commodities.com'; ManagerEmail = 'boss@61commodities.com' }
        $r = Invoke-CtgExchangeOffboarding -User $u -Config ([pscustomobject]@{ delegateManagerFullAccess = $true })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $User -eq 'boss@61commodities.com' -and @($AccessRights) -contains 'FullAccess' -and $AutoMapping }
        ($r.Actions -join ' ') | Should -Match 'granted manager boss@61commodities.com Full Access'
    }

    # FR #7: the intake names a delegate ("provide mailbox access to Peter Hegland") — planned onto
    # the config as grantFullAccessTo. The NAME is resolved to a mailbox before anything is granted.
    It 'grants the case-requested delegate Full Access, resolving a display name' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Resolve-CtgAddressByDisplayName -ModuleName Coretelligent.Exchange -MockWith { 'phegland@61commodities.com' }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ grantFullAccessTo = 'Peter Hegland' })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $User -eq 'phegland@61commodities.com' -and @($AccessRights) -contains 'FullAccess' -and $AutoMapping }
        ($r.Actions -join ' ') | Should -Match "resolved case-requested delegate 'Peter Hegland'"
    }

    It 'warns (and grants nothing) when the case-requested delegate name matches no single mailbox' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Resolve-CtgAddressByDisplayName -ModuleName Coretelligent.Exchange -MockWith { $null }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ grantFullAccessTo = 'Pete Hegland' })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        ($r.Actions -join ' ') | Should -Match 'WARN the case asks for mailbox access'
    }

    # FR #84: several delegates. The config carries a STRING for one (the case above, unchanged) and an
    # ARRAY when the ticket named more than one.
    It 'grants EVERY delegate the ticket named' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ grantFullAccessTo = @('phegland@61commodities.com', 'dgani@61commodities.com') })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $User -eq 'phegland@61commodities.com' }
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $User -eq 'dgani@61commodities.com' }
        ($r.Actions -join ' ') | Should -Match 'granted case-requested delegate phegland@61commodities.com'
        ($r.Actions -join ' ') | Should -Match 'granted case-requested delegate dgani@61commodities.com'
    }

    # The whole point of per-delegate isolation: a typo in one row must not cost the OTHER people their
    # access. Before this, one unresolvable name was the only name, so it failed alone; in a list it
    # would take the rest down with it if the loop bailed.
    It 'one unresolvable delegate does not stop the others being granted' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Resolve-CtgAddressByDisplayName -ModuleName Coretelligent.Exchange -MockWith { $null }  # the NAME never resolves
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ grantFullAccessTo = @('Nobody Atall', 'dgani@61commodities.com') })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $User -eq 'dgani@61commodities.com' }
        ($r.Actions -join ' ') | Should -Match "WARN the case asks for mailbox access for 'Nobody Atall'"
        ($r.Actions -join ' ') | Should -Match 'granted case-requested delegate dgani@61commodities.com'
    }

    It 'a failed grant for one delegate does not stop the next' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith {
            if ($User -eq 'phegland@61commodities.com') { throw 'Exchange said no' }
        }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ grantFullAccessTo = @('phegland@61commodities.com', 'dgani@61commodities.com') })
        ($r.Actions -join ' ') | Should -Match 'WARN could not grant phegland@61commodities.com Full Access'
        ($r.Actions -join ' ') | Should -Match 'granted case-requested delegate dgani@61commodities.com'
    }

    It 'blank entries in the delegate list are ignored, not resolved' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Resolve-CtgAddressByDisplayName -ModuleName Coretelligent.Exchange -MockWith { $null }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ grantFullAccessTo = @('', '   ', 'dgani@61commodities.com') })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -Exactly
        Should -Invoke Resolve-CtgAddressByDisplayName -ModuleName Coretelligent.Exchange -Times 0 -Exactly
    }

    # FR #0000211: the client (config.offboard.delegateAutoMapping) or the case can grant a delegate
    # Full Access WITHOUT adding the mailbox to their Outlook. Unset stays on (the tests above).
    It 'grants both delegates with AutoMapping OFF when delegateAutoMapping is false' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        $u = [pscustomobject]@{ UserPrincipalName = 'jdoe@61commodities.com'; ManagerEmail = 'boss@61commodities.com' }
        $r = Invoke-CtgExchangeOffboarding -User $u -Config ([pscustomobject]@{ delegateManagerFullAccess = $true; grantFullAccessTo = 'dgani@61commodities.com'; delegateAutoMapping = $false })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -Exactly -ParameterFilter { $User -eq 'boss@61commodities.com' -and -not $AutoMapping }
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -Exactly -ParameterFilter { $User -eq 'dgani@61commodities.com' -and -not $AutoMapping }
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 0 -Exactly -ParameterFilter { $AutoMapping }
        ($r.Actions -join ' ') | Should -Match 'granted manager boss@61commodities.com Full Access to the mailbox \(AutoMapping off'
        ($r.Actions -join ' ') | Should -Match 'granted case-requested delegate dgani@61commodities.com Full Access to the mailbox \(AutoMapping off'
    }

    It 'delegateAutoMapping true keeps AutoMapping on' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ grantFullAccessTo = 'dgani@61commodities.com'; delegateAutoMapping = $true })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -Exactly -ParameterFilter { $User -eq 'dgani@61commodities.com' -and $AutoMapping }
        ($r.Actions -join ' ') | Should -Match '\(AutoMapping on\)'
    }

    It 'a hand-edited "false" string still turns AutoMapping off' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        $null = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ grantFullAccessTo = 'dgani@61commodities.com'; delegateAutoMapping = 'false' })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -Exactly -ParameterFilter { -not $AutoMapping }
    }

    It 'says an existing grant keeps its AutoMapping when the case asks for it off' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @([pscustomobject]@{ User = 'dgani@61commodities.com'; AccessRights = @('FullAccess') }) }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ grantFullAccessTo = 'dgani@61commodities.com'; delegateAutoMapping = $false })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        ($r.Actions -join ' ') | Should -Match 'already has Full Access — no change \(AutoMapping stays as it was'
    }

    It 'is idempotent — no re-grant when the manager already has Full Access' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @([pscustomobject]@{ User = 'boss@61commodities.com'; AccessRights = @('FullAccess') }) }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        $u = [pscustomobject]@{ UserPrincipalName = 'jdoe@61commodities.com'; ManagerEmail = 'boss@61commodities.com' }
        $r = Invoke-CtgExchangeOffboarding -User $u -Config ([pscustomobject]@{ delegateManagerFullAccess = $true })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        ($r.Actions -join ' ') | Should -Match 'already has Full Access'
    }

    It 'removes the user from CLOUD distribution lists, skipping on-prem-synced ones' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-DistributionGroup -ModuleName Coretelligent.Exchange -MockWith {
            @(
                [pscustomobject]@{ Identity = 'cloud-dl'; DisplayName = 'Notifications'; IsDirSynced = $false }
                [pscustomobject]@{ Identity = 'synced-dl'; DisplayName = 'TechStaff'; IsDirSynced = $true }   # on-prem -> AD removes it
            )
        }
        Mock Get-DistributionGroupMember -ModuleName Coretelligent.Exchange -MockWith { @([pscustomobject]@{ PrimarySmtpAddress = 'jdoe@61commodities.com' }) }
        Mock Remove-DistributionGroupMember -ModuleName Coretelligent.Exchange -MockWith { }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ removeDistributionGroups = $true })
        # only the cloud DL is touched; the synced one is skipped (filtered out before the member check)
        Should -Invoke Remove-DistributionGroupMember -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'cloud-dl' } -Times 1 -Exactly
        Should -Invoke Remove-DistributionGroupMember -ModuleName Coretelligent.Exchange -Times 1 -Exactly
        ($r.Actions -join ' ') | Should -Match 'removed from cloud distribution list: Notifications'
    }

    It 'looks the manager up from the DIRECTORY when the case has none, and grants Full Access' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Get-User -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Manager = 'Patrick Breitner' } }
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ PrimarySmtpAddress = 'pbreitner@core.tech' } }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ delegateManagerFullAccess = $true })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $User -eq 'pbreitner@core.tech' -and @($AccessRights) -contains 'FullAccess' }
        ($r.Actions -join ' ') | Should -Match 'resolved manager from the directory: pbreitner@core.tech'
    }

    It 'resolves the manager from Entra (Graph) when Exchange Get-User.Manager is blank' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        # Exchange's own view has no manager, but Entra (Graph) does — the real-world INC0841839 case.
        Mock Get-User -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Manager = '' } }
        # AdditionalProperties as a generic Dictionary — exactly what Graph returns (NOT a [hashtable]),
        # so this also guards Get-CtgProp's IDictionary handling.
        $mgrDict = [System.Collections.Generic.Dictionary[string, object]]::new()
        $mgrDict['mail'] = 'boss@core.tech'; $mgrDict['userPrincipalName'] = 'boss@core.tech'
        Mock Get-MgUserManager -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ AdditionalProperties = $mgrDict } }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ delegateManagerFullAccess = $true })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $User -eq 'boss@core.tech' -and @($AccessRights) -contains 'FullAccess' }
        ($r.Actions -join ' ') | Should -Match 'resolved manager from the directory: boss@core.tech'
    }

    It 'warns (does not fail) when delegateManagerFullAccess is set but no manager on the case OR directory' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Get-User -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Manager = '' } }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config ([pscustomobject]@{ delegateManagerFullAccess = $true })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        ($r.Actions -join ' ') | Should -Match 'no manager on the case'
    }

    It "uses the intake's managerName (a NAME, not an address) when the directory link is gone — INC0859438" {
        # The real failure: the AD offboard step had already CLEARED the manager link, so every
        # directory lookup came back empty — while the case form named the manager all along.
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { @() }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Get-User -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Manager = '' } }   # link cleared
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Filter -match 'Elizabeth McPhillips' } -MockWith {
            [pscustomobject]@{ PrimarySmtpAddress = 'emcphillips@core.tech' }
        }
        $u = [pscustomobject]@{ UserPrincipalName = 'ahoule@core.tech'; managerName = 'Elizabeth McPhillips' }
        $r = Invoke-CtgExchangeOffboarding -User $u -Config ([pscustomobject]@{ delegateManagerFullAccess = $true })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $User -eq 'emcphillips@core.tech' -and @($AccessRights) -contains 'FullAccess' }
        ($r.Actions -join ' ') | Should -Match "resolved manager 'Elizabeth McPhillips' from the case -> emcphillips@core.tech"
    }

    It 'never guesses when a manager NAME matches several mailboxes' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Add-MailboxPermission -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Get-User -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Manager = '' } }
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -MockWith {
            @([pscustomobject]@{ PrimarySmtpAddress = 'jsmith@core.tech' }, [pscustomobject]@{ PrimarySmtpAddress = 'jsmith2@core.tech' })
        }
        $u = [pscustomobject]@{ UserPrincipalName = 'ahoule@core.tech'; managerName = 'John Smith' }
        $r = Invoke-CtgExchangeOffboarding -User $u -Config ([pscustomobject]@{ delegateManagerFullAccess = $true })
        Should -Invoke Add-MailboxPermission -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        ($r.Actions -join ' ') | Should -Match "names manager 'John Smith' but no single matching mailbox"
    }
}

Describe 'Connect-CtgExchange' {
    It 'connects app-only with a thumbprint on a Windows runner' {
        InModuleScope Coretelligent.Exchange {
            $IsWindows = $true   # simulate Windows so the cert-store path is allowed
            Mock Connect-ExchangeOnline -MockWith { }
            Connect-CtgExchange -AppId 'app-1' -Organization '61commodities.com' -CertificateThumbprint 'ABC123'
            Should -Invoke Connect-ExchangeOnline -Times 1 -ParameterFilter { $Organization -eq '61commodities.com' -and $CertificateThumbprint -eq 'ABC123' }
        }
    }

    It 'refuses a thumbprint on a non-Windows runner — points to CertificateBase64' {
        InModuleScope Coretelligent.Exchange {
            $IsWindows = $false   # the central macOS/Linux runner: no Windows cert store
            Mock Connect-ExchangeOnline -MockWith { }
            { Connect-CtgExchange -AppId 'app-1' -Organization 'x.com' -CertificateThumbprint 'ABC123' } | Should -Throw -ExpectedMessage '*Windows runner*'
            Should -Invoke Connect-ExchangeOnline -Times 0 -Exactly
        }
    }

    It 'connects cross-platform with a CertificateBase64 (.pfx written to a temp file, then deleted)' {
        Mock Connect-ExchangeOnline -ModuleName Coretelligent.Exchange -MockWith { }
        Connect-CtgExchange -AppId 'app-1' -Organization 'x.com' -CertificateBase64 'AAAA'
        Should -Invoke Connect-ExchangeOnline -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $CertificateFilePath -like '*.pfx' }
    }
}

Describe 'Connect-CtgExchangeOnPrem' {
    BeforeAll {
        function global:New-PSSession { [CmdletBinding()] param($ConfigurationName, $ConnectionUri, $Authentication, $Credential) }
        function global:Import-PSSession { [CmdletBinding()] param($Session, $CommandName, [switch]$AllowClobber, [switch]$DisableNameChecking) }
        Import-Module "$PSScriptRoot/../modules/Coretelligent.Exchange/Coretelligent.Exchange.psm1" -Force
    }

    It 'opens a Kerberos Exchange remote session and imports only the *RemoteMailbox cmdlets' {
        $cred = [pscredential]::new('CORE\svc-ex', (ConvertTo-SecureString 'p' -AsPlainText -Force))
        Mock New-PSSession    -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Id = 7; Name = 'exch' } }
        Mock Import-PSSession -ModuleName Coretelligent.Exchange -MockWith { }
        $s = Connect-CtgExchangeOnPrem -ConnectionUri 'http://core-cce1-ex01.coretelligent.local/PowerShell/' -Credential $cred
        $s.Id | Should -Be 7
        Should -Invoke New-PSSession -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter {
            $ConfigurationName -eq 'Microsoft.Exchange' -and $ConnectionUri -eq 'http://core-cce1-ex01.coretelligent.local/PowerShell/' -and $Authentication -eq 'Kerberos'
        }
        # selective import avoids clobbering EXO's Get-Mailbox / Set-MailboxRegionalConfiguration
        Should -Invoke Import-PSSession -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $CommandName -contains '*RemoteMailbox' -and $AllowClobber }
    }
}

Describe 'Confirm-CtgExchange' {
    BeforeEach {
        function global:Get-Mailbox { [CmdletBinding()] param($Identity) }
        function global:Get-CASMailbox { [CmdletBinding()] param($Identity) }
        Import-Module "$PSScriptRoot/../modules/Coretelligent.Exchange/Coretelligent.Exchange.psm1" -Force
        $user = [pscustomobject]@{ UserPrincipalName = 'jdoe@61commodities.com' }
    }

    It 'offboard: passes when the mailbox is shared and ActiveSync/OWA are off' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '10 GB (10,737,418,240 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'SharedMailbox' } }
        Mock Get-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ ActiveSyncEnabled = $false; OWAEnabled = $false } }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true }
        $r = Confirm-CtgExchange -User $user -Config $config -Action 'offboard'
        $r.ok | Should -BeTrue
    }

    It 'offboard: passes when EXO still shows UserMailbox but the on-prem remote mailbox is shared (pending sync)' {
        # Hybrid: Set-RemoteMailbox -Type Shared converts on-prem immediately; EXO catches up on the next
        # sync. The read-back must accept the on-prem RemoteSharedMailbox instead of false-failing + looping.
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '0 GB (0 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox' } }
        Mock Get-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'RemoteSharedMailbox' } }
        Mock Get-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ ActiveSyncEnabled = $false; OWAEnabled = $false } }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true }
        $r = Confirm-CtgExchange -User $user -Config $config -Action 'offboard'
        $r.ok | Should -BeTrue
        ($r.checks | Where-Object { $_.name -eq 'mailbox is shared' }).pass | Should -BeTrue
    }

    It 'offboard: MailUser (no EXO mailbox) — shared via on-prem remote, ActiveSync/OWA checks skipped' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '0 GB (0 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { $null }   # MailUser: no EXO mailbox
        Mock Get-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'RemoteSharedMailbox' } }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true }
        $r = Confirm-CtgExchange -User $user -Config $config -Action 'offboard'
        $r.ok | Should -BeTrue
        ($r.checks | Where-Object { $_.name -eq 'mailbox is shared' }).pass | Should -BeTrue
        @($r.checks | Where-Object { $_.name -like '*ActiveSync*' }).Count | Should -Be 0   # no EXO mailbox -> not checked
    }

    It 'offboard: still fails when NEITHER EXO nor the on-prem remote mailbox is shared' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '0 GB (0 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox' } }
        Mock Get-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'RemoteUserMailbox' } }
        Mock Get-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ ActiveSyncEnabled = $false; OWAEnabled = $false } }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true }
        $r = Confirm-CtgExchange -User $user -Config $config -Action 'offboard'
        ($r.checks | Where-Object { $_.name -eq 'mailbox is shared' }).pass | Should -BeFalse
    }

    It 'offboard: resolves by display name (same as the executor) so it checks the RIGHT mailbox' {
        # No UPN on the case — the validator must resolve via Get-Recipient, not check an empty identity
        # (which would always "miss" and trigger the offboard re-run loop).
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ PrimarySmtpAddress = 'esack@61commodities.com'; DisplayName = 'Evan Sacksner' } }
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '3 GB (3,221,225,472 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'SharedMailbox' } }
        Mock Get-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ ActiveSyncEnabled = $false; OWAEnabled = $false } }
        $u = [pscustomobject]@{ UserPrincipalName = ''; DisplayName = 'Evan Sacksner' }
        $r = Confirm-CtgExchange -User $u -Config ([pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true }) -Action 'offboard'
        $r.ok | Should -BeTrue
        Should -Invoke Get-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'esack@61commodities.com' } -Times 1
    }

    It 'offboard: passes (nothing to verify) when the target cannot be resolved — no re-run loop' {
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -MockWith { @() }
        $u = [pscustomobject]@{ UserPrincipalName = ''; DisplayName = 'Nobody Here' }
        $r = Confirm-CtgExchange -User $u -Config ([pscustomobject]@{ convertToShared = [pscustomobject]@{} }) -Action 'offboard'
        $r.ok | Should -BeTrue
    }

    It 'offboard: an over-threshold mailbox is allowed to stay a user mailbox' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '75 GB (80,530,636,800 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox' } }
        Mock Get-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ ActiveSyncEnabled = $false; OWAEnabled = $false } }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true }
        $r = Confirm-CtgExchange -User $user -Config $config -Action 'offboard'
        $r.ok | Should -BeTrue
    }

    It 'onboard has no lane: returns ok with no checks' {
        $r = Confirm-CtgExchange -User $user -Config ([pscustomobject]@{}) -Action 'onboard'
        $r.ok | Should -BeTrue
        @($r.checks).Count | Should -Be 0
    }

    It 'offboard: passes the GAL check when hideFromGal was requested and EXO confirms it is hidden' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox'; HiddenFromAddressListsEnabled = $true } }
        Mock Get-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ ActiveSyncEnabled = $false; OWAEnabled = $false } }
        $config = [pscustomobject]@{ hideFromGal = $true; blockMobileDevices = $true }
        $r = Confirm-CtgExchange -User $user -Config $config -Action 'offboard'
        $r.ok | Should -BeTrue
        ($r.checks | Where-Object { $_.name -eq 'hidden from GAL' }).pass | Should -BeTrue
    }

    It 'offboard: fails the GAL check when hideFromGal was requested but EXO still shows it visible' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox'; HiddenFromAddressListsEnabled = $false } }
        Mock Get-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ ActiveSyncEnabled = $false; OWAEnabled = $false } }
        $config = [pscustomobject]@{ hideFromGal = $true; blockMobileDevices = $true }
        $r = Confirm-CtgExchange -User $user -Config $config -Action 'offboard'
        $r.ok | Should -BeFalse
        ($r.checks | Where-Object { $_.name -eq 'hidden from GAL' }).pass | Should -BeFalse
    }

    It 'offboard: skips the GAL check for a directory-synced mailbox even when hideFromGal was requested (EXO cannot hide it; the AD lane owns synced hides, and the executor already soft-WARNed)' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox'; HiddenFromAddressListsEnabled = $false; IsDirSynced = $true } }
        Mock Get-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ ActiveSyncEnabled = $false; OWAEnabled = $false } }
        $config = [pscustomobject]@{ hideFromGal = $true; blockMobileDevices = $true }
        $r = Confirm-CtgExchange -User $user -Config $config -Action 'offboard'
        @($r.checks | Where-Object { $_.name -eq 'hidden from GAL' }).Count | Should -Be 0
        $r.ok | Should -BeTrue
    }

    It 'offboard: does not assert the GAL check when hideFromGal was not requested' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox'; HiddenFromAddressListsEnabled = $false } }
        Mock Get-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ ActiveSyncEnabled = $false; OWAEnabled = $false } }
        $config = [pscustomobject]@{ blockMobileDevices = $true }
        $r = Confirm-CtgExchange -User $user -Config $config -Action 'offboard'
        @($r.checks | Where-Object { $_.name -eq 'hidden from GAL' }).Count | Should -Be 0
    }

    It 'offboard: skips the GAL check for a MailUser (no EXO mailbox) even when hideFromGal was requested' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '0 GB (0 bytes)' } }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { $null }   # MailUser: no EXO mailbox
        $config = [pscustomobject]@{ hideFromGal = $true }
        $r = Confirm-CtgExchange -User $user -Config $config -Action 'offboard'
        $r.ok | Should -BeTrue
        @($r.checks | Where-Object { $_.name -eq 'hidden from GAL' }).Count | Should -Be 0
    }
}

Describe 'Invoke-CtgExchangeOnboarding' {
    BeforeEach {
        $script:user = [pscustomobject]@{ SamAccountName='jdoe'; MailNickname='jdoe'; DisplayName='John Doe'; UserPrincipalName='jdoe@core.tech'; WorkEmail='jdoe@core.tech' }
        $script:config = [pscustomobject]@{ enableRemoteMailbox = [pscustomobject]@{ routingDomain='coretell.mail.onmicrosoft.com'; emailAddressPolicyEnabled=$true } }
    }

    It 'enables the remote mailbox with the routing address and sets the policy flag' {
        Mock Get-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { $null }
        Mock Enable-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith {}
        Mock Set-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith {}
        $r = Invoke-CtgExchangeOnboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        Should -Invoke Enable-RemoteMailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $RemoteRoutingAddress -eq 'jdoe@coretell.mail.onmicrosoft.com' -and $PrimarySmtpAddress -eq 'jdoe@core.tech' } -Times 1
        Should -Invoke Set-RemoteMailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $EmailAddressPolicyEnabled -eq $true } -Times 1
    }

    It 'is idempotent — skips enable when already remote-enabled' {
        Mock Get-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Identity='jdoe' } }
        Mock Enable-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith {}
        Mock Set-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith {}
        $r = Invoke-CtgExchangeOnboarding -User $user -Config $config
        Should -Invoke Enable-RemoteMailbox -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        ($r.Actions -join ' ') | Should -Match 'already enabled'
    }
}

Describe 'Invoke-CtgExchangeHybridOnboard' {
    # Regression: a lane with NO enableRemoteMailbox config makes Invoke-CtgExchangeOnboarding return an
    # object with no Email property — the caller must read it defensively, not crash with
    # "The property 'Email' cannot be found on this object".
    It 'does not crash when the onboard lane has no enableRemoteMailbox config' {
        Mock Set-CtgMailboxRegional -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Actions=@() } }
        Mock Get-CtgRequestedGroupNames -ModuleName Coretelligent.Exchange -MockWith { @() }
        $user = [pscustomobject]@{ SamAccountName='ddirienzo'; UserPrincipalName='ddirienzo@core.tech'; DisplayName='Drew Dirienzo' }
        $cfg = [pscustomobject]@{ waitForSync=$false }  # no enableRemoteMailbox, no mirror
        $r = Invoke-CtgExchangeHybridOnboard -User $user -Config $cfg
        $r.Status | Should -Be 'ok'
        ($r.Actions -join ' ') | Should -Match 'no remote-mailbox config'
    }
}

Describe 'Invoke-CtgExchangeHybridOnboard' {
    BeforeEach {
        $script:user = [pscustomobject]@{ SamAccountName='jdoe'; ManagerEmail='boss@core.tech' }
        Mock Invoke-CtgExchangeOnboarding -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ System='exchange'; Status='ok'; Email='jdoe@core.tech'; Routing='jdoe@coretell.mail.onmicrosoft.com'; Actions=@('enabled remote mailbox') } }
        Mock Set-CtgMailboxRegional   -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ System='exchange'; Status='ok'; Actions=@('regional set') } }
    }

    It 'runs enable -> wait -> regional and carries the manager email through' {
        Mock Wait-CtgMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Status='ok'; Found=$true; Identity='jdoe' } }
        $r = Invoke-CtgExchangeHybridOnboard -User $user -Config ([pscustomobject]@{})
        $r.Status | Should -Be 'ok'
        $r.Email  | Should -Be 'jdoe@core.tech'
        Should -Invoke Invoke-CtgExchangeOnboarding -ModuleName Coretelligent.Exchange -Times 1 -Exactly
        Should -Invoke Wait-CtgMailbox -ModuleName Coretelligent.Exchange -Times 1 -Exactly
        Should -Invoke Set-CtgMailboxRegional -ModuleName Coretelligent.Exchange -Times 1 -Exactly -ParameterFilter { $ManagerEmail -eq 'boss@core.tech' }
        ($r.Actions -join ' ') | Should -Match 'regional set'
    }

    It 'skips the sync-wait when waitForSync is false' {
        Mock Wait-CtgMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Status='ok'; Found=$true } }
        $r = Invoke-CtgExchangeHybridOnboard -User $user -Config ([pscustomobject]@{ waitForSync=$false })
        Should -Invoke Wait-CtgMailbox -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        Should -Invoke Set-CtgMailboxRegional -ModuleName Coretelligent.Exchange -Times 1 -Exactly
    }

    It 'defers regional/calendar when the mailbox never syncs (no error)' {
        Mock Wait-CtgMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Status='timeout'; Found=$false } }
        $r = Invoke-CtgExchangeHybridOnboard -User $user -Config ([pscustomobject]@{})
        $r.Status  | Should -Be 'ok'
        $r.Warning | Should -Match 'not synced'
        Should -Invoke Set-CtgMailboxRegional -ModuleName Coretelligent.Exchange -Times 0 -Exactly
    }
}

Describe 'Set-CtgMailboxRegional' {
    It 'sets language/timezone and grants the manager Reviewer on the calendar' {
        Mock Set-MailboxRegionalConfiguration -ModuleName Coretelligent.Exchange -MockWith {}
        Mock Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -MockWith {}
        $config = [pscustomobject]@{ regional=[pscustomobject]@{ language='en-us'; timezone='Pacific Standard Time'; defaultTimezone='Eastern Standard Time' }; calendar=[pscustomobject]@{ grantManagerReviewer=$true } }
        Set-CtgMailboxRegional -Identity 'jdoe@core.tech' -Config $config -ManagerEmail 'boss@core.tech'
        Should -Invoke Set-MailboxRegionalConfiguration -ModuleName Coretelligent.Exchange -ParameterFilter { $TimeZone -eq 'Pacific Standard Time' } -Times 1
        Should -Invoke Add-MailboxFolderPermission -ModuleName Coretelligent.Exchange -ParameterFilter { $User -eq 'boss@core.tech' -and $AccessRights -eq 'Reviewer' } -Times 1
    }

    It 'falls back to the default timezone when the location had none (literal {token})' {
        Mock Set-MailboxRegionalConfiguration -ModuleName Coretelligent.Exchange -MockWith {}
        $config = [pscustomobject]@{ regional=[pscustomobject]@{ language='en-us'; timezone='{location.timezone}'; defaultTimezone='Eastern Standard Time' } }
        Set-CtgMailboxRegional -Identity 'jdoe@core.tech' -Config $config
        Should -Invoke Set-MailboxRegionalConfiguration -ModuleName Coretelligent.Exchange -ParameterFilter { $TimeZone -eq 'Eastern Standard Time' } -Times 1
    }
}

Describe 'Wait-CtgMailbox' {
    It 'returns Found as soon as the mailbox appears in EXO' {
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Identity='jdoe' } }
        $r = Wait-CtgMailbox -Identity 'jdoe@core.tech' -TimeoutSeconds 5 -IntervalSeconds 0
        $r.Found | Should -BeTrue
        $r.Status | Should -Be 'ok'
    }

    It 'returns timeout when the mailbox never lands within the window' {
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { $null }
        $r = Wait-CtgMailbox -Identity 'jdoe@core.tech' -TimeoutSeconds 0 -IntervalSeconds 0
        $r.Found | Should -BeFalse
        $r.Status | Should -Be 'timeout'
    }

    It 'keeps polling until the mailbox appears (no open-ended sleep)' {
        $script:n = 0
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { $script:n++; if ($script:n -ge 3) { [pscustomobject]@{ Identity='jdoe' } } else { $null } }
        $r = Wait-CtgMailbox -Identity 'jdoe@core.tech' -TimeoutSeconds 10 -IntervalSeconds 0
        $r.Found | Should -BeTrue
        Should -Invoke Get-Mailbox -ModuleName Coretelligent.Exchange -Times 3
    }
}

Describe 'Invoke-CtgExchangeNamedGroups' {
    It 'adds a DL via Add-DistributionGroupMember, a 365 group via Add-UnifiedGroupLinks, and warns on an unknown name' {
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'DCG' } -MockWith { [pscustomobject]@{ DisplayName = 'DCG'; Identity = 'DCG'; RecipientTypeDetails = 'MailUniversalDistributionGroup'; IsDirSynced = $false } }
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'Team365' } -MockWith { [pscustomobject]@{ DisplayName = 'Team365'; Identity = 'Team365'; RecipientTypeDetails = 'GroupMailbox'; IsDirSynced = $false } }
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'Ghost' } -MockWith { $null }
        Mock Add-DistributionGroupMember -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Add-UnifiedGroupLinks -ModuleName Coretelligent.Exchange -MockWith { }
        $acts = Invoke-CtgExchangeNamedGroups -NewUser 'laura@dcg.co' -Groups @('DCG', 'Team365', 'Ghost')
        Should -Invoke Add-DistributionGroupMember -ModuleName Coretelligent.Exchange -Times 1 -Exactly
        Should -Invoke Add-UnifiedGroupLinks -ModuleName Coretelligent.Exchange -Times 1 -Exactly
        ($acts -join ' ') | Should -Match 'added to distribution group: DCG'
        ($acts -join ' ') | Should -Match 'added to 365 group: Team365'
        ($acts -join ' ') | Should -Match 'not found in Exchange Online'
    }

    It 'skips a dir-synced distribution list (AD lane owns it)' {
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { $Identity -eq 'Synced DL' } -MockWith { [pscustomobject]@{ DisplayName = 'Synced DL'; Identity = 'Synced DL'; RecipientTypeDetails = 'MailUniversalDistributionGroup'; IsDirSynced = $true } }
        Mock Add-DistributionGroupMember -ModuleName Coretelligent.Exchange -MockWith { }
        $acts = Invoke-CtgExchangeNamedGroups -NewUser 'laura@dcg.co' -Groups @('Synced DL')
        Should -Invoke Add-DistributionGroupMember -ModuleName Coretelligent.Exchange -Times 0 -Exactly
        ($acts -join ' ') | Should -Match 'on-prem-synced group'
    }
}

# --- convert-to-shared safety: unknown size, config intent, and the cloud read-back ---------------
# Regression guards for the offboard licence path. The licence gate downstream keys off the action
# lines these tests assert on, and removing a licence from a mailbox that is NOT really shared in the
# cloud lets Exchange purge the mail after its 30-day grace.

Describe 'Test-CtgConvertToShared' {
    It 'reads the INTENT out of every profile shape, not the object''s existence' {
        Test-CtgConvertToShared $null | Should -BeFalse
        Test-CtgConvertToShared $true | Should -BeTrue
        Test-CtgConvertToShared $false | Should -BeFalse
        # a settings bag: its presence is the opt-in
        Test-CtgConvertToShared ([pscustomobject]@{ skipIfMailboxOverGB = 50 }) | Should -BeTrue
        # marketscience's shape — the one that exists specifically to say "don't"
        Test-CtgConvertToShared ([pscustomobject]@{ value = $true; unless = 'instructed not to' }) | Should -BeTrue
        Test-CtgConvertToShared ([pscustomobject]@{ value = $false; unless = 'instructed not to' }) | Should -BeFalse
    }
}

Describe 'Get-CtgMailboxSizeGB' {
    It 'returns $null (unknown) — never 0 — when the size cannot be read or parsed' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { $null }
        Get-CtgMailboxSizeGB -Identity 'x@y.com' | Should -BeNullOrEmpty
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = 'Unlimited' } }
        Get-CtgMailboxSizeGB -Identity 'x@y.com' | Should -BeNullOrEmpty
        Get-CtgMailboxSizeGB -Identity '' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-CtgMailboxSize' {
    # FR #20: a 33 MB mailbox once read as "size unknown" because its TotalItemSize deserialized with
    # no "(…,… bytes)" suffix. The parser must recover a real size from every shape it arrives in, and
    # still return $null (never 0) for a genuinely unreadable one.
    It 'reads exact bytes from the parenthetical string form' {
        ConvertFrom-CtgMailboxSize '10 GB (10,737,418,240 bytes)' | Should -Be 10
        ConvertFrom-CtgMailboxSize '0 GB (0 bytes)' | Should -Be 0
    }
    It 'reads the structured .Value.ToBytes() (a live EXO session)' {
        $size = [pscustomobject]@{ Value = [pscustomobject]@{ } }
        $size.Value | Add-Member -MemberType ScriptMethod -Name ToBytes -Value { 35127296 } # 33.5 MB
        ConvertFrom-CtgMailboxSize $size | Should -Be 0.032714844
    }
    It 'recovers a unit-suffixed string with NO byte count — the UM0029906 shape' {
        ConvertFrom-CtgMailboxSize '33.5 MB' | Should -Be 0.032714844
        ConvertFrom-CtgMailboxSize '1.2 GB'  | Should -Be 1.2
        ConvertFrom-CtgMailboxSize '2 TB'    | Should -Be 2048
    }
    It 'a 33 MB mailbox is UNDER the 50 GB cap (the whole point — convert must be offered)' {
        (ConvertFrom-CtgMailboxSize '33.5 MB') -lt 50 | Should -BeTrue
    }
    It 'returns $null for unparseable / empty input — an unknown size is not zero' {
        ConvertFrom-CtgMailboxSize 'Unlimited' | Should -BeNullOrEmpty
        ConvertFrom-CtgMailboxSize ''          | Should -BeNullOrEmpty
        ConvertFrom-CtgMailboxSize $null       | Should -BeNullOrEmpty
    }
    # FR #85. At two decimal places every mailbox under ~5 MB collapsed to exactly 0.00 GB, and 0 is a
    # MEANINGFUL reading everywhere downstream: "known empty, the cheapest thing there is to convert".
    # A 512 KB mailbox with real mail in it was therefore indistinguishable from an empty one. This
    # test previously asserted `'512 KB' | Should -Be 0` — it pinned the bug.
    It 'a small but NON-EMPTY mailbox does not read as zero' {
        ConvertFrom-CtgMailboxSize '512 KB' | Should -Not -Be 0
        (ConvertFrom-CtgMailboxSize '512 KB') -gt 0 | Should -BeTrue
        ConvertFrom-CtgMailboxSize '1 MB'   | Should -Not -Be 0
        ConvertFrom-CtgMailboxSize '1 KB'   | Should -Not -Be 0
        ConvertFrom-CtgMailboxSize '4096 (4,096 bytes)' | Should -Not -Be 0
    }
    It 'a genuinely EMPTY mailbox still reads as exactly zero' {
        ConvertFrom-CtgMailboxSize '0 GB (0 bytes)' | Should -Be 0
        ConvertFrom-CtgMailboxSize '0 B'            | Should -Be 0
    }
    It 'a small mailbox is still under the cap, so convert is still offered' {
        (ConvertFrom-CtgMailboxSize '512 KB') -lt 50 | Should -BeTrue
    }
}

Describe 'Format-CtgMailboxSize' {
    # "0.000488 GB" is technically true and tells an operator nothing. A size is only useful on a case
    # note when the unit matches the magnitude — this is what the requestor actually sees.
    It 'renders sub-gigabyte sizes in a unit a human reads' {
        Format-CtgMailboxSize (ConvertFrom-CtgMailboxSize '512 KB') | Should -Be '512 KB'
        Format-CtgMailboxSize (ConvertFrom-CtgMailboxSize '33.5 MB') | Should -Match '^33\.5 MB$'
        Format-CtgMailboxSize (ConvertFrom-CtgMailboxSize '1.2 GB')  | Should -Be '1.2 GB'
        Format-CtgMailboxSize (ConvertFrom-CtgMailboxSize '75 GB (80,530,636,800 bytes)') | Should -Be '75 GB'
    }
    It 'says "unknown" for an unreadable size — never a number' {
        Format-CtgMailboxSize $null | Should -Be 'unknown'
    }
    It 'distinguishes a genuinely empty mailbox from a tiny one' {
        Format-CtgMailboxSize 0 | Should -Be '0 (empty)'
        Format-CtgMailboxSize (ConvertFrom-CtgMailboxSize '1 KB') | Should -Not -Be '0 (empty)'
    }
}

Describe 'Invoke-CtgExchangeOffboarding convert safety' {
    BeforeEach {
        $script:user = [pscustomobject]@{ UserPrincipalName = 'jdoe@61commodities.com'; DisplayName = 'J Doe' }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox' } }
        Mock Set-Mailbox -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Set-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Set-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { }
    }

    # FR #85 — POLICY REVERSAL, requested explicitly by the requestor after the risk was put to them.
    # This test used to assert the opposite ("does NOT convert when the mailbox size is unknown — an
    # unreadable size is not a small one"). An unreadable size is now treated as 0 so the offboard
    # completes and moves forward rather than stalling on a transient EXO read failure.
    #
    # The accepted cost, stated here so it is never rediscovered by accident: a LARGE mailbox whose
    # size read fails twice is now converted to shared and stripped of its licence, and Microsoft caps
    # an unlicensed shared mailbox at 50 GB — past that the mailbox is locked and its mail
    # inaccessible. The retry below is what makes that unlikely; the warning is what makes it findable.
    It 'treats an unknown size as 0 and converts anyway — by operator policy (FR #85)' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { $null }
        Mock Start-Sleep -ModuleName Coretelligent.Exchange -MockWith { }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 } }
        $r = Invoke-CtgExchangeOffboarding -User $script:user -Config $config
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 1 -Exactly -ParameterFilter { $Type -eq 'Shared' }
        ($r.Actions -join ' ') | Should -Match 'WARN mailbox size UNKNOWN after a retry'
        ($r.Actions -join ' ') | Should -Match 'Proceeding as if the mailbox were EMPTY'
        # the assumption must name its own worst case, on the case and in the work note
        ($r.Actions -join ' ') | Should -Match '50 GB unlicensed-shared cap'
        $r.MailboxSizeGB | Should -Be 0
    }

    It 'retries the size read once before assuming anything — a throttled read is usually transient' {
        $script:calls = 0
        Mock Start-Sleep -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith {
            $script:calls++
            if ($script:calls -eq 1) { return $null }          # first read throttles…
            [pscustomobject]@{ TotalItemSize = '2 GB (2,147,483,648 bytes)' }  # …second succeeds
        }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 } }
        $r = Invoke-CtgExchangeOffboarding -User $script:user -Config $config
        $r.MailboxSizeGB | Should -Be 2
        ($r.Actions -join ' ') | Should -Match 'succeeded on retry'
        # a recovered read must NOT leave the scary assumption note behind
        ($r.Actions -join ' ') | Should -Not -Match 'Proceeding as if the mailbox were EMPTY'
    }

    It 'a small but non-empty mailbox reports a readable size, not "0 GB"' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '512 KB (524,288 bytes)' } }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 } }
        $r = Invoke-CtgExchangeOffboarding -User $script:user -Config $config
        ($r.Actions -join ' ') | Should -Match 'mailbox size: 512 KB'
        ($r.Actions -join ' ') | Should -Not -Match 'mailbox size: 0'
        $r.MailboxSizeGB | Should -Not -Be 0
    }

    It 'does NOT convert when the profile says value:false' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ value = $false; unless = 'instructed not to' } }
        $r = Invoke-CtgExchangeOffboarding -User $script:user -Config $config
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 0 -Exactly -ParameterFilter { $Type -eq 'Shared' }
        ($r.Actions -join ' ') | Should -Not -Match 'converted mailbox to shared'
    }

    It 'hybrid: claims the convert only once the CLOUD reads SharedMailbox' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Identity = 'jdoe' } }
        # NOT yet shared when the step starts (else the FR#27 already-shared pre-check would short-circuit
        # the convert entirely) — the on-prem convert runs, and only the POST-convert read-back (the 3rd
        # Get-Mailbox call: existence check, pre-check, then this verify) finds the cloud caught up.
        $callState = @{ n = 0 }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith {
            $callState.n++
            if ($callState.n -le 2) { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox' } }
            else { [pscustomobject]@{ RecipientTypeDetails = 'SharedMailbox' } }
        }.GetNewClosure()
        $r = Invoke-CtgExchangeOffboarding -User $script:user -Config ([pscustomobject]@{ convertToShared = $true })
        ($r.Actions -join ' ') | Should -Match 'verified shared in the cloud'
    }

    It 'hybrid: WARNs and does NOT claim the convert while the cloud still reads UserMailbox' {
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ Identity = 'jdoe' } }
        # dirsync hasn't landed — the cloud object is still a user mailbox
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox' } }
        $r = Invoke-CtgExchangeOffboarding -User $script:user -Config ([pscustomobject]@{ convertToShared = $true })
        Should -Invoke Set-RemoteMailbox -ModuleName Coretelligent.Exchange -Times 1 -ParameterFilter { $Type -eq 'Shared' }
        ($r.Actions -join ' ') | Should -Match 'WARN convert submitted on-prem'
        ($r.Actions -join ' ') | Should -Not -Match 'verified shared in the cloud'
    }

    It 'MailUser with no on-prem session: WARNs instead of throwing on Set-Mailbox' {
        # No EXO mailbox AND no Get-RemoteMailbox object -> the old code called Set-Mailbox anyway,
        # which throws "does not support recipients of this type" and aborted the whole step.
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { $null }
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }
        Mock Get-RemoteMailbox -ModuleName Coretelligent.Exchange -MockWith { $null }
        $r = Invoke-CtgExchangeOffboarding -User $script:user -Config ([pscustomobject]@{ convertToShared = $true; removeDistributionGroups = $false })
        $r.Status | Should -Be 'ok'
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 0 -Exactly -ParameterFilter { $Type -eq 'Shared' }
        ($r.Actions -join ' ') | Should -Match 'WARN mailbox NOT converted'
    }
}

Describe 'Invoke-CtgExchangeOffboarding hide-from-GAL' {
    BeforeEach {
        Mock Resolve-CtgExchangeTarget { [pscustomobject]@{ Upn = 'leaver@contoso.com'; DisplayName = ''; MatchCount = 1 } } -ModuleName Coretelligent.Exchange
        Mock Get-CtgMailboxSizeGB { 1 } -ModuleName Coretelligent.Exchange
        Mock Get-Mailbox { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox'; HiddenFromAddressListsEnabled = $false } } -ModuleName Coretelligent.Exchange
        Mock Set-Mailbox { } -ModuleName Coretelligent.Exchange
    }

    It 'hides from GAL when config asks and it is not already hidden' {
        # The static BeforeEach mock always reports HiddenFromAddressListsEnabled = $false, which can't
        # exercise the executor's read-BACK-after-write (it would always see the pre-write state and
        # WARN "still shows visible"). Make the mock stateful so the read-back sees the real EXO
        # behavior: Set-Mailbox applies synchronously, so the follow-up Get-Mailbox reflects it.
        $state = @{ hidden = $false }
        Mock Get-Mailbox { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox'; HiddenFromAddressListsEnabled = $state.hidden } } -ModuleName Coretelligent.Exchange
        Mock Set-Mailbox { $state.hidden = $true } -ModuleName Coretelligent.Exchange -ParameterFilter { $HiddenFromAddressListsEnabled -eq $true }
        $u = [pscustomobject]@{ UserPrincipalName = 'leaver@contoso.com' }
        $r = Invoke-CtgExchangeOffboarding -User $u -Config ([pscustomobject]@{ hideFromGal = $true })
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $HiddenFromAddressListsEnabled -eq $true } -Times 1
        ($r.Actions -join "`n") | Should -Match 'hid from GAL'
    }

    It 'is idempotent: skips the write when already hidden' {
        Mock Get-Mailbox { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox'; HiddenFromAddressListsEnabled = $true } } -ModuleName Coretelligent.Exchange
        $u = [pscustomobject]@{ UserPrincipalName = 'leaver@contoso.com' }
        $r = Invoke-CtgExchangeOffboarding -User $u -Config ([pscustomobject]@{ hideFromGal = $true })
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $null -ne $HiddenFromAddressListsEnabled } -Times 0
        ($r.Actions -join "`n") | Should -Match 'already hidden from GAL'
    }

    It 'does not hide when config opts out with { value = $false }' {
        $u = [pscustomobject]@{ UserPrincipalName = 'leaver@contoso.com' }
        $r = Invoke-CtgExchangeOffboarding -User $u -Config ([pscustomobject]@{ hideFromGal = [pscustomobject]@{ value = $false } })
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $null -ne $HiddenFromAddressListsEnabled } -Times 0
    }

    It 'WARNs (does not throw) when EXO rejects a directory-synced mailbox' {
        Mock Set-Mailbox { throw "The operation couldn't be performed because object 'leaver' is being synchronized." } -ModuleName Coretelligent.Exchange -ParameterFilter { $null -ne $HiddenFromAddressListsEnabled }
        $u = [pscustomobject]@{ UserPrincipalName = 'leaver@contoso.com' }
        $r = Invoke-CtgExchangeOffboarding -User $u -Config ([pscustomobject]@{ hideFromGal = $true })
        ($r.Actions -join "`n") | Should -Match 'WARN.*hide from GAL.*sync'
    }

    It 'skips the hide (on-prem note) for a MailUser with no EXO mailbox' {
        Mock Get-Mailbox { $null } -ModuleName Coretelligent.Exchange
        $u = [pscustomobject]@{ UserPrincipalName = 'leaver@contoso.com' }
        $r = Invoke-CtgExchangeOffboarding -User $u -Config ([pscustomobject]@{ hideFromGal = $true })
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -ParameterFilter { $null -ne $HiddenFromAddressListsEnabled } -Times 0
        ($r.Actions -join "`n") | Should -Match 'hide-from-GAL skipped.*MailUser'
    }
}

Describe 'Test-CtgHideFromGal' {
    It 'defaults, flags, and objects resolve correctly' {
        Test-CtgHideFromGal $true | Should -BeTrue
        Test-CtgHideFromGal $false | Should -BeFalse
        Test-CtgHideFromGal 'off' | Should -BeFalse
        Test-CtgHideFromGal ([pscustomobject]@{ value = $false }) | Should -BeFalse
        Test-CtgHideFromGal ([pscustomobject]@{ value = $true }) | Should -BeTrue
        Test-CtgHideFromGal $null | Should -BeFalse
    }

    It 'treats an object with no value key as opt-in (presence = intent), and normalizes string falsy forms' {
        Test-CtgHideFromGal ([pscustomobject]@{ attribute = 'msExchHideFromAddressLists' }) | Should -BeTrue
        Test-CtgHideFromGal 'no' | Should -BeFalse
        Test-CtgHideFromGal 'false' | Should -BeFalse
        Test-CtgHideFromGal '0' | Should -BeFalse
    }
}

Describe 'Invoke-CtgExchangeOffboarding admin-account (-a) sweep' {
    BeforeEach {
        $user = [pscustomobject]@{ UserPrincipalName = 'jdoe@x.com' }
        Mock Set-Mailbox -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Set-CASMailbox -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Set-MailboxAutoReplyConfiguration -ModuleName Coretelligent.Exchange -MockWith { }
        Mock Get-Mailbox -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox' } }
        Mock Get-MailboxStatistics -ModuleName Coretelligent.Exchange -MockWith { [pscustomobject]@{ TotalItemSize = '10 GB (10,737,418,240 bytes)' } }
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -MockWith { $null }
    }

    It 'runs the disable path on the -a mailbox when the recipient exists, without converting it' {
        Mock Get-Recipient -ModuleName Coretelligent.Exchange -ParameterFilter { "$Identity" -eq 'jdoe-a@x.com' } -MockWith {
            [pscustomobject]@{ PrimarySmtpAddress = 'jdoe-a@x.com' }
        }
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true; removeDistributionGroups = $false; adminAccountSuffix = '-a' }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        $r.Upn | Should -Be 'jdoe@x.com'      # the primary stays authoritative on the result
        $r.MailboxSizeGB | Should -Be 10
        ($r.Actions -join "`n") | Should -Match 'admin account check: found jdoe-a@x\.com'
        # convert-to-shared is a mail-continuity step and is stripped from the -a pass; the CAS block is kept
        Should -Invoke Set-Mailbox -ModuleName Coretelligent.Exchange -Times 1 -Exactly -ParameterFilter { $Type -eq 'Shared' }
        Should -Invoke Set-CASMailbox -ModuleName Coretelligent.Exchange -Times 2 -Exactly -ParameterFilter { $ActiveSyncEnabled -eq $false }
    }

    It 'reports plainly when there is no -a recipient' {
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true; removeDistributionGroups = $false; adminAccountSuffix = '-a' }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config $config
        $r.Status | Should -Be 'ok'
        ($r.Actions -join "`n") | Should -Match 'admin account check: no jdoe-a@x\.com'
        $r.PSObject.Properties['Candidates'] | Should -BeNullOrEmpty
        Should -Invoke Set-CASMailbox -ModuleName Coretelligent.Exchange -Times 1 -Exactly
    }

    It 'does nothing extra when adminAccountSuffix is not configured' {
        $config = [pscustomobject]@{ convertToShared = [pscustomobject]@{ skipIfMailboxOverGB = 50 }; blockMobileDevices = $true; removeDistributionGroups = $false }
        $r = Invoke-CtgExchangeOffboarding -User $user -Config $config
        ($r.Actions -join "`n") | Should -Not -Match 'admin account'
        Should -Invoke Get-Recipient -ModuleName Coretelligent.Exchange -Times 0 -Exactly
    }
}
