#Requires -Version 7.0

# Coretelligent.ActiveDirectory
# On-prem AD user lifecycle. Runs on the client-network agent against the local DC (the
# ActiveDirectory PowerShell module), never centrally. Identity origin for ad-synced /
# ad-standalone clients. Everything is idempotent: safe to re-run after a partial failure.
#
# Public surface:
#   Invoke-CtgADOnboarding   - create user in the OU, attributes, home drive, groups
#   Invoke-CtgADOffboarding  - reset, evidence + remove groups, hide-GAL, disable, (maybe) move
#
# The do-not-move-ou guardrail is load-bearing: for some clients moving the user's OU deletes
# the synced 365 account, so the move is skipped when the guardrail is present.

Set-StrictMode -Version Latest

#region helpers ---------------------------------------------------------------

function Get-CtgProp {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# Narrate into the live run-report progress (Send-CtgProgress is the runner's global poster; absent
# under Pester, so guard it). Narration must never change behaviour.
function Write-CtgADStep([string]$Message) {
    if (Get-Command Send-CtgProgress -ErrorAction SilentlyContinue) { Send-CtgProgress $Message }
}

# Does an AD error mean the requested attribute isn't in this directory's schema? (The msExch*
# attributes exist only where the on-prem Exchange schema is installed — "One or more properties
# are invalid" family.) Used to tell "can never work here" apart from a transient DC/ADWS error.
function Test-CtgADSchemaMissingError([string]$Message) {
    return $Message -match '(?i)properties are invalid|no such attribute|attribute .* (does not exist|not found)'
}

# Domain FQDN -> distinguished name: "61commodities.com" -> "DC=61commodities,DC=com".
function ConvertTo-CtgDomainDn {
    param([string]$Domain)
    if ([string]::IsNullOrWhiteSpace($Domain)) { return '' }
    ($Domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
}

# Resolve an OU config value to a full DN. Accepts a full DN, or a bare OU name to be placed
# under the client's domain root.
function Resolve-CtgOuPath {
    param([string]$Ou, [string]$Domain)
    if ([string]::IsNullOrWhiteSpace($Ou)) { return (ConvertTo-CtgDomainDn $Domain) }
    if ($Ou -match 'DC=') { return $Ou }                     # already a full DN
    if ($Ou -match '^OU=') { return "$Ou,$(ConvertTo-CtgDomainDn $Domain)" }
    "OU=$Ou,$(ConvertTo-CtgDomainDn $Domain)"
}

# The base for AD DNs must be the ACTUAL AD domain (from the connected DC), NOT the user's email/UPN
# PrimaryDomain. They differ whenever the AD domain is a subdomain of the mail domain (AD
# corp.example.com vs mail example.com) — and building a DN from the mail domain targets a naming
# context the DC isn't authoritative for, so New-ADUser fails "The server is unwilling to process the
# request". Query the connected domain (honouring the -Server/-Credential splat); fall back to the
# supplied email domain only if the query fails, so read-only/offline callers still get *a* value.
function Resolve-CtgAdDomain {
    param([hashtable]$AdConnection = @{}, [string]$Fallback)
    try {
        $root = (Get-ADDomain @AdConnection -ErrorAction Stop).DNSRoot
        if ($root) { return [string]$root }
    } catch { }
    return $Fallback
}

# Space/punctuation-insensitive AD group lookup. A profile often has a group name that's off only by
# spacing ("Perimeter81 Users" vs the real "Perimeter 81 Users") or punctuation. Try the exact identity
# first; if that misses, search a small candidate set (by the first alphabetic token) and match on a
# NORMALIZED name (letters+digits only, lowercased). Returns the AD group object on a SINGLE confident
# match, else $null (0 or ambiguous -> caller keeps the original name + warns). Read-only.
function Resolve-CtgAdGroup {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$AdConnection = @{})
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $exact = Get-ADGroup -Identity $Name -ErrorAction SilentlyContinue @AdConnection
    if ($exact) { return $exact }
    $norm = { param($s) ([string]$s -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }
    $target = & $norm $Name
    if (-not $target) { return $null }
    $token = ([regex]::Match($Name, '[A-Za-z]{3,}')).Value   # keep the AD query narrow
    if (-not $token) { return $null }
    $cands = @(Get-ADGroup -Filter "Name -like '*$token*'" -ErrorAction SilentlyContinue @AdConnection)
    $hits = @($cands | Where-Object { (& $norm $_.Name) -eq $target })
    if (@($hits).Count -eq 1) { return $hits[0] }
    return $null
}

# Evaluate a conditional-group rule like "avd == true" against the user object.
function Test-CtgCondition {
    param([string]$When, $User)
    if ([string]::IsNullOrWhiteSpace($When)) { return $true }
    if ($When -match '^\s*(\w+)\s*==\s*(true|false)\s*$') {
        $field = $Matches[1]; $want = [bool]::Parse($Matches[2])
        $have = [bool](Get-CtgProp $User $field)
        return ($have -eq $want)
    }
    return $false   # unrecognized condition -> don't add (reviewer can widen later)
}

#endregion

# Apply a directory-attribute map (the planner's resolved $Config.attributes) generically: each
# attribute is Set-ADUser -Replace'd, so a new attribute is a profile edit with NO module change.
# `manager` is special — it's a DN-valued attribute, so a readable name is resolved to a DN first.
# Returns the list of applied "name=value" pairs (for the actions log).
function Set-CtgADAttributes {
    # $AdConnection is splatted onto every AD cmdlet: @{ Server=<dc>; Credential=<pscred> } when the
    # brokered ad-dc secret drives auth (Option 2), or empty @{} to use the runner's ambient context.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Identity, $Attributes, [hashtable]$AdConnection = @{})
    $applied = [System.Collections.Generic.List[string]]::new()
    if (-not $Attributes) { return $applied.ToArray() }
    # Works for a JSON-deserialized pscustomobject (production) or a hashtable (tests).
    $names = if ($Attributes -is [hashtable]) { @($Attributes.Keys) } else { @($Attributes.PSObject.Properties.Name) }
    foreach ($name in $names) {
        $value = if ($Attributes -is [hashtable]) { $Attributes[$name] } else { $Attributes.$name }
        if ($null -eq $value -or "$value" -eq '') { continue }
        if ($name -ieq 'manager') {
            # already a DN? else resolve by name — escape quotes, and refuse to guess on ambiguity.
            $dn = if ("$value" -match '^(CN|OU)=') {
                "$value"
            }
            else {
                $safe = "$value" -replace "'", "''"
                $found = @(Get-ADUser -Filter "Name -eq '$safe'" -ErrorAction SilentlyContinue @AdConnection)
                if ($found.Count -gt 1) { Write-Warning "manager '$value' is ambiguous ($($found.Count) matches) — skipped"; $null }
                elseif ($found.Count -eq 1) { $found[0].DistinguishedName }
                else { $null }
            }
            if ($dn -and $PSCmdlet.ShouldProcess($Identity, "Set manager = $dn")) {
                Set-ADUser -Identity $Identity -Manager $dn -ErrorAction Continue @AdConnection
                $applied.Add("manager=$dn")
            }
            continue
        }
        # countryCode is an Integer-syntax AD attribute; cast so a templated "840" doesn't fail.
        $replaceVal = if ($name -ieq 'countryCode') { [int]$value } else { $value }
        if ($PSCmdlet.ShouldProcess($Identity, "Set $name = $value")) {
            Set-ADUser -Identity $Identity -Replace @{ $name = $replaceVal } -ErrorAction Continue @AdConnection
            $applied.Add("$name=$value")
        }
    }
    return $applied.ToArray()
}

# Resolve the "mirror <user>" directive to that reference user's live group memberships (DNs).
# Tries DisplayName, then Name, then SamAccountName. Returns the group-DN array (possibly empty)
# when the user is found, or $null when no such user — so the caller can flag a miss vs. an
# intentionally-empty membership.
# Resolve the "make them like <X>" reference user and return their group DNs, or $null when no such
# user exists.
#
# The identifier form is NOT ours to choose. The intake field is free text and, in practice, is almost
# always an EMAIL: 36 of the last 40 mirror requests were addresses, not names. This used to try only
# DisplayName, Name and SamAccountName, so every one of those missed and the step reported "mirror user
# not found — mirror groups not applied" while the cloud lane, whose resolver handles a UPN, mirrored
# the same person happily (FR #0000126 — UM0031004, roxana@agostinofoods.com).
#
# So: try the mail-shaped attributes FIRST when the value contains an "@", and the name-shaped ones
# first when it does not. Both sets are always tried — a display name containing an @ is unlikely but
# costs one extra query to rule out, and an address stored only in `mail` still resolves.
function Get-CtgMirrorGroups {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReferenceUser, [hashtable]$AdConnection = @{})
    $esc = $ReferenceUser -replace "'", "''"
    # EmailAddress is the AD `mail` attribute as the ActiveDirectory module surfaces it; a mirror user
    # whose UPN differs from their SMTP address (common after a domain change) resolves on the second.
    $byMail = @("UserPrincipalName -eq '$esc'", "EmailAddress -eq '$esc'")
    $byName = @("DisplayName -eq '$esc'", "Name -eq '$esc'", "SamAccountName -eq '$esc'")
    $filters = if ($ReferenceUser -like '*@*') { @($byMail) + @($byName) } else { @($byName) + @($byMail) }
    foreach ($filter in $filters) {
        $ref = Get-ADUser -Filter $filter -Properties MemberOf -ErrorAction SilentlyContinue @AdConnection | Select-Object -First 1
        if ($ref) { return ,@($ref.MemberOf) }
    }
    return $null
}

function Invoke-CtgADOnboarding {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        # Brokered AD auth (Option 2): @{ Server=<dc>; Credential=<pscred> } — splatted onto every AD
        # cmdlet so the runner authenticates as the ad-dc account rather than its own process identity.
        [hashtable]$AdConnection = @{}
    )
    $actions = [System.Collections.Generic.List[string]]::new()
    $primarySam = Get-CtgProp $User 'SamAccountName'   # StrictMode-safe
    $primaryUpn = [string]$User.UserPrincipalName
    $domain = Resolve-CtgAdDomain -AdConnection $AdConnection -Fallback (Get-CtgProp $User 'PrimaryDomain')
    $ouPath = Resolve-CtgOuPath (Get-CtgProp $Config 'ou') $domain

    # 1. Decide WHICH account to use before creating one: check existence, confirm it's the same
    # person (name match), else fall back to an alternate username (or pause for a decision); if it
    # is, adopt it and reconcile the rest below. Mirrors Invoke-CtgM365Onboarding / Google. Candidate
    # (sam, upn) pairs = the primary plus each UPN fallback (its local part is the SamAccountName).
    $candPairs = [System.Collections.Generic.List[object]]::new()
    $candPairs.Add(@($primarySam, $primaryUpn))
    foreach ($fu in @(Get-CtgProp $User 'UserPrincipalNameFallbacks')) {
        if ($fu) { $candPairs.Add(@((($fu -split '@')[0]), [string]$fu)) }
    }
    # drop malformed locals (leading/trailing/double separator — a DC rejects them)
    $candPairs = @($candPairs | Where-Object { $_[0] -and ($_[0] -notmatch '(^[._-]|[._-]$|[._-]{2,})') })
    $wantFirst = ([string]$User.FirstName).Trim()
    $wantLast  = ([string]$User.LastName).Trim()
    $wantName  = ([string]$User.DisplayName).Trim()
    # A nicknamed hire ("Bill" for William) carries the nickname in FirstName/DisplayName; the legal
    # first name rides along as LegalFirstName. A rehire's existing account was created from the
    # LEGAL name, so same-person matching must accept either — else a rehire reads as a collision.
    $wantLegalFirst = ([string](Get-CtgProp $User 'LegalFirstName')).Trim()
    $wantLegalName  = if ($wantLegalFirst -and $wantLast) { "$wantLegalFirst $wantLast" } else { '' }
    # 'adopt' = it's ours, unset = pause for a decision; a different name auto-falls-back regardless.
    $collisionPolicy = [string](Get-CtgProp $Config 'usernameCollisionPolicy')

    $sam = $null; $chosenUpn = $null; $existing = $null
    foreach ($pair in $candPairs) {
        $cand = $pair[0]; $candUpn = $pair[1]
        $found = Get-ADUser -Filter "SamAccountName -eq '$cand'" -Properties GivenName, Surname, DisplayName -ErrorAction SilentlyContinue @AdConnection
        if (-not $found) { $sam = $cand; $chosenUpn = $candUpn; break }
        $fGiven = ([string](Get-CtgProp $found 'GivenName')).Trim()
        $fSur   = ([string](Get-CtgProp $found 'Surname')).Trim()
        $fDisp  = ([string](Get-CtgProp $found 'DisplayName')).Trim()
        $sameName = ($wantFirst -and $wantLast -and $fGiven -ieq $wantFirst -and $fSur -ieq $wantLast) -or ($wantName -and $fDisp -ieq $wantName) `
            -or ($wantLegalFirst -and $wantLast -and $fGiven -ieq $wantLegalFirst -and $fSur -ieq $wantLast) -or ($wantLegalName -and $fDisp -ieq $wantLegalName)
        if ($sameName) {
            $sam = $cand; $chosenUpn = $candUpn; $existing = $found
            $actions.Add("user exists ($cand) and matches '$(if ($fDisp) { $fDisp } else { "$fGiven $fSur" })' — same person (re-run), skipped create"); break
        }
        if (-not ($fGiven -or $fSur -or $fDisp)) {
            $sam = $cand; $chosenUpn = $candUpn; $existing = $found
            $actions.Add("user exists ($cand) — adopted (no name on the account to confirm), skipped create"); break
        }
        if ($collisionPolicy -ieq 'adopt') {
            $sam = $cand; $chosenUpn = $candUpn; $existing = $found
            $actions.Add("user exists ($cand) as '$fDisp' — operator chose ADOPT, skipped create"); break
        }
        $actions.Add("SamAccountName '$cand' is taken by a different user ($fDisp) — trying the next pattern")
    }
    if (-not $sam) {
        throw "DECISION_NEEDED:username_collision | Every candidate SamAccountName is taken by a different person: $(@($candPairs | ForEach-Object { $_[0] }) -join ', '). Add a username fallback pattern, or set usernameCollisionPolicy=adopt to reuse the existing account. | upn=$primaryUpn | name=$wantName"
    }
    if ($sam -ne $primarySam) { $actions.Add("using fallback username: $sam (primary $primarySam taken)") }

    if (-not $existing -and $PSCmdlet.ShouldProcess($sam, "Create AD user in $ouPath")) {
        # A DC won't enable an account without an initial password. Caller may override later /
        # set the same upstream password for mirror clients; this is a compliant placeholder.
        $initial = ConvertTo-SecureString ([System.Guid]::NewGuid().ToString() + '!Aa9') -AsPlainText -Force
        # Wrap so a create failure names the resolved target DN — a bare "unwilling to process the
        # request" hides WHERE it tried to write (the #1 cause is a wrong/nonexistent OU DN).
        try {
            New-ADUser -Name $User.DisplayName -SamAccountName $sam -UserPrincipalName $chosenUpn `
                -GivenName $User.FirstName -Surname $User.LastName -DisplayName $User.DisplayName `
                -Path $ouPath -Enabled $true -AccountPassword $initial `
                -OtherAttributes @{ proxyAddresses = "SMTP:$chosenUpn" } @AdConnection
        } catch {
            throw "creating user '$sam' at '$ouPath' (domain $domain): $($_.Exception.Message)"
        }
        $actions.Add("created user $sam in $ouPath")
    }

    # 2. Home drive ------------------------------------------------------------
    $home = Get-CtgProp $Config 'homeDrive'
    if ($home) {
        $unc = ((Get-CtgProp $home 'unc') -replace '<username>', $sam)
        $letter = (Get-CtgProp $home 'letter')
        if ($PSCmdlet.ShouldProcess($sam, "Map home drive ${letter}: -> $unc")) {
            Set-ADUser -Identity $sam -HomeDrive "${letter}:" -HomeDirectory $unc @AdConnection
            $actions.Add("mapped home drive ${letter}: -> $unc")
        }
    }

    # 3. Directory attributes (resolved by the planner) ------------------------
    foreach ($a in (Set-CtgADAttributes -Identity $sam -Attributes (Get-CtgProp $Config 'attributes') -AdConnection $AdConnection)) {
        $actions.Add("set attribute: $a")
    }

    # 4. Groups: base + conditional --------------------------------------------
    $groups = [System.Collections.Generic.List[string]]::new()
    foreach ($g in @(Get-CtgProp $Config 'groups')) { if ($g) { $groups.Add([string]$g) } }
    foreach ($cg in @(Get-CtgProp $Config 'conditionalGroups')) {
        if (Test-CtgCondition (Get-CtgProp $cg 'when') $User) {
            foreach ($g in @(Get-CtgProp $cg 'groups')) { if ($g) { $groups.Add([string]$g) } }
        }
    }
    # Mirror: union the reference user's live memberships (the "make them like <X>" request). Deduped
    # against the groups already chosen; Add-ADGroupMember below is idempotent, and DNs add fine.
    $mirrorUser = Get-CtgProp $Config 'mirrorFromUser'
    if ($mirrorUser) {
        $mirrorGroups = Get-CtgMirrorGroups -ReferenceUser ([string]$mirrorUser) -AdConnection $AdConnection
        if ($null -eq $mirrorGroups) {
            $actions.Add("mirror user '$mirrorUser' not found — mirror groups not applied")
        }
        else {
            $seen = [System.Collections.Generic.HashSet[string]]::new([string[]]$groups, [System.StringComparer]::OrdinalIgnoreCase)
            $added = 0
            foreach ($dn in $mirrorGroups) { if ($dn -and $seen.Add([string]$dn)) { $groups.Add([string]$dn); $added++ } }
            $actions.Add("mirrored $added group(s) from '$mirrorUser'")
        }
    }
    foreach ($group in $groups) {
        if ($PSCmdlet.ShouldProcess($sam, "Add to group $group")) {
            # -ErrorAction Stop so a real failure is visible (was SilentlyContinue, which claimed
            # success even when the add failed). "Already a member" is success. ✓/✗ to the live status.
            try {
                Add-ADGroupMember -Identity $group -Members $sam -ErrorAction Stop @AdConnection
                $actions.Add("added to group: $group")
                Write-CtgADStep "✓ added to group: $group"
            } catch {
                $msg = $_.Exception.Message
                if ($msg -match 'already a member') {
                    $actions.Add("already in group: $group")
                    Write-CtgADStep "✓ already in group: $group"
                } elseif ($msg -match '[Cc]annot find|does not exist|No such object|not.*found|identity') {
                    # Group name is likely off by spacing/punctuation ("Perimeter81 Users" vs the real
                    # "Perimeter 81 Users"). Resolve it to a real AD group by a normalized match and retry.
                    $resolved = Resolve-CtgAdGroup -Name $group -AdConnection $AdConnection
                    if ($resolved) {
                        try {
                            Add-ADGroupMember -Identity $resolved.DistinguishedName -Members $sam -ErrorAction Stop @AdConnection
                            $actions.Add("added to group: $($resolved.Name) (matched config '$group')")
                            Write-CtgADStep "✓ group: $($resolved.Name) — matched '$group'"
                        } catch {
                            if ($_.Exception.Message -match 'already a member') { $actions.Add("already in group: $($resolved.Name) (matched '$group')") }
                            else { $actions.Add("WARN could not add to group '$($resolved.Name)' (matched '$group'): $($_.Exception.Message)") ; Write-CtgADStep "✗ group: $($resolved.Name) — $($_.Exception.Message)" }
                        }
                    } else {
                        $actions.Add("WARN group not found in AD: '$group' (no unique space/punctuation match — check the name in the rules editor)")
                        Write-CtgADStep "✗ group not found: $group"
                    }
                } else {
                    $actions.Add("WARN could not add to group ${group}: $msg")
                    Write-CtgADStep "✗ group: $group — $msg"
                }
            }
        }
    }

    [pscustomobject]@{ System = 'active-directory'; Status = 'ok'; Sam = $sam; Ou = $ouPath; Actions = $actions.ToArray() }
}

