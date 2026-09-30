#Requires -Version 7.0

# Coretelligent.Teams  (Teams Phone — assign a phone number on onboard, release it on offboard)
#
# Onboard: once the user's M365 licence carries Teams Phone (and, for a Calling Plan number, a Calling
# Plan), assign them a number: the one an operator typed on the case (config.phoneNumber), else the
# next free number in the tenant whose prefix matches their office's area code (config.areaCode, which
# the app resolves from the profile's phoneByAreaCode). The assigned number is returned as PhoneNumber,
# which the app hands to the ad-phone-writeback step (AD telephoneNumber) and shows in the case notes.
# Offboard: release every number assigned to the leaver back to the tenant pool, returned as
# ReleasedNumbers so the case records which number was freed.
#
# Only Calling Plan numbers for now (config.numberType, default CallingPlan). OperatorConnect and
# DirectRouting are what Set-CsPhoneNumberAssignment calls the other two; Direct Routing also needs a
# voice routing policy, which is why it isn't simply a matter of passing the type through.
#
# WHERE THIS RUNS. The MicrosoftTeams module ships its own Microsoft.Identity.Client, the same assembly
# family Microsoft.Graph and ExchangeOnlineManagement load at runner start. Importing it into the runner
# would bind a second copy and wedge Graph — the hang #121 fixed for PnP. So every function here that
# calls a Cs cmdlet runs in a CHILD pwsh (Invoke-CtgTeamsOutOfProcess), which imports MicrosoftTeams on
# its own, connects with the m365-admin app certificate, and prints one tagged result line. Importing
# THIS module into the runner is harmless: nothing here loads MicrosoftTeams until a Cs cmdlet is called.
#
# App-only prerequisites (see /help/teams): the m365-admin app's service principal holds the Entra
# "Teams Administrator" role; MicrosoftTeams is installed on the runner host (the child installs it for
# the current user on first use if it isn't).
#
# Cs cmdlets used (MicrosoftTeams 5.x-8.x; -PhoneNumber / -PhoneNumberType are aliases in 8.x):
#   Get-CsOnlineUser -Identity <upn>                     FeatureTypes (PhoneSystem, CallingPlan), LineUri
#   Get-CsPhoneNumberAssignment -AssignedPstnTargetId    the numbers a user already has
#   Get-CsPhoneNumberAssignment -NumberType -PstnAssignmentStatus Unassigned -CapabilitiesContain UserAssignment
#   Set-CsPhoneNumberAssignment -Identity -PhoneNumber -PhoneNumberType [-LocationId]   (enables Enterprise Voice)
#   Remove-CsPhoneNumberAssignment -Identity -RemoveAll

Set-StrictMode -Version Latest

function Get-CtgProp {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# ── Pure helpers (unit-tested; no Teams connection) ─────────────────────────────────────────────────

# A number in E.164 ("+12035550123"), or $null when it can't be one. Accepts what people type: spaces,
# dashes, dots, brackets, a "tel:" prefix, and a bare 10-digit North American number.
function ConvertTo-CtgTeamsE164 {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Number)
    if ([string]::IsNullOrWhiteSpace($Number)) { return $null }
    $n = ($Number.Trim() -replace '^(?i)tel:', '' -replace ';.*$', '')
    $plus = $n.StartsWith('+')
    $digits = $n -replace '\D', ''
    if (-not $digits) { return $null }
    if ($plus) { return "+$digits" }
    if ($digits.Length -eq 10) { return "+1$digits" }
    if ($digits.Length -eq 11 -and $digits.StartsWith('1')) { return "+$digits" }
    if ($digits.Length -gt 11) { return "+$digits" }
    return $null
}

# The E.164 prefix a free number must start with for an office's area code: "203" -> "+1203" (a bare
# 3-digit code is North American), "+65" -> "+65", "+44 20" -> "+4420". $null when there's none.
function ConvertTo-CtgTeamsAreaPrefix {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$AreaCode)
    if ([string]::IsNullOrWhiteSpace($AreaCode)) { return $null }
    $a = $AreaCode.Trim()
    $digits = $a -replace '\D', ''
    if (-not $digits) { return $null }
    if ($a.StartsWith('+')) { return "+$digits" }
    if ($digits.Length -eq 3) { return "+1$digits" }
    if ($digits.Length -eq 4 -and $digits.StartsWith('1')) { return "+$digits" }
    return "+$digits"
}

