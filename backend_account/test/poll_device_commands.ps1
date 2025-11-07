# Simple PowerShell smoke test for device polling endpoint
param()

$baseUrl = 'http://localhost:4000'
$adminUser = 'admin'
$adminPass = 'adminpass'
$deviceId = $null

# Use a unique test username per run
$timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
$testUsername = "polltester_$timestamp"
$testPassword = 'userpass'

function Invoke-Api($method, $url, $body = $null, $token = $null, $headers = $null) {
    $hdrs = @{}
    if ($token) { $hdrs['Authorization'] = "Bearer $token" }
    if ($headers) { foreach ($k in $headers.Keys) { $hdrs[$k] = $headers[$k] } }
    try {
        if ($body -ne $null) {
            $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $hdrs -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 10)
            return @{ status = 200; body = $resp }
        }
        else {
            $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $hdrs
            return @{ status = 200; body = $resp }
        }
    }
    catch {
        $err = $_.Exception
        $status = $null
        $content = $null
        if ($err.Response) {
            $status = [int]$err.Response.StatusCode.value__
            try { $content = (New-Object System.IO.StreamReader($err.Response.GetResponseStream())).ReadToEnd() } catch { $content = $err.Message }
        }
        else {
            $status = 0
            $content = $err.Message
        }
        return @{ status = $status; body = $content }
    }
}

Write-Host "1) Admin login"
$login = Invoke-Api -method 'POST' -url "$baseUrl/api/accounts/login" -body @{ username = $adminUser; password = $adminPass }
Write-Host "Status:" $login.status
if ($login.status -ne 200) { Write-Host "Admin login failed"; exit 2 }
$adminToken = $login.body.token

Write-Host "2) Create and login test user"
$create = Invoke-Api -method 'POST' -url "$baseUrl/api/accounts" -body @{ username = $testUsername; password = $testPassword; role = 'user'; modules = @() } -token $adminToken
Write-Host "Create status:" $create.status
if ($create.status -ne 200 -and $create.status -ne 201) { Write-Host "Create user failed:" $create.body; exit 3 }
$testUserId = $create.body._id

$loginUser = Invoke-Api -method 'POST' -url "$baseUrl/api/accounts/login" -body @{ username = $testUsername; password = $testPassword }
if ($loginUser.status -ne 200) { Write-Host "Test user login failed"; exit 4 }
$userToken = $loginUser.body.token

Write-Host "2a) Register device (admin)"
$deviceId = "esp32_1_$timestamp"
$deviceSecret = [guid]::NewGuid().ToString()
$devCreate = Invoke-Api -method 'POST' -url "$baseUrl/api/devices" -body @{ deviceId = $deviceId; name = "Test Device"; secretKey = $deviceSecret } -token $adminToken
Write-Host "Device create status:" $devCreate.status
if ($devCreate.status -ne 200 -and $devCreate.status -ne 201) { Write-Host "Device registration failed:" $devCreate.body; exit 2 }
Write-Host "Device registered with secret (kept local for test)"

Write-Host "3) Grant control permission to test user"
$grant = Invoke-Api -method 'PATCH' -url "$baseUrl/api/accounts/$testUserId" -body @{ modules = @(@{ moduleId = $deviceId; canRead = $true; canControl = $true }) } -token $adminToken
Write-Host "Grant status:" $grant.status
if ($grant.status -ne 200) { Write-Host "Grant failed:" $grant.body; exit 5 }

Write-Host "4) Test user creates a control command"
$ctl = Invoke-Api -method 'POST' -url "$baseUrl/api/devices/$deviceId/control" -body @{ action = @{ type = 'ping'; value = 'now' } } -token $userToken
Write-Host "Control POST status:" $ctl.status
if ($ctl.status -ne 202 -and $ctl.status -ne 200) { Write-Host "Control creation failed:" $ctl.body; exit 6 }
$commandId = $ctl.body.commandId
Write-Host "Created commandId:" $commandId

# Helper: compute HMAC-SHA256 hex
function Compute-Hmac([string] $secret, [string] $data) {
    $key = [System.Text.Encoding]::UTF8.GetBytes($secret)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($data)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($key)
    $hash = $hmac.ComputeHash($bytes)
    return ($hash | ForEach-Object { $_.ToString("x2") }) -join ''
}

# Poll as device. We'll sign the requests with x-signature header (HMAC over parsed body stringified, e.g. '{}')
$headers = @{}
$signatureForGet = Compute-Hmac $deviceSecret "{}"
$headers['x-signature'] = $signatureForGet

Write-Host "5) Device polling for commands (first poll should return the command)"
$poll1 = Invoke-Api -method 'GET' -url "$baseUrl/api/devices/$deviceId/commands" -headers $headers
Write-Host "Poll1 status:" $poll1.status
Write-Host "Poll1 body:" ($poll1.body | ConvertTo-Json -Depth 5)

if ($poll1.status -ne 200) { Write-Host "Poll failed:" $poll1.body; exit 7 }
if (-not $poll1.body.commands -or $poll1.body.commands.Count -eq 0) { Write-Host "No commands returned on first poll; expected one"; exit 8 }

Write-Host "5b) Device acks the first returned command"
$firstCmd = $poll1.body.commands[0]
$ackBody = @{ status = 'done' }
$ackBodyStr = ($ackBody | ConvertTo-Json -Depth 5)
$sigAck = Compute-Hmac $deviceSecret $ackBodyStr
$ackHeaders = @{ 'x-signature' = $sigAck }
$ack = Invoke-Api -method 'POST' -url "$baseUrl/api/devices/$deviceId/commands/$($firstCmd.commandId)/ack" -body $ackBody -headers $ackHeaders
Write-Host "Ack status:" $ack.status
Write-Host "Ack body:" ($ack.body | ConvertTo-Json -Depth 5)
if ($ack.status -ne 200) { Write-Host "Ack failed:" $ack.body; exit 11 }

Write-Host "6) Device polling again (should be empty now)"
$poll2 = Invoke-Api -method 'GET' -url "$baseUrl/api/devices/$deviceId/commands" -headers $headers
Write-Host "Poll2 status:" $poll2.status
Write-Host "Poll2 body:" ($poll2.body | ConvertTo-Json -Depth 5)
if ($poll2.status -ne 200) { Write-Host "Second poll failed:" $poll2.body; exit 9 }
if ($poll2.body.commands.Count -ne 0) { Write-Host "Second poll returned commands unexpectedly"; exit 10 }

Write-Host "Device poll test finished successfully"