# Change/mover lane: apply a delta to an EXISTING AD user — add groups, remove groups (by name or
# by full reconcile against a desired set), move OU, set attributes. Reuses the same primitives as
# onboarding/offboarding (Resolve-CtgAdGroup for a fuzzy group-name miss, Test-CtgADProtectedGroup to
# refuse stripping a privileged group, Set-CtgADAttributes for the attribute map). Idempotent: adding
# an already-held group or removing one the user isn't in just narrates, never throws.
function Invoke-CtgADChange {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        # Brokered AD auth (Option 2): @{ Server=<dc>; Credential=<pscred> } — splatted onto every AD
        # cmdlet so the runner authenticates as the ad-dc account rather than its own process identity.
        [hashtable]$AdConnection = @{}
    )
    $actions = [System.Collections.Generic.List[string]]::new()
    $sam = [string]((Get-CtgProp $User 'SamAccountName') ?? (Get-CtgProp $User 'sam'))
    if (-not $sam) { throw "Invoke-CtgADChange: no SamAccountName on the target user" }

    # ADD ------------------------------------------------------------------
    foreach ($g in @(Get-CtgProp $Config 'groups')) {
        if (-not $g) { continue }
        if (Test-CtgADProtectedGroup -Group ([pscustomobject]@{ Name = $g }) -Config $Config) { $actions.Add("refused protected group: $g"); continue }
        if ($PSCmdlet.ShouldProcess($sam, "Add to group $g")) {
            try { Add-ADGroupMember -Identity $g -Members $sam -ErrorAction Stop @AdConnection; $actions.Add("added to group: $g") }
            catch {
                if ($_.Exception.Message -match 'already a member') { $actions.Add("already in group: $g") }
                else {
                    # Group name likely off by spacing/punctuation — retry against a normalized match
                    # before giving up (mirrors Invoke-CtgADOnboarding's group-add fallback).
                    $resolved = Resolve-CtgAdGroup -Name $g -AdConnection $AdConnection
                    if ($resolved) {
                        try { Add-ADGroupMember -Identity $resolved.DistinguishedName -Members $sam -ErrorAction Stop @AdConnection; $actions.Add("added to group: $($resolved.Name) (matched config '$g')") }
                        catch {
                            if ($_.Exception.Message -match 'already a member') { $actions.Add("already in group: $($resolved.Name) (matched '$g')") }
                            else { $actions.Add("WARN could not add to group '$($resolved.Name)' (matched '$g'): $($_.Exception.Message)") }
                        }
                    } else { $actions.Add("WARN group not found in AD: '$g' (no unique space/punctuation match — check the name in the rules editor)") }
                }
            }
        }
    }

    # REMOVE by name, and/or full reconcile to desiredGroups -----------------
    $removeNames = @(Get-CtgProp $Config 'removeGroups' | Where-Object { $_ })
    $reconcile = (Get-CtgProp $Config 'reconcileGroups') -eq $true
    if ($removeNames.Count -or $reconcile) {
        $memberships = @(Get-ADPrincipalGroupMembership -Identity $sam -ErrorAction SilentlyContinue @AdConnection)
        $desired = @(Get-CtgProp $Config 'desiredGroups' | ForEach-Object { "$_".ToLower() })
        foreach ($g in $memberships) {
            $name = [string]$g.Name
            if ($name -ieq 'Domain Users') { continue }
            $isNamedForRemoval = [bool]($removeNames | Where-Object { $_ -ieq $name })
            if (Test-CtgADProtectedGroup -Group $g -Config $Config) {
                if ($isNamedForRemoval) { $actions.Add("refused protected group: $name") }
                continue
            }
            $shouldRemove = if ($reconcile) { -not ($desired -contains $name.ToLower()) } else { $isNamedForRemoval }
            if (-not $shouldRemove) { continue }
            $gid = if ($g.DistinguishedName) { $g.DistinguishedName } else { $g.Name }
            if ($PSCmdlet.ShouldProcess($sam, "Remove from group $name")) {
                # -ErrorAction Stop so a failed removal is surfaced, not silently logged as success
                # (mirrors Invoke-CtgADOffboarding's removeAllGroups path).
                try {
                    Remove-ADGroupMember -Identity $gid -Members $sam -Confirm:$false -ErrorAction Stop @AdConnection
                    $actions.Add("removed from group: $name")
                } catch {
                    $actions.Add("WARN could not remove from group $($name): $($_.Exception.Message)")
                }
            }
        }
        # A removeGroups entry the user isn't actually in — surface it rather than silently no-op.
        $memberNames = @($memberships | ForEach-Object { [string]$_.Name })
        foreach ($n in $removeNames) { if (-not ($memberNames -contains $n)) { $actions.Add("not a member of $n (skip)") } }
    }

    # OU move ------------------------------------------------------------
    $targetOu = Get-CtgProp $Config 'moveToOu'
    if ($targetOu) {
        if ("$targetOu" -notmatch '(?i)dc=') { $actions.Add("skipped move: '$targetOu' is not a full OU DN (expected OU=…,DC=…)") }
        else {
            $existing = Get-ADUser -Identity $sam -ErrorAction Stop @AdConnection
            if ($PSCmdlet.ShouldProcess($sam, "Move to $targetOu")) {
                Move-ADObject -Identity $existing.DistinguishedName -TargetPath $targetOu @AdConnection
                $actions.Add("moved to $targetOu")
            }
        }
    }

    # Attributes -----------------------------------------------------------
    foreach ($a in (Set-CtgADAttributes -Identity $sam -Attributes (Get-CtgProp $Config 'attributes') -AdConnection $AdConnection)) {
        $actions.Add("set attribute: $a")
    }

    [pscustomobject]@{ System = 'active-directory'; Status = 'ok'; Sam = $sam; Actions = $actions.ToArray() }
}

