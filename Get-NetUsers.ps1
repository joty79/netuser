# Get-NetUsers.ps1
# Script to list local/remote Windows users, group memberships, and active sessions.
# Supports both CLI output mode and interactive TUI mode (PS_UI_Blueprint).
# Version 1.3.0 - Connection history filtered per network, displaying HostName + IP.

param(
    [Parameter(Mandatory = $false, HelpMessage = "Enter the target ComputerName or IP Address (e.g. 192.168.1.47)")]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$Interactive
)

$isRemote = -not [string]::IsNullOrEmpty($ComputerName) -and 
            ($ComputerName -ne "localhost") -and 
            ($ComputerName -ne "127.0.0.1") -and 
            ($ComputerName -ne $env:COMPUTERNAME)

$runTui = $Interactive -or ($null -eq $PSBoundParameters["ComputerName"] -and $null -eq $PSBoundParameters["Credential"])

if ($runTui) {
    $blueprintPath = "C:\Users\joty79\.agent-shared\templates\PS_UI_Blueprint.psm1"
    if (Test-Path -LiteralPath $blueprintPath) {
        Invoke-Expression (Get-Content -Raw -LiteralPath $blueprintPath)
    } else {
        Write-Warning "Could not find TUI Blueprint at: $blueprintPath"
        Write-Warning "Falling back to standard CLI mode..."
        $runTui = $false
    }
}

# Paths
$historyPath = "d:\Users\joty79\scripts\netuser\history.json"