# Whether Teams sees the licence a number of this type needs. The licence can be on the account in
# Entra well before Teams lists its features, so "not yet" is normal right after onboarding.
function Test-CtgTeamsVoiceReady {
    [CmdletBinding()]
    param($OnlineUser, [string]$NumberType = 'CallingPlan')
    if (-not $OnlineUser) { return [pscustomobject]@{ Ready = $false; Missing = @('the user (Teams does not list them yet)') } }
    $features = @(@(Get-CtgProp $OnlineUser 'FeatureTypes') | ForEach-Object { [string]$_ })
    $need = @('PhoneSystem') + @(if ($NumberType -eq 'CallingPlan') { 'CallingPlan' })
    $missing = @($need | Where-Object { $features -notcontains $_ })
    [pscustomobject]@{ Ready = ($missing.Count -eq 0); Missing = $missing }
}

# The free numbers to try, lowest first: user-assignable, of the right type, unassigned, activated where
# Teams says so, and starting with the office's prefix. Pure over Get-CsPhoneNumberAssignment's output.
function Select-CtgTeamsFreeNumbers {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Numbers = @(), [Parameter(Mandatory)][string]$Prefix, [string]$NumberType = 'CallingPlan')
    @($Numbers | Where-Object {
        $tn = [string](Get-CtgProp $_ 'TelephoneNumber')
        $type = [string](Get-CtgProp $_ 'NumberType')
        $status = [string](Get-CtgProp $_ 'PstnAssignmentStatus')
        $state = [string](Get-CtgProp $_ 'ActivationState')
        $target = [string](Get-CtgProp $_ 'AssignedPstnTargetId')
        (ConvertTo-CtgTeamsE164 $tn) -and (ConvertTo-CtgTeamsE164 $tn).StartsWith($Prefix) -and
            (-not $type -or $type -eq $NumberType) -and
            (-not $status -or $status -eq 'Unassigned') -and -not $target -and
            (-not $state -or $state -eq 'Activated')
    } | Sort-Object { ConvertTo-CtgTeamsE164 ([string](Get-CtgProp $_ 'TelephoneNumber')) })
}

function Get-CtgTeamsUpn {
    param($User)
    foreach ($k in 'UserPrincipalName', 'userToOffboard', 'workEmail', 'Email') {
        $v = [string](Get-CtgProp $User $k)
        if ($v -match '@') { return $v.Trim() }
    }
    $null
}

function Get-CtgTeamsAssignedNumbers {
    param([Parameter(Mandatory)][string]$Upn)
    @(Get-CsPhoneNumberAssignment -AssignedPstnTargetId $Upn -ErrorAction Stop | ForEach-Object { ConvertTo-CtgTeamsE164 ([string](Get-CtgProp $_ 'TelephoneNumber')) } | Where-Object { $_ })
}

# ── Executors (call Cs cmdlets — run inside the child process) ──────────────────────────────────────

