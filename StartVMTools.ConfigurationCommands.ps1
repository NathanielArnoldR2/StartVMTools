function New-StartVMConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    # Members cannot be further validated here because a string-to-
    # StartVMMember conversion is handled by the Add-StartVMMember
    # function.
    [Object[]]
    $Members
  )

  $xml = [System.Xml.XmlDocument]::new()

  $cfg = $xml.AppendChild(
    $xml.CreateElement("Configuration")
  )

  $cfg.SetAttribute("xmlns:xsi","http://www.w3.org/2001/XMLSchema-instance")

  "Name",
  "Members",
  "ActionSets" |
    ForEach-Object {
      $cfg.AppendChild(
        $xml.CreateElement($_)
      ) | Out-Null
    }

  $setParams = [hashtable]$PSBoundParameters

  $cfg |
    Set-StartVMConfiguration @setParams

  $cfg
}
function Set-StartVMConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject
  )

  DynamicParam {
    $params = [System.Management.Automation.RuntimeDefinedParameterDictionary]::new()

    $commonParamNames = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
      [System.Management.Automation.Internal.CommonParameters]
    ) |
      ForEach-Object psobject |
      ForEach-Object Properties |
      ForEach-Object Name

    $sourceParams = Get-Command New-StartVMConfiguration |
                      ForEach-Object Parameters |
                      ForEach-Object GetEnumerator |
                      ForEach-Object Value |
                      Where-Object Name -cnotin $commonParamNames

    foreach ($sourceParam in $sourceParams) {
      $param = [System.Management.Automation.RuntimeDefinedParameter]::new(
        $sourceParam.Name,
        $sourceParam.ParameterType,
        $sourceParam.Attributes
      )

      $params.Add(
        $sourceParam.Name,
        $param
      )
    }

    return $params
  }

  process {
    if ($PSBoundParameters.ContainsKey("Members")) {
      $InputObject |
        Get-StartVMMember |
        Remove-StartVMMember

      $InputObject |
        Add-StartVMMember $PSBoundParameters.Members
    }
  }
}

function Get-StartVMMember {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject
  )
  process {
    $InputObject.
      SelectNodes("Members/Member")
  }
}
function New-StartVMMember {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      Position  = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Name,

    [switch]
    $Optional,

    [ValidateNotNullOrEmpty()]
    [string]
    $UserName,

    [ValidateNotNullOrEmpty()]
    [string]
    $Password
  )

  [PSCustomObject]@{
    PSTypeName = "StartVMMember"
    Name       = $Name
    Required   = -not $Optional # Implicit cast to [bool].
    UserName   = $UserName
    Password   = $Password
  }
}
function Add-StartVMMember {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject,

    [Parameter(
      Mandatory = $true,
      Position = 0
    )]
    [Object[]]
    $Member
  )

  $membersNode = $InputObject.SelectSingleNode("Members")

  foreach ($MemberItem in $Member) {
    $memberNode = $membersNode.AppendChild(
      $InputObject.
      OwnerDocument.
      CreateElement("Member")
    )

    if ($MemberItem -is [string]) {
      $MemberItem = New-StartVMMember $MemberItem
    }

    if ($MemberItem.psobject.TypeNames[0] -cne "StartVMMember") {
      throw "Invalid member. Object was not a 'StartVMMember', or a string name from which a member could be constructed."
    }

    $memberNode.SetAttribute("Name", $MemberItem.Name)
    $memberNode.SetAttribute("Required", $MemberItem.Required.ToString().ToLower())

    if (
      $MemberItem.UserName.Length -gt 0 -or
      $MemberItem.Password.Length -gt 0
    ) {
      $credNode = $memberNode.AppendChild(
        $InputObject.
        OwnerDocument.
        CreateElement("Credential")
      )

      $credNode.SetAttribute("UserName", $MemberItem.UserName)
      $credNode.SetAttribute("Password", $MemberItem.Password)
    }
  }
}
function Remove-StartVMMember {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject
  )
  process {
    $InputObject.
      ParentNode.
      RemoveChild($InputObject) |
      Out-Null
  }
}
New-Alias -Name member -Value New-StartVMMember

