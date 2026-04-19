# manage.ps1 - TUI manager for feathered-unicorns users and groups
# Requires PowerShell 5.1+. Save as UTF-8 with BOM or ASCII to avoid encoding issues.

$UsersFile         = "$PSScriptRoot\..\users.txt"
$OverridesFile     = "$PSScriptRoot\..\loadout-overrides\default-loadout-overrides.txt"
$BlacklistFile      = "$PSScriptRoot\..\blacklist.txt"
$CustomLoadoutsFile = "$PSScriptRoot\..\custom-loadouts\default-custom-loadouts.txt"
$UE4ContentPath     = "$PSScriptRoot\..\..\ContractorsVR\ModProject\Content"

# UE4 parent class strings used to identify asset types by scanning raw binary
$CLASS_PARENT_CLASS      = 'ZomboyLoadoutHolderDataInfo'
$CLASS_ITEM_WEAPON_TYPES = @('TF2InteractableActor', 'TF2Gun', 'TF2MeleeWeapon', 'TF2Fists')
$CLASS_ITEM_ATTACH_TYPE  = 'TF2LoadoutAttachment'
$CLASS_ATTACHMENT_SLOTS  = @('Hat', 'Misc', 'Misc 2')
# Maps known slot names to the item sub-types valid for that slot.
# Get-ItemsForSlot uses this so the HolderInfo binary search only matches
# items of the right type for the slot, not items from all slots.
$SLOT_ITEM_TYPES = @{
    'Melee'     = @('TF2MeleeWeapon', 'TF2Fists')
    'Primary'   = @('TF2Gun', 'TF2InteractableActor')
    'Secondary' = @('TF2Gun', 'TF2InteractableActor')
}

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
$blacklist      = [System.Collections.Generic.List[hashtable]]::new()  # list of {Name,Uid,Punishment,Reason,EndDate}
$customLoadouts = [System.Collections.Generic.List[hashtable]]::new()  # list of {Name, Classes}
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
function Scan-Assets([string[]]$parentClasses, [string[]]$subPaths, $nameFilter = '*.uasset', $classSuffix = '') {
    $cacheKey = "$($parentClasses -join '+')_$($subPaths -join '|')_$classSuffix"
    if ($script:assetCache.ContainsKey($cacheKey)) { return $script:assetCache[$cacheKey] }

    if (-not (Test-Path $script:UE4ContentPath)) {
        $script:assetCache[$cacheKey] = @()
        return @()
    }

    # Compile parallel scanner once per session
    if (-not ('AssetScanner' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.IO;
using System.Text;
using System.Threading.Tasks;
public static class AssetScanner {
    public static List<string[]> Scan(string[] paths, string[] parentClasses, string resolvedBase, string classSuffix) {
        var bag = new ConcurrentBag<string[]>();
        var enc = Encoding.GetEncoding(28591);
        var rb  = resolvedBase.TrimEnd('\\');
        Parallel.ForEach(paths, path => {
            byte[] bytes;
            using (var fs = File.OpenRead(path)) {
                int toRead = (int)Math.Min(fs.Length, 524288L);
                bytes = new byte[toRead];
                int offset = 0, read;
                while (offset < toRead && (read = fs.Read(bytes, offset, toRead - offset)) > 0) offset += read;
            }
            string text = enc.GetString(bytes);
            string matched = null;
            foreach (var pc in parentClasses) { if (text.Contains(pc)) { matched = pc; break; } }
            if (matched != null) {
                string rel      = path.Substring(rb.Length).TrimStart('\\').Replace('\\', '/');
                string noExt    = rel.EndsWith(".uasset") ? rel.Substring(0, rel.Length - 7) : rel;
                string name     = Path.GetFileNameWithoutExtension(path);
                string gamePath = "/Game/" + noExt + "." + name + classSuffix;
                bag.Add(new string[] { name, gamePath, path, matched });
            }
        });
        var list = new List<string[]>(bag);
        list.Sort((a, b) => StringComparer.OrdinalIgnoreCase.Compare(a[0], b[0]));
        return list;
    }
}
'@
    }

    $resolvedBase = (Resolve-Path $script:UE4ContentPath).Path.TrimEnd('\')
    $filePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($sub in $subPaths) {
        $dir = Join-Path $resolvedBase $sub
        if (Test-Path $dir) {
            foreach ($f in (Get-ChildItem -Path $dir -Filter $nameFilter -Recurse -File)) {
                $filePaths.Add($f.FullName)
            }
        }
    }

    if ($filePaths.Count -eq 0) { $script:assetCache[$cacheKey] = @(); return @() }

    Write-At 2 3 "  Scanning $($filePaths.Count) files in parallel..." DarkGray
    $raw = [AssetScanner]::Scan($filePaths.ToArray(), $parentClasses, $resolvedBase, $classSuffix)

    # Determine which subpaths are contributions so those assets can be flagged as deprecated
    $contribPrefix = $null
    foreach ($sub in $subPaths) {
        if ($sub -match '(?i)^Contributions') {
            $contribPrefix = Join-Path $resolvedBase $sub; break
        }
    }
    # Build objects, sort canonical (non-deprecated) before contributions so that
    # when deduplicating by Label the canonical copy always wins, then re-sort by Label.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $arr = @($raw | ForEach-Object {
        $isDepr = $null -ne $contribPrefix -and $_[2].StartsWith($contribPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        [PSCustomObject]@{ Label = $_[0]; GamePath = $_[1]; FilePath = $_[2]; Type = $_[3]; IsDeprecated = $isDepr }
    } | Sort-Object IsDeprecated, Label | Where-Object { $seen.Add($_.Label) })
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
    $top = 0

    function Render {
        Clear-Host
        $h        = [Console]::WindowHeight
        $w        = [Console]::WindowWidth - 4
        $visCount = [Math]::Max(1, $h - 5)
        Write-At 2 1 $title Cyan
        Write-At 2 2 ('-' * [Math]::Min($title.Length + 2, $w)) DarkCyan
        for ($i = $top; $i -lt $items.Count -and ($i - $top) -lt $visCount; $i++) {
            $row   = $i - $top + 3
            $label = "   $($items[$i])  "
            if ($i -eq $sel) { Write-At 2 $row $label Black White }
            elseif ($items[$i] -like '+*') { Write-At 2 $row $label Green }
            elseif ($items[$i] -like '<*') { Write-At 2 $row $label DarkGray }
            else                           { Write-At 2 $row $label White }
        }
        $fy = [Math]::Min($visCount + 3, $h - 2)
        $nav = if ($items.Count -gt $visCount) { "  ($($sel + 1)/$($items.Count))  Up/Down: scroll    Enter: select    Esc: back" } else { 'Arrow keys: navigate    Enter: select    Esc: back' }
        if ($fy -ge 0 -and $fy -lt $h) { Write-At 2 $fy $nav DarkGray }
        if ($statusLine -ne '' -and ($fy + 1) -lt $h) { Write-At 2 ($fy + 1) $statusLine Yellow }
    }

    Render
    while ($true) {
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'UpArrow' {
                if ($sel -gt 0) {
                    $sel--
                    $visCount = [Math]::Max(1, [Console]::WindowHeight - 5)
                    if ($sel -lt $top) { $top = $sel }
                }
                Render
            }
            'DownArrow' {
                if ($sel -lt $items.Count - 1) {
                    $sel++
                    $visCount = [Math]::Max(1, [Console]::WindowHeight - 5)
                    if ($sel -ge $top + $visCount) { $top = $sel - $visCount + 1 }
                }
                Render
            }
            'Enter'  { Show-Cursor; return $sel }
            'Escape' { Show-Cursor; return -1 }
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
                @(0..($items.Count - 1) | ForEach-Object {
                    $candidate = $items[$_].ToLower()
                    if ($searchSubtexts -and $null -ne $subtexts -and $_ -lt $subtexts.Count -and $subtexts[$_] -ne '') {
                        $candidate = "$candidate $($subtexts[$_].ToLower())"
                    }
                    if ($filterMode -eq 'contains') {
                        if ($candidate.Contains($q)) { [PSCustomObject]@{ Idx = $_; Score = 1 } }
                    } else {
                        $s = $candidate; $qi = 0; $bestRun = 0; $curRun = 0; $lastPos = -2
                        for ($ci = 0; $ci -lt $s.Length; $ci++) {
                            if ($qi -lt $q.Length -and $s[$ci] -eq $q[$qi]) {
                                $curRun = if ($ci -eq $lastPos + 1) { $curRun + 1 } else { 1 }
                                if ($curRun -gt $bestRun) { $bestRun = $curRun }
                                $lastPos = $ci; $qi++
                            }
                        }
                        if ($qi -eq $q.Length) { [PSCustomObject]@{ Idx = $_; Score = $bestRun } }
                    }
                } | Where-Object { $null -ne $_ } | Sort-Object @{E='Score';D=$true},@{E={$items[$_.Idx].Length};D=$false} | ForEach-Object { $items[$_.Idx] })
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
                    if ($sub -ne '') {
                        $subColor = if ($sub.Contains('[DEPRECATED]')) { 'Yellow' } else { 'DarkGray' }
                        Write-At (2 + $label.Length) ($listY+$vi) $sub $subColor
                    }
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
    $allItemTypes = $script:CLASS_ITEM_WEAPON_TYPES + @($script:CLASS_ITEM_ATTACH_TYPE)
    $ca    = @(Scan-Assets @($script:CLASS_PARENT_CLASS) $script:CLASS_SCAN_PATHS '*HolderInfo.uasset')
    $ia    = @(Scan-Assets $allItemTypes $script:ITEM_SCAN_PATHS '*.uasset' '_C')
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
            'Copy',
            'Delete',
            '< Back'
        )
        $c = Show-Menu (Format-OverrideLabel $o) $menuItems
        switch ($c) {
            -1 { return }
            7  { return }
            0 {
                if ($null -eq $classAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
                $newClass = Pick-Asset 'Edit Class (ZomboyLoadoutHolderDataInfo)' $classAssets.Value
                if ($null -ne $newClass) { $script:overrides[$idx].Class = $newClass; Save-Overrides; Show-Status 'Class updated.' }
            }
            1 {
                if ($null -eq $classAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
                $classObj   = @($classAssets.Value | Where-Object { $_.GamePath -eq $o.Class })[0]
                $classSlots = if ($null -ne $classObj) { @(Scan-Slots @($classObj)) } else { @() }
                if ($classSlots.Count -eq 0) { $classSlots = @($slots.Value) }
                $slotIdx = Show-Menu 'Edit Slot' $classSlots
                if ($slotIdx -ge 0) { $script:overrides[$idx].Slot = $classSlots[$slotIdx]; Save-Overrides; Show-Status 'Slot updated.' }
            }
            2 {
                if ($null -eq $itemAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
                $slotItems   = Get-ItemsForSlot $itemAssets.Value $o.Slot
                $classObj    = @($classAssets.Value | Where-Object { $_.GamePath -eq $o.Class })[0]
                $holderPath  = if ($null -ne $classObj) { $classObj.FilePath } else { $null }
                $newItem = Pick-ItemWithDefaults "Edit Item  [$($o.Slot)]" $o.Slot $slotItems $holderPath
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
            5 { Copy-Override $idx $classAssets $itemAssets $slots; return }
            6 { Delete-Override $idx; return }
        }
    }
}

# Filter item assets to only those valid for the given slot name.
function Get-ItemsForSlot([PSCustomObject[]]$allItems, [string]$slotName) {
    if ($null -eq $slotName -or $slotName -eq '' -or $allItems.Count -eq 0) { return $allItems }
    if ($script:CLASS_ATTACHMENT_SLOTS -contains $slotName) {
        return @($allItems | Where-Object { $_.Type -eq $script:CLASS_ITEM_ATTACH_TYPE })
    }
    if ($script:SLOT_ITEM_TYPES.ContainsKey($slotName)) {
        $types = $script:SLOT_ITEM_TYPES[$slotName]
        return @($allItems | Where-Object { $types -contains $_.Type })
    }
    return @($allItems | Where-Object { $script:CLASS_ITEM_WEAPON_TYPES -contains $_.Type })
}

# Returns the subset of $slotItems that the HolderInfo assigns to $slotName.
# Parses the UE4 name table and scans for (itemNameIdx, 0, ELoadoutCategory_XXX_idx, 0)
# patterns in the binary data, which is how TMap<FName, ELoadoutCategory> is serialised.
# Falls back to a plain token-present check when parsing fails or no category map is found.
function Get-HolderInfoDefaults([string]$holderFilePath, [PSCustomObject[]]$slotItems, [string]$slotName = '') {
    if ($null -eq $holderFilePath -or $holderFilePath -eq '' -or -not (Test-Path $holderFilePath)) { return @() }
    if ($slotItems.Count -eq 0) { return @() }
    if (-not ('HolderInfoParser' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public static class HolderInfoParser {
    static string ReadFString(BinaryReader br) {
        int len = br.ReadInt32();
        if (len == 0) return string.Empty;
        if (len > 0) {
            byte[] buf = br.ReadBytes(len);
            return Encoding.ASCII.GetString(buf, 0, Math.Max(0, len - 1));
        }
        byte[] ubuf = br.ReadBytes(-len * 2);
        return Encoding.Unicode.GetString(ubuf, 0, Math.Max(0, (-len - 1) * 2));
    }
    // Returns dict: item blueprint class name (e.g. "Syringegun_C") -> slot name ("Primary" etc.)
    public static Dictionary<string, string> GetItemCategories(string filePath) {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try {
            byte[] bytes = File.ReadAllBytes(filePath);
            using (var ms = new MemoryStream(bytes))
            using (var br = new BinaryReader(ms)) {
                if (br.ReadUInt32() != 0x9E2A83C1) return result;
                br.ReadInt32(); // LegacyFileVersion
                br.ReadInt32(); // LegacyUE3Version
                br.ReadInt32(); // FileVersionUE4
                br.ReadInt32(); // FileVersionLicenseeUE4
                int cvCount = br.ReadInt32();
                for (int i = 0; i < cvCount; i++) { br.ReadBytes(16); br.ReadInt32(); }
                br.ReadInt32(); // TotalHeaderSize
                ReadFString(br); // FolderName
                br.ReadUInt32(); // PackageFlags
                int nameCount = br.ReadInt32();
                int nameOffset = br.ReadInt32();
                ms.Seek(nameOffset, SeekOrigin.Begin);
                var names = new string[nameCount];
                for (int i = 0; i < nameCount; i++) {
                    names[i] = ReadFString(br);
                    br.ReadUInt32(); // NonCasePreservingHash + CasePreservingHash (2x uint16)
                }
                // Map category enum names -> slot label
                var catNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                    { "ELoadoutCategory_Primary", "Primary" },
                    { "ELoadoutCategory_Sidearm", "Sidearm" },
                    { "ELoadoutCategory_Melee",   "Melee"   },
                    { "ELoadoutCategory_Gadget",  "Gadget"  }
                };
                var catMap = new Dictionary<int, string>();
                var itemIdxSet = new HashSet<int>();
                for (int i = 0; i < names.Length; i++) {
                    string n = names[i];
                    if (catNames.TryGetValue(n, out string slot)) catMap[i] = slot;
                    else if (n.EndsWith("_C") && n.Length > 2) itemIdxSet.Add(i);
                }
                if (catMap.Count == 0 || itemIdxSet.Count == 0) return result;
                // Scan binary as int32 array for pattern [itemIdx][0][catIdx][0]
                // This matches TMap<FName,ELoadoutCategory> serialised as FName key + FName enum value
                int intLen = bytes.Length / 4;
                for (int i = 0; i <= intLen - 4; i++) {
                    int v0 = BitConverter.ToInt32(bytes, i * 4);
                    if (!itemIdxSet.Contains(v0)) continue;
                    if (BitConverter.ToInt32(bytes, (i + 1) * 4) != 0) continue;
                    int v2 = BitConverter.ToInt32(bytes, (i + 2) * 4);
                    if (!catMap.ContainsKey(v2)) continue;
                    if (BitConverter.ToInt32(bytes, (i + 3) * 4) != 0) continue;
                    result[names[v0]] = catMap[v2];
                }
            }
        } catch { }
        return result;
    }
}
'@
    }
    $categories = [HolderInfoParser]::GetItemCategories($holderFilePath)
    if ($categories.Count -gt 0 -and $slotName -ne '') {
        # Use the precise per-item category mapping from the UE4 asset
        return @($slotItems | Where-Object {
            $assetName = ($_.GamePath -split '\.' | Select-Object -Last 1)
            $categories.ContainsKey($assetName) -and $categories[$assetName] -eq $slotName
        })
    }
    # Fallback: token-present check (no category data found or slotName not specified)
    $bytes = [System.IO.File]::ReadAllBytes($holderFilePath)
    $text  = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    return @($slotItems | Where-Object {
        $assetName = ($_.GamePath -split '\.' | Select-Object -Last 1)
using System.Collections.Generic;
using System.IO;
using System.Text;
public static class HolderInfoParser {
    static string ReadFString(BinaryReader br) {
        int len = br.ReadInt32();
        if (len == 0) return string.Empty;
        if (len > 0) {
            byte[] buf = br.ReadBytes(len);
            return Encoding.ASCII.GetString(buf, 0, Math.Max(0, len - 1));
        }
        byte[] ubuf = br.ReadBytes(-len * 2);
        return Encoding.Unicode.GetString(ubuf, 0, Math.Max(0, (-len - 1) * 2));
    }
    // Returns dict: item blueprint class name (e.g. "Syringegun_C") -> slot name ("Primary" etc.)
    public static Dictionary<string, string> GetItemCategories(string filePath) {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try {
            byte[] bytes = File.ReadAllBytes(filePath);
            using (var ms = new MemoryStream(bytes))
            using (var br = new BinaryReader(ms)) {
                if (br.ReadUInt32() != 0x9E2A83C1) return result;
                br.ReadInt32(); // LegacyFileVersion
                br.ReadInt32(); // LegacyUE3Version
                br.ReadInt32(); // FileVersionUE4
                br.ReadInt32(); // FileVersionLicenseeUE4
                int cvCount = br.ReadInt32();
                for (int i = 0; i < cvCount; i++) { br.ReadBytes(16); br.ReadInt32(); }
                br.ReadInt32(); // TotalHeaderSize
                ReadFString(br); // FolderName
                br.ReadUInt32(); // PackageFlags
                int nameCount = br.ReadInt32();
                int nameOffset = br.ReadInt32();
                ms.Seek(nameOffset, SeekOrigin.Begin);
                var names = new string[nameCount];
                for (int i = 0; i < nameCount; i++) {
                    names[i] = ReadFString(br);
                    br.ReadUInt32(); // NonCasePreservingHash + CasePreservingHash (2x uint16)
                }
                // Map category enum names -> slot label
                var catNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                    { "ELoadoutCategory_Primary", "Primary" },
                    { "ELoadoutCategory_Sidearm", "Sidearm" },
                    { "ELoadoutCategory_Melee",   "Melee"   },
                    { "ELoadoutCategory_Gadget",  "Gadget"  }
                };
                var catMap = new Dictionary<int, string>();
                var itemIdxSet = new HashSet<int>();
                for (int i = 0; i < names.Length; i++) {
                    string n = names[i];
                    string slot;
                    if (catNames.TryGetValue(n, out slot)) catMap[i] = slot;
                    else if (n.EndsWith("_C") && n.Length > 2) itemIdxSet.Add(i);
                }
                if (catMap.Count == 0 || itemIdxSet.Count == 0) return result;
                // Scan binary as int32 array for pattern [itemIdx][0][catIdx][0]
                // This matches TMap<FName,ELoadoutCategory> serialised as FName key + FName enum value
                int intLen = bytes.Length / 4;
                for (int i = 0; i <= intLen - 4; i++) {
                    int v0 = BitConverter.ToInt32(bytes, i * 4);
                    if (!itemIdxSet.Contains(v0)) continue;
                    if (BitConverter.ToInt32(bytes, (i + 1) * 4) != 0) continue;
                    int v2 = BitConverter.ToInt32(bytes, (i + 2) * 4);
                    if (!catMap.ContainsKey(v2)) continue;
                    if (BitConverter.ToInt32(bytes, (i + 3) * 4) != 0) continue;
                    result[names[v0]] = catMap[v2];
                }
            }
        } catch { }
        return result;
    }
}
'@
    }
    $categories = [HolderInfoParser]::GetItemCategories($holderFilePath)
    if ($categories.Count -gt 0 -and $slotName -ne '') {
        # Use the precise per-item category mapping from the UE4 asset
        return @($slotItems | Where-Object {
            $assetName = ($_.GamePath -split '\.' | Select-Object -Last 1)
            $categories.ContainsKey($assetName) -and $categories[$assetName] -eq $slotName
        })
    }
    # Fallback: token-present check (no category data found or slotName not specified)
    $bytes = [System.IO.File]::ReadAllBytes($holderFilePath)
    $text  = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    return @($slotItems | Where-Object {
        $assetName = ($_.GamePath -split '\.' | Select-Object -Last 1)
        $text.Contains($assetName)
    })
}

# Single-item picker that first offers class-defaults vs all-items choice when defaults exist.
function Pick-ItemWithDefaults($title, $slotName, [PSCustomObject[]]$slotItems, $holderFilePath) {
    $defaultItems = if ($null -ne $holderFilePath -and $holderFilePath -ne '') { Get-HolderInfoDefaults $holderFilePath $slotItems $slotName } else { @() }
    if ($defaultItems.Count -gt 0) {
        $modeIdx = Show-Menu "Item source for '$slotName'" @(
            "Class defaults ($($defaultItems.Count) items)",
            "All items ($($slotItems.Count) items)",
            '< Cancel'
        )
        if ($modeIdx -lt 0 -or $modeIdx -eq 2) { return $null }
        $useItems = if ($modeIdx -eq 0) { $defaultItems } else { $slotItems }
    } else {
        $useItems = $slotItems
    }
    return Pick-Asset $title $useItems
}

# Pick an asset from a scanned array via fuzzy picker. Returns GamePath or $null.
function Pick-Asset($title, [PSCustomObject[]]$assets) {
    if ($assets.Count -eq 0) {
        Show-Status "No assets found. Check `$UE4ContentPath in the script." Yellow
        return $null
    }
    $labels    = @($assets | ForEach-Object { $_.Label })
    $subtexts  = @($assets | ForEach-Object { if ($_.IsDeprecated) { "$($_.GamePath)  [DEPRECATED]" } else { $_.GamePath } })
    $gamePaths = @($assets | ForEach-Object { $_.GamePath })
    $picked    = Show-Picker $title $labels $false $subtexts 'fuzzy' $null $false
    if ($null -eq $picked) { return $null }
    $i = [Array]::IndexOf($labels, $picked)
    return $gamePaths[$i]
}

function Create-Override([ref]$classAssets, [ref]$itemAssets, [ref]$slots, $defaultTag = $null) {
    # Scan assets on demand (first time only)
    if ($null -eq $classAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }

    $newClass   = $null
    $newSlot    = $null
    $newItem    = $null
    $newPlayers = $null
    $newTag     = $null
    $classSlots = @()
    $step = 0   # 0=class, 1=slot, 2=item, 3=players, 4=tag

    while ($step -le 4) {
        if ($step -eq 0) {
            $newClass = Pick-Asset 'Override: Pick class (ZomboyLoadoutHolderDataInfo)' $classAssets.Value
            if ($null -eq $newClass) { return }
            $classObj   = @($classAssets.Value | Where-Object { $_.GamePath -eq $newClass })[0]
            $classSlots = if ($null -ne $classObj) { @(Scan-Slots @($classObj)) } else { @() }
            if ($classSlots.Count -eq 0) { $classSlots = @($slots.Value) }
            $step++
        } elseif ($step -eq 1) {
            $slotIdx = Show-Menu 'Override: Pick slot' $classSlots
            if ($slotIdx -lt 0) { $step-- } else { $newSlot = $classSlots[$slotIdx]; $step++ }
        } elseif ($step -eq 2) {
            if ($null -eq $itemAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
            $slotItems  = Get-ItemsForSlot $itemAssets.Value $newSlot
            $classObj   = @($classAssets.Value | Where-Object { $_.GamePath -eq $newClass })[0]
            $holderPath = if ($null -ne $classObj) { $classObj.FilePath } else { $null }
            $newItem = Pick-ItemWithDefaults "Override: Pick item  [$newSlot]" $newSlot $slotItems $holderPath
            if ($null -eq $newItem) { $step-- } else { $step++ }
        } elseif ($step -eq 3) {
            $allTargets = @($script:users.Keys) + @($script:groups.Keys | ForEach-Object { "@$_" })
            $newPlayers = Pick-Players $allTargets @()
            if ($null -eq $newPlayers) { $step-- } else { $step++ }
        } elseif ($step -eq 4) {
            $newTag = Pick-Tag $defaultTag
            if ($null -eq $newTag) { $step-- } else { $step++ }
        }
    }

    # Duplicate check: warn if any new Class+Slot+Item+Player combo already exists
    $newPlayerSet = [System.Collections.Generic.HashSet[string]]($newPlayers)
    $dupePlayers  = [System.Collections.Generic.List[string]]::new()
    foreach ($existing in $script:overrides) {
        if ($existing.Class -ne $newClass -or $existing.Slot -ne $newSlot -or $existing.Item -ne $newItem) { continue }
        foreach ($p in ($existing.Players -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })) {
            if ($newPlayerSet.Contains($p) -and -not $dupePlayers.Contains($p)) { $dupePlayers.Add($p) }
        }
    }
    if ($dupePlayers.Count -gt 0) {
        $dc = Show-Menu 'Duplicate override detected!' @('Save anyway', '< Cancel') `
            "Already assigned Class+Slot+Item to: $($dupePlayers -join ', ')"
        if ($dc -ne 0) { return }
    }

    $script:overrides.Add(@{ Class = $newClass; Slot = $newSlot; Item = $newItem; Players = ($newPlayers -join ','); Tag = $newTag })
    Save-Overrides
    Show-Status 'Override created.'
}

function Copy-Override($idx, [ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    $src = $script:overrides[$idx]
    $script:overrides.Add(@{ Class = $src.Class; Slot = $src.Slot; Item = $src.Item; Players = $src.Players; Tag = $src.Tag })
    Save-Overrides
    $newIdx = $script:overrides.Count - 1
    Show-Status 'Override copied. Opening new entry...'
    Override-Actions $newIdx $classAssets $itemAssets $slots
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
    if ($ts -eq '' -or $ts -eq '0' -or $null -eq $ts) { return 'permanent' }
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
        $lines.Add("REASON: $($e.Reason)")
        if ($e.EndDate    -ne '') { $lines.Add("END_DATE: $($e.EndDate)") }
    }
    $lines.Add('L!ListEnd')
    Set-Content -Path $script:BlacklistFile -Value $lines -Encoding UTF8
}

function Format-BlacklistLabel($e) {
    $meta = @()
    if ($e.Punishment -ne '') { $meta += $e.Punishment }
    if ($e.Reason     -ne '') { $meta += $e.Reason }
    if ($e.EndDate -ne '' -and $e.EndDate -ne '0') { $meta += "until $(Format-UnixDate $e.EndDate)" }
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
    if ($idx -eq 0) { return '0' }

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

    if ($days -le 0) { return '0' }
    [string](( Get-UnixNow) + [int64]$days * 86400)
}

function Blacklist-Wizard($entry) {
    # Sequential wizard used only when creating a new entry. Returns $true if saved.
    Clear-Host
    Write-At 2 1 'Add Blacklist Entry' Cyan
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
    $punIdx = Show-Menu 'Punishment' $punishments '' 1
    if ($punIdx -lt 0) { return $false }
    $newPunishment = if ($punIdx -eq 0) { '' } else { $punishments[$punIdx] }

    # REASON
    $reasons = @('(none)', 'BAN_EVADING', 'TOXICITY', 'HARASSMENT')
    $resIdx  = Show-Menu 'Reason' $reasons
    if ($resIdx -lt 0) { return $false }
    $newReason = if ($resIdx -eq 0) { '' } else { $reasons[$resIdx] }

    # END_DATE
    $dateChoice = Show-Menu 'End date' @('Permanent', 'Set duration')
    if ($dateChoice -lt 0) { return $false }
    $newEndDate = '0'
    if ($dateChoice -eq 1) {
        $picked = Pick-EndDate
        if ($null -eq $picked) { return $false }
        $newEndDate = $picked
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
    $saved = Blacklist-Wizard $entry
    if (-not $saved -or $entry.Name -eq '') { return }
    $script:blacklist.Add($entry)
    Save-Blacklist
    Show-Status "Added '$($entry.Name)' to blacklist."
}

function Blacklist-Actions($idx) {
    while ($true) {
        $e         = $script:blacklist[$idx]
        $punLabel  = if ($e.Punishment -ne '') { $e.Punishment } else { '(none)' }
        $resLabel  = if ($e.Reason     -ne '') { $e.Reason }     else { '(none)' }
        $dateLabel = if ($e.EndDate -ne '' -and $e.EndDate -ne '0') { Format-UnixDate $e.EndDate } else { 'permanent' }
        $uidLabel  = if ($e.Uid        -ne '') { $e.Uid }        else { '(none)' }
        $menuItems = @(
            "Name:        $($e.Name)",
            "UID:         $uidLabel",
            "Punishment:  $punLabel",
            "Reason:      $resLabel",
            "End date:    $dateLabel",
            'Delete',
            '< Back'
        )
        $c = Show-Menu (Format-BlacklistLabel $e) $menuItems
        switch ($c) {
            -1 { return }
            6  { return }
            0 {
                Clear-Host
                $newName = $null
                while ($true) {
                    Clear-Region 2 7 ([Console]::WindowWidth - 4) 1
                    $newName = Read-Line-TUI 2 4 'Name:  ' $e.Name
                    if ($null -eq $newName) { break }
                    $newName = $newName.Trim()
                    if ($newName -eq '') { Show-Error 'Name cannot be empty.' 7; continue }
                    break
                }
                if ($null -ne $newName -and $newName -ne '') { $script:blacklist[$idx].Name = $newName; Save-Blacklist; Show-Status 'Name updated.' }
            }
            1 {
                Clear-Host
                $newUid = Read-Line-TUI 2 4 'UID:   ' $e.Uid
                if ($null -ne $newUid) { $script:blacklist[$idx].Uid = $newUid.Trim(); Save-Blacklist; Show-Status 'UID updated.' }
            }
            2 {
                $punishments = @('(none)', 'BAN', 'MUTE', 'WARN')
                $curIdx = if ($e.Punishment -eq '') { 0 } else { [Array]::IndexOf($punishments, $e.Punishment) }
                if ($curIdx -lt 0) { $curIdx = 0 }
                $punIdx = Show-Menu 'Edit Punishment' $punishments '' $curIdx
                if ($punIdx -ge 0) {
                    $script:blacklist[$idx].Punishment = if ($punIdx -eq 0) { '' } else { $punishments[$punIdx] }
                    Save-Blacklist; Show-Status 'Punishment updated.'
                }
            }
            3 {
                $reasons = @('(none)', 'BAN_EVADING', 'TOXICITY', 'HARASSMENT')
                $curIdx  = if ($e.Reason -eq '') { 0 } else { [Array]::IndexOf($reasons, $e.Reason) }
                if ($curIdx -lt 0) { $curIdx = 0 }
                $resIdx = Show-Menu 'Edit Reason' $reasons '' $curIdx
                if ($resIdx -ge 0) {
                    $script:blacklist[$idx].Reason = if ($resIdx -eq 0) { '' } else { $reasons[$resIdx] }
                    Save-Blacklist; Show-Status 'Reason updated.'
                }
            }
            4 {
                $curDateLabel = if ($e.EndDate -ne '') { "current: $(Format-UnixDate $e.EndDate)" } else { 'currently permanent' }
                $dateChoice = Show-Menu "End date  ($curDateLabel)" @('Keep current', 'Set new duration', 'Clear (permanent)')
                if ($dateChoice -eq 1) {
                    $picked = Pick-EndDate
                    if ($null -ne $picked) { $script:blacklist[$idx].EndDate = $picked; Save-Blacklist; Show-Status 'End date updated.' }
                } elseif ($dateChoice -eq 2) {
                    $script:blacklist[$idx].EndDate = '0'; Save-Blacklist; Show-Status 'End date cleared (permanent).'
                }
            }
            5 {
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

# ---------------------------------------------------------------------------
# Custom loadouts management
# ---------------------------------------------------------------------------

function Load-CustomLoadouts {
    $script:customLoadouts = [System.Collections.Generic.List[hashtable]]::new()
    if (-not (Test-Path $script:CustomLoadoutsFile)) { return }
    $lines      = Get-Content $script:CustomLoadoutsFile
    $curLoadout = $null
    $curClass   = $null
    $curSlot    = $null
    foreach ($line in $lines) {
        $l = $line.Trim()
        if ($l -match '^LOADOUT:\s*(.+)') {
            if ($null -ne $curSlot  -and $null -ne $curClass)   { $curClass.Slots.Add($curSlot); $curSlot = $null }
            if ($null -ne $curClass -and $null -ne $curLoadout) { $curLoadout.Classes.Add($curClass); $curClass = $null }
            if ($null -ne $curLoadout) { $script:customLoadouts.Add($curLoadout) }
            $curLoadout = @{ Name = $Matches[1].Trim(); SaveId = '0'; Classes = [System.Collections.Generic.List[hashtable]]::new() }
        } elseif ($l -match '^SAVE_ID:\s*(.*)' -and $null -ne $curLoadout -and $null -eq $curClass) {
            $curLoadout.SaveId = $Matches[1].Trim()
        } elseif ($l -match '^CLASS:\s*(.+)') {
            if ($null -ne $curSlot  -and $null -ne $curClass)   { $curClass.Slots.Add($curSlot); $curSlot = $null }
            if ($null -ne $curClass -and $null -ne $curLoadout) { $curLoadout.Classes.Add($curClass) }
            $curClass = @{ Class = $Matches[1].Trim(); Slots = [System.Collections.Generic.List[hashtable]]::new() }
        } elseif ($l -match '^SLOT:\s*(.*)' -and $null -ne $curClass) {
            if ($null -ne $curSlot) { $curClass.Slots.Add($curSlot) }
            $curSlot = @{ Slot = $Matches[1].Trim(); HasNone = 'false'; DefaultItem = ''; Category = ''; Items = [System.Collections.Generic.List[string]]::new() }
        } elseif ($null -ne $curSlot) {
            if      ($l -match '^HAS_NONE:\s*(.*)')      { $curSlot.HasNone     = $Matches[1].Trim() }
            elseif  ($l -match '^DEFAULT_ITEM:\s*(.*)')  { $curSlot.DefaultItem = $Matches[1].Trim() }
            elseif  ($l -match '^CATEGORY:\s*(.*)')      { $curSlot.Category    = $Matches[1].Trim() }
            elseif  ($l -match '^ITEM:\s*(.+)')          { $curSlot.Items.Add($Matches[1].Trim()) }
        }
    }
    if ($null -ne $curSlot  -and $null -ne $curClass)   { $curClass.Slots.Add($curSlot) }
    if ($null -ne $curClass -and $null -ne $curLoadout) { $curLoadout.Classes.Add($curClass) }
    if ($null -ne $curLoadout) { $script:customLoadouts.Add($curLoadout) }
}

function Save-CustomLoadouts {
    $out   = [System.Collections.Generic.List[string]]::new()
    $first = $true
    foreach ($lo in $script:customLoadouts) {
        if (-not $first) { $out.Add('') }
        $out.Add("LOADOUT: $($lo.Name)")
        $sid = if ($null -eq $lo.SaveId -or $lo.SaveId -eq '') { '0' } else { $lo.SaveId }
        $out.Add("SAVE_ID: $sid")
        foreach ($c in $lo.Classes) {
            $out.Add("CLASS: $($c.Class)")
            foreach ($s in $c.Slots) {
                $out.Add("SLOT: $($s.Slot)")
                $out.Add("HAS_NONE: $($s.HasNone)")
                if ($s.DefaultItem -ne '') { $out.Add("DEFAULT_ITEM: $($s.DefaultItem)") }
                $out.Add("CATEGORY: $($s.Category)")
                foreach ($item in $s.Items) { $out.Add("ITEM: $item") }
            }
        }
        $first = $false
    }
    Set-Content -Path $script:CustomLoadoutsFile -Value $out.ToArray() -Encoding UTF8
}

function Format-LoadoutClassLabel($c) {
    $cls        = ($c.Class -split '/' | Select-Object -Last 1) -replace '\..+$'
    $slotNames  = if ($c.Slots.Count -gt 0) { (@($c.Slots | ForEach-Object { $_.Slot })) -join ', ' } else { 'no slots' }
    $totalItems = ($c.Slots | ForEach-Object { $_.Items.Count } | Measure-Object -Sum).Sum
    if ($null -eq $totalItems) { $totalItems = 0 }
    "$cls  [$slotNames]  ($totalItems items)"
}

function Menu-CustomLoadouts {
    $classAssets = $null
    $itemAssets  = $null
    $slots       = $null
    while ($true) {
        $CREATE_NEW = '+ Create new loadout'
        $labels     = @($CREATE_NEW) + @($script:customLoadouts | ForEach-Object { "$($_.Name)  ($($_.Classes.Count) classes)" })
        $picked = Show-Picker "Custom Loadouts ($($script:customLoadouts.Count))" $labels
        if ($null -eq $picked) { return }
        if ($picked -eq $CREATE_NEW) {
            Create-CustomLoadout ([ref]$classAssets) ([ref]$itemAssets) ([ref]$slots)
        } else {
            $idx = [Array]::IndexOf($labels, $picked) - 1
            if ($idx -ge 0) { Loadout-Actions $idx ([ref]$classAssets) ([ref]$itemAssets) ([ref]$slots) }
        }
    }
}

function Create-CustomLoadout([ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    Clear-Host
    Write-At 2 1 'Create Custom Loadout' Cyan
    Write-At 2 2 'Esc to cancel.' DarkGray
    $name = $null
    while ($true) {
        Clear-Region 2 5 ([Console]::WindowWidth - 4) 1
        $name = Read-Line-TUI 2 3 'Loadout name: '
        if ($null -eq $name) { return }
        $name = $name.Trim()
        if ($name -eq '') { Show-Error 'Name cannot be empty.'; continue }
        if (@($script:customLoadouts | Where-Object { $_.Name -eq $name }).Count -gt 0) { Show-Error "Loadout '$name' already exists."; continue }
        break
    }
    $saveId = $null
    while ($true) {
        Clear-Region 2 5 ([Console]::WindowWidth - 4) 1
        $saveId = Read-Line-TUI 2 4 'Save ID (integer, default 0): ' '0'
        if ($null -eq $saveId) { return }
        $saveId = $saveId.Trim()
        if ($saveId -eq '') { $saveId = '0' }
        $tmp = 0
        if (-not [int]::TryParse($saveId, [ref]$tmp)) { Show-Error 'Save ID must be an integer.' 5; continue }
        break
    }
    $script:customLoadouts.Add(@{ Name = $name; SaveId = $saveId; Classes = [System.Collections.Generic.List[hashtable]]::new() })
    Save-CustomLoadouts
    $idx = $script:customLoadouts.Count - 1
    Show-Status "Created loadout '$name'."
    Loadout-Actions $idx $classAssets $itemAssets $slots
}

function Loadout-Actions($idx, [ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    while ($true) {
        $lo = $script:customLoadouts[$idx]
        $saveIdLabel = if ($null -eq $lo.SaveId -or $lo.SaveId -eq '') { '0' } else { $lo.SaveId }
        $c = Show-Menu $lo.Name @(
            "Manage classes ($($lo.Classes.Count))",
            "Save ID:  $saveIdLabel",
            'Rename',
            'Delete',
            '< Back'
        )
        switch ($c) {
            -1 { return }
            4  { return }
            0  { Loadout-Classes $idx $classAssets $itemAssets $slots }
            1  {
                Clear-Host
                Write-At 2 1 "Edit Save ID: $($lo.Name)" Cyan
                $newId = $null
                while ($true) {
                    Clear-Region 2 5 ([Console]::WindowWidth - 4) 1
                    $newId = Read-Line-TUI 2 3 'Save ID: ' $saveIdLabel
                    if ($null -eq $newId) { break }
                    $newId = $newId.Trim()
                    if ($newId -eq '') { $newId = '0' }
                    $tmp = 0
                    if (-not [int]::TryParse($newId, [ref]$tmp)) { Show-Error 'Save ID must be an integer.' 5; continue }
                    break
                }
                if ($null -ne $newId) { $script:customLoadouts[$idx].SaveId = $newId; Save-CustomLoadouts; Show-Status 'Save ID updated.' }
            }
            2  {
                Clear-Host
                Write-At 2 1 "Rename: $($lo.Name)" Cyan
                $newName = $null
                while ($true) {
                    Clear-Region 2 5 ([Console]::WindowWidth - 4) 1
                    $newName = Read-Line-TUI 2 3 'New name: ' $lo.Name
                    if ($null -eq $newName) { break }
                    $newName = $newName.Trim()
                    if ($newName -eq '') { $newName = $lo.Name; break }
                    if ($newName -ne $lo.Name -and (@($script:customLoadouts | Where-Object { $_.Name -eq $newName }).Count -gt 0)) {
                        Show-Error "Loadout '$newName' already exists."; continue
                    }
                    break
                }
                if ($null -ne $newName -and $newName -ne '') {
                    $script:customLoadouts[$idx].Name = $newName
                    Save-CustomLoadouts
                    Show-Status "Renamed to '$newName'."
                }
            }
            3  {
                $c2 = Show-Menu "Delete '$($lo.Name)'?" @('Yes, delete', '< Cancel')
                if ($c2 -eq 0) {
                    $script:customLoadouts.RemoveAt($idx)
                    Save-CustomLoadouts
                    Show-Status "Deleted '$($lo.Name)'." Yellow
                    return
                }
            }
        }
    }
}

function Loadout-Classes($idx, [ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    while ($true) {
        $lo          = $script:customLoadouts[$idx]
        $classLabels = @($lo.Classes | ForEach-Object { Format-LoadoutClassLabel $_ })
        $items       = @('+ Add class') + $classLabels + @('< Back')
        $c = Show-Menu "$($lo.Name) - Classes ($($lo.Classes.Count))" $items
        if ($c -lt 0 -or $c -eq ($items.Count - 1)) { return }
        if ($c -eq 0) {
            Create-LoadoutClass $idx $classAssets $itemAssets $slots
        } else {
            Class-Actions $idx ($c - 1) $classAssets $itemAssets $slots
        }
    }
}

function Create-LoadoutClass($loadoutIdx, [ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    if ($null -eq $classAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
    $newClass = Pick-Asset 'New class: Pick HolderInfo asset' $classAssets.Value
    if ($null -eq $newClass) { return }
    $newClassEntry = @{
        Class = $newClass
        Slots = [System.Collections.Generic.List[hashtable]]::new()
    }
    $script:customLoadouts[$loadoutIdx].Classes.Add($newClassEntry)
    Save-CustomLoadouts
    $newIdx = $script:customLoadouts[$loadoutIdx].Classes.Count - 1
    Show-Status 'Class added. Add slots to configure it.'
    Class-Actions $loadoutIdx $newIdx $classAssets $itemAssets $slots
}

function Class-Actions($loadoutIdx, $classIdx, [ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    while ($true) {
        $c_obj    = $script:customLoadouts[$loadoutIdx].Classes[$classIdx]
        $clsShort = ($c_obj.Class -split '/' | Select-Object -Last 1) -replace '\..+$'
        $c = Show-Menu $clsShort @(
            "Class:       $clsShort",
            "Slots ($($c_obj.Slots.Count)): Manage",
            'Delete class',
            '< Back'
        )
        switch ($c) {
            -1 { return }
            3  { return }
            0 {
                if ($null -eq $classAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
                $newClass = Pick-Asset 'Edit Class (HolderInfo asset)' $classAssets.Value
                if ($null -ne $newClass) { $script:customLoadouts[$loadoutIdx].Classes[$classIdx].Class = $newClass; Save-CustomLoadouts; Show-Status 'Class updated.' }
            }
            1 { Class-Slots $loadoutIdx $classIdx $classAssets $itemAssets $slots }
            2 {
                $c2 = Show-Menu "Delete class '$clsShort'?" @('Yes, delete', '< Cancel')
                if ($c2 -eq 0) {
                    $script:customLoadouts[$loadoutIdx].Classes.RemoveAt($classIdx)
                    Save-CustomLoadouts
                    Show-Status 'Class deleted.' Yellow
                    return
                }
            }
        }
    }
}

function Class-Slots($loadoutIdx, $classIdx, [ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    while ($true) {
        $c_obj      = $script:customLoadouts[$loadoutIdx].Classes[$classIdx]
        $clsShort   = ($c_obj.Class -split '/' | Select-Object -Last 1) -replace '\..+$'
        $slotLabels = @($c_obj.Slots | ForEach-Object { "$($_.Slot)  ($($_.Items.Count) items)" })
        $menuItems  = @('+ Add slot') + $slotLabels + @('< Back')
        $c = Show-Menu "$clsShort - Slots ($($c_obj.Slots.Count))" $menuItems
        if ($c -lt 0 -or $c -eq ($menuItems.Count - 1)) { return }
        if ($c -eq 0) { Create-ClassSlot $loadoutIdx $classIdx $classAssets $itemAssets $slots }
        else          { Slot-Actions $loadoutIdx $classIdx ($c - 1) $classAssets $itemAssets $slots }
    }
}

function Create-ClassSlot($loadoutIdx, $classIdx, [ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    if ($null -eq $classAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
    $c_obj      = $script:customLoadouts[$loadoutIdx].Classes[$classIdx]
    $newSlot    = $null
    $newHasNone = 'false'
    $newCat     = ''
    $step = 0   # 0=slot, 1=has_none, 2=category
    while ($step -le 2) {
        if ($step -eq 0) {
            $classObj   = @($classAssets.Value | Where-Object { $_.GamePath -eq $c_obj.Class })[0]
            $classSlots = if ($null -ne $classObj) { @(Scan-Slots @($classObj)) } else { @() }
            if ($classSlots.Count -eq 0) { $classSlots = @($slots.Value) }
            $si = Show-Menu 'Add Slot: Pick slot' $classSlots
            if ($si -lt 0) { return } else { $newSlot = $classSlots[$si]; $step++ }
        } elseif ($step -eq 1) {
            $hi = Show-Menu 'HAS_NONE  (allow empty slot selection)?' @('false', 'true')
            if ($hi -lt 0) { $step-- } else { $newHasNone = @('false', 'true')[$hi]; $step++ }
        } elseif ($step -eq 2) {
            $catOptions = @('Primary', 'Sidearm', 'Melee', 'Gadget')
            $catIdx = Show-Menu 'Add Slot: Category' $catOptions
            if ($catIdx -lt 0) { $step-- } else { $newCat = $catOptions[$catIdx]; $step++ }
        }
    }
    $newSlotEntry = @{ Slot = $newSlot; HasNone = $newHasNone; DefaultItem = ''; Category = $newCat; Items = [System.Collections.Generic.List[string]]::new() }
    $script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots.Add($newSlotEntry)
    Save-CustomLoadouts
    $newSlotIdx = $script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots.Count - 1
    Show-Status 'Slot added.'
    Slot-Actions $loadoutIdx $classIdx $newSlotIdx $classAssets $itemAssets $slots
}

function Slot-Actions($loadoutIdx, $classIdx, $slotIdx, [ref]$classAssets, [ref]$itemAssets, [ref]$slots) {
    while ($true) {
        $c_obj    = $script:customLoadouts[$loadoutIdx].Classes[$classIdx]
        $s_obj    = $c_obj.Slots[$slotIdx]
        $slotName = $s_obj.Slot
        $defShort = if ($s_obj.DefaultItem -ne '') { ($s_obj.DefaultItem -split '/' | Select-Object -Last 1) -replace '\..+$' } else { '(none)' }
        $c = Show-Menu $slotName @(
            "Slot:          $slotName",
            "HAS_NONE:      $($s_obj.HasNone)",
            "Default item:  $defShort",
            "Category:      $($s_obj.Category)",
            "Items ($($s_obj.Items.Count)): Manage",
            'Delete slot',
            '< Back'
        )
        switch ($c) {
            -1 { return }
            6  { return }
            0 {
                if ($null -eq $classAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
                $classObj   = @($classAssets.Value | Where-Object { $_.GamePath -eq $c_obj.Class })[0]
                $classSlots = if ($null -ne $classObj) { @(Scan-Slots @($classObj)) } else { @() }
                if ($classSlots.Count -eq 0) { $classSlots = @($slots.Value) }
                $newSlotI = Show-Menu 'Edit Slot' $classSlots
                if ($newSlotI -ge 0) { $script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots[$slotIdx].Slot = $classSlots[$newSlotI]; Save-CustomLoadouts; Show-Status 'Slot updated.' }
            }
            1 {
                $newVal = if ($s_obj.HasNone.ToLower() -eq 'true') { 'false' } else { 'true' }
                $script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots[$slotIdx].HasNone = $newVal
                Save-CustomLoadouts
            }
            2 {
                $curItems = @($script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots[$slotIdx].Items)
                if ($curItems.Count -eq 0) {
                    Show-Status 'No items in this slot yet. Add items first.' Yellow
                } else {
                    $itemLabels = @($curItems | ForEach-Object { ($_ -split '/' | Select-Object -Last 1) -replace '\..+$' })
                    $options    = @('(none)') + $itemLabels
                    $curDef     = $s_obj.DefaultItem
                    $curDefLbl  = if ($curDef -ne '') { ($curDef -split '/' | Select-Object -Last 1) -replace '\..+$' } else { '(none)' }
                    $initIdx    = [Array]::IndexOf($options, $curDefLbl); if ($initIdx -lt 0) { $initIdx = 0 }
                    $selIdx     = Show-Menu 'Set default item' $options '' $initIdx
                    if ($selIdx -ge 0) {
                        $script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots[$slotIdx].DefaultItem = if ($selIdx -eq 0) { '' } else { $curItems[$selIdx - 1] }
                        Save-CustomLoadouts
                        Show-Status 'Default item updated.'
                    }
                }
            }
            3 {
                $catOptions = @('Primary', 'Sidearm', 'Melee', 'Gadget')
                $initCat = [Array]::IndexOf($catOptions, $s_obj.Category); if ($initCat -lt 0) { $initCat = 0 }
                $catIdx = Show-Menu 'Edit Category' $catOptions '' $initCat
                if ($catIdx -ge 0) { $script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots[$slotIdx].Category = $catOptions[$catIdx]; Save-CustomLoadouts; Show-Status 'Category updated.' }
            }
            4 {
                if ($null -eq $itemAssets.Value) { $scan = Scan-AssetsWithStatus; $classAssets.Value = $scan.ClassAssets; $itemAssets.Value = $scan.ItemAssets; $slots.Value = $scan.Slots }
                $slotItems    = Get-ItemsForSlot $itemAssets.Value $slotName
                $curItems     = @($script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots[$slotIdx].Items)
                $classObj     = @($classAssets.Value | Where-Object { $_.GamePath -eq $c_obj.Class })[0]
                $defaultItems = if ($null -ne $classObj) { Get-HolderInfoDefaults $classObj.FilePath $slotItems $slotName } else { @() }
                $useItems     = $slotItems
                if ($defaultItems.Count -gt 0) {
                    $modeIdx = Show-Menu "Item source for slot '$slotName'" @(
                        "Class defaults ($($defaultItems.Count) items)",
                        "All items ($($slotItems.Count) items)",
                        '< Cancel'
                    )
                    if ($modeIdx -lt 0 -or $modeIdx -eq 2) { break }
                    if ($modeIdx -eq 0) {
                        $defPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($di in $defaultItems) { $defPathSet.Add($di.GamePath) | Out-Null }
                        $extras   = @($slotItems | Where-Object { -not $defPathSet.Contains($_.GamePath) -and $curItems -contains $_.GamePath })
                        $useItems = @($defaultItems) + $extras
                    }
                }
                $allLabels    = @($useItems | ForEach-Object { $_.Label })
                $allGamePaths = @($useItems | ForEach-Object { $_.GamePath })
                $preSelected  = @($curItems | ForEach-Object {
                    $gp = $_; $ii = [Array]::IndexOf($allGamePaths, $gp)
                    if ($ii -ge 0) { $allLabels[$ii] } else { $null }
                } | Where-Object { $null -ne $_ })
                $picked = Show-Picker "Items: $slotName  (Space=toggle, Enter=confirm)" $allLabels $true $allGamePaths 'fuzzy' $preSelected $false
                if ($null -ne $picked) {
                    $newPaths = [System.Collections.Generic.List[string]]::new()
                    foreach ($lbl in $picked) {
                        $ii = [Array]::IndexOf($allLabels, $lbl)
                        if ($ii -ge 0) { $newPaths.Add($allGamePaths[$ii]) }
                    }
                    $script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots[$slotIdx].Items = $newPaths
                    if ($s_obj.DefaultItem -ne '' -and -not $newPaths.Contains($s_obj.DefaultItem)) {
                        $script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots[$slotIdx].DefaultItem = ''
                    }
                    Save-CustomLoadouts
                    Show-Status "Items updated ($($newPaths.Count) items)."
                }
            }
            5 {
                $c2 = Show-Menu "Delete slot '$slotName'?" @('Yes, delete', '< Cancel')
                if ($c2 -eq 0) {
                    $script:customLoadouts[$loadoutIdx].Classes[$classIdx].Slots.RemoveAt($slotIdx)
                    Save-CustomLoadouts
                    Show-Status 'Slot deleted.' Yellow
                    return
                }
            }
        }
    }
}

Load-Data
Load-Overrides
Load-CustomLoadouts
Hide-Cursor

try {
    while ($true) {
        $c = Show-Menu 'Feathered Unicorns - Manager' @('Manage Users', 'Manage Groups', 'Manage Loadout Overrides', 'Manage Custom Loadouts', 'Manage Blacklist', 'Exit') `
            "Users: $($script:users.Count)   Groups: $($script:groups.Count)   Overrides: $($script:overrides.Count)   Loadouts: $($script:customLoadouts.Count)"
        switch ($c) {
            -1 { break }
            0  { Menu-Users }
            1  { Menu-Groups }
            2  { Menu-Overrides }
            3  { Menu-CustomLoadouts }
            4  { Menu-Blacklist }
            5  { Clear-Host; Show-Cursor; exit }
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
