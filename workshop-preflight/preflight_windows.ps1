# Workshop preflight for Windows. Start it by double-clicking preflight_windows.cmd.
# Options: -Yes (accept defaults, no prompts)  -SkipDocker
#
# Needs nothing beyond what ships with Windows, because Python itself is under test.
# Written for Windows PowerShell 5.1. Keep this file ASCII: 5.1 misreads UTF-8 without a BOM.
# Mostly cmdlets rather than .NET calls, so it still works under Constrained Language Mode.

param([switch]$Yes, [switch]$SkipDocker)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Here = $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$TempBase = $env:TEMP
if (-not $TempBase) { $TempBase = '/tmp' }
$WorkDir = Join-Path $TempBase ("workshop-preflight-$Stamp-" + (Get-Random))
$Results = Join-Path $WorkDir 'results.tsv'
$LogFile = Join-Path $WorkDir 'details.log'
$Report = Join-Path $HOME "workshop-preflight-report-$Stamp.txt"
$AssumeYes = [bool]$Yes
$Inspected = ''
$IssuersRead = 0
$MissingTools = ''
$IsAdminUser = $true
$DockerExe = ''
$ProxyEffective = ''
$SysProxy = ''
$OpenAiKey = ''
$LangfusePk = ''
$LangfuseSk = ''
$ReportDone = $false
$Interrupted = $true
$LastRc = 0
$LastText = ''
$LastStdout = ''
$PublicCa = "Let.s Encrypt|DigiCert|Sectigo|Google Trust|Amazon|Cloudflare|GlobalSign|GoDaddy|Entrust|Microsoft|Baltimore|ZeroSSL|Starfield|SSL\.com|Certainly|COMODO|IdenTrust|ISRG|USERTrust|Fastly"

foreach ($needed in @('defaults.conf', 'preflight_checks.py', 'docker_probe\Dockerfile')) {
    $neededPath = Join-Path $Here ($needed -replace '\\', [string][char]47)
    if (-not (Test-Path -LiteralPath $neededPath)) {
        Write-Host "Missing $needed. Extract the whole zip into a folder and run the script from there."
        exit 2
    }
}

$null = New-Item -ItemType Directory -Path $WorkDir -Force
Set-Content -LiteralPath $Results -Value $null -Encoding UTF8
Set-Content -LiteralPath $LogFile -Value $null -Encoding UTF8

# ---------------------------------------------------------------- output helpers
function Write-Log([string]$Text) { Add-Content -LiteralPath $LogFile -Value $Text -Encoding UTF8 }

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor White
    Write-Log "`n`n======== $Title ========"
}

function Write-Progress2([string]$Text) { Write-Host "  ...    $Text" -ForegroundColor DarkGray }

# One check failing must never stop the checks after it.
function Invoke-Check([string]$Name, [scriptblock]$Block) {
    try {
        & $Block
    } catch {
        Write-Log "UNHANDLED ERROR in ${Name}: $($_ | Out-String)"
        Record "$Name.crash" 'FAIL' "$Name check stopped unexpectedly" $_.Exception.Message 'The remaining checks still ran. The error is in the diagnostics.'
    }
}

function One-Line([string]$Text) { return ($Text -replace "[\t\r\n]+", ' ').Trim() }

function Record([string]$Id, [string]$Status, [string]$Title, [string]$Detail = '', [string]$Hint = '') {
    $row = (One-Line $Id), (One-Line $Status), (One-Line $Title), (One-Line $Detail), (One-Line $Hint) -join "`t"
    Add-Content -LiteralPath $Results -Value $row -Encoding UTF8
    Write-Log "`n[RESULT] $Status ${Id}: $Title | $Detail"
    $color = 'Green'
    if ($Status -eq 'WARN') { $color = 'Yellow' }
    if ($Status -eq 'FAIL') { $color = 'Red' }
    if ($Status -eq 'SKIP') { $color = 'Cyan' }
    Write-Host '  [' -NoNewline
    Write-Host ($Status.PadRight(4)) -NoNewline -ForegroundColor $color
    $line = "] $Title"
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line
    if ($Hint -and ($Status -eq 'FAIL' -or $Status -eq 'WARN')) { Write-Host "         > $Hint" }
}

function Quote-Arg([string]$Arg) {
    if ($Arg -eq '') { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $escaped = $Arg -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

# Sets LastRc (124 = timed out, 127 = could not start), LastStdout and LastText (stdout + stderr).
function Invoke-Logged([string]$Exe, [string[]]$ArgList = @(), [int]$TimeoutSec = 60) {
    $id = Get-Random
    $outFile = Join-Path $WorkDir "o$id.txt"
    $errFile = Join-Path $WorkDir "e$id.txt"
    $argLine = (@($ArgList) | ForEach-Object { Quote-Arg $_ }) -join ' '
    $filePath = $Exe
    if ($Exe -match '\.(cmd|bat)$') {
        $filePath = $env:ComSpec
        $argLine = '/d /s /c "' + (Quote-Arg $Exe) + ' ' + $argLine + '"'
    }
    Write-Log "`n`$ $Exe $argLine"
    $started = Get-Date
    $script:LastRc = 127
    $script:LastStdout = ''
    $script:LastText = ''
    try {
        $startArgs = @{ FilePath = $filePath; NoNewWindow = $true; PassThru = $true; RedirectStandardOutput = $outFile; RedirectStandardError = $errFile; ErrorAction = 'Stop' }
        if ($argLine) { $startArgs['ArgumentList'] = $argLine }
        $proc = Start-Process @startArgs
        $null = $proc.Handle   # caching the handle keeps ExitCode readable afterwards
        Wait-Process -Id $proc.Id -Timeout $TimeoutSec -ErrorAction SilentlyContinue
        if ($proc.HasExited) {
            $script:LastRc = $proc.ExitCode
        } else {
            $null = & taskkill.exe /T /F /PID $proc.Id 2>&1
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $script:LastRc = 124
        }
    } catch {
        Write-Log "could not start: $($_.Exception.Message)"
        $script:LastText = $_.Exception.Message
    }
    if (Test-Path -LiteralPath $outFile) { $script:LastStdout = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) }
    $errText = ''
    if (Test-Path -LiteralPath $errFile) { $errText = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) }
    if ($script:LastStdout -or $errText) { $script:LastText = $script:LastStdout + $errText }
    $shown = $script:LastText
    if ($shown.Length -gt 12000) { $shown = $shown.Substring($shown.Length - 12000) }
    Write-Log $shown
    Write-Log ("[exit $($script:LastRc) after " + [int]((Get-Date) - $started).TotalSeconds + "s]")
}

function Last-Line([string]$Text) {
    $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return '' }
    return $lines[$lines.Count - 1].Trim()
}

function Ask-Yes([string]$Prompt, [string]$Default) {
    if ($AssumeYes) { return ($Default -eq 'y') }
    $answer = Read-Host $Prompt
    if (-not $answer) { $answer = $Default }
    return ($answer -match '^(y|yes)$')
}

function Read-Secret([string]$Label) {
    $secure = Read-Host "  $Label (hidden, Enter to skip)" -AsSecureString
    try {
        $plain = (New-Object System.Management.Automation.PSCredential('x', $secure)).GetNetworkCredential().Password
    } catch {
        # Constrained Language Mode cannot unwrap a SecureString, so ask for it visibly.
        $plain = Read-Host "  $Label (visible on this locked-down system, Enter to skip)"
    }
    return ([string]$plain).Trim()
}

