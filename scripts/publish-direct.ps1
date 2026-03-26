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
    [switch]$Help
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-WarnLine([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host $Message -ForegroundColor Red }

function Show-Help {
@"
Usage:
  .\scripts\publish-direct.ps1 <markdown-file> [theme] [highlight]

Examples:
  .\scripts\publish-direct.ps1 .\articles\ico-frt-test.md
  .\scripts\publish-direct.ps1 .\articles\ico-frt-test.md -AutoCover

Options:
  -ToolsFile    TOOLS.md path, default: $HOME\.openclaw\workspace\TOOLS.md
  -AutoCover    Generate AI cover before publish
  -AiBaseUrl    AI API base URL, default: https://yunwu.ai
  -AiModel      AI image model, default: gemini-3-pro-image-preview
  -AiApiKey     AI API key (or set env: YUNWU_API_KEY)
  -Help         Show this help
"@ | Write-Host
}

function Ensure-Command([string]$CommandName, [string]$InstallHint) {
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "$CommandName is required. $InstallHint"
    }
}

function Get-ExportValueFromTools([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
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

function Ensure-Credentials {
    if (-not $env:WECHAT_APP_ID) { $env:WECHAT_APP_ID = Get-ExportValueFromTools -Path $ToolsFile -Name "WECHAT_APP_ID" }
    if (-not $env:WECHAT_APP_SECRET) { $env:WECHAT_APP_SECRET = Get-ExportValueFromTools -Path $ToolsFile -Name "WECHAT_APP_SECRET" }
    if (-not $env:WECHAT_APP_ID -or -not $env:WECHAT_APP_SECRET) {
        throw "Missing WECHAT_APP_ID / WECHAT_APP_SECRET."
    }
}

function Parse-FrontMatter([string]$MarkdownRaw) {
    $result = @{
        title = ""
        cover = ""
        author = ""
        source_url = ""
        digest = ""
    }

    if ($MarkdownRaw -match "(?s)^---\r?\n(.*?)\r?\n---\r?\n?(.*)$") {
        $front = $Matches[1]
        foreach ($line in ($front -split "\r?\n")) {
            if ($line -match "^\s*title\s*:\s*(.+)\s*$") { $result.title = $Matches[1].Trim(" '""") }
            elseif ($line -match "^\s*cover\s*:\s*(.+)\s*$") { $result.cover = $Matches[1].Trim(" '""") }
            elseif ($line -match "^\s*author\s*:\s*(.+)\s*$") { $result.author = $Matches[1].Trim(" '""") }
            elseif ($line -match "^\s*source_url\s*:\s*(.+)\s*$") { $result.source_url = $Matches[1].Trim(" '""") }
            elseif ($line -match "^\s*digest\s*:\s*(.+)\s*$") { $result.digest = $Matches[1].Trim(" '""") }
        }
    }
    return $result
}

function Strip-FrontMatter([string]$MarkdownRaw) {
    if ($MarkdownRaw -match "(?s)^---\r?\n.*?\r?\n---\r?\n?(.*)$") {
        return $Matches[1]
    }
    return $MarkdownRaw
}

function Resolve-PathFromMarkdown([string]$MarkdownFile, [string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if ($PathValue -match "^https?://") { return $PathValue }
    $base = Split-Path -Parent $MarkdownFile
    return [System.IO.Path]::GetFullPath((Join-Path $base $PathValue))
}

function Invoke-CurlJson([string]$Url, [string]$Method = "GET", [string]$BodyJson = "", [int]$MaxTime = 40) {
    $tmpFile = Join-Path $env:TEMP ("curl-json-" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        if ([string]::IsNullOrWhiteSpace($BodyJson)) {
            $output = curl.exe -s --max-time $MaxTime -X $Method $Url
        } else {
            [System.IO.File]::WriteAllText($tmpFile, $BodyJson, (New-Object System.Text.UTF8Encoding($false)))
            $output = curl.exe -s --max-time $MaxTime -X $Method -H "Content-Type: application/json; charset=utf-8" --data-binary "@$tmpFile" $Url
        }
        if ([string]::IsNullOrWhiteSpace($output)) { throw "Empty response from $Url" }
        return $output | ConvertFrom-Json
    } finally {
        if (Test-Path $tmpFile) { Remove-Item -Force $tmpFile }
    }
}

function Get-AccessToken([string]$AppId, [string]$AppSecret) {
    $url = "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid=$AppId&secret=$AppSecret"
    $res = Invoke-CurlJson -Url $url
    if ($res.access_token) { return [string]$res.access_token }
    throw "Token API failed: $($res | ConvertTo-Json -Depth 6 -Compress)"
}

function Upload-Material([string]$AccessToken, [string]$LocalFilePath, [string]$Type = "image") {
    if (-not (Test-Path -LiteralPath $LocalFilePath)) {
        throw "Local file not found: $LocalFilePath"
    }
    $url = "https://api.weixin.qq.com/cgi-bin/material/add_material?access_token=$AccessToken&type=$Type"
    $raw = curl.exe -s --max-time 60 -F "media=@$LocalFilePath" "$url"
    $res = $raw | ConvertFrom-Json
    if ($res.media_id) { return $res }
    throw "Upload material failed: $($res | ConvertTo-Json -Depth 6 -Compress)"
}

function Render-Html([string]$MarkdownFilePath, [string]$ThemeName, [string]$HighlightName) {
    $tempHtml = Join-Path $env:TEMP ("wenyan-render-" + [guid]::NewGuid().ToString("N") + ".html")
    $stderrFile = Join-Path $env:TEMP ("wenyan-render-" + [guid]::NewGuid().ToString("N") + ".stderr.txt")
    try {
        $argLine = "render -f `"$MarkdownFilePath`" -t `"$ThemeName`" -h `"$HighlightName`""
        $proc = Start-Process -FilePath "wenyan" -ArgumentList $argLine -NoNewWindow -RedirectStandardOutput $tempHtml -RedirectStandardError $stderrFile -PassThru
        $finished = $proc.WaitForExit(25000)
        if (-not $finished) {
            try { Stop-Process -Id $proc.Id -Force } catch {}
            throw "wenyan render timeout"
        }
        if ($proc.ExitCode -ne 0) {
            $stderr = ""
            if (Test-Path $stderrFile) { $stderr = [System.IO.File]::ReadAllText($stderrFile, [System.Text.Encoding]::UTF8) }
            throw "wenyan render failed: $stderr"
        }
        return [System.IO.File]::ReadAllText($tempHtml, [System.Text.Encoding]::UTF8)
    } finally {
        if (Test-Path $tempHtml) { Remove-Item -Force $tempHtml }
        if (Test-Path $stderrFile) { Remove-Item -Force $stderrFile }
    }
}

function Escape-Html([string]$Text) {
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

function Apply-InlineMarkdown([string]$Text) {
    $t = $Text
    $t = [regex]::Replace($t, '\*\*(.+?)\*\*', '<strong style="font-weight:bold;color:#1a1a1a;">$1</strong>')
    $t = [regex]::Replace($t, '(?<!\*)\*([^*]+?)\*(?!\*)', '<em style="font-style:italic;">$1</em>')
    $t = [regex]::Replace($t, '`([^`]+?)`', '<code style="font-size:14px;background:#f5f5f5;padding:2px 6px;border-radius:3px;color:#c7254e;font-family:Consolas,monospace;">$1</code>')
    $t = [regex]::Replace($t, '\[([^\]]+)\]\(([^)]+)\)', '<a href="$2" style="color:#576b95;text-decoration:none;border-bottom:1px solid #576b95;">$1</a>')
    $t = [regex]::Replace($t, '!\[[^\]]*\]\(([^)]+)\)', '<img src="$1" style="max-width:100%;border-radius:4px;margin:8px 0;" />')
    return $t
}

function Convert-MarkdownToBasicHtml([string]$MarkdownRaw) {
    $sBody   = 'margin:0;padding:0;'
    $sH1     = 'font-size:22px;font-weight:bold;color:#1a1a1a;text-align:center;margin:28px 0 20px;line-height:1.4;letter-spacing:1px;'
    $sH2     = 'font-size:18px;font-weight:bold;color:#2b2b2b;margin:24px 0 12px;padding-left:12px;border-left:4px solid #576b95;line-height:1.5;'
    $sH3     = 'font-size:16px;font-weight:bold;color:#3f3f3f;margin:20px 0 10px;line-height:1.5;'
    $sP      = 'font-size:15px;color:#3f3f3f;line-height:1.8;margin:10px 0;letter-spacing:0.5px;text-align:justify;'
    $sLi     = 'font-size:15px;color:#3f3f3f;line-height:1.8;margin:6px 0;letter-spacing:0.5px;'
    $sUl     = 'margin:10px 0 10px 20px;padding:0;list-style:disc;'
    $sOl     = 'margin:10px 0 10px 20px;padding:0;list-style:decimal;'
    $sQuote  = 'margin:16px 0;padding:12px 16px;background:#f8f8f8;border-left:4px solid #576b95;color:#666;font-size:14px;line-height:1.7;border-radius:0 4px 4px 0;'
    $sHr     = 'border:none;border-top:1px solid #e5e5e5;margin:24px 0;'
    $sImg    = 'max-width:100%;border-radius:4px;margin:12px auto;display:block;'

    $inList = $false
    $listType = ""
    $inQuote = $false
    $quoteLines = @()
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine("<section style=`"$sBody`">")

    $lines = $MarkdownRaw -split "\r?\n"
    foreach ($lineRaw in $lines) {
        $line = $lineRaw.TrimEnd()

        if ($line -match "^\s*>\s?(.*)$") {
            if ($inList) { [void]$sb.AppendLine("</ul>"); $inList = $false }
            $inQuote = $true
            $quoteLines += $Matches[1]
            continue
        } elseif ($inQuote) {
            $qText = Escape-Html ($quoteLines -join " ")
            $qText = Apply-InlineMarkdown $qText
            [void]$sb.AppendLine("<blockquote style=`"$sQuote`">$qText</blockquote>")
            $inQuote = $false
            $quoteLines = @()
        }

        if ($line -match "^\s*[-*]\s+(.+)$") {
            if (-not $inList) {
                [void]$sb.AppendLine("<ul style=`"$sUl`">")
                $inList = $true; $listType = "ul"
            }
            $li = Escape-Html $Matches[1]
            $li = Apply-InlineMarkdown $li
            [void]$sb.AppendLine("<li style=`"$sLi`">$li</li>")
            continue
        } elseif ($line -match "^\s*(\d+)\.\s+(.+)$") {
            if (-not $inList) {
                [void]$sb.AppendLine("<ol style=`"$sOl`">")
                $inList = $true; $listType = "ol"
            }
            $li = Escape-Html $Matches[2]
            $li = Apply-InlineMarkdown $li
            [void]$sb.AppendLine("<li style=`"$sLi`">$li</li>")
            continue
        } elseif ($inList) {
            $closeTag = if ($listType -eq "ol") { "</ol>" } else { "</ul>" }
            [void]$sb.AppendLine($closeTag)
            $inList = $false
        }

        if ($line -match "^\s*---+\s*$" -or $line -match "^\s*\*\*\*+\s*$") {
            [void]$sb.AppendLine("<hr style=`"$sHr`" />")
        } elseif ($line -match "^\s*###\s+(.+)$") {
            $h = Escape-Html $Matches[1]
            $h = Apply-InlineMarkdown $h
            [void]$sb.AppendLine("<h3 style=`"$sH3`">$h</h3>")
        } elseif ($line -match "^\s*##\s+(.+)$") {
            $h = Escape-Html $Matches[1]
            $h = Apply-InlineMarkdown $h
            [void]$sb.AppendLine("<h2 style=`"$sH2`">$h</h2>")
        } elseif ($line -match "^\s*#\s+(.+)$") {
            $h = Escape-Html $Matches[1]
            $h = Apply-InlineMarkdown $h
            [void]$sb.AppendLine("<h1 style=`"$sH1`">$h</h1>")
        } elseif ([string]::IsNullOrWhiteSpace($line)) {
            continue
        } else {
            $p = Escape-Html $line
            $p = Apply-InlineMarkdown $p
            [void]$sb.AppendLine("<p style=`"$sP`">$p</p>")
        }
    }

    if ($inQuote -and $quoteLines.Count -gt 0) {
        $qText = Escape-Html ($quoteLines -join " ")
        $qText = Apply-InlineMarkdown $qText
        [void]$sb.AppendLine("<blockquote style=`"$sQuote`">$qText</blockquote>")
    }
    if ($inList) {
        $closeTag = if ($listType -eq "ol") { "</ol>" } else { "</ul>" }
        [void]$sb.AppendLine($closeTag)
    }

    [void]$sb.AppendLine("</section>")
    return $sb.ToString()
}

function Download-TempFile([string]$Url) {
    $ext = ".tmp"
    if ($Url -match "\.png($|\?)") { $ext = ".png" }
    elseif ($Url -match "\.jpe?g($|\?)") { $ext = ".jpg" }
    elseif ($Url -match "\.webp($|\?)") { $ext = ".webp" }
    $path = Join-Path $env:TEMP ("img-" + [guid]::NewGuid().ToString("N") + $ext)
    Invoke-WebRequest -Uri $Url -OutFile $path -TimeoutSec 40
    return $path
}

function Replace-ImageSources([string]$Html, [string]$MarkdownPath, [string]$AccessToken) {
    $regex = [regex]'(?is)<img\b[^>]*?\bsrc\s*=\s*["''](?<src>[^"'']+)["''][^>]*>'
    $matches = $regex.Matches($Html)
    $updated = $Html

    foreach ($m in $matches) {
        $src = $m.Groups["src"].Value
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        if ($src -like "https://mmbiz.qpic.cn*") { continue }
        if ($src -like "data:*") { continue }

        $tempDownloaded = $null
        try {
            if ($src -match "^https?://") {
                $tempDownloaded = Download-TempFile -Url $src
                $upload = Upload-Material -AccessToken $AccessToken -LocalFilePath $tempDownloaded -Type "image"
            } else {
                $local = Resolve-PathFromMarkdown -MarkdownFile $MarkdownPath -PathValue $src
                $upload = Upload-Material -AccessToken $AccessToken -LocalFilePath $local -Type "image"
            }
            $newUrl = [string]$upload.url
            if ($newUrl -like "http://*") { $newUrl = $newUrl -replace "^http://", "https://" }
            $updated = $updated.Replace($src, $newUrl)
        } finally {
            if ($tempDownloaded -and (Test-Path $tempDownloaded)) {
                Remove-Item -Force $tempDownloaded
            }
        }
    }
    return $updated
}

function Publish-Draft([string]$AccessToken, [hashtable]$Article) {
    $url = "https://api.weixin.qq.com/cgi-bin/draft/add?access_token=$AccessToken"
    $payload = @{
        articles = @(
            @{
                title = $Article.title
                author = $Article.author
                digest = $Article.digest
                content = $Article.content
                content_source_url = $Article.content_source_url
                thumb_media_id = $Article.thumb_media_id
                need_open_comment = 0
                only_fans_can_comment = 0
            }
        )
    } | ConvertTo-Json -Depth 10 -Compress
    $res = Invoke-CurlJson -Url $url -Method "POST" -BodyJson $payload -MaxTime 60
    if ($res.media_id) { return $res }
    throw "Draft add failed: $($res | ConvertTo-Json -Depth 6 -Compress)"
}

try {
    if ($Help -or [string]::IsNullOrWhiteSpace($File)) {
        Show-Help
        exit 0
    }

    Ensure-Command -CommandName "node" -InstallHint "Install Node.js first."
    Ensure-Command -CommandName "wenyan" -InstallHint "Install with: npm install -g @wenyan-md/cli"
    Ensure-Command -CommandName "curl.exe" -InstallHint "curl is required on Windows."
    Ensure-Credentials

    $resolvedMarkdown = (Resolve-Path -LiteralPath $File).Path
    if (-not (Test-Path -LiteralPath $resolvedMarkdown -PathType Leaf)) {
        throw "Markdown file not found: $File"
    }

    if ($AutoCover) {
        if ([string]::IsNullOrWhiteSpace($AiApiKey)) {
            throw "Auto cover requires -AiApiKey or env YUNWU_API_KEY."
        }
        $coverScript = Join-Path -Path $PSScriptRoot -ChildPath "generate-cover.ps1"
        Write-Info "Auto cover enabled. Generating cover..."
        & $coverScript -MarkdownFile "$resolvedMarkdown" -BaseUrl "$AiBaseUrl" -Model "$AiModel" -ApiKey "$AiApiKey"
        if ($LASTEXITCODE -ne 0) {
            throw "Cover generation failed."
        }
    }

    $raw = [System.IO.File]::ReadAllText($resolvedMarkdown, [System.Text.Encoding]::UTF8)
    $fm = Parse-FrontMatter -MarkdownRaw $raw
    if ([string]::IsNullOrWhiteSpace($fm.title)) {
        throw "Frontmatter title is required."
    }
    if ([string]::IsNullOrWhiteSpace($fm.cover)) {
        throw "Frontmatter cover is required."
    }

    Write-Info "Fetching access token..."
    $token = Get-AccessToken -AppId $env:WECHAT_APP_ID -AppSecret $env:WECHAT_APP_SECRET

    Write-Info "Rendering markdown to HTML..."
    try {
        $html = Render-Html -MarkdownFilePath $resolvedMarkdown -ThemeName $Theme -HighlightName $Highlight
    } catch {
        Write-WarnLine "wenyan render unavailable ($($_.Exception.Message)); fallback to basic markdown renderer."
        $bodyOnly = Strip-FrontMatter -MarkdownRaw $raw
        $html = Convert-MarkdownToBasicHtml -MarkdownRaw $bodyOnly
    }
    if ([string]::IsNullOrWhiteSpace($html)) {
        throw "Rendered HTML is empty."
    }

    Write-Info "Uploading inline images and rewriting HTML..."
    $htmlRewritten = Replace-ImageSources -Html $html -MarkdownPath $resolvedMarkdown -AccessToken $token

    $coverPath = Resolve-PathFromMarkdown -MarkdownFile $resolvedMarkdown -PathValue $fm.cover
    if ($coverPath -match "^https?://") {
        $tmpCover = Download-TempFile -Url $coverPath
        try {
            $coverUpload = Upload-Material -AccessToken $token -LocalFilePath $tmpCover -Type "image"
        } finally {
            if (Test-Path $tmpCover) { Remove-Item -Force $tmpCover }
        }
    } else {
        $coverUpload = Upload-Material -AccessToken $token -LocalFilePath $coverPath -Type "image"
    }

    $article = @{
        title = $fm.title
        author = $fm.author
        digest = $fm.digest
        content = $htmlRewritten
        content_source_url = $fm.source_url
        thumb_media_id = [string]$coverUpload.media_id
    }

    Write-Info "Publishing draft to WeChat..."
    $publishRes = Publish-Draft -AccessToken $token -Article $article
    Write-Ok "Publish succeeded. Draft media_id: $($publishRes.media_id)"
    Write-Host "Open https://mp.weixin.qq.com/ to verify."
    exit 0
}
catch {
    Write-Fail "Publish-direct failed: $($_.Exception.Message)"
    exit 1
}