function Test-CtgADProtectedGroup {
    # Is this group a privileged group to NEVER strip on offboard? Used by BOTH the executor (skip
    # removal) and the validator (don't count as a miss):
    #   - well-known privileged group NAMES (the add-on),
    #   - an "*Privileged* OU" DN pattern (matches Offboarding_User.ps1's protected-group detection),
    #   - an explicit config list (protectedGroups).
    # protectPrivilegedGroups:false disables it. Config: protectedGroupPattern, protectedGroups.
    param($Group, $Config)
    if ((Get-CtgProp $Config 'protectPrivilegedGroups') -eq $false) { return $false }
    $wellKnown = @('Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators',
        'Account Operators', 'Backup Operators', 'Server Operators', 'Print Operators',
        'Group Policy Creator Owners', 'DnsAdmins', 'Key Admins', 'Enterprise Key Admins')
    $names = @($wellKnown + @(Get-CtgProp $Config 'protectedGroups' | Where-Object { $_ }) | ForEach-Object { "$_".ToLower() })
    if ($names -contains "$(Get-CtgProp $Group 'Name')".ToLower()) { return $true }
    $pattern = [string]((Get-CtgProp $Config 'protectedGroupPattern') ?? '*,OU=*Privileged,*')
    $dn = [string](Get-CtgProp $Group 'DistinguishedName')
    return ($pattern -and $dn -and ($dn -like $pattern))
}

# Shape AD user objects into the candidate rows the app's picker renders. Kept in ONE place so the
# ambiguous branch and the no-match branch can never disagree about the shape.
function ConvertTo-CtgAdCandidate {
    param($Users)
    @($Users | ForEach-Object {
        [pscustomobject]@{
            id                = [string](Get-CtgProp $_ 'DistinguishedName')
            upn               = [string](Get-CtgProp $_ 'UserPrincipalName')
            samAccountName    = [string](Get-CtgProp $_ 'SamAccountName')
            displayName       = [string](Get-CtgProp $_ 'DisplayName')
            jobTitle          = [string](Get-CtgProp $_ 'Title')
            department        = [string](Get-CtgProp $_ 'Department')
            enabled           = [bool](Get-CtgProp $_ 'Enabled')
            mail              = [string](Get-CtgProp $_ 'EmailAddress')
            distinguishedName = [string](Get-CtgProp $_ 'DistinguishedName')
            source            = 'active-directory'
        }
    })
}

# Candidates to offer a human when the name on the ticket matches NOBODY in AD. An exact search already
# failed, so searching exactly again cannot help: each token of the name is tried as a PREFIX against
# DisplayName / Surname / GivenName / SamAccountName, and the union comes back for the operator to pick
# from. @() when nobody is close.
function Get-CtgAdOffboardCandidates {
    param([string]$Name, [hashtable]$AdConnection = @{}, [int]$Limit = 10)
    if ([string]::IsNullOrWhiteSpace($Name)) { return @() }
    $props = @('SamAccountName', 'UserPrincipalName', 'DisplayName', 'Title', 'Department', 'Enabled', 'EmailAddress', 'DistinguishedName')
    $tokens = @($Name -split '\s+' | Where-Object { $_.Length -ge 2 })
    $found = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($t in $tokens) {
        $esc = $t -replace "'", "''"
        foreach ($field in @('DisplayName', 'Surname', 'GivenName', 'SamAccountName')) {
            # One failing probe (a field a schema doesn't index) must not lose what the others found.
            try { $hits = @(Get-ADUser -Filter "$field -like '$esc*'" -Properties $props -ErrorAction Stop @AdConnection) }
            catch { continue }
            foreach ($u in $hits) {
                $dn = [string](Get-CtgProp $u 'DistinguishedName')
                if ($dn -and $seen.Add($dn)) { $found.Add($u) }
            }
        }
    }
    @(ConvertTo-CtgAdCandidate (@($found) | Select-Object -First $Limit))
}