# ---------------------------------------------------------------- report
function Protect-Text([string]$Text) {
    foreach ($secret in @($OpenAiKey, $LangfusePk, $LangfuseSk)) {
        if ($secret) { $Text = $Text.Replace($secret, '***REDACTED***') }
    }
    $Text = $Text -replace 'sk-[A-Za-z0-9_*\-]{8,}', 'sk-***REDACTED***'
    $Text = $Text -replace 'pk-lf-[A-Za-z0-9\-]+', 'pk-lf-***REDACTED***'
    $Text = $Text -replace 'gh[pousr]_[A-Za-z0-9]{20,}', 'gh*_***REDACTED***'
    $Text = $Text -replace 'github_pat_[A-Za-z0-9_]+', 'github_pat_***REDACTED***'
    $Text = $Text -replace '(Bearer|Basic) [A-Za-z0-9._~+/=\-]{8,}', '$1 ***REDACTED***'
    $Text = $Text -replace '([?&]token=)[^&\s]+', '$1***REDACTED***'
    $Text = $Text -replace '(ServerApp\.token=)\S+', '$1***REDACTED***'
    $Text = $Text -replace '([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/@\s]+:[^/@\s]+@', '$1***:***@'
    $user = $env:USERNAME
    if (-not $user) { $user = $env:USER }
    $machine = $env:COMPUTERNAME
    if (-not $machine) { $machine = $env:HOSTNAME }
    if ($user -and $user.Length -ge 3) { $Text = $Text -ireplace [regex]::Escape($user), '<user>' }
    if ($machine -and $machine.Length -ge 3) { $Text = $Text -ireplace [regex]::Escape($machine), '<host>' }
    return $Text
}

function Get-Rows {
    if (-not (Test-Path -LiteralPath $Results)) { return @() }
    return @(Get-Content -LiteralPath $Results -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { , @($_ -split "`t") })
}

function Count-Status([string]$Status) {
    $n = 0
    foreach ($row in (Get-Rows)) { if ($row[1] -eq $Status) { $n++ } }
    return $n
}

function Get-Verdict {
    if ((Count-Status 'FAIL') -gt 0) { return 'NOT READY - required items failed' }
    if ((Count-Status 'WARN') -gt 0) { return 'READY WITH WARNINGS - see the items below' }
    return 'READY'
}

