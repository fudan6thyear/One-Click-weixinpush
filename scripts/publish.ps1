param(
    [Parameter(Position = 0)]
    [string]$File,
    [Parameter(Position = 1)]
    [string]$Theme = "lapis",
    [Parameter(Position = 2)]
    [string]$Highlight = "solarized-light",
    [string]$ToolsFile = "$HOME\.openclaw\workspace\TOOLS.md",
    [switch]$AutoCover,
    [switch]$NoAutoCover,
    [string]$AiBaseUrl = "https://yunwu.ai",
    [string]$AiModel = "doubao-seedream-5-0-260128",
    [string]$AiApiKey = $env:YUNWU_API_KEY,
    [switch]$SkipInstall,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

function Show-Help {
    @"
Usage:
  .\scripts\publish.ps1 <markdown-file> [theme] [highlight]

Examples:
  .\scripts\publish.ps1 .\example.md
  .\scripts\publish.ps1 .\article.md lapis solarized-light
  .\scripts\publish.ps1 .\article.md -ToolsFile "C:\path\TOOLS.md"
  .\scripts\publish.ps1 .\article.md -NoAutoCover

Options:
  -ToolsFile    TOOLS.md path, default: $HOME\.openclaw\workspace\TOOLS.md
  -AutoCover    Deprecated. Auto cover is enabled by default.
  -NoAutoCover  Skip AI cover generation for this publish
  -AiBaseUrl    AI API base URL, default: https://yunwu.ai
  -AiModel      AI image model, default: doubao-seedream-5-0-260128
  -AiApiKey     AI API key (or set env: YUNWU_API_KEY)
  -SkipInstall  Deprecated. Kept for backward compatibility only.
  [theme] [highlight] are accepted for backward compatibility only and do not affect built-in rendering
  -Help         Show this help
"@ | Write-Host
}

try {
    if ($Help -or [string]::IsNullOrWhiteSpace($File)) {
        Show-Help
        exit 0
    }

    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "publish-direct.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "publish-direct.ps1 not found at $scriptPath"
    }

    Write-Host "publish.ps1 is now a compatibility wrapper around publish-direct.ps1." -ForegroundColor Yellow
    if ($SkipInstall) {
        Write-Host "-SkipInstall is deprecated and ignored." -ForegroundColor Yellow
    }
    if ($AutoCover -and $NoAutoCover) {
        throw "Use either -AutoCover or -NoAutoCover, not both."
    }

    & $scriptPath "$File" "$Theme" "$Highlight" -ToolsFile "$ToolsFile" -AiBaseUrl "$AiBaseUrl" -AiModel "$AiModel" -AiApiKey "$AiApiKey" @(
        if ($AutoCover) { '-AutoCover' }
        if ($NoAutoCover) { '-NoAutoCover' }
    )
    exit $LASTEXITCODE
}
catch {
    Write-Host "Publish failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