function Add-StartVMActionSet {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject,

    [Parameter(
      Mandatory = $true
    )]
    [ValidateSet(
      "Config",
      "Start",
      "Test",
      "Save",
      "Restore",
      "Update"
    )]
    [string]
    $Context,

    # Members cannot be further validated here because a string-to-
    # StartVMMember conversion is handled by the Add-StartVMMember
    # function.
    [Object[]]
    $Members,

    [PSTypeName("StartVMAction")]
    [Object[]]
    $Actions,

    [switch]
    $UseEnhancedSessionMode,

    [switch]
    $PassThru
  )

  $actionSets = $InputObject.SelectSingleNode("ActionSets")

  $actionSet = $actionSets.AppendChild(
    $InputObject.
      OwnerDocument.
      CreateElement("ActionSet")
  )

  $actionSet.SetAttribute("Context", [string]::Empty)

  "Members",
  "Actions" |
    ForEach-Object {
      $actionSet.AppendChild(
        $InputObject.
        OwnerDocument.
        CreateElement($_)
      ) | Out-Null
    }

  $actionSet.SetAttribute("UseEnhancedSessionMode", [string]::Empty)

  $setParams = [hashtable]$PSBoundParameters

  $setParams.Remove("InputObject")
  $setParams.Remove("PassThru")

  $actionSet |
    Set-StartVMActionSet @setParams

  if ($PassThru) {
    $actionSet
  }
}
function Set-StartVMActionSet {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param()

  DynamicParam {
    $params = [System.Management.Automation.RuntimeDefinedParameterDictionary]::new()

    $commonParamNames = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
      [System.Management.Automation.Internal.CommonParameters]
    ) |
      ForEach-Object psobject |
      ForEach-Object Properties |
      ForEach-Object Name

    $excludedParamNames = @(
      "PassThru"
    )

    $sourceParams = Get-Command Add-StartVMActionSet |
                      ForEach-Object Parameters |
                      ForEach-Object GetEnumerator |
                      ForEach-Object Value |
                      Where-Object Name -cnotin $commonParamNames |
                      Where-Object Name -cnotin $excludedParamNames


    foreach ($sourceParam in $sourceParams) {
      $param = [System.Management.Automation.RuntimeDefinedParameter]::new(
        $sourceParam.Name,
        $sourceParam.ParameterType,
        $sourceParam.Attributes
      )

      $params.Add(
        $sourceParam.Name,
        $param
      )
    }

    return $params
  }

  process {
    if ($PSBoundParameters.ContainsKey("Context")) {
      $PSBoundParameters.InputObject.SetAttribute(
        "Context",
        $PSBoundParameters.Context
      )
    }

    if ($PSBoundParameters.ContainsKey("Members")) {
      $PSBoundParameters.InputObject |
        Get-StartVMMember |
        Remove-StartVMMember

      $PSBoundParameters.InputObject |
        Add-StartVMMember $PSBoundParameters.Members
    }

    if ($PSBoundParameters.ContainsKey("Actions")) {
      $PSBoundParameters.InputObject |
        Get-StartVMAction |
        Remove-StartVMAction

      $PSBoundParameters.InputObject |
        Add-StartVMAction $PSBoundParameters.Actions
    }

    if ($PSBoundParameters.ContainsKey("UseEnhancedSessionMode")) {
      $PSBoundParameters.InputObject.SetAttribute(
        "UseEnhancedSessionMode",
        $PSBoundParameters.UseEnhancedSessionMode.ToString().ToLower()
      )
    }
  }
}
New-Alias -Name actionSet -Value Add-StartVMActionSet

