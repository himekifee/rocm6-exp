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
      Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |
      Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation, PSPath
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

  foreach ($index in 0..($installerUrls.Count - 1)) {
    $url = $installerUrls[$index]
    $attemptId = $index + 1
    $downloadPath = Join-Path $downloadsDir ("attempt-${attemptId}.bin")

    try {
      $response = Invoke-WebRequest -Uri $url -MaximumRedirection 10 -OutFile $downloadPath -PassThru
      $headers = foreach ($headerName in $response.Headers.Keys) {
        "${headerName}: $($response.Headers[$headerName])"
      }
      Save-Lines -Path (Join-Path $downloadsDir ("attempt-${attemptId}-headers.txt")) -Lines $headers

      $isPortableExecutable = Test-PortableExecutable -Path $downloadPath
      $fileInfo = Get-Item $downloadPath

      $attempts += [pscustomobject]@{
        url = $url
        path = $downloadPath
        length = $fileInfo.Length
        finalUri = [string]$response.BaseResponse.ResponseUri
        contentType = $response.Headers['Content-Type']
        isPortableExecutable = $isPortableExecutable
      }

      if ($isPortableExecutable) {
        $installerPath = Join-Path $downloadsDir 'hip-sdk-installer.exe'
        Move-Item -Path $downloadPath -Destination $installerPath -Force
        $selectedInstallerUrl = $url
        break
      }

      $previewLines = Get-Content -Path $downloadPath -TotalCount 80 -ErrorAction SilentlyContinue
      if ($previewLines) {
        Save-Lines -Path (Join-Path $downloadsDir ("attempt-${attemptId}-preview.txt")) -Lines $previewLines
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
    $_.DisplayName -match 'AMD|HIP|ROCm|Radeon' -or $_.Publisher -match 'AMD'
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
