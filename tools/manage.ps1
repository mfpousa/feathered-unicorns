# manage.ps1 - TUI manager for feathered-unicorns users and groups
# Requires PowerShell 5.1+. Save as UTF-8 with BOM or ASCII to avoid encoding issues.

$UsersFile         = "$PSScriptRoot\..\users.txt"
$OverridesFile     = "$PSScriptRoot\..\loadout-overrides\default-loadout-overrides.txt"
$BlacklistFile     = "$PSScriptRoot\..\blacklist.txt"
$UE4ContentPath    = "$PSScriptRoot\..\..\ContractorsVR\ModProject\Content"

# UE4 parent class strings used to identify asset types by scanning raw binary
$CLASS_PARENT_ITEM  = 'ZomboyInteractableActor'
$CLASS_PARENT_CLASS = 'ZomboyLoadoutHolderDataInfo'

# Subdirectories under $UE4ContentPath to scan for each asset type
# Scoping these avoids scanning the entire Content tree (88k+ files)
$CLASS_SCAN_PATHS = @('tf2_commons_v142\Loadout\Loadouts')
$ITEM_SCAN_PATHS  = @('tf2_commons_v142\Loadout\Loadouts', 'tf2_commons_v142\Loadout\Weapons', 'Contributions')

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

$users     = [ordered]@{}   # name -> uid
$groups    = [ordered]@{}   # groupname -> List[string]
$overrides  = [System.Collections.Generic.List[hashtable]]::new()  # list of {Class,Slot,Item,Players}
$blacklist  = [System.Collections.Generic.List[hashtable]]::new()  # list of {Name,Uid,Punishment,Reason,EndDate}
$assetCache = @{}            # parentClass -> [PSCustomObject[]] {Label, GamePath}

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
# Asset scanner
# Scans .uasset files under $UE4ContentPath whose raw binary contains $parentClass.
# Results cached in $script:assetCache per parentClass string.
# Returns [PSCustomObject[]] with .Label (filename without extension), .GamePath
# (full /Game/Path/To/Asset.Asset reference used in override files), and .FilePath.
# $nameFilter: optional wildcard applied to filenames before binary scanning
#   (e.g. '*HolderInfo' prevents cosmetics that merely reference the class from matching)
# ---------------------------------------------------------------------------
function Scan-Assets($parentClass, [string[]]$subPaths, $nameFilter = '*.uasset') {
    $cacheKey = "$parentClass|$($subPaths -join '|')"
    if ($script:assetCache.ContainsKey($cacheKey)) { return $script:assetCache[$cacheKey] }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (-not (Test-Path $script:UE4ContentPath)) {
        $script:assetCache[$cacheKey] = @()
        return @()
    }

    # Resolve away any ../.. components so Substring() gets the right offset
    $resolvedBase = (Resolve-Path $script:UE4ContentPath).Path.TrimEnd('\')

    # Collect files only from the specified subdirectories
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($sub in $subPaths) {
        $dir = Join-Path $resolvedBase $sub
        if (Test-Path $dir) {
            foreach ($f in (Get-ChildItem -Path $dir -Filter $nameFilter -Recurse -File)) {
                $files.Add($f)
            }
        }
    }

    $total  = $files.Count
    $n      = 0

    foreach ($f in $files) {
        $n++
        if ($n % 50 -eq 0) {
            Write-At 2 3 "  $n / $total files..." DarkGray
        }
        # Read bytes and decode as Latin-1 (1:1 byte mapping) so .NET Contains() can search
        # the raw binary for the parent class string without a slow PowerShell loop
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $text  = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
        if (-not $text.Contains($parentClass)) { continue }

        # Convert filesystem path to /Game/ reference
        $rel      = $f.FullName.Substring($resolvedBase.Length).TrimStart('\').Replace('\', '/')
        $noExt    = $rel -replace '\.uasset$'
        $name     = $f.BaseName
        $gamePath = "/Game/$noExt.$name"

        $results.Add([PSCustomObject]@{
            Label    = $name
            GamePath = $gamePath
            FilePath = $f.FullName
        })
    }

    $arr = $results.ToArray()
    $script:assetCache[$cacheKey] = $arr
    return $arr
}

# Extract ELoadoutCategory slot names from the already-scanned HolderInfo assets.
# Finds short CamelCase words that appear in the majority of these assets,
# excluding known UE4 engine/property keywords.
# Extract ELoadoutCategory slot names by parsing UE4 FNameMaps from HolderInfo assets.
# FNames are the authoritative identifiers (property names, enum values, etc.).
# Path strings like /Game/.../Cosmetics live in FStrings, not FNames — so they
# never appear here, unlike the previous raw-binary approach.
# Inlined to avoid PowerShell 5.1 function-return / try-catch pipeline quirks.
function Scan-Slots([PSCustomObject[]]$classAssets) {
    $freq  = @{}
    $total = $classAssets.Count
    if ($total -eq 0) { return @() }

    $exclude = [System.Collections.Generic.HashSet[string]]([string[]]@(
        'None','True','False','Class','Package','Brush','Script','Engine','Core',
        'Object','Default','Actor','World','Level','Component','Blueprint',
        'MapProperty','ArrayProperty','BoolProperty','EnumProperty','NameProperty',
        'ObjectProperty','StructProperty','TextProperty','SoftObjectProperty',
        'SlateBrush','Texture','MetaData','PackageMetaData','DisplayName',
        'ImageSize','HolsterSetup','ResourceObject','bHasNone'
    ))

    foreach ($a in $classAssets) {
        # All binary reading stays in local variables — no function call, no return-value issues
        $names = [System.Collections.Generic.List[string]]::new()
        $br    = $null
        try {
            $br = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($a.FilePath))
            if ($br.BaseStream.Length -ge 64) {
                # Header: magic(4), legacyVer(4), ue3ver(4), ue4ver(4), licVer(4)
                # Note: skip magic check — uint32 vs long type coercion in PS5.1 makes -eq unreliable
                $br.ReadUInt32() | Out-Null  # magic
                $br.ReadInt32() | Out-Null; $br.ReadInt32() | Out-Null
                $br.ReadInt32() | Out-Null; $br.ReadInt32() | Out-Null
                $cv = $br.ReadInt32()
                if ($cv -gt 0 -and $cv -lt 1000) { $br.ReadBytes($cv * 20) | Out-Null }
                $br.ReadInt32() | Out-Null   # TotalHeaderSize
                $fnLen = $br.ReadInt32()
                if ($fnLen -gt 0)     { $br.ReadBytes($fnLen)        | Out-Null }
                elseif ($fnLen -lt 0) { $br.ReadBytes(-$fnLen * 2)   | Out-Null }
                $br.ReadUInt32() | Out-Null  # PackageFlags
                $nc = $br.ReadInt32()
                $no = $br.ReadInt32()
                if ($nc -gt 0 -and $nc -lt 100000 -and $no -gt 0) {
                    $br.BaseStream.Seek($no, [System.IO.SeekOrigin]::Begin) | Out-Null
                    for ($i = 0; $i -lt $nc; $i++) {
                        $len = $br.ReadInt32()
                        if ($len -gt 0 -and $len -lt 4096) {
                            $s = [System.Text.Encoding]::UTF8.GetString($br.ReadBytes($len)).TrimEnd("`0")
                        } elseif ($len -lt 0 -and $len -gt -2048) {
                            $s = [System.Text.Encoding]::Unicode.GetString($br.ReadBytes(-$len * 2)).TrimEnd("`0")
                        } else { break }
                        $br.ReadInt32() | Out-Null   # hash
                        $names.Add($s)
                    }
                }
            }
        } catch { } finally { if ($null -ne $br) { $br.Dispose() } }

        $seen = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($n in $names) {
            if ($n -match '^[A-Z][a-z]{2,11}$' -and -not $exclude.Contains($n) -and $seen.Add($n)) {
                if (-not $freq.ContainsKey($n)) { $freq[$n] = 0 }
                $freq[$n]++
            }
        }
    }

    [string[]]@($freq.GetEnumerator() | Where-Object { $_.Value -ge $total } | Sort-Object Name | ForEach-Object { $_.Key })
}


function Load-Overrides {
    $script:overrides = [System.Collections.Generic.List[hashtable]]::new()
    if (-not (Test-Path $script:OverridesFile)) { return }

    $lines   = Get-Content $script:OverridesFile
    $current = $null
    foreach ($line in $lines) {
        $l = $line.Trim()
        if ($l -match '^CLASS:\s*(.+)') {
            if ($null -ne $current) { $script:overrides.Add($current) }
            $current = @{ Class = $Matches[1].Trim(); Slot = ''; Item = ''; Players = ''; Tag = '' }
        } elseif ($null -ne $current) {
            if      ($l -match '^SLOT:\s*(.*)')     { $current.Slot    = $Matches[1].Trim() }
            elseif  ($l -match '^ITEM:\s*(.*)')     { $current.Item    = $Matches[1].Trim() }
            elseif  ($l -match '^PLAYERS:\s*(.*)')  { $current.Players = $Matches[1].Trim() }
            elseif  ($l -match '^TAG:\s*(.*)')      { $current.Tag     = $Matches[1].Trim() }
        }
    }
    if ($null -ne $current) { $script:overrides.Add($current) }
}

function Save-Overrides {
    $out   = [System.Collections.Generic.List[string]]::new()
    $first = $true
    foreach ($o in $script:overrides) {
        if (-not $first) { $out.Add('') }
        $out.Add("CLASS: $($o.Class)")
        $out.Add("SLOT: $($o.Slot)")
        $out.Add("ITEM: $($o.Item)")
        $out.Add("PLAYERS: $($o.Players)")
        $t = if ($null -ne $o.Tag) { $o.Tag } else { '' }
        if ($t -ne '') { $out.Add("TAG: $t") }
        $first = $false
    }
    Set-Content -Path $script:OverridesFile -Value $out.ToArray() -Encoding UTF8
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
function Show-Menu($title, $items, $statusLine = '', $initialSel = 0) {
    Hide-Cursor
    $sel = if ($initialSel -ge 0 -and $initialSel -lt $items.Count) { $initialSel } else { 0 }

    function Render {
        Clear-Host
        $h = [Console]::WindowHeight
        $w = [Console]::WindowWidth - 4
        Write-At 2 1 $title Cyan
        Write-At 2 2 ('-' * [Math]::Min($title.Length + 2, $w)) DarkCyan
        for ($i = 0; $i -lt $items.Count; $i++) {
            $row = $i + 3
            if ($row -ge $h - 2) { break }   # stop before running off screen
            $label = "   $($items[$i])  "
            if ($i -eq $sel) { Write-At 2 $row $label Black White }
            elseif ($items[$i] -like '+*') { Write-At 2 $row $label Green }
            elseif ($items[$i] -like '<*') { Write-At 2 $row $label DarkGray }
            else                           { Write-At 2 $row $label White }
        }
        $fy = [Math]::Min($items.Count + 5, $h - 2)
        if ($fy -ge 0 -and $fy -lt $h) {
            Write-At 2 $fy 'Arrow keys: navigate    Enter: select    Esc: back' DarkGray
        }
        if ($statusLine -ne '' -and ($fy + 1) -lt $h) {
            Write-At 2 ($fy + 1) $statusLine Yellow
        }
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
function Show-Picker($title, [string[]]$items, $multiSelect = $false, [string[]]$subtexts = $null, $filterMode = 'fuzzy', [string[]]$preSelected = $null, $searchSubtexts = $true) {
    Hide-Cursor
    $selected = [System.Collections.Generic.List[string]]@()
    if ($multiSelect -and $null -ne $preSelected) {
        foreach ($p in $preSelected) { if ($p -ne '') { $selected.Add($p) } }
    }
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
                if ($searchSubtexts -and $null -ne $subtexts -and $_ -lt $subtexts.Count -and $subtexts[$_] -ne '') {
                    $candidate = "$candidate $($subtexts[$_].ToLower())"
                }
                if ($filterMode -eq 'contains') {
                    $candidate.Contains($q)
                } else {
                    $s = $candidate; $qi = 0
                    foreach ($ch in $s.ToCharArray()) { if ($qi -lt $q.Length -and $ch -eq $q[$qi]) { $qi++ } }
                    $qi -eq $q.Length
                }
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
# Loadout overrides management
# ---------------------------------------------------------------------------

# Returns a short human-readable label for an override entry (used in Override-Actions title)
function Format-OverrideLabel($o) {
    $cls  = ($o.Class  -split '/' | Select-Object -Last 1) -replace '\..+$'
    $item = ($o.Item   -split '/' | Select-Object -Last 1) -replace '\..+$'
    $slot = $o.Slot
    "$cls  [$slot]  ->  $item"
}

# Build a flat list of tree-display rows from $overrides, filtered by $query.
# Each row: PSCustomObject { Display, OrigIdx (-2=create-new, -1=header, >=0=override index), IsHeader }
function Build-OverrideRows($overrides, $query, $tagFilter) {
    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $rows.Add([PSCustomObject]@{ Display = '  + Create new override'; OrigIdx = -2; IsHeader = $false })

    # Filter by tag: '' = untagged only, $null = all
    $indices = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $overrides.Count; $i++) {
        $t = if ($null -eq $overrides[$i].Tag) { '' } else { $overrides[$i].Tag }
        if ($null -eq $tagFilter -or $t -eq $tagFilter) { $indices.Add($i) }
    }
    if ($indices.Count -eq 0) { return ,$rows.ToArray() }

    # Group indices by short class name, preserving first-seen order
    $classOrder = [System.Collections.Generic.List[string]]::new()
    $classMap   = @{}
    foreach ($i in $indices) {
        $cls = ($overrides[$i].Class -split '/' | Select-Object -Last 1) -replace '\..+$'
        if (-not $classMap.ContainsKey($cls)) {
            $classMap[$cls] = [System.Collections.Generic.List[int]]::new()
            $classOrder.Add($cls)
        }
        $classMap[$cls].Add($i)
    }

    $q = $query.ToLower()
    foreach ($cls in $classOrder) {
        $matchIdx = [System.Collections.Generic.List[int]]::new()
        foreach ($i in $classMap[$cls]) {
            if ($q -eq '') { $matchIdx.Add($i); continue }
            $o = $overrides[$i]
            $itemShort = ($o.Item -split '/' | Select-Object -Last 1) -replace '\..+$'
            if ("$cls $($o.Slot) $itemShort $($o.Players)".ToLower().Contains($q)) { $matchIdx.Add($i) }
        }
        if ($matchIdx.Count -eq 0) { continue }

        # Sort matched indices by slot name, then by item name
        $sortedIdx = @($matchIdx | Sort-Object { $overrides[$_].Slot }, { ($overrides[$_].Item -split '/' | Select-Object -Last 1) -replace '\..+$' })

        $rows.Add([PSCustomObject]@{ Display = "  $cls"; OrigIdx = -1; IsHeader = $true })
        for ($j = 0; $j -lt $sortedIdx.Count; $j++) {
            $o = $overrides[$sortedIdx[$j]]
            $itemShort = ($o.Item -split '/' | Select-Object -Last 1) -replace '\..+$'
            $branch = if ($j -eq $sortedIdx.Count - 1) { '    \--' } else { '    |--' }
            $rows.Add([PSCustomObject]@{
                Display  = "$branch [$($o.Slot)]  $itemShort"
                OrigIdx  = $sortedIdx[$j]
                IsHeader = $false
            })
        }
    }
    return ,$rows.ToArray()
}

function Render-OverrideTree($rows, $sel, $query, $tagLabel) {
    Hide-Cursor
    Clear-Host
    $w      = [Console]::WindowWidth - 4
    $h      = [Console]::WindowHeight
    $listY  = 4
    $maxVis = [Math]::Max(1, $h - $listY - 2)

    $visibleCount = ($rows | Where-Object { $_.OrigIdx -ge 0 }).Count
    $title = "Loadout Overrides  [$tagLabel]  ($visibleCount)"
    Write-At 2 1 ($title + (' ' * [Math]::Max(0, $w - $title.Length))) Cyan
    Write-At 2 2 ('-' * [Math]::Min(34, $w)) DarkCyan
    $searchLine = "  Search: $query"
    Write-At 2 3 ($searchLine + (' ' * [Math]::Max(0, $w - $searchLine.Length))) White

    $scrollTop    = [Math]::Max(0, $sel - [int]($maxVis / 2))
    $maxScrollTop = [Math]::Max(0, $rows.Count - $maxVis)
    if ($scrollTop -gt $maxScrollTop) { $scrollTop = $maxScrollTop }

    for ($vi = 0; $vi -lt $maxVis; $vi++) {
        $ri = $scrollTop + $vi
        if ($ri -ge $rows.Count) { Clear-Region 2 ($listY + $vi) $w 1; continue }
        $r   = $rows[$ri]
        $pad = ' ' * [Math]::Max(0, $w - $r.Display.Length)
        if ($ri -eq $sel) {
            Write-At 2 ($listY + $vi) ($r.Display + $pad) Black White
        } elseif ($r.OrigIdx -eq -3) {
            Write-At 2 ($listY + $vi) ($r.Display + $pad) Yellow
        } elseif ($r.IsHeader) {
            Write-At 2 ($listY + $vi) ($r.Display + $pad) Cyan
        } elseif ($r.OrigIdx -eq -2) {
            Write-At 2 ($listY + $vi) ($r.Display + $pad) Green
        } else {
            Write-At 2 ($listY + $vi) ($r.Display + $pad) White
        }
    }
    Write-At 2 ($h - 2) 'Type to filter   Up/Down: navigate   Enter: select   Esc: back' DarkGray
}

function Menu-OverridesForTag($tagFilter, $tagLabel, [ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    $query = ''
    $sel   = 0

    while ($true) {
        $rows = Build-OverrideRows $script:overrides $query $tagFilter
        if ($sel -ge $rows.Count) { $sel = [Math]::Max(0, $rows.Count - 1) }
        Render-OverrideTree $rows $sel $query $tagLabel

        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'Escape'    { Show-Cursor; return }
            'Enter'     {
                if ($rows.Count -eq 0) { break }
                $r = $rows[$sel]
                if ($r.OrigIdx -eq -2) {
                    Create-Override $classAssets $itemAssets $slots $tagFilter
                } elseif ($r.OrigIdx -ge 0) {
                    Override-Actions $r.OrigIdx $classAssets $itemAssets $slots
                }
                # IsHeader: do nothing
            }
            'UpArrow'   { if ($sel -gt 0) { $sel-- } }
            'DownArrow' { if ($sel -lt $rows.Count - 1) { $sel++ } }
            'Backspace' { if ($query.Length -gt 0) { $query = $query.Substring(0, $query.Length - 1); $sel = 0 } }
            default {
                $ch = $k.KeyChar
                if ($ch -ne "`0" -and $ch -ne "`r") { $query += $ch; $sel = 0 }
            }
        }
    }
}

function Menu-Overrides {
    $classAssets = $null
    $itemAssets  = $null
    $slots       = $null

    while ($true) {
        # Collect all distinct tags in file order
        $tagOrder = [System.Collections.Generic.List[string]]::new()
        $tagSet   = @{}
        foreach ($o in $script:overrides) {
            $t = if ($null -eq $o.Tag) { '' } else { $o.Tag }
            if (-not $tagSet.ContainsKey($t)) { $tagSet[$t] = $true; $tagOrder.Add($t) }
        }

        # Build menu items: create first, then named tags (sorted), then (untagged) if present
        $menuTags    = [System.Collections.Generic.List[string]]::new()
        $menuLabels  = [System.Collections.Generic.List[string]]::new()
        $menuLabels.Add('+ Create new override')
        foreach ($t in ($tagOrder | Where-Object { $_ -ne '' } | Sort-Object)) {
            $cnt = @($script:overrides | Where-Object { $_.Tag -eq $t }).Count
            $menuTags.Add($t)
            $menuLabels.Add("$t  ($cnt)")
        }
        if ($tagSet.ContainsKey('')) {
            $cnt = @($script:overrides | Where-Object { $null -eq $_.Tag -or $_.Tag -eq '' }).Count
            $menuTags.Add('')
            $menuLabels.Add("(untagged)  ($cnt)")
        }
        $menuLabels.Add('< Back')

        $c = Show-Menu "Loadout Overrides  ($($script:overrides.Count) total)" $menuLabels.ToArray()
        if ($c -lt 0 -or $c -eq ($menuLabels.Count - 1)) { return }

        if ($c -eq 0) {
            Create-Override ([ref]$classAssets) ([ref]$itemAssets) ([ref]$slots) $null
            continue
        }

        $selTag   = $menuTags[$c - 1]  # -1 to skip the leading Create entry
        $selLabel = if ($selTag -eq '') { '(untagged)' } else { $selTag }
        Menu-OverridesForTag $selTag $selLabel ([ref]$classAssets) ([ref]$itemAssets) ([ref]$slots)
    }
}

# Wraps Scan-Assets with a 'please wait' screen. Returns hashtable {ClassAssets, ItemAssets, Slots}.
function Scan-AssetsWithStatus {
    Clear-Host
    Write-At 2 2 'Scanning UE4 assets... (this may take a moment)' Yellow
    [Console]::CursorVisible = $false
    $ca    = @(Scan-Assets $script:CLASS_PARENT_CLASS $script:CLASS_SCAN_PATHS '*HolderInfo.uasset')
    $ia    = @(Scan-Assets $script:CLASS_PARENT_ITEM  $script:ITEM_SCAN_PATHS)
    $slots = @(Scan-Slots $ca)
    return @{ ClassAssets = $ca; ItemAssets = $ia; Slots = $slots }
}

function Pick-Tag($defaultTag = $null) {
    $existingTags = @($script:overrides | ForEach-Object { if ($null -eq $_.Tag) { '' } else { $_.Tag } } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
    $options = @('(none)') + $existingTags + @('+ New tag...')
    # Pre-position cursor: '' -> 0, named tag -> its index in $options
    $initIdx = 0
    if ($null -ne $defaultTag) {
        if ($defaultTag -eq '') { $initIdx = 0 }
        else {
            $found = [Array]::IndexOf($existingTags, $defaultTag)
            if ($found -ge 0) { $initIdx = $found + 1 }  # +1 for leading '(none)'
        }
    }
    $idx = Show-Menu 'Pick tag (section)' $options '' $initIdx
    if ($idx -lt 0) { return $null }
    if ($idx -eq 0) { return '' }
    if ($idx -eq ($options.Count - 1)) {
        Clear-Host
        $newTag = Read-Line-TUI 2 3 'Tag name: '
        if ($null -eq $newTag -or $newTag.Trim() -eq '') { return $null }
        return $newTag.Trim()
    }
    return $options[$idx]
}

function Override-Actions($idx, [ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    while ($true) {
        $o      = $script:overrides[$idx]
        $clsShort  = ($o.Class -split '/' | Select-Object -Last 1) -replace '\..+$'
        $itemShort = ($o.Item  -split '/' | Select-Object -Last 1) -replace '\..+$'
        $tagLabel  = if ($null -eq $o.Tag -or $o.Tag -eq '') { '(none)' } else { $o.Tag }
        $menuItems = @(
            "Class:    $clsShort",
            "Slot:     $($o.Slot)",
            "Item:     $itemShort",
            "Players:  $($o.Players)",
            "Tag:      $tagLabel",
            'Delete',
            '< Back'
        )
        $c = Show-Menu (Format-OverrideLabel $o) $menuItems
        switch ($c) {
            -1 { return }
            6  { return }
            0 {
                if ($null -eq $classAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
                $newClass = Pick-Asset 'Edit Class (ZomboyLoadoutHolderDataInfo)' $classAssets.Value
                if ($null -ne $newClass) { $script:overrides[$idx].Class = $newClass; Save-Overrides; Show-Status 'Class updated.' }
            }
            1 {
                if ($null -eq $slots.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
                $slotIdx = Show-Menu 'Edit Slot' $slots.Value
                if ($slotIdx -ge 0) { $script:overrides[$idx].Slot = $slots.Value[$slotIdx]; Save-Overrides; Show-Status 'Slot updated.' }
            }
            2 {
                if ($null -eq $itemAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
                $newItem = Pick-Asset 'Edit Item (ZomboyInteractableActor)' $itemAssets.Value
                if ($null -ne $newItem) { $script:overrides[$idx].Item = $newItem; Save-Overrides; Show-Status 'Item updated.' }
            }
            3 {
                $allTargets  = @($script:users.Keys) + @($script:groups.Keys | ForEach-Object { "@$_" })
                $curPlayers  = @($script:overrides[$idx].Players -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                $newPlayers  = Pick-Players $allTargets $curPlayers
                if ($null -ne $newPlayers) { $script:overrides[$idx].Players = ($newPlayers -join ','); Save-Overrides; Show-Status 'Players updated.' }
            }
            4 {
                $newTag = Pick-Tag
                if ($null -ne $newTag) { $script:overrides[$idx].Tag = $newTag; Save-Overrides; Show-Status 'Tag updated.' }
            }
            5 { Delete-Override $idx; return }
        }
    }
}

# Pick an asset from a scanned array via fuzzy picker. Returns GamePath or $null.
function Pick-Asset($title, [PSCustomObject[]]$assets) {
    if ($assets.Count -eq 0) {
        Show-Status "No assets found. Check `$UE4ContentPath in the script." Yellow
        return $null
    }
    $labels    = @($assets | ForEach-Object { $_.Label })
    $gamePaths = @($assets | ForEach-Object { $_.GamePath })
    $picked    = Show-Picker $title $labels $false $gamePaths 'fuzzy' $null $false
    if ($null -eq $picked) { return $null }
    $i = [Array]::IndexOf($labels, $picked)
    return $gamePaths[$i]
}

function Create-Override([ref]$classAssets, [ref]$itemAssets, [ref]$slots, $defaultTag = $null) {
    # Scan assets on demand (first time only)
    if ($null -eq $classAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }

    # CLASS
    $newClass = Pick-Asset 'Override: Pick class (ZomboyLoadoutHolderDataInfo)' $classAssets.Value
    if ($null -eq $newClass) { return }

    # SLOT
    $slotIdx = Show-Menu 'Override: Pick slot' $slots.Value
    if ($slotIdx -lt 0) { return }
    $newSlot = $slots.Value[$slotIdx]

    # ITEM
    $newItem = Pick-Asset 'Override: Pick item (ZomboyInteractableActor)' $itemAssets.Value
    if ($null -eq $newItem) { return }

    # PLAYERS
    $allTargets = @($script:users.Keys) + @($script:groups.Keys | ForEach-Object { "@$_" })
    $newPlayers = Pick-Players $allTargets @()

    # TAG
    $newTag = Pick-Tag $defaultTag
    if ($null -eq $newTag) { return }

    $script:overrides.Add(@{ Class = $newClass; Slot = $newSlot; Item = $newItem; Players = ($newPlayers -join ','); Tag = $newTag })
    Save-Overrides
    Show-Status 'Override created.'
}

function Delete-Override($idx) {
    $label = Format-OverrideLabel $script:overrides[$idx]
    $c = Show-Menu "Delete override?" @('Yes, delete', '< Cancel') $label
    if ($c -ne 0) { return }
    $script:overrides.RemoveAt($idx)
    Save-Overrides
    Show-Status 'Override deleted.' Yellow
}

# Multi-select picker for players/groups. $preSelected highlights existing selections.
function Pick-Players([string[]]$allTargets, [string[]]$preSelected) {
    # Pre-seed the multi-select picker with currently assigned players/groups
    $picked = Show-Picker 'Override: Pick players/groups  (Space=toggle, Enter=confirm)' $allTargets $true $null 'fuzzy' $preSelected
    if ($null -eq $picked) { return $null }   # cancelled
    return @($picked)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Blacklist management
# ---------------------------------------------------------------------------

function Get-UnixNow {
    [int64](([datetime]::UtcNow - [datetime]'1970-01-01T00:00:00Z').TotalSeconds)
}

function Format-UnixDate([string]$ts) {
    if ($ts -eq '' -or $null -eq $ts) { return 'permanent' }
    try {
        $epoch = [datetime]'1970-01-01T00:00:00Z'
        $dt = $epoch.AddSeconds([int64]$ts).ToLocalTime()
        return $dt.ToString('yyyy-MM-dd HH:mm')
    } catch { return $ts }
}

function Load-Blacklist {
    $script:blacklist = [System.Collections.Generic.List[hashtable]]::new()
    if (-not (Test-Path $script:BlacklistFile)) { return }
    $lines   = Get-Content $script:BlacklistFile
    $current = $null
    foreach ($line in $lines) {
        $l = $line.Trim()
        if ($l -match '^NAME:\s*(.+)') {
            if ($null -ne $current) { $script:blacklist.Add($current) }
            $current = @{ Name = $Matches[1].Trim(); Uid = ''; Punishment = ''; Reason = ''; EndDate = '' }
        } elseif ($null -ne $current) {
            if      ($l -match '^UID:\s*(.*)')        { $current.Uid        = $Matches[1].Trim() }
            elseif  ($l -match '^PUNISHMENT:\s*(.*)') { $current.Punishment = $Matches[1].Trim() }
            elseif  ($l -match '^REASON:\s*(.*)')     { $current.Reason     = $Matches[1].Trim() }
            elseif  ($l -match '^END_DATE:\s*(.*)')   { $current.EndDate    = $Matches[1].Trim() }
        }
    }
    if ($null -ne $current) { $script:blacklist.Add($current) }
}

function Save-Blacklist {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('L!ListBegin')
    foreach ($e in $script:blacklist) {
        $lines.Add("NAME: $($e.Name)")
        $lines.Add("UID: $($e.Uid)")
        if ($e.Punishment -ne '') { $lines.Add("PUNISHMENT: $($e.Punishment)") }
        if ($e.Reason     -ne '') { $lines.Add("REASON: $($e.Reason)") }
        if ($e.EndDate    -ne '') { $lines.Add("END_DATE: $($e.EndDate)") }
    }
    $lines.Add('L!ListEnd')
    Set-Content -Path $script:BlacklistFile -Value $lines -Encoding UTF8
}

function Format-BlacklistLabel($e) {
    $meta = @()
    if ($e.Punishment -ne '') { $meta += $e.Punishment }
    if ($e.Reason     -ne '') { $meta += $e.Reason }
    if ($e.EndDate    -ne '') { $meta += "until $(Format-UnixDate $e.EndDate)" }
    if ($meta.Count -gt 0) { "$($e.Name)  [$($meta -join ' | ')]" }
    else                   { $e.Name }
}

function Pick-EndDate {
    # Returns unix timestamp string, '' for permanent/no date, or $null to cancel
    $options = @(
        'Permanent (no end date)',
        '1 day', '3 days', '7 days', '14 days',
        '30 days', '60 days', '90 days',
        'Custom...'
    )
    $idx = Show-Menu 'Pick ban duration' $options
    if ($idx -lt 0) { return $null }
    if ($idx -eq 0) { return '' }

    $dayTable = @(0, 1, 3, 7, 14, 30, 60, 90)
    $days = 0
    if ($idx -ge 1 -and $idx -le 7) {
        $days = $dayTable[$idx]
    } elseif ($idx -eq 8) {
        $unitIdx = Show-Menu 'Duration unit' @('Days', 'Weeks', 'Months')
        if ($unitIdx -lt 0) { return $null }
        Clear-Host
        Write-At 2 1 'Custom duration' Cyan
        $numStr = Read-Line-TUI 2 3 'Amount: '
        if ($null -eq $numStr) { return $null }
        $num = 0
        if (-not [int]::TryParse($numStr.Trim(), [ref]$num) -or $num -le 0) {
            Show-Status 'Invalid number.' Red
            return $null
        }
        if ($unitIdx -eq 0)      { $days = $num }
        elseif ($unitIdx -eq 1)  { $days = $num * 7 }
        else                     { $days = $num * 30 }
    }

    if ($days -le 0) { return '' }
    [string](( Get-UnixNow) + [int64]$days * 86400)
}

function Blacklist-EditFields($entry) {
    # Edits $entry hashtable in-place. Returns $true if saved, $false if cancelled.
    Clear-Host
    $isNew = ($entry.Name -eq '')
    $editTitle = if ($isNew) { 'Add Blacklist Entry' } else { "Edit: $($entry.Name)" }
    Write-At 2 1 $editTitle Cyan
    Write-At 2 2 'Esc on any field cancels.' DarkGray

    # NAME
    $newName = $null
    while ($true) {
        Clear-Region 2 7 ([Console]::WindowWidth - 4) 1
        $newName = Read-Line-TUI 2 4 'Name:  ' $entry.Name
        if ($null -eq $newName) { return $false }
        $newName = $newName.Trim()
        if ($newName -eq '') { Show-Error 'Name cannot be empty.' 7; continue }
        break
    }

    # UID
    $newUid = Read-Line-TUI 2 5 'UID:   ' $entry.Uid
    if ($null -eq $newUid) { return $false }
    $newUid = $newUid.Trim()

    # PUNISHMENT
    $punishments = @('(none)', 'BAN', 'MUTE', 'WARN')
    $curPunIdx   = if ($entry.Punishment -eq '') { 1 } else { [Array]::IndexOf($punishments, $entry.Punishment) }
    if ($curPunIdx -lt 0) { $curPunIdx = 1 }
    $curPunLabel = if ($entry.Punishment -ne '') { $entry.Punishment } else { 'none' }
    $punIdx = Show-Menu "Punishment  (current: $curPunLabel)" $punishments
    if ($punIdx -lt 0) { return $false }
    $newPunishment = if ($punIdx -eq 0) { '' } else { $punishments[$punIdx] }

    # REASON
    $reasons    = @('(none)', 'BAN_EVADING', 'TOXICITY', 'HARASSMENT')
    $curResIdx  = if ($entry.Reason -eq '') { 0 } else { [Array]::IndexOf($reasons, $entry.Reason) }
    if ($curResIdx -lt 0) { $curResIdx = 0 }
    $curResLabel = if ($entry.Reason -ne '') { $entry.Reason } else { 'none' }
    $resIdx = Show-Menu "Reason  (current: $curResLabel)" $reasons
    if ($resIdx -lt 0) { return $false }
    $newReason = if ($resIdx -eq 0) { '' } else { $reasons[$resIdx] }

    # END_DATE
    $curDateLabel = if ($entry.EndDate -ne '') { "current: $(Format-UnixDate $entry.EndDate)" } else { 'currently permanent' }
    $dateOpts = if ($isNew) { @('Permanent', 'Set duration') } else { @('Keep current', 'Set new duration', 'Clear (permanent)') }
    $dateChoice = Show-Menu "End date  ($curDateLabel)" $dateOpts
    if ($dateChoice -lt 0) { return $false }

    $newEndDate = $entry.EndDate
    if ($isNew) {
        if ($dateChoice -eq 1) {
            $picked = Pick-EndDate
            if ($null -eq $picked) { return $false }
            $newEndDate = $picked
        } else { $newEndDate = '' }
    } else {
        if ($dateChoice -eq 1) {
            $picked = Pick-EndDate
            if ($null -eq $picked) { return $false }
            $newEndDate = $picked
        } elseif ($dateChoice -eq 2) { $newEndDate = '' }
    }

    $entry.Name       = $newName
    $entry.Uid        = $newUid
    $entry.Punishment = $newPunishment
    $entry.Reason     = $newReason
    $entry.EndDate    = $newEndDate
    return $true
}

function Blacklist-Create {
    $entry = @{ Name = ''; Uid = ''; Punishment = ''; Reason = ''; EndDate = '' }
    $saved = Blacklist-EditFields $entry
    if (-not $saved -or $entry.Name -eq '') { return }
    $script:blacklist.Add($entry)
    Save-Blacklist
    Show-Status "Added '$($entry.Name)' to blacklist."
}

function Blacklist-Actions($idx) {
    while ($true) {
        $e     = $script:blacklist[$idx]
        $label = Format-BlacklistLabel $e
        $sub   = if ($e.Uid -ne '') { "UID: $($e.Uid)" } else { 'No UID' }
        $c = Show-Menu $label @('Edit', 'Delete', '< Back') $sub
        switch ($c) {
            -1 { return } 2 { return }
            0 {
                $saved = Blacklist-EditFields $e
                if ($saved) { Save-Blacklist; Show-Status "Saved '$($e.Name)'." }
            }
            1 {
                $c2 = Show-Menu "Remove '$($e.Name)'?" @('Yes, delete', '< Cancel')
                if ($c2 -eq 0) {
                    $script:blacklist.RemoveAt($idx)
                    Save-Blacklist
                    Show-Status "Removed '$($e.Name)'." Yellow
                    return
                }
            }
        }
    }
}

function Menu-Blacklist {
    Load-Blacklist
    while ($true) {
        $CREATE_NEW = '+ Add new entry'
        $labels     = @($CREATE_NEW) + @($script:blacklist | ForEach-Object { Format-BlacklistLabel $_ })
        $subtexts   = @('') + @($script:blacklist | ForEach-Object { $_.Uid })
        $picked = Show-Picker "Blacklist ($($script:blacklist.Count))" $labels $false $subtexts 'contains'
        if ($null -eq $picked) { return }
        if ($picked -eq $CREATE_NEW) {
            Blacklist-Create
        } else {
            $idx = [Array]::IndexOf($labels, $picked) - 1
            if ($idx -ge 0 -and $idx -lt $script:blacklist.Count) {
                Blacklist-Actions $idx
            }
        }
    }
}

Load-Data
Load-Overrides
Hide-Cursor

try {
    while ($true) {
        $c = Show-Menu 'Feathered Unicorns - Manager' @('Manage Users', 'Manage Groups', 'Manage Loadout Overrides', 'Manage Blacklist', 'Exit') `
            "Users: $($script:users.Count)   Groups: $($script:groups.Count)   Overrides: $($script:overrides.Count)"
        switch ($c) {
            -1 { break }
            0  { Menu-Users }
            1  { Menu-Groups }
            2  { Menu-Overrides }
            3  { Menu-Blacklist }
            4  { Clear-Host; Show-Cursor; exit }
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