function Write-Report {
    if ($script:ReportDone) { return }
    $script:ReportDone = $true
    $b = New-Object System.Collections.ArrayList
    $osText = 'Windows'
    try { $osText = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch {}
    $null = $b.Add('WORKSHOP PREFLIGHT REPORT')
    $null = $b.Add('Created:   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
    $null = $b.Add("Platform:  $osText on $env:PROCESSOR_ARCHITECTURE")
    $null = $b.Add('Verdict:   ' + (Get-Verdict))
    $null = $b.Add("Counts:    PASS $(Count-Status 'PASS') | WARN $(Count-Status 'WARN') | FAIL $(Count-Status 'FAIL') | SKIP $(Count-Status 'SKIP')")
    if ($script:Interrupted) { $null = $b.Add('NOTE:      The run did not finish, so this report is partial.') }
    $null = $b.Add('')
    $null = $b.Add('---- SUMMARY ----')
    foreach ($row in (Get-Rows)) {
        $text = $row[1].PadRight(6) + $row[0].PadRight(21) + $row[2]
        if ($row[3]) { $text += " - $($row[3])" }
        $null = $b.Add($text)
    }
    $null = $b.Add('')
    $null = $b.Add('---- PROBLEMS AND LIKELY CAUSES ----')
    $found = $false
    foreach ($row in (Get-Rows)) {
        if ($row[1] -eq 'FAIL' -or $row[1] -eq 'WARN') {
            $found = $true
            $null = $b.Add("$($row[1]) $($row[0]): $($row[2])")
            if ($row[3]) { $null = $b.Add("    Detail: $($row[3])") }
            if ($row[4]) { $null = $b.Add("    Likely cause / fix: $($row[4])") }
            $null = $b.Add('')
        }
    }
    if (-not $found) { $null = $b.Add('None.'); $null = $b.Add('') }
    $null = $b.Add('---- SETTINGS USED ----')
    if ($script:Cfg) {
        $null = $b.Add("OpenAI URL:     $($Cfg.OPENAI_BASE_URL)")
        $null = $b.Add("OpenAI models:  $($Cfg.OPENAI_MODEL)")
        $null = $b.Add('OpenAI key:     ' + $(if ($script:OpenAiKey) { 'provided' } else { 'not provided' }))
        $null = $b.Add("Langfuse host:  $($Cfg.LANGFUSE_HOST)")
        $null = $b.Add('Langfuse keys:  ' + $(if ($script:LangfusePk -and $script:LangfuseSk) { 'provided' } else { 'not provided' }))
        $null = $b.Add("Git test repo:  $($Cfg.GIT_REPO_URL)")
        $null = $b.Add("Pip index:      $($Cfg.PIP_INDEX_URL)")
        $null = $b.Add("Pip packages:   $($Cfg.PIP_PACKAGES)")
        $null = $b.Add("Docker images:  $($Cfg.DOCKER_TEST_IMAGE) $($Cfg.DOCKER_BASE_IMAGE)")
        $null = $b.Add('Proxy:          ' + $(if ($script:ProxyEffective) { $script:ProxyEffective } else { 'none' }))
        $null = $b.Add('CA bundle:      ' + $(if ($Cfg.CA_BUNDLE) { $Cfg.CA_BUNDLE } else { 'none' }))
    }
    $null = $b.Add('')
    $null = $b.Add('---- FULL DIAGNOSTICS ----')
    $null = $b.Add([string](Get-Content -LiteralPath $LogFile -Raw -Encoding UTF8))
    $finalText = Protect-Text ($b -join "`r`n")
    try {
        Set-Content -LiteralPath $Report -Value $finalText -Encoding UTF8 -ErrorAction Stop
    } catch {
        $script:Report = Join-Path $TempBase (Split-Path -Leaf $Report)
        Set-Content -LiteralPath $script:Report -Value $finalText -Encoding UTF8
    }
}

# ---------------------------------------------------------------- settings
$Cfg = @{
    OPENAI_BASE_URL = ''; OPENAI_MODEL = ''; LANGFUSE_HOST = ''; GIT_REPO_URL = ''; PIP_INDEX_URL = ''
    PIP_PACKAGES = ''; DOCKER_TEST_IMAGE = ''; DOCKER_BASE_IMAGE = ''; PROXY_URL = 'auto'; CA_BUNDLE = ''
}

function Read-KeyValues([string]$Path) {
    $values = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $text = ($line.Trim()) -replace '^export\s+', ''
        if (-not $text -or $text.StartsWith('#') -or -not $text.Contains('=')) { continue }
        $at = $text.IndexOf('=')
        $values[$text.Substring(0, $at)] = ($text.Substring($at + 1)).Trim().Trim('"').Trim("'")
    }
    return $values
}

function Get-SystemProxy {
    try {
        $target = [Uri]'https://api.openai.com/v1/models'
        $resolved = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($target)
        if ($resolved -and $resolved.Host -ne $target.Host) { return $resolved.AbsoluteUri.TrimEnd('/') }
    } catch {}
    try {
        $settings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($settings.ProxyEnable -eq 1 -and $settings.ProxyServer) {
            $server = [string]$settings.ProxyServer
            if ($server -match 'https=([^;]+)') { $server = $Matches[1] }
            elseif ($server -match '=') { return '' }
            if ($server -notmatch '://') { $server = "http://$server" }
            return $server
        }
    } catch {}
    return ''
}

function Resolve-Proxy {
    $fromEnv = $env:HTTPS_PROXY
    if (-not $fromEnv) { $fromEnv = $env:HTTP_PROXY }
    switch ($Cfg.PROXY_URL) {
        'none' { $script:ProxyEffective = '' }
        { $_ -eq 'auto' -or -not $_ } { $script:ProxyEffective = $(if ($fromEnv) { $fromEnv } else { $SysProxy }) }
        default { if ($Cfg.PROXY_URL -ne 'none' -and $Cfg.PROXY_URL -ne 'auto' -and $Cfg.PROXY_URL) { $script:ProxyEffective = $Cfg.PROXY_URL } }
    }
}

function Show-Settings {
    Resolve-Proxy
    $proxyNow = $(if ($script:ProxyEffective) { $script:ProxyEffective } else { 'direct connection' })
    $caNow = $(if ($Cfg.CA_BUNDLE) { $Cfg.CA_BUNDLE } else { 'none' })
    Write-Host ''
    Write-Host "  1. OpenAI API URL      $($Cfg.OPENAI_BASE_URL)"
    Write-Host "  2. OpenAI models       $($Cfg.OPENAI_MODEL)"
    Write-Host "  3. Langfuse host       $($Cfg.LANGFUSE_HOST)"
    Write-Host "  4. Git test repo       $($Cfg.GIT_REPO_URL)"
    Write-Host "  5. Pip index           $($Cfg.PIP_INDEX_URL)"
    Write-Host "  6. Pip test packages   $($Cfg.PIP_PACKAGES)"
    Write-Host "  7. Docker test image   $($Cfg.DOCKER_TEST_IMAGE)"
    Write-Host "  8. Docker base image   $($Cfg.DOCKER_BASE_IMAGE)"
    Write-Host "  9. Proxy               $($Cfg.PROXY_URL) (currently: $proxyNow)"
    Write-Host " 10. Corporate CA file   $caNow"
    Write-Host ''
}

function Edit-Setting([string]$Key, [string]$Label) {
    $shown = $(if ($Cfg[$Key]) { $Cfg[$Key] } else { 'empty' })
    $answer = Read-Host "  $Label [$shown]"
    if ($answer -eq '-') { $Cfg[$Key] = '' }
    elseif ($answer) { $Cfg[$Key] = $answer }
}

function Get-KeyValue([string]$Current, [string]$EnvName, [string]$Label) {
    if ($Current) { return $Current }
    $existing = [string](Get-Item -Path "Env:$EnvName" -ErrorAction SilentlyContinue).Value
    if ($existing -and (Ask-Yes "  $EnvName is already set in this terminal. Use it? [Y/n]" 'y')) { return $existing }
    if ($AssumeYes) { return '' }
    return (Read-Secret $Label)
}

function Configure {
    $defaults = Read-KeyValues (Join-Path $Here 'defaults.conf')
    foreach ($key in @($Cfg.Keys)) { if ($defaults.ContainsKey($key)) { $Cfg[$key] = $defaults[$key] } }
    $script:SysProxy = Get-SystemProxy
    $keysFile = Join-Path $Here 'keys.env'
    if (Test-Path -LiteralPath $keysFile) {
        $keys = Read-KeyValues $keysFile
        $script:OpenAiKey = [string]$keys['OPENAI_API_KEY']
        $script:LangfusePk = [string]$keys['LANGFUSE_PUBLIC_KEY']
        $script:LangfuseSk = [string]$keys['LANGFUSE_SECRET_KEY']
        if ($keys['LANGFUSE_BASE_URL']) { $Cfg.LANGFUSE_HOST = $keys['LANGFUSE_BASE_URL'] }
        elseif ($keys['LANGFUSE_HOST']) { $Cfg.LANGFUSE_HOST = $keys['LANGFUSE_HOST'] }
    }
    Write-Section 'Settings'
    Show-Settings
    if (-not (Ask-Yes 'Use these settings? [Y/n]' 'y')) {
        Write-Host '  Press Enter to keep a value, or type a new one. Enter - to clear it. Proxy accepts auto, none, or a URL.'
        Edit-Setting 'OPENAI_BASE_URL' 'OpenAI API URL'
        Edit-Setting 'OPENAI_MODEL' 'OpenAI models (space separated)'
        Edit-Setting 'LANGFUSE_HOST' 'Langfuse host'
        Edit-Setting 'GIT_REPO_URL' 'Git test repo'
        Edit-Setting 'PIP_INDEX_URL' 'Pip index'
        Edit-Setting 'PIP_PACKAGES' 'Pip test packages'
        Edit-Setting 'DOCKER_TEST_IMAGE' 'Docker test image'
        Edit-Setting 'DOCKER_BASE_IMAGE' 'Docker base image'
        Edit-Setting 'PROXY_URL' 'Proxy'
        Edit-Setting 'CA_BUNDLE' 'Corporate CA file'
        Show-Settings
    }

    Write-Host 'API keys are used only for test calls. They are never saved and are removed from the report.'
    if (Test-Path -LiteralPath $keysFile) { Write-Host '  Using the keys supplied in keys.env.' }
    $script:OpenAiKey = Get-KeyValue $script:OpenAiKey 'OPENAI_API_KEY' 'OpenAI API key'
    $script:LangfusePk = Get-KeyValue $script:LangfusePk 'LANGFUSE_PUBLIC_KEY' 'Langfuse public key'
    $script:LangfuseSk = Get-KeyValue $script:LangfuseSk 'LANGFUSE_SECRET_KEY' 'Langfuse secret key'

    foreach ($key in @('OPENAI_BASE_URL', 'LANGFUSE_HOST', 'PIP_INDEX_URL')) { $Cfg[$key] = $Cfg[$key].TrimEnd('/') }

    Resolve-Proxy
    if ($script:ProxyEffective) {
        $env:HTTP_PROXY = $script:ProxyEffective
        $env:HTTPS_PROXY = $script:ProxyEffective
    } else {
        Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:ALL_PROXY -ErrorAction SilentlyContinue
    }
    $env:NO_PROXY = 'localhost,127.0.0.1,::1'

    if ($Cfg.CA_BUNDLE) {
        if (Test-Path -LiteralPath $Cfg.CA_BUNDLE) {
            $env:SSL_CERT_FILE = $Cfg.CA_BUNDLE
            $env:REQUESTS_CA_BUNDLE = $Cfg.CA_BUNDLE
            $env:PIP_CERT = $Cfg.CA_BUNDLE
            $env:CURL_CA_BUNDLE = $Cfg.CA_BUNDLE
            $env:GIT_SSL_CAINFO = $Cfg.CA_BUNDLE
        } else {
            Record 'config.ca' 'WARN' 'Corporate CA file not found' $Cfg.CA_BUNDLE 'Check the path. Continuing without it.'
            $Cfg.CA_BUNDLE = ''
        }
    }
}

# ---------------------------------------------------------------- system
function Check-System {
    Write-Section 'Laptop'
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]
        Write-Log "OS: $($os.Caption) $($os.Version) build $($os.BuildNumber)"
        Write-Log "CPU: $($cpu.Name), virtualization enabled in firmware: $($cpu.VirtualizationFirmwareEnabled)"
        Record 'sys.os' 'PASS' "$($os.Caption)" "build $($os.BuildNumber), $env:PROCESSOR_ARCHITECTURE, $($cs.NumberOfLogicalProcessors) CPU threads"

        # An 8 GB laptop reports slightly under 8 once firmware has reserved its share.
        $ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        if ($ramGb -ge 15) { Record 'sys.ram' 'PASS' "RAM $ramGb GB" }
        elseif ($ramGb -ge 7.5) { Record 'sys.ram' 'WARN' "RAM $ramGb GB" 'meets the 8 GB minimum' '16 GB is recommended for Docker. Close other apps during the workshop.' }
        else { Record 'sys.ram' 'FAIL' "RAM $ramGb GB" 'below the 8 GB minimum' 'Use a laptop with at least 8 GB of RAM.' }
    } catch {
        Record 'sys.os' 'WARN' 'Could not read system information' $_.Exception.Message
    }

    $driveName = $(if ($env:SystemDrive) { $env:SystemDrive.Substring(0, 1) } else { '/' })
    $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGb = [math]::Round($drive.Free / 1GB, 0)
        if ($freeGb -ge 15) { Record 'sys.disk' 'PASS' "Free disk $freeGb GB" }
        elseif ($freeGb -ge 5) { Record 'sys.disk' 'WARN' "Free disk $freeGb GB" '' '15 GB or more is recommended for Docker images and Python packages.' }
        else { Record 'sys.disk' 'FAIL' "Free disk $freeGb GB" '' 'Free at least 5 GB. Python packages alone need about 1 GB.' }
    }

    # S-1-5-32-544 is the local Administrators group, listed even when UAC has filtered it.
    Invoke-Logged 'whoami.exe' @('/groups') 20
    if ($LastText -match 'S-1-5-32-544') {
        $script:IsAdminUser = $true
        Record 'sys.admin' 'PASS' 'Account has admin rights'
    } else {
        $script:IsAdminUser = $false
        Record 'sys.admin' 'WARN' 'Account does not have admin rights' '' 'IT must pre-install anything reported missing below.'
    }

    $tools = 'zscaler|netskope|falcon|crowdstrike|sentinel|cylance|globalprotect|pangps|anyconnect|forticlient|umbrella|carbonblack|tanium|defender|msmpeng'
    $names = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $tools } | Select-Object -ExpandProperty Name -Unique
    Write-Log ("Security and VPN processes: " + (@($names) -join ', '))
    try {
        $fs = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction Stop
        Write-Log "LongPathsEnabled: $($fs.LongPathsEnabled)"
    } catch {}
}

