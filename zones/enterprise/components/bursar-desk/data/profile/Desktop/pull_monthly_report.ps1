# Monthly uupl-historian report, run on the 1st of each month
# Usage: .\pull_monthly_report.ps1 -Month 2024-04
param(
    [string]$Month = (Get-Date -Format "yyyy-MM")
)

$HistorianUrl = "http://10.10.2.10:8080"
$User         = "uupl-historian"
$Pass         = "Historian2015"

$Cred    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
$Headers = @{ Authorization = "Basic $Cred" }
$Uri     = "$HistorianUrl/report?asset=turbine_main&from=$Month-01&to=$Month-28"
$OutFile = "$HOME\reports\turbine_$Month.csv"

New-Item -ItemType Directory -Force -Path "$HOME\reports" | Out-Null
Invoke-WebRequest -Uri $Uri -Headers $Headers -OutFile $OutFile
Write-Host "Done. Report saved to $OutFile"
