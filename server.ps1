$ErrorActionPreference = 'Stop'
# Keep internal filenames and syntax compatible with Windows PowerShell 3.0.

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$port = 26128
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pagePath = Join-Path $root 'index.html'
$iconPath = Join-Path $root 'favicon.ico'
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")

function Send-Response {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        [string]$ContentType,
        [byte[]]$Body
    )

    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.Headers['Cache-Control'] = 'no-store, no-cache, must-revalidate'
    $Response.Headers['Pragma'] = 'no-cache'
    $Response.ContentLength64 = $Body.Length
    $Response.OutputStream.Write($Body, 0, $Body.Length)
    $Response.OutputStream.Close()
}

function Get-Utf8WebContent {
    param(
        [string]$Uri,
        [int]$TimeoutSec = 20
    )

    $webResponse = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec $TimeoutSec
    $bytes = $webResponse.RawContentStream.ToArray()
    return [Text.Encoding]::UTF8.GetString($bytes)
}

if (-not (Test-Path -LiteralPath $pagePath)) {
    throw "找不到页面文件：$pagePath"
}

try {
    $listener.Start()
} catch {
    Write-Host "TTYQ History Query is already running." -ForegroundColor Yellow
    Write-Host "Open: http://127.0.0.1:$port/"
    Start-Process "http://127.0.0.1:$port/"
    Write-Host ""
    Write-Host "Press Enter to close this extra window." -ForegroundColor Cyan
    Read-Host
    exit
}

