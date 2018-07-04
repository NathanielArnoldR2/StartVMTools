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

rule -Individual /Data/LastConfigurationName $constrainedString @{
  Pattern   = "^[A-Za-z0-9 ]+$"
  MinLength = 1
  MaxLength = 20
}

# LastActionSetContext is fully validated by schema.


# LastProcessed is fully validated as a [datetime] by the schema. Will consider
# further validation when I determine a use case for this value.