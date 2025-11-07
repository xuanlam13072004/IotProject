<#
Simple PowerShell runner for the smoke tests against backend_account
Usage: run this from the backend_account folder, with the server running and MongoDB connected.
#>

param()

$baseUrl = 'http://localhost:4000'
$adminUser = 'admin'
$adminPass = 'adminpass'
$deviceId = 'esp32_1'

# Use a unique test username per run to avoid conflicts with previous runs
$timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
$testUsername = "testuser_$timestamp"

function Invoke-Api($method, $url, $body = $null, $token = $null) {
    $headers = @{}
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    try {
        if ($body -ne $null) {
            $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 10)
            return @{ status = 200; body = $resp }
        }
        else {
            $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers
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

Write-Host "Ensure the server is running and .env has ADMIN_USERNAME/ADMIN_PASSWORD (to bootstrap admin)"

Write-Host "\n1) Login as admin"
$login = Invoke-Api -method 'POST' -url "$baseUrl/api/accounts/login" -body @{ username = $adminUser; password = $adminPass }
Write-Host "Status:" $login.status
Write-Host "Body:" ($login.body | ConvertTo-Json -Depth 5)
if ($login.status -ne 200) { Write-Host "Cannot continue without admin token"; exit 2 }
$adminToken = $login.body.token

Write-Host "\n2) Create test user (admin)"
$testPassword = 'userpass'
$create = Invoke-Api -method 'POST' -url "$baseUrl/api/accounts" -body @{ username = $testUsername; password = $testPassword; role = 'user'; modules = @() } -token $adminToken
Write-Host "Status:" $create.status
if ($create.body) { $createBodyStr = $create.body | ConvertTo-Json -Depth 5 } else { $createBodyStr = $create.body }
Write-Host "Body:" $createBodyStr
if ($create.status -eq 200 -or $create.status -eq 201) {
    # Use the server-returned id when creation succeeded
    $testUserId = $create.body._id
}
else {
    Write-Host "Create may have failed; attempting to find test user ID by username..."
    $list = Invoke-Api -method 'GET' -url "$baseUrl/api/accounts" -token $adminToken
    if ($list.status -ne 200) {
        Write-Host "Failed to list accounts to find test user (status $($list.status)); aborting"
        exit 5
    }
    $found = $list.body | Where-Object { $_.username -eq $testUsername }
    if (-not $found) {
        Write-Host "Could not find account with username $testUsername; aborting"
        exit 6
    }
    $testUserId = $found._id
}

Write-Host "\n3) Login as testuser"
$loginUser = Invoke-Api -method 'POST' -url "$baseUrl/api/accounts/login" -body @{ username = $testUsername; password = $testPassword }
Write-Host "Status:" $loginUser.status
Write-Host "Body:" ($loginUser.body | ConvertTo-Json -Depth 5)
if ($loginUser.status -ne 200) { Write-Host "Test user login failed; aborting"; exit 3 }
$userToken = $loginUser.body.token

Write-Host "\n4) Attempt control without permission (expect 403)"
$ctl1 = Invoke-Api -method 'POST' -url "$baseUrl/api/devices/$deviceId/control" -body @{ action = @{ type = 'toggle'; value = 'on' } } -token $userToken
Write-Host "Status:" $ctl1.status
if ($ctl1.body -is [string]) { $ctl1BodyStr = $ctl1.body } else { $ctl1BodyStr = $ctl1.body | ConvertTo-Json -Depth 5 }
Write-Host "Body:" $ctl1BodyStr

Write-Host "\n5) Grant control permission to testuser (admin)"
if (-not $testUserId) { Write-Host "No test user id found, aborting"; exit 4 }
$grant = Invoke-Api -method 'PATCH' -url "$baseUrl/api/accounts/$testUserId" -body @{ modules = @(@{ moduleId = $deviceId; canRead = $true; canControl = $true }) } -token $adminToken
Write-Host "Status:" $grant.status
if ($grant.body -is [string]) { $grantBodyStr = $grant.body } else { $grantBodyStr = $grant.body | ConvertTo-Json -Depth 5 }
Write-Host "Body:" $grantBodyStr

Write-Host "\n6) Attempt control with permission (expect 202)"
$ctl2 = Invoke-Api -method 'POST' -url "$baseUrl/api/devices/$deviceId/control" -body @{ action = @{ type = 'toggle'; value = 'off' } } -token $userToken
Write-Host "Status:" $ctl2.status
if ($ctl2.body -is [string]) { $ctl2BodyStr = $ctl2.body } else { $ctl2BodyStr = $ctl2.body | ConvertTo-Json -Depth 5 }
Write-Host "Body:" $ctl2BodyStr

Write-Host "\nSmoke test finished"
