#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install','Machine','User')]
    [string]$Mode = 'Install'
)

# TIMENOW Corporate Visual Agent
# Instalacao inicial pelo Intune em contexto SYSTEM.
# Ajustes de repositorio e nomes dos arquivos ficam em config.json.

$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:ProgramData 'TIMENOW\CorporateVisual'
$AgentPath = Join-Path $Root 'TIMENOW-Agent.ps1'
$ConfigUrl = 'https://raw.githubusercontent.com/tiagomalvestio/ekko/main/config.json'
$ConfigPath = Join-Path $Root 'config.json'
$LogPath = Join-Path $Root 'agent.log'
$BgInfoExe = Join-Path $Root 'Bginfo64.exe'
$TaskMachine = 'TIMENOW-CorporateVisual-Machine'
$TaskUser = 'TIMENOW-CorporateVisual-User'

function Write-Log {
    param([string]$Message)
    try {
        $targetLog = if ($Mode -eq 'User') {
            Join-Path $env:LOCALAPPDATA 'TIMENOW\\CorporateVisual\\agent-user.log'
        } else {
            $LogPath
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $targetLog) -Force | Out-Null
        Add-Content -LiteralPath $targetLog -Encoding UTF8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Mode] $Message"
    } catch {}
}

function Get-Url {
    param([string]$Base,[string]$Relative)
    return ($Base.TrimEnd('/') + '/' + $Relative.TrimStart('/'))
}

function Download-File {
    param([string]$Url,[string]$Destination,[ValidateSet('Any','JpegPng','Zip')][string]$Type='Any')
    $temp = "$Destination.download"
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    try {
        $separator = if ($Url.Contains('?')) { '&' } else { '?' }
        Invoke-WebRequest -Uri ($Url + $separator + 't=' + [DateTime]::UtcNow.Ticks) -OutFile $temp -UseBasicParsing -TimeoutSec 90
        if (-not (Test-Path $temp) -or (Get-Item $temp).Length -lt 100) { throw 'Arquivo baixado vazio ou invalido.' }

        $bytes = [IO.File]::ReadAllBytes($temp)
        if ($Type -eq 'JpegPng') {
            $jpg = $bytes.Length -ge 3 -and $bytes[0] -eq 255 -and $bytes[1] -eq 216 -and $bytes[2] -eq 255
            $png = $bytes.Length -ge 8 -and $bytes[0] -eq 137 -and $bytes[1] -eq 80 -and $bytes[2] -eq 78 -and $bytes[3] -eq 71
            if (-not ($jpg -or $png)) { throw 'O arquivo recebido nao e uma imagem JPEG/PNG valida.' }
        }
        if ($Type -eq 'Zip' -and $bytes[0] -ne 80 -or $Type -eq 'Zip' -and $bytes[1] -ne 75) {
            throw 'O pacote ZIP baixado e invalido.'
        }

        $replace = $true
        if (Test-Path $Destination) {
            $oldHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            $newHash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
            $replace = $oldHash -ne $newHash
        }
        if ($replace) { Move-Item -LiteralPath $temp -Destination $Destination -Force }
        else { Remove-Item -LiteralPath $temp -Force }
        return $replace
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-Config {
    # Somente o modo Machine (SYSTEM) atualiza o config em ProgramData.
    # O modo User apenas le a copia local, pois usuarios comuns nao podem gravar em ProgramData.
    if ($Mode -eq 'Machine') {
        $null = Download-File -Url $ConfigUrl -Destination $ConfigPath
    }
    if (-not (Test-Path $ConfigPath)) { throw 'config.json ainda nao esta no cache. Aguarde o ciclo SYSTEM.' }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $cfg.repository.baseUrl) { throw 'config.json sem repository.baseUrl.' }
    return $cfg
}

function Ensure-BgInfo {
    if (Test-Path $BgInfoExe) {
        $sig = Get-AuthenticodeSignature -FilePath $BgInfoExe
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Microsoft Corporation') { return }
        Remove-Item $BgInfoExe -Force -ErrorAction SilentlyContinue
    }

    $zip = Join-Path $env:TEMP 'TIMENOW-BGInfo.zip'
    $extract = Join-Path $env:TEMP 'TIMENOW-BGInfo'
    try {
        Download-File -Url 'https://download.sysinternals.com/files/BGInfo.zip' -Destination $zip -Type Zip | Out-Null
        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $source = Join-Path $extract 'Bginfo64.exe'
        if (-not (Test-Path $source)) { throw 'Bginfo64.exe nao encontrado no pacote.' }
        $sig = Get-AuthenticodeSignature -FilePath $source
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
            throw 'A assinatura digital do BGInfo nao foi validada.'
        }
        Copy-Item -LiteralPath $source -Destination $BgInfoExe -Force
        Write-Log 'BGInfo instalado e assinatura Microsoft validada.'
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-Agent {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    if ($PSCommandPath -ne $AgentPath) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $AgentPath -Force
    }

    # SYSTEM: executa na inicializacao e a cada 6 horas.
    $ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $machineAction = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$AgentPath`" -Mode Machine"
    $machineTriggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(10) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 3650))
    )
    $systemPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskMachine -Action $machineAction -Trigger $machineTriggers -Principal $systemPrincipal -Settings $settings -Description 'Agente TIMENOW: atualiza os arquivos corporativos.' -Force | Out-Null

    # Usuário: aplica wallpaper e BGInfo no logon e a cada 6 horas.
    $userAction = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$AgentPath`" -Mode User"
    $userTriggers = @(
        (New-ScheduledTaskTrigger -AtLogOn),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(15) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 3650))
    )
    $userPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -LogonType Group -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskUser -Action $userAction -Trigger $userTriggers -Principal $userPrincipal -Settings $settings -Description 'Agente TIMENOW: aplica wallpaper e BGInfo na sessao do usuario.' -Force | Out-Null

    # Usuarios podem ler/executar; somente SYSTEM e Administradores alteram os arquivos.
    & icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-32-545:(OI)(CI)(RX)' | Out-Null
    Write-Log 'Agente instalado; tarefas SYSTEM e usuario registradas.'
}

