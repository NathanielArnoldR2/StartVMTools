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

    [string[]]
    $ResourceServerOptions = [string[]]@(),

    [bool]
    $TestResourceShares = $true,

    [bool]
    $AutoExit = $true
  )

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

  $node = $cfg.AppendChild(
    $xml.CreateElement("ResourceServerOptions")
  )

  foreach ($option in $ResourceServerOptions) {
    $node.AppendChild(
      $xml.CreateElement("ResourceServerOption")
    ).InnerXml = $option
  }

  $cfg.AppendChild(
    $xml.CreateElement("TestResourceShares")
  ).InnerXml = $TestResourceShares.ToString().ToLower()

  $cfg.AppendChild(
    $xml.CreateElement("AutoExit")
  ).InnerXml = $AutoExit.ToString().ToLower()
  
  $cfg
}