function Check-Terminal {
    Write-Section 'Terminal'
    $mode = [string]$ExecutionContext.SessionState.LanguageMode
    Write-Log "PowerShell $($PSVersionTable.PSVersion), language mode $mode"
    Write-Log "PATH=$env:Path"
    Write-Log (Get-ExecutionPolicy -List | Out-String)

    $shell = $env:ComSpec
    if ($shell) {
        Invoke-Logged $shell @('/c', 'echo PF_CMD_OK') 15
        if ($LastText -match 'PF_CMD_OK') {
            Record 'term.cmd' 'PASS' 'Command Prompt runs commands'
        } else {
            Record 'term.cmd' 'FAIL' 'Command Prompt could not run a command' "exit $LastRc" 'cmd.exe may be disabled by policy. Ask IT.'
        }
    }
    Record 'term.powershell' 'PASS' 'PowerShell runs this script' "version $($PSVersionTable.PSVersion), $mode"
    if ($mode -ne 'FullLanguage') {
        Record 'term.language' 'WARN' "PowerShell is in $mode" '' 'AppLocker or WDAC is active. Virtual environment activation may be blocked, and Python may be restricted too.'
    }

    # This launcher bypasses the policy for itself only, so read what a normal terminal gets.
    $effective = 'Restricted'
    foreach ($scope in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
        $policy = [string](Get-ExecutionPolicy -Scope $scope)
        if ($policy -and $policy -ne 'Undefined') { $effective = $policy; break }
    }
    if ($effective -in @('Restricted', 'AllSigned')) {
        Record 'term.policy' 'WARN' "PowerShell execution policy is $effective" '' 'venv\Scripts\Activate.ps1 will not run. Use Command Prompt with venv\Scripts\activate.bat, or run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
    } else {
        Record 'term.policy' 'PASS' "PowerShell execution policy is $effective" 'virtual environments can be activated'
    }
}

# ---------------------------------------------------------------- network
$CurlExe = ''
$curlCmd = Get-Command 'curl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $curlCmd) { $curlCmd = Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($curlCmd) { $CurlExe = $curlCmd.Source }

function Curl-Hint([int]$Code, [string]$Text) {
    if ($Text -match 'CRYPT_E_NO_REVOCATION_CHECK|CRYPT_E_REVOCATION_OFFLINE') { return 'Windows could not check certificate revocation, which is common behind an inspection proxy. Ask IT to allow the CRL endpoints.' }
    if ($Text -match 'SEC_E_UNTRUSTED_ROOT|CERT_TRUST|unable to get local issuer') { return 'The certificate is not trusted, which usually means corporate TLS inspection. Ask IT for the root CA file and set CA_BUNDLE.' }
    switch ($Code) {
        5 { return 'The proxy host name cannot be resolved. Check the proxy URL.' }
        6 { return 'DNS cannot resolve this host. Connect to VPN, or ask IT whether it is blocked.' }
        7 {
            if ($ProxyEffective) { return 'Could not connect through the configured proxy. Check the proxy URL, or try proxy setting none.' }
            return 'The connection was refused or blocked. A firewall or missing proxy setting is likely.'
        }
        28 { return 'The connection timed out. A firewall is probably dropping traffic, or a proxy is needed.' }
        35 { return 'The TLS handshake failed. A firewall or inspection proxy may be interfering.' }
        52 { return 'The connection was dropped after it opened. A proxy or firewall is likely closing it.' }
        56 { return 'The connection was dropped after it opened. A proxy or firewall is likely closing it.' }
        60 { return 'The certificate is not trusted, which usually means corporate TLS inspection. Ask IT for the root CA file and set CA_BUNDLE.' }
        77 { return 'The certificate is not trusted, which usually means corporate TLS inspection. Ask IT for the root CA file and set CA_BUNDLE.' }
        97 { return 'The proxy handshake failed. Check the proxy URL.' }
    }
    return "curl failed with exit code $Code. See the diagnostics."
}

function Get-CertIssuer([string]$Url) {
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Timeout = 12000
        if ($ProxyEffective) { $request.Proxy = New-Object System.Net.WebProxy($ProxyEffective) }
        try { $response = $request.GetResponse(); $response.Close() } catch {}
        $cert = $request.ServicePoint.Certificate
        if ($cert) { return [string]$cert.Issuer }
    } catch {}
    return ''
}

# Uses WinINET, so it follows Windows proxy settings and PAC files the way a browser does.
function Test-SystemStack([string]$Url) {
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 -Method Get -ErrorAction Stop
        return "HTTP $($response.StatusCode)"
    } catch {
        if ($_.Exception.Response) { return "HTTP $([int]$_.Exception.Response.StatusCode)" }
        return ''
    }
}