# Network Identity Check
function Get-CurrentNetworkIdentity {
    $profileName = "Unknown Network"
    $gatewayMac = "00-00-00-00-00-00"
    $subnetId = "0.0.0.0"

    try {
        $profile = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object IPv4Connectivity -eq 'Internet' | Select-Object -First 1
        if ($null -eq $profile) {
            $profile = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($null -ne $profile) {
            $profileName = $profile.Name
        }
    } catch {}

    try {
        $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        if ($routes) {
            $gatewayIp = $routes[0].NextHop
            $neighbor = Get-NetNeighbor -IPAddress $gatewayIp -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($neighbor -and $neighbor.LinkLayerAddress) {
                $gatewayMac = $neighbor.LinkLayerAddress.ToUpper()
            }
        }
    } catch {}

    try {
        $ipInfo = $null
        if ($null -ne $profile) {
            $ipInfo = Get-NetIPAddress -InterfaceIndex $profile.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($null -eq $ipInfo) {
            $ipInfo = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet' } |
                Select-Object -First 1
        }
        if ($ipInfo -and $ipInfo.IPAddress -match '^(\d+\.\d+\.\d+)\.\d+$') {
            $subnetId = $Matches[1]
        }
    } catch {}

    $networkId = "$profileName|$gatewayMac|$subnetId"
    return [PSCustomObject]@{
        NetworkId   = $networkId
        ProfileName = $profileName
        GatewayMac  = $gatewayMac
        SubnetId    = $subnetId
    }
}

# Connection History Management
function Get-ConnectionHistory {
    if (Test-Path -LiteralPath $historyPath) {
        try {
            $content = Get-Content -LiteralPath $historyPath -Raw -ErrorAction Stop
            $history = ConvertFrom-Json $content
            $list = [System.Collections.Generic.List[object]]::new()
            if ($history) {
                foreach ($h in @($history)) {
                    $comp = if ($h.ComputerName) { $h.ComputerName } else { "Unknown" }
                    $ip = if ($h.IPAddress) { $h.IPAddress } else { $comp }
                    $user = if ($h.UserName) { $h.UserName } else { "Administrator" }
                    $netId = if ($h.NetworkId) { $h.NetworkId } else { "" }
                    $time = if ($h.LastConnected) { $h.LastConnected } else { "" }
                    
                    $list.Add([PSCustomObject]@{
                        ComputerName  = $comp
                        IPAddress     = $ip
                        UserName      = $user
                        NetworkId     = $netId
                        LastConnected = $time
                    })
                }
            }
            return @($list)
        } catch {
            return @()
        }
    }
    return @()
}

function Add-ConnectionHistoryEntry {
    param(
        [string]$ComputerName,
        [string]$IPAddress,
        [string]$UserName
    )
    
    $netId = (Get-CurrentNetworkIdentity).NetworkId
    $history = Get-ConnectionHistory
    
    # Remove existing entry for this specific IP on this network
    $history = $history | Where-Object { 
        -not ($_.IPAddress -eq $IPAddress -and $_.NetworkId -eq $netId)
    }
    
    $newEntry = [PSCustomObject]@{
        ComputerName  = $ComputerName
        IPAddress     = $IPAddress
        UserName      = $UserName
        NetworkId     = $netId
        LastConnected = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    
    $updatedHistory = @($newEntry) + $history
    if ($updatedHistory.Count -gt 15) {
        $updatedHistory = $updatedHistory[0..14]
    }
    
    try {
        $updatedHistory | ConvertTo-Json | Set-Content -LiteralPath $historyPath -Encoding UTF8
    } catch {}
}

# CSV/Markdown Data Export
function Export-UserData {
    param(
        [string]$Target,
        $userData
    )
    
    $exportsDir = "d:\Users\joty79\scripts\netuser\exports"
    if (-not (Test-Path -LiteralPath $exportsDir)) {
        $null = New-Item -ItemType Directory -Path $exportsDir -Force
    }
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    
    # 1. Export to Markdown
    $mdFile = Join-Path -Path $exportsDir -ChildPath "report_${Target}_$timestamp.md"
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("# User Accounts Report for $Target")
    $null = $sb.AppendLine("Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $null = $sb.AppendLine()
    
    $null = $sb.AppendLine("## User Accounts")
    $null = $sb.AppendLine("| Name | Enabled | Description |")
    $null = $sb.AppendLine("|---|---|---|")
    foreach ($u in $userData.Users) {
        $null = $sb.AppendLine("| $($u.Name) | $($u.Enabled) | $($u.Description) |")
    }
    $null = $sb.AppendLine()
    
    $null = $sb.AppendLine("## Administrators Group Members")
    $null = $sb.AppendLine("| Name | Source | Class |")
    $null = $sb.AppendLine("|---|---|---|")
    foreach ($m in $userData.Administrators) {
        $null = $sb.AppendLine("| $($m.Name) | $($m.PrincipalSource) | $($m.ObjectClass) |")
    }
    $null = $sb.AppendLine()
    
    $null = $sb.AppendLine("## Remote Desktop Users Group Members")
    $null = $sb.AppendLine("| Name | Source | Class |")
    $null = $sb.AppendLine("|---|---|---|")
    foreach ($m in $userData.RdpUsers) {
        $null = $sb.AppendLine("| $($m.Name) | $($m.PrincipalSource) | $($m.ObjectClass) |")
    }
    $null = $sb.AppendLine()
    
    $null = $sb.AppendLine("## Active Sessions (quser)")
    $null = $sb.AppendLine("| Username | Session Name | ID | State | Idle Time | Logon Time |")
    $null = $sb.AppendLine("|---|---|---|---|---|---|")
    foreach ($s in $userData.Sessions) {
        $null = $sb.AppendLine("| $($s.Username) | $($s.SessionName) | $($s.Id) | $($s.State) | $($s.IdleTime) | $($s.LogonTime) |")
    }
    
    $sb.ToString() | Set-Content -LiteralPath $mdFile -Encoding UTF8
    
    # 2. Export to CSVs
    $csvUsers = Join-Path -Path $exportsDir -ChildPath "users_${Target}_$timestamp.csv"
    $userData.Users | Export-Csv -Path $csvUsers -NoTypeInformation -Encoding UTF8
    
    $csvAdmins = Join-Path -Path $exportsDir -ChildPath "admins_${Target}_$timestamp.csv"
    $userData.Administrators | Export-Csv -Path $csvAdmins -NoTypeInformation -Encoding UTF8
    
    $csvRdp = Join-Path -Path $exportsDir -ChildPath "rdpusers_${Target}_$timestamp.csv"
    if ($userData.RdpUsers.Count -gt 0) {
        $userData.RdpUsers | Export-Csv -Path $csvRdp -NoTypeInformation -Encoding UTF8
    }
    
    $csvSessions = Join-Path -Path $exportsDir -ChildPath "sessions_${Target}_$timestamp.csv"
    if ($userData.Sessions.Count -gt 0) {
        $userData.Sessions | Export-Csv -Path $csvSessions -NoTypeInformation -Encoding UTF8
    }
    
    return [PSCustomObject]@{
        MarkdownPath = $mdFile
        CsvUsersPath = $csvUsers
    }
}

# Helper function to ensure local WinRM service is running
function Ensure-LocalWinRM {
    try {
        $winrmService = Get-Service -Name "WinRM" -ErrorAction Stop
        if ($winrmService.Status -ne 'Running') {
            Write-Host "Starting local WinRM service..." -ForegroundColor Gray
            try {
                Start-Service -Name "WinRM" -ErrorAction Stop
            } catch {
                Write-Host "  🔒 Local elevation required to start WinRM. Executing via gsudo..." -ForegroundColor Cyan
                & gsudo.exe pwsh -NoProfile -Command "Start-Service -Name 'WinRM'"
            }
        }
    } catch {
        Write-Warning "Could not access or start WinRM service locally: $_"
    }
}

# Helper function to auto-configure TrustedHosts for remote targets
function Add-ToTrustedHosts {
    param([string]$Target)
    
    Ensure-LocalWinRM
    
    try {
        $hostsItem = Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop
        $currentHosts = $hostsItem.Value
        
        # Check if already trusted
        if ($currentHosts -eq "*" -or $currentHosts.Split(",") -contains $Target) {
            Write-Host "  ✅ Target '$Target' is already in TrustedHosts." -ForegroundColor Green
            return
        }
        
        Write-Host "  ⚠️ Target '$Target' is not in TrustedHosts. Adding..." -ForegroundColor Yellow
        $newHosts = if ([string]::IsNullOrEmpty($currentHosts)) { $Target } else { "$currentHosts,$Target" }
        
        try {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newHosts -Force -ErrorAction Stop
            Write-Host "  ✅ Successfully added '$Target' to TrustedHosts." -ForegroundColor Green
        } catch {
            Write-Host "  🔒 Local elevation required to modify TrustedHosts. Executing via gsudo..." -ForegroundColor Cyan
            $encodedCmd = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$newHosts' -Force"))
            & gsudo.exe pwsh -NoProfile -EncodedCommand $encodedCmd
            
            # Verify update
            $verifyHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
            if ($verifyHosts.Split(",") -contains $Target -or $verifyHosts -eq "*") {
                Write-Host "  ✅ Successfully added '$Target' to TrustedHosts via gsudo." -ForegroundColor Green
            } else {
                throw "Verification failed. Target still not in TrustedHosts."
            }
        }
    } catch {
        Write-Warning "❌ Failed to update TrustedHosts: $_"
    }
}

# Fast network discovery using ConnectAsync (port 5985)
function Get-NetDiscoveredHosts {
    $discovered = [System.Collections.Generic.List[object]]::new()
    
    $interfaces = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet' }
        
    if (-not $interfaces) { return $discovered }
    
    $neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.State -ne 'Unreachable' -and $_.IPAddress -notmatch '^\d+\.\d+\.\d+\.255$' -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' }
        
    $gateways = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    if ($routes) {
        foreach ($r in $routes) {
            if (-not [string]::IsNullOrWhiteSpace($r.NextHop)) { $null = $gateways.Add($r.NextHop) }
        }
    }
    
    $localIPs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($if in $interfaces) { $null = $localIPs.Add($if.IPAddress) }
    
    $targetIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($neighbors) {
        foreach ($n in $neighbors) { $null = $targetIPsSet.Add($n.IPAddress) }
    }
    
    $targetIPs = @(
        $targetIPsSet | Where-Object { -not $gateways.Contains($_) -and -not $localIPs.Contains($_) }
    )
    
    if (-not $targetIPs) { return $discovered }
    
    $connections = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($ip in $targetIPs) {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $ipObj = [System.Net.IPAddress]::Parse($ip)
            $task = $tcp.ConnectAsync($ipObj, 5985)
            $connections.Add([PSCustomObject]@{
                IP        = $ip
                TcpClient = $tcp
                Task      = $task
            })
        } catch {
            $tcp.Dispose()
        }
    }
    
    # Wait up to 500ms
    $swTimeout = [System.Diagnostics.Stopwatch]::StartNew()
    while ($swTimeout.ElapsedMilliseconds -lt 500) {
        $allDone = $true
        foreach ($c in $connections) {
            if (-not $c.Task.IsCompleted) {
                $allDone = $false
                break
            }
        }
        if ($allDone) { break }
        Start-Sleep -Milliseconds 20
    }
    $swTimeout.Stop()
    
    $winrmOpenIPs = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $connections) {
        if ($c.Task.IsCompleted -and $c.TcpClient.Connected) {
            $winrmOpenIPs.Add($c.IP)
        }
        $c.TcpClient.Dispose()
    }
    
    # Resolve names asynchronously for online hosts
    $resolutionTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($ip in $winrmOpenIPs) {
        try {
            $dnsTask = [System.Net.Dns]::GetHostEntryAsync($ip)
            $resolutionTasks.Add([PSCustomObject]@{ IP = $ip; Task = $dnsTask })
        } catch {}
    }
    
    if ($resolutionTasks.Count -gt 0) {
        $resTasksArray = [System.Threading.Tasks.Task[]]::new($resolutionTasks.Count)
        for ($i = 0; $i -lt $resolutionTasks.Count; $i++) { $resTasksArray[$i] = $resolutionTasks[$i].Task }
        try { [System.Threading.Tasks.Task]::WaitAll($resTasksArray, 400) } catch {}
    }
    
    foreach ($rt in $resolutionTasks) {
        $hostName = $rt.IP
        if ($rt.Task.IsCompleted -and -not $rt.Task.IsFaulted -and $rt.Task.Result.HostName) {
            $hostName = $rt.Task.Result.HostName
            if ($hostName -match '^([^.]+)\.') { $hostName = $Matches[1] }
        }
        $discovered.Add([PSCustomObject]@{ IP = $rt.IP; HostName = $hostName })
    }
    
    return $discovered
}

# TUI Flow Functions
function Clear-TuiScreen {
    [Console]::Write((Get-TuiForceClearSequence))
}

function Get-ActiveSessionsList {
    try {
        $quserOut = quser 2>&1
        if ($quserOut -match "No User exists") {
            return @()
        } else {
            $lines = $quserOut -split "`r?`n" | Where-Object { [string]::IsNullOrWhiteSpace($_) -eq $false }
            $sessions = for ($i = 1; $i -lt $lines.Count; $i++) {
                $line = $lines[$i].Trim()
                $parts = $line -split '\s{2,}'
                if ($parts.Count -ge 4) {
                    [PSCustomObject]@{
                        Username    = $parts[0].Replace(">","").Trim()
                        SessionName = if ($parts.Count -eq 6) { $parts[1] } else { "" }
                        Id          = if ($parts.Count -eq 6) { $parts[2] } else { $parts[1] }
                        State       = if ($parts.Count -eq 6) { $parts[3] } else { $parts[2] }
                        IdleTime    = if ($parts.Count -eq 6) { $parts[4] } else { $parts[3] }
                        LogonTime   = if ($parts.Count -eq 6) { $parts[5] } else { $parts[4] }
                    }
                }
            }
            return @($sessions)
        }
    } catch {
        return @()
    }
}

# Structured rendering to avoid ANSI truncation artifacts and stretch bugs
function Get-FormattedLines {
    param($userData)
    $lines = [System.Collections.Generic.List[string]]::new()
    
    # 1. User Accounts
    $lines.Add("=== User Accounts ===")
    $lines.Add( [string]::Format("{0,-20} {1,-10} {2}", "Name", "Enabled", "Description") )
    $lines.Add( "-" * 70 )
    foreach ($u in $userData.Users) {
        $lines.Add( [string]::Format("{0,-20} {1,-10} {2}", $u.Name, $u.Enabled, $u.Description) )
    }
    
    $lines.Add("")
    # 2. Administrators Group
    $lines.Add("=== Administrators Group Members ===")
    $lines.Add( [string]::Format("{0,-30} {1,-15} {2}", "Name", "Source", "Class") )
    $lines.Add( "-" * 70 )
    foreach ($m in $userData.Administrators) {
        $lines.Add( [string]::Format("{0,-30} {1,-15} {2}", $m.Name, $m.PrincipalSource, $m.ObjectClass) )
    }
    
    $lines.Add("")
    # 3. Remote Desktop Users Group
    $lines.Add("=== Remote Desktop Users Group Members ===")
    if ($userData.RdpUsers.Count -eq 0) {
        $lines.Add("  (No members found)")
    } else {
        $lines.Add( [string]::Format("{0,-30} {1,-15} {2}", "Name", "Source", "Class") )
        $lines.Add( "-" * 70 )
        foreach ($m in $userData.RdpUsers) {
            $lines.Add( [string]::Format("{0,-30} {1,-15} {2}", $m.Name, $m.PrincipalSource, $m.ObjectClass) )
        }
    }
    
    $lines.Add("")
    # 4. Active Sessions (quser)
    $lines.Add("=== Active Sessions (quser) ===")
    if ($userData.Sessions.Count -eq 0) {
        $lines.Add("  (No active sessions)")
    } else {
        $lines.Add( [string]::Format("{0,-15} {1,-15} {2,-5} {3,-10} {4,-10} {5}", "Username", "SessionName", "ID", "State", "IdleTime", "LogonTime") )
        $lines.Add( "-" * 75 )
        foreach ($s in $userData.Sessions) {
            $lines.Add( [string]::Format("{0,-15} {1,-15} {2,-5} {3,-10} {4,-10} {5}", $s.Username, $s.SessionName, $s.Id, $s.State, $s.IdleTime, $s.LogonTime) )
        }
    }
    
    return $lines
}

function Show-ScrollableText {
    param(
        [string]$Title,
        $userData
    )
    
    $scrollOffset = 0
    $exitScroll = $false
    
    try {
        while (-not $exitScroll) {
            Lock-ViewportToWindow
            $width = Get-UiWidth
            $height = $Host.UI.RawUI.WindowSize.Height
            $maxVisibleLines = [Math]::Max(5, $height - 11)
            
            $rawLines = Get-FormattedLines -userData $userData
            
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title $Title -Subtitle "Up/Down/PgUp/PgDn to scroll. E to export. Esc to return." -Width $width
            
            # Draw beautiful border around the content area
            $innerWidth = $width - 4
            $borderH = (Get-UiGlyph -Name BoxH) * $innerWidth
            Add-UiFrameLine -Frame $frame -Text "$($_C.H2)$(Get-UiGlyph -Name BoxTopLeft)$borderH$(Get-UiGlyph -Name BoxTopRight)$($_C.Reset)$($_C.EraseLn)"
            
            $endIndex = [Math]::Min($scrollOffset + $maxVisibleLines - 1, $rawLines.Count - 1)
            for ($i = $scrollOffset; $i -le $endIndex; $i++) {
                $lineText = $rawLines[$i].Replace("`t", "    ")
                
                # Truncate to inner width to prevent terminal stretching/wrapping
                if ($lineText.Length -gt $innerWidth) {
                    $lineText = $lineText.Substring(0, $innerWidth)
                }
                
                $padWidth = [Math]::Max(0, $innerWidth - $lineText.Length)
                $paddedText = $lineText + (' ' * $padWidth)
                
                # Colorize headers & highlights safely after truncation
                $coloredText = $paddedText
                if ($paddedText -match '^===') {
                    $coloredText = "$($_C.Info)$($_C.Bold)$paddedText$($_C.Reset)"
                } elseif ($paddedText -match '^---') {
                    $coloredText = "$($_C.Dim)$paddedText$($_C.Reset)"
                } else {
                    $coloredText = $coloredText -replace '\bTrue\b', "$($_C.OK)True$($_C.Reset)"
                    $coloredText = $coloredText -replace '\bFalse\b', "$($_C.Fail)False$($_C.Reset)"
                }
                
                Add-UiFrameLine -Frame $frame -Text "$($_C.H2)$(Get-UiGlyph -Name BoxV)$($_C.Reset) $coloredText $($_C.H2)$(Get-UiGlyph -Name BoxV)$($_C.Reset)$($_C.EraseLn)"
            }
            
            # Pad empty vertical space
            $printedCount = $endIndex - $scrollOffset + 1
            if ($printedCount -lt $maxVisibleLines) {
                for ($i = $printedCount; $i -lt $maxVisibleLines; $i++) {
                    $emptyPad = ' ' * $innerWidth
                    Add-UiFrameLine -Frame $frame -Text "$($_C.H2)$(Get-UiGlyph -Name BoxV)$($_C.Reset) $emptyPad $($_C.H2)$(Get-UiGlyph -Name BoxV)$($_C.Reset)$($_C.EraseLn)"
                }
            }
            
            Add-UiFrameLine -Frame $frame -Text "$($_C.H2)$(Get-UiGlyph -Name BoxBottomLeft)$borderH$(Get-UiGlyph -Name BoxBottomRight)$($_C.Reset)$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame
            
            $scrollInfo = "Line $($scrollOffset + 1) of $($rawLines.Count)"
            $segments = @(
                New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
                New-UiShortcutSegment -Text " Scroll ($scrollInfo)   " -Color $_C.Dim
                New-UiShortcutSegment -Text "E" -Color $_C.Gold
                New-UiShortcutSegment -Text " = export   " -Color $_C.Dim
                New-UiShortcutSegment -Text "Esc" -Color $_C.Fail
                New-UiShortcutSegment -Text " = back" -Color $_C.Dim
            )
            Add-UiFrameShortcutSegments -Frame $frame -Segments $segments -Width $width
            Write-UiFrame -Frame $frame
            
            $key = Read-ConsoleKey
            switch ($key.Key) {
                'UpArrow' { $scrollOffset = [Math]::Max(0, $scrollOffset - 1) }
                'DownArrow' { $scrollOffset = [Math]::Min([Math]::Max(0, $rawLines.Count - $maxVisibleLines), $scrollOffset + 1) }
                'PageUp' { $scrollOffset = [Math]::Max(0, $scrollOffset - $maxVisibleLines) }
                'PageDown' { $scrollOffset = [Math]::Min([Math]::Max(0, $rawLines.Count - $maxVisibleLines), $scrollOffset + $maxVisibleLines) }
                'Home' { $scrollOffset = 0 }
                'End' { $scrollOffset = [Math]::Max(0, $rawLines.Count - $maxVisibleLines) }
                'Escape' { $exitScroll = $true }
                'E' {
                    $targetName = if ($isRemote) { $ComputerName } else { $env:COMPUTERNAME }
                    $exportRes = Export-UserData -Target $targetName -userData $userData
                    
                    Clear-TuiScreen
                    $bannerFrame = New-UiFrame
                    Add-UiFrameBanner -Frame $bannerFrame -Title "Export Complete" -Subtitle "Saved to exports folder" -Width $width
                    Add-UiFrameLine -Frame $bannerFrame
                    Add-UiFrameLine -Frame $bannerFrame -Text "  ✅ Exported Markdown: $($exportRes.MarkdownPath)$($_C.EraseLn)"
                    Add-UiFrameLine -Frame $bannerFrame -Text "  ✅ Exported CSV Files: $($exportRes.CsvUsersPath)$($_C.EraseLn)"
                    Add-UiFrameLine -Frame $bannerFrame
                    Add-UiFrameLine -Frame $bannerFrame -Text "  Press any key to return..."
                    Write-UiFrame -Frame $bannerFrame
                    $null = Read-ConsoleKey
                    $script:RequestForceClear = $true
                }
                'ResizeEvent' { continue }
            }
        }
    } finally {
        $script:RequestForceClear = $true
    }
}

function Show-LocalUsersFlow {
    Restore-TuiHost
    Clear-Host
    Write-Host "Querying local user information..." -ForegroundColor Cyan
    
    $localUsers = Get-LocalUser | Select-Object Name, Enabled, Description
    $adminMembers = try {
        Get-LocalGroupMember -Group "Administrators" | Select-Object Name, PrincipalSource, ObjectClass
    } catch { @() }
    $rdpMembers = try {
        Get-LocalGroupMember -Group "Remote Desktop Users" | Select-Object Name, PrincipalSource, ObjectClass
    } catch { @() }
    $activeSessions = Get-ActiveSessionsList
    
    $userData = [PSCustomObject]@{
        Users          = $localUsers
        Administrators = $adminMembers
        RdpUsers       = $rdpMembers
        Sessions       = $activeSessions
    }
    
    Initialize-TuiHost
    Show-ScrollableText -Title "Local User Info: $env:COMPUTERNAME" -userData $userData
}

function Run-RemoteUsersFlow {
    param(
        [string]$TargetComputer,
        [string]$TargetName,
        [string]$DefaultUser = "Administrator"
    )
    
    Restore-TuiHost
    Clear-Host
    Write-Host "Connecting to remote PC: $TargetName ($TargetComputer)" -ForegroundColor Cyan
    Write-Host "Checking/adding TrustedHosts config..." -ForegroundColor White
    Add-ToTrustedHosts -Target $TargetComputer
    
    Write-Host "`nPlease specify target PC credentials:" -ForegroundColor Yellow
    Write-Host "  Username [default: $DefaultUser]: " -NoNewline -ForegroundColor White
    $inputUser = Read-Host
    $username = if ([string]::IsNullOrWhiteSpace($inputUser)) { $DefaultUser } else { $inputUser }
    
    Write-Host "  Password (press Enter if blank): " -NoNewline -ForegroundColor White
    $passwordSecure = Read-Host -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential ($username, $passwordSecure)
    
    $sessionParams = @{ ComputerName = $TargetComputer; Credential = $cred }
    
    Write-Host "`nEstablishing WinRM session..." -ForegroundColor White
    $session = $null
    $userData = $null
    $connectionError = $null
    try {
        $session = New-PSSession @sessionParams -ErrorAction Stop
        Write-Host "Session established. Querying user accounts..." -ForegroundColor Green
        
        $scriptBlock = {
            function Get-RemoteActiveSessions {
                try {
                    $quserOut = quser 2>&1
                    if ($quserOut -match "No User exists") {
                        return @()
                    } else {
                        $lines = $quserOut -split "`r?`n" | Where-Object { [string]::IsNullOrWhiteSpace($_) -eq $false }
                        $sessions = for ($i = 1; $i -lt $lines.Count; $i++) {
                            $line = $lines[$i].Trim()
                            $parts = $line -split '\s{2,}'
                            if ($parts.Count -ge 4) {
                                [PSCustomObject]@{
                                    Username    = $parts[0].Replace(">","").Trim()
                                    SessionName = if ($parts.Count -eq 6) { $parts[1] } else { "" }
                                    Id          = if ($parts.Count -eq 6) { $parts[2] } else { $parts[1] }
                                    State       = if ($parts.Count -eq 6) { $parts[3] } else { $parts[2] }
                                    IdleTime    = if ($parts.Count -eq 6) { $parts[4] } else { $parts[3] }
                                    LogonTime   = if ($parts.Count -eq 6) { $parts[5] } else { $parts[4] }
                                }
                            }
                        }
                        return @($sessions)
                    }
                } catch {
                    return @()
                }
            }
            
            $localUsers = Get-LocalUser | Select-Object Name, Enabled, Description
            $adminMembers = try {
                Get-LocalGroupMember -Group "Administrators" | Select-Object Name, PrincipalSource, ObjectClass
            } catch { @() }
            $rdpMembers = try {
                Get-LocalGroupMember -Group "Remote Desktop Users" | Select-Object Name, PrincipalSource, ObjectClass
            } catch { @() }
            $activeSessions = Get-RemoteActiveSessions
            
            return [PSCustomObject]@{
                Users          = $localUsers
                Administrators = $adminMembers
                RdpUsers       = $rdpMembers
                Sessions       = $activeSessions
            }
        }
        
        $userData = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ErrorAction Stop
        
        # Save connection to history on success, including name and IP Address
        Add-ConnectionHistoryEntry -ComputerName $TargetName -IPAddress $TargetComputer -UserName $username
        
    } catch {
        $connectionError = $_.Exception.Message
    } finally {
        if ($null -ne $session) { Remove-PSSession $session }
    }
    
    Initialize-TuiHost
    if ($null -ne $connectionError) {
        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title "Connection Error" -Subtitle "Could not query target: $TargetName" -Width (Get-UiWidth)
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  ❌ WinRM Connection failed:$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame -Text "  $connectionError$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  Press any key to return..."
        Write-UiFrame -Frame $frame
        $null = Read-ConsoleKey
    } else {
        Show-ScrollableText -Title "Remote User Info: $TargetName" -userData $userData
    }
}

function Invoke-LanScanFlow {
    Clear-TuiScreen
    $frame = New-UiFrame
    Add-UiFrameBanner -Frame $frame -Title 'Connecting to LAN' -Subtitle 'Scanning local network...' -Width (Get-UiWidth)
    Add-UiFrameLine -Frame $frame
    Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Scanning local network for active PCs (testing WinRM 5985)...$($_C.Reset)$($_C.EraseLn)"
    Write-UiFrame -Frame $frame
    
    $discoveredHosts = @(Get-NetDiscoveredHosts)
    
    if ($discoveredHosts.Count -eq 0) {
        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title 'Network Scan Results' -Subtitle 'No hosts found' -Width (Get-UiWidth)
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Warn)No active PCs with WinRM (port 5985) open were found on your local network.$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  Press any key to return to main menu..."
        Write-UiFrame -Frame $frame
        $null = Read-ConsoleKey
        return
    }
    
    $hostOptions = foreach ($d in $discoveredHosts) {
        "$($d.HostName) ($($d.IP))"
    }
    
    $selectedHostString = Invoke-ArrowMenu -Items $hostOptions -Title "Discovered PCs (Select to query users)"
    if ($null -eq $selectedHostString) { return }
    
    $selectedIndex = [Array]::IndexOf($hostOptions, $selectedHostString)
    $selectedHost = $discoveredHosts[$selectedIndex]
    
    Run-RemoteUsersFlow -TargetComputer $selectedHost.IP -TargetName $selectedHost.HostName
}

function Connect-RemotePcFlow {
    Restore-TuiHost
    Clear-Host
    Write-Host "Connect to Remote PC" -ForegroundColor Cyan
    Write-Host "Enter Target IP address or Hostname: " -NoNewline -ForegroundColor White
    $target = Read-Host
    if ([string]::IsNullOrWhiteSpace($target)) {
        Initialize-TuiHost
        return
    }
    
    Run-RemoteUsersFlow -TargetComputer $target -TargetName $target
}

function Invoke-NetUsersTui {
    Initialize-TuiHost
    $selectedIndex = 0
    
    try {
        while ($true) {
            Lock-ViewportToWindow
            $width = Get-UiWidth
            
            # Load active network identity
            $networkInfo = Get-CurrentNetworkIdentity
            $currentNetworkId = $networkInfo.NetworkId
            $networkName = $networkInfo.ProfileName
            
            # Filter connection history for current network
            $allHistory = Get-ConnectionHistory
            $history = @($allHistory | Where-Object { $_.NetworkId -eq $currentNetworkId })
            
            # Rebuild menu items and actions list dynamically
            $menuOptions = [System.Collections.Generic.List[string]]::new()
            $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
            
            $menuOptions.Add("Check Local PC Users")
            $actions.Add([PSCustomObject]@{ Type = 'Local'; Label = "Check Local PC Users" })
            
            $menuOptions.Add("Scan LAN for Manageable PCs (WinRM 5985) [Ctrl+L]")
            $actions.Add([PSCustomObject]@{ Type = 'Scan'; Label = "Scan LAN for Manageable PCs (WinRM 5985) [Ctrl+L]" })
            
            $menuOptions.Add("Connect to Remote PC (IP/Hostname)...")
            $actions.Add([PSCustomObject]@{ Type = 'ConnectNew'; Label = "Connect to Remote PC (IP/Hostname)..." })
            
            if ($history.Count -gt 0) {
                $menuOptions.Add("--- Connection History ---")
                $actions.Add([PSCustomObject]@{ Type = 'Header'; Label = "--- Connection History ---" })
                
                foreach ($h in $history) {
                    $displayName = if ($h.ComputerName.ToLower() -eq $h.IPAddress.ToLower() -or [string]::IsNullOrEmpty($h.ComputerName)) {
                        "  $($h.IPAddress) (user: $($h.UserName))"
                    } else {
                        "  $($h.ComputerName) ($($h.IPAddress)) (user: $($h.UserName))"
                    }
                    $menuOptions.Add($displayName)
                    $actions.Add([PSCustomObject]@{ Type = 'HistoryEntry'; Data = $h; Label = $displayName })
                }
            }
            
            $menuOptions.Add("Exit")
            $actions.Add([PSCustomObject]@{ Type = 'Exit'; Label = "Exit" })
            
            # Guard bounds
            if ($selectedIndex -ge $menuOptions.Count) {
                $selectedIndex = $menuOptions.Count - 1
            }
            
            # Ensure not pointing on a non-selectable Header option
            if ($actions[$selectedIndex].Type -eq 'Header') {
                $selectedIndex++
            }
            
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title "netuser TUI Control Panel" -Subtitle "Local & Remote User Check Utility | Active Network: $networkName" -Width $width
            Add-UiFrameSection -Frame $frame -Title "Main Menu" -Width $width
            
            for ($i = 0; $i -lt $menuOptions.Count; $i++) {
                if ($i -eq $selectedIndex) {
                    Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $($menuOptions[$i]) $($_C.Reset)$($_C.EraseLn)"
                } else {
                    if ($actions[$i].Type -eq 'Header') {
                        Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)$($menuOptions[$i])$($_C.Reset)$($_C.EraseLn)"
                    } else {
                        Add-UiFrameLine -Frame $frame -Text "    $($_C.White)$($menuOptions[$i])$($_C.Reset)$($_C.EraseLn)"
                    }
                }
            }
            
            Add-UiFrameLine -Frame $frame
            
            $segments = @(
                New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
                New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
                New-UiShortcutSegment -Text ' = select   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Ctrl+L' -Color $_C.Gold
                New-UiShortcutSegment -Text ' = scan network   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
                New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
            )
            Add-UiFrameShortcutSegments -Frame $frame -Segments $segments -Width $width
            Write-UiFrame -Frame $frame
            
            $key = Read-ConsoleKey
            
            # Ctrl+L key interception
            if ($key.KeyChar -eq [char]12 -or ($key.Key -eq 'L' -and $key.VirtualKeyCode -eq 76)) {
                Invoke-LanScanFlow
                $script:RequestForceClear = $true
                continue
            }
            
            switch ($key.Key) {
                'UpArrow' {
                    $selectedIndex = [Math]::Max(0, $selectedIndex - 1)
                    if ($actions[$selectedIndex].Type -eq 'Header') {
                        $selectedIndex = [Math]::Max(0, $selectedIndex - 1)
                    }
                }
                'DownArrow' {
                    $selectedIndex = [Math]::Min($menuOptions.Count - 1, $selectedIndex + 1)
                    if ($actions[$selectedIndex].Type -eq 'Header') {
                        $selectedIndex = [Math]::Min($menuOptions.Count - 1, $selectedIndex + 1)
                    }
                }
                'Escape' { return }
                'ResizeEvent' { continue }
                'Enter' {
                    $action = $actions[$selectedIndex]
                    switch ($action.Type) {
                        'Local' { Show-LocalUsersFlow }
                        'Scan' { Invoke-LanScanFlow }
                        'ConnectNew' { Connect-RemotePcFlow }
                        'HistoryEntry' {
                            Run-RemoteUsersFlow -TargetComputer $action.Data.IPAddress -TargetName $action.Data.ComputerName -DefaultUser $action.Data.UserName
                        }
                        'Exit' { return }
                    }
                    $script:RequestForceClear = $true
                }
            }
        }
    } finally {
        Restore-TuiHost
    }
}

