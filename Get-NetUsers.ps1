# Get-NetUsers.ps1
# Script to list local/remote Windows users, group memberships, and active sessions.
# Follows the RDCcheck UI/UX guidelines and auto-configures TrustedHosts.

param(
    [Parameter(Mandatory = $false, HelpMessage = "Enter the target ComputerName or IP Address (e.g. 192.168.1.47)")]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential
)

$isRemote = -not [string]::IsNullOrEmpty($ComputerName) -and 
            ($ComputerName -ne "localhost") -and 
            ($ComputerName -ne "127.0.0.1") -and 
            ($ComputerName -ne $env:COMPUTERNAME)

# Helper function to ensure local WinRM service is running
function Ensure-LocalWinRM {
    try {
        $winrmService = Get-Service -Name "WinRM" -ErrorAction Stop
        if ($winrmService.Status -ne 'Running') {
            Write-Host "Starting local WinRM service..." -ForegroundColor Gray
            # Try to start it. If access denied, elevate via gsudo
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

# Principal header
if ($isRemote) {
    Write-Host "Initializing Remote Users check for target: $ComputerName" -ForegroundColor Cyan
    Add-ToTrustedHosts -Target $ComputerName
} else {
    Write-Host "Initializing Local Users check for target: $env:COMPUTERNAME" -ForegroundColor Cyan
}

# Remote branch
if ($isRemote) {
    # 1. Resolve Credentials and Prepare Session Parameters
    if ($null -eq $Credential) {
        Write-Host "No credentials provided. Attempting connection with current user..." -ForegroundColor Gray
        try {
            $testSession = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
            Remove-PSSession $testSession
            Write-Host "  ✅ Connected successfully using current credentials." -ForegroundColor Green
        } catch {
            Write-Host "Current user connection failed. Please specify target PC credentials:" -ForegroundColor Yellow
            
            # Prompt for Username
            Write-Host "  Username [default: Administrator]: " -NoNewline -ForegroundColor White
            $inputUser = Read-Host
            $username = if ([string]::IsNullOrWhiteSpace($inputUser)) { "Administrator" } else { $inputUser }
            
            # Prompt for Password
            Write-Host "  Password (press Enter if blank): " -NoNewline -ForegroundColor White
            $passwordSecure = Read-Host -AsSecureString
            
            $Credential = New-Object System.Management.Automation.PSCredential ($username, $passwordSecure)
        }
    }
    
    $sessionParams = @{ ComputerName = $ComputerName }
    if ($null -ne $Credential) { $sessionParams["Credential"] = $Credential }
    
    # 2. Test Connection
    Write-Host "`nVerifying WinRM connectivity to target PC..." -ForegroundColor White
    try {
        $session = New-PSSession @sessionParams -ErrorAction Stop
        Write-Host "  ✅ Successfully established WinRM session." -ForegroundColor Green
    } catch {
        Write-Error "❌ Failed to connect to target machine via WinRM. Please verify:"
        Write-Host "  - Target PC is online and reachable."
        Write-Host "  - WinRM is enabled on target PC."
        Write-Host "  - You are using valid Administrator credentials."
        Write-Host "`nError Details: $_" -ForegroundColor Red
        Exit
    }
    
    # 3. Retrieve Info
    Write-Host "`nQuerying user accounts, group memberships, and active sessions..." -ForegroundColor White
    
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
                # Parse quser output
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
    
    try {
        $remoteData = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ErrorAction Stop
        
        # Display Users
        Write-Host "`n=== Local User Accounts ===" -ForegroundColor Cyan
        $remoteData.Users | Format-Table -AutoSize
        
        # Display Groups
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
        
        # Display Active Sessions
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
    
} else {
    # Local branch
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
}

Write-Host "`nUser check completed!" -ForegroundColor Green
