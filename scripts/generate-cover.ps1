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
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

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

    if ($text.Length -gt 500) {
        return $text.Substring(0, 500)
    }
    return $text
}

function Build-Prompt([string]$Title, [string]$Snippet) {
    return @"
Create a clean, high-quality cover image for an article.

CRITICAL RULES:
- ABSOLUTELY NO TEXT, NO LETTERS, NO WORDS, NO NUMBERS, NO CHARACTERS of any language in the image
- NO watermark, NO logo, NO caption, NO label, NO title overlay
- The image must be purely visual/illustrative with ZERO text elements

Style requirements:
- Modern, editorial, magazine-quality composition
- Rich color palette, professional lighting
- Clear single visual focal point
- Abstract or symbolic representation of the topic
- Safe for all audiences

The article is about:
$Title

Key themes to represent visually (use symbols, metaphors, objects — NOT text):
$Snippet
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
        response_format = "b64_json"
    }

    return Invoke-RestMethod -Method Post -Uri $Endpoint -Headers $headers -Body ($payloadPrimary | ConvertTo-Json -Depth 10)
}

function Invoke-ImageGenerationGemini([string]$BaseApiUrl, [string]$ApiKeyValue, [string]$ModelName, [string]$Prompt) {
    $trimmed = $BaseApiUrl.TrimEnd("/")
    $endpoint = "$trimmed/v1beta/models/$ModelName`:generateContent?key=$ApiKeyValue"
    $payload = @{
        contents = @(
            @{
                parts = @(
                    @{
                        text = $Prompt
                    }
                )
            }
        )
    }

    return Invoke-RestMethod -Method Post -Uri $endpoint -ContentType "application/json" -Body ($payload | ConvertTo-Json -Depth 20) -TimeoutSec 60
}

function Use-GeminiEndpoint([string]$ModelName) {
    return $ModelName -like "gemini-*"
}

function Save-ImageFromResponse([object]$Response, [string]$OutputFile) {
    if ($null -ne $Response.data -and $Response.data.Count -gt 0) {
        $first = $Response.data[0]
        if ($null -ne $first.b64_json -and $first.b64_json -ne "") {
            $encoded = [string]$first.b64_json
            if ($encoded -match '^data:[^;]+;base64,(.+)$') {
                $encoded = $Matches[1]
            }
            $bytes = [System.Convert]::FromBase64String($encoded)
            [System.IO.File]::WriteAllBytes($OutputFile, $bytes)
            return
        }
        if ($null -ne $first.base64 -and $first.base64 -ne "") {
            $encoded = [string]$first.base64
            if ($encoded -match '^data:[^;]+;base64,(.+)$') {
                $encoded = $Matches[1]
            }
            $bytes = [System.Convert]::FromBase64String($encoded)
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

function Save-ImageFromGeminiResponse([object]$Response, [string]$OutputFileBaseNoExt) {
    if ($null -eq $Response.candidates -or $Response.candidates.Count -eq 0) {
        $json = $Response | ConvertTo-Json -Depth 8
        throw "Gemini response has no candidates: $json"
    }

    $parts = $Response.candidates[0].content.parts
    foreach ($part in $parts) {
        if ($null -ne $part.inlineData -and $null -ne $part.inlineData.data -and $part.inlineData.data -ne "") {
            $mime = [string]$part.inlineData.mimeType
            $ext = if ($mime -eq "image/png") { ".png" } elseif ($mime -eq "image/webp") { ".webp" } else { ".jpg" }
            $target = "$OutputFileBaseNoExt$ext"
            [System.IO.File]::WriteAllBytes($target, [System.Convert]::FromBase64String([string]$part.inlineData.data))
            return $target
        }
    }

    $json = $Response | ConvertTo-Json -Depth 8
    throw "Gemini response has no inline image data: $json"
}

function Update-MarkdownCover([string]$MarkdownPath, [string]$CoverRelativePath, [string]$Title) {
    $lines = [System.IO.File]::ReadAllLines($MarkdownPath, [System.Text.Encoding]::UTF8)
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

            [System.IO.File]::WriteAllLines($MarkdownPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
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
    [System.IO.File]::WriteAllLines($MarkdownPath, [string[]]$injected, (New-Object System.Text.UTF8Encoding($false)))
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

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "API key is missing. Set YUNWU_API_KEY or pass -ApiKey."
    }

    $raw = [System.IO.File]::ReadAllText([string]$resolvedMarkdown, [System.Text.Encoding]::UTF8)
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

    if (Use-GeminiEndpoint -ModelName $Model) {
        try {
            Write-Host "Generating cover via Gemini endpoint on $BaseUrl ..."
            $geminiAction = {
                Invoke-ImageGenerationGemini -BaseApiUrl $BaseUrl -ApiKeyValue $ApiKey -ModelName $Model -Prompt $prompt
            }
            $geminiResponse = Invoke-WithRetry -Action $geminiAction -MaxAttempts $RetryCount -DelaySec $RetryDelaySec -Name "Gemini generateContent"
            $generatedFile = Save-ImageFromGeminiResponse -Response $geminiResponse -OutputFileBaseNoExt $outputBase
        }
        catch {
            Write-Host "Gemini endpoint failed, fallback to OpenAI images endpoint..." -ForegroundColor Yellow
            $openaiEndpoint = "$($BaseUrl.TrimEnd('/'))/v1/images/generations"
            $openaiAction = {
                Invoke-ImageGenerationOpenAI -Endpoint $openaiEndpoint -ApiKeyValue $ApiKey -ModelName $Model -Prompt $prompt
            }
            $openaiResponse = Invoke-WithRetry -Action $openaiAction -MaxAttempts ([Math]::Max(1, [Math]::Floor($RetryCount / 2))) -DelaySec $RetryDelaySec -Name "OpenAI images"
            $generatedFile = "$outputBase.png"
            Save-ImageFromResponse -Response $openaiResponse -OutputFile $generatedFile
        }
    }
    else {
        Write-Host "Generating cover via OpenAI images endpoint on $BaseUrl ..."
        $openaiEndpoint = "$($BaseUrl.TrimEnd('/'))/v1/images/generations"
        $openaiAction = {
            Invoke-ImageGenerationOpenAI -Endpoint $openaiEndpoint -ApiKeyValue $ApiKey -ModelName $Model -Prompt $prompt
        }
        $openaiResponse = Invoke-WithRetry -Action $openaiAction -MaxAttempts $RetryCount -DelaySec $RetryDelaySec -Name "OpenAI images"
        $generatedFile = "$outputBase.png"
        Save-ImageFromResponse -Response $openaiResponse -OutputFile $generatedFile
    }

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