function Check-Url([string]$Id, [string]$Label, [string]$Url, [string]$Severity, [bool]$Allow403 = $false) {
    $targetHost = $Url -replace '^[a-z]+://([^/:]+).*', '$1'
    $bodyFile = Join-Path $WorkDir 'body.txt'
    $code = 0
    $rc = 127
    $errText = ''
    if ($CurlExe) {
        Invoke-Logged $CurlExe @('-sS', '-o', $bodyFile, '--connect-timeout', '10', '-m', '20', '-w', '%{http_code} ip=%{remote_ip} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s', $Url) 25
        $rc = $LastRc
        $errText = $LastText
        $first = ((Last-Line $LastStdout) -split ' ')[0]
        if ($first -match '^\d+$') { $code = [int]$first }
    }
    $issuer = Get-CertIssuer $Url
    $detail = $targetHost
    if ($issuer) {
        $script:IssuersRead++
        $detail += ", cert issuer: $issuer"
        if ($issuer -notmatch $PublicCa) { $script:Inspected += " $targetHost [$issuer];" }
    }

    if ($rc -ne 0) {
        $system = Test-SystemStack $Url
        Write-Log "Windows network stack result for ${Url}: $(if ($system) { $system } else { 'failed' })"
        try { Write-Log (Resolve-DnsName -Name $targetHost -ErrorAction Stop | Out-String) } catch { Write-Log "DNS lookup failed: $($_.Exception.Message)" }
        if ($system) {
            Record $Id $Severity "${Label}: works through Windows settings, but not for command-line tools" "$detail, curl exit $rc, Windows $system" 'Python, Git and Docker ignore PAC files. Re-run and enter the proxy URL under item 9, or ask IT for it.'
        } else {
            Record $Id $Severity "${Label}: not reachable" "$detail, curl exit $rc" (Curl-Hint $rc $errText)
        }
    } elseif ($code -eq 407) {
        Record $Id $Severity "${Label}: proxy login required" "$detail, HTTP 407" 'The proxy wants a login that tools cannot provide. Ask IT to allowlist this host.'
    } elseif ($code -eq 403 -and -not $Allow403) {
        if (Test-Path -LiteralPath $bodyFile) { Write-Log ([string](Get-Content -LiteralPath $bodyFile -Raw -ErrorAction SilentlyContinue)) }
        Record $Id $Severity "${Label}: blocked (HTTP 403)" $detail 'This may be a URL filter. The response body is in the diagnostics. Ask IT to allowlist this host.'
    } elseif ($code -ge 500) {
        Record $Id $Severity "${Label}: server or gateway error" "$detail, HTTP $code" 'This is a proxy or temporary service problem. Retry, then ask IT if it persists.'
    } else {
        Record $Id 'PASS' "$Label reachable" "$detail, HTTP $code"
    }
}

function Check-Network {
    Write-Section 'Network'
    Write-Log "Effective proxy: $(if ($ProxyEffective) { $ProxyEffective } else { 'none' })"
    Invoke-Logged 'netsh.exe' @('winhttp', 'show', 'proxy') 15
    Invoke-Logged 'ipconfig.exe' @('/all') 15
    try {
        $settings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        Write-Log "Internet Settings: ProxyEnable=$($settings.ProxyEnable) ProxyServer=$($settings.ProxyServer) AutoConfigURL=$($settings.AutoConfigURL)"
    } catch {}
    if (-not $CurlExe) {
        Record 'net.curl' 'WARN' 'curl.exe not found' '' 'Network checks will be less detailed.'
    } else {
        Invoke-Logged $CurlExe @('--version') 15
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    Check-Url 'net.openai' 'OpenAI API' "$($Cfg.OPENAI_BASE_URL)/models" 'FAIL'
    Check-Url 'net.pypi' 'Package index' "$($Cfg.PIP_INDEX_URL)/pip/" 'FAIL'
    if ($Cfg.PIP_INDEX_URL -like 'https://pypi.org/*') {
        Check-Url 'net.pythonhosted' 'PyPI file downloads' 'https://files.pythonhosted.org/' 'FAIL'
    }
    Check-Url 'net.github' 'GitHub' 'https://github.com' 'WARN'
    Check-Url 'net.codeload' 'GitHub downloads' 'https://codeload.github.com' 'WARN'
    Check-Url 'net.dockerhub' 'Docker Hub registry' 'https://registry-1.docker.io/v2/' 'WARN'
    Check-Url 'net.dockerauth' 'Docker Hub login service' 'https://auth.docker.io/token' 'WARN'
    Check-Url 'net.dockercdn' 'Docker Hub image CDN' 'https://production.cloudflare.docker.com/' 'WARN' $true
    Check-Url 'net.vscode' 'VS Code extensions' 'https://marketplace.visualstudio.com' 'WARN'
    Check-Url 'net.openvsx' 'Cursor extensions (Open VSX)' 'https://open-vsx.org' 'WARN'
    Check-Url 'net.langfuse_us' 'Langfuse US region' 'https://us.cloud.langfuse.com' 'WARN'

    if ($Inspected) {
        Record 'net.tls_inspection' 'WARN' 'TLS inspection detected' $Inspected 'HTTPS is being re-signed by a non-public CA. Python and Docker may not trust it even when browsers do; see the Python and Docker results.'
    } elseif ($IssuersRead -eq 0) {
        Record 'net.tls_inspection' 'SKIP' 'TLS inspection not checked' 'certificate issuers could not be read here; the Python TLS check below still tests trust'
    } else {
        Record 'net.tls_inspection' 'PASS' 'No TLS inspection detected' "$IssuersRead sampled certificates come from public CAs"
    }
}

# Keys go through a private curl config file so they never appear in a process list.
function Invoke-SecretCurl([string]$ConfigLine, [string]$Url) {
    $cfgFile = Join-Path $WorkDir 'curl.cfg'
    $bodyFile = Join-Path $WorkDir 'api_body.txt'
    Set-Content -LiteralPath $cfgFile -Value $ConfigLine -Encoding Ascii
    Invoke-Logged $CurlExe @('-sS', '-K', $cfgFile, '-o', $bodyFile, '--connect-timeout', '10', '-m', '30', '-w', '%{http_code}', $Url) 40
    Remove-Item -LiteralPath $cfgFile -Force -ErrorAction SilentlyContinue
    $script:ApiRc = $LastRc
    $script:ApiCode = (Last-Line $LastStdout)
    $script:ApiBody = ''
    if (Test-Path -LiteralPath $bodyFile) { $script:ApiBody = [string](Get-Content -LiteralPath $bodyFile -Raw -ErrorAction SilentlyContinue) }
    if ($script:ApiBody.Length -gt 600) { Write-Log $script:ApiBody.Substring(0, 600) } else { Write-Log $script:ApiBody }
}

function Check-OpenAiApi {
    Write-Section 'OpenAI API'
    if (-not $OpenAiKey) {
        Record 'openai.key' 'WARN' 'OpenAI key not tested' 'no key provided' 'Re-run with a key to prove API access. Required for the agent and LLM judges.'
        return
    }
    if (-not $CurlExe) {
        Record 'openai.key' 'SKIP' 'Raw API check skipped' 'curl.exe not found; the Python SDK check below still tests the key'
        return
    }
    Invoke-SecretCurl "header = `"Authorization: Bearer $OpenAiKey`"" "$($Cfg.OPENAI_BASE_URL)/models"
    if ($ApiRc -ne 0) {
        Record 'openai.key' 'FAIL' 'OpenAI API call failed' "curl exit $ApiRc" (Curl-Hint $ApiRc $LastText)
        return
    }
    switch ($ApiCode) {
        '200' {
            $missing = @()
            foreach ($model in ($Cfg.OPENAI_MODEL -split '\s+' | Where-Object { $_ })) {
                if (-not $ApiBody.Contains('"' + $model + '"')) { $missing += $model }
            }
            if ($missing.Count -eq 0) {
                Record 'openai.key' 'PASS' 'OpenAI key accepted' "available: $($Cfg.OPENAI_MODEL)"
            } else {
                Record 'openai.key' 'WARN' 'OpenAI key accepted, but a model is not listed' ($missing -join ' ') "Choose models this key's project can use."
            }
        }
        '401' { Record 'openai.key' 'FAIL' 'OpenAI rejected the key' 'HTTP 401' 'Check it was pasted completely and has not been revoked.' }
        '403' { Record 'openai.key' 'FAIL' 'OpenAI access refused' 'HTTP 403' 'This may be a proxy URL filter or an unsupported region. The response body is in the diagnostics.' }
        '429' { Record 'openai.key' 'FAIL' 'OpenAI rate limit or no credit' 'HTTP 429' "The network and key work. Check the account's billing and limits." }
        default { Record 'openai.key' 'FAIL' 'Unexpected OpenAI response' "HTTP $ApiCode" 'The response body is in the diagnostics.' }
    }
}

function Check-Langfuse {
    Write-Section 'Langfuse'
    $fallback = "Fallback: run code locally and view results in the instructor's Langfuse project."
    Check-Url 'langfuse.ui' 'Langfuse UI' $Cfg.LANGFUSE_HOST 'WARN'
    Check-Url 'langfuse.api' 'Langfuse API' "$($Cfg.LANGFUSE_HOST)/api/public/health" 'WARN'

    if ($LangfusePk -and $LangfuseSk -and $CurlExe) {
        Invoke-SecretCurl "user = `"${LangfusePk}:${LangfuseSk}`"" "$($Cfg.LANGFUSE_HOST)/api/public/projects"
        if ($ApiRc -ne 0) { Record 'langfuse.auth' 'WARN' 'Langfuse key check failed' "curl exit $ApiRc" ((Curl-Hint $ApiRc $LastText) + " $fallback") }
        elseif ($ApiCode -eq '200') { Record 'langfuse.auth' 'PASS' 'Langfuse keys accepted' }
        elseif ($ApiCode -eq '401') { Record 'langfuse.auth' 'WARN' 'Langfuse rejected the keys' 'HTTP 401' "Check the keys and the region: cloud.langfuse.com and us.cloud.langfuse.com are separate. $fallback" }
        else { Record 'langfuse.auth' 'WARN' 'Unexpected Langfuse response' "HTTP $ApiCode" $fallback }
    } else {
        Record 'langfuse.auth' 'SKIP' 'Langfuse keys not tested' 'keys not provided'
    }

    Confirm-InChrome $fallback
}

