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
