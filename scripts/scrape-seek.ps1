<#!
Scrapes SEEK API pages for ICT Contract jobs, stops when a page contains no new jobs
(compared to a local CSV), fetches job details (GraphQL), sends the description
to Google Gemini (Structured Output) to extract contract duration signals, and
appends results to CSV.

CSV columns:
- CrawlTime        (UTC ISO-8601)
- jobID            (SEEK job id)
- duration_specified (bool)
- duration_months    (int)
- renewal_mentioned  (bool)

Usage (locally):
  pwsh ./scripts/scrape-seek.ps1 -OutputCsvPath "data/seek_jobs.csv" -MaxPages 50

In CI:
  The script reads the API key from $env:GEMINI_API_KEY.
#>

[CmdletBinding()]
param(
  [string]$OutputCsvPath = "data/seek_jobs.csv",
  [int]$MaxPages = 50,
  [int]$PageSize = 100,
  [string]$Classification = "6281",      # ICT
  [string]$WorkType = "244",             # Contract/Temp
  [string]$SeekLocale = "en-AU",
  [string]$SeekCountry = "AU",
  [string]$SeekZone = "anz-1",
  [string]$SeekTimezone = "Europe/Berlin",
  [string]$GeminiModel = "gemini-2.5-flash-lite",
  [int]$DelayMsBetweenRequests = 200
)

# --- Safety checks
if (-not $env:GEMINI_API_KEY -or [string]::IsNullOrWhiteSpace($env:GEMINI_API_KEY)) {
  throw "Environment variable GEMINI_API_KEY is not set. Provide it via GitHub Actions secret or your local env."
}

# --- Helpers
function New-QueryString {
  param([hashtable]$Params)
  $pairs = foreach ($k in $Params.Keys) {
    "{0}={1}" -f ([System.Uri]::EscapeDataString([string]$k)),
                 ([System.Uri]::EscapeDataString([string]$Params[$k]))
  }
  $pairs -join "&"
}

function Invoke-WebJsonWithRetry {
  param(
    [Parameter(Mandatory=$true)][string]$Uri,
    [ValidateSet('GET','POST')][string]$Method = 'GET',
    [hashtable]$Headers,
    [string]$UserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36",
    [string]$Body,
    [string]$ContentType = "application/json",
    [int]$MaxAttempts = 4
  )
  $attempt = 0
  do {
    try {
      $attempt++
      return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -UserAgent $UserAgent -Body $Body -ContentType $ContentType
    } catch {
      if ($attempt -ge $MaxAttempts) { throw }
      $backoff = [math]::Pow(2, $attempt) * 250
      Write-Host "Request failed (attempt $attempt). Retrying in $backoff ms..." -ForegroundColor Yellow
      Start-Sleep -Milliseconds $backoff
    }
  } while ($true)
}

