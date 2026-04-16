# manage.ps1 - TUI manager for feathered-unicorns users and groups
# Requires PowerShell 5.1+. Save as UTF-8 with BOM or ASCII to avoid encoding issues.

$UsersFile = "$PSScriptRoot\..\users.txt"

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

$users  = [ordered]@{}   # name -> uid
$groups = [ordered]@{}   # groupname -> List[string]

function Load-Data {
    $script:users  = [ordered]@{}
    $script:groups = [ordered]@{}
    $lines   = Get-Content $UsersFile
    $inUsers = $false; $inGroups = $false
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i].Trim()
        if ($line -eq '#region USERS')  { $inUsers = $true;  $inGroups = $false }
        if ($line -eq '#endregion')     { $inUsers = $false; $inGroups = $false }
        if ($line -eq '#region GROUPS') { $inGroups = $true; $inUsers  = $false }
        if ($inUsers -and $line -match '^NAME:\s*(.+)') {
            $name = $Matches[1].Trim()
            $next = if ($i+1 -lt $lines.Count) { $lines[$i+1].Trim() } else { '' }
            if ($next -match '^UID:\s*(.*)') { $script:users[$name] = $Matches[1].Trim(); $i += 2; continue }
        }
        if ($inGroups -and $line -match '^GROUP:\s*(.+)') {
            $gname = $Matches[1].Trim()
            $next  = if ($i+1 -lt $lines.Count) { $lines[$i+1].Trim() } else { '' }
            if ($next -match '^MEMBERS:\s*(.*)') {
                $raw = $Matches[1].Trim()
                $members = [System.Collections.Generic.List[string]]::new()
                if ($raw -ne '') {
                    foreach ($m in ($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })) {
                        $members.Add($m)
                    }
                }
                $script:groups[$gname] = $members
                $i += 2; continue
            }
        }
        $i++
    }
}

function Save-Data {
    $lines = @('-------------', '#region USERS', '-------------')
    foreach ($e in $script:users.GetEnumerator()) { $lines += "NAME: $($e.Key)"; $lines += "UID: $($e.Value)" }
    $lines += ''; $lines += '#endregion'; $lines += ''
    $lines += '-------------'; $lines += '#region GROUPS'; $lines += '-------------'
    foreach ($e in $script:groups.GetEnumerator()) {
        $lines += "GROUP: $($e.Key)"
        $lines += "MEMBERS: $($e.Value -join ',')"
    }
    $lines += '#endregion'
    Set-Content -Path $UsersFile -Value $lines -Encoding UTF8
}

function Get-UidMap {
    $map = @{}
    foreach ($e in $script:users.GetEnumerator()) { $map[$e.Value] = $e.Key }
    return $map
}

# ---------------------------------------------------------------------------
# Low-level TUI primitives
# ---------------------------------------------------------------------------

function Hide-Cursor  { [Console]::CursorVisible = $false }
function Show-Cursor  { [Console]::CursorVisible = $true  }

function Write-At($x, $y, $text, $fg = $null, $bg = $null) {
    [Console]::SetCursorPosition($x, $y)
    if ($fg -and $bg) { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg -NoNewline }
    elseif ($fg)      { Write-Host $text -ForegroundColor $fg -NoNewline }
    else              { Write-Host $text -NoNewline }
}

function Clear-Region($x, $y, $width, $height) {
    $blank = ' ' * $width
    for ($row = $y; $row -lt ($y + $height); $row++) { Write-At $x $row $blank }
}

