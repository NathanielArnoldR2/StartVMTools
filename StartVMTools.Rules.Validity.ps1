$actionSetCount = $OutputXml.SelectNodes("/Configuration/ActionSets/ActionSet").Count

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

$memberNameConstraint = @{
  Pattern   = "^[A-Za-z0-9 .\-+()]+$"
  MinLength = 1
  MaxLength = 40
}
$memberRequiredAtLeastOne = {

  $required = @(
    $nodeListValues |
      Where-Object {$_ -eq 'true'}
  )

  if ($required.Count -eq 0) {
    throw "At least one member must be required; they may not all be optional."
  }
}

$configRdpNullables = {
  $config = $node.SelectSingleNode("..").Config

  if ($config -eq 'false' -and $nodeValue.Length -gt 0) {
    throw "Redirection properties may not be specified when 'Config' property is 'false'."
  }
  elseif ($config -eq 'false') {
    $node.$valProp = 'n/a'
    return
  }

  if ($config -eq 'true' -and $nodeValue.Length -eq 0) {
    throw "Redirection properties must be specified when 'Config' property is 'true'."
  }
}

rule -Individual /Configuration/Name $constrainedString @{
  Pattern   = "^[A-Za-z0-9 ]+$"
  MinLength = 1
  MaxLength = 27
}

#region /Configuration/Members
rule -Individual /Configuration/Members/Member/@Name $constrainedString $memberNameConstraint
rule -Aggregate /Configuration/Members/Member/@Name $uniqueness

rule -Aggregate /Configuration/Members/Member/@Required `
     -PrereqScript {
  $nodeListValues.Count -gt 0
} `
     -Script $memberRequiredAtLeastOne
#endregion

rule -Aggregate /Configuration/ActionSets/ActionSet/@Context $uniqueness

rule -Individual /Configuration/ActionSets/ActionSet/@UseEnhancedSessionMode {
  $context = $node.SelectSingleNode("..").Context

  $applicableContexts = @(
    "Start"
    "Restore"
  )

  # Unless Enhanced Session Mode is explicitly indicated, it is disabled.
  if ($nodeValue.Length -eq 0 -and $context -in $applicableContexts) {
    $node.$valProp = 'false'
  }

  # Enhanced Session Mode is not applicable to contexts n/e 'Start'.
  elseif ($nodeValue.Length -eq 0) {
    $node.$valProp = 'n/a'
  }

  # Schema restricts possible non-empty values to 'true' and 'false'.
  # Regardless, since neither of these values are applicable to
  # contexts -ne 'Start', we throw an error.
  elseif ($context -notin $applicableContexts) {
    throw "The 'UseEnhancedSessionMode' setting is relevant only for 'Start' and 'Restore' context actionsets, and should not be specified otherwise."
  }
}

#region /Configuration/ActionSets/ActionSet/Members

# Inherit Members list from Configuration, if indicated and possible.
rule -Individual /Configuration/ActionSets/ActionSet/Members `
     -PrereqScript {
  $nodeValue.Length -eq 0
} `
     -Script {
  $cfgMembers = $node.SelectSingleNode("/Configuration/Members")

  if ($cfgMembers.InnerXml.Length -gt 0) {
    $node.$valProp = $cfgMembers.InnerXml
  }
  else {
    throw "Each actionset must have a list of members. If none are directly attached to the actionset, they may be inherited from the list attached to the wider configuration."
  }
}

rule -Individual /Configuration/ActionSets/ActionSet/Members/Member/@Name $constrainedString $memberNameConstraint

foreach ($i_actionSet in 1..$actionSetCount) {
  rule -Aggregate /Configuration/ActionSets/ActionSet[$i_actionSet]/Members/Member/@Name $uniqueness
  rule -Aggregate /Configuration/ActionSets/ActionSet[$i_actionSet]/Members/Member/@Required $memberRequiredAtLeastOne
}

#endregion

#region /Configuration/ActionSets/ActionSet/Actions