function Invoke-CtgTeamsOnboarding {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$User, $Config)
    $actions = [System.Collections.Generic.List[string]]::new()
    $numberType = [string](Get-CtgProp $Config 'numberType'); if (-not $numberType) { $numberType = 'CallingPlan' }
    $result = { param($phone, $retry) [pscustomobject]@{ System = 'teams'; Status = 'ok'; PhoneNumber = $phone; Actions = $actions.ToArray(); RetryAfterMinutes = $retry } }
    if ($numberType -ne 'CallingPlan') { throw "numberType '$numberType' isn't supported yet — only CallingPlan numbers can be assigned automatically" }

    $upn = Get-CtgTeamsUpn $User
    if (-not $upn) { throw 'no user principal name on the case to assign a Teams number to' }

    # 1. Already has a number: nothing to do (idempotent). A different number typed on the case is not
    #    forced over it — replacing someone's live number is a decision for a person.
    $existing = @(Get-CtgTeamsAssignedNumbers -Upn $upn)
    $wanted = ConvertTo-CtgTeamsE164 ([string](Get-CtgProp $Config 'phoneNumber'))
    if ($existing.Count -gt 0) {
        if ($wanted -and $existing -notcontains $wanted) {
            $actions.Add("WARN $upn already has Teams number $($existing -join ', '); the case asks for $wanted — not changed (unassign the current one in the Teams admin centre first if it should be replaced)")
        }
        else { $actions.Add("$upn already has Teams number $($existing -join ', ') — no change") }
        return & $result $existing[0] $null
    }

    # 2. The licence has to have reached Teams first. Right after onboarding it usually hasn't: wait.
    $online = Get-CsOnlineUser -Identity $upn -ErrorAction SilentlyContinue
    $ready = Test-CtgTeamsVoiceReady -OnlineUser $online -NumberType $numberType
    if (-not $ready.Ready) {
        $actions.Add("waiting for Teams to pick up the licence — missing: $($ready.Missing -join ', ') (checking again shortly)")
        return & $result $null 15
    }

    # 3. Which number.
    $candidates = @()
    if ($wanted) {
        $rec = Get-CsPhoneNumberAssignment -TelephoneNumber $wanted -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $rec) { throw "the case asks for $wanted, but that number isn't in this tenant's Teams numbers" }
        $holder = [string](Get-CtgProp $rec 'AssignedPstnTargetId')
        if ($holder) { throw "the case asks for $wanted, but it's already assigned (to $holder)" }
        $candidates = @($rec)
        $actions.Add("using the number entered on the case: $wanted")
    }
    else {
        $area = [string](Get-CtgProp $Config 'areaCode')
        $prefix = ConvertTo-CtgTeamsAreaPrefix $area
        if (-not $prefix) {
            $office = [string](Get-CtgProp $Config 'office')
            throw "no area code for this user's office$(if ($office) { " ('$office')" }) — add it to the client's phoneByAreaCode, or enter a number on the case"
        }
        $pool = @(Get-CsPhoneNumberAssignment -NumberType $numberType -PstnAssignmentStatus Unassigned -CapabilitiesContain UserAssignment -Top 1000 -ErrorAction Stop)
        $candidates = @(Select-CtgTeamsFreeNumbers -Numbers $pool -Prefix $prefix -NumberType $numberType)
        if ($candidates.Count -eq 0) {
            $actions.Add("WARN no free $numberType number starting $prefix in the tenant — acquire one in the Teams admin centre, or enter a number on the case (checking again in an hour)")
            return & $result $null 60
        }
        $actions.Add("$($candidates.Count) free number(s) starting $prefix; taking the first")
    }

    # 4. Assign. Two onboardings can pick the same free number at once; the loser's assignment fails,
    #    so try the next few rather than failing the step.
    $location = [string](Get-CtgProp $Config 'emergencyLocationId')
    $lastError = $null
    foreach ($c in @($candidates | Select-Object -First 3)) {
        $tn = ConvertTo-CtgTeamsE164 ([string](Get-CtgProp $c 'TelephoneNumber'))
        $loc = if ($location) { $location } else { [string](Get-CtgProp $c 'LocationId') }
        $assign = @{ Identity = $upn; PhoneNumber = $tn; PhoneNumberType = $numberType; ErrorAction = 'Stop' }
        if ($loc) { $assign.LocationId = $loc }
        if (-not $PSCmdlet.ShouldProcess($upn, "Assign Teams number $tn")) {
            $actions.Add("would assign Teams number $tn to $upn (WhatIf)")
            return & $result $tn $null
        }
        try {
            Set-CsPhoneNumberAssignment @assign | Out-Null
            $actions.Add("assigned Teams number $tn to $upn")
            return & $result $tn $null
        }
        catch {
            $lastError = $_.Exception.Message
            $actions.Add("WARN could not assign ${tn}: $lastError")
            if ($wanted) { break }
        }
    }
    $hint = if ($lastError -match '(?i)location|emergency|address') { ' — the number may need an emergency location: set emergencyLocationByOffice on the client''s Teams config' } else { '' }
    throw "could not assign a Teams number to ${upn}: $lastError$hint"
}

function Invoke-CtgTeamsOffboarding {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$User, $Config)
    $actions = [System.Collections.Generic.List[string]]::new()
    $upn = Get-CtgTeamsUpn $User
    if (-not $upn) { throw 'no user principal name on the case to release a Teams number from' }
    $numbers = @(Get-CtgTeamsAssignedNumbers -Upn $upn)
    if ($numbers.Count -eq 0) {
        $actions.Add("$upn has no Teams number — nothing to release")
        return [pscustomobject]@{ System = 'teams'; Status = 'ok'; ReleasedNumbers = @(); Actions = $actions.ToArray() }
    }
    if ($PSCmdlet.ShouldProcess($upn, "Release Teams number(s) $($numbers -join ', ')")) {
        Remove-CsPhoneNumberAssignment -Identity $upn -RemoveAll -ErrorAction Stop | Out-Null
        $actions.Add("released Teams number $($numbers -join ', ') from $upn (back in the tenant's pool)")
    }
    else { $actions.Add("would release Teams number $($numbers -join ', ') from $upn (WhatIf)") }
    [pscustomobject]@{ System = 'teams'; Status = 'ok'; ReleasedNumbers = $numbers; Actions = $actions.ToArray() }
}