function Get-StartVMAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject
  )
  process {
    $InputObject.
      SelectNodes("Actions/Action")
  }
}
function New-StartVMRestoreCheckpointAction {
  [CmdletBinding(
    DefaultParameterSetName = "CheckpointName",
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      ParameterSetName = "CheckpointName",
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $CheckpointName,

    [Parameter(
      ParameterSetName = "CheckpointMap",
      Mandatory = $true,
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [hashtable]
    $CheckpointMap
  )

  $outHash = [ordered]@{
    PSTypeName = "StartVMAction"
    Type       = "RestoreCheckpointAction"
  }

  if ($PSCmdlet.ParameterSetName -eq "CheckpointName") {
    $outHash.CheckpointName = $CheckpointName
  }
  elseif ($PSCmdlet.ParameterSetName -eq "CheckpointMap") {
    $outHash.CheckpointMap = $CheckpointMap
  }

  [PSCustomObject]$outHash
}
New-Alias -Name act_restoreCheckpoint -Value New-StartVMRestoreCheckpointAction
function New-StartVMCleanAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Target
  )
  [PSCustomObject]@{
    PSTypeName       = "StartVMAction"
    Type             = "CleanAction"
    Target           = $Target
  }
}
New-Alias -Name act_clean -Value New-StartVMCleanAction

function New-StartVMConfigHwAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Target,

    [byte]
    $ProcessorCount,

    [long]
    $MemoryBytes,

    [AllowEmptyCollection()]
    [string[]]
    $NetworkAdapters
  )

  $outHash = [ordered]@{
    PSTypeName        = "StartVMAction"
    Type              = "ConfigHwAction"
    Target            = $Target
  }

  if ($PSBoundParameters.ContainsKey("ProcessorCount")) {
    $outHash.ProcessorCount = $ProcessorCount
  }

  if ($PSBoundParameters.ContainsKey("MemoryBytes")) {
    $outHash.MemoryBytes = $MemoryBytes
  }

  if ($PSBoundParameters.ContainsKey("NetworkAdapters")) {
    $outHash.NetworkAdapters = $NetworkAdapters
  }

  [PSCustomObject]$outHash
}
New-Alias -Name act_configHw -Value New-StartVMConfigHwAction
function New-StartVMCustomAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Target,

    [Parameter(
      Mandatory = $true
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Script
  )
  [PSCustomObject]@{
    PSTypeName        = "StartVMAction"
    Type              = "CustomAction"
    Target            = $Target
    Script            = $Script
  }
}
New-Alias -Name act_custom -Value New-StartVMCustomAction

function New-StartVMStartAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Target,

    [switch]
    $WaitForHeartbeat
  )
  [PSCustomObject]@{
    PSTypeName       = "StartVMAction"
    Type             = "StartAction"
    Target           = $Target
    WaitForHeartbeat = (-not $PSBoundParameters.ContainsKey("WaitForHeartbeat")) -or ($WaitForHeartbeat)
  }
}
New-Alias -Name act_start -Value New-StartVMStartAction

function New-StartVMInjectAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Target,

    [Parameter(
      Mandatory = $true
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Script,

    [switch]
    $UsePhysHostName,

    [switch]
    $WaitForKvp,

    [switch]
    $UseResourceServer,

    [ValidateNotNullOrEmpty()]
    [string[]]
    $Packages = [string[]]@(),

    [ValidateNotNullOrEmpty()]
    [string]
    $UserName,

    [ValidateNotNullOrEmpty()]
    [string]
    $Password
  )
  $outHash = [ordered]@{
    PSTypeName        = "StartVMAction"
    Type              = "InjectAction"
    Target            = $Target
    Script            = $Script
    UsePhysHostName   = [bool]$UsePhysHostName
    WaitForKvp        = [bool]$WaitForKvp
    UseResourceServer = $null
    Packages          = $Packages
    UserName          = $UserName
    Password          = $Password
  }

  if ($PSBoundParameters.ContainsKey("UseResourceServer")) {
    $outHash.UseResourceServer = [bool]$UseResourceServer
  }

  [PSCustomObject]$outHash
}
New-Alias -Name act_inject -Value New-StartVMInjectAction

function New-StartVMConfigRdpAction {
  [CmdletBinding(
    DefaultParameterSetName = "Config",
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      ParameterSetName = "Config",
      Position = 0
    )]
    [Parameter(
      ParameterSetName = "Clear",
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Target,

    [Parameter(
      ParameterSetName = "Clear",
      Mandatory = $true
    )]
    [switch]
    $Clear,

    [Parameter(
      ParameterSetName = "Config"
    )]
    [switch]
    $RedirectAudio,

    [Parameter(
      ParameterSetName = "Config"
    )]
    [switch]
    $RedirectMicrophone
  )
  $outHash = [ordered]@{
    PSTypeName         = "StartVMAction"
    Type               = "ConfigRdpAction"
    Target             = $Target
    Clear              = $PSCmdlet.ParameterSetName -eq "Config" -or ($PSCmdlet.ParameterSetName -eq "Clear" -and $Clear)
    Config             = $PSCmdlet.ParameterSetName -eq "Config"
    RedirectAudio      = $null
    RedirectMicrophone = $null
  }

  if ($outHash.Config) {
    $outHash.RedirectAudio = [bool]$RedirectAudio
    $outHash.RedirectMicrophone = [bool]$RedirectMicrophone
  }

  [PSCustomObject]$outHash
}
New-Alias -Name act_configRdp -Value New-StartVMConfigRdpAction
function New-StartVMConnectAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Target
  )
  [PSCustomObject]@{
    PSTypeName       = "StartVMAction"
    Type             = "ConnectAction"
    Target           = $Target
  }
}
New-Alias -Name act_connect -Value New-StartVMConnectAction

function New-StartVMSaveIfNeededAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Target
  )
  [PSCustomObject]@{
    PSTypeName       = "StartVMAction"
    Type             = "SaveIfNeededAction"
    Target           = $Target
  }
}
New-Alias -Name act_saveIfNeeded -Value New-StartVMSaveIfNeededAction
function New-StartVMStopAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Target
  )
  [PSCustomObject]@{
    PSTypeName       = "StartVMAction"
    Type             = "StopAction"
    Target           = $Target
  }
}
New-Alias -Name act_stop -Value New-StartVMStopAction
function New-StartVMTakeCheckpointAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Position  = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $CheckpointName
  )
  [PSCustomObject]@{
    PSTypeName        = "StartVMAction"
    Type              = "TakeCheckpointAction"
    CheckpointName    = $CheckpointName
  }
}
New-Alias -Name act_takeCheckpoint -Value New-StartVMTakeCheckpointAction

function New-StartVMReplaceCheckpointAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $Target
  )
  [PSCustomObject]@{
    PSTypeName       = "StartVMAction"
    Type             = "ReplaceCheckpointAction"
    Target           = $Target
  }
}
New-Alias -Name act_replaceCheckpoint -Value New-StartVMReplaceCheckpointAction
function Add-StartVMAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject,

    [Parameter(
      Mandatory = $true,
      Position = 0
    )]
    [PSTypeName("StartVMAction")]
    [Object[]]
    $Action,

    [byte]
    $Index,

    [switch]
    $PassThru
  )