function Invoke-CtgADOffboarding {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [hashtable]$AdConnection = @{}
    )
    $actions = [System.Collections.Generic.List[string]]::new()
    # StrictMode-safe: the incident offboard payload may have no SamAccountName property at all.
    $sam = [string](Get-CtgProp $User 'SamAccountName')
    # `userToOffboard` is the last link in the name chain: a ServiceNow UM intake carries the leaver
    # ONLY under that key, so without it this resolves to nothing and the offboard silently no-ops
    # (reporting "no user identity on the case" while the account stays live).
    $displayName = [string]((Get-CtgProp $User 'DisplayName') ?? (Get-CtgProp $User 'userToOffboard'))
    # An email in the name slot (SNOW resolves the contact reference to one) identifies the user
    # directly — match it against the UPN rather than searching AD for a display name shaped like an email.
    $upnHint = [string]((Get-CtgProp $User 'UserPrincipalName') ?? (Get-CtgProp $User 'email'))
    if (-not $upnHint -and $displayName -match '@') {
        $upnHint = $displayName
        $displayName = ''
    }

    # Resolve by SamAccountName when present, then by UPN/email (exact, and what a ServiceNow contact
    # reference resolves to), else by DISPLAY NAME against AD (offboard intakes often carry only the
    # name). Exactly-one match is authoritative; 0/many -> stop with a clear note.
    $existing = $null
    if (-not [string]::IsNullOrWhiteSpace($sam)) {
        $existing = Get-ADUser -Identity $sam -Properties MemberOf, DistinguishedName, Manager -ErrorAction SilentlyContinue @AdConnection
    }
    if (-not $existing -and $upnHint) {
        $upnEsc = $upnHint -replace "'", "''"
        $byUpn = @(Get-ADUser -Filter "UserPrincipalName -eq '$upnEsc'" -Properties MemberOf, DistinguishedName, Manager -ErrorAction SilentlyContinue @AdConnection)
        if ($byUpn.Count -eq 1) {
            $existing = $byUpn[0]; $sam = [string](Get-CtgProp $existing 'SamAccountName')
            $actions.Add("resolved offboard target by UPN '$upnHint' -> $sam")
        }
    }
    if (-not $existing -and $displayName) {
        $dnEsc = $displayName -replace "'", "''"   # escape quotes so "Sean O'Brien" can't break the AD filter
        $byName = @(Get-ADUser -Filter "DisplayName -eq '$dnEsc'" -Properties MemberOf, DistinguishedName, Manager -ErrorAction SilentlyContinue @AdConnection)
        if ($byName.Count -eq 1) {
            $existing = $byName[0]; $sam = [string](Get-CtgProp $existing 'SamAccountName')
            $actions.Add("resolved offboard target by display name '$displayName' -> $sam")
        }
        elseif ($byName.Count -gt 1) {
            # SEVERAL people share this name. Never guess — hand the humans the shortlist and stop.
            return [pscustomobject]@{
                System='active-directory'; Status='ok'; Sam=$sam
                Actions=@("WARN $($byName.Count) AD users match display name '$displayName' — pick the right one on the case. Nothing done.")
                Candidates = @(ConvertTo-CtgAdCandidate $byName)
                CandidateQuery = $displayName
                CandidateReason = 'ambiguous'
                Evidence=@{ Groups=@() }
            }
        }
    }
    # NO identifier at all on the case: we could not even look the person up. This used to return
    # Status='ok' — a GREEN offboard step for an account that is still enabled, which is the worst way
    # for this to fail. Fail loudly instead.
    if (-not $sam -and -not $upnHint -and -not $displayName) {
        throw "active-directory: the case carries no SamAccountName, UPN, email or name for the user to offboard — set the offboard target on the case, then re-run."
    }
    if (-not $existing) {
        # Nobody matched. The name on the ticket is not the name in AD ("Parth Shah" vs "Parth K. Shah"),
        # so re-searching for it exactly can only fail again. Broaden and let a human choose, rather than
        # report "user not found" and leave the account enabled.
        $who = if ($sam) { $sam } else { $displayName }
        $cands = @(Get-CtgAdOffboardCandidates -Name $displayName -AdConnection $AdConnection)
        if ($cands.Count -gt 0) {
            return [pscustomobject]@{
                System='active-directory'; Status='ok'; Sam=$sam
                Actions=@("WARN no exact match for '$who' — $($cands.Count) similar AD user(s) found; pick the right one on the case. Nothing done.")
                Candidates = $cands
                CandidateQuery = $who
                CandidateReason = 'no-match'
                Evidence=@{ Groups=@() }
            }
        }
        return [pscustomobject]@{ System='active-directory'; Status='ok'; Sam=$sam; Actions=@("user not found ($who)"); Evidence=@{ Groups=@() } }
    }
    $guardrails = @(Get-CtgProp $Config 'guardrails')

    # 1. Reset password --------------------------------------------------------
    if ((Get-CtgProp $Config 'resetPassword')) {
        if ($PSCmdlet.ShouldProcess($sam, "Reset password")) {
            $new = ConvertTo-SecureString ([System.Guid]::NewGuid().ToString() + '!Aa9') -AsPlainText -Force
            Set-ADAccountPassword -Identity $sam -Reset -NewPassword $new @AdConnection
            $actions.Add("reset password")
        }
    }

    # 2. Evidence FIRST, then remove groups (primary group can't be removed) ----
    $memberships = @(Get-ADPrincipalGroupMembership -Identity $sam -ErrorAction SilentlyContinue @AdConnection)
    $groupNames = @($memberships | ForEach-Object { $_.Name })
    $actions.Add("captured $($groupNames.Count) group membership(s) as evidence")

    # 2a. Set "Disabled Users" as the PRIMARY group BEFORE stripping groups. A primary group can't be
    # removed while it's primary, and every user must have one — so make the Disabled Users group
    # primary first, which then lets remove-all-groups strip the original primary (e.g. Domain Users).
    $primaryGroup = [string]((Get-CtgProp $Config 'disabledUsersPrimaryGroup') ?? (Get-CtgProp $Config 'disabledUsersGroup'))
    if ($primaryGroup) {
        if ($PSCmdlet.ShouldProcess($sam, "Set '$primaryGroup' as primary group")) {
            try {
                $grp = Get-ADGroup -Identity $primaryGroup -Properties primaryGroupToken @AdConnection
                if (-not ($memberships | Where-Object { $_.Name -eq $grp.Name })) {
                    Add-ADGroupMember -Identity $grp -Members $sam -ErrorAction Stop @AdConnection
                    $actions.Add("added to $primaryGroup (for primary-group assignment)")
                }
                $current = (Get-ADUser -Identity $sam -Properties primaryGroupID @AdConnection).primaryGroupID
                if ($current -eq $grp.primaryGroupToken) {
                    $actions.Add("'$primaryGroup' is already the primary group — no change")
                }
                else {
                    Set-ADUser -Identity $sam -Replace @{ primaryGroupID = $grp.primaryGroupToken } @AdConnection
                    $actions.Add("set '$primaryGroup' as the primary group")
                }
            }
            catch { $actions.Add("WARN could not set '$primaryGroup' as primary group: $($_.Exception.Message)") }
        }
    }

    # 2b. Privileged-group protection. Offboarding_User.ps1 detects groups under an "*Privileged*" OU
    # and prints "please manually remove" — but then strips them anyway (warn-but-remove). Here we
    # detect them the same way AND actually SKIP them, recording each as a manual-removal item so a
    # privileged membership is never silently torn down (and never left without a paper trail).
    $protectedFound = @()

    if ((Get-CtgProp $Config 'removeAllGroups')) {
        # Distinguish the engine's DEFAULT from a choice this client actually made, so an operator
        # reading the run report can tell which it was. Before FR #0000109, 42 of 44 AD clients removed
        # no groups at all because nothing ever set this flag; the default now fills that silence, and
        # forces the evidence snapshot that makes it reversible.
        if ([string](Get-CtgProp $Config 'removeAllGroupsBy') -eq 'engine-default') {
            $actions.Add("removing all group memberships by ENGINE DEFAULT — this client has no group policy configured. Memberships are captured as evidence first; set removeAllGroups:false on the client to opt out.")
        }
        foreach ($g in $memberships) {
            if ($g.Name -eq 'Domain Users') { continue }   # the OLD default primary — not removable this way
            # The "Disabled Users" group is now the user's PRIMARY group (set in step 2a) — a primary
            # group can't be removed and isn't supposed to be. Skip it cleanly (it's intentionally kept),
            # not a warning.
            if ($primaryGroup -and "$($g.Name)" -ieq $primaryGroup) {
                $actions.Add("kept '$($g.Name)' — the user's primary group (set in this offboard); intentionally not removed")
                continue
            }
            if (Test-CtgADProtectedGroup -Group $g -Config $Config) {
                $protectedFound += $g.Name
                $actions.Add("WARN protected/privileged group NOT removed — remove manually: $($g.Name)")
                Write-CtgADStep "⚠ protected group — manual removal required: $($g.Name)"
                continue
            }
            if ($PSCmdlet.ShouldProcess($sam, "Remove from group $($g.Name)")) {
                # Remove by DistinguishedName, NOT Name. Remove-ADGroupMember -Identity resolves a group
                # by DN / objectGUID / SID / sAMAccountName — never the CN/Name. For groups whose
                # sAMAccountName differs from their display name (Teams/M365-provisioned "<name>_<hex>"
                # groups, or names with spaces), passing $g.Name fails "cannot find an object with
                # identity" even though the group plainly exists — which also left the user still in the
                # groups, so the "groups removed" validation missed. The DN always resolves.
                $gid = if ($g.DistinguishedName) { $g.DistinguishedName } else { $g.Name }
                # -ErrorAction Stop so a failed removal is surfaced, not silently logged as success.
                try {
                    Remove-ADGroupMember -Identity $gid -Members $sam -Confirm:$false -ErrorAction Stop @AdConnection
                    $actions.Add("removed from group: $($g.Name)")
                    Write-CtgADStep "✓ removed from group: $($g.Name)"
                } catch {
                    $actions.Add("WARN could not remove from group $($g.Name): $($_.Exception.Message)")
                    Write-CtgADStep "✗ group: $($g.Name) — $($_.Exception.Message)"
                }
            }
        }
    }

    # 2b. Remove the SPECIFIC groups named by the offboard rules (config.removeGroups), if the user
    # is actually a member. Independent of removeAllGroups (and a no-op once that already stripped all).
    $removeGroups = @(Get-CtgProp $Config 'removeGroups' | Where-Object { $_ })
    if ($removeGroups.Count) {
        $memberByLower = @{}; foreach ($g in $memberships) { $memberByLower["$($g.Name)".ToLower()] = $g }
        foreach ($name in $removeGroups) {
            if ("$name" -ieq 'Domain Users') { continue }
            $grpObj = $memberByLower["$name".ToLower()]   # the real group object the user belongs to
            if (-not $grpObj) { $actions.Add("not a member of $name (skip)"); continue }
            # Resolve by DN (see the removeAllGroups note above) — a Name-based identity fails for
            # groups whose sAMAccountName differs from their display name.
            $gid = if ($grpObj.DistinguishedName) { $grpObj.DistinguishedName } else { $grpObj.Name }
            if ($PSCmdlet.ShouldProcess($sam, "Remove from group $($grpObj.Name)")) {
                Remove-ADGroupMember -Identity $gid -Members $sam -Confirm:$false -ErrorAction SilentlyContinue @AdConnection
                $actions.Add("removed from group: $($grpObj.Name)")
            }
        }
    }

    # 3. Hide from GAL ---------------------------------------------------------
    # FR #36: on ad_synced clients the planner injects { attribute='msExchHideFromAddressLists',
    # value='TRUE' } here (EXO refuses to modify a directory-synced mailbox, so the hide happens
    # on-prem and syncs up). Hardened accordingly: the value defaults to TRUE, the write is
    # read-first idempotent, and a schema-missing attribute (an AD without the on-prem Exchange
    # schema) WARNs and CONTINUES — the manager clear / disable / OU move below must still run.
    $hide = Get-CtgProp $Config 'hideFromGal'
    if ($hide) {
        $attr = Get-CtgProp $hide 'attribute'; $val = Get-CtgProp $hide 'value'
        if ($null -eq $val -or "$val" -eq '') { $val = 'TRUE' }
        if ($attr -and $PSCmdlet.ShouldProcess($sam, "Hide from GAL ($attr=$val)")) {
            # Read the current value first — a re-run (or an operator's manual hide) must not re-write.
            # A failed read (schema missing) falls through to the write, whose catch owns the WARN.
            $curHide = $null
            try { $curHide = Get-CtgProp (Get-ADUser -Identity $sam -Properties $attr -ErrorAction Stop @AdConnection) $attr } catch { }
            $alreadyHidden = ($null -ne $curHide) -and (
                ("$curHide" -ieq "$val") -or (($curHide -is [bool]) -and $curHide -and ("$val" -ieq 'TRUE'))
            )
            if ($alreadyHidden) {
                $actions.Add("already hidden from GAL ($attr)")
            }
            else {
                try {
                    Set-ADUser -Identity $sam -Replace @{ $attr = $val } -ErrorAction Stop @AdConnection
                    $actions.Add("hid from GAL: $attr=$val")
                }
                catch {
                    # "One or more properties are invalid" = the attribute isn't in this AD's schema.
                    if (Test-CtgADSchemaMissingError $_.Exception.Message) {
                        $actions.Add("WARN could not hide from GAL — $attr isn't in this AD schema (no on-prem Exchange schema); hide manually or configure a custom attribute + Entra Connect rule")
                    }
                    else {
                        $actions.Add("WARN could not hide from GAL ($attr): $($_.Exception.Message)")
                    }
                    Write-CtgADStep "✗ hide from GAL: $attr — $($_.Exception.Message)"
                }
            }
        }
    }

    # 4. Remove manager --------------------------------------------------------
    # Capture WHO the manager is BEFORE clearing the link. Two reasons: the run report should name the
    # person (not just "cleared manager"), and the Exchange step grants that manager Full Access to the
    # converted shared mailbox. Exchange normally runs first and reads the live link — but when it runs
    # AFTER this step (a re-run, or a first attempt that failed) the link is already gone and the
    # delegate is silently skipped. Returned as `Manager`, which the app hands to Exchange on claim.
    $managerInfo = $null
    $mgrDn = [string](Get-CtgProp $existing 'Manager')
    if ($mgrDn) {
        try {
            $m = Get-ADUser -Identity $mgrDn -Properties DisplayName, EmailAddress, UserPrincipalName -ErrorAction Stop @AdConnection
            $managerInfo = @{
                Name              = [string]((Get-CtgProp $m 'DisplayName') ?? (Get-CtgProp $m 'Name'))
                Email             = [string]((Get-CtgProp $m 'EmailAddress') ?? (Get-CtgProp $m 'UserPrincipalName'))
                DistinguishedName = $mgrDn
            }
        }
        catch {
            # The DN is still worth reporting even if the manager object can't be read.
            $managerInfo = @{ Name = $null; Email = $null; DistinguishedName = $mgrDn }
        }
    }
    if ($PSCmdlet.ShouldProcess($sam, "Clear manager")) {
        Set-ADUser -Identity $sam -Clear manager @AdConnection
        $who =
            if ($managerInfo -and $managerInfo.Name -and $managerInfo.Email) { ": $($managerInfo.Name) <$($managerInfo.Email)>" }
            elseif ($managerInfo -and $managerInfo.Name) { ": $($managerInfo.Name)" }
            elseif ($managerInfo) { ": $($managerInfo.DistinguishedName)" }
            else { " (none set)" }
        $actions.Add("cleared manager$who")
    }

    # 4b. Offboard attributes from the rules (config.offboardAttributes) — e.g. description. AFTER the
    # manager clear so a rule that intentionally re-points 'manager' on offboard isn't undone.
    foreach ($a in (Set-CtgADAttributes -Identity $sam -Attributes (Get-CtgProp $Config 'offboardAttributes') -AdConnection $AdConnection)) {
        $actions.Add("set $a")
    }

    # 5. Disable ----------------------------------------------------------------
    if ((Get-CtgProp $Config 'disableAccount') -ne $false) {
        if ($PSCmdlet.ShouldProcess($sam, "Disable account")) {
            Disable-ADAccount -Identity $sam @AdConnection
            $actions.Add("disabled account")
        }
    }

    # 6. Move OU — UNLESS the guardrail forbids it. A rule-driven moveToOu (offboard rules) wins over
    # the system default disabledUsersOu.
    $targetOu = Get-CtgProp $Config 'moveToOu'
    if (-not $targetOu) { $targetOu = Get-CtgProp $Config 'disabledUsersOu' }
    if ($guardrails -contains 'do-not-move-ou') {
        $actions.Add("did not move OU (do-not-move-ou guardrail — moving would delete the synced 365 account)")
    }
    elseif ($targetOu) {
        # Move-ADObject needs a full DN; a bare/typo'd OU value would throw and abort the offboard.
        # Skip with a clear note instead (group removal + disable still completed above).
        if ("$targetOu" -notmatch '(?i)dc=') {
            $actions.Add("skipped move: '$targetOu' is not a full OU DN (expected OU=…,DC=…)")
        }
        elseif ($PSCmdlet.ShouldProcess($sam, "Move to $targetOu")) {
            Move-ADObject -Identity $existing.DistinguishedName -TargetPath $targetOu @AdConnection
            $actions.Add("moved to $targetOu")
        }
    }

    # 7. Disable + move the user's COMPUTER object. The machine name comes from the case (the Entra
    # device resolved by the M365 step, or config.computerName) — never guessed. Disable, then move to
    # the Disabled Computers OU when configured. Idempotent; a clean note when the computer isn't found.
    $computerInfo = $null
    $computerName = [string]((Get-CtgProp $Config 'computerName') ?? (Get-CtgProp $User 'computerName') ?? (Get-CtgProp $User 'deviceName') ?? (Get-CtgProp $User 'EntraDeviceName'))
    if ((Get-CtgProp $Config 'disableComputer') -and $computerName) {
        try {
            $comp = Get-ADComputer -Identity $computerName -Properties DistinguishedName, Enabled -ErrorAction SilentlyContinue @AdConnection
            if (-not $comp) {
                $actions.Add("computer '$computerName' not found in AD — nothing to disable")
            }
            else {
                $computerInfo = @{ Name = $comp.Name; DistinguishedName = $comp.DistinguishedName }
                if ($comp.Enabled -eq $false) {
                    $actions.Add("computer '$computerName' already disabled")
                }
                elseif ($PSCmdlet.ShouldProcess($computerName, "Disable computer")) {
                    Disable-ADAccount -Identity $comp.DistinguishedName @AdConnection
                    $actions.Add("disabled computer: $computerName")
                }
                $compOu = Get-CtgProp $Config 'disabledComputersOu'
                if ($compOu -and "$compOu" -match '(?i)dc=' -and $PSCmdlet.ShouldProcess($computerName, "Move computer to $compOu")) {
                    Move-ADObject -Identity $comp.DistinguishedName -TargetPath $compOu @AdConnection
                    $actions.Add("moved computer '$computerName' to $compOu")
                }
            }
        }
        catch { $actions.Add("WARN could not disable computer '$computerName': $($_.Exception.Message)") }
    }

    # 8. -a ADMIN-ACCOUNT SWEEP (config.adminAccountSuffix, e.g. '-a'): the person may hold a
    # privileged secondary account named <sam><suffix> (mgallegos -> mgallegos-a) that must be
    # disabled with them. The ticket only carries a display name, so the admin identity is derived
    # from the RESOLVED primary, looked up EXACTLY (never the fuzzy-candidates machinery — a missing
    # -a account must never pause the case), and when present run through this same offboard with the
    # suffix stripped (depth-1 recursion) and the computer keys dropped (the -a account has no
    # workstation of its own).
    $adminEvidence = $null
    $adminSuffix = [string](Get-CtgProp $Config 'adminAccountSuffix')
    if ($adminSuffix) {
        if ($adminSuffix -notmatch '^[A-Za-z0-9._-]{1,16}$') {
            $actions.Add("WARN admin-account check skipped: suffix '$adminSuffix' is not a valid account-name fragment")
        }
        else {
            $adminSam = "$sam$adminSuffix"
            $primaryUpn = [string](Get-CtgProp $existing 'UserPrincipalName')
            $adminUpn = ''
            if ($primaryUpn -match '^([^@]+)@(.+)$') { $adminUpn = "$($Matches[1])$adminSuffix@$($Matches[2])" }
            $samEsc = $adminSam -replace "'", "''"
            $adminHit = @(Get-ADUser -Filter "SamAccountName -eq '$samEsc'" -ErrorAction SilentlyContinue @AdConnection)
            if ($adminHit.Count -eq 0 -and $adminUpn) {
                $adminUpnEsc = $adminUpn -replace "'", "''"
                $adminHit = @(Get-ADUser -Filter "UserPrincipalName -eq '$adminUpnEsc'" -ErrorAction SilentlyContinue @AdConnection)
            }
            if ($adminHit.Count -eq 0) {
                $actions.Add("admin account check: no $adminSam in AD — nothing extra to disable")
            }
            else {
                $adminWho = [string]((Get-CtgProp $adminHit[0] 'SamAccountName') ?? $adminSam)
                $actions.Add("admin account check: found $adminWho — disabling it the same way")
                $adminCfg = @{}
                foreach ($p in $Config.PSObject.Properties) {
                    if ($p.Name -in @('adminAccountSuffix', 'disableComputer', 'computerName', 'disabledComputersOu')) { continue }
                    $adminCfg[$p.Name] = $p.Value
                }
                $adminResult = Invoke-CtgADOffboarding -User ([pscustomobject]@{ SamAccountName = $adminWho; UserPrincipalName = $adminUpn }) -Config ([pscustomobject]$adminCfg) -AdConnection $AdConnection
                foreach ($a in @(Get-CtgProp $adminResult 'Actions')) { $actions.Add("[$adminWho] $a") }
                $adminEvidence = Get-CtgProp $adminResult 'Evidence'
            }
        }
    }

    [pscustomobject]@{
        System='active-directory'; Status='ok'; Sam=$sam
        # Manager: the link this step CLEARED. The app reads it off the result and hands it to the
        # Exchange step (Full Access on the shared mailbox); it's evidence too, so the run report can
        # name the person whose access was removed.
        Manager=$managerInfo
        # AdminAccount = what the -a sweep did (its own Groups/Manager evidence), $null when not configured.
        Evidence=@{ Groups = $groupNames; Computer = $computerInfo; ProtectedGroups = @($protectedFound); Manager = $managerInfo; AdminAccount = $adminEvidence }
        Actions=$actions.ToArray()
    }
}

