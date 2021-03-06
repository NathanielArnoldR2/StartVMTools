<#

@TODO:

Develop a way to detect absent parameters in an advanced function without
having to know their names. E.G. compare the set of all valid parameters
for a ParameterSetName against the PSBoundParameters hashtable.

Useful for "protecting" PersistentData.ConfigurationCommand against an
intentionally malformed xml, preventing an unwanted mandatory parameter
prompt.

#>

. $PSScriptRoot\StartVMTools.WriteOutputTime.ps1

$resources = @{}

$resources.ToolsetConfigSchema  = [System.Xml.Schema.XmlSchema]::Read(
  [System.Xml.XmlNodeReader]::new(
    [xml](Get-Content -LiteralPath $PSScriptRoot\StartVMTools.ToolsetConfig.xsd -Raw)
  ),
  $null
)
$resources.ToolsetConfigCommand = [scriptblock]::Create((
  Get-Content -LiteralPath $PSScriptRoot\StartVMTools.ToolsetConfig.ConfigurationCommand.ps1 -Raw
))

$resources.ActionsConfigSchema = [System.Xml.Schema.XmlSchema]::Read(
  [System.Xml.XmlNodeReader]::new(
    [xml](Get-Content -LiteralPath $PSScriptRoot\StartVMTools.xsd -Raw)
  ),
  $null
)
$resources.ActionsConfigCommands = [scriptblock]::Create((
  Get-Content -LiteralPath $PSScriptRoot\StartVMTools.ConfigurationCommands.ps1 -Raw
))

$resources.RuleEvaluator = [scriptblock]::Create(
  (Get-Content -LiteralPath $PSScriptRoot\StartVMTools.RuleEvaluator.ps1 -Raw)
)

$resources.PersistentDataSchema = [System.Xml.Schema.XmlSchema]::Read(
  [System.Xml.XmlNodeReader]::new(
    [xml](Get-Content -LiteralPath $PSScriptRoot\StartVMTools.PersistentData.xsd -Raw)
  ),
  $null
)
$resources.PersistentDataCommand = [scriptblock]::Create((
  Get-Content -LiteralPath $PSScriptRoot\StartVMTools.PersistentData.ConfigurationCommand.ps1 -Raw
))
$resources.PersistentDataRules = [scriptblock]::Create((
  Get-Content -LiteralPath $PSScriptRoot\StartVMTools.PersistentData.Rules.ps1 -Raw
))

$credPath = "$PSScriptRoot\StartVMTools.FallbackCredentials.ps1"

$resources.FallbackCredentials = @()
if (Test-Path -LiteralPath $credPath) {
  $resources.FallbackCredentials = @(
    & $credPath
  )
}

$resources.ToolsetConfigRules = [scriptblock]::Create(
  (Get-Content -LiteralPath $PSScriptRoot\StartVMTools.ToolsetConfig.Rules.ps1 -Raw)
)

$resources.ValidityRules = [scriptblock]::Create(
  (Get-Content -LiteralPath $PSScriptRoot\StartVMTools.Rules.Validity.ps1 -Raw)
)
$resources.ReadinessRules = [scriptblock]::Create(
  (Get-Content -LiteralPath $PSScriptRoot\StartVMTools.Rules.Readiness.ps1 -Raw)
)

$resources.InjectScripts = @{}
$resources.InjectScripts.InitLocalPaths = {
  $localPaths = @{
    CTRoot = Join-Path -Path $env:SystemDrive -ChildPath CT
  }
  $localPaths.Modules = Join-Path -Path $localPaths.CTRoot -ChildPath Modules
  $localPaths.Packages = Join-Path -Path $localPaths.CTRoot -ChildPath Packages
}
$resources.InjectScripts.InitOnlineResources = {
  if (Test-Path -LiteralPath $localPaths.CTRoot) {
    throw "The resource destination path already exists @ '$($localPaths.CTRoot)' on the vm. Any successful configuration should have removed this path."
  }

  $startTime = Get-Date

  while ($true) {
    if (Test-NetConnection -ComputerName $params.ResourceServer -InformationLevel Quiet -ErrorAction Ignore -WarningAction SilentlyContinue) {
      break
    }

    if (((Get-Date) - $startTime).TotalMinutes -ge 1) {
      throw "Failed to establish presence of a resource server within a minute."
    }
  }

  $sharePaths = @{
    Modules  = "\\$($params.ResourceServer)\Modules"
    Packages = "\\$($params.ResourceServer)\Packages"
  }

  while ($true) {
    $absentShares = @(
      $sharePaths.Values |
        Where-Object {-not (Test-Path -LiteralPath $_)}
    )

    if ($absentShares.Count -eq 0) {
      break
    }

    if (((Get-Date) - $startTime).TotalMinutes -ge 1) {
      throw "Failed to establish simultaneous presence of all resource shares within a minute."
    }
  }

  New-Item -Path $localPaths.Modules -ItemType Directory -Force |
    Out-Null

  Get-ChildItem -LiteralPath $sharePaths.Modules |
    Copy-Item -Destination $localPaths.Modules -Recurse

$importScript = {

$modules = Get-ChildItem -LiteralPath $PSScriptRoot -Directory |
             ForEach-Object Name

$modules |
  ForEach-Object {
    Import-Module "$PSScriptRoot\$_\$_.psm1"
  }

if ($modules -contains "CTPackage") {
  Add-CTPackageSource -Name Local  -Path "%PACKAGELOCAL%"
  Add-CTPackageSource -Name Remote -Path "%PACKAGESHARE%"
}

}.ToString().
  Trim().
  Replace("%PACKAGELOCAL%", $localPaths.Packages).
  Replace("%PACKAGESHARE%", $sharePaths.Packages)

  $importPath = New-Item -Path $localPaths.Modules -Name import.ps1 -Value $importScript |
                  ForEach-Object FullName

  . $importPath

  if ($Error.Count -gt 0) {
    throw "Terminating due to unexpected error."
  }
}
$resources.InjectScripts.InitOfflineResources = {

$importScript = {

$modules = Get-ChildItem -LiteralPath $PSScriptRoot -Directory |
             ForEach-Object Name

$modules |
  ForEach-Object {
    Import-Module "$PSScriptRoot\$_\$_.psm1"
  }

if ($modules -contains "CTPackage") {
  Add-CTPackageSource -Name Local  -Path "%PACKAGELOCAL%"
}

}.ToString().
  Trim().
  Replace("%PACKAGELOCAL%", $localPaths.Packages)

  $importPath = New-Item -Path $localPaths.Modules -Name import.ps1 -Value $importScript |
                  ForEach-Object FullName

  . $importPath

  if ($Error.Count -gt 0) {
    throw "Terminating due to unexpected error."
  }
}
$resources.InjectScripts.RunAsUser = {

  function Register-ConfigTaskInUserSession {
    [CmdletBinding(
      PositionalBinding = $false
    )]
    param(
      [Parameter(
        Mandatory = $true,
        Position = 0
      )]
      [scriptblock]
      $Task,

      [switch]
      $Wait
    )
    try {
      $encodedCommand = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($Task.ToString().Trim())
      )
      
      $params = @{
        TaskName  = "Start"
        Principal = New-ScheduledTaskPrincipal   -GroupId BUILTIN\Users
        Action    = New-ScheduledTaskAction      -Execute "C:\Windows\System32\WindowsPowershell\v1.0\powershell.exe" -Argument "/EncodedCommand $encodedCommand"
        Settings  = New-ScheduledTaskSettingsSet -Priority 4 # 4 is Normal Priority. Default of 7 is Below Normal.
        Trigger   = New-ScheduledTaskTrigger     -At (Get-Date).AddMinutes(2) -Once # Long enough to be sure user has (auto) signed in.
      }
      
      $scheduledTask = Register-ScheduledTask @params
      
      if ($Wait) {
        do {
          Start-Sleep -Seconds 60
      
          $info = $scheduledtask |
                          Get-ScheduledTaskInfo

          # Task result with bitmask 0x41300 reflects status of the task
          # *construct*, rather than that of the task itself. For example,
          # 0x41303 is a task that has not run, while 0x41301 is a task
          # in progress.
        } until (($info.LastTaskResult -band 0x41300) -ne 0x41300)
      
        if ($info.LastTaskResult -ne 0) {
          throw "Task in user session returned unexpected result code $($info.LastTaskResult)."
        }
      }
    } catch {
      $PSCmdlet.ThrowTerminatingError($_)
    }
  }
  New-Alias -Name runAsUser -Value Register-ConfigTaskInUserSession

}