function Confirm-CtgTeams {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$User, $Config, [string]$Action = 'onboard')
    $upn = Get-CtgTeamsUpn $User
    # @(...) around the whole if: an if that yields one number would otherwise unwrap it to a string.
    $numbers = @(if ($upn) { Get-CtgTeamsAssignedNumbers -Upn $upn })
    if ($Action -eq 'offboard') {
        $pass = $numbers.Count -eq 0
        return [pscustomobject]@{ ok = $pass; checks = @(@{ name = 'no Teams number assigned'; expected = 'none'; actual = $(if ($numbers.Count) { $numbers -join ', ' } else { 'none' }); pass = $pass }) }
    }
    $wanted = ConvertTo-CtgTeamsE164 ([string](Get-CtgProp $Config 'phoneNumber'))
    $pass = if ($wanted) { $numbers -contains $wanted } else { $numbers.Count -gt 0 }
    [pscustomobject]@{ ok = $pass; checks = @(@{ name = $(if ($wanted) { "Teams number $wanted assigned" } else { 'a Teams number assigned' }); expected = $(if ($wanted) { $wanted } else { 'a number' }); actual = $(if ($numbers.Count) { $numbers -join ', ' } else { 'none' }); pass = $pass }) }
}

# ── The out-of-process hand-off (runs in the runner) ────────────────────────────────────────────────

# The child prints progress lines as-is and exactly one "RESULT<tab><base64 JSON>" or
# "FAIL<tab><base64 message>" line. Anything else — a crash, a missing module, silence — is reported as
# a failure with the child's last lines, never read as success.
function ConvertFrom-CtgTeamsChildOutput {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Lines = @(), [int]$ExitCode = 0)
    $decode = { param($b) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) }
    $clean = @($Lines | Where-Object { $_ -and $_.Trim() })
    $fail = @($clean | Where-Object { $_ -like "FAIL`t*" }) | Select-Object -Last 1
    if ($fail) { throw (& $decode $fail.Substring(5)) }
    $ok = @($clean | Where-Object { $_ -like "RESULT`t*" }) | Select-Object -Last 1
    if ($ok) { return (& $decode $ok.Substring(7)) | ConvertFrom-Json }
    $tail = ($clean | Select-Object -Last 4) -join ' | '
    throw "the Teams helper process exited ($ExitCode) without a result$(if ($tail) { ": $tail" } else { ' and printed nothing' })"
}