# CLI Mode Functions
function Show-LocalUsersCli {
    Write-Host "Initializing Local Users check for target: $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "`nQuerying local user accounts, group memberships, and active sessions..." -ForegroundColor White
    
    try {
        $localUsers = Get-LocalUser | Select-Object Name, Enabled, Description
        Write-Host "`n=== Local User Accounts ===" -ForegroundColor Cyan
        $localUsers | Format-Table -AutoSize
        
        $adminMembers = try {
            Get-LocalGroupMember -Group "Administrators" | Select-Object Name, PrincipalSource, ObjectClass
        } catch { @() }
        Write-Host "`n=== Administrators Group Members ===" -ForegroundColor Cyan
        if ($adminMembers.Count -gt 0) {
            $adminMembers | Format-Table -AutoSize
        } else {
            Write-Host "No members found or error querying group." -ForegroundColor Yellow
        }
        
        $rdpMembers = try {
            Get-LocalGroupMember -Group "Remote Desktop Users" | Select-Object Name, PrincipalSource, ObjectClass
        } catch { @() }
        Write-Host "`n=== Remote Desktop Users Group Members ===" -ForegroundColor Cyan
        if ($rdpMembers.Count -gt 0) {
            $rdpMembers | Format-Table -AutoSize
        } else {
            Write-Host "No members found or error querying group." -ForegroundColor Yellow
        }
        
        $activeSessions = Get-ActiveSessionsList
        Write-Host "`n=== Active Sessions (quser) ===" -ForegroundColor Cyan
        if ($activeSessions.Count -gt 0) {
            $activeSessions | Format-Table -AutoSize
        } else {
            Write-Host "No active sessions found." -ForegroundColor Yellow
        }
    } catch {
        Write-Error "❌ Error retrieving local data: $_"
    }
    
    Write-Host "`nUser check completed!" -ForegroundColor Green
}