#region Config retrieval & validation
function Test-StartVMIsValidComputerName {
  param(
    [string]
    $Name
  )
  try {
    if ($Name.Length -ne $Name.Trim().Length) {
      return $false
    }

    if ($Name.Length -lt 1 -or $Name.Length -gt 14) {
      return $false
    }

    if ($Name -notmatch "^[A-Z0-9\-]+$") {
      return $false
    }

    if ($Name[0] -eq "-" -or $Name[-1] -eq "-") {
      return $false
    }

    return $true
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function Get-StartVMToolsetConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [String]
    $ToolsetConfigPath
  )

  try {
    Write-Verbose "Retrieving & validating toolset configuration."

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()

    $rs.CreatePipeline('$config = @{}; $config.Resources = @{}; $config.Resources.Online = @{}; $config.Resources.Offline = @{}').Invoke() | Out-Null

    try {
      $rs.CreatePipeline((Get-Content -LiteralPath $ToolsetConfigPath -Raw -ErrorAction Stop)).Invoke() | Out-Null
    } catch {
      $exception = [System.Exception]::new(
        "Error while processing toolset config definition file.",
        $_.Exception
      )

      throw $exception
    }

    if ($rs.CreatePipeline('$config').Invoke()[0] -isnot [hashtable]) {
      throw "Error while retrieving toolset config definition. Config object in transitional state was not a hashtable."
    }

    $rs.CreatePipeline($script:resources.ToolsetConfigCommand.ToString()).Invoke() | Out-Null

    $config = $rs.CreatePipeline("New-StartVMToolsetConfiguration @config").Invoke()[0]
    $rs.Close()

    if ($config -isnot [System.Xml.XmlElement]) {
      throw "Error while retrieving toolset config definition. Config object in final state was not an XmlElement."
    }

    $TestXml = $config.OwnerDocument.OuterXml -as [xml]
    $TestXml.Schemas.Add($script:resources.ToolsetConfigSchema) |
      Out-Null

    try {
      $TestXml.Validate($null)
    } catch {
      $exception = [System.Exception]::new(
        "Error while validating toolset config to schema. $($_.Exception.InnerException.Message)",
        $_.Exception
      )

      throw $exception
    }

    $config = Test-StartVMToolsetConfiguration -Configuration $config

    $config
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}
function Test-StartVMToolsetConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNode]
    $Configuration
  )
  try {
    if ($Configuration -is [System.Xml.XmlElement]) {
      $Configuration = $Configuration.OwnerDocument
    }

    $OutputXml = $Configuration.OuterXml -as [xml]

    . $script:resources.RuleEvaluator

    New-Alias -Name rule -Value New-EvaluationRule

    . $script:resources.ToolsetConfigRules

    Remove-Item alias:\rule

    Invoke-EvaluationRules -Xml $OutputXml -Rules $Rules

    return $OutputXml.SelectSingleNode("/Configuration")
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function Set-StartVMRootShortcut {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration
  )

  $PSDriveRoot = $PSScriptRoot.Substring(0, 3)

  $shortcutName = $Configuration.Name + ".lnk"

  $shortcutPath = Join-Path -Path $PSDriveRoot -ChildPath $shortcutName

  if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
    return
  }

  Get-ChildItem -LiteralPath $PSDriveRoot -File -Force |
    Where-Object Extension -eq .lnk |
    Remove-Item -Force

  Import-Module $PSDriveRoot\src\ps1\inc\PortableScriptShortcuts\PortableScriptShortcuts.psm1 -Verbose:$false

  New-PortableScriptShortcut -ShortcutPath $shortcutName `
                             -ScriptPath StartVM.ps1 `
                             -ScriptParameters $Configuration.Name
}

function Select-StartVMActionSetContext {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Configuration,

    [Parameter(
      Mandatory = $true
    )]
    [AllowEmptyString()]
    [string]
    $Context
  )

  Write-Verbose "Selecting or validating actionset context."

  $Contexts = @(
    "Config"
    "Start"
    "Test"
    "Save"
    "Restore"
    "Update"
    "Custom"
  )

  $ContextsInConfiguration = @(
    $Configuration.SelectNodes("ActionSets/ActionSet/@Context") |
      ForEach-Object "#text"
  )

  # Deriving supported contexts in this manner lets us avoid any defects in the
  # value pulled from XML. Validation to schema should take care of this, but
  # it's better to be safe than sorry.
  $SupportedContexts = @(
    $Contexts |
      Where-Object {$_ -in $ContextsInConfiguration}
  )

  if ($Context.Length -gt 0 -and $Context -notin $Contexts) {
    throw "Provided context is unknown to this module."
  }
  elseif ($Context.Length -gt 0 -and $Context -notin $SupportedContexts) {
    throw "Provided context is not supported by this configuration."
  }
  elseif ($Context.Length -gt 0) {
    # Normalize capitalization of provided context.
    return $SupportedContexts |
             Where-Object {$_ -eq $Context}
  }

  if ($SupportedContexts.Count -eq 1) {
    return $SupportedContexts[0]
  }

  $inc = 1

  $choices = @(
    $SupportedContexts |
      ForEach-Object {
        [System.Management.Automation.Host.ChoiceDescription]::new(
          "&$($inc): $($_)",
          $null # TODO: Context help messages?
        )
        $inc++
      }
  )

  $result = $Host.UI.PromptForChoice(
    $null,
    "Select a supported actionset context.",
    $choices,
    0
  )

  return $SupportedContexts[$result]
}

function Resolve-StartVMRuntimeConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ActionsConfig,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Context,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )

  Write-Verbose "Resolving configuration resources from runtime environment."

  $defaultOptions = @(
    $ToolsetConfig.SelectNodes("DefaultMemberOptions/DefaultMemberOption") |
      ForEach-Object InnerXml
  )

  $ignoreList = @(
    $ToolsetConfig.SelectNodes("IgnoreList/IgnoreListItem") |
      ForEach-Object InnerXml
  )

  $RuntimeConfig.DisallowedMemberNames = [string[]]@(
    $defaultOptions
    $ignoreList
  )

  $actionSet = $ActionsConfig.SelectNodes("/Configuration/ActionSets/ActionSet[@Context='$Context']")

  if ($actionSet.Count -ne 1) {
    throw "No more than one actionset may be defined for any context. $($actionSet.Count) actionset(s) were defined for context '$Context'."
  }

  $actionSet = $actionSet[0]

  $members = @(
    $actionSet.SelectNodes("Members/Member")
  )

  if ($members.Count -eq 0) {
    $members = @(
      $ActionsConfig.SelectNodes("/Configuration/Members/Member")
    )
  }

  if ($members.Count -eq 0) {
    throw "Each actionset must have an associated list of members, whether directly defined for it or inherited from the wider configuration."
  }

  if ($members.Name -contains 'default') {
    Write-Verbose "  - Selecting vm for 'default' member."

    $vms = @(
      Get-VM |
        ForEach-Object Name
    )

    $RuntimeConfig.DefaultMemberName = $defaultOptions |
                                         Where-Object {$_ -in $vms} |
                                         Select-Object -First 1

    $defaultIsRequired = @(
      $members |
        Where-Object Name -eq default |
        Where-Object Required -eq true
    ).Count -gt 0

    # If 'default' is not required, the member is simply marked non-present
    # during readiness testing. Otherwise, this error is thrown.
    if ($null -eq $RuntimeConfig.DefaultMemberName -and $defaultIsRequired) {
      throw "No vm listed in the 'DefaultMemberOptions' in the toolset config was found on this host."
    }
  }

  if ($Context -eq "Update") {
    Write-Verbose "  - Prompting user to confirm 'Update' context."

    $choices = @()
    $choices += [System.Management.Automation.Host.ChoiceDescription]::new(
      "&Yes",
      "Run a test of this 'Update' configuration that keeps the current top checkpoint."
    )
    $choices += [System.Management.Automation.Host.ChoiceDescription]::new(
      "&No",
      "Run the 'Update' configuration as is, replacing the current top checkpoint."
    )

    $result = $Host.UI.PromptForChoice(
      $null,
      "Would you like to run a test of this 'Update' that will not overwrite the current top checkpoint?",
      $choices,
      0
    )

    $RuntimeConfig.RunUpdateAsTest = $result -eq 0
  }

  $usesPhysHostName = @(
    $actionSet.
      Actions.
      Action.
      Where({$_.Type -eq "InjectAction"}).
      Where({$_.UsePhysHostName -eq "true"})
  ).Count -gt 0

  if ($usesPhysHostName) {
    Write-Verbose "  - Selecting physical hostname for conveyance to vm configuration."

    $hostname = [System.Net.Dns]::GetHostName()

    if ($ToolsetConfig.PhysHostNameOverride -eq 'true') {
      Write-Verbose "    - Provide a hostname, or press [Enter] to use actual hostname '$hostname'."
      while ($true) {
        $RuntimeConfig.PhysHostName = Read-Host -Prompt Hostname

        if ($RuntimeConfig.PhysHostName.Length -eq 0) {
          $RuntimeConfig.PhysHostName = $hostname
          break
        }
        elseif (Test-StartVMIsValidComputerName -Name $RuntimeConfig.PhysHostName) {
          break
        }

        Write-Warning "Hostname was not valid for this context."
      }
    }
    elseif ($ToolsetConfig.PhysHostNameOverride -ne 'false') {
      $choices = @()
      $choices += [System.Management.Automation.Host.ChoiceDescription]::new(
        "&Yes",
        "Pass override value '$($ToolsetConfig.PhysHostNameOverride)' to vm configuration steps."
      )
      $choices += [System.Management.Automation.Host.ChoiceDescription]::new(
        "&No",
        "Pass actual hostname '$hostname' to vm configuration steps."
      )

      $result = $Host.UI.PromptForChoice(
        $null,
        "Would you like to pass the configured hostname override value '$($ToolsetConfig.PhysHostNameOverride)' to vm configuration steps?",
        $choices,
        -1
      )

      if ($result -eq 0) {
        $RuntimeConfig.PhysHostName = $ToolsetConfig.PhysHostNameOverride
      }
      elseif ($result -eq 1) {
        $RuntimeConfig.PhysHostName = $hostname
      }
    }
    else {
      $RuntimeConfig.PhysHostName = $hostname
    }

    if ($RuntimeConfig.PhysHostName.Length -gt 14) {
      $RuntimeConfig.PhysHostName = $RuntimeConfig.PhysHostName.Substring(0, 14)
      Write-Warning "    - Truncated oversize hostname to '$($RuntimeConfig.PhysHostName)'."
    }
  }

  $usesOfflineServicing = @(
    $actionSet.
      Actions.
      Action.
      Where({$_.Type -eq "CustomAction"}).
      Where({
        $_.OfflineServicing -eq "true"
      })
  ).Count -gt 0

  $usesResourceServer = @(
    $actionSet.
      Actions.
      Action.
      Where({$_.Type -eq "InjectAction"}).
      Where({
        $_.UseResourceServer -eq "true" -or
        $_.SelectNodes("Packages/Package").Count -gt 0
      })
  ).Count -gt 0

  if ($usesOfflineServicing -or ($usesResourceServer -and $ToolsetConfig.Resources.ApplyMode -eq "Offline")) {
    Write-Verbose "  - Verifying elevated context for offline servicing."

    # Is the principal derived from the current Windows identity an *elevated*
    # administrator?
    $scriptIsElevated =
    [System.Security.Principal.WindowsPrincipal]::new(
      [System.Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole(
      [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )

    if (-not $scriptIsElevated) {
      throw "The script must be run elevated to service vm resources mounted offline."
    }
  }

  if ($usesResourceServer -and $ToolsetConfig.Resources.ApplyMode -eq "Online") {
    Write-Verbose "  - Selecting and validating resource server for modules and packages."

    $serverOptions = $ToolsetConfig.SelectNodes("Resources/Online/ServerOptions/ServerOption") |
                       ForEach-Object InnerXml

    if ($serverOptions.Count -eq 0) {
      throw "No resource server options were defined in the toolset configuration."
    }

    $startTime = Get-Date
    
    :ext while ($true) {
      foreach ($server in $serverOptions) {
        if (Test-NetConnection -ComputerName $server -InformationLevel Quiet -ErrorAction Ignore -WarningAction SilentlyContinue) {
          break ext
        }
      }

      if (((Get-Date) - $startTime).TotalHours -ge 1) {
        throw "Failed to establish presence of a resource server within an hour."
      }

      Start-Sleep -Seconds 60
    }

    if ($ToolsetConfig.Resources.Online.TestShares -eq 'false') {
      Write-Warning "    - Skipped share validation."
    }
    else {
      $sharePaths = @(
        "Modules",
        "Packages" |
          ForEach-Object {
            Join-Path -Path "\\$server\" -ChildPath $_
          }
      )

      $shareStartTime = Get-Date
      $showedHint = $false

      while ($true) {
        $absentShares = @(
          $sharePaths |
            Where-Object {-not (Test-Path -LiteralPath $_)}
        )

        if ($absentShares.Count -eq 0) {
          break
        }

        if (((Get-Date) - $shareStartTime).TotalMinutes -ge 5 -and (-not $showedHint)) {
          Write-Verbose "    - HINT: Try running with toolsetconfig.resources.online.testshares set to '`$false'!"
          $showedHint = $true
        }

        if (((Get-Date) - $startTime).TotalHours -ge 1) {
          throw "Failed to establish simultaneous presence of all resource shares within an hour."
        }

        Start-Sleep -Seconds 60
      }
    }

    $RuntimeConfig.ResourceServer = $server
  } elseif ($usesResourceServer -and $ToolsetConfig.Resources.ApplyMode -eq "Offline") {
    Write-Verbose "  - Validating offline source paths for modules and packages."

    function Test-StartVMOfflineSourcePath {
      param(
        [Parameter(
          Mandatory = $true
        )]
        [string]
        $Path
      )
      try {
        if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
          return $false
        }

        $item = Get-Item -LiteralPath $Path -ErrorAction Stop

        if ($item -isnot [System.IO.DirectoryInfo]) {
          return $false
        }
    
        if ($Path -ne $item.FullName) {
          return $false
        }
    
        return $true
      } catch {
        $PSCmdlet.ThrowTerminatingError($_)
      }
    }

    if (
      $ToolsetConfig.Resources.Offline.ModulesSourcePath.Length -eq 0 -or
      $ToolsetConfig.Resources.Offline.PackagesSourcePath.Length -eq 0
    ) {
      throw "Offline source paths for Modules and Packages must be defined when the selected actionset uses resources and apply mode is 'Offline'."
    }

    if (
      (-not (Test-StartVMOfflineSourcePath $ToolsetConfig.Resources.Offline.ModulesSourcePath)) -or
      (-not (Test-StartVMOfflineSourcePath $ToolsetConfig.Resources.Offline.PackagesSourcePath))
    ) {
      throw "Offline source paths for Modules and Packages must be rooted, direct paths to existing directories on a local volume or network share."
    }
  }
}

function Test-StartVMActionsConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNode]
    $ActionsConfig
  )
  try {

    Write-Verbose "Validating actions configuration structure and consistency."

    $OutputXml = $ActionsConfig.OwnerDocument.OuterXml -as [xml]

    . $script:resources.RuleEvaluator

    New-Alias -Name rule -Value New-EvaluationRule

    . $script:resources.ValidityRules

    Remove-Item alias:\rule

    Invoke-EvaluationRules -Xml $OutputXml -Rules $Rules

    return $OutputXml.SelectSingleNode("/Configuration")
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}
#endregion