function Confirm-CtgAD {
    <#
    .SYNOPSIS
        Post-action read-back for on-prem AD. No mutations; returns { ok; checks[] }.
    .PARAMETER Action
        'onboard' (user in the OU + groups + home drive) or 'offboard' (disabled + groups
        removed + hidden from GAL + NOT moved when the do-not-move-ou guardrail is present).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][ValidateSet('onboard', 'offboard')][string]$Action,
        [hashtable]$AdConnection = @{}
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    $add = { param($name, $expected, $actual) $checks.Add(@{ name = $name; expected = $expected; actual = $actual; pass = ($expected -eq $actual) }) }
    $sam = [string](Get-CtgProp $User 'SamAccountName')   # StrictMode-safe (payload may lack the property)
    $domain = Resolve-CtgAdDomain -AdConnection $AdConnection -Fallback (Get-CtgProp $User 'PrimaryDomain')

    # Resolve the SAME way the executor does — by display name when the case has no SamAccountName —
    # so the read-back doesn't pass an empty -Identity (a hard bind error) and doesn't check the wrong
    # account (which would "miss" and re-run the offboard via the revalidate loop).
    if ([string]::IsNullOrWhiteSpace($sam)) {
        $dn = [string](Get-CtgProp $User 'DisplayName')
        if ($Action -eq 'offboard' -and $dn) {
            $dnEsc = $dn -replace "'", "''"   # escape quotes so "Sean O'Brien" can't break the AD filter
            $byName = @(Get-ADUser -Filter "DisplayName -eq '$dnEsc'" -Properties SamAccountName -ErrorAction SilentlyContinue @AdConnection)
            if ($byName.Count -eq 1) { $sam = [string](Get-CtgProp $byName[0] 'SamAccountName') }
        }
        if ([string]::IsNullOrWhiteSpace($sam)) {
            return [pscustomobject]@{ ok = $true; checks = @(@{ name = 'no resolvable offboard target — nothing to verify'; expected = $true; actual = $true; pass = $true }) }
        }
    }

    # Request ONLY schema-guaranteed properties here. msExchHideFromAddressLists exists only where the
    # on-prem Exchange schema is installed — an AD without it (M365/EXO-only tenants like Six One) makes
    # Get-ADUser -Properties <that> throw for the WHOLE call, so -EA SilentlyContinue would null $u and a
    # fully-onboarded user would look absent → every check "fails". The Exchange attr is fetched
    # best-effort below, only for the offboard hide-from-GAL check that actually needs it.
    $u = Get-ADUser -Identity $sam -Properties MemberOf, DistinguishedName, Enabled, HomeDirectory -ErrorAction SilentlyContinue @AdConnection
    $exists = [bool]$u
    $memberObjs = if ($exists) { @(Get-ADPrincipalGroupMembership -Identity $sam -ErrorAction SilentlyContinue @AdConnection) } else { @() }
    $groupNames = @($memberObjs | ForEach-Object { $_.Name })

    if ($Action -eq 'onboard') {
        $ouPath = Resolve-CtgOuPath (Get-CtgProp $Config 'ou') $domain
        & $add 'user exists' $true $exists
        & $add "in OU $ouPath" $true ([bool]($exists -and (Get-CtgProp $u 'DistinguishedName') -like "*$ouPath"))

        $want = [System.Collections.Generic.List[string]]::new()
        foreach ($g in @(Get-CtgProp $Config 'groups')) { if ($g) { $want.Add([string]$g) } }
        foreach ($cg in @(Get-CtgProp $Config 'conditionalGroups')) {
            if (Test-CtgCondition (Get-CtgProp $cg 'when') $User) { foreach ($g in @(Get-CtgProp $cg 'groups')) { if ($g) { $want.Add([string]$g) } } }
        }
        foreach ($g in $want) { & $add "group: $g" $true ([bool]($groupNames -contains $g)) }

        $home = Get-CtgProp $Config 'homeDrive'
        if ($home) { & $add 'home drive mapped' $true ([bool]($exists -and (Get-CtgProp $u 'HomeDirectory'))) }
    }
    else {
        & $add 'account disabled' $true ([bool](-not $exists -or (Get-CtgProp $u 'Enabled') -eq $false))
        if ($exists -and (Get-CtgProp $Config 'removeAllGroups')) {
            # Exclude the same groups the executor intentionally keeps: the primary group (Domain Users,
            # and the "Disabled Users" group we set as primary) — a primary group can't be removed — and
            # protected/privileged groups. None of these count as a failed removal.
            $primaryGroup = [string]((Get-CtgProp $Config 'disabledUsersPrimaryGroup') ?? (Get-CtgProp $Config 'disabledUsersGroup'))
            $remaining = @($memberObjs | Where-Object {
                    $_.Name -ne 'Domain Users' -and
                    -not ($primaryGroup -and "$($_.Name)" -ieq $primaryGroup) -and
                    -not (Test-CtgADProtectedGroup -Group $_ -Config $Config)
                }).Count
            & $add 'groups removed' $true ([bool]($remaining -eq 0))
        }
        $hide = Get-CtgProp $Config 'hideFromGal'
        if ($exists -and $hide -and (Get-CtgProp $hide 'attribute')) {
            # FR #36: verify against the CONFIGURED attribute (it may be a custom one, e.g.
            # msDS-cloudExtensionAttribute1 + an Entra Connect rule), compared to the configured
            # value (truthy fallback for booleans / no value). A SCHEMA-MISSING read (the attribute
            # isn't in this AD — the executor already WARNed) skips the check entirely: a
            # perpetually-red verify would loop the case. Any OTHER read error (DC timeout, ADWS
            # hiccup) stays FAIL-CLOSED — record a miss rather than green-light a leaver who may
            # still be visible.
            $hideAttr = [string](Get-CtgProp $hide 'attribute')
            $hideVal = [string](Get-CtgProp $hide 'value')
            $hideOutcome = 'read'; $curHide = $null
            try { $curHide = Get-CtgProp (Get-ADUser -Identity $sam -Properties $hideAttr -ErrorAction Stop @AdConnection) $hideAttr }
            catch { $hideOutcome = if (Test-CtgADSchemaMissingError $_.Exception.Message) { 'schema-missing' } else { 'error' } }
            if ($hideOutcome -eq 'read') {
                $hidden = if ([string]::IsNullOrWhiteSpace($hideVal)) { [bool]$curHide }
                          else { ("$curHide" -ieq $hideVal) -or (($curHide -is [bool]) -and $curHide -and ($hideVal -ieq 'TRUE')) }
                & $add 'hidden from GAL' $true $hidden
            }
            elseif ($hideOutcome -eq 'error') {
                & $add 'hidden from GAL' $true $false
            }
        }
        # do-not-move-ou guardrail: the DN must NOT sit under the Disabled Users OU.
        $disabledOu = Get-CtgProp $Config 'disabledUsersOu'
        if ($exists -and (@(Get-CtgProp $Config 'guardrails') -contains 'do-not-move-ou') -and $disabledOu) {
            & $add 'not moved (do-not-move-ou)' $true ([bool]((Get-CtgProp $u 'DistinguishedName') -notlike "*$disabledOu"))
        }
    }

    $all = @($checks)
    [pscustomobject]@{ ok = (@($all | Where-Object { -not $_.pass }).Count -eq 0); checks = $all }
}

