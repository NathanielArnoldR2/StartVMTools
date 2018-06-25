<#

@TODO: Remove direct child Members node from Configuration node.

The frequency with which members and member properties (Optional, Credentials)
shift per-actionset within a single configuration renders the configuration-
level "Members" node less useful, particularly as no more than 2 or 3 separate
actionsets will ever share the same configuration.

@TODO: Shift credential inheritance from Validity to Readiness.

For conceptual and practical reasons, credential inheritance is better placed
in Readiness than Validity steps.

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

$credPath = "$PSScriptRoot\StartVMTools.FallbackCredentials.ps1"

$resources.FallbackCredentials = @()
if (Test-Path -LiteralPath $credPath) {
  $resources.FallbackCredentials = @(
    & $credPath
  )
}

$resources.RuleEvaluator = [scriptblock]::Create(
  (Get-Content -LiteralPath $PSScriptRoot\StartVMTools.RuleEvaluator.ps1 -Raw)
)

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
$resources.InjectScripts.InitResources = {

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

  if (Test-Path -LiteralPath C:\CT) {
    throw "The resource destination path already exists @ 'C:\CT' on the vm. Any successful configuration should have removed this path."
  }

  $localPaths = @{
    Modules  = "C:\CT\Modules"
    Packages = "C:\CT\Packages"
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

$preferLocalPackages = %PREFERLOCALPACKAGES%

if ($modules -contains "CTPackage" -and $preferLocalPackages) {
  Add-CTPackageSource -Name Local  -Path "%PACKAGELOCAL%"
  Add-CTPackageSource -Name Remote -Path "%PACKAGESHARE%"
}
elseif ($modules -contains "CTPackage") {
  Add-CTPackageSource -Name Remote -Path "%PACKAGESHARE%"
  Add-CTPackageSource -Name Local  -Path "%PACKAGELOCAL%"
}

}.ToString().
  Trim().
  Replace("%PREFERLOCALPACKAGES%", "`$$($params.PreferLocalPackages.ToString().ToLower())").
  Replace("%PACKAGELOCAL%", $localPaths.Packages).
  Replace("%PACKAGESHARE%", $sharePaths.Packages)

  $importPath = New-Item -Path $localPaths.Modules -Name import.ps1 -Value $importScript |
                  ForEach-Object FullName

  . $importPath

  if ($Error.Count -gt 0) {
    throw "Terminating due to unexpected error."
  }
}
$resources.InjectScripts.RunAsUser = {

  function Register-ConfigTaskInUserSession {
    param(
      [Parameter(
        Mandatory = $true
      )]
      [scriptblock]
      $Task
    )

    $encodedCommand = [Convert]::ToBase64String(
      [System.Text.Encoding]::Unicode.GetBytes($Task.ToString())
    )

    $params = @{
      TaskName  = "Start"
      Principal = New-ScheduledTaskPrincipal   -GroupId BUILTIN\Users
      Action    = New-ScheduledTaskAction      -Execute "C:\Windows\System32\WindowsPowershell\v1.0\powershell.exe" -Argument "/EncodedCommand $encodedCommand"
      Settings  = New-ScheduledTaskSettingsSet -Priority 4 # 4 is Normal Priority. Default of 7 is Below Normal.
      Trigger   = New-ScheduledTaskTrigger     -At (Get-Date).AddMinutes(2) -Once # Long enough to be sure user has (auto) signed in.
    }

    Register-ScheduledTask @params |
      Out-Null
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

    $rs.CreatePipeline('$config = @{}').Invoke() | Out-Null

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
    "Update"
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
      "Would you like to run a test of this 'Update' configuration that will not overwrite the current top checkpoint",
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

  if ($usesResourceServer) {
    Write-Verbose "  - Selecting and validating resource server for modules and packages."

    $serverOptions = $ToolsetConfig.SelectNodes("ResourceServerOptions/ResourceServerOption") |
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

    if ($ToolsetConfig.TestResourceShares -eq 'false') {
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
          Write-Verbose "    - HINT: Try running with toolsetconfig testresourceshares set to '`$false'!"
          $showedHint = $true
        }

        if (((Get-Date) - $startTime).TotalHours -ge 1) {
          throw "Failed to establish simultaneous presence of all resource shares within an hour."
        }

        Start-Sleep -Seconds 60
      }
    }

    $RuntimeConfig.ResourceServer = $server
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

    if ($item.CheckpointName.Length -eq 0) {
      $msgAug = "top"

      $targetSnapshot = @(
        $vmSnapshots |
          Where-Object ParentSnapshotId -eq $null
      )
    }
    elseif ($context -eq "Start") {
      $msgAug = "'$($item.CheckpointName)'"

      $snapshotName = "Class-Ready Configuration ($($item.CheckpointName))"

      $targetSnapshot = @(
        $vmSnapshots |
          Where-Object Name -eq $snapshotName
      )
    }

    if ($targetSnapshot.Count -ne 1) {
      throw "Expected to find exactly one checkpoint matching specification ($msgAug) for member '$($member.Name)', but found $($targetSnapshot.Count)."
    }

    $item.SetAttribute("VMId", $member.VMId)
    $item.SetAttribute("CheckpointId", $targetSnapshot[0].Id)
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

  if ($null -eq $Action.Credential) {
    throw "No credential was provided for this action, and none could not be derived from the actionset, configuration, or fallback credential store."
  }
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

  foreach ($adapter in $Action.SelectNodes("NetworkAdapters/NetworkAdapter")) {
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
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $items = $Action.SelectNodes("CheckpointMap/CheckpointMapItem")

    foreach ($item in $items) {
      $vm = Get-VM -Id $item.VMId

      if ($vm.State -ne "Off") {
        $vm |
          Stop-VM -TurnOff -Force
      }

      Get-VMSnapshot -Id $item.CheckpointId |
        Restore-VMSnapshot -Confirm:$false
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
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -ne "Off") {
      throw "This action requires the vm be in an 'Off' state."
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
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -ne "Running") {
      throw "This action requires the vm be in a 'Running' state."
    }

    $credential = [System.Management.Automation.PSCredential]::new(
      $Action.Credential.UserName,
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
    if ($Action.UseResourceServer -eq 'true') {
      $injectParams.PreferLocalPackages = $Action.SelectNodes("Packages/Package").Count -gt 0
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
      Write-Verbose "  - Initializing modules and package source in vm session."
      Invoke-Command -Session $session -ScriptBlock $resources.InjectScripts.InitResources |
        Out-Null
    }

    $context = $Action.SelectSingleNode("../..").Context

    if ($context -eq "Start") {
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
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
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

    $state = @(
      $vms |
        ForEach-Object State |
        Sort-Object -Unique
    )

    if ($state.Count -ne 1 -or $state[0] -ne "Off") {
      throw "This action requires all present member vms be in an 'Off' state."
    }

    foreach ($vm in $vms) {
      $vm |
        Get-VMSnapshot |
        Where-Object Name -eq $Action.CheckpointName |
        Remove-VMSnapshot -Confirm:$false

      $vm |
        Checkpoint-VM -SnapshotName $Action.CheckpointName
    }
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
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
    $vm = Get-VM -Id $Action.VMId

    if ($vm.State -ne "Running") {
      throw "This action requires the vm be in a 'Running' state."
    }

    Start-CTVMConnect -VM $vm
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
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
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
    [PSCustomObject]
    $RuntimeConfig
  )
  process {
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
        & "Invoke-StartVMAction_$type" -RuntimeConfig $RuntimeConfig -ErrorAction Stop
    } catch {
      $PSCmdlet.ThrowTerminatingError($_)
    }
  }
}
#endregion

#region Retrieve/Test Toolset/Actions Config
function Test-StartVMActionsConfig_Members_Each ($Member) {
  Start-Task "#$inc"

  #region Validate Obj. Content / Structure
  if ($Member -isnot [PSCustomObject]) {
    Complete-Task -Status Terminal "Each Member must be a [PSCustomObject]."
  }

  if (     $Member.VMName -isnot [String] `
       -or $Member.VMName.Length -eq 0 `
       -or $Member.VMName.Length -ne $Member.VMName.Trim().Length
     ) {
    Complete-Task -Status Terminal "Member.VMName must be a non-empty [String] with no leading or trailing whitespace."
  }

  if (      $Member.UserName -ne $null `
       -and (     $Member.UserName -isnot [String] `
              -or $Member.UserName.Length -eq 0 `
              -or $Member.UserName.Length -ne $Member.UserName.Trim().Length
            )
     ) {
    Complete-Task -Status Terminal "If provided, Member.UserName must be a non-empty [String] with no leading or trailing whitespace."
  }

  if (      $Member.Password -ne $null `
       -and (     $Member.Password -isnot [String] `
              -or $Member.Password.Length -eq 0 `
              -or $Member.Password.Length -ne $Member.Password.Trim().Length
            )
     ) {
    Complete-Task -Status Terminal "If provided, Member.Password must be a non-empty [String] with no leading or trailing whitespace."
  }

  if (     (      $Member.UserName -eq $null `
             -and $Member.Password -ne $null `
           ) `
       -or (      $Member.UserName -ne $null `
             -and $Member.Password -eq $null
           )
     ) {
    Complete-Task -Status Terminal "Member.UserName and Member.Password must be provided together, or not at all."
  }

  if ($Member.Optional -isnot [bool]) {
    Complete-Task -Status Terminal "Member.Optional must be a [Boolean]."
  }
  #endregion

  #region Validate VM/Attributes On Current System.
  $vms = @(
    Get-VM |
      Where-Object Name -eq $Member.VMName
  )

  if ($vms.Count -gt 1) {
    Complete-Task -Status Terminal "$($vms.Count) distinct virtual machines named '$($Member.VMName)' were found on this computer. This script is not equipped to tolerate this ambiguity."
  }

  if ($vms.Count -eq 0 -and -not $Member.Optional) {
    Complete-Task -Status Terminal "No virtual machine named '$($Member.VMName)' was found on this computer. Presence of this vm is mandatory for this actions configuration."
  }

  if ($vms.Count -eq 1) {
    $vm = $vms[0]

    $topCheckpoint = @(
      Get-VMSnapshot -VM $vm |
        Where-Object ParentSnapshotName -eq $null
    )

    if (     $topCheckpoint.Count -ne 1 `
         -or (      $topCheckpoint.Name -notlike "Post-Import Starting Image*" `
               -and $topCheckpoint.Name -notlike "Known Good Configuration*"
             )
       ) {
      Complete-Task -Status Terminal "No unambiguous candidate for top-level 'Post-Import' or 'Known Good' checkpoint was found for the vm '$($Member.VMName)'."
    }
  }
  #endregion

  if ($Member.UserName -ne $null) {
    $Credential = Get-StartVMCredential -UserName $Member.UserName -Password $Member.Password
  }
  else { # Will be null if VMName is not found.
    $Credential = Get-StartVMCredential -VMName $Member.VMName
  }

  $outObj = [PSCustomObject]@{
    VMName = $Member.VMName
    Credential = $Credential
    Optional = $Member.Optional
    Present = $vms.Count -eq 1
  }

  $optMap = @{
    $true  = "Optional"
    $false = "Required" 
  }

  $presentMap = @{
    $true  = "Present"
    $false = "Absent"
  }

  Complete-Task -Status Info "Done! ($($outObj.VMName,$optMap.($outObj.Optional),$presentMap.($outObj.Present) -join " | "))"

  $outObj
}
function Test-StartVMActionsConfig_Members ($Members) {
  Start-Task "Validating member vm(s)"

  if ($Members -isnot [Object[]] -or $Members.Count -eq 0) {
    Complete-Task -Status Terminal "Config.Members must be a non-empty [Object[]] array."
  }

  $inc = 1
  $Members = @(
    $Members |
      ForEach-Object {
        Test-StartVMActionsConfig_Members_Each $_
        $inc++
      }
  )

  $uniqueCount = @(
    $Members |
      ForEach-Object VMName |
      Sort-Object -Unique
  ).Count

  if ($Members.Count -ne $uniqueCount) {
    Complete-Task -Status Terminal "Each Member must have a unique VMName."
  }

  $mandatoryCount = @(
    $Members |
      Where-Object Optional -eq $false
  ).Count

  if ($mandatoryCount -eq 0) {
    Complete-Task -Status Terminal "At least one Member must be Mandatory."
  }

  Complete-Task -Status Info "Validated $($members.Count) member vm(s)."

  $Members
}

