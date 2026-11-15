param(
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][string]$Version
)
# A new release of a HeMi app to winget: the manifests of the newest version already in microsoft/winget-pkgs are taken
# (their texts stay as they are), the version, the installer URL of the tag, its SHA256 from SHA256SUMS.txt and the date
# are changed, and a pull request is opened from the fork <owner>/winget-pkgs.
# Runs in the release workflows of the apps with GH_TOKEN = a token (public_repo) of the owner of the fork.
$ErrorActionPreference = 'Stop'
$Version = $Version.TrimStart('v')
$owner = 'Hemal1k'
$id = "$owner.$App"
$base = "manifests/h/$owner/$App"
$upstream = 'microsoft/winget-pkgs'
$fork = "$owner/winget-pkgs"

function Raw([string]$path) { (gh api "repos/$upstream/contents/$path" -H 'Accept: application/vnd.github.raw') -join "`n" }

# the newest version there (none: the first one is sent by hand)
$ErrorActionPreference = 'Continue'                                     # a 404 of gh is an answer here, not an error
$versions = @(gh api "repos/$upstream/contents/$base" --jq '.[].name' 2>$null)
$found = $LASTEXITCODE -eq 0 -and $versions
$ErrorActionPreference = 'Stop'
if (-not $found) { Write-Host "$id is not in winget yet - skipped."; exit 0 }
$prev = $versions | Sort-Object { [version]$_ } | Select-Object -Last 1
if ([version]$prev -ge [version]$Version) { Write-Host "$id $prev is there already - skipped."; exit 0 }
$open = gh pr list --repo $upstream --state open --search "$id $Version in:title" --json number --jq length
if ([int]$open -gt 0) { Write-Host "A pull request for $id $Version is open already - skipped."; exit 0 }

# the installer and its SHA256 from the release
$file = "$App-Setup.exe"
$sums = (Invoke-WebRequest "https://github.com/$owner/$App/releases/download/v$Version/SHA256SUMS.txt" -UseBasicParsing).Content
if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
$line = ($sums -split "`n") | Where-Object { $_ -match "\*?$([regex]::Escape($file))\s*$" } | Select-Object -First 1
if (-not $line) { throw "$file is not in SHA256SUMS.txt of v$Version." }
$sha = ($line -split '\s+')[0].ToUpper()
$date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')

$files = @{}
foreach ($name in "$id.yaml", "$id.installer.yaml", "$id.locale.en-US.yaml") {
    $t = Raw "$base/$prev/$name"
    $t = $t -replace "(?m)^PackageVersion: .*$", "PackageVersion: $Version"
    $t = $t -replace "/releases/download/v$([regex]::Escape($prev))/", "/releases/download/v$Version/"
    $t = $t -replace "/releases/tag/v$([regex]::Escape($prev))", "/releases/tag/v$Version"
    $t = $t -replace "(?m)^(\s*)InstallerSha256: .*$", "`${1}InstallerSha256: $sha"
    $t = $t -replace "(?m)^ReleaseDate: .*$", "ReleaseDate: $date"
    $files[$name] = $t.TrimEnd() + "`n"
}

# the branch in the fork (in step with upstream first), the files, the pull request
$branch = "$id-$Version"
gh api -X POST "repos/$fork/merge-upstream" -f branch=master | Out-Null
$sha1 = gh api "repos/$upstream/git/ref/heads/master" --jq .object.sha
gh api -X POST "repos/$fork/git/refs" -f "ref=refs/heads/$branch" -f "sha=$sha1" | Out-Null
foreach ($name in $files.Keys) {
    $body = @{ message = "$id $Version"; branch = $branch; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($files[$name])) } | ConvertTo-Json
    $tmp = New-TemporaryFile
    [IO.File]::WriteAllText($tmp, $body)
    gh api -X PUT "repos/$fork/contents/$base/$Version/$name" --input $tmp | Out-Null
    Remove-Item $tmp
}
$notes = @"
## 📖 Description
Update: **$id** $Version (from $prev) – a new release: https://github.com/$owner/$App/releases/tag/v$Version

Made by the release workflow of the app: the manifests of $prev with the new version, installer URL, SHA256 (from ``SHA256SUMS.txt`` of the release) and date.

## 📦 Manifest Checklist

- [x] Checked that there aren't other open [pull requests](https://github.com/microsoft/winget-pkgs/pulls) for the same manifest update/change
- [x] This PR only modifies one (1) manifest
"@
$nf = New-TemporaryFile
[IO.File]::WriteAllText($nf, $notes)
gh pr create --repo $upstream --head "${owner}:$branch" --base master --title "Update: $id to $Version" --body-file $nf
Remove-Item $nf
