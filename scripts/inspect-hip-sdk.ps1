Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifactRoot = Join-Path $repoRoot 'artifacts'
$downloadsDir = Join-Path $artifactRoot 'downloads'
$logsDir = Join-Path $artifactRoot 'logs'
$metadataDir = Join-Path $artifactRoot 'metadata'
$inventoryDir = Join-Path $artifactRoot 'inventory'
$treesDir = Join-Path $artifactRoot 'trees'

$null = New-Item -ItemType Directory -Force -Path @(
  $artifactRoot,
  $downloadsDir,
  $logsDir,
  $metadataDir,
  $inventoryDir,
  $treesDir
)

$failures = [System.Collections.Generic.List[string]]::new()

function Save-Lines {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [object[]]$Lines
  )

  $parent = Split-Path -Parent $Path
  if ($parent) {
    $null = New-Item -ItemType Directory -Force -Path $parent
  }

  $content = foreach ($line in $Lines) {
    if ($null -eq $line) {
      ''
    }
    else {
      [string]$line
    }
  }

  Set-Content -Path $Path -Value $content -Encoding utf8
}

function Save-Json {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    $Value
  )

  $parent = Split-Path -Parent $Path
  if ($parent) {
    $null = New-Item -ItemType Directory -Force -Path $parent
  }

  $Value | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding utf8
}

function Record-Failure {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [System.Exception]$Exception
  )

  $failures.Add("${Name}: $($Exception.Message)")
}

function Get-OptionalPropertyValue {
  param(
    [Parameter(Mandatory = $true)]
    [object]$InputObject,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName
  )

  $property = $InputObject.PSObject.Properties[$PropertyName]
  if ($null -eq $property) {
    return $null
  }

  return $property.Value
}

function Get-WebResponseUriString {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Response
  )

  if ($null -ne $Response.BaseResponse) {
    $baseResponseUri = Get-OptionalPropertyValue -InputObject $Response.BaseResponse -PropertyName 'ResponseUri'
    if ($baseResponseUri) {
      return [string]$baseResponseUri
    }

    $requestMessage = Get-OptionalPropertyValue -InputObject $Response.BaseResponse -PropertyName 'RequestMessage'
    if ($requestMessage) {
      $requestUri = Get-OptionalPropertyValue -InputObject $requestMessage -PropertyName 'RequestUri'
      if ($requestUri) {
        return [string]$requestUri
      }
    }
  }

  return $null
}

function Save-ResponseHeaders {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [object]$Response
  )

  $headers = @()
  foreach ($headerName in $Response.Headers.Keys) {
    $headers += "${headerName}: $($Response.Headers[$headerName])"
  }
  Save-Lines -Path $Path -Lines $headers
}

function Save-TextPreview {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
  )

  try {
    $previewLines = Get-Content -Path $InputPath -TotalCount 120 -ErrorAction Stop
    if ($previewLines) {
      Save-Lines -Path $OutputPath -Lines $previewLines
    }
  }
  catch {
    Record-Failure -Name "preview:$InputPath" -Exception $_.Exception
  }
}

function Get-LicenseFormBody {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Html,
    [Parameter(Mandatory = $true)]
    [string]$Filename
  )

  $body = @{}
  $inputMatches = [System.Text.RegularExpressions.Regex]::Matches(
    $Html,
    '<input[^>]+type="hidden"[^>]+name="(?<name>[^"]+)"[^>]+value="(?<value>[^"]*)"',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )

  foreach ($match in $inputMatches) {
    $name = $match.Groups['name'].Value
    $value = $match.Groups['value'].Value
    if ($name) {
      $body[$name] = $value
    }
  }

  if (-not $body.ContainsKey('filename')) {
    $body['filename'] = $Filename
  }

  return $body
}

function Invoke-Section {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [scriptblock]$Script
  )

  try {
    & $Script
  }
  catch {
    Record-Failure -Name $Name -Exception $_.Exception
  }
}