# ── AD email write-back ─────────────────────────────────────────────────────────────────────────
# After the cloud mailbox exists, record the user's email in AD's `mail` attribute. Runs on the
# client-network agent (rides the ActiveDirectory capability — no cloud creds). The app injects
# `writebackEmail` (the mailbox's ASSIGNED primary SMTP, resolved from the m365/exchange result) into
# the payload at dispatch; we fall back to the deterministic work email / UPN when it isn't present
# (older runner / no result) — the same value AD's proxyAddresses was already set to at create time.
# Idempotent: only writes when `mail` differs. Onboard-only.
function Resolve-CtgWritebackEmail($User) {
    foreach ($k in 'writebackEmail', 'workEmail', 'userPrincipalName') {
        $v = [string](Get-CtgProp $User $k)
        if (-not [string]::IsNullOrWhiteSpace($v) -and ($v -match '@')) { return $v }
    }
    return $null
}

function Invoke-CtgADEmailWriteback {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [hashtable]$AdConnection = @{}
    )
    $actions = [System.Collections.Generic.List[string]]::new()
    $email = Resolve-CtgWritebackEmail $User
    if (-not $email) {
        return [pscustomobject]@{ System = 'ad-email-writeback'; Status = 'ok'; Actions = @('no email to write back (no writebackEmail/workEmail/UPN on the case) — nothing done') }
    }

    # Resolve the just-created user: SamAccountName, else UPN, else DisplayName (exactly one).
    $sam = [string](Get-CtgProp $User 'SamAccountName')
    $upn = [string](Get-CtgProp $User 'UserPrincipalName')
    $displayName = [string](Get-CtgProp $User 'DisplayName')
    $existing = $null
    if (-not [string]::IsNullOrWhiteSpace($sam)) {
        $existing = Get-ADUser -Identity $sam -Properties mail -ErrorAction SilentlyContinue @AdConnection
    }
    if (-not $existing -and $upn) {
        $upnEsc = $upn -replace "'", "''"
        $existing = @(Get-ADUser -Filter "UserPrincipalName -eq '$upnEsc'" -Properties mail -ErrorAction SilentlyContinue @AdConnection)[0]
        if ($existing) { $sam = [string](Get-CtgProp $existing 'SamAccountName') }
    }
    if (-not $existing -and $displayName) {
        $dnEsc = $displayName -replace "'", "''"
        $byName = @(Get-ADUser -Filter "DisplayName -eq '$dnEsc'" -Properties mail -ErrorAction SilentlyContinue @AdConnection)
        if ($byName.Count -eq 1) { $existing = $byName[0]; $sam = [string](Get-CtgProp $existing 'SamAccountName') }
        elseif ($byName.Count -gt 1) {
            return [pscustomobject]@{ System = 'ad-email-writeback'; Status = 'ok'; Actions = @("WARN $($byName.Count) AD users match display name '$displayName' — can't pick one; nothing written") }
        }
    }
    if (-not $existing) {
        return [pscustomobject]@{ System = 'ad-email-writeback'; Status = 'ok'; Actions = @("user not found ($(if ($sam) { $sam } elseif ($upn) { $upn } else { $displayName })) — nothing written") }
    }

    # Idempotent: only write when the mail attribute differs from the target.
    $current = [string](Get-CtgProp $existing 'mail')
    if ($current -ieq $email) {
        $actions.Add("AD mail already '$email' — no change")
    }
    elseif ($PSCmdlet.ShouldProcess($sam, "Set AD mail = $email")) {
        try {
            Set-ADUser -Identity $sam -EmailAddress $email -ErrorAction Stop @AdConnection
            $actions.Add("set AD mail: '$(if ($current) { $current } else { '(unset)' })' -> '$email'")
        } catch {
            throw "setting AD mail for '$sam' to '$email': $($_.Exception.Message)"
        }
    }

    [pscustomobject]@{ System = 'ad-email-writeback'; Status = 'ok'; Sam = $sam; Mail = $email; Actions = $actions.ToArray() }
}

function Confirm-CtgADEmailWriteback {
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [hashtable]$AdConnection = @{}
    )
    $email = Resolve-CtgWritebackEmail $User
    if (-not $email) {
        # No email on the case = the executor deliberately wrote nothing; that's a pass, not a miss.
        return [pscustomobject]@{ ok = $true; checks = @(@{ name = 'no email to write back (no writebackEmail/workEmail/UPN on the case) — nothing to verify'; expected = $true; actual = $true; pass = $true }) }
    }
    # Same lookup fallback as the executor (sam -> UPN -> unique DisplayName): a case without a
    # SamAccountName otherwise validates against nobody and misses even though the mail is correct.
    $u = Get-CtgAdCaseUser -User $User -Properties @('mail') -AdConnection $AdConnection
    $actual = [string](Get-CtgProp $u 'mail')
    $pass = [bool]($actual -and ($actual -ieq $email))
    [pscustomobject]@{ ok = $pass; checks = @(@{ name = "AD mail = $email"; expected = $email; actual = $actual; pass = $pass }) }
}

