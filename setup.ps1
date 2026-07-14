<#
.SYNOPSIS
  Onboard one or more GitHub repos to Scrutineer in a single command.

.DESCRIPTION
  For each repo it: sets the API key secret(s), sets the model/routing Variables, and commits
  the caller workflow (.github/workflows/scrutineer.yml). If the default branch is
  protected, the caller file is added via a pull request instead (which you merge).

  Keys are read from env vars if present, else prompted (masked); they are piped straight to
  `gh secret set` and never written to disk or the console.

.PARAMETER Repos
  One or more "owner/repo" to onboard.

.PARAMETER Reviewers
  The REVIEWERS value, e.g. "gemini", "gemini,z-ai/glm-5.2", "google/gemini-2.5-flash,z-ai/glm-5.2".

.PARAMETER OpenRouterHosts
  Optional allow-list of host slugs for OpenRouter models (e.g. "novita,fireworks,together,gmicloud").

.EXAMPLE
  ./setup.ps1 -Repos me/app -Reviewers "gemini"

.EXAMPLE
  ./setup.ps1 -Repos me/app,me/lib -Reviewers "gemini,z-ai/glm-5.2" -OpenRouterHosts "novita,fireworks,together,gmicloud"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string[]] $Repos,
  [string] $Reviewers = 'gemini',
  [string] $OpenRouterHosts = '',
  [string] $OpenRouterSort = '',
  [string] $OpenRouterMaxPrice = '',
  [string] $Ref = 'jonespr1/scrutineer/.github/workflows/review.yml@v1',
  [string] $Branch = 'main'
)

$ErrorActionPreference = 'Continue'
$script:OpenedPRs = @()

# Caller workflow written into each repo. {{REF}} is replaced with -Ref.
$CallerTemplate = @'
name: 'Scrutineer'
on:
  pull_request:
    types: [opened, reopened]
  issue_comment:
    types: [created]