#region Persistent data handling
function Read-StartVMPersistentData {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Path,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $ConfigurationName,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $ActionSetContext
  )
  try {
    if ($ActionSetContext -ne "Save") {
      if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
      }

      return
    }

    Write-Verbose "Processing persistent data file on vm host."

    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
      throw "A persistent data file was not found at the expected path. This file must exist at this path for a 'Save'-context actionset to proceed. Run an actionset of any other context to generate this file."
    }

    try {
      $data = Import-Clixml -LiteralPath $Path

      if ($data -isnot [hashtable]) {
        throw "Object retrieved from CliXml was not a hashtable."
      }

      . $script:resources.PersistentDataCommand

      $data = New-StartVMPersistentData @data

      if ($data -isnot [System.Xml.XmlElement]) {
        throw "Object emitted by configuration command was not an XmlElement, as expected."
      }

      $TestXml = $data.OwnerDocument.OuterXml -as [xml]
      $TestXml.Schemas.Add($script:resources.PersistentDataSchema) |
        Out-Null

      try {
        $TestXml.Validate($null)
      } catch {
        $exception = [System.Exception]::new(
          "Error while validating persistent data to schema. See InnerException for more details.",
          $_.Exception
        )

        throw $exception
      }

      $TestXml = $data.OwnerDocument.OuterXml -as [xml]

      . $script:resources.RuleEvaluator

      New-Alias -Name rule -Value New-EvaluationRule

      . $script:resources.PersistentDataRules

      Remove-Item alias:\rule

      Invoke-EvaluationRules -Xml $TestXml -Rules $Rules 
    } catch {
      Remove-Item -LiteralPath $Path -Force

      $exception = [System.Exception]::new(
        "Error while processing persistent data file. See InnerException for more details. File has been removed.",
        $_.Exception
      )

      throw $exception
    }

    if ($data.LastConfigurationName -ne $ConfigurationName -or $data.LastActionSetContext -notin "Start","Restore") {
      throw "A 'Save'-context actionset may only proceed when the last actionset run on this host was a 'Start' or 'Restore' for the same configuration name."
    }

    Remove-Item -LiteralPath $Path -Force

  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function Write-StartVMPersistentData {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Path,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $ConfigurationName,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $ActionSetContext
  )
  try {
    Write-Verbose "Writing persistent data file on vm host."

    @{
      LastConfigurationName = $ConfigurationName
      LastActionSetContext  = $ActionSetContext
      LastProcessed         = [datetime]::Now
    } |
      Export-Clixml -LiteralPath $Path
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}
#endregion

#region Config resolution & transformation; environment preparation
function Resolve-StartVMActionsConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNode]
    $ActionsConfig,

    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Context,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  try {
    Write-Verbose "Resolving '$Context' context actionset against available resources on host."

    $OutputXml = $ActionsConfig.OwnerDocument.OuterXml -as [xml]

    $OutputXml.SelectNodes("/Configuration/ActionSets/ActionSet") |
      Where-Object Context -ne $Context |
      ForEach-Object {
        $_.ParentNode.RemoveChild($_)
      } |
      Out-Null

    . $script:resources.RuleEvaluator

    New-Alias -Name rule -Value New-EvaluationRule

    . $script:resources.ReadinessRules

    Remove-Item alias:\rule

    Invoke-EvaluationRules -Xml $OutputXml -Rules $Rules

    $OutputXml.SelectNodes("/Configuration/ActionSets/ActionSet/Members/Member") |
      ForEach-Object {
        if ($_.Required -eq 'true') {
          $reqString = "REQUIRED"
        }
        else {
          $reqString = "OPTIONAL"
        }

        if ($_.Present -eq 'true') {
          $presString = "PRESENT"
        }
        else {
          $presString = "ABSENT"
        }

        if ($_.Present -eq 'true' -and $_.Name -ne $_.VMName) {
          $asString = " as '$($_.VMName)'"
        }
        else {
          $asString = [string]::Empty
        }

        Write-Verbose "  - $($reqString) member '$($_.Name)' is $($presString)$($asString)."
      }

    return $OutputXml.SelectSingleNode("/Configuration/ActionSets/ActionSet")
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function Resolve-StartVMActionsConfiguration_EachAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Action
  )

