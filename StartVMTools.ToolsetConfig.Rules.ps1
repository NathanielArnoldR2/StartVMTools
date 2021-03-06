$constrainedString = {
  if ($nodeValue.Length -ne $nodeValue.Trim().Length) {
    throw "Value had leading or trailing whitespace."
  }

  if ($nodeValue.Length -lt $params.MinLength -or $nodeValue.Length -gt $params.MaxLength) {
    throw "Value did not meet length constraint of $($params.MinLength) min or $($params.MaxLength) max."
  }

  if ($nodeValue.Contains("\")) {
    throw "Value contained ('\') path separator character."
  }

  if ($nodeValue -notmatch $params.Pattern) {
    throw "Value did not match expected pattern '$($params.Pattern)'."
  }

  if ($params.SkipValidityTest) {
    return
  }

  $testPath = Join-Path -Path C:\ -ChildPath $nodeValue -ErrorAction Stop

  if (-not (Test-Path -LiteralPath $testPath -IsValid -ErrorAction Stop)) {
    throw "Value failed 'Test-Path -IsValid' validity failsafe."
  }
}

$uniqueness = {
  $uniqueValues = @(
    $nodeListValues |
      Sort-Object -Unique
  )

  if ($nodeListValues.Count -ne $uniqueValues.Count) {
    throw "List contained duplicate values."
  }
}

$offlineSourcePath = {
  $applyMode = $node.SelectSingleNode("../..").ApplyMode

  if ($nodeValue.Length -eq 0) {
    return
  }

  #if ($nodeValue.Length -eq 0) {
  #  throw "Offline source paths for Modules and Packages must be specified when the resource apply mode is 'Offline'."
  #}

  if (-not (Test-StartVMOfflineSourcePath -Path $nodeValue)) {
    throw "Offline source paths for Modules and Packages must be rooted, direct paths to existing directories on a local volume or network share."
  }
}

function Test-StartVMOfflineSourcePath {
  param(
    [Parameter(
      Mandatory = $true
    )]
    [string]
    $Path
  )
  try {
    if ($Path -notmatch "^[A-Z]:\\" -and $Path -notmatch "^\\\\") {
      return $false
    }

    if (-not (Test-Path -LiteralPath $Path -IsValid -ErrorAction Stop)) {
      return $false
    }

    return $true
  } catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
}

rule -Individual /Configuration/DefaultMemberOptions/DefaultMemberOption $constrainedString @{
  Pattern   = "^[A-Za-z0-9 .\-+()]+$"
  MinLength = 1
  MaxLength = 40
}
rule -Aggregate /Configuration/DefaultMemberOptions/DefaultMemberOption $uniqueness

rule -Individual /Configuration/IgnoreList/IgnoreListItem $constrainedString @{
  Pattern   = "^[A-Za-z0-9 .\-+()]+$"
  MinLength = 1
  MaxLength = 40
}
rule -Individual /Configuration/IgnoreList/IgnoreListItem {
  $defaultMemberOptions = $node.SelectNodes("/Configuration/DefaultMemberOptions/DefaultMemberOption") |
                            ForEach-Object InnerXml

  if ($nodeValue -in $defaultMemberOptions) {
    throw "No item may appear in both the DefaultMemberOptions and the IgnoreList."
  }
}
rule -Aggregate /Configuration/IgnoreList/IgnoreListItem $uniqueness

rule -Individual /Configuration/PhysHostNameOverride {
  if (-not (Test-StartVMIsValidComputerName -Name $nodeValue)) {
    throw "A valid windows computer name consisting only of letters, numbers, and interior hyphens is expected in this context. To support the most common use case, this computer name may be no more than 14 characters in length."
  }
}

rule -Individual /Configuration/Resources/Online/ServerOptions/ServerOption {
  if (Test-StartVMIsValidComputerName -Name $nodeValue) {
    return
  }

  $ipCast = $null

  $isIp = [ipaddress]::TryParse($nodeValue, [ref]$ipCast)

  if ($isIp -and $ipCast.AddressFamily -eq "InterNetwork") {
    return
  }

  throw "Each ResourceServerOption must be a valid computer name or ipv4 address."
}
rule -Aggregate /Configuration/Resources/Online/ServerOptions/ServerOption $uniqueness

rule -Individual /Configuration/Resources/Offline/ModulesSourcePath $offlineSourcePath

rule -Individual /Configuration/Resources/Offline/PackagesSourcePath $offlineSourcePath