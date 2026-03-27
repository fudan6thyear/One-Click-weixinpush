param(
    [string]$MarkdownFile = "",
    [string]$BaseUrl = "https://yunwu.ai",
    [string]$Model = "doubao-seedream-5-0-260128",
    [string]$ApiKey = $env:YUNWU_API_KEY,
    [string]$OutputDir = "",
    [int]$RetryCount = 5,
    [int]$RetryDelaySec = 2,
    [switch]$NoUpdateMarkdown,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

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

function Read-LinesUtf8Strict([string]$Path) {
    $text = Read-TextUtf8Strict -Path $Path
    if ([string]::IsNullOrEmpty($text)) { return @() }
    return $text -split "\r?\n"
}

function Write-TextUtf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    [void](Read-TextUtf8Strict -Path $Path)
}

function Write-LinesUtf8([string]$Path, [string[]]$Lines) {
    $text = [string]::Join([Environment]::NewLine, $Lines)
    Write-TextUtf8 -Path $Path -Text $text
}

function Assert-MarkdownUtf8([string]$Path) {
    [void](Read-TextUtf8Strict -Path $Path)
    Write-Host "UTF-8 check passed." -ForegroundColor Green
}

function Show-Help {
    @"
Usage:
  .\scripts\generate-cover.ps1 -MarkdownFile .\article.md

Options:
  -BaseUrl           API base URL (default: https://yunwu.ai)
  -Model             image model (default: doubao-seedream-5-0-260128)
  -ApiKey            API key (default from env: YUNWU_API_KEY)
  -OutputDir         output folder (default: <markdown-dir>\assets)
  -RetryCount        retry attempts for flaky upstreams (default: 5)
  -RetryDelaySec     delay between retries in seconds (default: 2)
  -NoUpdateMarkdown  do not modify markdown cover frontmatter
  -Help              show help
"@ | Write-Host
}

function Get-FrontMatterAndBody([string]$Raw) {
    $frontMatter = ""
    $body = $Raw
    if ($Raw -match "(?s)^---\r?\n(.*?)\r?\n---\r?\n?(.*)$") {
        $frontMatter = $Matches[1]
        $body = $Matches[2]
    }
    return @{
        FrontMatter = $frontMatter
        Body = $body
    }
}

function Get-Title([string]$FrontMatter, [string]$Body, [string]$FallbackFile) {
    if ($FrontMatter -match "(?m)^\s*title\s*:\s*(.+)\s*$") {
        return $Matches[1].Trim(" '""")
    }
    if ($Body -match "(?m)^\s*#\s+(.+)\s*$") {
        return $Matches[1].Trim()
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($FallbackFile)
}

function Get-ContentSnippet([string]$Body) {
    $text = $Body
    $text = $text -replace '(?s)```.*?```', ' '
    $text = $text -replace '(?m)^\s{0,3}>\s?', ''
    $text = $text -replace '[#*_\[\]\(\)\-\|`]', ' '
    $text = $text -replace '\s+', ' '
    $text = $text.Trim()

    if ($text.Length -gt 160) {
        return $text.Substring(0, 160)
    }
    return $text
}

function Limit-Text([string]$Text, [int]$MaxLength) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $trimmed = ($Text -replace '\s+', ' ').Trim()
    if ($trimmed.Length -le $MaxLength) {
        return $trimmed
    }

    return $trimmed.Substring(0, $MaxLength).TrimEnd() + "..."
}

function Get-VisualScene([string]$Title, [string]$Snippet) {
    $combined = ($Title + ' ' + $Snippet).ToLower()

    if ($combined -match 'privacy|隐私|personal data|个人信息|gdpr|ccpa|data protection|数据保护') {
        return 'A glowing transparent shield floating above a city of interconnected data nodes, with an abstract silhouette of a person standing protected inside the shield, blue and white tones, dramatic lighting'
    }

    if ($combined -match '未成年|child|minor|youth|age verification|年龄|school|student') {
        return 'A luminous bubble of soft light surrounding a small figure who is surrounded by colorful floating digital device icons; caring adult silhouettes forming a protective ring outside; warm and cool blue palette'
    }

    if ($combined -match 'law|legal|regulation|合规|法律|监管|enforcement|regulatory|penalty|处罚|court|judgment') {
        return 'An imposing stone courthouse facade bathed in golden morning light, with translucent glowing network lines overlaid across the architecture, and abstract balanced scales as a faint holographic overlay'
    }

    if ($combined -match 'ai|artificial intelligence|automation|robot|机器人|就业|employment|job|工作|labor') {
        return 'A human hand and a sleek robotic arm reaching toward each other across a glowing horizontal divide in a modern bright open-plan office, warm amber light on the human side, cool blue light on the machine side, cinematic depth of field'
    }

    if ($combined -match 'security|cybersecurity|breach|hack|漏洞|网络安全') {
        return 'A luminous padlock made of circuit lines at the center of a dark digital storm of cascading abstract data fragments, red and electric blue energy streams, cinematic editorial style'
    }

    if ($combined -match 'business|strategy|enterprise|企业|商业|market|市场') {
        return 'An aerial view of a chessboard city-grid at blue-hour dusk with one glowing golden skyscraper rising prominently above the others, long dramatic shadows, editorial illustration style'
    }

    return 'A lone researcher silhouette stands before a vast translucent wall of floating abstract knowledge nodes and glowing connection lines, cool blue and teal tones, modern editorial illustration'
}

function Build-Prompt([string]$Title, [string]$Snippet) {
    $scene = Get-VisualScene -Title $Title -Snippet $Snippet

    return @"
NO TEXT RULE (absolute, highest priority): The final image must contain zero visible characters of any kind — no letters, no digits, no Chinese characters, no abbreviations, no labels, no captions, no logos, no watermarks. Violating this rule makes the image unusable.

Create a landscape cover illustration with aspect ratio 2.35:1 (equivalent to 900x383 px) for a WeChat official account article.

Scene to illustrate: $scene

Additional requirements:
- Horizontal landscape composition. Place the main focal element at center so it survives a square crop of the middle third.
- Modern editorial illustration style, clean and professional, for a Chinese business or technology media outlet.
- Strong contrast, rich colors — not washed-out or pastel.
- No UI elements, no speech bubbles, no infographic labels.
"@
}

function Invoke-WithRetry([scriptblock]$Action, [int]$MaxAttempts, [int]$DelaySec, [string]$Name) {
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-Host "$Name attempt $attempt/$MaxAttempts ..."
            return & $Action
        }
        catch {
            $lastError = $_
            $message = $_.Exception.Message
            Write-Host "$Name attempt $attempt failed: $message" -ForegroundColor Yellow
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds $DelaySec
            }
        }
    }

    if ($null -ne $lastError) {
        throw $lastError
    }
    throw "$Name failed with unknown error."
}

