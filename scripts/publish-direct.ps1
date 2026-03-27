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
    [switch]$Help
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-WarnLine([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host $Message -ForegroundColor Red }

function Read-TextUtf8Strict([string]$Path) {
    try {
        $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false, $true)))
    } catch [System.Text.DecoderFallbackException] {
        throw "Markdown file must be valid UTF-8: $Path"
    }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }
    return $text
}

function Assert-MarkdownUtf8([string]$Path) {
    [void](Read-TextUtf8Strict -Path $Path)
    Write-Info "UTF-8 check passed."
}

function Show-Help {
@"
Usage:
  .\scripts\publish-direct.ps1 <markdown-file> [theme] [highlight]

Examples:
  .\scripts\publish-direct.ps1 .\articles\ico-frt-test.md
  .\scripts\publish-direct.ps1 .\articles\ico-frt-test.md -AutoCover
  .\scripts\publish-direct.ps1 .\articles\ico-frt-test.md -NoAutoCover

Options:
  -ToolsFile    TOOLS.md path, default: $HOME\.openclaw\workspace\TOOLS.md
  -AutoCover    Deprecated. Auto cover is enabled by default.
  -NoAutoCover  Skip AI cover generation for this publish
  -AiBaseUrl    AI API base URL, default: https://yunwu.ai
  -AiModel      AI image model, default: doubao-seedream-5-0-260128
  -AiApiKey     AI API key (or set env: YUNWU_API_KEY)
  [theme] [highlight] are accepted for backward compatibility only and do not affect built-in rendering
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
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
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

function Get-MarkdownBody([string]$MarkdownRaw) {
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
            $output = curl.exe -s --max-time $MaxTime -X $Method -H "Content-Type: application/json" --data-binary "@$tmpFile" $Url
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

function Escape-AttributeValue([string]$Text) {
    return $Text.Replace('"', '&quot;').Replace("'", '&#39;')
}

function Convert-InlineMarkdown([string]$Text) {
    $html = Escape-Html $Text
    $html = [regex]::Replace($html, '!\[([^\]]*)\]\(([^)]+)\)', {
        param($m)
        $alt = Escape-AttributeValue $m.Groups[1].Value
        $src = Escape-AttributeValue $m.Groups[2].Value
        return "<img src=""$src"" alt=""$alt"" style=""display:block;width:100%;max-width:100%;height:auto;margin:18px auto;border-radius:12px;"" />"
    })
    $html = [regex]::Replace($html, '\[([^\]]+)\]\((https?://[^)]+)\)', {
        param($m)
        $label = $m.Groups[1].Value
        $href = Escape-AttributeValue $m.Groups[2].Value
        return "<a href=""$href"" style=""color:#2f6fed;text-decoration:none;border-bottom:1px solid #bfd3ff;"">$label</a>"
    })
    $html = [regex]::Replace($html, '`([^`]+)`', '<code style="font-family:Consolas,Monaco,monospace;font-size:0.92em;background:#f3f5f7;color:#c7254e;padding:2px 6px;border-radius:6px;">$1</code>')
    $html = [regex]::Replace($html, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    $html = [regex]::Replace($html, '__([^_]+)__', '<strong>$1</strong>')
    return $html
}

function Get-MarkdownTableCells([string]$Line) {
    $trimmed = $Line.Trim()
    if ($trimmed.StartsWith('|')) { $trimmed = $trimmed.Substring(1) }
    if ($trimmed.EndsWith('|')) { $trimmed = $trimmed.Substring(0, $trimmed.Length - 1) }
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return @() }
    return @($trimmed -split '\|' | ForEach-Object { $_.Trim() })
}

function Convert-MarkdownToBasicHtml([string]$MarkdownRaw) {
    $body = Get-MarkdownBody -MarkdownRaw $MarkdownRaw
    $sb = New-Object System.Text.StringBuilder
    $lines = $body -split "\r?\n"
    $inUnorderedList = $false
    $inOrderedList = $false
    $inBlockquote = $false
    $inCodeBlock = $false
    $inTable = $false
    $tableHeaderDone = $false

    [void]$sb.AppendLine('<section style="max-width:100%;font-size:16px;line-height:1.8;color:#1f2329;word-break:break-word;">')
    foreach ($lineRaw in $lines) {
        $line = $lineRaw.TrimEnd()

        if ($line -match '^\s*```') {
            if ($inBlockquote) {
                [void]$sb.AppendLine("</blockquote>")
                $inBlockquote = $false
            }
            if ($inTable) {
                [void]$sb.AppendLine('</tbody></table>')
                $inTable = $false
                $tableHeaderDone = $false
            }
            if ($inUnorderedList) {
                [void]$sb.Append('</ul>')
                $inUnorderedList = $false
            }
            if ($inOrderedList) {
                [void]$sb.Append('</ol>')
                $inOrderedList = $false
            }

            if (-not $inCodeBlock) {
                [void]$sb.AppendLine('<pre style="margin:20px 0;padding:16px;background:#0f172a;color:#e2e8f0;border-radius:12px;overflow-x:auto;white-space:pre-wrap;word-break:break-word;"><code style="font-family:Consolas,Monaco,monospace;font-size:13px;line-height:1.7;">')
                $inCodeBlock = $true
            } else {
                [void]$sb.AppendLine('</code></pre>')
                $inCodeBlock = $false
            }
            continue
        }

        if ($inCodeBlock) {
            [void]$sb.AppendLine((Escape-Html $line))
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($inBlockquote) {
                [void]$sb.AppendLine('</blockquote>')
                $inBlockquote = $false
            }
            if ($inTable) {
                [void]$sb.AppendLine('</tbody></table>')
                $inTable = $false
                $tableHeaderDone = $false
            }
            if ($inUnorderedList) {
                [void]$sb.Append('</ul>')
                $inUnorderedList = $false
            }
            if ($inOrderedList) {
                [void]$sb.Append('</ol>')
                $inOrderedList = $false
            }
            continue
        }

        $isTableRow = $line -match '^\s*\|(.+)\|\s*$'
        $isTableSeparator = $line -match '^\s*\|[\s\-:|]+\|\s*$'

        if ($isTableRow) {
            if ($inBlockquote) {
                [void]$sb.AppendLine('</blockquote>')
                $inBlockquote = $false
            }
            if ($inUnorderedList) {
                [void]$sb.Append('</ul>')
                $inUnorderedList = $false
            }
            if ($inOrderedList) {
                [void]$sb.Append('</ol>')
                $inOrderedList = $false
            }

            if ($isTableSeparator) {
                continue
            }

            $cells = Get-MarkdownTableCells -Line $line
            if (-not $inTable) {
                [void]$sb.AppendLine('<table style="width:100%;border-collapse:collapse;margin:20px 0;font-size:15px;line-height:1.7;"><thead><tr>')
                foreach ($cell in $cells) {
                    [void]$sb.Append("<th style=""padding:10px 14px;border:1px solid #d8dee4;background:#f6f9ff;text-align:left;font-weight:700;"">$(Convert-InlineMarkdown $cell)</th>")
                }
                [void]$sb.AppendLine('</tr></thead><tbody>')
                $inTable = $true
                $tableHeaderDone = $true
            } else {
                [void]$sb.Append('<tr>')
                foreach ($cell in $cells) {
                    [void]$sb.Append("<td style=""padding:10px 14px;border:1px solid #d8dee4;text-align:left;vertical-align:top;"">$(Convert-InlineMarkdown $cell)</td>")
                }
                [void]$sb.AppendLine('</tr>')
            }
            continue
        } elseif ($inTable) {
            [void]$sb.AppendLine('</tbody></table>')
            $inTable = $false
            $tableHeaderDone = $false
        }

        if ($line -match '^\s*>\s?(.*)$') {
            if ($inUnorderedList) {
                [void]$sb.Append('</ul>')
                $inUnorderedList = $false
            }
            if ($inOrderedList) {
                [void]$sb.Append('</ol>')
                $inOrderedList = $false
            }
            if (-not $inBlockquote) {
                [void]$sb.AppendLine('<blockquote style="margin:20px 0;padding:4px 0 4px 16px;border-left:4px solid #2f6fed;background:#f6f9ff;color:#445066;">')
                $inBlockquote = $true
            }
            [void]$sb.AppendLine("<p style=""margin:10px 0;"">$(Convert-InlineMarkdown $Matches[1])</p>")
            continue
        } elseif ($inBlockquote) {
            [void]$sb.AppendLine('</blockquote>')
            $inBlockquote = $false
        }

        if ($line -match '^\s*[-*]\s+(.+)$') {
            if ($inOrderedList) {
                [void]$sb.Append('</ol>')
                $inOrderedList = $false
            }
            if (-not $inUnorderedList) {
                [void]$sb.Append('<ul style="margin:16px 0;padding-left:1.4em;color:#1f2329;">')
                $inUnorderedList = $true
            }
            [void]$sb.Append("<li style=""margin:8px 0;line-height:1.8;"">$(Convert-InlineMarkdown $Matches[1])</li>")
            continue
        } elseif ($inUnorderedList) {
            [void]$sb.Append('</ul>')
            $inUnorderedList = $false
        }

        if ($line -match '^\s*\d+\.\s+(.+)$') {
            if ($inUnorderedList) {
                [void]$sb.Append('</ul>')
                $inUnorderedList = $false
            }
            if (-not $inOrderedList) {
                [void]$sb.Append('<ol style="margin:16px 0;padding-left:1.4em;color:#1f2329;">')
                $inOrderedList = $true
            }
            [void]$sb.Append("<li style=""margin:8px 0;line-height:1.8;"">$(Convert-InlineMarkdown $Matches[1])</li>")
            continue
        } elseif ($inOrderedList) {
            [void]$sb.Append('</ol>')
            $inOrderedList = $false
        }

        if ($line -match '^\s*!\[(?<alt>[^\]]*)\]\((?<src>[^)]+)\)\s*$') {
            $figureSrc = Escape-AttributeValue (Escape-Html $Matches['src'])
            $figureAlt = Escape-AttributeValue (Escape-Html $Matches['alt'])
            [void]$sb.AppendLine("<figure style=""margin:24px 0;""><img src=""$figureSrc"" alt=""$figureAlt"" style=""display:block;width:100%;max-width:100%;height:auto;border-radius:12px;"" /></figure>")
            continue
        }

        if ($line -match '^\s*---+\s*$') {
            [void]$sb.AppendLine('<hr style="margin:28px 0;border:none;border-top:1px solid #d8dee4;" />')
            continue
        }

        if ($line -match "^\s*###\s+(.+)$") {
            [void]$sb.AppendLine("<h3 style=""margin:22px 0 10px;font-size:18px;line-height:1.5;font-weight:700;color:#1f2329;"">$(Convert-InlineMarkdown $Matches[1])</h3>")
        } elseif ($line -match "^\s*##\s+(.+)$") {
            [void]$sb.AppendLine("<h2 style=""margin:34px 0 14px;padding-left:12px;border-left:4px solid #2f6fed;font-size:22px;line-height:1.5;font-weight:700;color:#1f2329;"">$(Convert-InlineMarkdown $Matches[1])</h2>")
        } elseif ($line -match "^\s*#\s+(.+)$") {
            [void]$sb.AppendLine("<h1 style=""margin:0 0 24px;font-size:28px;line-height:1.45;font-weight:800;color:#1f2329;"">$(Convert-InlineMarkdown $Matches[1])</h1>")
        } else {
            [void]$sb.AppendLine("<p style=""margin:0 0 16px;text-align:justify;"">$(Convert-InlineMarkdown $line)</p>")
        }
    }

    if ($inBlockquote) { [void]$sb.AppendLine('</blockquote>') }
    if ($inTable) { [void]$sb.AppendLine('</tbody></table>') }
    if ($inUnorderedList) { [void]$sb.Append('</ul>') }
    if ($inOrderedList) { [void]$sb.Append('</ol>') }
    if ($inCodeBlock) { [void]$sb.AppendLine('</code></pre>') }
    [void]$sb.AppendLine('</section>')
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
            $escapedNewUrl = Escape-AttributeValue $newUrl
            $updatedTag = [regex]::Replace($m.Value, '(?is)(\bsrc\s*=\s*["''])([^"'']+)(["''])', {
                param($srcMatch)
                return $srcMatch.Groups[1].Value + $escapedNewUrl + $srcMatch.Groups[3].Value
            })
            $updated = $updated.Replace($m.Value, $updatedTag)
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

    $shouldAutoCover = -not $NoAutoCover
    if ($AutoCover -and $NoAutoCover) {
        throw "Use either -AutoCover or -NoAutoCover, not both."
    }

    if ($shouldAutoCover) {
        if ([string]::IsNullOrWhiteSpace($AiApiKey)) {
            throw "Auto cover is enabled by default and requires -AiApiKey or env YUNWU_API_KEY. Use -NoAutoCover to skip cover generation."
        }
        $coverScript = Join-Path -Path $PSScriptRoot -ChildPath "generate-cover.ps1"
        Write-Info "Auto cover enabled by default. Generating cover..."
        & $coverScript -MarkdownFile "$resolvedMarkdown" -BaseUrl "$AiBaseUrl" -Model "$AiModel" -ApiKey "$AiApiKey"
        if ($LASTEXITCODE -ne 0) {
            throw "Cover generation failed."
        }
    } else {
        Write-WarnLine "Skipping AI cover generation because -NoAutoCover was provided."
    }

    Assert-MarkdownUtf8 -Path $resolvedMarkdown
    $raw = Read-TextUtf8Strict -Path $resolvedMarkdown
    $fm = Parse-FrontMatter -MarkdownRaw $raw
    if ([string]::IsNullOrWhiteSpace($fm.title)) {
        throw "Frontmatter title is required."
    }
    if ([string]::IsNullOrWhiteSpace($fm.cover)) {
        throw "Frontmatter cover is required."
    }

    Write-Info "Fetching access token..."
    $token = Get-AccessToken -AppId $env:WECHAT_APP_ID -AppSecret $env:WECHAT_APP_SECRET

    Write-Info "Rendering markdown to HTML with built-in styled renderer..."
    $html = Convert-MarkdownToBasicHtml -MarkdownRaw $raw
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