Write-Host "TTYQ History Query is running." -ForegroundColor Green
Write-Host "Open: http://127.0.0.1:$port/"
Write-Host "Keep this window open. Close it to stop the query tool." -ForegroundColor Cyan
Start-Process "http://127.0.0.1:$port/"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        try {
            if ($request.Url.AbsolutePath -eq '/') {
                $body = [System.IO.File]::ReadAllBytes($pagePath)
                Send-Response -Response $response -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body $body
                continue
            }

            if ($request.Url.AbsolutePath -eq '/favicon.ico' -and (Test-Path -LiteralPath $iconPath)) {
                $body = [System.IO.File]::ReadAllBytes($iconPath)
                Send-Response -Response $response -StatusCode 200 -ContentType 'image/x-icon' -Body $body
                continue
            }

            if ($request.Url.AbsolutePath -eq '/api/issue') {
                $issue = $request.QueryString['issue']
                if ($issue -notmatch '^\d{5,7}$') {
                    $message = [Text.Encoding]::UTF8.GetBytes('{"error":"期号格式不正确"}')
                    Send-Response -Response $response -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $message
                    continue
                }

                if ($issue.Length -eq 5) {
                    $issue = "20$issue"
                }

                $oddsType = $request.QueryString['type']
                if (-not $oddsType) {
                    $oddsType = 'oz'
                }

                $providerText = $request.QueryString['provider']
                if (-not $providerText) {
                    $provider = 7
                } elseif ($providerText -match '^\d+$') {
                    $provider = [int]$providerText
                } else {
                    $message = [Text.Encoding]::UTF8.GetBytes('{"error":"赔率公司编号不正确"}')
                    Send-Response -Response $response -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $message
                    continue
                }

                $typeLabels = @{
                    'oz' = '欧指'
                    'asia' = '让球'
                    'dx' = '进球数'
                }
                $providerLabels = @{
                    '0' = '皇*'
                    '1' = '36*'
                    '2' = '澳*'
                    '3' = '威廉*'
                    '4' = '伟*'
                    '5' = '立*'
                    '7' = '平均欧指'
                }

                if (-not $typeLabels.ContainsKey($oddsType)) {
                    $message = [Text.Encoding]::UTF8.GetBytes('{"error":"赔率类型不正确"}')
                    Send-Response -Response $response -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $message
                    continue
                }

                if ($oddsType -eq 'oz') {
                    $validProviders = @(0, 1, 2, 3, 4, 5, 7)
                } else {
                    $validProviders = @(0, 1, 2, 3, 4, 5)
                }

                if ([array]::IndexOf($validProviders, $provider) -lt 0) {
                    $message = [Text.Encoding]::UTF8.GetBytes('{"error":"该赔率类型不支持所选公司"}')
                    Send-Response -Response $response -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $message
                    continue
                }

                $remoteUrl = "https://www.ttyingqiu.com/static/no_cache/league/zc/jsbf/ttyq2020/sfc/sfc6cb_$issue.json"
                try {
                    $issueData = (Get-Utf8WebContent -Uri $remoteUrl) | ConvertFrom-Json
                } catch {
                    $message = [Text.Encoding]::UTF8.GetBytes('{"error":"天天盈球未找到该期数据，请检查期号"}')
                    Send-Response -Response $response -StatusCode 404 -ContentType 'application/json; charset=utf-8' -Body $message
                    continue
                }

                $oddsUrl = "https://www.ttyingqiu.com/static/no_cache/league/zc/jsbf/ttyq2020/sfc/$issue/$($oddsType)_404_$provider.json"
                try {
                    $oddsData = (Get-Utf8WebContent -Uri $oddsUrl) | ConvertFrom-Json
                } catch {
                    $message = [Text.Encoding]::UTF8.GetBytes('{"error":"该期没有所选赔率数据，请更换分类或公司"}')
                    Send-Response -Response $response -StatusCode 404 -ContentType 'application/json; charset=utf-8' -Body $message
                    continue
                }

                $oddsMap = @{}
                foreach ($oddsItem in $oddsData) {
                    $oddsMap[[string]$oddsItem.matchId] = $oddsItem
                }

                foreach ($matchItem in $issueData.matchList) {
                    $matchKey = [string]$matchItem.matchId
                    $selectedOdds = $null
                    if ($oddsMap.ContainsKey($matchKey)) {
                        $officialOdds = $oddsMap[$matchKey]
                        $selectedOdds = [pscustomobject]@{
                            winOdds = $officialOdds.winOdds
                            drawOdds = $officialOdds.drawOdds
                            loseOdds = $officialOdds.loseOdds
                            firstWinOdds = $officialOdds.firstWinOdds
                            firstDrawOdds = $officialOdds.firstDrawOdds
                            firstLoseOdds = $officialOdds.firstLoseOdds
                            winUpDown = $officialOdds.winUpDown
                            drawUpDown = $officialOdds.drawUpDown
                            loseUpDown = $officialOdds.loseUpDown
                        }
                    }
                    $matchItem | Add-Member -NotePropertyName 'selectedOdds' -NotePropertyValue $selectedOdds -Force
                }

                $oddsSelection = [pscustomobject]@{
                    type = $oddsType
                    provider = $provider
                    typeLabel = $typeLabels[$oddsType]
                    providerLabel = $providerLabels[[string]$provider]
                }
                $issueData | Add-Member -NotePropertyName 'oddsSelection' -NotePropertyValue $oddsSelection -Force

                $body = [Text.Encoding]::UTF8.GetBytes(($issueData | ConvertTo-Json -Depth 12 -Compress))
                Send-Response -Response $response -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $body
                continue
            }

            if ($request.Url.AbsolutePath -eq '/api/issues') {
                try {
                    $listHtml = Get-Utf8WebContent -Uri 'https://www.ttyingqiu.com/6cbqc'
                    $currentMatch = [regex]::Match($listHtml, '"date"\s*:\s*"(20\d{5})"')
                    $currentIssue = $currentMatch.Groups[1].Value
                    if (-not $currentIssue) {
                        throw 'current issue unavailable'
                    }

                    $year = $currentIssue.Substring(0, 4)
                    $sequence = [int]$currentIssue.Substring(4)
                    for ($offset = 1; $offset -le 30; $offset++) {
                        $candidateIssue = $year + ($sequence + $offset).ToString('000')
                        $candidateUrl = "https://www.ttyingqiu.com/static/no_cache/league/zc/jsbf/ttyq2020/sfc/sfc6cb_$candidateIssue.json"
                        try {
                            $candidateResponse = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $candidateUrl -TimeoutSec 10
                            if ($candidateResponse.StatusCode -eq 200) {
                                $currentIssue = $candidateIssue
                            }
                        } catch {
                            break
                        }
                    }

                    $sequence = [int]$currentIssue.Substring(4)
                    $items = @()
                    for ($number = $sequence; $number -ge 1; $number--) {
                        $items += '"' + $year + $number.ToString('000') + '"'
                    }
                    $issuesJson = '{"current":"' + $currentIssue + '","issues":[' + ($items -join ',') + ']}'
                    $body = [Text.Encoding]::UTF8.GetBytes($issuesJson)
                    Send-Response -Response $response -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $body
                } catch {
                    $message = [Text.Encoding]::UTF8.GetBytes('{"current":"","issues":[]}')
                    Send-Response -Response $response -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $message
                }
                continue
            }

            if ($request.Url.AbsolutePath -eq '/api/draw') {
                $issue = $request.QueryString['issue']
                if ($issue -notmatch '^\d{5,7}$') {
                    $message = [Text.Encoding]::UTF8.GetBytes('{"error":"invalid issue"}')
                    Send-Response -Response $response -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $message
                    continue
                }

                if ($issue.Length -eq 5) {
                    $issue = "20$issue"
                }

                try {
                    $shortIssue = $issue.Substring($issue.Length - 5)
                    $drawUrl = "https://www.gdlottery.cn/f_html/kjgg/P011_$shortIssue.html"
                    $drawHtml = Get-Utf8WebContent -Uri $drawUrl
                    $salesLabel = -join @(0x5168,0x56FD,0x9500,0x552E,0x91D1,0x989D | ForEach-Object { [char]$_ })
                    $poolLabel = -join @(0x5143,0x5956,0x91D1,0x6EDA,0x5165 | ForEach-Object { [char]$_ })
                    $dateLabel = -join @(0x5F00,0x5956,0x65E5,0x671F | ForEach-Object { [char]$_ })
                    $firstPrizeLabel = -join @(0x4E00,0x7B49,0x5956 | ForEach-Object { [char]$_ })

                    $sales = [regex]::Match($drawHtml, [regex]::Escape($salesLabel) + '[^0-9]*([0-9,]+)').Groups[1].Value.Replace(',', '')
                    $pool = [regex]::Match($drawHtml, '([0-9,.]+)' + [regex]::Escape($poolLabel)).Groups[1].Value.Replace(',', '').Replace('.00', '')
                    $dateMatch = [regex]::Match($drawHtml, [regex]::Escape($dateLabel) + '[^0-9]*(\d{4})[^0-9]+(\d{1,2})[^0-9]+(\d{1,2})')
                    $drawDate = $dateMatch.Groups[1].Value + '-' + $dateMatch.Groups[2].Value.PadLeft(2, '0') + '-' + $dateMatch.Groups[3].Value.PadLeft(2, '0')
                    $prizePattern = '<li[^>]*>\s*' + [regex]::Escape($firstPrizeLabel) + '\s*</li>\s*<li[^>]*>\s*([0-9,]+)[^<]*</li>\s*<li[^>]*>\s*([0-9,.]+)[^<]*</li>'
                    $prizeMatch = [regex]::Match($drawHtml, $prizePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
                    $firstPrizeCount = $prizeMatch.Groups[1].Value.Replace(',', '')
                    $firstPrizeAmount = $prizeMatch.Groups[2].Value.Replace(',', '').Replace('.00', '')

                    $drawJson = '{"sales":"' + $sales + '","pool":"' + $pool + '","drawDate":"' + $drawDate + '","firstPrizeCount":"' + $firstPrizeCount + '","firstPrizeAmount":"' + $firstPrizeAmount + '"}'
                    $body = [Text.Encoding]::UTF8.GetBytes($drawJson)
                    Send-Response -Response $response -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $body
                } catch {
                    $message = [Text.Encoding]::UTF8.GetBytes('{"sales":"","pool":"","drawDate":"","firstPrizeCount":"","firstPrizeAmount":""}')
                    Send-Response -Response $response -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $message
                }
                continue
            }

            $message = [Text.Encoding]::UTF8.GetBytes('Not Found')
            Send-Response -Response $response -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Body $message
        } catch {
            if ($response.OutputStream.CanWrite) {
                $message = [Text.Encoding]::UTF8.GetBytes('{"error":"本地服务处理请求失败"}')
                Send-Response -Response $response -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $message
            }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