function Invoke-ImageGenerationOpenAI([string]$Endpoint, [string]$ApiKeyValue, [string]$ModelName, [string]$Prompt) {
    $headers = @{
        "Authorization" = "Bearer $ApiKeyValue"
        "Content-Type"  = "application/json"
    }

    $payloadPrimary = @{
        model           = $ModelName
        prompt          = $Prompt
        size            = "2848x1216"
        response_format = "url"
        watermark       = $false
    }

    return Invoke-RestMethod -Method Post -Uri $Endpoint -Headers $headers -Body ($payloadPrimary | ConvertTo-Json -Depth 10)
}

function Save-ImageFromResponse([object]$Response, [string]$OutputFile) {
    if ($null -ne $Response.data -and $Response.data.Count -gt 0) {
        $first = $Response.data[0]
        if ($null -ne $first.b64_json -and $first.b64_json -ne "") {
            $bytes = [System.Convert]::FromBase64String([string]$first.b64_json)
            [System.IO.File]::WriteAllBytes($OutputFile, $bytes)
            return
        }
        if ($null -ne $first.base64 -and $first.base64 -ne "") {
            $bytes = [System.Convert]::FromBase64String([string]$first.base64)
            [System.IO.File]::WriteAllBytes($OutputFile, $bytes)
            return
        }
        if ($null -ne $first.url -and $first.url -ne "") {
            Invoke-WebRequest -Uri ([string]$first.url) -OutFile $OutputFile
            return
        }
    }

    $json = $Response | ConvertTo-Json -Depth 8
    throw "Cannot parse image from API response: $json"
}