# ── Teams number write-back ───────────────────────────────────────────────────────────────────────
# Write the Teams Phone number the teams step assigned into AD's telephoneNumber, so it syncs to Entra
# and shows in the address book. The app injects it as `writebackPhone` at dispatch (from the teams
# step's PhoneNumber); no number = the teams step assigned none, and nothing is written.
function Invoke-CtgADPhoneWriteback {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [hashtable]$AdConnection = @{}
    )
    $phone = [string](Get-CtgProp $User 'writebackPhone')
    if ([string]::IsNullOrWhiteSpace($phone)) {
        return [pscustomobject]@{ System = 'ad-phone-writeback'; Status = 'ok'; Actions = @('no Teams number to write back (the Teams step assigned none) — nothing done') }
    }
    $phone = $phone.Trim()
    $u = Get-CtgAdCaseUser -User $User -Properties @('telephoneNumber') -AdConnection $AdConnection
    if (-not $u) {
        return [pscustomobject]@{ System = 'ad-phone-writeback'; Status = 'ok'; Actions = @("WARN the user wasn't found in AD (or their display name matches more than one) — telephoneNumber not written; set it to $phone by hand") }
    }
    $sam = [string](Get-CtgProp $u 'SamAccountName')
    $current = [string](Get-CtgProp $u 'telephoneNumber')
    $actions = [System.Collections.Generic.List[string]]::new()
    if ($current -eq $phone) { $actions.Add("AD telephoneNumber already '$phone' — no change") }
    elseif ($PSCmdlet.ShouldProcess($sam, "Set AD telephoneNumber = $phone")) {
        try {
            Set-ADUser -Identity $sam -OfficePhone $phone -ErrorAction Stop @AdConnection
            $actions.Add("set AD telephoneNumber: '$(if ($current) { $current } else { '(unset)' })' -> '$phone'")
        }
        catch { throw "setting AD telephoneNumber for '$sam' to '$phone': $($_.Exception.Message)" }
    }
    else { $actions.Add("would set AD telephoneNumber for $sam to '$phone' (WhatIf)") }
    [pscustomobject]@{ System = 'ad-phone-writeback'; Status = 'ok'; Sam = $sam; TelephoneNumber = $phone; Actions = $actions.ToArray() }
}

function Confirm-CtgADPhoneWriteback {
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [hashtable]$AdConnection = @{}
    )
    $phone = [string](Get-CtgProp $User 'writebackPhone')
    if ([string]::IsNullOrWhiteSpace($phone)) {
        return [pscustomobject]@{ ok = $true; checks = @(@{ name = 'no Teams number to write back — nothing to verify'; expected = $true; actual = $true; pass = $true }) }
    }
    $u = Get-CtgAdCaseUser -User $User -Properties @('telephoneNumber') -AdConnection $AdConnection
    $actual = [string](Get-CtgProp $u 'telephoneNumber')
    $pass = $actual -eq $phone.Trim()
    [pscustomobject]@{ ok = $pass; checks = @(@{ name = "AD telephoneNumber = $($phone.Trim())"; expected = $phone.Trim(); actual = $actual; pass = $pass }) }
}

# ── Hybrid identity-link CHECK (Design D, DETECT-ONLY) ────────────────────────────────────────────
# Verify that the on-prem AD object will LINK to its Entra object rather than spawn a duplicate: the
# Entra source anchor (immutableId) must equal base64(objectGUID) OR base64(mS-DS-ConsistencyGuid).
# The app injects the Entra object's { immutableId, syncEnabled, userId } (from the m365 result) into
# the payload as `cloudObject`. We only READ + FLAG here — no write (that's a later level). Onboard-only.
function Get-CtgAdCaseUser {
    param([pscustomobject]$User, [string[]]$Properties, [hashtable]$AdConnection = @{})
    $sam = [string](Get-CtgProp $User 'SamAccountName')
    $upn = [string](Get-CtgProp $User 'UserPrincipalName')
    $displayName = [string](Get-CtgProp $User 'DisplayName')
    $u = $null
    if (-not [string]::IsNullOrWhiteSpace($sam)) { $u = Get-ADUser -Identity $sam -Properties $Properties -ErrorAction SilentlyContinue @AdConnection }
    if (-not $u -and $upn) { $u = @(Get-ADUser -Filter "UserPrincipalName -eq '$($upn -replace "'", "''")'" -Properties $Properties -ErrorAction SilentlyContinue @AdConnection)[0] }
    if (-not $u -and $displayName) {
        $byName = @(Get-ADUser -Filter "DisplayName -eq '$($displayName -replace "'", "''")'" -Properties $Properties -ErrorAction SilentlyContinue @AdConnection)
        if ($byName.Count -eq 1) { $u = $byName[0] }
    }
    return $u
}

function Invoke-CtgADConsistencyCheck {
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [hashtable]$AdConnection = @{}
    )
    $u = Get-CtgAdCaseUser -User $User -Properties @('objectGUID', 'mS-DS-ConsistencyGuid') -AdConnection $AdConnection
    if (-not $u) {
        return [pscustomobject]@{ System = 'ad-consistency-check'; Status = 'ok'; Actions = @('on-prem user not found — nothing to check') }
    }
    # Both possible source anchors, as the base64 immutableId form AAD Connect uses.
    $anchors = [System.Collections.Generic.List[string]]::new()
    $og = Get-CtgProp $u 'objectGUID'
    if ($og) { try { $anchors.Add([System.Convert]::ToBase64String(([guid]$og).ToByteArray())) } catch {} }
    $cg = Get-CtgProp $u 'mS-DS-ConsistencyGuid'
    if ($cg) { try { $anchors.Add([System.Convert]::ToBase64String([byte[]]$cg)) } catch {} }

    $cloud = Get-CtgProp $User 'cloudObject'
    $immutableId = [string](Get-CtgProp $cloud 'immutableId')
    $syncEnabled = Get-CtgProp $cloud 'syncEnabled'
    $userId = [string](Get-CtgProp $cloud 'userId')

    $actions = [System.Collections.Generic.List[string]]::new()
    # The app injects read=$false when it never obtained an Entra object to compare against — the m365
    # step failed, was completed by hand, or did not run. That is NOT the same as 'there is no cloud
    # object yet', and reporting it as such handed the operator an all-clear for a comparison that never
    # happened (FR #0000093 — the whole reason this check was being ignored). An older app sends no
    # `read` field at all, in which case this branch is skipped and the behaviour is unchanged.
    $read = Get-CtgProp $cloud 'read'
    if ($read -eq $false) {
        $why = [string](Get-CtgProp $cloud 'reason')
        $actions.Add("WARN could NOT verify the AD/Entra link — $(if ($why) { $why } else { 'the Microsoft 365 step reported no Entra object' }). Nothing was compared, so this is NOT an all-clear: fix the 365 step and re-run it, then re-run this check.")
    }
    elseif ([string]::IsNullOrWhiteSpace($userId)) {
        $actions.Add('no matching Entra object reported — a fresh sync will create + anchor it (ok)')
    }
    elseif ($syncEnabled -eq $false) {
        # A cloud-ONLY object exists (not synced from AD) — the on-prem user will NOT hard-match it and
        # AAD Connect will create a second object. This is the duplicate risk the operator must resolve.
        $actions.Add("WARN a CLOUD-ONLY Entra object exists for this user (id $userId) — the on-prem account won't link to it; AAD Connect will create a DUPLICATE. Hard-match it (set mS-DS-ConsistencyGuid to the cloud immutableId) or soft-match by primary SMTP before syncing.")
    }
    elseif ([string]::IsNullOrWhiteSpace($immutableId)) {
        $actions.Add("Entra object $userId is sync-enabled but reported no immutableId — can't confirm the anchor from here; treat as linked")
    }
    elseif ($anchors -contains $immutableId) {
        $actions.Add("linked: Entra immutableId matches the on-prem source anchor (objectGUID / mS-DS-ConsistencyGuid)")
    }
    else {
        $actions.Add("WARN Entra immutableId ($immutableId) does NOT match the on-prem source anchor ($($anchors -join ' / ')) — the objects may be UNLINKED (possible duplicate). Verify the AAD Connect source anchor.")
    }

    $warned = @($actions | Where-Object { $_ -like 'WARN*' }).Count
    [pscustomobject]@{ System = 'ad-consistency-check'; Status = 'ok'; Sam = [string](Get-CtgProp $u 'SamAccountName'); Flagged = ($warned -gt 0); Actions = $actions.ToArray() }
}

# ── Hard-match (operator-confirmed link) ──────────────────────────────────────────────────────────
# Set the on-prem mS-DS-ConsistencyGuid to the existing Entra object's immutableId so AAD Connect
# HARD-MATCHES them (links instead of duplicating). Triggered by a human clicking "Link" after the
# consistency check flagged a mismatch — the app injects the target `immutableId` (from the m365
# result). Heavily guarded: refuses anything that isn't a 16-byte base64 GUID; idempotent.
function Invoke-CtgADHardMatch {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [hashtable]$AdConnection = @{}
    )
    $actions = [System.Collections.Generic.List[string]]::new()
    $immutableId = [string](Get-CtgProp $Config 'immutableId')
    if ([string]::IsNullOrWhiteSpace($immutableId)) { $immutableId = [string](Get-CtgProp $User 'immutableId') }
    if ([string]::IsNullOrWhiteSpace($immutableId)) {
        return [pscustomobject]@{ System = 'ad-hard-match'; Status = 'error'; Actions = @('no immutableId provided to hard-match to — nothing done') }
    }
    $bytes = $null
    try { $bytes = [Convert]::FromBase64String($immutableId) } catch { $bytes = $null }
    if (-not $bytes -or $bytes.Length -ne 16) {
        return [pscustomobject]@{ System = 'ad-hard-match'; Status = 'error'; Actions = @("immutableId '$immutableId' is not a 16-byte base64 GUID — refusing to write the anchor") }
    }
    $u = Get-CtgAdCaseUser -User $User -Properties @('mS-DS-ConsistencyGuid') -AdConnection $AdConnection
    if (-not $u) { return [pscustomobject]@{ System = 'ad-hard-match'; Status = 'error'; Actions = @('on-prem user not found — nothing done') } }
    $sam = [string](Get-CtgProp $u 'SamAccountName')
    $current = Get-CtgProp $u 'mS-DS-ConsistencyGuid'
    $currentB64 = if ($current) { [Convert]::ToBase64String([byte[]]$current) } else { $null }
    if ($currentB64 -eq $immutableId) {
        $actions.Add("mS-DS-ConsistencyGuid already = $immutableId — already hard-matched (no change)")
    }
    elseif ($PSCmdlet.ShouldProcess($sam, "Set mS-DS-ConsistencyGuid = $immutableId (hard-match)")) {
        try {
            Set-ADUser -Identity $sam -Replace @{ 'mS-DS-ConsistencyGuid' = $bytes } -ErrorAction Stop @AdConnection
            $actions.Add("set mS-DS-ConsistencyGuid = $immutableId — run a directory-sync so AAD Connect links the on-prem + cloud objects")
        } catch { throw "setting mS-DS-ConsistencyGuid for '$sam': $($_.Exception.Message)" }
    }
    [pscustomobject]@{ System = 'ad-hard-match'; Status = 'ok'; Sam = $sam; Actions = $actions.ToArray() }
}

# ── Ad-hoc password reset (INC0855142) ───────────────────────────────────────────────────────────
# Operator-dispatched "Generate random password" from a case's Active Directory line. The APP
# generates the value (revealed once to the operator, then wiped) and injects it as config.newPassword
# at claim; this executor only sets it — the plaintext must NEVER appear in the result, actions, or an
# error message. For AD-synced tenants, password hash sync carries the change to Entra on its own.
function Invoke-CtgADPasswordReset {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$User,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [hashtable]$AdConnection = @{}
    )
    $newPassword = [string](Get-CtgProp $Config 'newPassword')
    if ([string]::IsNullOrWhiteSpace($newPassword)) {
        throw "no newPassword in the job config — the app injects it at claim and wipes it after its one-time reveal; dispatch a fresh reset from the account line instead of re-running this job"
    }
    # Same lookup fallback as the write-back/hard-match (sam -> UPN -> unique DisplayName).
    $u = Get-CtgAdCaseUser -User $User -Properties @('SamAccountName') -AdConnection $AdConnection
    if (-not $u) {
        $who = @((Get-CtgProp $User 'SamAccountName'), (Get-CtgProp $User 'UserPrincipalName'), (Get-CtgProp $User 'DisplayName')) | Where-Object { $_ } | Select-Object -First 1
        throw "AD user not found ($who) — password not reset"
    }
    $sam = [string](Get-CtgProp $u 'SamAccountName')
    $actions = [System.Collections.Generic.List[string]]::new()
    if ($PSCmdlet.ShouldProcess($sam, "Reset password")) {
        $secure = ConvertTo-SecureString $newPassword -AsPlainText -Force
        try { Set-ADAccountPassword -Identity $sam -Reset -NewPassword $secure -ErrorAction Stop @AdConnection }
        catch { throw "resetting the password for '$sam': $($_.Exception.Message)" }
        $actions.Add("reset password for $sam (shown once to the operator, never stored)")
        # Default ON; the operator can untick "require change at next sign-in" when they still have
        # to log in AS the user (equipment setup) before handing the account over (FR #14).
        if ((Get-CtgProp $Config 'requireChangeAtSignIn') -eq $false) {
            $actions.Add("change-at-next-logon NOT required — operator choice")
        }
        else {
            try {
                Set-ADUser -Identity $sam -ChangePasswordAtLogon $true -ErrorAction Stop @AdConnection
                $actions.Add("must change password at next logon")
            } catch {
                # The reset DID land — a policy that forbids the flag (e.g. password-never-expires) is a warning, not a failure.
                $actions.Add("WARN could not require change-at-next-logon: $($_.Exception.Message)")
            }
        }
    }
    [pscustomobject]@{ System = 'ad-password-reset'; Status = 'ok'; Sam = $sam; Actions = $actions.ToArray() }
}


