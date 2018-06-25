rule -Individual /Configuration/ActionSets/ActionSet/Members/Member {
  if ($node.Name -in $RuntimeConfig.DisallowedMemberNames) {
    throw "An actionset may not reference by name any vm in the ToolsetConfig IgnoreList or DefaultMemberOptions."
  }

  # To reach this juncture, the Member with Name 'default' will already be
  # verified as having Required -eq 'false' when no candidate is present.
  if ($node.Name -eq 'default' -and $RuntimeConfig.DefaultMemberName -isnot [string]) {
    $node.SetAttribute("Present", 'false')
    return
  }

  if ($node.Name -eq 'default') {
    $vmName = $RuntimeConfig.DefaultMemberName
  }
  else {
    $vmName = $node.Name
  }

  $vms = @(
    Get-VM |
      Where-Object Name -eq $vmName
  )

  if ($vms.Count -gt 1) {
    throw "$($vms.Count) vm(s) were found with name '$vmName'. No more than 1 was expected."
  }

  if ($vms.Count -eq 0 -and $node.Required -eq "true") {
    throw "No vms were found with name '$vmName'. This member is required for realization to proceed."
  }

  $isPresent = $vms.Count -eq 1

  $node.SetAttribute("Present", $isPresent.ToString().ToLower())

  if ($isPresent) {
    $node.SetAttribute("VMName", $vms[0].Name)
    $node.SetAttribute("VMId", $vms[0].Id)
  }
}

rule -Individual "Configuration/ActionSets/ActionSet/Actions/Action" {
  Resolve-StartVMActionsConfiguration_EachAction -Action $node
}