function Update-MarkdownCover([string]$MarkdownPath, [string]$CoverRelativePath, [string]$Title) {
    $lines = Read-LinesUtf8Strict -Path $MarkdownPath
    $newCoverLine = "cover: $CoverRelativePath"

    if ($lines.Count -gt 0 -and $lines[0].Trim() -eq "---") {
        $end = -1
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq "---") {
                $end = $i
                break
            }
        }

        if ($end -gt 0) {
            $coverIndex = -1
            for ($i = 1; $i -lt $end; $i++) {
                if ($lines[$i] -match "^\s*cover\s*:") {
                    $coverIndex = $i
                    break
                }
            }

            if ($coverIndex -ge 0) {
                $lines[$coverIndex] = $newCoverLine
            }
            else {
                $lines = @($lines[0..($end - 1)] + $newCoverLine + $lines[$end..($lines.Count - 1)])
            }

            Write-LinesUtf8 -Path $MarkdownPath -Lines $lines
            return
        }
    }

    $injected = @(
        "---"
        "title: $Title"
        $newCoverLine
        "---"
        ""
    ) + $lines
    Write-LinesUtf8 -Path $MarkdownPath -Lines $injected
}

try {
    if ($Help) {
        Show-Help
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($MarkdownFile)) {
        throw "MarkdownFile is required. Use -MarkdownFile <path>."
    }

    $resolvedMarkdown = Resolve-Path -LiteralPath $MarkdownFile -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolvedMarkdown -PathType Leaf)) {
        throw "Markdown file not found: $MarkdownFile"
    }

    Assert-MarkdownUtf8 -Path $resolvedMarkdown
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "API key is missing. Set YUNWU_API_KEY or pass -ApiKey."
    }

    $raw = Read-TextUtf8Strict -Path $resolvedMarkdown
    $parts = Get-FrontMatterAndBody -Raw $raw
    $title = Get-Title -FrontMatter $parts.FrontMatter -Body $parts.Body -FallbackFile $resolvedMarkdown
    $snippet = Get-ContentSnippet -Body $parts.Body
    $prompt = Build-Prompt -Title $title -Snippet $snippet

    $folder = $OutputDir
    if ([string]::IsNullOrWhiteSpace($folder)) {
        $folder = Join-Path -Path (Split-Path -Parent $resolvedMarkdown) -ChildPath "assets"
    }
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $fileNameBase = "ai-cover-$timestamp"
    $outputBase = Join-Path -Path $folder -ChildPath $fileNameBase
    $generatedFile = $null

    $imagesEndpoint = "$($BaseUrl.TrimEnd('/'))/v1/images/generations"
    Write-Host "Generating cover via images endpoint on $BaseUrl ..."
    $imagesAction = {
        Invoke-ImageGenerationOpenAI -Endpoint $imagesEndpoint -ApiKeyValue $ApiKey -ModelName $Model -Prompt $prompt
    }
    $imagesResponse = Invoke-WithRetry -Action $imagesAction -MaxAttempts $RetryCount -DelaySec $RetryDelaySec -Name "Images generation"
    $generatedFile = "$outputBase.png"
    Save-ImageFromResponse -Response $imagesResponse -OutputFile $generatedFile

    $coverRelative = "./assets/$([System.IO.Path]::GetFileName($generatedFile))"
    if (-not $NoUpdateMarkdown) {
        Update-MarkdownCover -MarkdownPath $resolvedMarkdown -CoverRelativePath $coverRelative -Title $title
        Write-Host "Markdown updated: cover -> $coverRelative" -ForegroundColor Green
    }

    Write-Host "Cover generated: $generatedFile" -ForegroundColor Green
    exit 0
}
catch {
    $message = $_.Exception.Message
    if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream()) {
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $body = $reader.ReadToEnd()
            if (-not [string]::IsNullOrWhiteSpace($body)) {
                $message = "$message`nAPI response: $body"
            }
        }
        catch {
        }
    }
    Write-Host "Cover generation failed: $message" -ForegroundColor Red
    exit 1
}