# -- VALIDATE All Action Targets.
rule -Individual /Configuration/ActionSets/ActionSet/Actions/Action[@Target] {
  $memberNames = @(
    $node.SelectNodes("../../Members/Member/@Name") |
      ForEach-Object '#text'
  )

  $target = $memberNames |
              Where-Object {$_ -eq $node.Target}

  # If the actionset targets only one member, it needn't be made explicit when
  # defining any action. To assist in 'RunUpdateAsTest' and auto-'ConfigHw'-
  # related actions transformations, we delay actually populating this value
  # until we're ready to confirm readiness.
  if ($node.Target.Length -eq 0 -and $memberNames.Count -eq 1) {
    return
  }

  if ($node.Target.Length -eq 0) {
    throw "When an actionset has more than one member, the target of each action must be specified where applicable."
  }

  # By replacing the provided value with that from the Members list, we enforce canonical capitalization.
  if ($target -is [string]) {
    $node.SetAttribute("Target", $target)
  }
  else {
    throw "The target of this action was not the name of a member associated with this actionset."
  }
}

# -- TRANSFORM Restore CheckpointName to CheckpointMap
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='RestoreCheckpointAction'][CheckpointName]" {
  $memberNames = @(
    $node.SelectNodes("../../Members/Member/@Name") |
      ForEach-Object '#text'
  )

  $checkpointName = $node.CheckpointName

  $node.RemoveChild(
    $node.SelectSingleNode("CheckpointName")
  )

  $mapNode = $node.AppendChild(
    $node.OwnerDocument.CreateElement("CheckpointMap")
  )

  foreach ($member in $memberNames) {
    $itemNode = $mapNode.AppendChild(
      $node.OwnerDocument.CreateElement("CheckpointMapItem")
    )

    $itemNode.SetAttribute("Target", $member)
    $itemNode.SetAttribute("CheckpointName", $checkpointName)
  }
}

# -- VALIDATE CheckpointMap (Individual Attributes)
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='RestoreCheckpointAction']/CheckpointMap/CheckpointMapItem/@Target" {
  $memberNames = @(
    $node.SelectNodes("../../../../../Members/Member/@Name") |
      ForEach-Object '#text'
  )

  if ($nodeValue -notin $memberNames) {
    throw "Each item in a checkpoint map must refer to a member of the actionset in which it appears."
  }
}
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='RestoreCheckpointAction']/CheckpointMap/CheckpointMapItem/@CheckpointName" `
     -PrereqScript {
  $nodeValue.Length -gt 0
} `
     -Script $constrainedString `
     -Params @{
  Pattern   = "^[A-Za-z0-9 ]+$"
  MinLength = 3
  MaxLength = 14
}

# -- VALIDATE Inject Action
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='InjectAction']/UseResourceServer" {
  $packages = $node.SelectNodes("../Packages/Package")

  if ($nodeValue.Length -eq 0) {
    $node.$valProp = ($packages.Count -gt 0).ToString().ToLower()
    return
  }

  if ($packages.Count -gt 0 -and $nodeValue -eq 'false') {
    throw "The 'UseResourceServer' setting must not be set to 'false' when an 'Inject' action includes packages for staging."
  }
}
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='InjectAction']/Packages/Package" $constrainedString @{
  Pattern   = "^[A-Za-z0-9 .\-+()]+$"
  MinLength = 1
  MaxLength = 30
}

# -- VALIDATE ConfigHw Action
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='ConfigHwAction']/ProcessorCount" `
     -Script {
  # Via schema, already validated as unsigned byte; for validity, then, we
  # need only make sure it's -gt 0.
  if ([int]$nodeValue -eq 0) {
    throw "ProcessorCount must be greater than 0."
  }
}
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='ConfigHwAction']/MemoryBytes" `
     -Script {
  if ([int64]$nodeValue -ne 512mb -and ([int64]$nodeValue % 1gb) -ne 0) {
    throw "MemoryBytes must be exactly 512mb or an exact multiple of 1gb."
  }
}
rule -Individual "Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='ConfigHwAction']/NetworkAdapters/NetworkAdapter" `
     -Script $constrainedString `
     -Params @{
  Pattern   = "^[A-Za-z0-9 ]+$"
  MinLength = 3
  MaxLength = 20
}

# -- VALIDATE Wait Action
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='WaitAction']/Seconds" `
     -Script {
  # Via schema, already validated as unsigned byte; for validity, then, we
  # need only make sure it's -gt 0.
  if ([int]$nodeValue -eq 0) {
    throw "Seconds must be greater than 0."
  }
}

# -- VALIDATE TakeCheckpoint Action
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='TakeCheckpointAction']/CheckpointName" `
     -PrereqScript {
  $nodeValue.Length -gt 0
} `
     -Script $constrainedString `
     -Params @{
  Pattern   = "^[A-Za-z0-9 ]+$"
  MinLength = 3
  MaxLength = 13
}