# Read a line of text with inline editing. Returns string or $null on Esc.
function Read-Line-TUI($px, $py, $prompt, $initial = '') {
    Show-Cursor
    $buf = [System.Collections.Generic.List[char]]@()
    foreach ($c in $initial.ToCharArray()) { $buf.Add($c) }
    $cur = $buf.Count
    $w   = [Console]::WindowWidth - $px - 2

    while ($true) {
        [Console]::SetCursorPosition($px, $py)
        $field = (-join $buf)
        $display = $prompt + $field + (' ' * [Math]::Max(0, $w - $field.Length))
        Write-Host $display -NoNewline
        [Console]::SetCursorPosition($px + $prompt.Length + $cur, $py)

        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'Enter'      { Hide-Cursor; return (-join $buf) }
            'Escape'     { Hide-Cursor; return $null }
            'Backspace'  { if ($cur -gt 0) { $cur--; $buf.RemoveAt($cur) } }
            'Delete'     { if ($cur -lt $buf.Count) { $buf.RemoveAt($cur) } }
            'LeftArrow'  { if ($cur -gt 0) { $cur-- } }
            'RightArrow' { if ($cur -lt $buf.Count) { $cur++ } }
            'Home'       { $cur = 0 }
            'End'        { $cur = $buf.Count }
            default {
                if ($k.KeyChar -ne "`0" -and $k.KeyChar -ne "`r") {
                    $buf.Insert($cur, $k.KeyChar); $cur++
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Arrow-key menu. Returns 0-based index or -1 on Esc.
# ---------------------------------------------------------------------------
function Show-Menu($title, $items, $statusLine = '') {
    Hide-Cursor
    $sel = 0

    function Render {
        Clear-Host
        Write-At 2 1 $title Cyan
        Write-At 2 2 ('-' * [Math]::Min($title.Length + 2, [Console]::WindowWidth - 4)) DarkCyan
        for ($i = 0; $i -lt $items.Count; $i++) {
            $label = "   $($items[$i])  "
            if ($i -eq $sel) { Write-At 2 ($i + 3) $label Black White }
            else              { Write-At 2 ($i + 3) "   $($items[$i])  " DarkGray }
        }
        $fy = $items.Count + 5
        Write-At 2 $fy 'Arrow keys: navigate    Enter: select    Esc: back' DarkGray
        if ($statusLine -ne '') { Write-At 2 ($fy + 1) $statusLine Yellow }
    }

    Render
    while ($true) {
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'UpArrow'   { if ($sel -gt 0) { $sel-- }; Render }
            'DownArrow' { if ($sel -lt $items.Count - 1) { $sel++ }; Render }
            'Enter'     { Show-Cursor; return $sel }
            'Escape'    { Show-Cursor; return -1 }
        }
    }
}

# ---------------------------------------------------------------------------
# Fuzzy picker. Returns string (single), List[string] (multi), or $null.
# Type to filter, arrows to navigate, Space to toggle (multi), Enter to confirm.
# ---------------------------------------------------------------------------
function Show-Picker($title, [string[]]$items, $multiSelect = $false, [string[]]$subtexts = $null) {
    Hide-Cursor
    $selected = [System.Collections.Generic.List[string]]@()
    $query    = ''
    $sel      = 0

    # Inline filter - avoids nested function scoping issues
    # [string[]] constraint prevents PowerShell from unwrapping single-element results to a bare string
    [string[]]$filtered = $items

    while ($true) {
        # Recompute filtered list
        if ($query -eq '') {
            $filtered = $items
        } else {
            $q = $query.ToLower()
            $filtered = if ($items.Count -eq 0) { @() } else {
                @(0..($items.Count - 1) | Where-Object {
                $candidate = $items[$_].ToLower()
                if ($null -ne $subtexts -and $_ -lt $subtexts.Count -and $subtexts[$_] -ne '') {
                    $candidate = "$candidate $($subtexts[$_].ToLower())"
                }
                $s = $candidate; $qi = 0
                foreach ($ch in $s.ToCharArray()) { if ($qi -lt $q.Length -and $ch -eq $q[$qi]) { $qi++ } }
                $qi -eq $q.Length
            } | ForEach-Object { $items[$_] })
            }
        }
        if ($null -eq $filtered) { $filtered = @() }
        # Clamp selection
        if ($filtered.Count -eq 0) { $sel = 0 }
        elseif ($sel -ge $filtered.Count) { $sel = $filtered.Count - 1 }

        # Render
        Clear-Host
        $w = [Console]::WindowWidth - 4
        Write-At 2 1 $title Cyan
        Write-At 2 2 ('-' * [Math]::Min($title.Length + 2, $w)) DarkCyan
        $searchLine = "  Search: $query"
        Write-At 2 3 ($searchLine + (' ' * [Math]::Max(0, $w - $searchLine.Length))) White
        if ($multiSelect -and $selected.Count -gt 0) {
            $sl = "  Selected ($($selected.Count)): " + ($selected -join ', ')
            if ($sl.Length -gt $w) { $sl = $sl.Substring(0, $w - 3) + '...' }
            Write-At 2 4 ($sl + (' ' * [Math]::Max(0, $w - $sl.Length))) Green
        } else {
            Clear-Region 2 4 $w 1
        }
        $listY  = 5
        $maxVis = [Math]::Max(1, [Console]::WindowHeight - $listY - 3)
        if ($filtered.Count -eq 0) {
            Write-At 2 $listY ('  (no matches)' + (' ' * $w)) DarkGray
            Clear-Region 2 ($listY+1) $w ($maxVis-1)
        } else {
            $scrollTop = [Math]::Max(0, $sel - [Math]::Floor($maxVis / 2))
            $scrollTop = [Math]::Min($scrollTop, [Math]::Max(0, $filtered.Count - $maxVis))
            for ($vi = 0; $vi -lt $maxVis; $vi++) {
                $fi = $scrollTop + $vi
                if ($fi -ge $filtered.Count) { Clear-Region 2 ($listY+$vi) $w 1; continue }
                $item   = $filtered[$fi]
                $marker = if ($multiSelect) { if ($selected.Contains($item)) { '[x]' } else { '[ ]' } } else { '   ' }
                $label  = "  $marker $item"
                $sub    = ''
                if ($null -ne $subtexts) {
                    $origIdx = [Array]::IndexOf($items, $item)
                    if ($origIdx -ge 0 -and $origIdx -lt $subtexts.Count -and $subtexts[$origIdx] -ne '') {
                        $sub = "  $($subtexts[$origIdx])"
                    }
                }
                $totalLen = $label.Length + $sub.Length
                if ($totalLen -gt $w) {
                    if ($label.Length -ge $w) { $label = $label.Substring(0, $w - 1); $sub = '' }
                    else { $sub = $sub.Substring(0, $w - $label.Length) }
                    $totalLen = $label.Length + $sub.Length
                }
                $pad = ' ' * [Math]::Max(0, $w - $totalLen)
                if ($fi -eq $sel) {
                    Write-At 2 ($listY+$vi) ($label + $sub + $pad) Black White
                } else {
                    Write-At 2 ($listY+$vi) $label White
                    if ($sub -ne '') { Write-At (2 + $label.Length) ($listY+$vi) $sub DarkGray }
                    Write-At (2 + $label.Length + $sub.Length) ($listY+$vi) $pad
                }
            }
        }
        $fy = [Console]::WindowHeight - 2
        if ($multiSelect) { Write-At 2 $fy 'Type to filter   Up/Down: navigate   Space: toggle   Enter: confirm   Esc: cancel' DarkGray }
        else              { Write-At 2 $fy 'Type to filter   Up/Down: navigate   Enter: select   Esc: cancel' DarkGray }

        # Read next key
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'Escape'     { Show-Cursor; return $null }
            'Enter'      {
                Show-Cursor
                if ($multiSelect) { return ,$selected }
                if ($filtered.Count -gt 0) { return $filtered[$sel] }
                return $null
            }
            'UpArrow'    { if ($sel -gt 0) { $sel-- } }
            'DownArrow'  { if ($sel -lt $filtered.Count - 1) { $sel++ } }
            'Spacebar'   {
                if ($multiSelect -and $filtered.Count -gt 0) {
                    $item = $filtered[$sel]
                    if ($selected.Contains($item)) { $selected.Remove($item) | Out-Null }
                    else { $selected.Add($item) }
                }
            }
            'Backspace'  {
                if ($query.Length -gt 0) { $query = $query.Substring(0, $query.Length - 1) }
                $sel = 0
            }
            default {
                $ch = $k.KeyChar
                if ($ch -ne "`0" -and $ch -ne "`r" -and $ch -ne ' ' -and $k.Key -ne 'Enter') {
                    $query += $ch; $sel = 0
                }
            }
        }
    }
}

# Show message and wait for any key
function Show-Status($msg, $color = 'Green') {
    Clear-Host
    Write-At 2 2 $msg $color
    Write-At 2 4 'Press any key...' DarkGray
    [Console]::ReadKey($true) | Out-Null
}

# Show an error line on row $row, auto-clear after next render
function Show-Error($msg, $row = 6) {
    Write-At 2 $row (' ' * ([Console]::WindowWidth - 4))
    Write-At 2 $row $msg Red
}

# ---------------------------------------------------------------------------
# User management
# ---------------------------------------------------------------------------

function Menu-Users {
    while ($true) {
        # Build picker items: "Create new" at top, then all users
        $userNames  = @($script:users.Keys)
        $CREATE_NEW = '+ Create new user'
        $userSubtexts = @('') + @($userNames | ForEach-Object { $script:users[$_] })
        $picked = Show-Picker "Users ($($userNames.Count))" (@($CREATE_NEW) + $userNames) $false $userSubtexts
        if ($null -eq $picked) { return }

        if ($picked -eq $CREATE_NEW) {
            Create-User
        } else {
            User-Actions $picked
        }
    }
}

function User-Actions($name) {
    while ($true) {
        $uid         = $script:users[$name]
        $memberships = @($script:groups.Keys | Where-Object { $script:groups[$_].Contains($name) })
        $memberInfo  = if ($memberships.Count -gt 0) { "Groups: $($memberships -join ', ')" } else { 'No group memberships' }
        $c = Show-Menu "$name  ($uid)" @('Edit', 'Delete', '< Back') $memberInfo
        switch ($c) {
            -1 { return } 2 { return }
            0  { Edit-User $name; return }   # name may have changed, exit and re-open from picker
            1  { Delete-User $name; return }
        }
    }
}

# Generic scrollable+searchable list. $allLines is string[]. Title shown at top.
function Show-ScrollList($title, [string[]]$allLines) {
    Hide-Cursor
    $query  = ''
    $top    = 0
    $listY  = 4
    $maxVis = [Math]::Max(1, [Console]::WindowHeight - $listY - 2)

    while ($true) {
        # Filter
        if ($query -eq '') {
            $lines = $allLines
        } else {
            $q = $query.ToLower()
            $lines = @($allLines | Where-Object {
                $s = $_.ToLower(); $qi = 0
                foreach ($ch in $s.ToCharArray()) { if ($qi -lt $q.Length -and $ch -eq $q[$qi]) { $qi++ } }
                $qi -eq $q.Length
            })
        }
        if ($null -eq $lines) { $lines = @() }
        $total = $lines.Count
        if ($top -ge $total -and $total -gt 0) { $top = $total - 1 }
        if ($total -eq 0) { $top = 0 }

        # Render
        Clear-Host
        $w = [Console]::WindowWidth - 4
        Write-At 2 1 $title Cyan
        Write-At 2 2 ('-' * [Math]::Min($title.Length + 2, $w)) DarkCyan
        $searchLine = "  Search: $query"
        Write-At 2 3 ($searchLine + (' ' * [Math]::Max(0, $w - $searchLine.Length))) White

        for ($vi = 0; $vi -lt $maxVis; $vi++) {
            $li = $top + $vi
            if ($li -ge $total) { Clear-Region 2 ($listY+$vi) $w 1; continue }
            $pad = ' ' * [Math]::Max(0, $w - $lines[$li].Length)
            Write-At 2 ($listY+$vi) ($lines[$li] + $pad) White
        }
        $countInfo = if ($query -ne '') { "$total matches of $($allLines.Count)" } elseif ($total -gt $maxVis) { "Line $($top+1)-$([Math]::Min($top+$maxVis,$total)) of $total" } else { "$total items" }
        Write-At 2 ([Console]::WindowHeight - 2) "Type to filter   Up/Down/PgUp/PgDn: scroll   Esc/Enter: back   $countInfo" DarkGray

        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'Escape'     { Show-Cursor; return }
            'Enter'      { Show-Cursor; return }
            'UpArrow'    { if ($top -gt 0) { $top-- } }
            'DownArrow'  { if ($top + $maxVis -lt $total) { $top++ } }
            'PageUp'     { $top = [Math]::Max(0, $top - $maxVis) }
            'PageDown'   { $top = [Math]::Min([Math]::Max(0, $total - $maxVis), $top + $maxVis) }
            'Home'       { $top = 0 }
            'End'        { $top = [Math]::Max(0, $total - $maxVis) }
            'Backspace'  { if ($query.Length -gt 0) { $query = $query.Substring(0, $query.Length - 1); $top = 0 } }
            default {
                $ch = $k.KeyChar
                if ($ch -ne "`0" -and $ch -ne "`r") { $query += $ch; $top = 0 }
            }
        }
    }
}

function Create-User($prefillName = '', $prefillUid = '') {
    Clear-Host
    Write-At 2 1 'Create User' Cyan
    Write-At 2 2 'Esc to cancel, Enter to confirm each field.' DarkGray

    $name = $null
    while ($true) {
        Clear-Region 2 5 ([Console]::WindowWidth - 4) 1
        $name = Read-Line-TUI 2 3 'Name: ' $prefillName
        if ($null -eq $name) { return $null }
        $name = $name.Trim()
        if ($name -eq '') { Show-Error 'Name cannot be empty.'; continue }
        if ($script:users.Contains($name)) { Show-Error "User '$name' already exists."; continue }
        break
    }

    $uidMap = Get-UidMap
    $uid    = $null
    while ($true) {
        Clear-Region 2 5 ([Console]::WindowWidth - 4) 1
        $uid = Read-Line-TUI 2 4 'UID:  ' $prefillUid
        if ($null -eq $uid) { return $null }
        $uid = $uid.Trim()
        if ($uid -eq '') { Show-Error 'UID cannot be empty.'; continue }
        if ($uidMap.ContainsKey($uid)) { Show-Error "UID already used by '$($uidMap[$uid])'."; continue }
        break
    }

    $script:users[$name] = $uid
    Save-Data
    Show-Status "Created user '$name' (UID: $uid)."
    return $name
}

function Edit-User($name = $null) {
    if ($null -eq $name) {
        $name = Show-Picker 'Edit User - pick user' @($script:users.Keys)
        if ($null -eq $name) { return }
    }

    $origUid = $script:users[$name]
    Clear-Host
    Write-At 2 1 "Edit User: $name" Cyan
    Write-At 2 2 'Esc on a field to cancel, Enter to keep/update.' DarkGray

    $newName = $null
    while ($true) {
        Clear-Region 2 6 ([Console]::WindowWidth - 4) 1
        $newName = Read-Line-TUI 2 4 'Name: ' $name
        if ($null -eq $newName) { return }
        $newName = $newName.Trim()
        if ($newName -eq '') { $newName = $name; break }
        if ($newName -ne $name -and $script:users.Contains($newName)) {
            Show-Error "Name '$newName' already exists."; continue
        }
        break
    }

    $uidMap = Get-UidMap
    $newUid = $null
    while ($true) {
        Clear-Region 2 6 ([Console]::WindowWidth - 4) 1
        $newUid = Read-Line-TUI 2 5 'UID:  ' $origUid
        if ($null -eq $newUid) { return }
        $newUid = $newUid.Trim()
        if ($newUid -eq '') { $newUid = $origUid; break }
        if ($newUid -ne $origUid -and $uidMap.ContainsKey($newUid)) {
            Show-Error "UID already used by '$($uidMap[$newUid])'."; continue
        }
        break
    }

    if ($newName -ne $name) {
        foreach ($g in $script:groups.Keys) {
            $idx = $script:groups[$g].IndexOf($name)
            if ($idx -ge 0) { $script:groups[$g][$idx] = $newName }
        }
        $script:users.Remove($name) | Out-Null
    }
    $script:users[$newName] = $newUid
    Save-Data
    Show-Status "Saved '$newName' (UID: $newUid)."
}

function Delete-User($name = $null) {
    if ($null -eq $name) {
        $name = Show-Picker 'Delete User - pick user' @($script:users.Keys)
        if ($null -eq $name) { return }
    }

    $memberships = @($script:groups.Keys | Where-Object { $script:groups[$_].Contains($name) })
    $info = if ($memberships.Count -gt 0) { "Also removes from: $($memberships -join ', ')" } else { '' }
    $c = Show-Menu "Delete '$name'?" @('Yes, delete', '< Cancel') $info
    if ($c -ne 0) { return }

    $script:users.Remove($name) | Out-Null
    foreach ($g in $memberships) { $script:groups[$g].Remove($name) | Out-Null }
    Save-Data
    Show-Status "Deleted '$name'." Yellow
}

# ---------------------------------------------------------------------------
# Group management
# ---------------------------------------------------------------------------

function Menu-Groups {
    while ($true) {
        $gnames     = @($script:groups.Keys)
        $CREATE_NEW = '+ Create new group'
        $labels     = @($CREATE_NEW) + @($gnames | ForEach-Object { "@$_ ($($script:groups[$_].Count) members)" })
        $picked = Show-Picker "Groups ($($gnames.Count))" $labels
        if ($null -eq $picked) { return }

        if ($picked -eq $CREATE_NEW) {
            Create-Group
        } else {
            # Strip the label decoration back to the raw group name
            $gname = $picked -replace '^@' -replace ' \(\d+ members\)$'
            Group-Actions $gname
        }
    }
}

function Group-Actions($gname) {
    while ($true) {
        $members = $script:groups[$gname]
        $c = Show-Menu "@$gname" @('View / Edit members', 'Rename', 'Delete', '< Back') `
            "$($members.Count) member(s): $($members -join ', ')"
        switch ($c) {
            -1 { return } 3 { return }
            0  {
                $members = $script:groups[$gname]
                $lines   = if ($members.Count -eq 0) { @('  (no members)') } else { @($members | ForEach-Object { "  $_" }) }
                Show-ScrollList "@$gname ($($members.Count) members)" $lines
                Edit-GroupMembers $gname
            }
            1  { $newName = Rename-Group $gname; if ($newName) { $gname = $newName } }
            2  { Delete-Group $gname; return }
        }
    }
}

function Create-Group {
    Clear-Host
    Write-At 2 1 'Create Group' Cyan
    $name = $null
    while ($true) {
        Clear-Region 2 5 ([Console]::WindowWidth - 4) 1
        $name = Read-Line-TUI 2 3 'Group name: '
        if ($null -eq $name) { return }
        $name = $name.Trim()
        if ($name -eq '') { Show-Error 'Name cannot be empty.'; continue }
        if ($script:groups.Contains($name)) { Show-Error "Group '$name' already exists."; continue }
        break
    }
    $script:groups[$name] = [System.Collections.Generic.List[string]]::new()
    Save-Data
    $c = Show-Menu "Group '@$name' created." @('Add members now', '< Skip')
    if ($c -eq 0) { Edit-GroupMembers $name }
}

function Edit-GroupMembers($preselected) {
    $gname = if ($null -ne $preselected) { $preselected } else {
        Show-Picker 'Edit Group Members - pick group' @($script:groups.Keys)
    }
    if ($null -eq $gname) { return }

    while ($true) {
        $c = Show-Menu "Edit Members: @$gname" @('Add existing users', 'Remove a member', 'Create new user and add', '< Done') `
            "Members: $($script:groups[$gname].Count)"
        switch ($c) {
            -1 { return } 3 { return }
            0 {
                $candidates = @($script:users.Keys | Where-Object { -not $script:groups[$gname].Contains($_) })
                if ($candidates.Count -eq 0) { Show-Status 'All users are already in this group.' Yellow; break }
                $picked = Show-Picker "Add to @$gname  (Space=toggle, Enter=confirm)" $candidates $true
                if ($null -ne $picked -and $picked.Count -gt 0) {
                    foreach ($p in $picked) { $script:groups[$gname].Add($p) }
                    Save-Data
                    Show-Status "Added $($picked.Count) user(s)."
                }
            }
            1 {
                if ($script:groups[$gname].Count -eq 0) { Show-Status 'Group is empty.' Yellow; break }
                $picked = Show-Picker "Remove from @$gname" @($script:groups[$gname])
                if ($null -ne $picked) {
                    $c2 = Show-Menu "Remove '$picked'?" @('Yes, remove', '< Cancel')
                    if ($c2 -eq 0) {
                        $script:groups[$gname].Remove($picked) | Out-Null
                        Save-Data
                        Show-Status "Removed '$picked'." Yellow
                    }
                }
            }
            2 {
                $newName = Create-User
                if ($null -ne $newName -and $script:users.Contains($newName)) {
                    $script:groups[$gname].Add($newName)
                    Save-Data
                    Show-Status "Added '$newName' to '@$gname'."
                }
            }
        }
    }
}

function Rename-Group($gname = $null) {
    if ($null -eq $gname) {
        $gname = Show-Picker 'Rename Group - pick group' @($script:groups.Keys)
        if ($null -eq $gname) { return }
    }
    Clear-Host
    Write-At 2 1 "Rename Group: @$gname" Cyan
    $newName = $null
    while ($true) {
        Clear-Region 2 5 ([Console]::WindowWidth - 4) 1
        $newName = Read-Line-TUI 2 3 'New name: '
        if ($null -eq $newName) { return }
        $newName = $newName.Trim()
        if ($newName -eq '') { Show-Error 'Name cannot be empty.'; continue }
        if ($script:groups.Contains($newName)) { Show-Error "Group '$newName' already exists."; continue }
        break
    }
    $script:groups[$newName] = $script:groups[$gname]
    $script:groups.Remove($gname) | Out-Null
    Save-Data
    Show-Status "Renamed '@$gname' to '@$newName'."
    return $newName
}

function Delete-Group($gname = $null) {
    if ($null -eq $gname) {
        $gname = Show-Picker 'Delete Group - pick group' @($script:groups.Keys)
        if ($null -eq $gname) { return }
    }
    $c = Show-Menu "Delete '@$gname' ($($script:groups[$gname].Count) members)?" @('Yes, delete', '< Cancel')
    if ($c -ne 0) { return }
    $script:groups.Remove($gname) | Out-Null
    Save-Data
    Show-Status "Deleted '@$gname'." Yellow
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Load-Data
Hide-Cursor

try {
    while ($true) {
        $c = Show-Menu 'Feathered Unicorns - User Manager' @('Manage Users', 'Manage Groups', 'Exit') `
            "Users: $($script:users.Count)   Groups: $($script:groups.Count)"
        switch ($c) {
            -1 { break }
            0  { Menu-Users }
            1  { Menu-Groups }
            2  { Clear-Host; Show-Cursor; exit }
        }
    }
} catch {
    Clear-Host
    Show-Cursor
    Write-Host 'UNHANDLED EXCEPTION' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ''
    Read-Host 'Press Enter to exit'
    exit 1
}
Clear-Host
Show-Cursor