function Convert-HtmlToPlainText {
  param([string]$Html)
  if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
  $text = [regex]::Replace($Html, "<[^>]+>", " ")
  $text = $text -replace "&nbsp;"," " -replace "&amp;","&" -replace "&#39;","'" -replace "&quot;",""" -replace "&lt;","<" -replace "&gt;",">"
  ($text -replace "\s+"," ").Trim()
}

# --- Gemini structured extraction (as in your snippet, slightly generalized)
function Invoke-GeminiJobContractExtraction {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$ApiKey,
    [Parameter(Mandatory=$true)][string]$JobText,
    [string]$ModelName = "gemini-2.5-flash-lite",
    [switch]$AsJson
  )

  $prompt = @"
You are an information extractor.

From the job description, determine:
- duration_specified (boolean): true if a specific duration (e.g., "6 months", "a 12-month contract") or a clear end date (e.g., "fixed term until 2025-12-31") is stated; false if it only says temporary/contract/fixed-term without a concrete duration or end date.
- duration_months (integer >= 0): the number of months. Use conversions: 1 year = 12 months; 4 weeks = 1 month; for weeks, round to a whole month. If only an end date is given without a known start date, set duration_months = 0.
- renewal_mentioned (boolean): true if an explicit contract extension/renewal is mentioned (e.g., "extension possible", "option to renew"); false if only conversion to a permanent role is mentioned.

Ignore probation periods, notice periods, application deadlines, and similar information.

Job description:
"@

  $fullPrompt = $prompt + "`n" + $JobText

  $body = @{
    contents = @(
      @{
        role  = "user"
        parts = @(@{ text = $fullPrompt })
      }
    )
    generationConfig = @{
      responseMimeType = "application/json"
      responseSchema   = @{
        type = "OBJECT"
        properties = @{
          duration_specified = @{ type = "BOOLEAN" }
          duration_months    = @{ type = "INTEGER"; minimum = 0 }
          renewal_mentioned  = @{ type = "BOOLEAN" }
        }
        required = @("duration_specified","duration_months","renewal_mentioned")
        propertyOrdering = @("duration_specified","duration_months","renewal_mentioned")
      }
      temperature = 0
    }
  }

  $uri = "https://generativelanguage.googleapis.com/v1beta/models/$ModelName`:generateContent"
  $headers = @{
    "x-goog-api-key" = $ApiKey
    "Content-Type"   = "application/json"
  }

  $resp = Invoke-WebJsonWithRetry -Uri $uri -Method POST -Headers $headers -Body (($body | ConvertTo-Json -Depth 100))

  $jsonText = $null
  if ($resp.candidates) {
    $jsonText = ($resp.candidates[0].content.parts | Where-Object { $_.text } | Select-Object -First 1).text
  }
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    $pf = $resp.promptFeedback | ConvertTo-Json -Depth 5
    throw "No JSON text from Gemini. PromptFeedback: $pf"
  }
  if ($AsJson) { return $jsonText }

  try {
    return $jsonText | ConvertFrom-Json
  } catch {
    throw "Gemini did not return valid JSON: $jsonText"
  }
}

# --- SEEK API: search page + job details
$seekSearchBase = "https://www.seek.com.au/api/jobsearch/v5/search"
$seekGraphqlUrl = "https://www.seek.com.au/graphql"

$commonHeaders = @{
  "Accept"                = "application/json, text/plain, */*"
  "Referer"               = "https://www.seek.com.au/jobs-in-information-communication-technology"
  "X-Seek-Site"           = "Chalice"
  "seek-request-brand"    = "seek"
  "seek-request-country"  = $SeekCountry
  "Sec-GPC"               = "1"
  "Pragma"                = "no-cache"
  "Cache-Control"         = "no-cache"
}

$graphqlHeaders = @{
  "Accept"                = "*/*"
  "seek-request-brand"    = "seek"
  "seek-request-country"  = $SeekCountry
  "X-Seek-Site"           = "chalice"
  "Origin"                = "https://www.seek.com.au"
}

function Get-SeekSearchPage {
  param([int]$Page)
  $params = @{
    siteKey               = "AU-Main"
    sourcesystem          = "houston"
    where                 = "All Australia"
    page                  = $Page
    classification        = $Classification
    worktype              = $WorkType
    pageSize              = $PageSize
    include               = "seodata,gptTargeting,relatedsearches,asyncpills"
    locale                = $SeekLocale
    source                = "FE_SERP"
    relatedSearchesCount  = 12
    queryHints            = "spellingCorrection"
    facets                = "salaryMin,workArrangement,workType"
    sortmode              = "ListedDate"
  }
  $uri = "$seekSearchBase?$(New-QueryString -Params $params)"
  Invoke-WebJsonWithRetry -Uri $uri -Method GET -Headers $commonHeaders
}

function Get-SeekJobDetailsContent {
  param([Parameter(Mandatory=$true)][string]$JobId)

  # Minimal GraphQL query requesting job content only (keeps payload small)
  $gqlQuery = @'
query jobDetails($jobId: ID!, $jobDetailsViewedCorrelationId: String!, $sessionId: String!, $zone: Zone!, $locale: Locale!, $languageCode: LanguageCodeIso!, $countryCode: CountryCodeIso2!, $timezone: Timezone!, $visitorId: UUID!, $enableApplicantCount: Boolean!, $enableWorkArrangements: Boolean!) {
  jobDetails(
    id: $jobId
    tracking: {channel: "WEB", jobDetailsViewedCorrelationId: $jobDetailsViewedCorrelationId, sessionId: $sessionId}
  ) {
    job {
      id
      content(platform: WEB)
    }
  }
}
'@

  $variables = @{
    jobId                           = $JobId
    jobDetailsViewedCorrelationId   = [guid]::NewGuid().Guid
    sessionId                       = [guid]::NewGuid().Guid
    zone                            = $SeekZone
    locale                          = $SeekLocale
    languageCode                    = "en"
    countryCode                     = $SeekCountry
    timezone                        = $SeekTimezone
    visitorId                       = [guid]::NewGuid().Guid
    enableApplicantCount            = $false
    enableWorkArrangements          = $true
  }

  $body = @{
    operationName = "jobDetails"
    variables     = $variables
    query         = $gqlQuery
  } | ConvertTo-Json -Depth 100

  $resp = Invoke-WebJsonWithRetry -Uri $seekGraphqlUrl -Method POST -Headers $graphqlHeaders -Body $body
  return $resp.data.jobDetails.job.content
}

# --- Ensure CSV exists with header
$csvDir = Split-Path -Parent $OutputCsvPath
if (-not [string]::IsNullOrWhiteSpace($csvDir)) {
  New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
}
if (-not (Test-Path -LiteralPath $OutputCsvPath)) {
  "CrawlTime,jobID,duration_specified,duration_months,renewal_mentioned" | Out-File -FilePath $OutputCsvPath -Encoding utf8
}

# --- Load existing job IDs
$existingIds = New-Object 'System.Collections.Generic.HashSet[string]'
try {
  $existing = Import-Csv -LiteralPath $OutputCsvPath
  foreach ($row in $existing) { [void]$existingIds.Add([string]$row.jobID) }
} catch { }

Write-Host "Loaded $($existingIds.Count) job IDs from CSV." -ForegroundColor Cyan

# --- Crawl loop
$processedNew = 0
$page = 1
while ($page -le $MaxPages) {
  Write-Host "Fetching page $page..." -ForegroundColor Cyan
  $search = Get-SeekSearchPage -Page $page
  $jobs = @()
  if ($search -and $search.data) { $jobs = @($search.data) }
  if ($jobs.Count -eq 0) {
    Write-Host "No results on page $page. Stopping." -ForegroundColor Yellow
    break
  }

  # Filter only truly new jobs by ID
  $newJobs = @()
  foreach ($j in $jobs) {
    $jid = [string]$j.id
    if (-not $existingIds.Contains($jid)) { $newJobs += $j }
  }

  if ($newJobs.Count -eq 0) {
    Write-Host "Page $page contains no new jobs. Stopping." -ForegroundColor Yellow
    break
  }

  foreach ($job in $newJobs) {
    $jid = [string]$job.id
    Write-Host "Processing new job $jid..." -ForegroundColor Green
    try {
      $html = Get-SeekJobDetailsContent -JobId $jid
      Start-Sleep -Milliseconds $DelayMsBetweenRequests

      if ([string]::IsNullOrWhiteSpace($html)) {
        Write-Host "No job description found for $jid. Skipping Gemini call." -ForegroundColor Yellow
        continue
      }

      $text = Convert-HtmlToPlainText -Html $html

      $result = Invoke-GeminiJobContractExtraction -ApiKey $env:GEMINI_API_KEY -JobText $text -ModelName $GeminiModel
      Start-Sleep -Milliseconds $DelayMsBetweenRequests

      $row = [PSCustomObject]@{
        CrawlTime          = [DateTime]::UtcNow.ToString("o")
        jobID              = $jid
        duration_specified = $result.duration_specified
        duration_months    = [int]$result.duration_months
        renewal_mentioned  = $result.renewal_mentioned
      }

      $row | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Append -Encoding utf8
      [void]$existingIds.Add($jid)
      $processedNew++
    } catch {
      Write-Warning "Failed to process job $jid: $($_.Exception.Message)"
    }
  }

  $page++
  Start-Sleep -Milliseconds $DelayMsBetweenRequests
}

Write-Host "Done. New jobs processed in this run: $processedNew" -ForegroundColor Cyan