function Show-RemoteUsersCli {
    Write-Host "Initializing Remote Users check for target: $ComputerName" -ForegroundColor Cyan
    Add-ToTrustedHosts -Target $ComputerName
    
    if ($null -eq $Credential) {
        Write-Host "No credentials provided. Attempting connection with current user..." -ForegroundColor Gray
        try {
            $testSession = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
            Remove-PSSession $testSession
            Write-Host "  ✅ Connected successfully using current credentials." -ForegroundColor Green
        } catch {
            Write-Host "Current user connection failed. Please specify target PC credentials:" -ForegroundColor Yellow
            Write-Host "  Username [default: Administrator]: " -NoNewline -ForegroundColor White
            $inputUser = Read-Host
            $username = if ([string]::IsNullOrWhiteSpace($inputUser)) { "Administrator" } else { $inputUser }
            
            Write-Host "  Password (press Enter if blank): " -NoNewline -ForegroundColor White
            $passwordSecure = Read-Host -AsSecureString
            $Credential = New-Object System.Management.Automation.PSCredential ($username, $passwordSecure)
        }
    }
    
    $sessionParams = @{ ComputerName = $ComputerName }
    if ($null -ne $Credential) { $sessionParams["Credential"] = $Credential }
    
    Write-Host "`nVerifying WinRM connectivity to target PC..." -ForegroundColor White
    try {
        $session = New-PSSession @sessionParams -ErrorAction Stop
        Write-Host "  ✅ Successfully established WinRM session." -ForegroundColor Green
    } catch {
        Write-Error "❌ Failed to connect to target machine via WinRM. Please verify settings."
        Write-Host "`nError Details: $_" -ForegroundColor Red
        Exit
    }
    
    Write-Host "`nQuerying user accounts, group memberships, and active sessions..." -ForegroundColor White
    try {
        $scriptBlock = {
            function Get-RemoteActiveSessions {
                try {
                    $quserOut = quser 2>&1
                    if ($quserOut -match "No User exists") {
                        return @()
                    } else {
                        $lines = $quserOut -split "`r?`n" | Where-Object { [string]::IsNullOrWhiteSpace($_) -eq $false }
                        $sessions = for ($i = 1; $i -lt $lines.Count; $i++) {
                            $line = $lines[$i].Trim()
                            $parts = $line -split '\s{2,}'
                            if ($parts.Count -ge 4) {
                                [PSCustomObject]@{
                                    Username    = $parts[0].Replace(">","").Trim()
                                    SessionName = if ($parts.Count -eq 6) { $parts[1] } else { "" }
                                    Id          = if ($parts.Count -eq 6) { $parts[2] } else { $parts[1] }
                                    State       = if ($parts.Count -eq 6) { $parts[3] } else { $parts[2] }
                                    IdleTime    = if ($parts.Count -eq 6) { $parts[4] } else { $parts[3] }
                                    LogonTime   = if ($parts.Count -eq 6) { $parts[5] } else { $parts[4] }
                                }
                            }
                        }
                        return @($sessions)
                    }
                } catch {
                    return @()
                }
            }
            
            $localUsers = Get-LocalUser | Select-Object Name, Enabled, Description
            
            $adminMembers = try {
                Get-LocalGroupMember -Group "Administrators" | Select-Object Name, PrincipalSource, ObjectClass
            } catch { @() }
            
            $rdpMembers = try {
                Get-LocalGroupMember -Group "Remote Desktop Users" | Select-Object Name, PrincipalSource, ObjectClass
            } catch { @() }
            
            $activeSessions = Get-RemoteActiveSessions
            
            return [PSCustomObject]@{
                Users          = $localUsers
                Administrators = $adminMembers
                RdpUsers       = $rdpMembers
                Sessions       = $activeSessions
            }
        }
        
        $remoteData = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ErrorAction Stop
        
        Write-Host "`n=== Local User Accounts ===" -ForegroundColor Cyan
        $remoteData.Users | Format-Table -AutoSize
        
        Write-Host "`n=== Administrators Group Members ===" -ForegroundColor Cyan
        if ($remoteData.Administrators.Count -gt 0) {
            $remoteData.Administrators | Format-Table -AutoSize
        } else {
            Write-Host "No members found or error querying group." -ForegroundColor Yellow
        }
        
        Write-Host "`n=== Remote Desktop Users Group Members ===" -ForegroundColor Cyan
        if ($remoteData.RdpUsers.Count -gt 0) {
            $remoteData.RdpUsers | Format-Table -AutoSize
        } else {
            Write-Host "No members found or error querying group." -ForegroundColor Yellow
        }
        
        Write-Host "`n=== Active Sessions (quser) ===" -ForegroundColor Cyan
        if ($remoteData.Sessions.Count -gt 0) {
            $remoteData.Sessions | Format-Table -AutoSize
        } else {
            Write-Host "No active sessions found." -ForegroundColor Yellow
        }
    } catch {
        Write-Error "❌ Error retrieving remote data: $_"
    } finally {
        Remove-PSSession $session
    }
    
    Write-Host "`nUser check completed!" -ForegroundColor Green
}

# Main Execution Switch
if ($runTui) {
    Invoke-NetUsersTui
} else {
    if ($isRemote) {
        Show-RemoteUsersCli
    } else {
        Show-LocalUsersCli
    }
}