function Invoke-Machine {
    $cfg = Get-Config
    $base = [string]$cfg.repository.baseUrl

    if ($cfg.assets.lockscreen.enabled) {
        $path = Join-Path $Root 'lockscreen.img'
        try {
            $changed = Download-File -Url (Get-Url $base $cfg.assets.lockscreen.path) -Destination $path -Type JpegPng
            Write-Log "Lock screen baixada. Alterada=$changed"
            # Personalization CSP: aplicavel a edicoes Windows suportadas (Enterprise/Education).
            $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
            New-Item -Path $key -Force | Out-Null
            New-ItemProperty -Path $key -Name LockScreenImagePath -Value $path -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $key -Name LockScreenImageUrl -Value $path -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $key -Name LockScreenImageStatus -Value 1 -PropertyType DWord -Force | Out-Null
        } catch { Write-Log "Falha lock screen: $($_.Exception.Message)" }
    }

    if ($cfg.assets.bginfo.enabled) {
        try {
            Ensure-BgInfo
            $bgi = Join-Path $Root 'TIMENOW.bgi'
            $changed = Download-File -Url (Get-Url $base $cfg.assets.bginfo.path) -Destination $bgi
            Write-Log "Configuracao BGInfo atualizada. Alterada=$changed"
        } catch { Write-Log "Falha BGInfo: $($_.Exception.Message)" }
    }

    if ($cfg.assets.wallpaper.enabled) {
        try {
            $wall = Join-Path $Root 'wallpaper.img'
            $changed = Download-File -Url (Get-Url $base $cfg.assets.wallpaper.path) -Destination $wall -Type JpegPng
            Write-Log "Wallpaper em cache atualizado. Alterado=$changed"
        } catch { Write-Log "Falha wallpaper: $($_.Exception.Message)" }
    }
}

function Invoke-User {
    $cfg = Get-Config
    $base = [string]$cfg.repository.baseUrl
    if ($cfg.assets.wallpaper.enabled) {
        try {
            $wallCache = Join-Path $Root 'wallpaper.img'
            $wallUser = Join-Path $env:LOCALAPPDATA 'TIMENOW\wallpaper.img'
            if (Test-Path $wallCache) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $wallUser) -Force | Out-Null
                Copy-Item -LiteralPath $wallCache -Destination $wallUser -Force
            } else {
                Download-File -Url (Get-Url $base $cfg.assets.wallpaper.path) -Destination $wallUser -Type JpegPng | Out-Null
            }

            Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $wallUser
            Add-Type @'
using System;
using System.Runtime.InteropServices;
public class TimenowWallpaper {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@ -ErrorAction SilentlyContinue
            [void][TimenowWallpaper]::SystemParametersInfo(20, 0, $wallUser, 3)
            Write-Log "Wallpaper aplicado para $env:USERNAME."
        } catch { Write-Log "Falha ao aplicar wallpaper: $($_.Exception.Message)" }
    }

    if ($cfg.assets.bginfo.enabled) {
        try {
            $bgi = Join-Path $Root 'TIMENOW.bgi'
            if ((Test-Path $BgInfoExe) -and (Test-Path $bgi)) {
                # Registra a aceitacao da EULA para o usuario atual; /accepteula nao e parametro do BGInfo.
                $eulaKey = 'HKCU:\\Software\\Sysinternals\\BGInfo'
                New-Item -Path $eulaKey -Force | Out-Null
                New-ItemProperty -Path $eulaKey -Name EulaAccepted -Value 1 -PropertyType DWord -Force | Out-Null
                Start-Process -FilePath $BgInfoExe -ArgumentList "`"$bgi`" /timer:0 /silent /nolicprompt" -WindowStyle Hidden
                Write-Log 'BGInfo iniciado na sessao do usuario.'
            } else {
                Write-Log 'BGInfo ou arquivo BGI ainda nao esta disponivel; sera tentado no proximo ciclo.'
            }
        } catch { Write-Log "Falha ao iniciar BGInfo: $($_.Exception.Message)" }
    }
}

try {
    switch ($Mode) {
        'Install' {
            Install-Agent
            & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $AgentPath -Mode Machine
        }
        'Machine' { Invoke-Machine }
        'User' { Invoke-User }
    }
} catch {
    Write-Log "ERRO FATAL: $($_.Exception.Message)"
    throw
}
