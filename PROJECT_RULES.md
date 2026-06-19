# Project Rules - netuser

## Overview
Durable rules, guidelines, and decision logs for the netuser query and verification scripts.

## PowerShell & Registry Guardrails
- **TrustedHosts Automation**: To connect to target PCs by raw IP over WinRM, the script verifies and configures `TrustedHosts`. Because modifying TrustedHosts requires Admin privileges, the script attempts local modification and falls back to invoking `gsudo` for elevation when needed.
- **Active Session Parsing**: Windows `quser` command outputs tabular data which is translated into structured PowerShell custom objects for easier post-processing and cleaner display.

---

## Decision Log

### Entry - 2026-06-19 (Project Creation & User Check Script)
- **Date**: 2026-06-19
- **Problem**: Need to query local and remote PC user accounts, group memberships, and active sessions in a standardized manner.
- **Root cause**: Standard RDP and administration troubleshooting sessions require checking which local accounts exist, which ones have access (Administrators / Remote Desktop Users), and who is currently logged in.
- **Guardrail/rule**: Provide a dedicated `Get-NetUsers.ps1` script supporting local queries by default and WinRM queries optionally, with built-in automated configuration for WSMan TrustedHosts.
- **Files affected**:
  - [Get-NetUsers.ps1](file:///d:/Users/joty79/scripts/netuser/Get-NetUsers.ps1)
  - [PROJECT_RULES.md](file:///d:/Users/joty79/scripts/netuser/PROJECT_RULES.md)
  - [README.md](file:///d:/Users/joty79/scripts/netuser/README.md)
  - [CHANGELOG.md](file:///d:/Users/joty79/scripts/netuser/CHANGELOG.md)
- **Validation/tests run**: Syntax validation and execution checks.

### Entry - 2026-06-19 (TUI Polish, Connection History, and Data Export)
- **Date**: 2026-06-19
- **Problem**: User interface improvements needed for scrollable text viewer (Esc key responsiveness, line wrap safety) and a need to save connection history and support exporting user reports to Markdown/CSV.
- **Root cause**: Standard nested `break` in PowerShell does not break parent loops inside `switch` statements. High density table strings cause terminal wrapping which breaks the cursor positioning of the TUI.
- **Guardrail/rule**:
  - **Loop Break Control**: Avoid bare `break` inside nested control flows; use explicit flag variables to control parent loops.
  - **Width-safety Truncation**: Perform hard line length limit calculations (e.g. `$width - 4`) on plain strings *before* injecting ANSI colors to prevent color code fragmentations.
  - **Connection History & Exports**: Persist successful remote connection hosts to `history.json` and map them to selectables in the main TUI menu. Provide `Export-UserData` to output MD and CSV files in `exports/` folder.
- **Files affected**:
  - [Get-NetUsers.ps1](file:///d:/Users/joty79/scripts/netuser/Get-NetUsers.ps1)
  - [PROJECT_RULES.md](file:///d:/Users/joty79/scripts/netuser/PROJECT_RULES.md)
  - [CHANGELOG.md](file:///d:/Users/joty79/scripts/netuser/CHANGELOG.md)
- **Validation/tests run**: Local manual run, syntax check, and mock connection tests.

### Entry - 2026-06-19 (Network-Scoped History Isolation & Display Name + IP)
- **Date**: 2026-06-19
- **Problem**: Connection history entries can clash or point to invalid addresses when moving between different physical or logical networks. Additionally, only displaying raw IPs in connection history is confusing.
- **Root cause**: Dynamic IP networks (like DHCP scopes) reuse the same IP ranges, so connection history must be isolated to prevent connection attempts to incorrect computers.
- **Guardrail/rule**:
  - **Network Isolation**: Capture `NetworkId` (ProfileName + GatewayMac + Subnet) using `Get-CurrentNetworkIdentity` and filter connection history display dynamically based on the current active connection.
  - **Combined Name and IP**: Save resolved hostnames and IP addresses during remote WinRM connections, and display them in history as `HostName (IP) - user: userName`.
  - **History Schema Migration**: Auto-migrate legacy history records to include default properties dynamically when loaded.
- **Files affected**:
  - [Get-NetUsers.ps1](file:///d:/Users/joty79/scripts/netuser/Get-NetUsers.ps1)
  - [PROJECT_RULES.md](file:///d:/Users/joty79/scripts/netuser/PROJECT_RULES.md)
  - [CHANGELOG.md](file:///d:/Users/joty79/scripts/netuser/CHANGELOG.md)
- **Validation/tests run**: Verified network filtering with active gateway identities and mock history structures.

### Entry - 2026-06-19 (TUI Escape Sequence Typo Correction)
- **Date**: 2026-06-19
- **Problem**: The string `_C.Reset)` was appearing literally at the left border of every scrollable line.
- **Root cause**: A double dollar `$$` was typed before `_C.Reset` inside the double-quoted string. In PowerShell, `$$` escapes to a literal `$` rather than evaluating the variable expression.
- **Guardrail/rule**: Always review variable evaluation syntax in double-quoted strings, especially for boundary escapes.
- **Files affected**:
  - [Get-NetUsers.ps1](file:///d:/Users/joty79/scripts/netuser/Get-NetUsers.ps1)
  - [PROJECT_RULES.md](file:///d:/Users/joty79/scripts/netuser/PROJECT_RULES.md)
  - [CHANGELOG.md](file:///d:/Users/joty79/scripts/netuser/CHANGELOG.md)
- **Validation/tests run**: Verified syntax and visually checked console frame boundaries.
