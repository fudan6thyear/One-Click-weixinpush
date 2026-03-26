param(
    [Parameter(Position = 0)]
    [string]$File,
    [Parameter(Position = 1)]
    [string]$Theme = "lapis",
    [Parameter(Position = 2)]
    [string]$Highlight = "solarized-light",
    [string]$ToolsFile = "$HOME\.openclaw\workspace\TOOLS.md",
    [switch]$AutoCover,
    [string]$AiBaseUrl = "https://yunwu.ai",
    [string]$AiModel = "gemini-3-pro-image-preview",
    [string]$AiApiKey = $env:YUNWU_API_KEY,
    [switch]$SkipInstall,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Info([string]$Message) {
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host $Message -ForegroundColor Green
}

function Write-WarnLine([string]$Message) {
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Fail([string]$Message) {
    Write-Host $Message -ForegroundColor Red
}

function Show-Help {
    @"
Usage:
  .\scripts\publish.ps1 <markdown-file> [theme] [highlight]

Examples:
  .\scripts\publish.ps1 .\example.md
  .\scripts\publish.ps1 .\article.md lapis solarized-light
  .\scripts\publish.ps1 .\article.md -ToolsFile "C:\path\TOOLS.md"

Options:
  -SkipInstall  Skip auto-install of wenyan-cli
  -ToolsFile    TOOLS.md path, default: $HOME\.openclaw\workspace\TOOLS.md
  -AutoCover    Generate AI cover before publish
  -AiBaseUrl    AI API base URL, default: https://yunwu.ai
  -AiModel      AI image model, default: gemini-3-pro-image-preview
  -AiApiKey     AI API key (or set env: YUNWU_API_KEY)
  -Help         Show this help
"@ | Write-Host
}

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

function Ensure-Wenyan {
    if (Get-Command wenyan -ErrorAction SilentlyContinue) {
        return
    }

    if ($SkipInstall) {
        throw "wenyan-cli is not installed. You used -SkipInstall. Install first: npm install -g @wenyan-md/cli"
    }

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw "npm is not available. Install Node.js first."
    }

    Write-WarnLine "wenyan not found. Installing @wenyan-md/cli..."
    npm install -g @wenyan-md/cli
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install wenyan-cli. Run manually: npm install -g @wenyan-md/cli"
    }

    if (-not (Get-Command wenyan -ErrorAction SilentlyContinue)) {
        throw "wenyan command still not found after install. Restart terminal and try again."
    }
}

function Ensure-Credentials {
    if (-not $env:WECHAT_APP_ID) {
        $env:WECHAT_APP_ID = Get-ExportValueFromTools -Path $ToolsFile -Name "WECHAT_APP_ID"
    }
    if (-not $env:WECHAT_APP_SECRET) {
        $env:WECHAT_APP_SECRET = Get-ExportValueFromTools -Path $ToolsFile -Name "WECHAT_APP_SECRET"
    }

    if (-not $env:WECHAT_APP_ID -or -not $env:WECHAT_APP_SECRET) {
        throw @"
Cannot find WeChat credentials.
Use one of these methods:
1) Set env vars in this terminal:
   `$env:WECHAT_APP_ID = "your_app_id"
   `$env:WECHAT_APP_SECRET = "your_app_secret"
2) Add to TOOLS.md:
   export WECHAT_APP_ID=your_app_id
   export WECHAT_APP_SECRET=your_app_secret
Current TOOLS.md path: $ToolsFile
"@
    }
}

function Test-FrontMatter([string]$MarkdownPath) {
    $content = [System.IO.File]::ReadAllText($MarkdownPath, [System.Text.Encoding]::UTF8)
    if (-not ($content -match "(?s)^---\s*?\r?\n.*?\r?\n---")) {
        Write-WarnLine "Warning: no frontmatter detected. wenyan may fail (title/cover required)."
        return
    }
    if ($content -notmatch "(?m)^\s*title\s*:") {
        Write-WarnLine "Warning: frontmatter is missing title."
    }
    if ($content -notmatch "(?m)^\s*cover\s*:") {
        Write-WarnLine "Warning: frontmatter is missing cover."
    }
}

function Invoke-AutoCover([string]$MarkdownPath) {
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "generate-cover.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "generate-cover.ps1 not found at $scriptPath"
    }

    if ([string]::IsNullOrWhiteSpace($AiApiKey)) {
        throw "Auto cover requires -AiApiKey or env YUNWU_API_KEY."
    }

    Write-Info "Auto cover is enabled. Generating cover image..."
    & $scriptPath -MarkdownFile "$MarkdownPath" -BaseUrl "$AiBaseUrl" -Model "$AiModel" -ApiKey "$AiApiKey"
    if ($LASTEXITCODE -ne 0) {
        throw "Cover generation script failed."
    }
}

try {
    if ($Help -or [string]::IsNullOrWhiteSpace($File)) {
        Show-Help
        exit 0
    }

    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        throw "node is not available. Install Node.js first."
    }

    $resolvedFile = Resolve-Path -LiteralPath $File -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolvedFile -PathType Leaf)) {
        throw "File does not exist: $File"
    }

    Ensure-Wenyan
    Ensure-Credentials
    if ($AutoCover) {
        Invoke-AutoCover -MarkdownPath $resolvedFile
    }
    Test-FrontMatter -MarkdownPath $resolvedFile

    Write-Info "Publishing article to WeChat draft box..."
    Write-Host "  File: $resolvedFile"
    Write-Host "  Theme: $Theme"
    Write-Host "  Highlight: $Highlight"
    Write-Host ""

    wenyan publish -f "$resolvedFile" -t "$Theme" -h "$Highlight"
    if ($LASTEXITCODE -ne 0) {
        throw "wenyan publish failed."
    }

    Write-Ok ""
    Write-Ok "Publish succeeded. Article was pushed to WeChat drafts."
    Write-Host "Open https://mp.weixin.qq.com/ to verify."
    exit 0
}
catch {
    Write-Fail "Publish failed: $($_.Exception.Message)"
    Write-WarnLine ""
    Write-WarnLine "Common issues:"
    Write-WarnLine "1) WeChat IP whitelist is not configured (error 45166)"
    Write-WarnLine "2) Markdown frontmatter is missing title/cover"
    Write-WarnLine "3) AppID/AppSecret is invalid"
    Write-WarnLine "4) Cover image path is invalid or size is not acceptable"
    exit 1
}
