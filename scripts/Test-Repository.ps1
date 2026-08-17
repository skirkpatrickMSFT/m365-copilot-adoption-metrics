param(
    [switch]$SkipBicep
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

$jsonFiles = Get-ChildItem $repoRoot -Recurse -File -Filter '*.json' |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
foreach ($file in $jsonFiles) {
    $null = Get-Content $file.FullName -Raw | ConvertFrom-Json
}
Write-Host "Validated $($jsonFiles.Count) JSON files."

$powerShellFiles = Get-ChildItem $repoRoot -Recurse -File -Filter '*.ps1' |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "PowerShell parse failure in $($file.FullName): $($parseErrors -join '; ')"
    }
}
Write-Host "Validated $($powerShellFiles.Count) PowerShell files."

. (Join-Path $repoRoot 'function-app/CloudEnvironment.ps1')
$expectedClouds = @{
    Commercial = @('https://manage.office.com', 'Global', 'https://graph.microsoft.com')
    GCC = @('https://manage-gcc.office.com', 'Global', 'https://graph.microsoft.com')
    GCCHigh = @('https://manage.office365.us', 'USGov', 'https://graph.microsoft.us')
    DoD = @('https://manage.protection.apps.mil', 'USGovDoD', 'https://dod-graph.microsoft.us')
}
foreach ($cloudName in $expectedClouds.Keys) {
    $cloud = Get-CloudEnvironmentConfiguration -CloudEnvironment $cloudName
    $expected = $expectedClouds[$cloudName]
    if ($cloud.ManagementApi -ne $expected[0] -or
        $cloud.GraphEnvironment -ne $expected[1] -or
        $cloud.GraphBaseUri -ne $expected[2]) {
        throw "Cloud configuration validation failed for $cloudName."
    }
    if ([string]::IsNullOrWhiteSpace($cloud.MonitorAudience) -or
        [string]::IsNullOrWhiteSpace($cloud.StorageSuffix)) {
        throw "Cloud storage or monitoring configuration is incomplete for $cloudName."
    }
}
Write-Host 'Validated all supported cloud configurations.'

if ($SkipBicep) {
    Write-Host 'Repository compatibility validation passed.'
    return
}

$bicepExecutable = Join-Path $HOME '.azure/bin/bicep'
if ($env:OS -eq 'Windows_NT') {
    $bicepExecutable += '.exe'
}
$bicepArgumentPrefix = @()
$bicepFileArgument = @()
if (-not (Test-Path $bicepExecutable)) {
    $azCommand = Get-Command az -ErrorAction Stop
    $bicepExecutable = $azCommand.Source
    $bicepArgumentPrefix = @('bicep')
    $bicepFileArgument = @('--file')
    if ($bicepExecutable -like '*.cmd') {
        $azPython = Join-Path (Split-Path (Split-Path $bicepExecutable -Parent) -Parent) 'python.exe'
        if (Test-Path $azPython) {
            $bicepExecutable = $azPython
            $bicepArgumentPrefix = @('-IBm', 'azure.cli', 'bicep')
        }
    }
}

$generatedTemplate = Join-Path ([System.IO.Path]::GetTempPath()) "copilot-adoption-$([guid]::NewGuid()).json"
$generatedParameters = Join-Path ([System.IO.Path]::GetTempPath()) "copilot-adoption-params-$([guid]::NewGuid()).json"
try {
    & $bicepExecutable @bicepArgumentPrefix build @bicepFileArgument (Join-Path $repoRoot 'infra/main.bicep') --outfile $generatedTemplate
    if ($LASTEXITCODE -ne 0) { throw 'Bicep template compilation failed.' }

    & $bicepExecutable @bicepArgumentPrefix build-params @bicepFileArgument (Join-Path $repoRoot 'infra/main.bicepparam') --outfile $generatedParameters
    if ($LASTEXITCODE -ne 0) { throw 'Bicep parameter compilation failed.' }

    $generated = Get-Content $generatedTemplate -Raw | ConvertFrom-Json
    $published = Get-Content (Join-Path $repoRoot 'infra/azuredeploy.json') -Raw | ConvertFrom-Json
    $generated.metadata.PSObject.Properties.Remove('_generator')
    $published.metadata.PSObject.Properties.Remove('_generator')
    $generatedJson = $generated | ConvertTo-Json -Depth 100 -Compress
    $publishedJson = $published | ConvertTo-Json -Depth 100 -Compress
    if ($generatedJson -ne $publishedJson) {
        throw 'infra/azuredeploy.json is not synchronized with infra/main.bicep.'
    }
}
finally {
    Remove-Item $generatedTemplate, $generatedParameters -Force -ErrorAction SilentlyContinue
}

Write-Host 'Repository validation passed.'