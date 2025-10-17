<#!
Scrapes SEEK API pages for ICT Contract jobs, stops when a page contains no new jobs
(compared to a local CSV), fetches job details (GraphQL), sends the description
to Google Gemini (Structured Output) to extract contract duration signals AND start timing,
and appends results to CSV.

CSV columns:
- CrawlTime          (UTC ISO-8601)
- jobID              (SEEK job id)
- duration_specified (bool)
- duration_months    (int)
- renewal_mentioned  (bool)
- start_specified    (bool)
- start_iso          (string, YYYY-MM-DD or empty)
- start_descriptor   (string)

Usage (locally):
  pwsh ./scripts/scrape-seek.ps1 -OutputCsvPath "data/seek_jobs.csv" -MaxPages 50

In CI:
  The script reads the API key from $env:GEMINI_API_KEY.
#>

[CmdletBinding()]
param(
  [string]$OutputCsvPath = "data/seek_jobs.csv",
  [int]$MaxPages = 10,
  [int]$PageSize = 22,
  [string]$Classification = "6281",      # ICT
  [string]$WorkType = "244",             # Contract/Temp
  [string]$SeekLocale = "en-AU",
  [string]$SeekCountry = "AU",
  [string]$SeekZone = "anz-1",
  [string]$SeekTimezone = "Europe/Berlin",
  [string]$GeminiModel = "gemini-2.5-flash-lite",
  [int]$DelayMsBetweenRequests = 200,
  [int]$DelayMsAfterGeminiRequest = 4000
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
  return $Html # keep HTML, Gemini can cope
}

# --- Gemini structured extraction (extended with start timing)
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

Also extract the start timing:
- start_specified (boolean): true if a start is mentioned (e.g., a concrete date, "ASAP", "immediately", "start in January 2026", "start after notice period"); false if there is no mention of when the role starts.
- start_iso (string): if an explicit date is provided, output ISO format YYYY-MM-DD. If only a month/year is given (e.g., "January 2026"), use the first day of that month (e.g., "2026-01-01"). Otherwise output an empty string "".
- start_descriptor (string): short human-readable phrase capturing what is said about the start, e.g., "ASAP", "immediately", "January 2026", "after 4 weeks' notice", "Q1 2026", or "not specified" if start_specified is false.

Ignore probation periods, notice periods that are not tied to start timing, application deadlines, closing dates, and similar info.

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
          start_specified    = @{ type = "BOOLEAN" }
          start_iso          = @{ type = "STRING" }
          start_descriptor   = @{ type = "STRING" }
        }
        required = @("duration_specified","duration_months","renewal_mentioned","start_specified","start_iso","start_descriptor")
        propertyOrdering = @("duration_specified","duration_months","renewal_mentioned","start_specified","start_iso","start_descriptor")
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
  $uri = "$($seekSearchBase)?$(New-QueryString -Params $params)"
  Invoke-WebJsonWithRetry -Uri $uri -Method GET -Headers $commonHeaders
}