#region Type-Specific Handlers
function Resolve-StartVMActionsConfiguration_EachAction_RestoreCheckpoint {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNodeList]
    $Members
  )

  $context = $Action.SelectSingleNode("../..").Context
  
  $goodSnapshotStates = @(
    "Off"
  )
  
  if ($context -in "Start","Custom") {
    $checkpointNameBase = "Class-Ready Configuration"
  }
  elseif ($context -eq "Restore") {
    $checkpointNameBase = "Mid-Class Configuration"
    $goodSnapshotStates += "Saved"
  }
  
  foreach ($item in $Action.SelectNodes("CheckpointMap/CheckpointMapItem")) {
    $member = $Members |
                Where-Object Name -eq $item.Target
  
    if ($member.Present -ne 'true') {
      $item.ParentNode.RemoveChild($item)
      continue
    }
  
    $vmSnapshots = @(
      Get-VM -Id $member.VMId |
        Get-VMSnapshot
    )
  
    if ($item.CheckpointName.Length -eq 0 -and $context -in "Start","Config","Update","Custom") {
      $targetSnapshot = @(
        $vmSnapshots |
          Where-Object ParentSnapshotId -eq $null
      )
    }
    elseif ($context -in "Start","Custom") {
      $targetSnapshot = @(
        $vmSnapshots |
          Where-Object Name -eq "$checkpointNameBase ($($item.CheckpointName))"
      )
    }
    elseif ($context -eq "Restore") {
      $targetSnapshot = @(
        $vmSnapshots |
          Where-Object ParentSnapshotName -eq "Class-Ready Configuration ($($item.CheckpointName))" |
          Where-Object Name -eq $checkpointNameBase
      )
    
      if ($targetSnapshot.Count -eq 0) {
        $targetSnapshot = @(
          $vmSnapshots |
            Where-Object Name -eq "$checkpointNameBase ($($item.CheckpointName))"
        )
      }
    }
  
    if ($targetSnapshot.Count -ne 1) {
      throw "Expected to find exactly one checkpoint matching '$context' '$($item.CheckpointName)' specification for member '$($member.Name)', but found $($targetSnapshot.Count)."
    }
  
    $targetSnapshot = $targetSnapshot[0]
  
    if ($targetSnapshot.State -notin $goodSnapshotStates) {
      throw "Targeted snapshot had invalid state '$($targetSnapshot.State)'."
    }
  
    $item.SetAttribute("VMId", $member.VMId)
    $item.SetAttribute("CheckpointId", $targetSnapshot.Id)
  }
}
function Resolve-StartVMActionsConfiguration_EachAction_Inject {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNodeList]
    $Members
  )

  Resolve-StartVMActionsConfiguration_Credential -Node $Action
}
function Resolve-StartVMActionsConfiguration_EachAction_ConfigHw {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNodeList]
    $Members
  )

  $procCountMax = (Get-VMHost).LogicalProcessorCount
  $memBytesMax  = (Get-VMHost).MemoryCapacity
  $switches  = @(Get-VMSwitch)

  if ($Action.ProcessorCount -is [string] -and [int]$Action.ProcessorCount -gt $procCountMax) {
    throw "A maximum of $procCountMax logical processors may be assigned to a vm on this host."
  }

  if ($Action.MemoryBytes -is [string] -and [int64]$Action.MemoryBytes -gt $memBytesMax) {
    throw "A maximum of $([System.Math]::Floor($memBytesMax / 1gb))gb memory may be assigned to a vm on this host."
  }

  foreach ($adapter in $Action.SelectSingleNode("NetworkAdapters").NetworkAdapter) {
    if ($adapter -eq 'none') {
      continue
    }

    $switchesWithName = @(
      $switches |
        Where-Object Name -eq $adapter
    )

    if ($switchesWithName.Count -ne 1) {
      throw "Expected to find exactly one switch with name '$adapter' on this host. Found $($switchesWithName.Count) instead."
    }
  }
}
function Resolve-StartVMActionsConfiguration_EachAction_TakeCheckpoint {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlNodeList]
    $Members
  )

  $context = $Action.SelectSingleNode("../..").Context

  if ($context -eq "Config") {
    $Action.CheckpointName = "Class-Ready Configuration ($($Action.CheckpointName))"
  }

  if ($context -eq "Save") {
    if ($Action.CheckpointName.Length -eq 0) {
      $Action.CheckpointName = "Mid-Class Configuration"
    }
    else {
      $Action.CheckpointName = "Mid-Class Configuration ($($Action.CheckpointName))"
    }
  }
  elseif ($context -eq "UpdateTest") {
    $Action.CheckpointName = "Update Test Configuration"
  }
}
#endregion
  try {
    $members = $Action.SelectNodes("../../Members/Member")

    if ($Action.Target -is [string]) {
      # Established during validity rules that attribute value may be empty only
      # when the actionset has one member.
      if ($Action.Target.Length -eq 0) {
        $Action.SetAttribute("Target", $members[0].Name)
      }

      # Hereafter, Action.Target *must* be the name of exactly *one* actionset
      # member. We established during validity rules that each member name
      # must be unique.

      $member = $members |
                  Where-Object Name -eq $Action.Target

      if ($member.Present -ne 'true') {
        $Action.ParentNode.RemoveChild($Action)
        return
      }

      $Action.SetAttribute("VMName", $member.VMName)
      $Action.SetAttribute("VMId", $member.VMId)
    }

    $handlerName = "Resolve-StartVMActionsConfiguration_EachAction_$($Action.Type -replace 'Action$','')"

    if (Test-Path -LiteralPath "function:\$handlerName") {
      & $handlerName -Action $Action -Members $members
    }
  } catch {
    # Simply re-throwing, because using $PSCmdlet.ThrowTerminatingError just
    # fails silently at this juncture.
    throw $_
  }
}

