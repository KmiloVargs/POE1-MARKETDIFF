# Servidor local: sirve index.html y guarda en cache los datos de poe.ninja (15 min).
# Solo escucha en este equipo (localhost). Se cierra cerrando la ventana.
param([int]$Port = 8377, [switch]$NoBrowser)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$cache = Join-Path $root 'cache'
if (-not (Test-Path $cache)) { New-Item -ItemType Directory $cache | Out-Null }

$ua       = 'poe1-profit-tool/1.0 (local personal use, 15 min cache)'
$base     = 'https://poe.ninja/poe1/api/economy'
$ttl      = 15 * 60
$exTypes  = 'Currency','Fragment','Omen','DivinationCard','Oil','DeliriumOrb','Thread','Fossil','Resonator','Essence','Artifact','Astrolabe','Scarab','Tattoo','Runegraft','AllflameEmber','EnshroudingCrystal'
$stTypes  = 'UniqueWeapon','UniqueArmour','UniqueAccessory','UniqueFlask','UniqueJewel','SkillGem','Beast','Map','Invitation'
$script:retryAfter = @{}

function Get-Cached([string]$key, [string]$url) {
    $file = Join-Path $cache "$key.json"
    $etagFile = Join-Path $cache "$key.etag"
    $now = Get-Date
    if (Test-Path $file) {
        $age = ($now - (Get-Item $file).LastWriteTime).TotalSeconds
        if ($age -lt $ttl) { return @{ bytes = [IO.File]::ReadAllBytes($file); stale = $false; time = (Get-Item $file).LastWriteTime } }
    }
    # Si poe.ninja fallo hace poco, no insistir durante 2 minutos.
    $blocked = $script:retryAfter.ContainsKey($key) -and $now -lt $script:retryAfter[$key]
    if (-not $blocked) {
        try {
            $req = [Net.HttpWebRequest]::Create($url)
            $req.UserAgent = $ua
            $req.Timeout = 45000
            $req.AutomaticDecompression = 'GZip, Deflate'
            if ((Test-Path $file) -and (Test-Path $etagFile)) {
                $req.Headers['If-None-Match'] = [IO.File]::ReadAllText($etagFile)
            }
            $res = $req.GetResponse()
            $ms = New-Object IO.MemoryStream
            $res.GetResponseStream().CopyTo($ms)
            $bytes = $ms.ToArray()
            $etag = $res.Headers['ETag']
            $res.Close()
            [IO.File]::WriteAllBytes($file, $bytes)
            if ($etag) { [IO.File]::WriteAllText($etagFile, $etag) }
            Start-Sleep -Milliseconds 150
            return @{ bytes = $bytes; stale = $false; time = Get-Date }
        } catch [Net.WebException] {
            $r = $_.Exception.Response
            if ($r -and [int]$r.StatusCode -eq 304) {
                (Get-Item $file).LastWriteTime = Get-Date
                $r.Close()
                return @{ bytes = [IO.File]::ReadAllBytes($file); stale = $false; time = Get-Date }
            }
            $script:retryAfter[$key] = $now.AddMinutes(2)
            Write-Host "  poe.ninja no respondio para ${key}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if (Test-Path $file) { return @{ bytes = [IO.File]::ReadAllBytes($file); stale = $true; time = (Get-Item $file).LastWriteTime } }
    return $null
}

function Send-Bytes($ctx, [byte[]]$bytes, [string]$type, [int]$code = 200) {
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $type
    $ctx.Response.Headers['Cache-Control'] = 'no-store'
    $ctx.Response.ContentLength64 = $bytes.Length
    if ($ctx.Request.HttpMethod -ne 'HEAD') { $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
    $ctx.Response.Close()
}
function Send-Text($ctx, [string]$text, [int]$code) {
    Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes($text)) 'application/json; charset=utf-8' $code
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch {
    Write-Host "El puerto $Port ya esta en uso: probablemente la pagina ya esta abierta." -ForegroundColor Yellow
    if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }
    exit 1
}
Write-Host "Listo: http://localhost:$Port/  (cierra esta ventana para apagar)" -ForegroundColor Green
if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $path = $ctx.Request.Url.AbsolutePath
        if ($path -eq '/' -or $path -eq '/index.html') {
            Send-Bytes $ctx ([IO.File]::ReadAllBytes((Join-Path $root 'index.html'))) 'text/html; charset=utf-8'
            continue
        }
        $key = $null
        if ($path -eq '/api/leagues') {
            $key = 'leagues'; $url = "$base/leagues"
        } elseif ($path -match '^/api/(ex|st)/([A-Za-z]+)$') {
            $kind = $Matches[1]; $type = $Matches[2]
            $league = [string]$ctx.Request.QueryString['league']
            $ok = if ($kind -eq 'ex') { $exTypes -ccontains $type } else { $stTypes -ccontains $type }
            if ($ok -and $league -match '^[A-Za-z0-9 ()''\-]{1,60}$') {
                $key = ($kind + '_' + $type + '_' + ($league -replace '[^A-Za-z0-9]', '_'))
                $q = 'league=' + [Uri]::EscapeDataString($league) + '&type=' + $type
                $url = if ($kind -eq 'ex') { "$base/exchange/current/overview?$q" } else { "$base/stash/current/item/overview?$q" }
            }
        }
        if (-not $key) { Send-Text $ctx '{"error":"no encontrado"}' 404; continue }
        $r = Get-Cached $key $url
        if (-not $r) { Send-Text $ctx '{"error":"poe.ninja no respondio"}' 502; continue }
        $ctx.Response.Headers['X-Data-Time'] = $r.time.ToUniversalTime().ToString('o')
        if ($r.stale) { $ctx.Response.Headers['X-Stale'] = '1' }
        Send-Bytes $ctx $r.bytes 'application/json; charset=utf-8'
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        try { $ctx.Response.Abort() } catch {}
    }
}
