# Get-NetUsers.ps1
# Script to list local/remote Windows users, group memberships, and active sessions.
# Supports both CLI output mode and interactive TUI mode (PS_UI_Blueprint).

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

# Load TUI Blueprint if running in interactive/TUI mode
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

function Show-ScrollableText {
    param(
        [string]$Title,
        [string]$Text
    )
    
    $lines = $Text -split "`r?`n"
    $scrollOffset = 0
    
    try {
        while ($true) {
            Lock-ViewportToWindow
            $width = Get-UiWidth
            $height = $Host.UI.RawUI.WindowSize.Height
            $maxVisibleLines = [Math]::Max(5, $height - 8)
            
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title $Title -Subtitle "Use Up/Down arrows/PageUp/PageDown to scroll. Esc to return." -Width $width
            
            $endIndex = [Math]::Min($scrollOffset + $maxVisibleLines - 1, $lines.Count - 1)
            for ($i = $scrollOffset; $i -le $endIndex; $i++) {
                $lineText = $lines[$i]
                if ($lineText.Length -gt $width) { $lineText = $lineText.Substring(0, $width) }
                Add-UiFrameLine -Frame $frame -Text "  $($_C.White)$lineText$($_C.Reset)$($_C.EraseLn)"
            }
            
            $printedCount = $endIndex - $scrollOffset + 1
            if ($printedCount -lt $maxVisibleLines) {
                for ($i = $printedCount; $i -lt $maxVisibleLines; $i++) {
                    Add-UiFrameLine -Frame $frame -Text "$($_C.EraseLn)"
                }
            }
            
            Add-UiFrameLine -Frame $frame
            $scrollInfo = "Line $($scrollOffset + 1) of $($lines.Count)"
            $segments = @(
                New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
                New-UiShortcutSegment -Text " Scroll ($scrollInfo)   " -Color $_C.Dim
                New-UiShortcutSegment -Text "Esc" -Color $_C.Fail
                New-UiShortcutSegment -Text " = back" -Color $_C.Dim
            )
            Add-UiFrameShortcutSegments -Frame $frame -Segments $segments -Width $width
            Write-UiFrame -Frame $frame
            
            $key = Read-ConsoleKey
            switch ($key.Key) {
                'UpArrow' { $scrollOffset = [Math]::Max(0, $scrollOffset - 1) }
                'DownArrow' { $scrollOffset = [Math]::Min([Math]::Max(0, $lines.Count - $maxVisibleLines), $scrollOffset + 1) }
                'PageUp' { $scrollOffset = [Math]::Max(0, $scrollOffset - $maxVisibleLines) }
                'PageDown' { $scrollOffset = [Math]::Min([Math]::Max(0, $lines.Count - $maxVisibleLines), $scrollOffset + $maxVisibleLines) }
                'Home' { $scrollOffset = 0 }
                'End' { $scrollOffset = [Math]::Max(0, $lines.Count - $maxVisibleLines) }
                'Escape' { break }
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
    
    $localUsers = Get-LocalUser | Select-Object Name, Enabled, Description | Out-String
    $adminMembers = try {
        Get-LocalGroupMember -Group "Administrators" | Select-Object Name, PrincipalSource, ObjectClass | Out-String
    } catch { "Error or no members found." }
    $rdpMembers = try {
        Get-LocalGroupMember -Group "Remote Desktop Users" | Select-Object Name, PrincipalSource, ObjectClass | Out-String
    } catch { "Error or no members found." }
    $activeSessions = try {
        quser 2>&1 | Out-String
    } catch { "No active sessions." }
    
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("=== Local User Accounts ===")
    $null = $sb.AppendLine($localUsers)
    $null = $sb.AppendLine("=== Administrators Group Members ===")
    $null = $sb.AppendLine($adminMembers)
    $null = $sb.AppendLine("=== Remote Desktop Users Group Members ===")
    $null = $sb.AppendLine($rdpMembers)
    $null = $sb.AppendLine("=== Active Sessions (quser) ===")
    $null = $sb.AppendLine($activeSessions)
    
    Initialize-TuiHost
    Show-ScrollableText -Title "Local User Info: $env:COMPUTERNAME" -Text ($sb.ToString())
}

function Run-RemoteUsersFlow {
    param(
        [string]$TargetComputer,
        [string]$TargetName
    )
    
    Restore-TuiHost
    Clear-Host
    Write-Host "Connecting to remote PC: $TargetName ($TargetComputer)" -ForegroundColor Cyan
    Write-Host "Checking/adding TrustedHosts config..." -ForegroundColor White
    Add-ToTrustedHosts -Target $TargetComputer
    
    Write-Host "`nPlease specify target PC credentials:" -ForegroundColor Yellow
    Write-Host "  Username [default: Administrator]: " -NoNewline -ForegroundColor White
    $inputUser = Read-Host
    $username = if ([string]::IsNullOrWhiteSpace($inputUser)) { "Administrator" } else { $inputUser }
    
    Write-Host "  Password (press Enter if blank): " -NoNewline -ForegroundColor White
    $passwordSecure = Read-Host -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential ($username, $passwordSecure)
    
    $sessionParams = @{ ComputerName = $TargetComputer; Credential = $cred }
    
    Write-Host "`nEstablishing WinRM session..." -ForegroundColor White
    $session = $null
    $textOutput = ""
    try {
        $session = New-PSSession @sessionParams -ErrorAction Stop
        Write-Host "Session established. Querying user accounts..." -ForegroundColor Green
        
        $scriptBlock = {
            $localUsers = Get-LocalUser | Select-Object Name, Enabled, Description | Out-String
            $adminMembers = try {
                Get-LocalGroupMember -Group "Administrators" | Select-Object Name, PrincipalSource, ObjectClass | Out-String
            } catch { "Error or no members found." }
            $rdpMembers = try {
                Get-LocalGroupMember -Group "Remote Desktop Users" | Select-Object Name, PrincipalSource, ObjectClass | Out-String
            } catch { "Error or no members found." }
            $activeSessions = try {
                quser 2>&1 | Out-String
            } catch { "No active sessions." }
            
            return [PSCustomObject]@{
                Users          = $localUsers
                Administrators = $adminMembers
                RdpUsers       = $rdpMembers
                Sessions       = $activeSessions
            }
        }
        
        $remoteData = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ErrorAction Stop
        
        $sb = [System.Text.StringBuilder]::new()
        $null = $sb.AppendLine("=== Remote User Accounts ===")
        $null = $sb.AppendLine($remoteData.Users)
        $null = $sb.AppendLine("=== Administrators Group Members ===")
        $null = $sb.AppendLine($remoteData.Administrators)
        $null = $sb.AppendLine("=== Remote Desktop Users Group Members ===")
        $null = $sb.AppendLine($remoteData.RdpUsers)
        $null = $sb.AppendLine("=== Active Sessions (quser) ===")
        $null = $sb.AppendLine($remoteData.Sessions)
        
        $textOutput = $sb.ToString()
        
    } catch {
        $textOutput = "❌ Connection failed or error retrieving data:`n`n$_"
    } finally {
        if ($null -ne $session) { Remove-PSSession $session }
    }
    
    Initialize-TuiHost
    Show-ScrollableText -Title "Remote User Info: $TargetName" -Text $textOutput
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
    $menuOptions = @(
        "Check Local PC Users"
        "Scan LAN for Manageable PCs (WinRM 5985) [Ctrl+L]"
        "Connect to Remote PC (IP/Hostname)..."
        "Exit"
    )
    $selectedIndex = 0
    
    try {
        while ($true) {
            Lock-ViewportToWindow
            $width = Get-UiWidth
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title "netuser TUI Control Panel" -Subtitle "Local & Remote User Check Utility" -Width $width
            Add-UiFrameSection -Frame $frame -Title "Main Menu" -Width $width
            
            for ($i = 0; $i -lt $menuOptions.Count; $i++) {
                if ($i -eq $selectedIndex) {
                    Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $($menuOptions[$i]) $($_C.Reset)$($_C.EraseLn)"
                } else {
                    Add-UiFrameLine -Frame $frame -Text "    $($_C.White)$($menuOptions[$i])$($_C.Reset)$($_C.EraseLn)"
                }
            }
            
            Add-UiFrameLine -Frame $frame
            
            # Draw shortcut segments manually
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
                'UpArrow' { $selectedIndex = [Math]::Max(0, $selectedIndex - 1) }
                'DownArrow' { $selectedIndex = [Math]::Min($menuOptions.Count - 1, $selectedIndex + 1) }
                'Escape' { return }
                'ResizeEvent' { continue }
                'Enter' {
                    switch ($selectedIndex) {
                        0 { Show-LocalUsersFlow }
                        1 { Invoke-LanScanFlow }
                        2 { Connect-RemotePcFlow }
                        3 { return }
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
        
        $activeSessions = try {
            $quserOut = quser 2>&1
            if ($quserOut -match "No User exists") {
                @()
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
                $sessions
            }
        } catch { @() }
        
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
            $localUsers = Get-LocalUser | Select-Object Name, Enabled, Description
            
            $adminMembers = try {
                Get-LocalGroupMember -Group "Administrators" | Select-Object Name, PrincipalSource, ObjectClass
            } catch { @() }
            
            $rdpMembers = try {
                Get-LocalGroupMember -Group "Remote Desktop Users" | Select-Object Name, PrincipalSource, ObjectClass
            } catch { @() }
            
            $activeSessions = try {
                $quserOut = quser 2>&1
                if ($quserOut -match "No User exists") {
                    @()
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
                    $sessions
                }
            } catch { @() }
            
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