# Encompasses inheritance, verification of presence where required, and
# validity checking.
function Resolve-StartVMActionsConfiguration_Credential {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $Node
  )

  try {
    $credNode = $node.SelectSingleNode("Credential")

    if ($credNode -eq $null) {
      $credOptions = @()

      if ($node.LocalName -eq "Member") {
        $memberName = $node.Name
      }
      elseif ($node.LocalName -eq "Action") {
        $memberName = $node.Target
      }

      # 'Inject' Action resolves up to ActionSet Member
      $credOptions += $node.SelectNodes("../../Members/Member") |
                        Where-Object Name -eq $memberName |
                        ForEach-Object Credential

      # 'Inject' Action or ActionSet Member resolves up to Configuration Member
      $credOptions += $node.SelectNodes("../../../../Members/Member") |
                        Where-Object Name -eq $memberName |
                        ForEach-Object Credential

      # Any context will take a Fallback Credential.
      $credOptions += $script:resources.FallbackCredentials |
                        Where-Object MemberName -eq $memberName

      $cred = $credOptions |
                Where-Object {$_ -ne $null} |
                Select-Object -First 1

      if ($cred -eq $null -and $node.LocalName -eq "Member") {
        return
      }
      elseif ($cred -eq $null -and $node.LocalName -eq "Action") {
        throw "No credential was provided for this action, and none could not be derived from the actionset, configuration, or fallback credential store."
      }

      $credNode = $node.AppendChild(
        $node.
        OwnerDocument.
        CreateElement("Credential")
      )

      $credNode.SetAttribute("Domain", $cred.Domain)
      $credNode.SetAttribute("UserName", $cred.UserName)
      $credNode.SetAttribute("Password", $cred.Password)
    }

    if ($credNode.Domain -ne $credNode.Domain.Trim() -or $credNode.Domain -match "\\") {
      throw "Credential Domain had leading or trailing whitespace or contained a backslash."
    }

    if ($credNode.UserName -ne $credNode.UserName.Trim() -or $credNode.UserName -match "\\") {
      throw "Credential UserName had leading or trailing whitespace or contained a backslash."
    }

    if ($credNode.Password -ne $credNode.Password.Trim()) {
      throw "Credential Password had leading or trailing whitespace."
    }
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

function Invoke-StartVMActionsTransform_AutoConfigHw {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ActionSet,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )

  # The goal of this transform is to automatically increase the resources given
  # a single-member load, if the host's hardware allows. When the configuration
  # is directed to ignore non-members, we can make no assumptions about what
  # host resources might already be spoken for.

  if ($ToolsetConfig.IgnoreNonMembers -eq 'true') {
    return
  }

  # My original intent was to permit auto-ConfigHw for 'Config' context
  # actionsets on the same basis as for 'Start' actionsets, but this is
  # unworkable, as a load may need only one member for configuration
  # (the default client, for example) but two or more members (e.g.
  # "Colors DC" for a trainer machine, "ClassServer 2016") at start.
  if ($actionSet.Context -ne "Start") {
    return
  }

  $presentMembers = @(
    $ActionSet.SelectNodes("Members/Member") |
      Where-Object Present -eq true
  )

  if ($presentMembers.Count -ne 1) {
    return
  }

  $configActions = @(
    $ActionSet.SelectNodes("Actions/Action") |
      Where-Object type -eq ConfigHwAction |
      Where-Object {
        $_.ProcessorCount -is [string] -or
        $_.MemoryBytes -is [string]
      }
  )

  # If any existing ConfigHw action *touches* processors or memory, automatic
  # configuration would be extraneous.
  if ($configActions.Count -ne 0) {
    return
  }

  # All host processor cores are available for assignment, as well as 1/2 host
  # RAM, if more than 8gb total is available. We don't want to "starve" the
  # host by leaving it with less than 4gb!
  $VMHost =
  Get-VMHost |
    ForEach-Object {
      [PSCustomObject]@{
        AvailableProcessors = $_.LogicalProcessorCount
        AvailableMemory = if ($_.MemoryCapacity -gt 8gb) {[System.Math]::Floor($_.MemoryCapacity / 2 / 1gb) * 1gb} else {$null}
      }
    }

  # Our final test involves comparing available resources to those used by the
  # snapshot that will be restored by the first action. If this snapshot was
  # already configured to invest all cores and 1/2 RAM, there's no need to
  # do so again.
  $snapshotProperties = Get-VMSnapshot -Id $ActionSet.SelectSingleNode("Actions/Action[1]/CheckpointMap/CheckpointMapItem").CheckpointId

  $ActionParams = @{
    Target = $presentMembers[0].Name
  }

  if ($snapshotProperties.ProcessorCount -lt $VMHost.AvailableProcessors) {
    $ActionParams.ProcessorCount = $VMHost.AvailableProcessors
  }
  if (
    $VMHost.AvailableMemory -ne $null -and
    ($snapshotProperties.DynamicMemoryEnabled -eq $true -or $snapshotProperties.MemoryStartup -lt $VMHost.AvailableMemory)
  ) {
    $ActionParams.MemoryBytes = $VMHost.AvailableMemory
  }

  # Snapshot already configured, *or* insufficient host resources.
  if ($ActionParams.Count -le 1) {
    return
  }

  Write-Verbose "Applying transform: Invest all host cores & 1/2 memory for only present load member."

  . $script:resources.ActionsConfigCommands

  $ActionSet |
    Add-StartVMAction @(
      act_configHw @ActionParams
    ) -Index 1 -PassThru |
    ForEach-Object {
      Resolve-StartVMActionsConfiguration_EachAction -Action $_
    }
}
function Invoke-StartVMActionsTransform_RunUpdateAsTest {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ActionSet,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )

  if ($ActionSet.Context -ne 'Update' -or (-not $RuntimeConfig.RunUpdateAsTest)) {
    return
  }

  Write-Verbose "Applying transform: Run 'Update' context actionset as 'Test'."

  . $script:resources.ActionsConfigCommands

  $ActionSet.Context = "UpdateTest"

  $ActionSet |
    Get-StartVMAction |
    Where-Object type -in @(
      "CleanAction"
      "ReplaceCheckpointAction"
    ) |
    Remove-StartVMAction

  $ActionSet |
    Add-StartVMAction @(
      act_takeCheckpoint "Update Test"
      act_start
      act_connect
    ) -PassThru |
    ForEach-Object {
      Resolve-StartVMActionsConfiguration_EachAction -Action $_
    }
}
function Invoke-StartVMActionsTransform_ApplyOffline {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ActionSet,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )

  if ($ToolsetConfig.Resources.ApplyMode -ne "Offline") {
    return
  }

  $usesResourceServer = @(
    $ActionSet.
      Actions.
      Action.
      Where({$_.Type -eq "InjectAction"}).
      Where({
        $_.UseResourceServer -eq "true" -or
        $_.SelectNodes("Packages/Package").Count -gt 0
      })
  ).Count -gt 0

  if (-not $usesResourceServer) {
    return
  }

  Write-Verbose "Applying transform: Apply resources to offline image before start."

  . $script:resources.ActionsConfigCommands

  while ($true) {
    $injectNode = $null
    $injectNodeIndex = -1

    foreach ($action in $ActionSet.SelectNodes("Actions/Action")) {
      $injectNodeIndex++

      if ($action.Type -ne "InjectAction") {
        continue
      }

      if ($action.UseResourceServer -eq "false" -and $action.SelectNodes("Packages/Package").Count -eq 0) {
        continue
      }

      if ($action.AddedApplyOfflineAction -eq "true") {
        continue
      }

      $injectNode = $action
    }

    if ($null -eq $injectNode) {
      break
    }

    # When populated, should be the index of the last Start action before the
    # Inject action for the same target.
    $startNodeIndex = $null

    $i = -1

    foreach ($action in $ActionSet.SelectNodes("Actions/Action")) {
      $i++

      if ($action.Type -ne "StartAction") {
        continue
      }

      if ($action.VMId -ne $injectNode.VMId) {
        continue
      }

      if ($i -ge $injectNodeIndex) {
        break
      }

      $startNodeIndex = $i
    }

    if ($null -eq $startNodeIndex) {
      throw "Failed to target 'start' corresponding to 'inject' action to insert apply offline action."
    }

    # When populated, should be the index of the last non-Start action (for any
    # target) before the index populated above.
    $nonStartNodeIndex = $null

    $i = -1

    foreach ($action in $ActionSet.SelectNodes("Actions/Action")) {
      $i++

      if ($action.Type -eq "StartAction") {
        continue
      }

      if ($i -ge $startNodeIndex) {
        break
      }

      $nonStartNodeIndex = $i
    }

    if ($null -eq $nonstartNodeIndex) {
      throw "Failed to target node before 'start' corresponding to 'inject' action to insert apply offline action."
    }

    $ActionParams = @{
      Target = $injectNode.Target
    }

    if ($injectNode.SelectNodes("Packages/Package").Count -gt 0) {
      $ActionParams.Packages = @($injectNode.SelectNodes("Packages/Package") | ForEach-Object InnerXml)
    }

    $ActionSet |
      Add-StartVMAction @(
        act_applyOffline @ActionParams
      ) -Index ($nonStartNodeIndex + 1) -PassThru |
      ForEach-Object {
        Resolve-StartVMActionsConfiguration_EachAction -Action $_
      }

    $injectNode.SetAttribute("AddedApplyOfflineAction", "true")
  }
}

function Stop-StartVMNonMembers {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ActionSet,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig
  )

  # Collecting necessary data.
  $ignoreList = @(
    $ToolsetConfig.SelectNodes("IgnoreList/IgnoreListItem") |
      ForEach-Object InnerXml
  )

  $memberIds = @(
    $ActionSet.SelectNodes("Members/Member") |
      Where-Object Present -eq true |
      ForEach-Object VMId
  )

  # Non-member vms that are running.
  $stopTargets = @(
    Get-VM |
      Where-Object State -ne Off |
      Where-Object Id -notin $memberIds
  )

  # Vms exempted from stop due to appearing in ignorelist.
  $ignoreListed = @(
    $stopTargets |
      Where-Object Name -in $ignoreList
  )

  $stopTargets = @(
    $stopTargets |
      Where-Object Name -notin $ignoreList
  )

  if ($ignoreListed.Count -gt 0) {
    Write-Warning "Per toolsetconfig ignorelist, ignoring $($ignoreListed.Count) running vm(s)."
  }

  # Vms exempted because "IgnoreNonMembers" is enabled.
  $ignoreNonMembered = @()
  if ($ToolsetConfig.IgnoreNonMembers -eq 'true') {
    $ignoreNonMembered = $stopTargets
    $stopTargets = @()
  }

  if ($ignoreNonMembered.Count -gt 0) {
    Write-Warning "Per toolsetconfig ignorenonmembers, ignoring $($ignoreNonMembered.Count) running vm(s)."
  }

  if ($stopTargets.Count -gt 0) {
    Write-Verbose "Stopping $($stopTargets.Count) running non-member vm(s)."
    $stopTargets |
      Stop-VM -TurnOff -Force -Confirm:$false
  }
}
#endregion

#region Actions orchestration
function Invoke-StartVMAction_RestoreCheckpoint {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $context = $Action.SelectSingleNode("../..").Context

    $items = $Action.SelectNodes("CheckpointMap/CheckpointMapItem")

    foreach ($item in $items) {
      $vm = Get-VM -Id $item.VMId

      if ($vm.State -ne "Off") {
        $vm |
          Stop-VM -TurnOff -Force
      }

      Get-VMSnapshot -Id $item.CheckpointId |
        Restore-VMSnapshot -Confirm:$false

      # A "clean" action will use the ParentSnapshotId property to ensure
      # the top checkpoint is applied before it proceeds. I've seen some
      # errors from this failsafe that likely indicate the property has
      # not updated in time, hence this manual check.
      do {
        Start-Sleep -Milliseconds 250
      } until ((Get-VM -Id $vm.Id).ParentSnapshotId -eq $item.CheckpointId)
    }

    if ($context -ne "Restore") {
      return
    }

    Write-Verbose "  - Deleting mid-class checkpoint(s) and waiting for vhd merge."

    foreach ($item in $items) {

      $snapshot = Get-VMSnapshot -Id $item.CheckpointId

      # For reasons unknown, trying to pipe directly to this cmdlet from
      # Get-VMSnapshot writes an obscure error.
      Remove-VMSnapshot -VMSnapshot $snapshot -Confirm:$false

      do {
        Start-Sleep -Seconds 1
      } until ((Get-VM -Id $item.VMId).Status -eq "Operating normally")
    }
  }
}
function Invoke-StartVMAction_Clean {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -ne "Off") {
      throw "This action requires the vm be in an 'Off' state."
    }

    $currentCheckpoint = Get-VMSnapshot -Id $vm.ParentSnapshotId

    if ($currentCheckpoint.ParentSnapshotId -ne $null) {
      throw "This action requires the vm first be reverted to its top checkpoint."
    }

    $vm |
      Get-VMSnapshot |
      Where-Object ParentSnapshotId -eq $currentCheckpoint.Id |
      Remove-VMSnapshot -IncludeAllChildSnapshots
  }
}

