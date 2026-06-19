# README — netuser

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows-0078D6?style=for-the-badge&logo=windows&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Language-PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="Language">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
</p>

<h1 align="center">👤 netuser</h1>

<p align="center">
  <b>Έλεγχος χρηστών, ομάδων και ενεργών συνεδριών σε τοπικούς ή απομακρυσμένους υπολογιστές.</b><br>
  <sub>Query user details & active sessions -> Diagnostic visibility</sub>
</p>

---

## ✨ What's Inside

| # | Tool | Description |
|:-:|------|-------------|
| 👤 | **[Get-NetUsers](#get-netusers)** | Έλεγχος χρηστών, Administrators, Remote Desktop Users, και ενεργών συνεδριών (quser). |

---

## 👤 Get-NetUsers

> Εργαλείο ελέγχου χρηστών και ενεργών συνεδριών (quser) σε τοπικούς ή απομακρυσμένους υπολογιστές μέσω WinRM.

### The Problem
- Δυσκολία γρήγορου ελέγχου των χρηστών που είναι συνδεδεμένοι σε έναν απομακρυσμένο υπολογιστή.
- Ανάγκη επιβεβαίωσης της συμμετοχής χρηστών στις ομάδες `Administrators` και `Remote Desktop Users` κατά το troubleshooting του RDP.
- Προβλήματα με το WinRM TrustedHosts όταν επιχειρείται σύνδεση μέσω IP διευθύνσεων χωρίς πρότερη ρύθμιση.

### The Solution

Το script πραγματοποιεί queries τοπικά ή απομακρυσμένα, ενώ αυτόματα προσθέτει την IP/hostname στο TrustedHosts (κάνοντας elevate μέσω `gsudo` αν απαιτείται) για απρόσκοπτη σύνδεση.

```
[Local PC] ---> (Έλεγχος TrustedHosts / Αυτόματη Προσθήκη) ---> [WinRM Connection] ---> [Target PC]
                                                                                            |
                                                                                    +---> Get-LocalUser
                                                                                    +---> Administrators Group
                                                                                    +---> Remote Desktop Users
                                                                                    +---> quser (Active Sessions)
```

### Usage

**Από τερματικό:**
```powershell
# Έλεγχος τοπικού υπολογιστή (εξ ορισμού)
.\Get-NetUsers.ps1

# Έλεγχος απομακρυσμένου υπολογιστή μέσω IP/Name
.\Get-NetUsers.ps1 -ComputerName 192.168.1.47

# Έλεγχος απομακρυσμένου υπολογιστή με συγκεκριμένα credentials
.\Get-NetUsers.ps1 -ComputerName 192.168.1.47 -Credential (Get-Credential)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ComputerName` | `string` | `$null` (Local) | Η IP διεύθυνση ή το όνομα του απομακρυσμένου υπολογιστή. |
| `-Credential` | `PSCredential` | `$null` | Διαπιστευτήρια σύνδεσης για τον απομακρυσμένο υπολογιστή. |

---

## 📦 Installation

### Quick Setup
```powershell
# Clone the repository
git clone https://github.com/joty79/netuser.git
cd netuser

# Run
.\Get-NetUsers.ps1
```

### Requirements
| Requirement | Details |
|-------------|---------|
| **OS** | Windows 10 / 11 / Server |
| **Runtime** | PowerShell 5.1 / PowerShell 7+ |
| **Dependencies** | `gsudo` (για αυτόματη προσθήκη στο TrustedHosts αν εκτελείται ως non-admin) |

---

## 📁 Project Structure

```
netuser/
├── Get-NetUsers.ps1      # Το κύριο PowerShell script
├── PROJECT_RULES.md     # Κανόνες και ιστορικό αποφάσεων του project
├── CHANGELOG.md         # Ιστορικό αλλαγών
└── README.md            # Αυτό το αρχείο τεκμηρίωσης
```

---

## 🧠 Technical Notes

<details>
<summary><b>Πώς λειτουργεί η αυτόματη ρύθμιση του TrustedHosts;</b></summary>

Το script διαβάζει την τρέχουσα τιμή του `WSMan:\localhost\Client\TrustedHosts`. Αν η target IP/Name δεν περιλαμβάνεται, την προσθέτει. Αν ο τρέχων χρήστης δεν έχει δικαιώματα διαχειριστή, το script καλεί το **gsudo** για να εκτελέσει την αλλαγή με elevation.

</details>

<details>
<summary><b>Πώς γίνεται το parsing του quser;</b></summary>

Το **quser** επιστρέφει text-based πίνακα. Το script διαχωρίζει τις γραμμές με regex/whitespace splitting και δημιουργεί **PSCustomObjects** για να είναι δυνατή η περαιτέρω επεξεργασία (π.χ. φιλτράρισμα ή εξαγωγή σε CSV).

</details>

---

<p align="center">
  <sub>Built with PowerShell · Local & Remote Queries · Windows WinRM</sub>
</p>