function Invoke-CtgTeamsOutOfProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('onboard', 'offboard', 'validate')][string]$Action,
        [Parameter(Mandatory)]$User,
        $Config,
        [string]$ValidateAction = 'onboard',
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$Tenant,
        [hashtable]$CertArgs = @{},
        [int]$TimeoutSeconds = 600,
        # Test seam: a module standing in for MicrosoftTeams (no tenant on a test host). Production
        # leaves it empty and the child imports MicrosoftTeams itself.
        [string]$TeamsModulePath = '',
        [string]$ModulePath = (Join-Path $PSScriptRoot 'Coretelligent.Teams.psd1')
    )
    $pwshPath = (Get-Process -Id $PID).Path
    if (-not $pwshPath -or $pwshPath -notmatch '(?i)pwsh(\.exe)?$') { $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
    if (-not $pwshPath) { throw 'cannot locate pwsh to run the Teams step in a clean process' }

    # A dry run sets $WhatIfPreference in this process only; the child is told explicitly, or it would
    # assign/release for real. File work uses .NET calls because New-Item/Set-Content honour WhatIf and
    # would silently not write the request under a dry run (#122).
    $dryRun = [bool]$WhatIfPreference
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ctg-teams-" + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($dir)
    if (-not $IsWindows) { & chmod 700 $dir 2>$null }
    $requestPath = Join-Path $dir 'request.json'
    $childPath = Join-Path $dir 'teams.ps1'
    try {
        $request = @{ Action = $Action; ValidateAction = $ValidateAction; User = $User; Config = $Config; AppId = $AppId; Tenant = $Tenant; CertArgs = $CertArgs; WhatIf = $dryRun; ModulePath = $ModulePath; TeamsModulePath = $TeamsModulePath }
        [System.IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 10 -Compress))
        if (-not $IsWindows) { & chmod 600 $requestPath 2>$null }
        # The child reads the request, deletes it (it holds the certificate), then does the work.
        $child = @'
param([string]$RequestPath)
$ErrorActionPreference = 'Stop'
$enc = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$s)) }
try {
    $p = [System.IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json
    [System.IO.File]::Delete($RequestPath)
    if ($p.TeamsModulePath) { Import-Module $p.TeamsModulePath -Force }
    else {
        if (-not (Get-Module -ListAvailable MicrosoftTeams)) {
            Write-Output 'MicrosoftTeams is not installed on this runner host — installing it for the current user'
            Install-Module MicrosoftTeams -Scope CurrentUser -Force -AllowClobber -AcceptLicense -Confirm:$false
        }
        Import-Module MicrosoftTeams
    }
    Import-Module $p.ModulePath -Force
    $cert = $null
    if ($p.CertArgs.CertificateBase64) {
        $bytes = [Convert]::FromBase64String(([string]$p.CertArgs.CertificateBase64 -replace '\s', ''))
        # EphemeralKeySet keeps the private key off disk on Windows; macOS refuses it ("This platform does
        # not support loading with EphemeralKeySet", see Connect-CtgExchange), where the default is used.
        $flags = if ($IsWindows) { 'EphemeralKeySet' } else { 'DefaultKeySet' }
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes, [string]$p.CertArgs.CertificatePassword, $flags)
    }
    elseif ($p.CertArgs.CertificateThumbprint) {
        $tp = [string]$p.CertArgs.CertificateThumbprint
        if (-not $IsWindows) { throw 'a CertificateThumbprint only works on a Windows runner (it reads the Windows certificate store) — store the certificate as CertificateBase64 on the m365-admin secret instead' }
        $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object Thumbprint -eq $tp | Select-Object -First 1
        if (-not $cert) { throw "certificate $tp is not in this host's certificate store" }
    }
    else { throw 'the m365-admin secret has no certificate (CertificateBase64 or CertificateThumbprint) for Teams app-only sign-in' }
    Connect-MicrosoftTeams -TenantId $p.Tenant -ApplicationId $p.AppId -Certificate $cert | Out-Null
    $whatIf = [bool]$p.WhatIf
    $r = switch ($p.Action) {
        'onboard'  { Invoke-CtgTeamsOnboarding  -User $p.User -Config $p.Config -WhatIf:$whatIf }
        'offboard' { Invoke-CtgTeamsOffboarding -User $p.User -Config $p.Config -WhatIf:$whatIf }
        'validate' { Confirm-CtgTeams -User $p.User -Config $p.Config -Action $p.ValidateAction }
    }
    Write-Output ("RESULT`t" + (& $enc ($r | ConvertTo-Json -Depth 8 -Compress)))
}
catch { Write-Output ("FAIL`t" + (& $enc $_.Exception.Message)) }
finally { try { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null } catch { } }
'@
        [System.IO.File]::WriteAllText($childPath, $child)

        $psi = [System.Diagnostics.ProcessStartInfo]::new($pwshPath)
        foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $childPath, '-RequestPath', $requestPath)) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        # Enforced: a child that never returns would otherwise hold the job until the stall watchdog.
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill($true) } catch { }
            throw "the Teams step didn't finish within $TimeoutSeconds seconds and was stopped"
        }
        $proc.WaitForExit()
        $lines = @(($stdout.Result + "`n" + $stderr.Result) -split "`r?`n")
        return ConvertFrom-CtgTeamsChildOutput -Lines $lines -ExitCode $proc.ExitCode
    }
    finally { try { [System.IO.Directory]::Delete($dir, $true) } catch { } }
}

Export-ModuleMember -Function ConvertTo-CtgTeamsE164, ConvertTo-CtgTeamsAreaPrefix, Test-CtgTeamsVoiceReady, Select-CtgTeamsFreeNumbers, Get-CtgTeamsUpn, Get-CtgTeamsAssignedNumbers, Invoke-CtgTeamsOnboarding, Invoke-CtgTeamsOffboarding, Confirm-CtgTeams, ConvertFrom-CtgTeamsChildOutput, Invoke-CtgTeamsOutOfProcess