function Invoke-StartVMAction_ConfigHw {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    $setParams = @{}

    if ($null -ne $Action.ProcessorCount) {
      $setParams.ProcessorCount = $Action.ProcessorCount
    }

    if ($null -ne $Action.MemoryBytes) {
      $setParams.StaticMemory = $true
      $setParams.MemoryStartupBytes = $Action.MemoryBytes
    }

    if ($setParams.Count -gt 0) {
      $vm |
        Set-VM @setParams
    }

    if ($null -ne $Action.NetworkAdapters) {
      $vm |
        Get-VMNetworkAdapter |
        Remove-VMNetworkAdapter

      $adapters = @(
        $Action.SelectNodes("NetworkAdapters/NetworkAdapter") |
          ForEach-Object InnerXml
      )

      foreach ($adapter in $adapters) {
        $params = @{}

        if ($adapter -ne 'none') {
          $params.SwitchName = $adapter
        }

        $vm |
          Add-VMNetworkAdapter @params
      }
    }
  }
}
function Invoke-StartVMAction_Custom {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -ne "Off") {
      throw "This action requires the vm be in an 'Off' state."
    }

    if ($Action.OfflineServicing -eq 'true') {

      $vhdPath = $vm |
                   Get-VMHardDiskDrive |
                   Select-Object -First 1 |
                   ForEach-Object Path

      $partition = Mount-VHD -Path $vhdPath -Passthru |
                     Get-Partition |
                     Where-Object Size -gt 1gb

      $volumeRoot = $partition |
                      ForEach-Object {$_.DriveLetter + ":\"}

      do {
        Start-Sleep -Milliseconds 250
      } until ((Get-PSDrive | Where-Object Root -eq $volumeRoot) -ne $null)

      $ImageRootName = "VHD" # Set to 'IMG' for direct transferral of code to Offline Servicing scripts.
      $ImageRoot = $volumeRoot

      function New-PSDriveObj ($Name, $PSProvider, $Root, $Description) {
        [PSCustomObject]@{
          Name        = $Name
          PSProvider  = $PSProvider
          Root        = $Root
          Description = $Description
        }
      }

      $drives = @(
        New-PSDriveObj -Name $ImageRootName `
                       -PSProvider FileSystem `
                       -Root $ImageRoot `
                       -Description "FileSystem Root"

        New-PSDriveObj -Name "$($ImageRootName)_REG_SYS" `
                       -PSProvider Registry `
                       -Root (Join-Path -Path $ImageRoot -ChildPath Windows\System32\config\SYSTEM) `
                       -Description "System Registry"
        
        New-PSDriveObj -Name "$($ImageRootName)_REG_SW" `
                       -PSProvider Registry `
                       -Root (Join-Path -Path $ImageRoot -ChildPath Windows\System32\config\SOFTWARE) `
                       -Description "Software Registry"
        
        New-PSDriveObj -Name "$($ImageRootName)_REG_DEF" `
                       -PSProvider Registry `
                       -Root (Join-Path -Path $ImageRoot -ChildPath Users\Default\NTUSER.DAT) `
                       -Description "Default Profile Registry"
        
        New-PSDriveObj -Name "$($ImageRootName)_REG_DEF_CLS" `
                       -PSProvider Registry `
                       -Root (Join-Path -Path $ImageRoot -ChildPath Users\Default\AppData\Local\Microsoft\Windows\UsrClass.dat) `
                       -Description "Default Profile Classes Registry"
      )

      foreach ($drive in $drives) {
        if (-not (Test-Path -LiteralPath $drive.Root)) {
          continue
        }
      
        if ($drive.PSProvider -eq "Registry") {
          & reg load "HKLM\$($drive.Name)" $drive.Root |
            Out-Null
      
          $drive.Root = "HKLM:\$($drive.Name)"
        }
      
        New-PSDrive -Name $drive.Name `
                    -PSProvider $drive.PSProvider `
                    -Root $drive.Root `
                    -Description $drive.Description |
          Out-Null
      }
    }

    $pl = $Host.Runspace.CreateNestedPipeline()
    $cmd = [System.Management.Automation.Runspaces.Command]::new('param($VM)', $true)
    $cmd.Parameters.Add(
      [System.Management.Automation.Runspaces.CommandParameter]::new(
        'VM',
        $vm
      )
    )
    $pl.Commands.Add($cmd)
    $pl.Commands.AddScript($Action.Script)
    $pl.Invoke() | Out-Null

    if ($Action.OfflineServicing -eq 'true') {
      # Mandatory before registry unload.
      [System.GC]::Collect()
      
      foreach ($drive in $drives) {
        if ((Get-PSDrive | where-Object Name -eq $drive.Name) -eq $null) {
          continue
        }
      
        Remove-PSDrive -Name $drive.Name
      
        if ($drive.PSProvider -eq "Registry") {
          & reg unload "HKLM\$($drive.Name)" |
            Out-Null
        }
      }

      Dismount-VHD -Path $vhdPath
    }
  }
}

function Invoke-StartVMAction_Start {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    $context = $Action.SelectSingleNode("../..").Context

    $goodStates = @("Off")

    if ($context -eq "Restore") {
      $goodStates += "Saved"
    }

    if ($vm.State -notin $goodStates) {
      throw "This action requires the vm be in an 'Off' state, *or* 'Saved' for actionset context 'Restore'."
    }

    $vm |
      Start-VM

    if ($Action.WaitForHeartbeat -ne 'true') {
      return
    }

    Write-Verbose "  - Waiting for heartbeat."

    do {
      Start-Sleep -Seconds 60

      $vmHeartbeat = $vm |
                       Get-VM |
                       ForEach-Object {$_.Heartbeat.ToString().Substring(0, 2)}
    } until ($vmHeartbeat -ceq "Ok")
  }
}

function Invoke-StartVMAction_Inject {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -ne "Running") {
      throw "This action requires the vm be in a 'Running' state."
    }

    $credential = [System.Management.Automation.PSCredential]::new(
      "$($Action.Credential.Domain)\$($Action.Credential.UserName)",
      (ConvertTo-SecureString -String $Action.Credential.Password -AsPlainText -Force)
    )

    Write-Verbose "  - Validating powershell direct manageability."

    $shout = {"The mountains are singing, and the lady comes."}
    $startTime = Get-Date

    do {
      $echo = Invoke-Command -VMId $vm.Id -Credential $credential -ScriptBlock $shout -ErrorAction Ignore
    } until ($echo -eq $shout.Invoke() -or ((Get-Date) - $startTime).TotalMinutes -ge 5)

    if ($echo -ne $shout.Invoke()) {
      throw "Unable to validate powershell direct manageability within the five minute timeout."
    }

    $session = New-PSSession -VMId $vm.Id -Credential $credential

    $injectParams = @{}
    if ($Action.UsePhysHostName -eq 'true') {
      $injectParams.PhysHostName = $RuntimeConfig.PhysHostName
    }

    if ($Action.UseResourceServer -eq 'true' -and $ToolsetConfig.Resources.ApplyMode -eq "Online") {
      $injectParams.ResourceServer = $RuntimeConfig.ResourceServer
    }

    if ($injectParams.Count -gt 0) {
      Invoke-Command -Session $session -ScriptBlock {param($params)} -ArgumentList $injectParams |
        Out-Null
    }

    Invoke-Command -Session $session -ScriptBlock {
      $ProgressPreference = "SilentlyContinue"
      $WarningPreference  = "SilentlyContinue"
    } |
      Out-Null

    if ($Action.UseResourceServer -eq 'true') {
      Invoke-Command -Session $session -ScriptBlock $resources.InjectScripts.InitLocalPaths |
        Out-Null

      if ($ToolsetConfig.Resources.ApplyMode -eq "Online") {
        Write-Verbose "  - Initializing modules and package source in vm session."
        Invoke-Command -Session $session -ScriptBlock $resources.InjectScripts.InitOnlineResources |
          Out-Null

        Write-Verbose "  - Copying package content from remote source."
        $Action.SelectNodes("Packages/Package") |
          ForEach-Object InnerXml |
          ForEach-Object {
            Invoke-Command -Session $session -ScriptBlock {
              Find-CTPackage $args[0] -Source Remote |
                Copy-CTPackage
            } -ArgumentList $_ |
              Out-Null
          }
      } elseif ($ToolsetConfig.Resources.ApplyMode -eq "Offline") {
        Write-Verbose "  - Initializing modules and package source in vm session."
        Invoke-Command -Session $session -ScriptBlock $resources.InjectScripts.InitOfflineResources |
          Out-Null
      }
    }

    $context = $Action.SelectSingleNode("../..").Context

    if ($context -in "Start","Custom") {
      Invoke-Command -Session $session -ScriptBlock $resources.InjectScripts.RunAsUser | 
        Out-Null
    }

    Write-Verbose "  - Injecting configuration script."
    $script = [scriptblock]::Create($Action.Script)
    Invoke-Command -Session $session -ScriptBlock $script |
      Out-Null

    Remove-PSSession -Session $session

    if ($Action.WaitForKvp -eq 'true') {
      Write-Verbose "  - Waiting for configuration to finish."
      Start-KvpFinAckHandshake -VMId $vm.Id
    }
  }
}

function Invoke-StartVMAction_Wait {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    Start-Sleep -Seconds $Action.Seconds
  }
}