# -- VALIDATE ApplyOffline Action (should only be applied via transformation of Inject action)
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='ApplyOfflineAction']/Packages/Package" $constrainedString @{
  Pattern   = "^[A-Za-z0-9 .\-+()]+$"
  MinLength = 1
  MaxLength = 30
}

rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='ConfigRdpAction']/RedirectAudio" $configRdpNullables
rule -Individual "/Configuration/ActionSets/ActionSet/Actions/Action[@xsi:type='ConfigRdpAction']/RedirectMicrophone" $configRdpNullables

foreach ($i_actionSet in 1..$actionSetCount) {

$actionsCount = $OutputXml.SelectNodes("/Configuration/ActionSets/ActionSet[$i_actionSet]/Actions/Action").Count

foreach ($i_action in 1..$actionsCount) {

rule -Aggregate "/Configuration/ActionSets/ActionSet[$i_actionSet]/Actions/Action[$i_action][@xsi:type='RestoreCheckpointAction']/CheckpointMap/CheckpointMapItem/@Target" $uniqueness

# Actions of type -ne RestoreCheckpointAction will return an empty nodeList,
# which need to be excluded from comparison. Schema validates Actions of type
# RestoreCheckpointAction to have a non-empty CheckpointMap.
rule -Aggregate "/Configuration/ActionSets/ActionSet[$i_actionSet]/Actions/Action[$i_action][@xsi:type='RestoreCheckpointAction']/CheckpointMap/CheckpointMapItem/@Target" `
     -PrereqScript {
  $nodeList.Count -gt 0
} `
     -Script {
  $members = $nodeList[0].SelectNodes("../../../../../Members/Member")

  if ($nodeList.Count -ne $members.Count) {
    throw "A checkpoint map must include an item for every member in its actionset."
  }
}

rule -Aggregate "/Configuration/ActionSets/ActionSet[$i_actionSet]/Actions/Action[$i_action][@xsi:type='InjectAction']/Packages/Package" $uniqueness

rule -Aggregate "/Configuration/ActionSets/ActionSet[$i_actionSet]/Actions/Action[$i_action][@xsi:type='ApplyOfflineAction']/Packages/Package" $uniqueness
}
}

#endregion

#region Restrictions on Actions and Members per-Context