# A browser can take a different network path from command-line tools, so a person confirms this.
function Confirm-InChrome([string]$Fallback) {
    if ($AssumeYes) {
        Record 'langfuse.chrome' 'SKIP' 'Chrome UI check not done' 'it needs a person; run without -Yes'
        return
    }
    $url = $Cfg.LANGFUSE_HOST
    $browser = 'Chrome'
    Write-Host ''
    Write-Host '  Manual check: the Langfuse page must load in Google Chrome. No sign-in is needed.'
    if (Ask-Yes "  Open $url in Chrome now? [Y/n]" 'y') {
        try {
            Start-Process 'chrome' -ArgumentList $url -ErrorAction Stop
        } catch {
            $browser = 'your default browser'
            Record 'langfuse.chrome_app' 'WARN' 'Google Chrome could not be opened' '' 'Install Chrome, or tell your instructor which browser you will use.'
            try { Start-Process $url -ErrorAction Stop } catch { Write-Log "Could not open a browser: $($_.Exception.Message)" }
        }
    } else {
        Write-Host "  Open this link in Chrome yourself: $url"
    }
    foreach ($attempt in 1..5) {
        $answer = ([string](Read-Host "  Did the page load in ${browser}? A sign-in page counts. [y = yes, n = no, s = skip]")).Trim().ToLower()
        if ($answer -eq 'y' -or $answer -eq 'yes') {
            Record 'langfuse.chrome' 'PASS' "Langfuse UI loads in $browser" 'confirmed by participant'
            return
        }
        if ($answer -eq 'n' -or $answer -eq 'no') {
            $seen = Read-Host '  What did you see? For example: blocked page, blank page, timeout'
            if (-not $seen) { $seen = 'not described' }
            Record 'langfuse.chrome' 'WARN' "Langfuse UI did not load in $browser" "participant saw: $seen" "The browser may use a different proxy or web filter. Ask IT to allow $url. $Fallback"
            return
        }
        if ($answer -eq 's' -or $answer -eq 'skip') {
            Record 'langfuse.chrome' 'SKIP' 'Chrome UI check skipped by participant'
            return
        }
        Write-Host '  Please type y, n or s.'
    }
    Record 'langfuse.chrome' 'SKIP' 'Chrome UI check not answered'
}

# ---------------------------------------------------------------- python
function Find-Python {
    $probe = "import sys; print('%d.%d.%d|%s' % (sys.version_info[:3] + (sys.executable,)))"
    $candidates = New-Object System.Collections.ArrayList
    if (Get-Command 'py.exe' -ErrorAction SilentlyContinue) {
        Invoke-Logged 'py.exe' @('-0p') 20
        foreach ($minor in 14, 13, 12, 11, 10) { $null = $candidates.Add(@('py.exe', "-3.$minor")) }
        $null = $candidates.Add(@('py.exe', '-3'))
    }
    foreach ($name in 'python.exe', 'python3.exe', 'python3') {
        foreach ($cmd in @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)) { $null = $candidates.Add(@($cmd.Source)) }
    }
    foreach ($pattern in "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe", "$env:USERPROFILE\anaconda3\python.exe", "$env:USERPROFILE\miniconda3\python.exe", "$env:ProgramData\anaconda3\python.exe", "$env:ProgramData\miniconda3\python.exe") {
        foreach ($item in @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue)) { $null = $candidates.Add(@($item.FullName)) }
    }

    $best = -99999999
    $script:PyScore = -1
    $script:PyExe = ''
    $script:PyVersion = ''
    foreach ($candidate in $candidates) {
        $list = @($candidate)
        $argsToUse = @()
        if ($list.Count -gt 1) { $argsToUse = @($list[1]) }
        $argsToUse += @('-c', $probe)
        # The Microsoft Store stub prints "Python was not found" and fails this parse.
        Invoke-Logged $list[0] $argsToUse 20
        if ($LastRc -ne 0) { continue }
        $found = Last-Line $LastStdout
        if ($found -notmatch '^(\d+)\.(\d+)\.(\d+)\|(.+)$') { continue }
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        $score = $major * 10000 + $minor * 100 + [int]$Matches[3]
        # The workshop targets 3.12, and brand-new versions can lack wheels for pinned packages.
        $rank = -1
        if ($major -eq 3) {
            $rank = 0
            if ($minor -eq 12) { $rank = 5 }
            elseif ($minor -eq 13) { $rank = 4 }
            elseif ($minor -eq 11) { $rank = 3 }
            elseif ($minor -eq 10) { $rank = 2 }
            elseif ($minor -gt 13) { $rank = 1 }
        }
        $ranked = $rank * 1000000 + $score
        if ($ranked -gt $best) {
            $best = $ranked
            $script:PyScore = $score
            $script:PyVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
            $script:PyExe = $Matches[4]
        }
    }
}