function Invoke-StartVMAction_ConfigRdp {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $configPath = [System.Environment]::GetFolderPath("ApplicationData") |
                    Join-Path -ChildPath Microsoft\Windows\Hyper-V\Client\1.0 |
                    Join-Path -ChildPath "vmconnect.rdp.$($action.VMId).config"

    if ($Action.Clear -eq 'true' -and (Test-Path -LiteralPath $configPath)) {
      Remove-Item -LiteralPath $configPath -Force
    }

    if ($Action.Config -ne 'true') {
      return
    }

    $xml = [System.Xml.XmlDocument]::new()

    $xml.AppendChild(
      $xml.CreateXmlDeclaration("1.0", "utf-8", $null)
    ) | Out-Null

    $optionsNode = $xml.AppendChild(
      $xml.CreateElement("configuration")
    ).AppendChild(
      $xml.CreateElement("Microsoft.Virtualization.Client.RdpOptions")
    )

    function Add-Setting {
      [CmdletBinding(
        PositionalBinding = $false
      )]
      param(
        [Parameter(
          Mandatory = $true,
          ValueFromPipeline = $true
        )]
        [System.Xml.XmlElement]
        $OptionsNode,

        [Parameter(
          Mandatory = $true
        )]
        [string]
        $Name,

        $Value = '',

        [string]
        $Type
      )

      $SettingNode = $OptionsNode.AppendChild(
        $OptionsNode.
        OwnerDocument.
        CreateElement("setting")
      )

      if ($Type.Length -eq 0) {
        $Type = $Value.GetType().FullName
      }

      $SettingNode.SetAttribute("name", $Name)
      $SettingNode.SetAttribute("type", $Type)

      $SettingNode.AppendChild(
        $OptionsNode.
        OwnerDocument.
        CreateElement("value")
      ).InnerText = [string]$Value
    }

    Add-Type -AssemblyName System.Windows.Forms
    $screenSize = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize

    $redirectAudioMap = @{
      true  = "AUDIO_MODE_REDIRECT"
      false = "AUDIO_MODE_NONE"
    }

    $optionsNode |
      Add-Setting -Name SavedConfigExists `
                  -Value $true
    $optionsNode |
      Add-Setting -Name AudioCaptureRedirectionMode `
                  -Value ($Action.RedirectMicrophone -eq "true")
    $optionsNode |
      Add-Setting -Name SaveButtonChecked `
                  -Value $true
    $optionsNode |
      Add-Setting -Name FullScreen `
                  -Value $false
    $optionsNode |
      Add-Setting -Name SmartCardsRedirection `
                  -Value $false
    $optionsNode |
      Add-Setting -Name RedirectedPnpDevices
    $optionsNode |
      Add-Setting -Name ClipboardRedirection `
                  -Value $false
    $optionsNode |
      Add-Setting -Name DesktopSize `
                  -Value ($screenSize.Width,$screenSize.Height -join ", ") `
                  -Type System.Drawing.Size
    $optionsNode |
      Add-Setting -Name VmServerName `
                  -Value ([System.Net.Dns]::GetHostName())
    $optionsNode |
      Add-Setting -Name RedirectedUsbDevices
    $optionsNode |
      Add-Setting -Name UseAllMonitors `
                  -Value $false
    $optionsNode |
      Add-Setting -Name AudioPlaybackRedirectionMode `
                  -Value $redirectAudioMap.($Action.RedirectAudio) `
                  -Type Microsoft.Virtualization.Client.RdpOptions+AudioPlaybackRedirectionType
    $optionsNode |
      Add-Setting -Name PrinterRedirection `
                  -Value $false
    $optionsNode |
      Add-Setting -Name RedirectedDrives
    $optionsNode |
      Add-Setting -Name VmName `
                  -Value $Action.VMName

    New-Item -Path $configPath -ItemType File -Value $xml.OuterXml -Force |
      Out-Null
  }
}

function Invoke-StartVMAction_Connect {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -ne "Running") {
      throw "This action requires the vm be in a 'Running' state."
    }

    Start-CTVMConnect -MaximizedVM $vm
  }
}

function Invoke-StartVMAction_Stop {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -ne "Running") {
      throw "This action requires the vm be in a 'Running' state."
    }

    $vm |
      Stop-VM -Force

    while ((Get-VM -Id $vm.Id).State -ne "Off") {
      Start-Sleep -Seconds 5
    }
  }
}
function Invoke-StartVMAction_SaveIfNeeded {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -eq "Off") {
      Write-Verbose "  - Skipped, as vm is already 'Off'."
      return
    }

    if ($vm.State -ne "Running") {
      throw "This action requires the vm be in an 'Off' or 'Running' state."
    }

    $vm |
      Stop-VM -Save -Force

    while ((Get-VM -Id $vm.Id).State -ne "Saved") {
      Start-Sleep -Seconds 5
    }
  }
}
function Invoke-StartVMAction_TakeCheckpoint {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vms = @(
      $Action.SelectNodes("../../Members/Member") |
        Where-Object Present -eq true |
        ForEach-Object {
          Get-VM -Id $_.VMId
        }
    )

    $context = $Action.SelectSingleNode("../..").Context

    $goodStates = @("Off")

    if ($context -eq "Save") {
      $goodStates += "Saved"
    }

    $badStates = @(
      $vms |
        ForEach-Object State |
        Sort-Object -Unique |
        Where-Object {$_ -notin $goodStates}
    )

    if ($badStates.Count -ne 0) {
      throw "This action requires all present member vms be in an 'Off' state, *or* 'Saved' for actionset context 'Save'."
    }

    foreach ($vm in $vms) {
      $snapshotsToRemove = @(
        $vm |
          Get-VMSnapshot |
          Where-Object Name -eq $Action.CheckpointName
      )

      # The value is filtered down in this manner to support having a "Restore"
      # context RestoreCheckpoint action preferentially restore the "Mid-Class
      # Configuration" checkpoint beneath the "Class-Ready Configuration"
      # identified by CheckpointName. In this case, having more than one
      # checkpoint for a vm with the same name is not a bad thing, so
      # long as no more than one is below each "Class-Ready Configuration".
      if ($Action.CheckpointName -eq "Mid-Class Configuration") {
        $snapshotsToRemove = @(
          $snapshotsToRemove |
            Where-Object ParentSnapshotId -eq $vm.ParentSnapshotId
        )
      }

      $snapshotsToRemove |
        Remove-VMSnapshot -Confirm:$false

      $vm |
        Checkpoint-VM -SnapshotName $Action.CheckpointName
    }
  }
}

function Invoke-StartVMAction_ReplaceCheckpoint {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -ne "Off") {
      throw "This action requires the vm be in an 'Off' state."
    }

    $currentCheckpoint = Get-VMSnapshot -Id $vm.ParentSnapshotId

    if ($currentCheckpoint.ParentSnapshotId -ne $null) {
      throw "This action requires the vm first be reverted to its top checkpoint."
    }

    $vm |
      Checkpoint-VM -SnapshotName "Known Good Configuration"

    Write-Verbose "  - Deleting existing top checkpoint and waiting for vhd merge."

    Remove-VMSnapshot -VMSnapshot $currentCheckpoint -Confirm:$false

    do {
      Start-Sleep -Seconds 1
    } until ((Get-VM -Id $vm.Id).Status -eq "Operating normally")
  }
}

function Invoke-StartVMAction_ApplyOffline {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -ne "Off") {
      throw "This action requires the vm be in an 'Off' state."
    }

    $vhdPath = $vm |
                 Get-VMHardDiskDrive |
                 Select-Object -First 1 |
                 ForEach-Object Path

    $partition = Mount-VHD -Path $vhdPath -Passthru |
                   Get-Partition |
                   Where-Object Size -gt 1gb

    $volumeRoot = $partition |
                    ForEach-Object {$_.DriveLetter + ":\"}

    do {
      Start-Sleep -Milliseconds 250
    } until ((Get-PSDrive | Where-Object Root -eq $volumeRoot) -ne $null)

    $vhdPaths = @{
      CTRoot = Join-Path -Path $volumeRoot -ChildPath CT
    }
    $vhdPaths.Modules = Join-Path -Path $vhdPaths.CTRoot -ChildPath Modules
    $vhdPaths.Packages = Join-Path -Path $vhdPaths.CTRoot -ChildPath Packages

    if (Test-Path -LiteralPath $vhdPaths.CTRoot) {
      throw "The resource destination path already exists @ '$($vhdPaths.CTRoot)' on the vhd. Any successful configuration should have removed this path."
    }

    New-Item -Path $vhdPaths.Modules -ItemType Directory -Force |
      Out-Null

    "Common",
    "CTPackage" |
      ForEach-Object {
        Copy-Item -LiteralPath (Join-Path -Path $ToolsetConfig.Resources.Offline.ModulesSourcePath -ChildPath $_) -Destination $vhdPaths.Modules -Recurse
      }

    $packages = @(
      $Action.SelectNodes("Packages/Package") |
        ForEach-Object InnerXml
    )

    if ($packages.Count -gt 0) {
      New-Item -Path $vhdPaths.Packages -ItemType Directory |
        Out-Null

      $packages |
        ForEach-Object {
          Copy-Item -LiteralPath (Join-Path -Path $ToolsetConfig.Resources.Offline.PackagesSourcePath -ChildPath $_) -Destination $vhdPaths.Packages -Recurse
        }
    }

    Dismount-VHD -Path $vhdPath
  }
}

function Invoke-StartVMAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $Action,

    [Parameter(
      Mandatory = $true
    )]
    [System.Xml.XmlElement]
    $ToolsetConfig,

    [Parameter(
      Mandatory = $true
    )]
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    try {
      $type = $Action.type -replace "Action$",""

      $msgAug = [string]::Empty
      if ($Action.Target -is [string]) {
        $msgAug = " with '$($Action.VMName)'"
      }

      Write-Verbose "Invoking action '$type'$msgAug."
      $Action |
        & "Invoke-StartVMAction_$type" -ToolsetConfig $ToolsetConfig -RuntimeConfig $RuntimeConfig -ErrorAction Stop
    } catch {
      $PSCmdlet.ThrowTerminatingError($_)
    }
  }
}
#endregion