# Ideally, the actions content of each actionset context would be validated
# more precisely, but I haven't found a way to do it that wouldn't be super
# verbose and difficult to maintain.
rule -Individual /Configuration/ActionSets/ActionSet {
  if ($node.Context -eq "Test") {
    throw "Handling for 'Test' Context has not been implemented."
  }

  $actions = $node.SelectNodes("Actions/Action")

  if ($node.Context -eq "Config") {
    $allowedTypes = @(
      "RestoreCheckpointAction"
      "ConfigHwAction"
      "CustomAction"
      "StartAction"
      "InjectAction"
      "StopAction"
      "TakeCheckpointAction"
    )

    $badActions = @(
      $actions |
        Where-Object type -notin $allowedTypes
    )

    if ($badActions.Count -gt 0) {
      throw "The 'Config' actionset contained one or more actions of a type inappropriate for its context."
    }

    if ($actions[0].type -ne "RestoreCheckpointAction") {
      throw "The first action of a 'Config' context actionset must be a RestoreCheckpoint action."
    }

    $restoreNotToTop = @(
      $actions[0].CheckpointMap.CheckpointMapItem.CheckpointName |
        Where-Object Length -gt 0
    )

    if ($restoreNotToTop.Count -gt 0) {
      throw "The RestoreCheckpoint action in a 'Config' context actionset must restore the top checkpoint."
    }

    if ($actions[$actions.Count - 1].type -ne "TakecheckpointAction") {
      throw "The last action of a 'Config' context actionset must be a TakeCheckpoint action."
    }

    if ($actions[$actions.Count - 1].CheckpointName.Length -eq 0) {
      throw "The TakeCheckpoint action in a 'Config' context actionset must specify a checkpoint name."
    }
  }

  if ($node.Context -eq "Start") {
    $allowedTypes = @(
      "RestoreCheckpointAction"
      "ConfigHwAction"
      "ConfigRdpAction"
      "CustomAction"
      "StartAction"
      "InjectAction"
      "ConnectAction"
    )

    $badActions = @(
      $actions |
        Where-Object type -notin $allowedTypes
    )

    if ($badActions.Count -gt 0) {
      throw "The 'Start' actionset contained one or more actions of a type inappropriate for its context."
    }

    if ($actions[0].type -ne "RestoreCheckpointAction") {
      throw "The first action of a 'Start' context actionset must be a RestoreCheckpoint action."
    }

    if ($actions[$actions.Count - 1].type -ne "ConnectAction") {
      throw "The last action of a 'Start' context actionset must be a Connect action."
    }
  }

  if ($node.Context -eq "Save") {
    $allowedTypes = @(
      "SaveIfNeededAction"
      "TakeCheckpointAction"
    )

    $badActions = @(
      $actions |
        Where-Object type -notin $allowedTypes
    )

    if ($badActions.Count -gt 0) {
      throw "The 'Config' actionset contained one or more actions of a type inappropriate for its context."
    }

    if ($actions[$actions.Count - 1].type -ne "TakecheckpointAction") {
      throw "The last action of a 'Save' context actionset must be a TakeCheckpoint action."
    }
  }

  if ($node.Context -eq "Restore") {
    $allowedTypes = @(
      "RestoreCheckpointAction"
      "ConfigRdpAction"
      "StartAction"
      "InjectAction"
      "ConnectAction"
    )

    $badActions = @(
      $actions |
        Where-Object type -notin $allowedTypes
    )

    if ($badActions.Count -gt 0) {
      throw "The 'Start' actionset contained one or more actions of a type inappropriate for its context."
    }

    if ($actions[0].type -ne "RestoreCheckpointAction") {
      throw "The first action of a 'Start' context actionset must be a RestoreCheckpoint action."
    }

    $restoreToTop = @(
      $actions[0].CheckpointMap.CheckpointMapItem.CheckpointName |
        Where-Object Length -eq 0
    )

    if ($restoreToTop.Count -gt 0) {
      throw "The RestoreCheckpoint action in a 'Restore' context actionset must not restore the top checkpoint."
    }

    if ($actions[$actions.Count - 1].type -ne "ConnectAction") {
      throw "The last action of a 'Start' context actionset must be a Connect action."
    }
  }

  if ($node.Context -eq "Update") {
    $members = @(
      $node.Members.Member
    )

    if ($members.Count -ne 1) {
      throw "An 'Update' context actionset may target only one member."
    }

    $allowedTypes = @(
      "RestoreCheckpointAction"
      "CleanAction"
      "CustomAction"
      "StartAction"
      "InjectAction"
      "StopAction"
      "ReplaceCheckpointAction"
    )

    $badActions = @(
      $actions |
        Where-Object type -notin $allowedTypes
    )

    if ($badActions.Count -gt 0) {
      throw "The 'Update' actionset contained one or more actions of a type inappropriate for its context."
    }

    if ($actions[0].type -ne "RestoreCheckpointAction") {
      throw "The first action of an 'Update' context actionset must be a RestoreCheckpoint action."
    }

    $restoreNotToTop = @(
      $actions[0].CheckpointMap.CheckpointMapItem.CheckpointName |
        Where-Object Length -gt 0
    )

    if ($restoreNotToTop.Count -gt 0) {
      throw "The RestoreCheckpoint action in an 'Update' context actionset must restore the top checkpoint."
    }

    if ($actions[1].type -ne "CleanAction") {
      throw "The second action of an 'Update' context actionset must be a Clean action."
    }

    if ($actions[$actions.Count - 1].type -ne "ReplaceCheckpointAction") {
      throw "The last action of an 'Update' context actionset must be a ReplaceCheckpoint action."
    }
  }

  if ($node.Context -eq "Custom") {
    $allowedTypes = @(
      "RestoreCheckpointAction"
      "ConfigHwAction"
      "CustomAction"
      "StartAction"
      "InjectAction"
      "WaitAction"
      "StopAction"
      "ConnectAction"
    )

    $badActions = @(
      $actions |
        Where-Object type -notin $allowedTypes
    )

    if ($badActions.Count -gt 0) {
      throw "The 'Update' actionset contained one or more actions of a type inappropriate for its context."
    }

    if ($actions[0].type -ne "RestoreCheckpointAction") {
      throw "The first action of a 'Config' context actionset must be a RestoreCheckpoint action."
    }
  }
}
#endregion