jobs:
  review:
    if: >-
      (github.event_name == 'pull_request' &&
       github.event.pull_request.user.type != 'Bot') ||
      (github.event.issue.pull_request != null &&
       contains(github.event.comment.body, '@review') &&
       contains(fromJson('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association))
    permissions:
      contents: 'read'
      issues: 'write'
      pull-requests: 'write'
    uses: '{{REF}}'
    # Explicit secrets, NOT "secrets: inherit" -- inherit hands the called workflow
    # every repo secret and trips SAST / secret-scan gates. review.yml declares
    # exactly these two under on.workflow_call.secrets.
    secrets:
      GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}
      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
'@

function Assert-Prereqs {
  gh --version *> $null; if ($LASTEXITCODE -ne 0) { throw "GitHub CLI (gh) not found." }
  gh auth status *> $null; if ($LASTEXITCODE -ne 0) { throw "Run 'gh auth login' first." }
}
function Read-Secret {
  param([string]$Prompt, [string]$EnvName)
  if ($EnvName -and (Test-Path "env:$EnvName")) { return (Get-Item "env:$EnvName").Value }
  $sec = Read-Host $Prompt -AsSecureString
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Set-RepoVar    { param($Repo,$Name,$Value) gh variable set $Name --repo $Repo --body $Value *> $null }
function Remove-RepoVar { param($Repo,$Name) gh variable delete $Name --repo $Repo *> $null }
function Get-FileSha {
  param($Repo,$Path,$Ref)
  $out = gh api "repos/$Repo/contents/$Path`?ref=$Ref" 2>$null
  if ($LASTEXITCODE -eq 0) { try { return [string]($out | ConvertFrom-Json).sha } catch { return '' } }
  return ''
}
function Invoke-PutFile {
  param($Repo,$Path,$ContentB64,$Message,$TargetBranch,$Sha)
  $body = @{ message=$Message; content=$ContentB64; branch=$TargetBranch }
  if ($Sha) { $body.sha = $Sha }
  $tmp = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($tmp, ($body | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    $out = gh api "repos/$Repo/contents/$Path" -X PUT --input $tmp 2>&1
    return @{ Code = $LASTEXITCODE; Out = ($out | Out-String) }
  } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
function Commit-Caller {
  param($Repo,$B64)
  $path = '.github/workflows/scrutineer.yml'
  $sha = Get-FileSha -Repo $Repo -Path $path -Ref $Branch
  $r = Invoke-PutFile -Repo $Repo -Path $path -ContentB64 $B64 -Message 'Add Scrutineer reviewer' -TargetBranch $Branch -Sha $sha
  if ($r.Code -eq 0) { Write-Host '    caller workflow committed' -ForegroundColor Green; return }
  if ($r.Out -match 'rule violations|protected branch|must be made through a pull request') {
    Write-Host '    default branch protected - opening a PR' -ForegroundColor Yellow
    $head = gh api "repos/$Repo/git/ref/heads/$Branch" -q '.object.sha' 2>$null
    $nb = 'chore/add-scrutineer'
    gh api "repos/$Repo/git/refs" -f "ref=refs/heads/$nb" -f "sha=$head" *> $null
    $sha2 = Get-FileSha -Repo $Repo -Path $path -Ref $nb
    $r2 = Invoke-PutFile -Repo $Repo -Path $path -ContentB64 $B64 -Message 'Add Scrutineer reviewer' -TargetBranch $nb -Sha $sha2
    if ($r2.Code -ne 0) { throw "Failed writing caller to $Repo`n$($r2.Out)" }
    $pr = gh pr create --repo $Repo --base $Branch --head $nb --title 'Add Scrutineer reviewer' --body 'Adds the Scrutineer AI PR reviewer. Merge to enable.' 2>&1 | Select-Object -Last 1
    if ($LASTEXITCODE -eq 0) {
      $script:OpenedPRs += "$Repo -> $pr"
      Write-Host "    PR opened: $pr" -ForegroundColor Green
    } else {
      # e.g. a PR from a previous run already exists — don't record the error text as a URL.
      Write-Host "    PR create skipped/failed: $pr" -ForegroundColor DarkGray
    }
    return
  }
  throw "Failed writing caller to $Repo`n$($r.Out)"
}

Assert-Prereqs

# Decide which keys are needed from the reviewer spec.
$needGemini = ($Reviewers -match '(^|,)\s*gemini(\s|:|,|$)')
$needOpenRouter = ($Reviewers -split ',' | Where-Object { $_.Trim() -and ($_.Trim() -notmatch '^gemini(:|$)') }).Count -gt 0
$geminiKey = $null; $orKey = $null
if ($needGemini)     { $geminiKey = Read-Secret 'Paste your Gemini API key (input hidden)' 'GEMINI_API_KEY' }
if ($needOpenRouter) { $orKey     = Read-Secret 'Paste your OpenRouter API key (input hidden)' 'OPENROUTER_API_KEY' }

$callerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($CallerTemplate -replace '\{\{REF\}\}', $Ref)))

foreach ($repo in $Repos) {
  $repo = $repo.Trim(); if (-not $repo) { continue }
  Write-Host "==> Onboarding $repo  [REVIEWERS=$Reviewers]" -ForegroundColor Cyan
  if ($geminiKey) { $geminiKey | gh secret set GEMINI_API_KEY     --repo $repo *> $null; Write-Host '    GEMINI_API_KEY set' -ForegroundColor Green }
  if ($orKey)     { $orKey     | gh secret set OPENROUTER_API_KEY --repo $repo *> $null; Write-Host '    OPENROUTER_API_KEY set' -ForegroundColor Green }
  Set-RepoVar $repo 'REVIEWERS' $Reviewers
  if ($OpenRouterHosts)    { Set-RepoVar $repo 'OPENROUTER_HOSTS' $OpenRouterHosts }    else { Remove-RepoVar $repo 'OPENROUTER_HOSTS' }
  if ($OpenRouterSort)     { Set-RepoVar $repo 'OPENROUTER_SORT' $OpenRouterSort }      else { Remove-RepoVar $repo 'OPENROUTER_SORT' }
  if ($OpenRouterMaxPrice) { Set-RepoVar $repo 'OPENROUTER_MAXPRICE' $OpenRouterMaxPrice } else { Remove-RepoVar $repo 'OPENROUTER_MAXPRICE' }
  Commit-Caller -Repo $repo -B64 $callerB64
}
$geminiKey = $null; $orKey = $null

Write-Host ''
if ($script:OpenedPRs.Count -gt 0) {
  Write-Host 'Protected repos - merge these PRs to finish:' -ForegroundColor Yellow
  $script:OpenedPRs | ForEach-Object { Write-Host "  $_" }
}
Write-Host "Done. Open a PR (or comment '@review') in an onboarded repo to test." -ForegroundColor Cyan
