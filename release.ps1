param(
    [string]$Version = "",
    [string]$TargetBranch = "",
    [string]$RepoSlug = "",
    [switch]$ReleaseNotesOnly,
    [switch]$SkipBuild,
    [switch]$AllowDirty,
    [switch]$NoPush,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Invoke-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found on PATH: $Name"
    }
}

function Get-VersionFromFile {
    $v = (Get-Content -Path "VERSION" -Raw).Trim()
    if (-not $v) {
        throw "VERSION file is empty."
    }
    return $v
}

function Test-SemVer {
    param([string]$Value)
    return $Value -match "^\d+\.\d+\.\d+$"
}

function Get-RepoSlugFromGit {
    $remoteUrl = (git remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read git origin URL. Pass -RepoSlug owner/repo."
    }
    $remoteUrl = "$remoteUrl".Trim()
    if ($remoteUrl -match "github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)(\.git)?$") {
        return "$($matches.owner)/$($matches.repo)"
    }
    throw "Origin remote is not a GitHub URL: $remoteUrl"
}

function Get-DefaultBranch {
    param([string]$ResolvedRepoSlug)
    $originHeadRef = "$((cmd /c "git symbolic-ref refs/remotes/origin/HEAD 2>nul"))".Trim()
    if ($LASTEXITCODE -eq 0 -and $originHeadRef -match "^refs/remotes/origin/(?<branch>.+)$") {
        return $matches.branch
    }

    $apiDefaultBranch = "$((gh api "repos/$ResolvedRepoSlug" --jq .default_branch 2>$null))".Trim()
    if ($LASTEXITCODE -eq 0 -and $apiDefaultBranch) {
        return $apiDefaultBranch
    }
    return "main"
}

function Get-DirtyFiles {
    $status = git status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed."
    }
    if (-not $status) {
        return @()
    }
    return @($status -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
}

function Replace-Once {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Replacement,
        [bool]$Required = $true
    )
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $updated = [regex]::Replace($raw, $Pattern, $Replacement, 1)
    if ($updated -eq $raw) {
        if ($Required) {
            throw "No match found while updating '$Path' with pattern '$Pattern'."
        }
        return
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path), $updated, $utf8NoBom)
}

function Set-VersionFiles {
    param([string]$TargetVersion)
    Set-Content -Path "VERSION" -Value "$TargetVersion`n" -Encoding ASCII
    Replace-Once -Path "package.json" -Pattern '"version"\s*:\s*"\d+\.\d+\.\d+"' -Replacement ('"version": "{0}"' -f $TargetVersion)
    Replace-Once -Path "package-lock.json" -Pattern '"version"\s*:\s*"\d+\.\d+\.\d+"' -Replacement ('"version": "{0}"' -f $TargetVersion)
    Replace-Once -Path "package-lock.json" -Pattern '"version"\s*:\s*"\d+\.\d+\.\d+"' -Replacement ('"version": "{0}"' -f $TargetVersion) -Required $false
}

function Get-ChangelogVersionSectionLines {
    param(
        [string]$TargetVersion,
        [string]$ChangelogPath = "CHANGELOG.md"
    )
    if (-not (Test-Path $ChangelogPath)) {
        throw "Missing changelog file: $ChangelogPath"
    }

    $escaped = [regex]::Escape($TargetVersion)
    $header = [regex]::new("^## \[$escaped\]", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $anyVersion = [regex]::new("^## \[.+\]")
    $lines = Get-Content -Path $ChangelogPath -Encoding UTF8
    $collecting = $false
    $out = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        if ($collecting) {
            if ($anyVersion.IsMatch($line)) { break }
            $out.Add($line)
            continue
        }
        if ($header.IsMatch($line)) { $collecting = $true }
    }

    if (-not $collecting) {
        throw "CHANGELOG.md has no section '## [$TargetVersion]'. Add it before running release.ps1."
    }
    return $out.ToArray()
}