function Test-StartVMActionsConfig_Actions_Each_VMName ($Action, $Members) {
  if ($Action.VMName -eq $null -and $Members.Count -eq 1) {
    $Action.VMName = $Members[0].VMName
  }

  if ($Action.VMName -eq $null) {
    Complete-Task -Status Terminal "When an action configuration has more than a single member vm, an action of type '$($Action.Type)' must use the VMName parameter to target a specific member." -SkipSameOriginTest
  }

  if ($Action.VMName -cnotin $Members.VMName) {
    Complete-Task -Status Terminal "Action.VMName must be the name of a member associated with the action configuration." -SkipSameOriginTest
  }
}

function Test-StartVMActionsConfig_Actions_Each_Type_RestoreCheckpoint ($Action, $Members, $Context) {
  if ($Action.CheckpointName -ne $null -and $Action.CheckpointMap -ne $null) {
    Complete-Task -Status Terminal "An action of type 'RestoreCheckpoint' may specify a checkpoint name or a checkpoint map, but not both." -SkipSameOriginTest
  }

  if (      $Action.CheckpointName -ne $null `
       -and (     $Action.CheckpointName -isnot [String] `
              -or $Action.CheckpointName.Length -eq 0 `
              -or $Action.CheckpointName -ne $Action.CheckpointName.Trim() `
            )
     ) {
    Complete-Task -Status Terminal "Action.CheckpointName must be a non-empty [String] with no leading or trailing whitespace." -SkipSameOriginTest
  }

  if ($Action.CheckpointMap -eq $null) {
    $Action.CheckpointMap = @{}

    foreach ($name in $Members.VMName) {
      $Action.CheckpointMap.$name = $Action.CheckpointName
    }
  }

  if ($Action.CheckpointMap -isnot [hashtable]) {
    Complete-Task -Status Terminal "Action.CheckpointMap must be a [Hashtable]." -SkipSameOriginTest
  }

  if ($Context -eq "Update" -and ([Array]$Action.CheckpointMap.Values)[0] -ne $null) {
    Complete-Task -Status Terminal "When an Action of type 'RestoreCheckpoint' is used in an 'Update' context, it must be used to restore the top 'Post-Import' or 'Known Good' checkpoint." -SkipSameOriginTest
  }

  $vmNames = $Action.CheckpointMap.Keys

  foreach ($vmName in $vmNames) {
    if (     $vmName -isnot [string] `
         -or $vmName.Length -eq 0 `
         -or $vmName -ne $vmName.Trim() `
         -or $vmName -notin $Members.VMName
    ) {
      Complete-Task -Status Terminal "Each key in Action.CheckpointMap must be the [String] name of a member associated with the action configuration." -SkipSameOriginTest
    }
  }

  $uniqueVMNamesCount = @(
    $vmNames |
      Sort-Object -Unique
  ).Count

  if ($vmNames.Count -ne $uniqueVMNamesCount) {
    Complete-Task -Status Terminal "Each key in Action.CheckpointMap must be unique." -SkipSameOriginTest
  }

  if ($vmNames.Count -ne $Members.Count) {
    Complete-Task -Status Terminal "When an Action.CheckpointMap is provided, each member associated with the action configuration must be represented." -SkipSameOriginTest
  }

  $checkpointNames = $Action.CheckpointMap.Values

  foreach ($checkpointName in $checkpointNames) {
    if (      $checkpointName -ne $null `
         -and (     $checkpointName -isnot [String] `
                -or $checkpointName.Length -eq 0 `
                -or $checkpointName -ne $checkpointName.Trim() `
              )
       ) {
      Complete-Task -Status Terminal "Each value in Action.CheckpointMap must either be null (indicating the top checkpoint), or a [String] identifier of a 'Class-Ready' checkpoint to restore." -SkipSameOriginTest
    }
  }

  $presentVms = @(
    $Members |
      Where-Object Present -eq $true |
      ForEach-Object VMName
  )

  $newMap = [ordered]@{}

  foreach ($vmName in $vmNames) {
    if ($vmName -notin $presentVms) {
      continue
    }

    if ($Action.CheckpointMap.$vmName -eq $null) {
      $snapshot = @(
        Get-VMSnapshot -VMName $vmName |
          Where-Object ParentSnapshotName -eq $null |
          ForEach-Object Id
      )
    }
    else {
      $snapshot = @(
        Get-VMSnapshot -VMName $vmName |
          Where-Object Name -eq "Class-Ready Configuration ($($Action.CheckpointMap.$vmName))" |
          ForEach-Object Id
      )
    }

    if ($snapshot.Count -ne 1) {
      Complete-Task -Status Terminal "The script could not resolve a definitive target snapshot id for the vm '$vmName' in a RestoreCheckpoint action." -SkipSameOriginTest
    }

    $newMap.$vmName = $snapshot[0]
  }

  [PSCustomObject]@{
    Type = "RestoreCheckpoint"
    CheckpointMap = $newMap
    AutoReconfig = $presentVms.Count -eq 1 -and $Context -ne "Update"
  }
}
function Test-StartVMActionsConfig_Actions_Each_Type_Start ($Action, $Members) {
  Test-StartVMActionsConfig_Actions_Each_VMName $Action $Members

  if ($Action.WaitForHeartbeat -isnot [bool]) {
    Complete-Task -Status Terminal "Action.WaitForHeartbeat must be a [Boolean]." -SkipSameOriginTest
  }

  $presentVMs = $Members |
                  Where-Object Present |
                  ForEach-Object VMName

  if ($Action.VMName -in $presentVMs) {
    $Action
  }
}
function Test-StartVMActionsConfig_Actions_Each_Type_Config ($Action, $Members) {
  Test-StartVMActionsConfig_Actions_Each_VMName $Action $Members

  if ($Action.Script -isnot [scriptblock]) {
    Complete-Task -Status Terminal "Action.Script must be a [ScriptBlock]." -SkipSameOriginTest
  }

  $validModes = "AtOnce","KVP"

  if ($Action.FinMode -isnot [string] -or $Action.FinMode -cnotin $validModes) {
    Complete-Task -Status Terminal "Action.FinMode must be a [String] that is a case-sensitive match for one of the following valid modes: '$($validModes -join "', '")'." -SkipSameOriginTest
  }

  if ($Action.UseResourceServer -isnot [bool]) {
    Complete-Task -Status Terminal "Action.UseResourceServer must be a [Boolean]." -SkipSameOriginTest
  }

  if ($Action.UsePhysHostName -isnot [bool]) {
    Complete-Task -Status Terminal "Action.UsePhysHostName must be a [Boolean]." -SkipSameOriginTest
  }

  $member = $members |
              Where-Object VMName -eq $Action.VMName

  if ($member.Credential -eq $null) {
    Complete-Task -Status Terminal "An action of type 'Config' requires credentials to the member vm, whether embedded in the module or supplied in the member definition, to authenticate the PowerShell direct management pathway." -SkipSameOriginTest
  }

  $presentVMs = $Members |
                  Where-Object Present |
                  ForEach-Object VMName

  if ($Action.VMName -in $presentVMs) {
    $Action
  }
}
function Test-StartVMActionsConfig_Actions_Each_Type_Stop ($Action, $Members) {
  Test-StartVMActionsConfig_Actions_Each_VMName $Action $Members

  $presentVMs = $Members |
                  Where-Object Present |
                  ForEach-Object VMName

  if ($Action.VMName -in $presentVMs) {
    $Action
  }
}

function Test-StartVMActionsConfig_Actions_Each_Type_Custom ($Action, $Members) {
  Test-StartVMActionsConfig_Actions_Each_VMName $Action $Members

  $presentVMs = $Members |
                  Where-Object Present |
                  ForEach-Object VMName

  if ($Action.VMName -in $presentVMs) {
    $Action
  }
}

function Test-StartVMActionsConfig_Actions_Each_Type_Clean ($Action, $Members) {
  Test-StartVMActionsConfig_Actions_Each_VMName $Action $Members

  $presentVMs = $Members |
                  Where-Object Present |
                  ForEach-Object VMName

  if ($Action.VMName -in $presentVMs) {
    $Action
  }
}
function Test-StartVMActionsConfig_Actions_Each_Type_ReplaceCheckpoint ($Action, $Members) {
  Test-StartVMActionsConfig_Actions_Each_VMName $Action $Members

  $presentVMs = $Members |
                  Where-Object Present |
                  ForEach-Object VMName

  if ($Action.VMName -in $presentVMs) {
    $Action
  }
}

function Test-StartVMActionsConfig_Actions_Each_Type_NetworkAdapters ($Action, $Members) {
  Test-StartVMActionsConfig_Actions_Each_VMName $Action $Members

  if ($Action.NetworkAdapters -isnot [String[]] -or $Action.NetworkAdapters.Count -eq 0) {
    Complete-Task -Status Terminal "Action.NetworkAdapters must be a non-empty [String[]] array." -SkipSameOriginTest
  }

  $SwitchNames = Get-VMSwitch |
                   ForEach-Object Name

  foreach ($adapter in $Actions.NetworkAdapters) {
    if ($adapter -notin $SwitchNames) {
      Complete-Task -Status Terminal "Each adapter in Action.NetworkAdapters must be the name of a virtual switch available on the system." -SkipSameOriginTest
    }
  }

  $presentVMs = $Members |
                  Where-Object Present |
                  ForEach-Object VMName

  if ($Action.VMName -in $presentVMs) {
    $Action
  }
}
function Test-StartVMActionsConfig_Actions_Each_Type_TakeCheckpoint ($Action, $Members) {
  if (     $Action.CheckpointName -isnot [String] `
       -or $Action.CheckpointName.Length -eq 0 `
       -or $Action.CheckpointName -ne $Action.CheckpointName.Trim() `
     ) {
    Complete-Task -Status Terminal "Action.CheckpointName must be a non-empty [String] with no leading or trailing whitespace." -SkipSameOriginTest
  }

  if ($Action.IncludeOptional -isnot [bool]) {
    Complete-Task -Status Terminal "Action.IncludeOptional must be a [Boolean]." -SkipSameOriginTest
  }

  $CheckpointName = "Class-Ready Configuration ($($Action.CheckpointName))"

  $Targets = @(
    $Members |
      Where-Object Present
  )

  if (-not $Action.IncludeOptional) {
    $Targets = @(
      $Targets |
        Where-Object Optional -eq $false
    )
  }

  [PSCustomObject]@{
    Type           = "TakeCheckpoint"
    CheckpointName = $CheckpointName
    VMNames        = $Targets.VMName
  }
}

function Test-StartVMActionsConfig_Actions_Each_Type_ConfigRdp ($Action, $Members) {
  Test-StartVMActionsConfig_Actions_Each_VMName $Action $Members

  if ($Action.Clear -isnot [bool] -or $Action.Config -isnot [bool]) {
    Complete-Task -Status Terminal "Action.Clear and Action.Config must be [Boolean]." -SkipSameOriginTest
  }

  if ($Action.Config -and -not $Action.Clear) {
    Complete-Task -Status Terminal "If Action.Config is `$true, Action.Clear must also be `$true." -SkipSameOriginTest
  }

  if ($Action.Config) {
    if ($Action.RedirectAudio -isnot [bool] -or $Action.RedirectMicrophone -isnot [bool]) {
      Complete-Task -Status Terminal "If Action.Config is `$true, Action.RedirectAudio and Action.RedirectMicrophone must be defined as [Boolean]." -SkipSameOriginTest
    }
  }

  $presentVms = $Members |
                  Where-Object Present -eq $true |
                  ForEach-Object VMName

  if ($Action.VMName -in $presentVMs) {
    $Action
  }
}
function Test-StartVMActionsConfig_Actions_Each_Type_Connect ($Action, $Members) {
  Test-StartVMActionsConfig_Actions_Each_VMName $Action $Members

  $presentVms = $Members |
                  Where-Object Present -eq $true |
                  ForEach-Object VMName

  if ($Action.VMName -in $presentVMs) {
    $Action
  }
}

function Test-StartVMActionsConfig_Actions_Each ($Action, $Members, $Context) {
  Start-Task "#$inc"

  if ($Action -isnot [PSCustomObject]) {
    Complete-Task -Status Terminal "Each Action must be a [PSCustomObject]."
  }

  if (
    $Action.Type -isnot [String]                       -or
    $Action.Type.Length -eq 0                          -or
    $Action.Type.Length -ne $Action.Type.Trim().Length
  ) {
    Complete-Task -Status Terminal "Action.Type must be a non-empty [String] with no leading or trailing whitespace."
  }

  $functionName = "Test-StartVMActionsConfig_Actions_Each_Type_$($Action.Type)"
  $functionPath = Join-Path -Path function:\ -ChildPath $functionName

  if (-not (Test-Path -LiteralPath $functionPath)) {
    Complete-Task -Status Terminal "No validation function exists for this Action.Type."
  }

  & $functionName $Action $Members $Context

  $msgAug = $Action.Type
  if ($Action.VMName -ne $null) {
    $msgAug += " w/ $($Action.VMName)"
  }

  Complete-Task -Status Info "Done! ($msgAug)"
}

function Test-StartVMActionsConfig_Actions_Context_Config ($Actions, $Members) {
  $allowedTypes = @(
    "RestoreCheckpoint"
    "NetworkAdapters"
    "Start"
    "Config"
    "Stop"
    "Custom"
    "TakeCheckpoint"
  )

  $badActionCount = @(
    $Actions |
      Where-Object Type -notin $allowedTypes
  ).Count

  if ($badActionCount -gt 0) {
    Complete-Task -Status Terminal "The actions included one or more types that are invalid for the Config context. Valid types for the Config context are as follows: '$($allowedTypes -join "', '")'." -SkipSameOriginTest
  }

  if ($Actions[-1].Type -ne "TakeCheckpoint") {
    Complete-Task -Status Terminal "An actionset for the config context must always conclude with a TakeCheckpoint action." -SkipSameOriginTest
  }
}
function Test-StartVMActionsConfig_Actions_Context_Start ($Actions, $Members) {
  $allowedTypes = @(
    "RestoreCheckpoint"
    "Start"
    "Config"
    "ConfigRdp"
    "Connect"
    "Custom"
  )

  $badActionCount = @(
    $Actions |
      Where-Object Type -notin $allowedTypes
  ).Count

  if ($badActionCount -gt 0) {
    Complete-Task -Status Terminal "The actions included one or more types that are invalid for the Start context. Valid types for the Start context are as follows: '$($allowedTypes -join "', '")'." -SkipSameOriginTest
  }

  if ($Actions[-1].Type -ne "Connect") {
    Complete-Task -Status Terminal "An actionset for the start context must always conclude with a Connect action." -SkipSameOriginTest
  }
}
function Test-StartVMActionsConfig_Actions_Context_Update ($Actions, $Members) {
  $allowedTypes = @(
    "RestoreCheckpoint"
    "Clean"
    "Start"
    "Config"
    "Stop"
    "Custom"
    "ReplaceCheckpoint"
  )

  $badActionCount = @(
    $Actions |
      Where-Object Type -notin $allowedTypes
  ).Count

  if ($Members.Count -ne 1) {
    Complete-Task -Status Terminal "An actionset for the 'Update' context may define only one member vm." -SkipSameOriginTest
  }

  if ($badActionCount -gt 0) {
    Complete-Task -Status Terminal "The actions included one or more types that are invalid for the Update context. Valid types for the Update context are as follows: '$($allowedTypes -join "', '")'." -SkipSameOriginTest
  }

  if ($Actions[1].Type -ne "Clean") {
    Complete-Task -Status Terminal "In an actionset for the Update context, the second action must be a Clean action, to remove all other VM checkpoints." -SkipSameOriginTest
  }

  if ($Actions[-1].Type -ne "ReplaceCheckpoint") {
    Complete-Task -Status Terminal "An actionset for the Update context must always conclude with a ReplaceCheckpoint action." -SkipSameOriginTest
  }
}

function Test-StartVMActionsConfig_Actions ($ActionSets, $Members, $Context) {
  Start-Task "Validating action(s)"

  if ($ActionSets -isnot [Object[]] -or $ActionSets.Count -eq 0) {
    Complete-Task -Status Terminal "Config.ActionSets must be a non-empty [Object[]] array."
  }

  $ActionSet = @(
    $ActionSets |
      Where-Object Context -eq $Context
  )

  if ($ActionSet.Count -ne 1) {
    Complete-Task -Status Terminal "The actions configuration must define exactly one ActionSet for a given Context to be used in that context. This configuration defined $($ActionSet.Count) actionset(s) for context '$Context'."
  }

  $ActionSet = $ActionSet[0]

  if (     $ActionSet.Actions -isnot [Object[]] `
       -or $ActionSet.Actions.Count -eq 0
     ) {
    Complete-Task -Status Terminal "ActionSet.Actions must be a non-empty [Object[]] array."
  }

  $inc = 1
  $ActionSet.Actions = @(
    $ActionSet.Actions |
      ForEach-Object {
        Test-StartVMActionsConfig_Actions_Each $_ $Members $Context
        $inc++
      }
  )

  if ($ActionSet.Actions[0].Type -ne "RestoreCheckpoint") {
    Complete-Task -Status Terminal "Regardless of context, the first action of any actionset must be of the 'RestoreCheckpoint' type."
  }

  $functionName = "Test-StartVMActionsConfig_Actions_Context_$Context"
  $functionPath = Join-Path -Path function:\ -ChildPath $functionName

  if (-not (Test-Path -LiteralPath $functionPath)) {
    Complete-Task -Status Terminal "No validation function exists for context '$Context'."
  }

  & $functionName $ActionSet.Actions $Members

  if ($Context -ne "Start" -and $ActionSet.EnhancedSessionMode -ne $null) {
    Complete-Task -Status Terminal "Enhanced Session Mode may be configured only for the 'Start' ActionSet Context."
  }
  elseif ($Context -ne "Start" -or $ActionSet.EnhancedSessionMode -eq $null) {
    $ActionSet.EnhancedSessionMode = $false
  }

  if ($ActionSet.EnhancedSessionMode -isnot [bool]) {
    Complete-Task -Status Terminal "EnhancedSessionMode must be a [Boolean]."
  }

  Complete-Task -Status Info "Validated $($ActionSet.Actions.Count) action(s)."

  $ActionSet
}

function Confirm-UpdateContext ($Members) {

  Start-Task "Prompting user to confirm implementation of update"

  Suspend-TaskLogging

  $choices = [System.Collections.ObjectModel.Collection[System.Management.Automation.Host.ChoiceDescription]]::new()
  $choices += [System.Management.Automation.Host.ChoiceDescription]::new(
    "Implement",
    "Remove all existing Class-Ready Configuration checkpoints and update the Known Good Configuration checkpoint for `"$($Members[0].VMName)`"."
  )
  $choices += [System.Management.Automation.Host.ChoiceDescription]::new(
    "Test",
    "Test configuration changes using a mock `"Class-Ready Configuration`" checkpoint for `"$($Members[0].VMName)`"."
  )

  Write-Host
  $choice = $Host.UI.PromptForChoice(
    $null,
    "Are you sure you want to Implement this update by removing all existing Class-Ready Configuration checkpoints and updating the Known Good Configuration checkpoint, or would you rather Test this update instead?",
    $choices,
    1
  )

  Resume-TaskLogging

  if ($choice -eq 0) {
    Complete-Task -Status Info "User confirmed implementation of update."
  }
  elseif ($choice -eq 1) {
    Complete-Task -Status Info "User elected to test implementation of update using a mock 'Class-Ready' checkpoint."
  }

  return $choice -eq 0
}

function Test-StartVMActionsConfig ($Config, $Context) {
  Start-Task "Validating '$ActionName' w/ context '$Context'"

  if ($Config -isnot [PSCustomObject]) {
    Complete-Task -Status Terminal "Config must be a [PSCustomObject]."
  }

  $Members = @(
    Test-StartVMActionsConfig_Members $Config.Members
  )
  $ActionSet = @(
    Test-StartVMActionsConfig_Actions $Config.ActionSets $Members $Context
  )

  Complete-Task -Status       Info `
                -Message      "'$ActionName' w/ context '$Context' is valid." `
                -ShortMessage "Done!"

  [PSCustomObject]@{
    Members = $Members
    ActionSet = $ActionSet
  }
}
#endregion

#region Orchestrate Actions
function Do-StartVMActions_Custom ($Action) {
  Start-Task "#$($inc): Custom w/ '$($Action.VMName)'"

  $vm = Get-VM -Name $Action.VMName

  if ($vm.State -ne "Off") {
    Complete-Task -Status Terminal "An action of type 'Custom' requires the vm be in an 'Off' state."
  }

  $Action.Script.Invoke($vm) | Out-Null

  Complete-Task -Status Info "Done!"
}

function Do-StartVMActions_Clean ($Action) {
  Start-Task "#$($inc): Clean w/ '$($Action.VMName)'"

  $vm = Get-VM -Name $Action.VMName

  if ($vm.State -ne "Off") {
    Complete-Task -Status Terminal "An action of type 'Clean' requires the vm be in an 'Off' state."
  }

  $currentCheckpoint = Get-VMSnapshot -Id $vm.ParentSnapshotId

  if ($currentCheckpoint.ParentSnapshotName -ne $null) {
    Complete-Task -Status Terminal "An action of type 'Clean' requires the top checkpoint be the one currently applied."
  }

  Get-VMSnapshot -VM $vm |
    Where-Object ParentCheckpointId -eq $currentCheckpoint.Id |
    Remove-VMSnapshot -IncludeAllChildSnapshots

  Complete-Task -Status Info "Done!"
}
function Do-StartVMActions_ReplaceCheckpoint ($Action) {
  Start-Task "#$($inc): Replace checkpoint w/ '$($Action.VMName)'"

  $vm = Get-VM -Name $Action.VMName

  if ($vm.State -ne "Off") {
    Complete-Task -Status Terminal "An action of type 'ReplaceCheckpoint' requires the vm be in an 'Off' state."
  }

  Start-Task "Generating new 'Known Good Configuration' checkpoint"
  $newCheckpoint = $vm |
                     Checkpoint-VM -SnapshotName "Known Good Configuration" -Passthru
  Complete-Task -Status Info "Done!"

  Start-Task "Removing previous checkpoint"
  $newCheckpoint.ParentSnapshotId |
    Get-VMSnapshot |
    Remove-VMSnapshot
  Complete-Task -Status Info "Done!"

  Start-Task "Waiting for vhd merge"
  do {
    Start-Sleep -Seconds 5
  } while ((Get-VM -Id $vm.Id).Status -ne "Operating normally")
  Complete-Task -Status Info "Done!"

  Complete-Task -Status Info "Finished replacing checkpoint."
}

function Do-StartVMActions_ConfigRdp ($Action) {
  Start-Task "#$($inc): Configure rdp options w/ '$($Action.VMName)'"

  if ($action.Config -eq $false -and $action.Clear -eq $false) {
    Complete-Task -Status Info "Done! (Retained)"
    return
  }

  $vm = Get-VM -Name $Action.VMName

  $configPath = Join-Path -Path ([System.Environment]::GetFolderPath("ApplicationData")) `
                          -ChildPath Microsoft\Windows\Hyper-V\Client\1.0

  $configPath = Join-Path -Path $configPath `
                          -ChildPath "vmconnect.rdp.$($vm.Id).config"

  if (Test-Path -LiteralPath $configPath) {
    Remove-Item -LiteralPath $configPath -Force -Recurse
  }

  if ($action.Config -eq $false) {
    Complete-Task -Status Info "Done! (Cleared)"
    return
  }

  $xml = [System.Xml.XmlDocument]::new()

  $xml.AppendChild(
    $xml.CreateXmlDeclaration("1.0", "utf-8", $null)
  ) | Out-Null

  $cfgNode = $xml.CreateElement("configuration")
  $xml.AppendChild($cfgNode) | Out-Null

  $optsNode = $xml.CreateElement("Microsoft.Virtualization.Client.RdpOptions")
  $cfgNode.AppendChild($optsNode) | Out-Null

  function Add-Setting ($Name, $Value = '', $Type) {
    $settingNode = $xml.CreateElement("setting")
    $optsNode.AppendChild($settingNode) | Out-Null

    if ($Type -eq $null) {
      $Type = $Value.GetType().FullName
    }

    $settingNode.SetAttribute("name", $Name)
    $settingNode.SetAttribute("type", $Type)

    $valueNode = $xml.CreateElement("value")
    $settingNode.AppendChild($valueNode) | Out-Null

    if ($Type -isnot "System.String" -or $Value.Length -gt 0) {
      $valueNode.InnerText = [string]$Value
    }
  }

  Add-Type -AssemblyName System.Windows.Forms

  $screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

  if ($Action.RedirectAudio) {
    $redirectSetting = "AUDIO_MODE_REDIRECT"
  }
  else {
    $redirectSetting = "AUDIO_MODE_NONE"
  }

  Add-Setting SavedConfigExists $true
  Add-Setting AudioCaptureRedirectionMode $Action.RedirectMicrophone
  Add-Setting SaveButtonChecked $true
  Add-Setting FullScreen $false
  Add-Setting SmartCardsRedirection $false
  Add-Setting RedirectedPnpDevices
  Add-Setting ClipboardRedirection $false
  Add-Setting DesktopSize ($screenBounds.Width,$screenBounds.Height -join ", ") System.Drawing.Size
  Add-Setting VmServerName ([System.Net.Dns]::GetHostName())
  Add-Setting RedirectedUsbDevices
  Add-Setting UseAllMonitors $false
  Add-Setting AudioPlaybackRedirectionMode $redirectSetting Microsoft.Virtualization.Client.RdpOptions+AudioPlaybackRedirectionType
  Add-Setting PrinterRedirection $false
  Add-Setting RedirectedDrives
  Add-Setting VmName $vm.Name

  #$xml.OuterXml

  New-Item -Path $configPath -ItemType File -Value $xml.OuterXml -Force |
    Out-Null

  Complete-Task -Status Info "Done! (Configured)"
}

function Do-StartVMActions ($Config, $ToolsetConfig) {
  Start-Task "Orchestrating action(s)" -Tags OrchestrateActions

  $inc = 1
  foreach ($Action in $Config.ActionSet.Actions) {
    $functionName = "Do-StartVMActions_$($Action.Type)"

    & $functionName $Action $Config.Members $ToolsetConfig

    $inc++
  }

  Complete-Task -Status Info "Orchestrated $($Config.ActionSet.Actions.Count) action(s)."
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
      "Update"
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

    $resultObj."Resolved Actions Configuration" = $ActionSet

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
      Invoke-StartVMAction -RuntimeConfig $RuntimeConfig

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