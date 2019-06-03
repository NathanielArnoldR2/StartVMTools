function New-StartVMToolsetConfiguration {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [bool]
    $AutoEject = $true,

    [string[]]
    $DefaultMemberOptions = [string[]]@(),

    [bool]
    $IgnoreNonMembers = $false,

    [string[]]
    $IgnoreList = [string[]]@(),

    [string]
    $PhysHostNameOverride = $false,

    [Parameter(
      Mandatory = $true
    )]
    [hashtable]
    $Resources,

    [bool]
    $AutoExit = $true
  )

#region Component Functions
function cmp_Resources {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [string]
    $ApplyMode = "Online",

    [Parameter(
      Mandatory = $true
    )]
    [hashtable]
    $Online,

    [Parameter(
      Mandatory = $true
    )]
    [hashtable]
    $Offline
  )
  [PSCustomObject]@{
    ApplyMode = $ApplyMode
    Online    = cmp_Resources_Online @Online
    Offline   = cmp_Resources_Offline @Offline
  }
}
function cmp_Resources_Online {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [string[]]
    $ServerOptions = [string[]]@(),

    [bool]
    $TestShares = $true
  )
  [PSCustomObject]@{
    ServerOptions = $ServerOptions
    TestShares    = $TestShares
  }
}
function cmp_Resources_Offline {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [string]
    $ModulesSourcePath = [string]::Empty,

    [string]
    $PackagesSourcePath = [string]::Empty
  )
  [PSCustomObject]@{
    ModulesSourcePath  = $ModulesSourcePath
    PackagesSourcePath = $PackagesSourcePath
  }
}
#endregion

  $xml = [System.Xml.XmlDocument]::new()

  $cfg = $xml.AppendChild(
    $xml.CreateElement("Configuration")
  )

  $cfg.AppendChild(
    $xml.CreateElement("AutoEject")
  ).InnerXml = $AutoEject.ToString().ToLower()

  $node = $cfg.AppendChild(
    $xml.CreateElement("DefaultMemberOptions")
  )

  foreach ($option in $DefaultMemberOptions) {
    $node.AppendChild(
      $xml.CreateElement("DefaultMemberOption")
    ).InnerXml = $option
  }

  $cfg.AppendChild(
    $xml.CreateElement("IgnoreNonMembers")
  ).InnerXml = $IgnoreNonMembers.ToString().ToLower()

  $node = $cfg.AppendChild(
    $xml.CreateElement("IgnoreList")
  )

  foreach ($item in $IgnoreList) {
    $node.AppendChild(
      $xml.CreateElement("IgnoreListItem")
    ).InnerXml = $item
  }

  if ($PhysHostNameOverride -cin "True","False") {
    $PhysHostNameOverride = $PhysHostNameOverride.ToLower()
  }

  $cfg.AppendChild(
    $xml.CreateElement("PhysHostNameOverride")
  ).InnerXml = $PhysHostNameOverride

  $resourcesObj = cmp_Resources @Resources

  $resourcesNode = $cfg.AppendChild(
    $xml.CreateElement("Resources")
  )

  $resourcesNode.AppendChild(
    $xml.CreateElement("ApplyMode")
  ).InnerXml = $resourcesObj.ApplyMode

  $onlineNode = $resourcesNode.AppendChild(
    $xml.CreateElement("Online")
  )

  $optionsNode = $onlineNode.AppendChild(
    $xml.CreateElement("ServerOptions")
  )

  foreach ($option in $resourcesObj.Online.ServerOptions) {
    $optionsNode.AppendChild(
      $xml.CreateElement("ServerOption")
    ).InnerXml = $option
  }

  $onlineNode.AppendChild(
    $xml.CreateElement("TestShares")
  ).InnerXml = $resourcesObj.Online.TestShares.ToString().ToLower()

  $offlineNode = $resourcesNode.AppendChild(
    $xml.CreateElement("Offline")
  )

  $offlineNode.AppendChild(
    $xml.CreateElement("ModulesSourcePath")
  ).InnerXml = $resourcesObj.Offline.ModulesSourcePath

  $offlineNode.AppendChild(
    $xml.CreateElement("PackagesSourcePath")
  ).InnerXml = $resourcesObj.Offline.PackagesSourcePath

  $cfg.AppendChild(
    $xml.CreateElement("AutoExit")
  ).InnerXml = $AutoExit.ToString().ToLower()
  
  $cfg
}