function Get-ChangelogSubsectionBullets {
    param([string[]]$SectionLines)
    $map = @{}
    $current = $null
    foreach ($line in $SectionLines) {
        if ($line -match "^###\s+(.+)$") {
            $current = $matches[1].Trim()
            if (-not $map.ContainsKey($current)) {
                $map[$current] = [System.Collections.Generic.List[string]]::new()
            }
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match "^\s*-\s+(.*)$") {
            $map[$current].Add($matches[1].TrimEnd())
        }
    }
    return $map
}

function Format-BulletGroups {
    param(
        [hashtable]$Map,
        [string[]]$GroupOrder
    )
    $sb = [System.Text.StringBuilder]::new()
    foreach ($name in $GroupOrder) {
        if (-not $Map.ContainsKey($name)) { continue }
        $list = $Map[$name]
        if ($list.Count -eq 0) { continue }
        [void]$sb.AppendLine("**$name**")
        foreach ($item in $list) {
            [void]$sb.AppendLine("- $item")
        }
        [void]$sb.AppendLine()
    }
    return ($sb.ToString().TrimEnd())
}

function Get-ReleaseNotePartsFromChangelog {
    param([string]$TargetVersion)
    $sectionLines = Get-ChangelogVersionSectionLines -TargetVersion $TargetVersion
    $map = Get-ChangelogSubsectionBullets -SectionLines $sectionLines

    $highlights = Format-BulletGroups -Map $map -GroupOrder @("Added", "Changed", "Deprecated", "Removed")
    if ([string]::IsNullOrWhiteSpace($highlights)) {
        $highlights = "- *No Added/Changed/Deprecated/Removed entries for this release.*"
    }
    $fixes = Format-BulletGroups -Map $map -GroupOrder @("Fixed", "Security")
    if ([string]::IsNullOrWhiteSpace($fixes)) {
        $fixes = "- *None.*"
    }
    return @{
        Highlights = $highlights
        Fixes      = $fixes
    }
}

function New-ReleaseNotesFile {
    param([string]$TargetVersion)
    $templatePath = "RELEASE_NOTES_TEMPLATE.md"
    if (-not (Test-Path $templatePath)) {
        throw "Missing template file: $templatePath"
    }

    $parts = Get-ReleaseNotePartsFromChangelog -TargetVersion $TargetVersion
    $template = Get-Content -Path $templatePath -Raw -Encoding UTF8
    $validation = if ($SkipBuild) { '- CSS build skipped (`-SkipBuild`).' } else { '- `npm run build:css` completed successfully.' }
    $notes = $template.
        Replace("{{VERSION}}", $TargetVersion).
        Replace("{{DATE}}", (Get-Date -Format "yyyy-MM-dd")).
        Replace("{{HIGHLIGHTS}}", $parts.Highlights).
        Replace("{{FIXES}}", $parts.Fixes).
        Replace("{{VALIDATION}}", $validation)

    $notesPath = Join-Path $env:TEMP "mainplate_release_notes_$TargetVersion.md"
    Set-Content -Path $notesPath -Value $notes -Encoding UTF8
    return $notesPath
}

function Invoke-CheckedNative {
    param(
        [string]$Command,
        [string]$ErrorMessage
    )
    if ($DryRun) {
        Write-Host "[dry-run] $Command" -ForegroundColor Yellow
        return
    }
    Invoke-Expression $Command
    if ($LASTEXITCODE -ne 0) {
        throw $ErrorMessage
    }
}

Assert-Command -Name git
Assert-Command -Name gh
Assert-Command -Name npm

$currentVersion = Get-VersionFromFile
$targetVersion = if ($Version) { $Version.Trim() } else { $currentVersion }
if (-not (Test-SemVer -Value $targetVersion)) {
    throw "Version must match semantic version format MAJOR.MINOR.PATCH (for example: 1.4.0)."
}

$resolvedRepoSlug = if ($RepoSlug) { $RepoSlug.Trim() } else { Get-RepoSlugFromGit }
if (-not $resolvedRepoSlug) {
    throw "Could not resolve GitHub repo slug. Pass -RepoSlug owner/repo."
}