function Check-Python {
    Write-Section 'Python, pip and Jupyter'
    Find-Python
    if (-not $PyExe) {
        $script:MissingTools += ' Python'
        Record 'python.version' 'FAIL' 'Python not found' '' 'Install Python 3.10+ from python.org or through IT, and tick "Add to PATH". Required for all hands-on code.'
        Record 'python.helper' 'SKIP' 'pip, package, OpenAI SDK and Jupyter checks not run' 'they need Python'
        return
    }
    if ($PyScore -ge 31000) {
        Record 'python.version' 'PASS' "Python $PyVersion" $PyExe
    } else {
        Record 'python.version' 'FAIL' "Python $PyVersion is too old" $PyExe 'Install Python 3.10+ from python.org or through IT. Required for all hands-on code.'
    }
    if ($PyScore -lt 30700) {
        Record 'python.helper' 'SKIP' 'Python-level checks skipped' 'this Python is too old to run them'
        return
    }
    $env:PF_WORK = $WorkDir
    $env:PF_RESULTS = $Results
    $env:PF_LOG = $LogFile
    $env:PF_PIP_INDEX_URL = $Cfg.PIP_INDEX_URL
    $env:PF_PIP_PACKAGES = $Cfg.PIP_PACKAGES
    $env:PF_OPENAI_BASE_URL = $Cfg.OPENAI_BASE_URL
    $env:PF_OPENAI_MODEL = $Cfg.OPENAI_MODEL
    $env:PF_OPENAI_API_KEY = $OpenAiKey
    $env:PF_LANGFUSE_HOST = $Cfg.LANGFUSE_HOST
    $env:PYTHONIOENCODING = 'utf-8'
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'

    # stdout stays on the console for live progress; stderr goes to the report for any traceback.
    $errFile = Join-Path $WorkDir 'helper_stderr.txt'
    $helper = Quote-Arg (Join-Path $Here 'preflight_checks.py')
    try {
        $proc = Start-Process -FilePath $PyExe -ArgumentList $helper -NoNewWindow -PassThru -RedirectStandardError $errFile -ErrorAction Stop
        $null = $proc.Handle
        Wait-Process -Id $proc.Id -Timeout 4200 -ErrorAction SilentlyContinue
        if (-not $proc.HasExited) {
            $null = & taskkill.exe /T /F /PID $proc.Id 2>&1
            Record 'python.helper' 'FAIL' 'Python checks timed out' '70 minutes' 'The checks finished so far are in the report.'
        } elseif ($proc.ExitCode -ne 0) {
            Record 'python.helper' 'FAIL' 'Python checks stopped unexpectedly' "exit $($proc.ExitCode)" 'The remaining checks still run. The traceback is in the diagnostics.'
        }
    } catch {
        Record 'python.helper' 'FAIL' 'Python checks could not start' $_.Exception.Message 'Endpoint security may be blocking Python.'
    }
    if (Test-Path -LiteralPath $errFile) { Write-Log ([string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)) }
    Remove-Item Env:PF_OPENAI_API_KEY -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- git
function Check-Git {
    Write-Section 'Git and GitHub'
    $fallback = 'Fallback: the code is shared as a zip and the CI/CD gate is an instructor demo.'
    $gitCmd = Get-Command 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $gitExe = ''
    if ($gitCmd) { $gitExe = $gitCmd.Source }
    elseif (Test-Path -LiteralPath "$env:ProgramFiles\Git\cmd\git.exe") { $gitExe = "$env:ProgramFiles\Git\cmd\git.exe" }
    if (-not $gitExe) {
        $script:MissingTools += ' Git'
        Record 'git.install' 'WARN' 'Git not installed' '' "Install Git, or ask IT to. $fallback"
        return
    }
    Invoke-Logged $gitExe @('--version') 20
    Record 'git.install' 'PASS' (Last-Line $LastStdout) $gitExe
    Invoke-Logged $gitExe @('config', '--global', '--get-regexp', '^(http|https|core\.sshcommand|url)\.') 20
    $env:GIT_TERMINAL_PROMPT = '0'
    Invoke-Logged $gitExe @('ls-remote', $Cfg.GIT_REPO_URL, 'HEAD') 60
    if ($LastRc -eq 0) {
        Record 'git.remote' 'PASS' 'Git can reach the repo' $Cfg.GIT_REPO_URL
    } else {
        Record 'git.remote' 'WARN' 'Cannot reach the Git repo' (Last-Line $LastText) "Check for a certificate, proxy or access error in the diagnostics. $fallback"
    }
    $cloneDir = Join-Path $WorkDir 'clone_test'
    Invoke-Logged $gitExe @('clone', '--depth', '1', $Cfg.GIT_REPO_URL, $cloneDir) 240
    if ($LastRc -eq 0 -and (Test-Path -LiteralPath (Join-Path $cloneDir '.git'))) {
        Record 'git.clone' 'PASS' 'Workshop repo cloned' $Cfg.GIT_REPO_URL
    } else {
        Record 'git.clone' 'WARN' 'Git clone failed' (Last-Line $LastText) $fallback
    }
}

# ---------------------------------------------------------------- IDE
function Find-Tool([string]$CommandName, [string[]]$Paths) {
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($path in $Paths) { if (Test-Path -LiteralPath $path) { return $path } }
    return ''
}

function Check-OneIde([string]$Label, [string]$Id, [string]$Tool) {
    Invoke-Logged $Tool @('--version') 30
    if ($LastRc -ne 0) {
        Record "ide.$Id" 'WARN' "$Label is installed but its command failed" "exit $LastRc" 'Open it once to finish setup.'
        return
    }
    Invoke-Logged $Tool @('--list-extensions') 45
    $missing = @()
    foreach ($extension in 'ms-python.python', 'ms-toolsai.jupyter') {
        if ($LastStdout -notmatch [regex]::Escape($extension)) { $missing += $extension }
    }
    if ($missing.Count -eq 0) {
        Record "ide.$Id" 'PASS' "$Label with Python and Jupyter extensions"
    } else {
        Record "ide.$Id" 'WARN' "$Label is missing extensions" ($missing -join ' ') 'Install them from the Extensions panel. Fallback: JupyterLab.'
    }
}

function Check-Ide {
    Write-Section 'IDE'
    $code = Find-Tool 'code.cmd' @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd", "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd")
    $cursor = Find-Tool 'cursor.cmd' @("$env:LOCALAPPDATA\Programs\cursor\resources\app\bin\cursor.cmd", "$env:ProgramFiles\Cursor\resources\app\bin\cursor.cmd")
    if ($code) { Check-OneIde 'VS Code' 'vscode' $code }
    if ($cursor) { Check-OneIde 'Cursor' 'cursor' $cursor }
    if (-not $code -and -not $cursor) {
        $script:MissingTools += ' IDE'
        Record 'ide.install' 'WARN' 'Neither VS Code nor Cursor found' '' 'Install one, or ask IT to. Fallback: JupyterLab through pip.'
    }
}

# ---------------------------------------------------------------- docker
function Docker-Hint([string]$Text) {
    if ($Text -match 'x509|certificate signed by unknown|tls: failed to verify') { return "Docker does not trust the corporate TLS inspection certificate. Add the root CA to Windows' trusted roots and restart Docker, or ask IT." }
    if ($Text -match 'toomanyrequests|rate limit') { return "Docker Hub's rate limit was reached, which is common on a shared office IP. Run docker login, or use a mirror." }
    if ($Text -match 'proxyconnect|407|proxy') { return "Docker's proxy setup failed. Set the proxy under Docker Desktop > Settings > Resources > Proxies." }
    if ($Text -match 'i/o timeout|context deadline|TLS handshake timeout|no such host|connection refused|connection reset') { return "Docker cannot reach Docker Hub. Allow registry-1.docker.io, auth.docker.io and production.cloudflare.docker.com, or set Docker's proxy." }
    if ($Text -match 'denied|unauthorized|not allowed|pull access') { return 'Docker Hub refused access, possibly from a registry policy. Ask IT, or use an approved image.' }
    if ($Text -match 'no space left') { return 'Docker is out of disk space. Run docker system prune or increase its disk limit.' }
    return 'See the Docker output in the diagnostics.'
}

function Check-Docker {
    Write-Section 'Docker'
    $fallback = 'Fallback: the build and run are an instructor demo.'
    if ($SkipDocker) { Record 'docker.install' 'SKIP' 'Docker checks skipped' '-SkipDocker was used'; return }
    $script:DockerExe = Find-Tool 'docker' @("$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe", "$env:USERPROFILE\.rd\bin\docker.exe")
    if (-not $DockerExe) {
        $script:MissingTools += ' Docker'
        foreach ($name in 'podman', 'nerdctl') { if (Get-Command $name -ErrorAction SilentlyContinue) { Write-Log "Found alternative container tool: $name" } }
        Record 'docker.install' 'WARN' 'Docker not installed' '' "Install Docker Desktop or the approved equivalent, or ask IT to. $fallback"
        Record 'docker.pull' 'SKIP' 'Docker image and container checks not run' 'Docker is not installed'
        return
    }
    Invoke-Logged $DockerExe @('--version') 20
    Record 'docker.install' 'PASS' (Last-Line $LastStdout) $DockerExe
    Invoke-Logged $DockerExe @('context', 'ls') 20

    # Docker Desktop on Windows depends on WSL2 and firmware virtualization.
    $env:WSL_UTF8 = '1'
    Invoke-Logged 'wsl.exe' @('--status') 20
    Invoke-Logged 'wsl.exe' @('-l', '-v') 20
    Write-Log (Get-Service -Name 'com.docker.service', 'vmcompute', 'LxssManager' -ErrorAction SilentlyContinue | Out-String)

    Invoke-Logged $DockerExe @('version') 30
    if ($LastRc -ne 0 -and -not $AssumeYes) {
        if (Ask-Yes '  Docker is installed but not running. Start Docker Desktop, wait for it to be ready, then retry? [Y/n]' 'y') {
            Invoke-Logged $DockerExe @('version') 30
        }
    }
    if ($LastRc -ne 0) {
        Record 'docker.daemon' 'WARN' 'Docker engine is not running' "exit $LastRc" "Start Docker Desktop and re-run. If it will not start, check WSL2 and BIOS virtualization in the diagnostics. $fallback"
        Record 'docker.pull' 'SKIP' 'Docker image and container checks not run' 'the Docker engine is not running'
        return
    }
    Record 'docker.daemon' 'PASS' 'Docker engine is running'
    Invoke-Logged $DockerExe @('info') 30

    $testImage = $Cfg.DOCKER_TEST_IMAGE
    $baseImage = $Cfg.DOCKER_BASE_IMAGE
    Invoke-Logged $DockerExe @('image', 'inspect', $testImage) 20
    $hadTest = ($LastRc -eq 0)
    Write-Progress2 "Pulling $testImage"
    Invoke-Logged $DockerExe @('pull', $testImage) 240
    if ($LastRc -eq 0) {
        Record 'docker.pull' 'PASS' 'Image pull from Docker Hub works' $testImage
        Invoke-Logged $DockerExe @('run', '--rm', $testImage) 90
        if ($LastRc -eq 0) { Record 'docker.run' 'PASS' 'Containers can run' $testImage }
        else { Record 'docker.run' 'WARN' 'Container failed to run' "exit $LastRc" ((Docker-Hint $LastText) + " $fallback") }
        if (-not $hadTest) { Invoke-Logged $DockerExe @('rmi', $testImage) 30 }
    } else {
        Record 'docker.pull' 'WARN' 'Cannot pull images from Docker Hub' "$testImage, exit $LastRc" ((Docker-Hint $LastText) + " $fallback")
        Record 'docker.run' 'SKIP' 'Container run not tested' 'the test image could not be pulled'
    }

    Write-Progress2 "Pulling $baseImage (may take a few minutes). It stays on the laptop to save time on the day."
    Invoke-Logged $DockerExe @('pull', $baseImage) 480
    if ($LastRc -eq 0) {
        Record 'docker.base' 'PASS' 'Base image pulled' $baseImage
    } else {
        Record 'docker.base' 'WARN' 'Cannot pull the base image' "$baseImage, exit $LastRc" ((Docker-Hint $LastText) + " $fallback")
    }

    Write-Progress2 'Building a test image, including pip install inside the build'
    $env:PIP_INDEX_URL = $Cfg.PIP_INDEX_URL
    $buildArgs = @('build', '--no-cache', '--progress=plain', '--build-arg', "BASE_IMAGE=$baseImage", '--build-arg', 'PIP_INDEX_URL')
    if ($ProxyEffective) { $buildArgs += @('--build-arg', 'HTTP_PROXY', '--build-arg', 'HTTPS_PROXY', '--build-arg', 'NO_PROXY') }
    $buildArgs += @('-t', 'workshop-preflight-probe', (Join-Path $Here 'docker_probe'))
    Invoke-Logged $DockerExe $buildArgs 420
    if ($LastRc -ne 0) {
        Record 'docker.build' 'WARN' 'Docker build failed' "exit $LastRc" ((Docker-Hint $LastText) + " If only pip failed, containers do not trust the corporate CA or lack the proxy. $fallback")
        Record 'docker.network' 'SKIP' 'Container network not tested' 'it needs the test image, which did not build'
        return
    }
    Record 'docker.build' 'PASS' 'Docker build with pip install works'

    $runArgs = @('run', '--rm')
    if ($ProxyEffective) { $runArgs += @('-e', 'HTTP_PROXY', '-e', 'HTTPS_PROXY', '-e', 'NO_PROXY') }
    $runArgs += @('workshop-preflight-probe', "$($Cfg.OPENAI_BASE_URL)/models", "$($Cfg.LANGFUSE_HOST)/api/public/health")
    Invoke-Logged $DockerExe $runArgs 120
    if ($LastRc -eq 0) {
        Record 'docker.network' 'PASS' 'Containers can reach OpenAI and Langfuse'
    } else {
        $failLine = @($LastText -split "`r?`n" | Where-Object { $_ -match '^FAIL' })
        $firstFail = $(if ($failLine.Count -gt 0) { $failLine[0] } else { "exit $LastRc" })
        Record 'docker.network' 'WARN' 'Container cannot reach OpenAI or Langfuse' $firstFail "Containers may lack the corporate CA or proxy, or a firewall may block them. $fallback"
    }
}

function Check-InstallRights {
    if (-not $IsAdminUser -and $MissingTools) {
        Write-Section 'Install rights'
        Record 'sys.installs' 'WARN' "IT must install:$MissingTools" 'this account has no admin rights' 'Installs are the most common day-of blocker, so request these before the workshop.'
    }
}

# ---------------------------------------------------------------- main
$ExitCode = 3
try {
    Write-Host 'Workshop laptop preflight' -ForegroundColor White
    Write-Host 'Checks that this laptop is ready for the workshop. Takes about 5-15 minutes.'
    Write-Host 'It installs nothing system-wide: Python packages go in a temporary folder that is'
    Write-Host 'deleted at the end. Docker may keep one downloaded base image, to save time on the day.'
    Write-Host 'It ends by writing a report file to send to your instructor. API keys are never included.'

    Invoke-Check 'settings' { Configure }
    Invoke-Check 'laptop' { Check-System }
    Invoke-Check 'terminal' { Check-Terminal }
    Invoke-Check 'network' { Check-Network }
    Invoke-Check 'openai' { Check-OpenAiApi }
    Invoke-Check 'langfuse' { Check-Langfuse }
    Invoke-Check 'python' { Check-Python }
    Invoke-Check 'git' { Check-Git }
    Invoke-Check 'ide' { Check-Ide }
    Invoke-Check 'docker' { Check-Docker }
    Invoke-Check 'rights' { Check-InstallRights }

    $Interrupted = $false
    $ExitCode = $(if ((Count-Status 'FAIL') -gt 0) { 1 } else { 0 })
} catch {
    Write-Host "Preflight stopped early: $($_.Exception.Message)" -ForegroundColor Red
    Write-Log "UNHANDLED ERROR: $($_ | Out-String)"
} finally {
    if ($DockerExe) { $null = & $DockerExe rmi -f workshop-preflight-probe 2>&1 }
    Write-Report
    Write-Section 'Result'
    Write-Host "  Verdict: $(Get-Verdict)" -ForegroundColor White
    Write-Host "  PASS $(Count-Status 'PASS') | WARN $(Count-Status 'WARN') | FAIL $(Count-Status 'FAIL') | SKIP $(Count-Status 'SKIP')"
    Write-Host ''
    Write-Host '  Report saved to:'
    Write-Host "  $Report"
    Write-Host ''
    Write-Host '  Please send this file to your instructor.'
    if (-not $AssumeYes) { Start-Process 'explorer.exe' -ArgumentList "/select,`"$Report`"" -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
exit $ExitCode
