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
    [string]$AiModel = "doubao-seedream-5-0-260128",
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
  -AiModel      AI image model, default: doubao-seedream-5-0-260128
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

function Escape-Html([string]$Text) {
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

function Apply-InlineMarkdown([string]$Text) {
    $t = $Text
    $t = [regex]::Replace($t, '\*\*(.+?)\*\*', '<strong style="font-weight:bold;color:#1a1a1a;">$1</strong>')
    $t = [regex]::Replace($t, '(?<!\*)\*([^*]+?)\*(?!\*)', '<em style="font-style:italic;">$1</em>')
    $t = [regex]::Replace($t, '`([^`]+?)`', '<code style="font-size:14px;background:#f5f5f5;padding:2px 6px;border-radius:3px;color:#c7254e;font-family:Consolas,monospace;">$1</code>')
    $t = [regex]::Replace($t, '!\[[^\]]*\]\(([^)]+)\)', '<img src="$1" style="max-width:100%;border-radius:4px;margin:8px 0;" />')
    $t = [regex]::Replace($t, '\[([^\]]+)\]\(([^)]+)\)', '<a href="$2" style="color:#576b95;text-decoration:none;border-bottom:1px solid #576b95;">$1</a>')
    return $t
}

function Parse-TableRow([string]$Line) {
    $trimmed = $Line.Trim().TrimStart('|').TrimEnd('|')
    $cells = $trimmed -split '\|'
    $result = @()
    foreach ($c in $cells) { $result += $c.Trim() }
    return ,$result
}

function Test-TableSeparator([string]$Line) {
    return $Line -match '^\s*\|[\s\-:]+(\|[\s\-:]+)+\|\s*$'
}

function Convert-MarkdownToBasicHtml([string]$MarkdownRaw) {
    $sBody   = 'margin:0;padding:0;'
    $sH1     = 'font-size:22px;font-weight:bold;color:#1a1a1a;text-align:center;margin:28px 0 20px;line-height:1.4;letter-spacing:1px;'
    $sH2     = 'font-size:18px;font-weight:bold;color:#2b2b2b;margin:24px 0 12px;padding-left:12px;border-left:4px solid #576b95;line-height:1.5;'
    $sH3     = 'font-size:16px;font-weight:bold;color:#3f3f3f;margin:20px 0 10px;line-height:1.5;'
    $sP      = 'font-size:15px;color:#3f3f3f;line-height:1.8;margin:10px 0;letter-spacing:0.5px;text-align:justify;'
    $sLi     = 'font-size:15px;color:#3f3f3f;line-height:1.8;margin:0;padding:2px 0;letter-spacing:0.5px;'
    $sUl     = 'margin:8px 0 8px 1.2em;padding:0;list-style:disc;list-style-position:outside;'
    $sOl     = 'margin:8px 0 8px 1.4em;padding:0;list-style:decimal;list-style-position:outside;'
    $sQuote  = 'margin:16px 0;padding:12px 16px;background:#f8f8f8;border-left:4px solid #576b95;color:#666;font-size:14px;line-height:1.7;border-radius:0 4px 4px 0;'
    $sHr     = 'border:none;border-top:1px solid #e5e5e5;margin:24px 0;'
    $sTable  = 'width:100%;border-collapse:collapse;margin:16px 0;font-size:14px;line-height:1.6;'
    $sTh     = 'background:#f2f3f5;font-weight:bold;color:#1a1a1a;border:1px solid #ddd;padding:8px 12px;text-align:left;'
    $sTd     = 'border:1px solid #ddd;padding:8px 12px;color:#3f3f3f;'

    $inList = $false
    $listType = ""
    $inQuote = $false
    $quoteLines = @()
    $inTable = $false
    $tableHeaderCells = @()
    $tableRows = @()
    $tableHasHeader = $false
    $sb = New-Object System.Text.StringBuilder

    function Close-List {
        if (-not $inList) { return }
        $closeTag = if ($listType -eq "ol") { "</ol>" } else { "</ul>" }
        [void]$sb.AppendLine($closeTag)
        Set-Variable -Scope 1 -Name inList -Value $false
        Set-Variable -Scope 1 -Name listType -Value ""
    }

    function Open-List([string]$NextListType) {
        if ($inList -and $listType -eq $NextListType) { return }
        Close-List
        $openTag = if ($NextListType -eq "ol") { "<ol style=`"$sOl`">" } else { "<ul style=`"$sUl`">" }
        [void]$sb.AppendLine($openTag)
        Set-Variable -Scope 1 -Name inList -Value $true
        Set-Variable -Scope 1 -Name listType -Value $NextListType
    }

    function Flush-Table {
        if (-not $inTable) { return }
        [void]$sb.AppendLine("<table style=`"$sTable`">")
        if ($tableHasHeader -and $tableHeaderCells.Count -gt 0) {
            [void]$sb.Append("<thead><tr>")
            foreach ($cell in $tableHeaderCells) {
                $c = Escape-Html $cell
                $c = Apply-InlineMarkdown $c
                [void]$sb.Append("<th style=`"$sTh`">$c</th>")
            }
            [void]$sb.AppendLine("</tr></thead>")
        }
        if ($tableRows.Count -gt 0) {
            [void]$sb.AppendLine("<tbody>")
            foreach ($row in $tableRows) {
                [void]$sb.Append("<tr>")
                foreach ($cell in $row) {
                    $c = Escape-Html $cell
                    $c = Apply-InlineMarkdown $c
                    [void]$sb.Append("<td style=`"$sTd`">$c</td>")
                }
                [void]$sb.AppendLine("</tr>")
            }
            [void]$sb.AppendLine("</tbody>")
        }
        [void]$sb.AppendLine("</table>")
        Set-Variable -Scope 1 -Name inTable -Value $false
        Set-Variable -Scope 1 -Name tableHeaderCells -Value @()
        Set-Variable -Scope 1 -Name tableRows -Value @()
        Set-Variable -Scope 1 -Name tableHasHeader -Value $false
    }

    [void]$sb.AppendLine("<section style=`"$sBody`">")

    $lines = $MarkdownRaw -split "\r?\n"
    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        $line = $lines[$idx].Replace([char]0x00A0, ' ').TrimEnd()
        $trimmedLine = $line.Trim()

        # --- table handling ---
        if ($line -match '^\s*\|.+\|\s*$') {
            Close-List
            if (-not $inTable) {
                $inTable = $true
                $tableHeaderCells = @()
                $tableRows = @()
                $tableHasHeader = $false

                $cells = Parse-TableRow $line
                $nextIdx = $idx + 1
                if ($nextIdx -lt $lines.Count -and (Test-TableSeparator $lines[$nextIdx])) {
                    $tableHeaderCells = $cells
                    $tableHasHeader = $true
                    $idx = $nextIdx
                } else {
                    $tableRows += ,$cells
                }
            } else {
                if (Test-TableSeparator $line) { continue }
                $cells = Parse-TableRow $line
                $tableRows += ,$cells
            }
            continue
        } elseif ($inTable) {
            Flush-Table
        }

        # --- blockquote ---
        if ($line -match "^\s*>\s?(.*)$") {
            Close-List
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

        # --- lists ---
        if ($inList -and [string]::IsNullOrWhiteSpace($trimmedLine)) {
            # Keep list open across blank lines to preserve numbering and spacing.
            continue
        }

        if ($line -match "^\s*[-*]\s+(.+)$") {
            $itemText = $Matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($itemText)) { continue }
            Open-List -NextListType "ul"
            $li = Escape-Html $itemText
            $li = Apply-InlineMarkdown $li
            [void]$sb.AppendLine("<li style=`"$sLi`">$li</li>")
            continue
        } elseif ($line -match "^\s*(\d+)\.\s+(.+)$") {
            $itemText = $Matches[2].Trim()
            if ([string]::IsNullOrWhiteSpace($itemText)) { continue }
            Open-List -NextListType "ol"
            $li = Escape-Html $itemText
            $li = Apply-InlineMarkdown $li
            [void]$sb.AppendLine("<li style=`"$sLi`">$li</li>")
            continue
        } elseif ($inList) {
            Close-List
        }

        # --- block elements ---
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

    # flush any trailing state
    if ($inQuote -and $quoteLines.Count -gt 0) {
        $qText = Escape-Html ($quoteLines -join " ")
        $qText = Apply-InlineMarkdown $qText
        [void]$sb.AppendLine("<blockquote style=`"$sQuote`">$qText</blockquote>")
    }
    if ($inList) { Close-List }
    if ($inTable) { Flush-Table }

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
    $bodyOnly = Strip-FrontMatter -MarkdownRaw $raw
    $html = Convert-MarkdownToBasicHtml -MarkdownRaw $bodyOnly
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