function Get-UninstallEntries {
  $registryPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )

  foreach ($registryPath in $registryPaths) {
    Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue |
      Where-Object {
        $displayName = Get-OptionalPropertyValue -InputObject $_ -PropertyName 'DisplayName'
        -not [string]::IsNullOrWhiteSpace($displayName)
      } |
      Select-Object @{
        Name = 'DisplayName'; Expression = { Get-OptionalPropertyValue -InputObject $_ -PropertyName 'DisplayName' }
      }, @{
        Name = 'DisplayVersion'; Expression = { Get-OptionalPropertyValue -InputObject $_ -PropertyName 'DisplayVersion' }
      }, @{
        Name = 'Publisher'; Expression = { Get-OptionalPropertyValue -InputObject $_ -PropertyName 'Publisher' }
      }, @{
        Name = 'InstallDate'; Expression = { Get-OptionalPropertyValue -InputObject $_ -PropertyName 'InstallDate' }
      }, @{
        Name = 'InstallLocation'; Expression = { Get-OptionalPropertyValue -InputObject $_ -PropertyName 'InstallLocation' }
      }, PSPath
  }
}

function Test-PortableExecutable {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $buffer = New-Object byte[] 2
    $read = $stream.Read($buffer, 0, 2)
    return $read -eq 2 -and $buffer[0] -eq 0x4D -and $buffer[1] -eq 0x5A
  }
  finally {
    $stream.Dispose()
  }
}

function Get-SafeName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  return (($Value -replace '[:\\/\s]+', '_').Trim('_'))
}

function Search-Patterns {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Roots,
    [Parameter(Mandatory = $true)]
    [string[]]$Patterns,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
  )

  $matches = foreach ($root in $Roots) {
    foreach ($pattern in $Patterns) {
      Get-ChildItem -Path $root -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue |
        Select-Object @{ Name = 'Root'; Expression = { $root } }, @{ Name = 'Pattern'; Expression = { $pattern } }, FullName, Length
    }
  }

  $uniqueMatches = $matches | Sort-Object FullName -Unique
  Save-Json -Path $OutputPath -Value @($uniqueMatches)
}

function Export-Tree {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Roots
  )

  foreach ($root in $Roots) {
    $safeName = Get-SafeName -Value $root
    $treePath = Join-Path $treesDir "${safeName}.txt"
    $entries = Get-ChildItem -Path $root -Force -Depth 4 -ErrorAction SilentlyContinue |
      Sort-Object FullName |
      Select-Object @{ Name = 'Type'; Expression = { if ($_.PSIsContainer) { 'dir' } else { 'file' } } }, FullName, Length
    $lines = foreach ($entry in $entries) {
      if ($entry.Type -eq 'dir') {
        "[dir]  $($entry.FullName)"
      }
      else {
        "[file] $($entry.FullName) ($($entry.Length) bytes)"
      }
    }
    Save-Lines -Path $treePath -Lines $lines
  }
}

$defaultInstallerUrls = @(
  'https://www.amd.com/en/developer/resources/rocm-hub/eula/licenses.html?filename=AMD-Software-PRO-Edition-25.Q3-WinSvr2022-For-HIP.exe',
  'https://www.amd.com/en/developer/resources/rocm-hub/eula/licenses.html?filename=AMD-Software-PRO-Edition-25.Q3-Win10-Win11-For-HIP.exe'
)

