$pw = ConvertTo-SecureString "1234" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ("dcadmin", $pw)

$results = Invoke-Command -ComputerName "172.19.139.48" -Credential $cred -ScriptBlock {
    $out = [System.Collections.Generic.List[string]]::new()
    
    $keys = Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\S-1-5-21-3041881177-22939230-2542508564-1001" -Recurse -ErrorAction SilentlyContinue
    foreach ($k in $keys) {
        $out.Add("Key: $($k.Name)")
        $vals = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        foreach ($prop in $k.GetValueNames()) {
            $out.Add("  $prop = $($vals.$prop)")
        }
    }
    
    return $out
}

$results | Out-String | Write-Output