function Get-StartVMActionsConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [String]
    $ConfigurationRoot,

    [Parameter(
      Mandatory = $true
    )]
    [String]
    $ConfigurationName
  )
  try {
    Write-Verbose "Retrieving actions configuration from file w/ basename '$ConfigurationName'."

    $configItem = @(
      Get-ChildItem -LiteralPath $ConfigurationRoot -File -Recurse |
        Where-Object Extension -in .ps1,.xml |
        Where-Object BaseName -eq $ConfigurationName
    )

    if ($configItem.Count -eq 0) {
      $exception = [System.Exception]::new("Named configuration not found in the configuration root or a subfolder thereof.")
      $exception.Data.Add("Name", $Name)

      throw $exception
    }

    if ($configItem.Count -gt 1) {
      $exception = [System.Exception]::new("Named configuration exists at multiple locations within the configuration root.")
      $exception.Data.Add("Name", $Name)
      $exception.Data.Add("Path1", $configItem[0].DirectoryName)
      $exception.Data.Add("Path2", $configItem[1].DirectoryName)

      throw $exception
    }

    if ($configItem[0].Extension -eq '.ps1') {
      $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
      $rs.Open()

      $rs.CreatePipeline($script:resources.ActionsConfigCommands).Invoke() | Out-Null
      $rs.CreatePipeline('$config = New-StartVMConfiguration').Invoke() | Out-Null
    
      try {
        $rs.CreatePipeline((Get-Content -LiteralPath $configItem[0].FullName -Raw)).Invoke() | Out-Null
      } catch {
        $exception = [System.Exception]::new(
          "Error while processing actions config definition file.",
          $_.Exception
        )

        throw $exception
      }

      $config = $rs.CreatePipeline('$config').Invoke()[0]
      $rs.Close()
    }
    elseif ($configItem[0].Extension -eq '.xml') {
      try {
        $config = ([xml](Get-Content -LiteralPath $configItem[0].FullName -Raw)).SelectSingleNode("/Configuration")
      } catch {
        $exception = [System.Exception]::new(
          "Error while processing actions config definition file.",
          $_.Exception
        )

        throw $exception
      }
    }

    if ($config -isnot [System.Xml.XmlElement]) {
      throw "Error while retrieving actions config definition. Object retrieved was not an XmlElement."
    }

    $nameNode = $config.SelectSingleNode("/Configuration/Name")

    if ($nameNode -isnot [System.Xml.XmlElement]) {
      throw "Error while retrieving actions config definition. Could not select element node for Name assignment."
    }

    $nameNode.InnerXml = $configItem.BaseName

    Write-Verbose "Validating actions configuration to schema."
    $TestXml = $config.OwnerDocument.OuterXml -as [xml]
    $TestXml.Schemas.Add($script:resources.ActionsConfigSchema) |
      Out-Null
    try {
      $TestXml.Validate($null)
    } catch {
      $exception = [System.Exception]::new(
        "Error while validating actions config to schema. $($_.Exception.InnerException.Message)",
        $_.Exception
      )

      throw $exception
    }

    $config
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}
function Invoke-StartVM {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [String]
    $ConfigurationRoot,

    [Parameter(
      Mandatory = $true
    )]
    [String]
    $ConfigurationName,

    [Parameter(
      Mandatory = $true
    )]
    [String]
    $ToolsetConfigPath,

    [ValidateSet(
      "Config",
      "Start",
      "Test",
      "Save",
      "Restore",
      "Update",
      "Custom"
    )]
    [String]
    $Context
  )
  $resultObj = [PSCustomObject]@{
    "Configuration Name"             = $null
    "Toolset Configuration"          = $null
    "Raw Actions Configuration"      = $null
    "Context"                        = $null
    "Runtime Configuration"          = $null
    "Resolved Actions Configuration" = $null
    "Processing Status"              = "Initial"
    "Start Time"                     = [datetime]::Now
    "End Time"                       = $null
    "Duration"                       = $null
    "Error Record"                   = $null
  }

  try {
    $resultObj."Processing Status" = "Retrieving & validating toolset configuration."

    $ToolsetConfig = 
    Get-StartVMToolsetConfiguration `
    -ToolsetConfigPath $ToolsetConfigPath

    $resultObj."Toolset Configuration" = $ToolsetConfig

    $resultObj."Processing Status" = "Retrieving actions configuration and validating to schema."

    $ActionsConfig = 
    Get-StartVMActionsConfiguration `
    -ConfigurationRoot $ConfigurationRoot `
    -ConfigurationName $ConfigurationName

    # Two separate means of determining the toolset is hosted on an external
    # drive, just so there's no mistake before we create the root shortcut
    # and auto-eject.
    if (@(Get-Module DismountToolsetDrive).Count -gt 0 -and $PSScriptRoot -like "[D-Z]:\src\ps1\inc\*") {
      Set-StartVMRootShortcut -Configuration $ActionsConfig

      if ($ToolsetConfig.AutoEject -eq "true") {
        Dismount-ToolsetDrive
      }
    }

    $resultObj."Raw Actions Configuration" = $ActionsConfig
    $resultObj."Configuration Name" = $ActionsConfig.Name

    # The way in which we resolve the toolset configuration depends in part
    # on the schema-validated content of the chosen actionset, which means
    # we must select/validate our actionset before resolution happens.
    $resultObj."Processing Status" = "Selecting or validating actionset context."

    $Context = Select-StartVMActionSetContext `
    -Configuration $ActionsConfig `
    -Context $Context

    $resultObj.Context = $Context

    $RuntimeConfig = [PSCustomObject]@{
      DisallowedMemberNames = $null
      DefaultMemberName     = $null
      RunUpdateAsTest       = $null
      PhysHostName          = $null
      ResourceServer        = $null
    }

    $resultObj."Processing Status" = "Resolving configuration resources from runtime environment."

    Resolve-StartVMRuntimeConfiguration `
    -ActionsConfig $ActionsConfig `
    -Context $Context `
    -ToolsetConfig $ToolsetConfig `
    -RuntimeConfig $RuntimeConfig

    $resultObj."Runtime Configuration" = $RuntimeConfig

    $resultObj."Processing Status" = "Validating actions configuration structure and consistency."

    $ActionsConfig = Test-StartVMActionsConfiguration -ActionsConfig $ActionsConfig

    $resultObj."Processing Status" = "Resolving actionset against available resources."

    $ActionSet =
    Resolve-StartVMActionsConfiguration `
    -ActionsConfig $ActionsConfig `
    -Context $Context `
    -RuntimeConfig $RuntimeConfig

    $resultObj."Processing Status" = "Evaluating & applying special actionset transformations."

    # These functions test eligibility for these transformations before
    # applying them. If eligibility is not established, control is
    # simply returned to the caller.
    Invoke-StartVMActionsTransform_AutoConfigHw    -ActionSet $ActionSet -ToolsetConfig $ToolsetConfig -RuntimeConfig $RuntimeConfig
    Invoke-StartVMActionsTransform_RunUpdateAsTest -ActionSet $ActionSet -ToolsetConfig $ToolsetConfig -RuntimeConfig $RuntimeConfig
    Invoke-StartVMActionsTransform_ApplyOffline    -ActionSet $ActionSet -ToolsetConfig $ToolsetConfig -RuntimeConfig $RuntimeConfig

    $resultObj."Resolved Actions Configuration" = $ActionSet

    # Criteria: Must be in a path automatically created where the Hyper-V role
    # is enabled/installed, readable/writable by Hyper-V Administrators.
    $PersistentDataPath = "C:\Users\Public\Documents\Hyper-V\StartVMTools.PersistentData.xml"

    # PersistentData is retrieved, validated on its own merits, and used for
    # its intended purpose (to limit circumstances in which a Save-context
    # actionset may be run) all within this function. It needs only the
    # path to the data and the current configuration name and actionset
    # context to do so, and thus *could* be placed far earlier. When
    # run, however, it will in many circumstances delete persistent
    # data after retrieving it, and thus should be placed after
    # any juncture where failure may be expected.
    Read-StartVMPersistentData `
    -Path $PersistentDataPath `
    -ConfigurationName $ActionsConfig.Name `
    -ActionSetContext $Context

    $resultObj."Processing Status" = "Preparing vm host for configuration start."

    Stop-StartVMNonMembers -ActionSet $ActionSet -ToolsetConfig $ToolsetConfig

    Write-Verbose "Stopping vm-related apps and managing enhanced session mode."
    $resetParams = @{}
    if ($ActionSet.UseEnhancedSessionMode -eq 'true') {
      $resetParams.SetEnhancedSessionMode = "Enabled"
    }
    Reset-CTVMHost @resetParams

    $resultObj."Processing Status" = "Orchestrating actions."

    $ActionSet.SelectNodes("Actions/Action") |
      Invoke-StartVMAction -ToolsetConfig $ToolsetConfig -RuntimeConfig $RuntimeConfig

    Write-StartVMPersistentData `
    -Path $PersistentDataPath `
    -ConfigurationName $ActionsConfig.Name `
    -ActionSetContext $Context

    $resultObj."End Time" = [datetime]::Now
    $resultObj."Duration" = $resultObj."End Time" - $resultObj."Start Time"
    $resultObj."Processing Status" = "Complete"
  } catch {
    $resultObj."Error Record" = $_
  }
  $resultObj
}

Export-ModuleMember -Function Get-StartVMActionsConfiguration,
                              Invoke-StartVM