$installerUrls = if ($env:HIP_SDK_INSTALLER_URLS) {
  $env:HIP_SDK_INSTALLER_URLS -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
else {
  $defaultInstallerUrls
}

$installerPath = $null
$selectedInstallerUrl = $null
$installExitCode = $null

Invoke-Section -Name 'system-metadata' -Script {
  Save-Json -Path (Join-Path $metadataDir 'computer-info.json') -Value (Get-ComputerInfo)
  Save-Lines -Path (Join-Path $metadataDir 'env-before.txt') -Lines ((Get-ChildItem Env: | Sort-Object Name) | ForEach-Object { "$($_.Name)=$($_.Value)" })
  Save-Lines -Path (Join-Path $metadataDir 'path-before.txt') -Lines ($env:PATH -split ';')
  Save-Lines -Path (Join-Path $metadataDir 'whoami.txt') -Lines @(
    (whoami),
    (whoami /groups)
  )
}

Invoke-Section -Name 'download-installer' -Script {
  $attempts = @()

  for ($index = 0; $index -lt $installerUrls.Count; $index++) {
    $url = $installerUrls[$index]
    $attemptId = $index + 1
    $downloadPath = Join-Path $downloadsDir ("attempt-${attemptId}.bin")

    try {
      $webSession = $null
      $response = Invoke-WebRequest -Uri $url -MaximumRedirection 10 -OutFile $downloadPath -PassThru -SessionVariable webSession
      Save-ResponseHeaders -Path (Join-Path $downloadsDir ("attempt-${attemptId}-headers.txt")) -Response $response

      $isPortableExecutable = Test-PortableExecutable -Path $downloadPath
      $fileInfo = Get-Item $downloadPath
      $contentType = $response.Headers['Content-Type']
      $finalUri = Get-WebResponseUriString -Response $response

      $attempts += [pscustomobject]@{
        url = $url
        path = $downloadPath
        length = $fileInfo.Length
        finalUri = $finalUri
        contentType = $contentType
        isPortableExecutable = $isPortableExecutable
        phase = 'initial'
      }

      if ($isPortableExecutable) {
        $installerPath = Join-Path $downloadsDir 'hip-sdk-installer.exe'
        Move-Item -Path $downloadPath -Destination $installerPath -Force
        $selectedInstallerUrl = $url
        break
      }

      Save-TextPreview -InputPath $downloadPath -OutputPath (Join-Path $downloadsDir ("attempt-${attemptId}-preview.txt"))

      if ($contentType -like 'text/html*') {
        $html = Get-Content -Path $downloadPath -Raw -ErrorAction Stop
        $filenameMatch = [System.Text.RegularExpressions.Regex]::Match($html, '<input[^>]+name="filename"[^>]+value="(?<filename>[^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $filename = if ($filenameMatch.Success) { $filenameMatch.Groups['filename'].Value } else { [System.IO.Path]::GetFileName(($url -split 'filename=')[-1]) }
        $postBody = Get-LicenseFormBody -Html $html -Filename $filename
        $postPath = Join-Path $downloadsDir ("attempt-${attemptId}-accepted.bin")
        $postResponse = Invoke-WebRequest -Uri $url -Method Post -Body $postBody -WebSession $webSession -MaximumRedirection 10 -OutFile $postPath -PassThru
        Save-ResponseHeaders -Path (Join-Path $downloadsDir ("attempt-${attemptId}-accepted-headers.txt")) -Response $postResponse

        $postFileInfo = Get-Item $postPath
        $postIsPortableExecutable = Test-PortableExecutable -Path $postPath
        $postContentType = $postResponse.Headers['Content-Type']
        $postFinalUri = Get-WebResponseUriString -Response $postResponse

        $attempts += [pscustomobject]@{
          url = $url
          path = $postPath
          length = $postFileInfo.Length
          finalUri = $postFinalUri
          contentType = $postContentType
          isPortableExecutable = $postIsPortableExecutable
          phase = 'accept-post'
        }

        if ($postIsPortableExecutable) {
          $installerPath = Join-Path $downloadsDir 'hip-sdk-installer.exe'
          Move-Item -Path $postPath -Destination $installerPath -Force
          $selectedInstallerUrl = $url
          break
        }

        Save-TextPreview -InputPath $postPath -OutputPath (Join-Path $downloadsDir ("attempt-${attemptId}-accepted-preview.txt"))
      }
    }
    catch {
      $attempts += [pscustomobject]@{
        url = $url
        error = $_.Exception.Message
      }
    }
  }

  Save-Json -Path (Join-Path $metadataDir 'download-attempts.json') -Value $attempts
}

Invoke-Section -Name 'install-hip-sdk' -Script {
  if (-not $installerPath) {
    throw 'No downloadable portable executable installer was obtained from the configured URLs.'
  }

  $installerLog = Join-Path $logsDir 'hip-sdk-install.log'
  $process = Start-Process -FilePath $installerPath -ArgumentList @('-install', '-log', $installerLog) -NoNewWindow -PassThru

  if (-not $process.WaitForExit(2700000)) {
    try {
      $process.Kill($true)
    }
    catch {
      Record-Failure -Name 'kill-installer-after-timeout' -Exception $_.Exception
    }
    throw 'HIP SDK installer timed out after 45 minutes.'
  }

  $installExitCode = $process.ExitCode
  Save-Lines -Path (Join-Path $metadataDir 'install-exit-code.txt') -Lines @("exitCode=$installExitCode", "url=$selectedInstallerUrl")
}

Invoke-Section -Name 'post-install-metadata' -Script {
  Save-Lines -Path (Join-Path $metadataDir 'env-after.txt') -Lines ((Get-ChildItem Env: | Sort-Object Name) | ForEach-Object { "$($_.Name)=$($_.Value)" })
  Save-Lines -Path (Join-Path $metadataDir 'path-after.txt') -Lines ($env:PATH -split ';')

  $uninstallEntries = @(Get-UninstallEntries)
  $amdEntries = $uninstallEntries | Where-Object {
    ((Get-OptionalPropertyValue -InputObject $_ -PropertyName 'DisplayName') -match 'AMD|HIP|ROCm|Radeon') -or
    ((Get-OptionalPropertyValue -InputObject $_ -PropertyName 'Publisher') -match 'AMD')
  }
  Save-Json -Path (Join-Path $metadataDir 'uninstall-entries-amd.json') -Value $amdEntries

  $candidateRoots = @(
    'C:\Program Files\AMD',
    'C:\Program Files\AMD\ROCm',
    'C:\Program Files\AMD\HIP SDK',
    'C:\Program Files\AMD\HIP',
    'C:\hipSDK',
    'C:\AMD'
  ) + ($amdEntries | ForEach-Object { $_.InstallLocation })

  $candidateRoots = $candidateRoots |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.TrimEnd('\\') } |
    Sort-Object -Unique |
    Where-Object { Test-Path $_ }

  Save-Lines -Path (Join-Path $metadataDir 'candidate-roots.txt') -Lines $candidateRoots

  $commandLookups = @(
    'clang++',
    'clang',
    'hipcc',
    'hipconfig',
    'hipInfo'
  ) | ForEach-Object {
    try {
      $command = Get-Command $_ -ErrorAction Stop
      [pscustomobject]@{
        command = $_
        source = $command.Source
        path = $command.Path
        commandType = [string]$command.CommandType
      }
    }
    catch {
      [pscustomobject]@{
        command = $_
        error = $_.Exception.Message
      }
    }
  }
  Save-Json -Path (Join-Path $metadataDir 'command-lookups.json') -Value $commandLookups

  Search-Patterns -Roots $candidateRoots -Patterns @('clang.exe', 'clang++.exe', 'hipcc*', 'hipconfig*', 'hipInfo*') -OutputPath (Join-Path $inventoryDir 'tooling.json')
  Search-Patterns -Roots $candidateRoots -Patterns @('amdhip64*.dll', 'amd_comgr*.dll', 'hiprt*.dll', 'hipblas*.dll', 'hipblaslt*.dll', 'rocblas*.dll', 'rocsolver*.dll', 'rocsparse*.dll') -OutputPath (Join-Path $inventoryDir 'runtime-dlls.json')
  Search-Patterns -Roots $candidateRoots -Patterns @('*.lib', '*.cmake') -OutputPath (Join-Path $inventoryDir 'libs-and-cmake.json')
  Search-Patterns -Roots $candidateRoots -Patterns @('*.h', '*.hpp') -OutputPath (Join-Path $inventoryDir 'headers.json')

  Export-Tree -Roots $candidateRoots
}

Save-Lines -Path (Join-Path $metadataDir 'summary.txt') -Lines @(
  "installerPath=$installerPath",
  "selectedInstallerUrl=$selectedInstallerUrl",
  "installExitCode=$installExitCode",
  '',
  'failures:',
  $failures
)

if ($failures.Count -gt 0) {
  $summary = @(
    'HIP SDK inspection completed with recoverable failures.',
    '',
    'Failures:'
  ) + $failures
  $summary | Out-File -FilePath (Join-Path $artifactRoot 'workflow-summary.txt') -Encoding utf8
}
else {
  'HIP SDK inspection completed without script-level failures.' | Out-File -FilePath (Join-Path $artifactRoot 'workflow-summary.txt') -Encoding utf8
}