$resolvedBranch = if ($TargetBranch) { $TargetBranch.Trim() } else { Get-DefaultBranch -ResolvedRepoSlug $resolvedRepoSlug }
$tag = $targetVersion

if (-not $AllowDirty) {
    $dirty = Get-DirtyFiles
    if ($dirty.Count -gt 0 -and -not $ReleaseNotesOnly) {
        throw "Working tree is dirty. Commit/stash changes first, or rerun with -AllowDirty."
    }
}

Invoke-Step "Preparing version metadata"
if ($targetVersion -ne $currentVersion) {
    if ($DryRun) {
        Write-Host "[dry-run] Would update VERSION, package.json, and package-lock.json to $targetVersion." -ForegroundColor Yellow
    }
    else {
        Set-VersionFiles -TargetVersion $targetVersion
        Write-Host "Updated version files to $targetVersion."
    }
}
else {
    Write-Host "VERSION already at $targetVersion."
}

Invoke-Step "Generating release notes from CHANGELOG"
$notesPath = New-ReleaseNotesFile -TargetVersion $targetVersion
Write-Host "Release notes file: $notesPath"

if ($ReleaseNotesOnly) {
    Invoke-Step "Updating release notes only"
    Invoke-CheckedNative -Command "gh release edit `"$tag`" --repo `"$resolvedRepoSlug`" --title `"$tag`" --notes-file `"$notesPath`" --latest" -ErrorMessage "Failed to update GitHub release notes."
    Write-Host "Release notes updated for $tag."
    exit 0
}

if (-not $SkipBuild) {
    Invoke-Step "Running CSS build"
    if ($DryRun) {
        Write-Host "[dry-run] npm run build:css" -ForegroundColor Yellow
    }
    else {
        npm run build:css
        if ($LASTEXITCODE -ne 0) {
            throw "CSS build failed."
        }
    }
}

Invoke-Step "Creating commit and tag"
$existingTag = "$((cmd /c "git tag --list $tag"))".Trim()
if ($existingTag) {
    throw "Tag already exists: $tag"
}

Invoke-CheckedNative -Command "git add -A" -ErrorMessage "git add failed."

if ($DryRun) {
    Write-Host "[dry-run] Would commit staged changes with message: Release $targetVersion." -ForegroundColor Yellow
}
else {
    git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "No staged changes to commit; using current HEAD for release."
    }
    else {
        git commit -m "Release $targetVersion."
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed."
        }
    }
}

Invoke-CheckedNative -Command "git tag -a $tag -m `"Release $targetVersion`"" -ErrorMessage "Failed to create tag."

if (-not $NoPush) {
    Invoke-Step "Pushing branch and tag"
    Invoke-CheckedNative -Command "git push origin HEAD" -ErrorMessage "Failed to push branch."
    Invoke-CheckedNative -Command "git push origin $tag" -ErrorMessage "Failed to push tag."
}
else {
    Write-Host "Skipping push due to -NoPush."
}

Invoke-Step "Publishing GitHub release"
$releaseExists = "$((cmd /c "gh release view $tag --repo $resolvedRepoSlug --json tagName --jq .tagName 2>nul"))".Trim()
if ($releaseExists -eq $tag) {
    Invoke-CheckedNative -Command "gh release edit `"$tag`" --repo `"$resolvedRepoSlug`" --title `"$tag`" --notes-file `"$notesPath`" --latest" -ErrorMessage "Failed to update existing GitHub release."
}
else {
    Invoke-CheckedNative -Command "gh release create `"$tag`" --repo `"$resolvedRepoSlug`" --title `"$tag`" --notes-file `"$notesPath`" --target `"$resolvedBranch`" --latest" -ErrorMessage "Failed to create GitHub release."
}

Write-Host ""
Write-Host "Release complete: $tag" -ForegroundColor Green