#region Type-Specific Markup Handlers
function Add-StartVMAction_RestoreCheckpoint ($Node, $Item) {
  if ($Item.CheckpointName -is [string]) {
    $Node.AppendChild(
      $Node.
      OwnerDocument.
      CreateElement("CheckpointName")
    ).InnerText = $Item.CheckpointName
  }
  elseif ($Item.CheckpointMap -is [hashtable]) {
    $MapNode = $Node.AppendChild(
      $Node.
      OwnerDocument.
      CreateElement("CheckpointMap")
    )

    foreach ($MapItem in $Item.CheckpointMap.GetEnumerator()) {
      $itemNode = $MapNode.AppendChild(
        $Node.
        OwnerDocument.
        CreateElement("CheckpointMapItem")
      )

      $itemNode.SetAttribute("Target", $MapItem.Key)

      if ($MapItem.Value -is [string]) {
        $itemNode.SetAttribute("CheckpointName", $MapItem.Value)
      }
      elseif ($null -eq $MapItem.Value) {
        $itemNode.SetAttribute("CheckpointName", [string]::Empty)
      }
    }
  }
}
function Add-StartVMAction_Start ($Node, $Item) {
  $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("WaitForHeartbeat")
  ).InnerText = $Item.WaitForHeartbeat.ToString().ToLower()
}
function Add-StartVMAction_Inject ($Node, $Item) {
  $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("Script")
  ).InnerText = $Item.Script

  $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("UsePhysHostName")
  ).InnerText = $Item.UsePhysHostName.ToString().ToLower()

  $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("WaitForKvp")
  ).InnerText = $Item.WaitForKvp.ToString().ToLower()

  $resSvrNode = $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("UseResourceServer")
  )

  if ($Item.UseResourceServer -is [bool]) {
    $resSvrNode.InnerText = $Item.UseResourceServer.ToString().ToLower()
  }

  $packagesNode = $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("Packages")
  )

  foreach ($package in $Item.Packages) {
    $packagesNode.AppendChild(
      $Node.
      OwnerDocument.
      CreateElement("Package")
    ).InnerText = $package
  }

  if (
    $Item.UserName.Length -gt 0 -or
    $Item.Password.Length -gt 0
  ) {
    $credNode = $Node.AppendChild(
      $Node.
      OwnerDocument.
      CreateElement("Credential")
    )

    $credNode.SetAttribute("UserName", $Item.UserName)
    $credNode.SetAttribute("Password", $Item.Password)
  }
}
function Add-StartVMAction_Custom ($Node, $Item) {
  $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("Script")
  ).InnerText = $Item.Script
}
function Add-StartVMAction_ConfigHw ($Node, $Item) {
  if ($null -ne $Item.ProcessorCount) {
    $Node.AppendChild(
      $Node.
      OwnerDocument.
      CreateElement("ProcessorCount")
    ).InnerText = $Item.ProcessorCount
  }

  if ($null -ne $Item.MemoryBytes) {
    $Node.AppendChild(
      $Node.
      OwnerDocument.
      CreateElement("MemoryBytes")
    ).InnerText = $Item.MemoryBytes
  }

  if ($null -ne $Item.NetworkAdapters) {
    $adaptersNode = $Node.AppendChild(
      $Node.
      OwnerDocument.
      CreateElement("NetworkAdapters")
    )

    foreach ($adapter in $Item.NetworkAdapters) {
      $adaptersNode.AppendChild(
        $Node.
        OwnerDocument.
        CreateElement("NetworkAdapter")
      ).InnerText = $adapter
    }
  }
}
function Add-StartVMAction_TakeCheckpoint ($Node, $Item) {
  $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("CheckpointName")
  ).InnerText = $Item.CheckpointName
}
function Add-StartVMAction_ConfigRdp ($Node, $Item) {
  $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("Clear")
  ).InnerText = $Item.Clear.ToString().ToLower()

  $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("Config")
  ).InnerText = $Item.Config.ToString().ToLower()

  $audNode = $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("RedirectAudio")
  )

  $micNode = $Node.AppendChild(
    $Node.
    OwnerDocument.
    CreateElement("RedirectMicrophone")
  )

  if ($Item.RedirectAudio -is [bool]) {
    $audNode.InnerText = $Item.RedirectAudio.ToString().ToLower()
  }
  if ($Item.RedirectMicrophone -is [bool]) {
    $micNode.InnerText = $Item.RedirectMicrophone.ToString().ToLower()
  }
}
#endregion

  $cfgNode = $InputObject.SelectSingleNode("/Configuration")
  $actionsNode = $InputObject.SelectSingleNode("Actions")

  $actions = $actionsNode.SelectNodes("Action")

  if (-not ($PSBoundParameters.ContainsKey("Index"))) {
    $Index = $actions.Count
  }

  if ($Index -gt 0) {
    $referenceNode = $actions[$Index - 1]
  }

  foreach ($ActionItem in $Action) {
    $actionNode = $InputObject.
                    OwnerDocument.
                    CreateElement("Action")

    $typeAttr = $InputObject.
                  OwnerDocument.
                  CreateAttribute("xsi:type", $cfgNode.xsi)

    $typeAttr.Value = $ActionItem.Type

    $actionNode.SetAttributeNode($typeAttr) | Out-Null

    if ($ActionItem.Target -is [string]) {
      $actionNode.SetAttribute("Target", $ActionItem.Target)
    }

    $handlerName = "Add-StartVMAction_$($ActionItem.Type -replace 'Action$','')"

    if (Test-Path -LiteralPath "function:\$handlerName") {
      & $handlerName -Node $actionNode -Item $ActionItem
    }

    if ($null -eq $referenceNode) {
      $actionsNode.AppendChild($actionNode) | Out-Null
    }
    else {
      $actionsNode.InsertAfter($actionNode, $referenceNode)
    }

    $referenceNode = $actionNode

    if ($PassThru) {
      $actionNode
    }
  }
}
function Remove-StartVMAction {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true
    )]
    [System.Xml.XmlElement]
    $InputObject
  )
  process {
    $InputObject.
      ParentNode.
      RemoveChild($InputObject) |
      Out-Null
  }
}