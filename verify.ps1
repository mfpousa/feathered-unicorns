# verify.ps1 - Consistency checker for feathered-unicorns data files

$ErrorCount = 0
$WarningCount = 0

function Write-Issue($level, $message) {
    if ($level -eq 'ERROR') {
        Write-Host "  [ERROR] $message" -ForegroundColor Red
        $script:ErrorCount++
    } else {
        Write-Host "  [WARN]  $message" -ForegroundColor Yellow
        $script:WarningCount++
    }
}

function Write-Section($title) {
    Write-Host ""
    Write-Host "--- $title ---" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Parse users.txt
# ---------------------------------------------------------------------------

Write-Section "Parsing users.txt"

$usersFile  = "$PSScriptRoot\users.txt"
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

$overrideFiles = Get-ChildItem "$PSScriptRoot\loadout-overrides\*.txt"

foreach ($file in $overrideFiles) {
    Write-Host "  Checking: $($file.Name)"
    $lines = Get-Content $file.FullName
    $j = 0

    while ($j -lt $lines.Count) {
        $line = $lines[$j].Trim()

        if ($line -match '^PLAYERS:\s*(.+)') {
            $playersRaw = $Matches[1].Trim() -split ',' | ForEach-Object { $_.Trim() }

            foreach ($player in $playersRaw) {
                if ($player -match '^@(.+)') {
                    $ref = $Matches[1]
                    if (-not $groups.ContainsKey($ref)) {
                        Write-Issue 'ERROR' "$($file.Name): PLAYERS references unknown group '@$ref'"
                    }
                } else {
                    if (-not $users.ContainsKey($player)) {
                        Write-Issue 'WARN' "$($file.Name): PLAYERS references unknown user '$player'"
                    }
                }
            }
        }

        $j++
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
