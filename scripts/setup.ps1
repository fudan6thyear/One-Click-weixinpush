param(
    [string]$ToolsFile = "$HOME\.openclaw\workspace\TOOLS.md"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Get-ExportValueFromTools([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    $pattern = "^\s*export\s+$Name\s*=\s*(.+)\s*$"
    foreach ($line in $lines) {
        if ($line -match $pattern) {
            $value = $Matches[1].Trim()
            if (($value.StartsWith("'") -and $value.EndsWith("'")) -or ($value.StartsWith('"') -and $value.EndsWith('"'))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return $value.Trim()
        }
    }
    return $null
}

try {
    if (-not (Test-Path -LiteralPath $ToolsFile)) {
        throw "TOOLS.md was not found: $ToolsFile"
    }

    $appId = Get-ExportValueFromTools -Path $ToolsFile -Name "WECHAT_APP_ID"
    $appSecret = Get-ExportValueFromTools -Path $ToolsFile -Name "WECHAT_APP_SECRET"

    if (-not $appId -or -not $appSecret) {
        throw "WECHAT_APP_ID / WECHAT_APP_SECRET not found in TOOLS.md."
    }

    $env:WECHAT_APP_ID = $appId
    $env:WECHAT_APP_SECRET = $appSecret

    Write-Host "WeChat env vars loaded into this session." -ForegroundColor Green
    Write-Host "WECHAT_APP_ID: $($env:WECHAT_APP_ID.Substring(0, [Math]::Min(10, $env:WECHAT_APP_ID.Length)))..." -ForegroundColor Cyan
    Write-Host "WECHAT_APP_SECRET: ******" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Tip: use dot-sourcing if you want variables in current terminal:" -ForegroundColor Yellow
    Write-Host ". .\scripts\setup.ps1" -ForegroundColor Yellow
}
catch {
    Write-Host "Load failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Make sure TOOLS.md includes:" -ForegroundColor Yellow
    Write-Host "export WECHAT_APP_ID=your_app_id" -ForegroundColor Yellow
    Write-Host "export WECHAT_APP_SECRET=your_app_secret" -ForegroundColor Yellow
    exit 1
}