function Get-SeekJobDetailsContent {
  param([Parameter(Mandatory=$true)][string]$JobId)

  $gqlQuery = "{`"operationName`":`"jobDetails`",`"variables`":{`"jobId`":`"$($JobId)`",`"jobDetailsViewedCorrelationId`":`"$((New-Guid).Guid)`",`"sessionId`":`"$((New-Guid).Guid)`",`"zone`":`"anz-1`",`"locale`":`"en-AU`",`"languageCode`":`"en`",`"countryCode`":`"AU`",`"timezone`":`"Europe/Berlin`",`"visitorId`":`"$((New-Guid).Guid)`",`"enableApplicantCount`":false,`"enableWorkArrangements`":true},`"query`":`"query jobDetails(`$jobId: ID!, `$jobDetailsViewedCorrelationId: String!, `$sessionId: String!, `$zone: Zone!, `$locale: Locale!, `$languageCode: LanguageCodeIso!, `$countryCode: CountryCodeIso2!, `$timezone: Timezone!, `$visitorId: UUID!, `$enableApplicantCount: Boolean!, `$enableWorkArrangements: Boolean!) {\n  jobDetails(\n    id: `$jobId\n    tracking: {channel: \`"WEB\`", jobDetailsViewedCorrelationId: `$jobDetailsViewedCorrelationId, sessionId: `$sessionId}\n  ) {\n    ...job\n    insights @include(if: `$enableApplicantCount) {\n      ... on ApplicantCount {\n        countLabel(locale: `$locale)\n        volumeLabel(locale: `$locale)\n        count\n        __typename\n      }\n      __typename\n    }\n    learningInsights(platform: WEB, zone: `$zone, locale: `$locale) {\n      analytics\n      content\n      __typename\n    }\n    gfjInfo {\n      location {\n        countryCode\n        country(locale: `$locale)\n        suburb(locale: `$locale)\n        region(locale: `$locale)\n        state(locale: `$locale)\n        postcode\n        __typename\n      }\n      workTypes {\n        label\n        __typename\n      }\n      company {\n        url(locale: `$locale, zone: `$zone)\n        __typename\n      }\n      __typename\n    }\n    workArrangements(visitorId: `$visitorId, channel: \`"JDV\`", platform: WEB) @include(if: `$enableWorkArrangements) {\n      arrangements {\n        type\n        label(locale: `$locale)\n        __typename\n      }\n      label(locale: `$locale)\n      __typename\n    }\n    seoInfo {\n      normalisedRoleTitle\n      workType\n      classification\n      subClassification\n      where(zone: `$zone)\n      broaderLocationName(locale: `$locale)\n      normalisedOrganisationName\n      __typename\n    }\n    __typename\n  }\n}\n\nfragment job on JobDetails {\n  job {\n    sourceZone\n    tracking {\n      adProductType\n      classificationInfo {\n        classificationId\n        classification\n        subClassificationId\n        subClassification\n        __typename\n      }\n      hasRoleRequirements\n      isPrivateAdvertiser\n      locationInfo {\n        area\n        location\n        locationIds\n        __typename\n      }\n      workTypeIds\n      postedTime\n      __typename\n    }\n    id\n    title\n    phoneNumber\n    isExpired\n    expiresAt {\n      dateTimeUtc\n      __typename\n    }\n    isLinkOut\n    contactMatches {\n      type\n      value\n      __typename\n    }\n    isVerified\n    abstract\n    content(platform: WEB)\n    status\n    listedAt {\n      label(context: JOB_POSTED, length: SHORT, timezone: `$timezone, locale: `$locale)\n      dateTimeUtc\n      __typename\n    }\n    salary {\n      currencyLabel(zone: `$zone)\n      label\n      __typename\n    }\n    shareLink(platform: WEB, zone: `$zone, locale: `$locale)\n    workTypes {\n      label(locale: `$locale)\n      __typename\n    }\n    advertiser {\n      id\n      name(locale: `$locale)\n      isVerified\n      registrationDate {\n        dateTimeUtc\n        __typename\n      }\n      __typename\n    }\n    location {\n      label(locale: `$locale, type: LONG)\n      __typename\n    }\n    classifications {\n      label(languageCode: `$languageCode)\n      __typename\n    }\n    products {\n      branding {\n        id\n        cover {\n          url\n          __typename\n        }\n        thumbnailCover: cover(isThumbnail: true) {\n          url\n          __typename\n        }\n        logo {\n          url\n          __typename\n        }\n        __typename\n      }\n      bullets\n      questionnaire {\n        questions\n        __typename\n      }\n      video {\n        url\n        position\n        __typename\n      }\n      displayTags {\n        label(locale: `$locale)\n        __typename\n      }\n      __typename\n    }\n    __typename\n  }\n  companyProfile(zone: `$zone) {\n    id\n    name\n    companyNameSlug\n    shouldDisplayReviews\n    branding {\n      logo\n      __typename\n    }\n    overview {\n      description {\n        paragraphs\n        __typename\n      }\n      industry\n      size {\n        description\n        __typename\n      }\n      website {\n        url\n        __typename\n      }\n      __typename\n    }\n    reviewsSummary {\n      overallRating {\n        numberOfReviews {\n          value\n          __typename\n        }\n        value\n        __typename\n      }\n      __typename\n    }\n    perksAndBenefits {\n      title\n      __typename\n    }\n    __typename\n  }\n  companySearchUrl(zone: `$zone, languageCode: `$languageCode)\n  companyTags {\n    key(languageCode: `$languageCode)\n    value\n    __typename\n  }\n  restrictedApplication(countryCode: `$countryCode) {\n    label(locale: `$locale)\n    __typename\n  }\n  sourcr {\n    image\n    imageMobile\n    link\n    __typename\n  }\n  __typename\n}`"}"

  $resp = Invoke-WebJsonWithRetry -Uri $seekGraphqlUrl -Method POST -Headers $graphqlHeaders -Body $gqlQuery
  return $resp.data.jobDetails.job.content
}

# --- Ensure CSV exists with header (and migrate if needed)
$csvDir = Split-Path -Parent $OutputCsvPath
if (-not [string]::IsNullOrWhiteSpace($csvDir)) {
  New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
}

$desiredHeader = "CrawlTime,jobID,duration_specified,duration_months,renewal_mentioned,start_specified,start_iso,start_descriptor"

if (-not (Test-Path -LiteralPath $OutputCsvPath)) {
  $desiredHeader | Out-File -FilePath $OutputCsvPath -Encoding utf8
} else {
  # migrate if header lacks new columns
  $firstLine = (Get-Content -LiteralPath $OutputCsvPath -TotalCount 1)
  if ($firstLine -ne $desiredHeader) {
    try {
      $existingRows = Import-Csv -LiteralPath $OutputCsvPath
      # Add missing columns with defaults
      foreach ($r in $existingRows) {
        if (-not $r.PSObject.Properties.Name.Contains("start_specified")) { $r | Add-Member -NotePropertyName start_specified -NotePropertyValue "" }
        if (-not $r.PSObject.Properties.Name.Contains("start_iso"))       { $r | Add-Member -NotePropertyName start_iso       -NotePropertyValue "" }
        if (-not $r.PSObject.Properties.Name.Contains("start_descriptor")){ $r | Add-Member -NotePropertyName start_descriptor-NotePropertyValue "" }
      }
      # Re-export with new header
      $existingRows | Select-Object CrawlTime,jobID,duration_specified,duration_months,renewal_mentioned,start_specified,start_iso,start_descriptor `
        | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding utf8
      # Ensure header is exact (some PS versions add BOM/order)
      $tmp = Get-Content -LiteralPath $OutputCsvPath
      $tmp[0] = $desiredHeader
      Set-Content -LiteralPath $OutputCsvPath -Value $tmp -Encoding utf8
      Write-Host "Migrated CSV header to include start_* columns." -ForegroundColor Green
    } catch {
      Write-Warning "CSV migration failed: $($_.Exception.Message)"
    }
  }
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
      Start-Sleep -Milliseconds $DelayMsAfterGeminiRequest

      $row = [PSCustomObject]@{
        CrawlTime          = [DateTime]::UtcNow.ToString("o")
        jobID              = $jid
        duration_specified = $result.duration_specified
        duration_months    = [int]$result.duration_months
        renewal_mentioned  = $result.renewal_mentioned
        start_specified    = $result.start_specified
        start_iso          = [string]$result.start_iso
        start_descriptor   = [string]$result.start_descriptor
      }

      # Ensure column order matches CSV
      $row | Select-Object CrawlTime,jobID,duration_specified,duration_months,renewal_mentioned,start_specified,start_iso,start_descriptor `
          | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Append -Encoding utf8

      [void]$existingIds.Add($jid)
      $processedNew++
    } catch {
      Write-Warning "Failed to process job $jid : $($_.Exception.Message)"
    }
  }

  $page++
  Start-Sleep -Milliseconds $DelayMsBetweenRequests
}

Write-Host "Done. New jobs processed in this run: $processedNew" -ForegroundColor Cyan
