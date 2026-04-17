# verify.ps1 - Consistency checker for feathered-unicorns data files

$ErrorCount = 0
$WarningCount = 0

# ---------------------------------------------------------------------------
# Asset validation (on-demand: only checks paths actually referenced)
# ---------------------------------------------------------------------------

$_ue4Resolved = Resolve-Path "$PSScriptRoot\..\..\ContractorsVR\ModProject\Content" -ErrorAction SilentlyContinue
$script:ue4Content = if ($_ue4Resolved) { $_ue4Resolved.Path.TrimEnd('\') } else { $null }
$script:assetCache = @{}   # "CLASS|/Game/..." or "ITEM|/Game/..." -> $true/$false

function Get-GameAssetFile([string]$gamePath) {
    # /Game/some/path/Asset.ClassName_C  ->  <Content>\some\path\Asset.uasset
    $rel = ($gamePath -replace '^/Game/') -replace '\.[^/\\]+$'
    return Join-Path $script:ue4Content ($rel.Replace('/', '\') + '.uasset')
}

function Get-GameClassName([string]$gamePath) {
    if ($gamePath -match '\.([^/.]+)$') { return $Matches[1] } else { return $null }
}

function Test-ClassAsset([string]$gamePath) {
    $key = "CLASS|$gamePath"
    if ($script:assetCache.ContainsKey($key)) { return $script:assetCache[$key] }
    $f = Get-GameAssetFile $gamePath
    if (-not (Test-Path $f)) { $script:assetCache[$key] = $false; return $false }
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($f))
    $className = Get-GameClassName $gamePath
    $ok = $text.Contains('ZomboyLoadoutHolderDataInfo') -and ($null -eq $className -or $text.Contains($className))
    $script:assetCache[$key] = $ok
    return $ok
}

function Test-ItemAsset([string]$gamePath) {
    $key = "ITEM|$gamePath"
    if ($script:assetCache.ContainsKey($key)) { return $script:assetCache[$key] }
    $f = Get-GameAssetFile $gamePath
    if (-not (Test-Path $f)) { $script:assetCache[$key] = $false; return $false }
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($f))
    $className = Get-GameClassName $gamePath
    $ok = $text.Contains('ZomboyInteractableActor') -and ($null -eq $className -or $text.Contains($className))
    $script:assetCache[$key] = $ok
    return $ok
}

$script:CurrentSection      = ''
$script:CurrentSectionPrinted = $false

function Write-Section($title) {
    $script:CurrentSection       = $title
    $script:CurrentSectionPrinted = $false
}

function Flush-Section {
    if (-not $script:CurrentSectionPrinted -and $script:CurrentSection -ne '') {
        Write-Host ""
        Write-Host "--- $($script:CurrentSection) ---" -ForegroundColor Cyan
        $script:CurrentSectionPrinted = $true
    }
}

function Write-Issue($level, $message) {
    Flush-Section
    if ($level -eq 'ERROR') {
        Write-Host "  [ERROR] $message" -ForegroundColor Red
        $script:ErrorCount++
    } else {
        Write-Host "  [WARN]  $message" -ForegroundColor Yellow
        $script:WarningCount++
    }
}

# ---------------------------------------------------------------------------
# Parse users.txt
# ---------------------------------------------------------------------------

Write-Section "Parsing users.txt"
Flush-Section

$usersFile  = "$PSScriptRoot\..\users.txt"
$usersLines = Get-Content $usersFile

$users  = @{}   # name -> uid
$groups = @{}   # groupname -> [member names]

$inUsers  = $false
$inGroups = $false
$i = 0

while ($i -lt $usersLines.Count) {
    $line = $usersLines[$i].Trim()

    if ($line -eq '#region USERS')  { $inUsers = $true;  $inGroups = $false }
    if ($line -eq '#endregion')     { $inUsers = $false; $inGroups = $false }
    if ($line -eq '#region GROUPS') { $inGroups = $true; $inUsers  = $false }

    if ($inUsers -and $line -match '^NAME:\s*(.+)') {
        $name = $Matches[1].Trim()
        $nextLine = if ($i + 1 -lt $usersLines.Count) { $usersLines[$i + 1].Trim() } else { '' }
        if ($nextLine -match '^UID:\s*(.*)') {
            $uid = $Matches[1].Trim()
            if ($users.ContainsKey($name)) {
                Write-Issue 'ERROR' "Duplicate NAME in users.txt: '$name'"
            } else {
                $users[$name] = $uid
            }
            $i += 2
            continue
        }
    }

    if ($inGroups -and $line -match '^GROUP:\s*(.+)') {
        $groupName = $Matches[1].Trim()
        $nextLine  = if ($i + 1 -lt $usersLines.Count) { $usersLines[$i + 1].Trim() } else { '' }
        if ($nextLine -match '^MEMBERS:\s*(.+)') {
            $members = $Matches[1].Trim() -split ',' | ForEach-Object { $_.Trim() }
            $groups[$groupName] = $members
            $i += 2
            continue
        }
    }

    $i++
}

Write-Host "  Found $($users.Count) users, $($groups.Count) groups."

# Check for duplicate UIDs
Write-Section "Checking for duplicate UIDs in users.txt"
$uidsSeen = @{}
foreach ($entry in $users.GetEnumerator()) {
    $uid = $entry.Value
    if ($uid -eq '') {
        Write-Issue 'WARN' "User '$($entry.Key)' has an empty UID"
    } elseif ($uidsSeen.ContainsKey($uid)) {
        Write-Issue 'ERROR' "Duplicate UID '$uid' on users '$($uidsSeen[$uid])' and '$($entry.Key)'"
    } else {
        $uidsSeen[$uid] = $entry.Key
    }
}

# ---------------------------------------------------------------------------
# Check group members exist as users
# ---------------------------------------------------------------------------

Write-Section "Checking group members reference valid users"

foreach ($group in $groups.GetEnumerator()) {
    foreach ($member in $group.Value) {
        if (-not $users.ContainsKey($member)) {
            Write-Issue 'ERROR' "Group '@$($group.Key)' references unknown user: '$member'"
        }
    }
}

# ---------------------------------------------------------------------------
# Parse and check loadout overrides
# ---------------------------------------------------------------------------

Write-Section "Checking loadout-overrides"

$validSlots = [System.Collections.Generic.HashSet[string]]([string[]]@('Hat','Melee','Misc','Primary','Sidearm','Pda','Watch'))

$canValidateAssets = $null -ne $script:ue4Content
Flush-Section
if ($canValidateAssets) {
    Write-Host "  Asset validation enabled (on-demand per referenced path)." -ForegroundColor DarkGray
} else {
    Write-Host "  Asset validation skipped (ContractorsVR/ModProject/Content not found)." -ForegroundColor Yellow
}

$overrideFiles = Get-ChildItem "$PSScriptRoot\..\loadout-overrides\*.txt"

foreach ($file in $overrideFiles) {
    Flush-Section
    Write-Host "  Checking: $($file.Name)"
    $lines = Get-Content $file.FullName

    # Parse into blocks: each block is CLASS/SLOT/ITEM/PLAYERS
    $blocks    = [System.Collections.Generic.List[hashtable]]::new()
    $cur       = $null
    $blockLine = 0

    for ($j = 0; $j -lt $lines.Count; $j++) {
        $line = $lines[$j].Trim()
        if ($line -eq '') { continue }

        if ($line -match '^CLASS:\s*(.*)') {
            if ($null -ne $cur) { $blocks.Add($cur) }
            $cur = @{ Class = $Matches[1].Trim(); Slot = $null; Item = $null; Players = $null; Line = ($j + 1) }
        } elseif ($line -match '^SLOT:\s*(.*)') {
            if ($null -ne $cur) { $cur.Slot    = $Matches[1].Trim() }
        } elseif ($line -match '^ITEM:\s*(.*)') {
            if ($null -ne $cur) { $cur.Item    = $Matches[1].Trim() }
        } elseif ($line -match '^PLAYERS:\s*(.*)') {
            if ($null -ne $cur) { $cur.Players = $Matches[1].Trim() }
        }
    }
    if ($null -ne $cur) { $blocks.Add($cur) }

    # Track class+slot+player combos for duplicate detection
    $seen = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($b in $blocks) {
        $loc = "$($file.Name) line $($b.Line)"

        # Required fields present and non-empty
        if ([string]::IsNullOrWhiteSpace($b.Class))       { Write-Issue 'ERROR' "$loc : CLASS is empty" }
        elseif ($canValidateAssets -and -not (Test-ClassAsset $b.Class)) {
            Write-Issue 'ERROR' "$loc : CLASS '$($b.Class)' not found in scanned assets"
        }
        if ($null -eq $b.Slot)                             { Write-Issue 'ERROR' "$loc : SLOT field missing" }
        elseif ([string]::IsNullOrWhiteSpace($b.Slot))     { Write-Issue 'ERROR' "$loc : SLOT is empty" }
        elseif (-not $validSlots.Contains($b.Slot))        { Write-Issue 'ERROR' "$loc : unknown SLOT '$($b.Slot)' (valid: $($validSlots -join ', '))" }
        if ($null -eq $b.Item)                             { Write-Issue 'ERROR' "$loc : ITEM field missing" }
        elseif ([string]::IsNullOrWhiteSpace($b.Item))     { Write-Issue 'ERROR' "$loc : ITEM is empty" }
        elseif ($canValidateAssets -and -not (Test-ItemAsset $b.Item)) {
            Write-Issue 'ERROR' "$loc : ITEM '$($b.Item)' not found in scanned assets"
        }
        if ($null -eq $b.Players)                      { Write-Issue 'ERROR' "$loc : PLAYERS field missing"; continue }
        elseif ([string]::IsNullOrWhiteSpace($b.Players)) { Write-Issue 'ERROR' "$loc : PLAYERS is empty"; continue }

        # Expand players list (resolve groups to members for duplicate checking)
        $playersRaw = $b.Players -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $expanded   = [System.Collections.Generic.List[string]]::new()

        foreach ($player in $playersRaw) {
            if ($player -match '^@(.+)') {
                $ref = $Matches[1]
                if (-not $groups.ContainsKey($ref)) {
                    Write-Issue 'ERROR' "$loc : PLAYERS references unknown group '@$ref'"
                } else {
                    foreach ($m in $groups[$ref]) { $expanded.Add($m) }
                }
            } else {
                if (-not $users.ContainsKey($player)) {
                    Write-Issue 'WARN' "$loc : PLAYERS references unknown user '$player'"
                }
                $expanded.Add($player)
            }
        }

        # Deduplicate expanded players (a user may appear via multiple groups)
        $expandedUnique = [System.Linq.Enumerable]::Distinct($expanded)

        # Duplicate class+slot+item+player detection
        foreach ($p in $expandedUnique) {
            $key = "$($b.Class)|$($b.Slot)|$($b.Item)|$p"
            if (-not $seen.Add($key)) {
                Write-Issue 'ERROR' "$loc : duplicate override - class '$($b.Class)', slot '$($b.Slot)', item '$($b.Item)', player '$p'"
            }
        }
    }

    Write-Host "    $($blocks.Count) override block(s) checked."
}

# ---------------------------------------------------------------------------
# Check blacklist.txt
# ---------------------------------------------------------------------------

Write-Section "Checking blacklist.txt"

$blacklistFile  = "$PSScriptRoot\..\blacklist.txt"
$blacklistLines = Get-Content $blacklistFile

$blNamesSeen     = @{}   # name (lower) -> {LineStart, BlockEnd, HasUid}
$blUidsSeen      = @{}   # uid -> first name
$blDupeUidLines  = [System.Collections.Generic.List[int]]::new()   # 0-based line indices of UID-dupe blocks
$blDupeNameLines = [System.Collections.Generic.List[int]]::new()   # 0-based line indices of name-dupe blocks (weaker kept)
$blNoUidLines    = [System.Collections.Generic.List[int]]::new()   # 0-based line indices of no-UID blocks
$blValidPunishments = @('BAN', 'MUTE', 'WARN')
$blValidReasons     = @('BAN_EVADING', 'TOXICITY', 'HARASSMENT')
$blEpoch   = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
$blNowUnix = [int64](([datetime]::UtcNow - $blEpoch).TotalSeconds)
$blI = 0

while ($blI -lt $blacklistLines.Count) {
    $blLine = $blacklistLines[$blI].Trim()

    if ($blLine -match '^NAME:\s*(.+)') {
        $blName    = $Matches[1].Trim()
        $blLineNum = $blI + 1
        $blNameKey = $blName.ToLower()

        # Scan all lines in this entry's block until next NAME or list marker
        $blUid        = $null
        $blPunishment = $null
        $blReason     = $null
        $blEndDate    = $null
        $blBlockEnd   = $blI
        for ($k = $blI + 1; $k -lt $blacklistLines.Count; $k++) {
            $kl = $blacklistLines[$k].Trim()
            if ($kl -match '^NAME:' -or $kl -match '^L!') { break }
            $blBlockEnd = $k
            if      ($kl -match '^UID:\s*(.*)'        -and $null -eq $blUid)        { $blUid        = $Matches[1].Trim() }
            elseif  ($kl -match '^PUNISHMENT:\s*(.*)'  -and $null -eq $blPunishment) { $blPunishment = $Matches[1].Trim() }
            elseif  ($kl -match '^REASON:\s*(.*)'      -and $null -eq $blReason)     { $blReason     = $Matches[1].Trim() }
            elseif  ($kl -match '^END_DATE:\s*(.*)'    -and $null -eq $blEndDate)    { $blEndDate    = $Matches[1].Trim() }
        }

        $blHasUid     = ($null -ne $blUid -and $blUid -ne '')
        $blSkipUidChk = $false   # set true when this entry is a name-dupe being discarded

        # --- Duplicate name check ---
        if ($blNamesSeen.ContainsKey($blNameKey)) {
            $prev = $blNamesSeen[$blNameKey]
            if ($blHasUid -and -not $prev.HasUid) {
                # Current entry is richer - mark the previous (weaker) one for removal
                Write-Issue 'WARN' "blacklist.txt line $blLineNum : duplicate name '$blName' - keeping this entry (has UID), removing earlier entry at line $($prev.LineStart + 1)"
                for ($k = $prev.LineStart; $k -le $prev.BlockEnd; $k++) { $blDupeNameLines.Add($k) }
                $blNamesSeen[$blNameKey] = @{ LineStart = $blI; BlockEnd = $blBlockEnd; HasUid = $blHasUid }
            } else {
                # Previous is richer or equal - mark current for removal
                Write-Issue 'WARN' "blacklist.txt line $blLineNum : duplicate name '$blName' - keeping earlier entry at line $($prev.LineStart + 1)"
                for ($k = $blI; $k -le $blBlockEnd; $k++) { $blDupeNameLines.Add($k) }
                $blSkipUidChk = $true
            }
        } else {
            $blNamesSeen[$blNameKey] = @{ LineStart = $blI; BlockEnd = $blBlockEnd; HasUid = $blHasUid }
        }

        # --- UID checks (skip for name-dupe entries being discarded) ---
        if (-not $blSkipUidChk) {
            if ($null -eq $blUid) {
                Write-Issue 'WARN' "blacklist.txt line $blLineNum : '$blName' missing UID line"
                for ($k = $blI; $k -le $blBlockEnd; $k++) { $blNoUidLines.Add($k) }
            } elseif ($blUid -eq '') {
                Write-Issue 'WARN' "blacklist.txt line $blLineNum : '$blName' has no UID"
                for ($k = $blI; $k -le $blBlockEnd; $k++) { $blNoUidLines.Add($k) }
            } elseif ($blUidsSeen.ContainsKey($blUid)) {
                Write-Issue 'ERROR' "blacklist.txt line $blLineNum : duplicate UID '$blUid' for '$blName' (first seen on '$($blUidsSeen[$blUid])')"
                for ($k = $blI; $k -le $blBlockEnd; $k++) { $blDupeUidLines.Add($k) }
            } else {
                $blUidsSeen[$blUid] = $blName
            }

            # --- PUNISHMENT validation ---
            if ($null -ne $blPunishment -and $blPunishment -ne '' -and $blValidPunishments -notcontains $blPunishment) {
                Write-Issue 'ERROR' "blacklist.txt line $blLineNum : '$blName' has invalid PUNISHMENT '$blPunishment' (valid: $($blValidPunishments -join ', '))"
            }

            # --- REASON validation ---
            if ($null -ne $blReason -and $blReason -ne '' -and $blValidReasons -notcontains $blReason) {
                Write-Issue 'ERROR' "blacklist.txt line $blLineNum : '$blName' has invalid REASON '$blReason' (valid: $($blValidReasons -join ', '))"
            }

            # --- END_DATE validation ---
            if ($null -ne $blEndDate -and $blEndDate -ne '' -and $blEndDate -ne '0') {
                $blEndDateVal = [int64]0
                if (-not [int64]::TryParse($blEndDate, [ref]$blEndDateVal)) {
                    Write-Issue 'ERROR' "blacklist.txt line $blLineNum : '$blName' has invalid END_DATE '$blEndDate' (must be a Unix timestamp or 0 for permanent)"
                } elseif ($blEndDateVal -le $blNowUnix) {
                    $expiredDt = $blEpoch.AddSeconds($blEndDateVal).ToLocalTime()
                    Write-Issue 'WARN' "blacklist.txt line $blLineNum : '$blName' ban expired on $($expiredDt.ToString('yyyy-MM-dd HH:mm'))"
                }
            }
        }

        $blI = $blBlockEnd + 1
        continue
    }

    $blI++
}

# Offer dedup if any removable duplicates were found
$blAllDupeLines = [System.Collections.Generic.List[int]]::new()
foreach ($x in $blDupeUidLines)  { $blAllDupeLines.Add($x) }
foreach ($x in $blDupeNameLines) { $blAllDupeLines.Add($x) }

if ($blAllDupeLines.Count -gt 0) {
    $dupeUidCount  = 0
    $dupeNameCount = 0
    foreach ($idx in $blDupeUidLines)  { if ($blacklistLines[$idx] -match '^NAME:') { $dupeUidCount++ } }
    foreach ($idx in $blDupeNameLines) { if ($blacklistLines[$idx] -match '^NAME:') { $dupeNameCount++ } }
    Write-Host ""
    if ($dupeUidCount -gt 0)  { Write-Host "  $dupeUidCount duplicate-UID entry/entries found." -ForegroundColor Yellow }
    if ($dupeNameCount -gt 0) { Write-Host "  $dupeNameCount duplicate-name entry/entries found (weaker copies)." -ForegroundColor Yellow }
    Write-Host "  Remove all redundant entries from blacklist.txt? [y/N] " -NoNewline -ForegroundColor Yellow
    $answer = Read-Host
    if ($answer -match '^[Yy]') {
        $dupeSet = [System.Collections.Generic.HashSet[int]]::new($blAllDupeLines)
        $cleaned = for ($k = 0; $k -lt $blacklistLines.Count; $k++) {
            if (-not $dupeSet.Contains($k)) { $blacklistLines[$k] }
        }
        $cleaned | Set-Content $blacklistFile
        Write-Host "  blacklist.txt updated - $($blAllDupeLines.Count) line(s) removed." -ForegroundColor Green
        # Reload lines so the no-UID prompt works on the updated file
        $blacklistLines = Get-Content $blacklistFile
    }
}

# Offer pruning of no-UID entries (always re-scan from current file contents)
$blNoUidLinesFresh = [System.Collections.Generic.List[int]]::new()
$blJ = 0
while ($blJ -lt $blacklistLines.Count) {
    if ($blacklistLines[$blJ] -match '^NAME:\s*(.+)') {
        $blJBlockEnd = $blJ + 1
        $blJUid = $null
        for ($k = $blJ + 1; $k -lt $blacklistLines.Count -and $k -le $blJ + 3; $k++) {
            if ($blacklistLines[$k] -match '^NAME:') { break }
            if ($blacklistLines[$k] -match '^UID:\s*(.*)') {
                $blJUid      = $Matches[1].Trim()
                $blJBlockEnd = $k
                break
            }
        }
        if ($null -eq $blJUid -or $blJUid -eq '') {
            for ($k = $blJ; $k -le $blJBlockEnd; $k++) { $blNoUidLinesFresh.Add($k) }
        }
        $blJ = $blJBlockEnd + 1
        continue
    }
    $blJ++
}

if ($blNoUidLinesFresh.Count -gt 0) {
    $noUidCount = 0
    foreach ($idx in $blNoUidLinesFresh) { if ($blacklistLines[$idx] -match '^NAME:') { $noUidCount++ } }
    Write-Host ""
    Write-Host "  $noUidCount entry/entries with no UID found." -ForegroundColor Yellow
    Write-Host "  Remove all no-UID entries from blacklist.txt? [y/N] " -NoNewline -ForegroundColor Yellow
    $answer2 = Read-Host
    if ($answer2 -match '^[Yy]') {
        $noUidSet = [System.Collections.Generic.HashSet[int]]::new($blNoUidLinesFresh)
        $cleaned2 = for ($k = 0; $k -lt $blacklistLines.Count; $k++) {
            if (-not $noUidSet.Contains($k)) { $blacklistLines[$k] }
        }
        $cleaned2 | Set-Content $blacklistFile
        Write-Host "  blacklist.txt updated - $($blNoUidLinesFresh.Count) line(s) removed." -ForegroundColor Green
    }
}

# Offer removal of expired-ban entries (fresh scan so indices are always current)
$blacklistLines = Get-Content $blacklistFile
$blExpiredLines = [System.Collections.Generic.List[int]]::new()
$blK = 0
while ($blK -lt $blacklistLines.Count) {
    if ($blacklistLines[$blK] -match '^NAME:\s*(.+)') {
        $blKEnd     = $blK
        $blKEndDate = $null
        for ($k = $blK + 1; $k -lt $blacklistLines.Count; $k++) {
            $kl = $blacklistLines[$k].Trim()
            if ($kl -match '^NAME:' -or $kl -match '^L!') { break }
            $blKEnd = $k
            if ($kl -match '^END_DATE:\s*(.+)') { $blKEndDate = $Matches[1].Trim() }
        }
        if ($null -ne $blKEndDate -and $blKEndDate -ne '0') {
            $blKVal = [int64]0
            if ([int64]::TryParse($blKEndDate, [ref]$blKVal) -and $blKVal -le $blNowUnix) {
                for ($k = $blK; $k -le $blKEnd; $k++) { $blExpiredLines.Add($k) }
            }
        }
        $blK = $blKEnd + 1
        continue
    }
    $blK++
}

if ($blExpiredLines.Count -gt 0) {
    $expiredCount = 0
    foreach ($idx in $blExpiredLines) { if ($blacklistLines[$idx] -match '^NAME:') { $expiredCount++ } }
    Write-Host ""
    Write-Host "  $expiredCount expired ban(s) found." -ForegroundColor Yellow
    Write-Host "  Remove all expired entries from blacklist.txt? [y/N] " -NoNewline -ForegroundColor Yellow
    $answerExp = Read-Host
    if ($answerExp -match '^[Yy]') {
        $expSet   = [System.Collections.Generic.HashSet[int]]::new($blExpiredLines)
        $cleaned3 = for ($k = 0; $k -lt $blacklistLines.Count; $k++) {
            if (-not $expSet.Contains($k)) { $blacklistLines[$k] }
        }
        $cleaned3 | Set-Content $blacklistFile
        Write-Host "  blacklist.txt updated - $($blExpiredLines.Count) line(s) removed." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "===========================" -ForegroundColor White
if ($ErrorCount -eq 0 -and $WarningCount -eq 0) {
    Write-Host "  All checks passed." -ForegroundColor Green
} else {
    Write-Host "  $ErrorCount error(s), $WarningCount warning(s)" -ForegroundColor $(if ($ErrorCount -gt 0) { 'Red' } else { 'Yellow' })
}
Write-Host "===========================" -ForegroundColor White
