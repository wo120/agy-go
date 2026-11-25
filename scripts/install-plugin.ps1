$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$TargetDir = Join-Path $env:USERPROFILE ".gemini\config\plugins\agy-remote"

Write-Host "[agy-remote] Building Windows Go binary (agy-remote.exe)..."
$BinDir = Join-Path $RepoRoot "plugin\bin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

Push-Location (Join-Path $RepoRoot "bridge")
try {
    if (-not $env:GOTOOLCHAIN) { $env:GOTOOLCHAIN = "auto" }
    & go build -o (Join-Path $BinDir "agy-remote.exe") ./cmd/agy-bridge
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}

Write-Host "[agy-remote] Installing plugin bundle to $TargetDir ..."
New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
foreach ($sub in @("assets", "bin", "rules", "sidecars", "skills")) {
    $dest = Join-Path $TargetDir $sub
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Copy-Item -Recurse -Force (Join-Path $RepoRoot "plugin\$sub") $dest
}
Copy-Item -Force (Join-Path $RepoRoot "plugin\plugin.json") $TargetDir

# Patch installed manifests to invoke agy-remote.exe on Windows while keeping git tree clean.
(Get-Content -Raw (Join-Path $RepoRoot "plugin\mcp_config.json")).Replace('/bin/agy-remote"', '/bin/agy-remote.exe"') |
    Set-Content -NoNewline -Encoding UTF8 (Join-Path $TargetDir "mcp_config.json")
(Get-Content -Raw (Join-Path $RepoRoot "plugin\hooks.json")).Replace('./bin/agy-remote ', './bin/agy-remote.exe ') |
    Set-Content -NoNewline -Encoding UTF8 (Join-Path $TargetDir "hooks.json")
(Get-Content -Raw (Join-Path $RepoRoot "plugin\sidecars\remote\sidecar.json")).Replace('../../bin/agy-remote"', '../../bin/agy-remote.exe"') |
    Set-Content -NoNewline -Encoding UTF8 (Join-Path $TargetDir "sidecars\remote\sidecar.json")

# Gracefully terminate any running old sidecar binary so Antigravity respawns the new build.
Get-CimInstance Win32_Process -Filter "Name = 'agy-remote.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*sidecar*" } |
    ForEach-Object {
        Write-Host "[agy-remote] Restarting running sidecar PID $($_.ProcessId)..."
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

Write-Host "[agy-remote] Installed successfully at $TargetDir"
