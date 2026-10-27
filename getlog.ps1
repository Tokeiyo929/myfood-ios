$ErrorActionPreference = "Stop"
Set-Location "D:/GitHub/MyFood/myfood-ios"
$cred = git credential fill 2>$null | Out-String
$tok = ($cred -split "`n" | Where-Object { $_ -like "password=*" }) -replace "^password=", ""
# trim
$tok = $tok.Trim()
# Use curl.exe to follow redirects and save logs
curl.exe -sL -H "Authorization: Bearer $tok" -o joblog.txt "https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/jobs/121970285639/logs"
"size: $((Get-Item joblog.txt).Length)"
Get-Content joblog.txt | Select-Object -Last 50
