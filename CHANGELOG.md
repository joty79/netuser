# Changelog

Όλες οι σημαντικές αλλαγές σε αυτό το project θα καταγράφονται σε αυτό το αρχείο.

Η μορφή βασίζεται στο [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.1.0] - 2026-06-19

### Added
- Προσθήκη πλήρους διαδραστικού TUI (Alternate Screen Buffer) χρησιμοποιώντας το `PS_UI_Blueprint.psm1`.
- Προσθήκη παράλληλης σάρωσης δικτύου (Network Discovery) στη θύρα 5985 (WinRM) πατώντας `Ctrl+L` ή μέσω του TUI μενού.
- Υλοποίηση προβολής αποτελεσμάτων σε scrollable text viewer με υποστήριξη πλοήγησης (Up/Down/PageUp/PageDown/Home/End).
- Υποστήριξη αυτόματης εναλλαγής μεταξύ TUI (όταν εκτελείται χωρίς ορίσματα) και CLI (όταν εκτελείται με ορίσματα).

## [1.0.0] - 2026-06-19

### Added
- Δημιουργία του project `netuser`.
- Ανάπτυξη του `Get-NetUsers.ps1` για έλεγχο χρηστών, Administrators, Remote Desktop Users και ενεργών συνεδριών.
- Υποστήριξη τοπικών και απομακρυσμένων queries μέσω WinRM.
- Αυτόματη ρύθμιση του `TrustedHosts` με χρήση `gsudo` για elevation όταν χρειάζεται.
- Δημιουργία `PROJECT_RULES.md` για τη διατήρηση της μνήμης του project.
- Δημιουργία `README.md` για την τεκμηρίωση του project.
