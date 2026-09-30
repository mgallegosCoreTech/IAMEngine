@{
    RootModule        = 'Coretelligent.Teams.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5d0f5c1e-7a2b-4f3e-9c61-2b8f4e6a9d17'
    Author            = 'Coretelligent Remote Operations'
    CompanyName       = 'Coretelligent'
    Description       = 'Teams Phone: assign a Calling Plan number on onboard (by office area code, or the one entered on the case) once the licence reaches Teams, and release it on offboard. Runs the MicrosoftTeams cmdlets in a child pwsh so they never share a process with Microsoft.Graph.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @('ConvertTo-CtgTeamsE164', 'ConvertTo-CtgTeamsAreaPrefix', 'Test-CtgTeamsVoiceReady', 'Select-CtgTeamsFreeNumbers', 'Get-CtgTeamsUpn', 'Get-CtgTeamsAssignedNumbers', 'Invoke-CtgTeamsOnboarding', 'Invoke-CtgTeamsOffboarding', 'Confirm-CtgTeams', 'ConvertFrom-CtgTeamsChildOutput', 'Invoke-CtgTeamsOutOfProcess')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
