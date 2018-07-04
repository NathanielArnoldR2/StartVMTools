function New-StartVMPersistentData {
  [CmdletBinding(
    PositionalBinding = $false
  )]
  param(
    [Parameter(
      Mandatory = $true
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $LastConfigurationName,

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
    $LastActionSetContext,

    [Parameter(
      Mandatory = $true
    )]
    [datetime]
    $LastProcessed
  )
  $xml = [System.Xml.XmlDocument]::new()

  $data = $xml.AppendChild(
    $xml.CreateElement("Data")
  )

  $data.AppendChild(
    $xml.CreateElement("LastConfigurationName")
  ).InnerXml = $LastConfigurationName

  $data.AppendChild(
    $xml.CreateElement("LastActionSetContext")
  ).InnerXml = $LastActionSetContext

  $data.AppendChild(
    $xml.CreateElement("LastProcessed")
  ).InnerXml = $LastProcessed.ToString("yyy-MM-ddTHH:mm:ss")

  $data
}