# --- Connection-test rights helpers -------------------------------------------------------------
# Can this account CREATE USER objects in a given OU? Evaluated from the OU's ACL (read-only).
# The evaluator is PURE (rule POCOs in, verdict out) so it's unit-testable on any platform; the
# two wrappers below do the directory reads and degrade to "verify manually" on anything odd.

# The AD schema class GUID for `user` objects — an ACE granting CreateChild scoped to this GUID
# (or unscoped, or GenericAll) is what "can create users here" means.
$script:AD_USER_CLASS_GUID = 'bf967aba-0de6-11d0-a285-00aa003049e2'

function Test-CtgAdCreateUserAce {
    <#
    .SYNOPSIS
        Pure ACE evaluation: do these SIDs get create-user on an object with these access rules?
    .PARAMETER Rules
        Rule POCOs: @{ Type = 'Allow'|'Deny'; Sid = 'S-1-…'; Rights = 'CreateChild, GenericRead…'
        (the ActiveDirectoryRights string); ObjectType = '<guid>' or '' (empty = all child classes) }.
    .OUTPUTS
        $true (an allow matches, no overriding deny), $false (denied / nothing allows), following
        the simplified model: any matching deny wins over allows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Sids
    )
    $applies = {
        param($rule)
        $sid = [string]$(if ($rule -is [System.Collections.IDictionary]) { $rule['Sid'] } else { $rule.Sid })
        if ($Sids -notcontains $sid) { return $false }
        $rights = [string]$(if ($rule -is [System.Collections.IDictionary]) { $rule['Rights'] } else { $rule.Rights })
        $objType = [string]$(if ($rule -is [System.Collections.IDictionary]) { $rule['ObjectType'] } else { $rule.ObjectType })
        $isCreate = ($rights -match 'GenericAll') -or (
            ($rights -match 'CreateChild') -and (
                -not $objType -or $objType -eq '00000000-0000-0000-0000-000000000000' -or $objType -ieq $script:AD_USER_CLASS_GUID
            )
        )
        return $isCreate
    }
    foreach ($r in $Rules) {
        $type = [string]$(if ($r -is [System.Collections.IDictionary]) { $r['Type'] } else { $r.Type })
        if ($type -ieq 'Deny' -and (& $applies $r)) { return $false }
    }
    foreach ($r in $Rules) {
        $type = [string]$(if ($r -is [System.Collections.IDictionary]) { $r['Type'] } else { $r.Type })
        if ($type -ieq 'Allow' -and (& $applies $r)) { return $true }
    }
    return $false
}

function Get-CtgAdAccountSids {
    <#
    .SYNOPSIS
        The service account's SID plus its group SIDs (tokenGroups when readable — nested and
        well-known groups included — else direct memberships), for ACL evaluation. Returns @()
        when nothing could be resolved (callers then report "verify manually").
    #>
    [CmdletBinding()]
    # -SamAccountName names the account to evaluate OUTRIGHT, and wins over $Creds. The caller knows
    # which identity the connection actually authenticates as, and since the runner may bind as SYSTEM
    # (ambient, no credential) rather than the ad-dc account, reading the account out of $Creds here
    # would audit the ACL of a principal the jobs never use. $Creds stays as the fallback so existing
    # callers keep working.
    param([hashtable]$AdConnection = @{}, $Creds, [string]$SamAccountName)
    $sam = $null
    if ($SamAccountName) { $sam = $SamAccountName }
    else {
        try {
            $s = if ($Creds -is [System.Collections.IDictionary]) { $Creds['ad-dc'] } else { $null }
            if ($s -and $s.Username) { $sam = ([string]$s.Username -split '[\\@]')[0]; if ([string]$s.Username -match '\\') { $sam = ([string]$s.Username -split '\\')[-1] } }
        } catch { }
    }
    if (-not $sam) { return @() }
    $sids = [System.Collections.Generic.List[string]]::new()
    try {
        $u = Get-ADUser -Identity $sam @AdConnection -ErrorAction Stop
        $sids.Add([string]$u.SID)
        # tokenGroups = the full transitive group set (what an access check actually uses).
        try {
            $obj = Get-ADUser -Identity $sam -Properties tokenGroups @AdConnection -ErrorAction Stop
            foreach ($g in @($obj.tokenGroups)) { $sids.Add([string]$g) }
        } catch {
            foreach ($g in @(Get-ADPrincipalGroupMembership -Identity $sam @AdConnection -ErrorAction SilentlyContinue)) { $sids.Add([string]$g.SID) }
        }
        # Everyone / Authenticated Users ACEs apply to any bound account.
        $sids.Add('S-1-1-0'); $sids.Add('S-1-5-11')
    } catch { return @() }
    @($sids | Select-Object -Unique)
}

function Test-CtgAdOuCreateUserRight {
    <#
    .SYNOPSIS
        One rights row (@{ op; ok; detail }) for "create users in $OuDn": reads the OU's security
        descriptor and evaluates it against the account's SIDs. Read-only; anything unreadable
        degrades to ok=$null ("verify manually"), never a false failure.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$AdConnection = @{},
        [Parameter(Mandatory)][string]$OuDn,
        [AllowEmptyCollection()][string[]]$Sids = @()
    )
    $op = "create users in $OuDn"
    if (-not $Sids -or $Sids.Count -eq 0) {
        return @{ op = $op; ok = $null; detail = 'could not resolve the service account''s SIDs — check the OU ACL manually' }
    }
    try {
        $ou = Get-ADOrganizationalUnit -Identity $OuDn -Properties ntSecurityDescriptor @AdConnection -ErrorAction Stop
        $acl = $ou.ntSecurityDescriptor
        $rules = @()
        foreach ($ace in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            $rules += @{
                Type       = [string]$ace.AccessControlType
                Sid        = [string]$ace.IdentityReference
                Rights     = [string]$ace.ActiveDirectoryRights
                ObjectType = [string]$ace.ObjectType
            }
        }
        $can = Test-CtgAdCreateUserAce -Rules $rules -Sids $Sids
        if ($can) { return @{ op = $op; ok = $true; detail = 'the account (or one of its groups) can create user objects here' } }
        return @{ op = $op; ok = $false; detail = 'no ACE grants this account CreateChild(user)/GenericAll on the OU — delegate "Create user objects" to it' }
    }
    catch {
        return @{ op = $op; ok = $null; detail = "could not read the OU ACL ($(([string]$_.Exception.Message).Trim())) — check it manually" }
    }
}

Export-ModuleMember -Function Invoke-CtgADOnboarding, Invoke-CtgADOffboarding, Invoke-CtgADChange, Invoke-CtgADEmailWriteback, Confirm-CtgADEmailWriteback, Invoke-CtgADPhoneWriteback, Confirm-CtgADPhoneWriteback, Invoke-CtgADConsistencyCheck, Invoke-CtgADHardMatch, Invoke-CtgADPasswordReset, Set-CtgADAttributes, Get-CtgMirrorGroups, Test-CtgCondition, Resolve-CtgOuPath, Confirm-CtgAD, Test-CtgAdCreateUserAce, Get-CtgAdAccountSids, Test-CtgAdOuCreateUserRight
