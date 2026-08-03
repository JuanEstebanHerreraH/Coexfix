# =====================================================================
#  CoexFix - Diagnostico WiFi + Bluetooth
#  Solo LEE informacion. No modifica nada.
#
#  El informe se escribe en el Escritorio y se actualiza despues de
#  CADA seccion. Si el script falla, el archivo muestra hasta donde
#  llego y cual fue el error.
# =====================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# Rutas absolutas: funcionan aunque el PATH este danado
$SYS      = "$env:SystemRoot\System32"
$NETSH    = "$SYS\netsh.exe"
$POWERCFG = "$SYS\powercfg.exe"
$NOTEPAD  = "$SYS\notepad.exe"

# --- Ubicacion del informe -------------------------------------------
$esc = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($esc) -or -not (Test-Path $esc)) {
    $esc = Join-Path $env:USERPROFILE 'Desktop'
}
if (-not (Test-Path $esc)) { $esc = $env:USERPROFILE }
$salida = Join-Path $esc ("CoexFix_informe_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm'))

# --- Acumulador ------------------------------------------------------
$script:R = New-Object System.Collections.ArrayList

function L   { param($t) [void]$script:R.Add([string]$t) }
function T   { param($t) L ''; L ('=' * 68); L "  $t"; L ('=' * 68) }
function SUB { param($t) L ''; L "--- $t ---" }

function Flush {
    try { Set-Content -LiteralPath $salida -Value $script:R -Encoding UTF8 -Force }
    catch { Write-Host "   No se pudo escribir el informe: $($_.Exception.Message)" -ForegroundColor Red }
}

# Ejecuta una seccion aislada: si falla, lo anota y sigue
function Seccion {
    param([string]$Titulo, [int]$Num, [int]$Total, [scriptblock]$Cuerpo)
    Write-Host ("   [{0}/{1}] {2}" -f $Num, $Total, $Titulo) -ForegroundColor DarkGray
    T "$Num. $Titulo"
    try { & $Cuerpo }
    catch {
        L ''
        L ">>> ERROR EN ESTA SECCION"
        L "    $($_.Exception.GetType().Name): $($_.Exception.Message)"
        L "    Linea: $($_.InvocationInfo.ScriptLineNumber)"
        Write-Host "        error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Flush
}

# --- Inicio ----------------------------------------------------------
Clear-Host
Write-Host ''
Write-Host '   CoexFix - DIAGNOSTICO' -ForegroundColor Cyan
Write-Host '   Solo lectura. No modifica el sistema.' -ForegroundColor DarkGray
Write-Host ''

$admin = $false
try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

L 'CoexFix - INFORME DE DIAGNOSTICO WIFI + BLUETOOTH'
L "Generado : $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
L "Equipo   : $env:COMPUTERNAME"
L "Usuario  : $env:USERNAME"
L "Admin    : $(if ($admin) { 'SI' } else { 'NO - secciones incompletas' })"
L "PSVersion: $($PSVersionTable.PSVersion)"
Flush

$TOT = 11

# ===================== 1. SISTEMA ====================================
Seccion 'SISTEMA' 1 $TOT {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    L "Sistema       : $($os.Caption)"
    L "Version       : $($os.Version) (build $($os.BuildNumber))"
    L "Arquitectura  : $($os.OSArchitecture)"
    L "Equipo        : $($cs.Manufacturer) $($cs.Model)"
    L "Ultimo inicio : $($os.LastBootUpTime)"
    L "Encendido hace: $([int]((Get-Date) - $os.LastBootUpTime).TotalHours) horas"
}

# ===================== 2. PATH =======================================
$script:faltaPath = @()
Seccion 'SALUD DEL ENTORNO (PATH)' 2 $TOT {
    L 'Un PATH danado impide instalar drivers y rompe herramientas.'
    L ''
    $maq = [Environment]::GetEnvironmentVariable('Path','Machine')
    $usr = [Environment]::GetEnvironmentVariable('Path','User')
    L "Longitud PATH de sistema : $($maq.Length) caracteres"
    L "Longitud PATH de usuario : $($usr.Length) caracteres"
    L "Longitud combinada       : $($maq.Length + $usr.Length) caracteres"
    if (($maq.Length + $usr.Length) -gt 1900) {
        L '>>> El PATH combinado se acerca al limite de Windows (~2047).'
        L '>>> Puede truncarse y romper comandos. Conviene limpiar'
        L '>>> entradas duplicadas del PATH de usuario.'
    }
    L ''
    foreach ($r in @("$env:SystemRoot\system32", "$env:SystemRoot",
                     "$env:SystemRoot\System32\WindowsPowerShell\v1.0")) {
        if ($maq -notmatch [regex]::Escape($r)) { $script:faltaPath += $r }
    }
    if ($script:faltaPath.Count -gt 0) {
        L '>>> FALTAN estas rutas en el PATH del sistema:'
        foreach ($f in $script:faltaPath) { L "      $f" }
        L ''
        L '    Reparar en: sysdm.cpl > Opciones avanzadas >'
        L '    Variables de entorno > Variables del sistema > Path'
    } else {
        L 'PATH del sistema: correcto.'
    }
    SUB 'PATH de sistema completo'
    foreach ($p in ($maq -split ';')) { if ($p) { L "  $p" } }
}

# ===================== 3. ADAPTADORES ================================
Seccion 'ADAPTADORES DE RED' 3 $TOT {
    $hoy = Get-Date
    $ads = Get-NetAdapter -IncludeHidden | Where-Object { $_.HardwareInterface }
    if (-not $ads) { L 'No se detectaron adaptadores fisicos.'; return }
    foreach ($a in $ads) {
        SUB $a.Name
        L "Descripcion   : $($a.InterfaceDescription)"
        L "Estado        : $($a.Status)"
        L "Tipo          : $($a.PhysicalMediaType)"
        L "MAC           : $($a.MacAddress)"
        L "Velocidad     : $($a.LinkSpeed)"
        L "Driver        : $($a.DriverVersion) ($($a.DriverProvider))"
        L "Fecha driver  : $($a.DriverDate)"
        L "Archivo       : $($a.DriverFileName)"
        if ($a.DriverDate) {
            $d = ($hoy - [datetime]$a.DriverDate).Days
            L "Antiguedad    : $([int]($d/365)) anios ($d dias)"
            if ($d -gt 1095) { L '>>> Driver de mas de 3 anios. Candidato a actualizar.' }
        }
    }
}

# ===================== 4. CONEXION WIFI ==============================
Seccion 'CONEXION WIFI ACTUAL' 4 $TOT {
    L 'Canales 1-14 = 2.4 GHz  |  Canal 36 o mayor = 5 GHz'
    L ''
    if (-not (Test-Path $NETSH)) { L "No se encontro netsh.exe en $NETSH"; return }
    $o = & $NETSH wlan show interfaces 2>&1
    if ($o) { foreach ($l in $o) { L $l } } else { L 'Sin salida de netsh.' }
}

# ===================== 5. REDES VISIBLES =============================
Seccion 'REDES VISIBLES - HAY 5 GHz?' 5 $TOT {
    if (-not (Test-Path $NETSH)) { L 'netsh.exe no disponible.'; return }
    $o = & $NETSH wlan show networks mode=bssid 2>&1
    $txt = ($o -join "`n")
    if ($txt.Trim().Length -lt 10) {
        L 'Sin resultados. Causas posibles:'
        L '  - Servicios de ubicacion desactivados (Windows los exige).'
        L '    Configuracion > Privacidad > Ubicacion.'
        L '  - Sin adaptador WiFi activo.'
        return
    }
    foreach ($l in $o) { L $l }
    SUB 'Resumen de bandas'
    $ch = [regex]::Matches($txt, '(?im)^\s*(?:Canal|Channel)\s*:\s*(\d+)') |
          ForEach-Object { [int]$_.Groups[1].Value }
    if (-not $ch) { L 'No se pudieron extraer canales.'; return }
    $c24 = @($ch | Where-Object { $_ -le 14 }).Count
    $c5  = @($ch | Where-Object { $_ -ge 32 }).Count
    L "Redes en 2.4 GHz : $c24"
    L "Redes en 5 GHz   : $c5"
    L ''
    if ($c5 -eq 0) {
        L '>>> No se detecto ninguna red de 5 GHz.'
        L '>>> O el adaptador no soporta 5 GHz, o no hay routers de'
        L '>>> 5 GHz al alcance.'
    } else {
        L '>>> El adaptador SI ve redes de 5 GHz.'
        L '>>> Revisar arriba si alguna es el router propio.'
    }
}

# ===================== 6. BLUETOOTH ==================================
Seccion 'BLUETOOTH' 6 $TOT {
    $bt = Get-PnpDevice -Class Bluetooth
    if (-not $bt) { L 'No se detectaron dispositivos Bluetooth.'; return }
    $act = @($bt | Where-Object { $_.Status -eq 'OK' })
    $fan = @($bt | Where-Object { $_.Status -ne 'OK' })
    SUB 'Activos'
    foreach ($d in $act) { L "[OK] $($d.FriendlyName)"; L "     $($d.InstanceId)" }
    if ($fan.Count -gt 0) {
        SUB 'Fantasma / desconectados'
        L 'Registrados pero ausentes. Pueden generar conflictos si se'
        L 'reconectan junto a otro adaptador.'
        L ''
        foreach ($d in $fan) { L "[$($d.Status)] $($d.FriendlyName)"; L "     $($d.InstanceId)" }
    }
    SUB 'Adaptadores fisicos'
    $rad = @($act | Where-Object { $_.InstanceId -like 'USB*' -or $_.InstanceId -like 'PCI*' })
    L "Activos detectados: $($rad.Count)"
    if ($rad.Count -gt 1) {
        L '>>> Hay mas de un adaptador Bluetooth ACTIVO.'
        L '>>> Dos stacks simultaneos causan conflictos. Desactivar uno.'
    }
}

# ===================== 7. USB ========================================
Seccion 'CONTROLADORAS Y DISPOSITIVOS USB' 7 $TOT {
    foreach ($c in (Get-CimInstance Win32_USBController)) { L $c.Name }
    SUB 'Radios conectadas por USB'
    $rad = @(Get-PnpDevice | Where-Object {
        $_.InstanceId -like 'USB*' -and $_.Status -eq 'OK' -and
        $_.FriendlyName -match 'Bluetooth|Wireless|WLAN|802\.11|Realtek|Ralink|MediaTek|Atheros|Broadcom|Qualcomm'
    })
    if ($rad.Count -eq 0) { L 'Ninguna. WiFi y/o Bluetooth son internos (PCIe).'; return }
    foreach ($d in $rad) { L $d.FriendlyName; L "     $($d.InstanceId)" }
    if ($rad.Count -ge 2) {
        L ''
        L '>>> Dos o mas radios en USB. Si son WiFi y Bluetooth separados,'
        L '>>> la interferencia mutua es probable. Separarlos fisicamente'
        L '>>> con un alargue USB ayuda.'
    }
}

# ===================== 8. ENERGIA ====================================
$script:nEnergia = 0
Seccion 'AHORRO DE ENERGIA USB' 8 $TOT {
    L 'Windows puede suspender dispositivos por su cuenta. Es una causa'
    L 'frecuente de cortes al activar Bluetooth.'
    L ''
    L 'Hay DOS mecanismos independientes y pueden discrepar:'
    L '  WMI      : la casilla "Permitir que el equipo apague este'
    L '             dispositivo". Algunos drivers la reimponen al'
    L '             reiniciar.'
    L '  Registro : PnPCapabilities. Valor 24 (0x18) desactiva la'
    L '             administracion de energia a nivel de driver y'
    L '             oculta la pestana. Es el mecanismo duradero.'
    L ''
    L 'Un dispositivo esta protegido si CUALQUIERA de los dos lo indica.'
    L ''

    # --- Mapa de PnPCapabilities por nombre de driver ---
    $capsPorDesc = @{}
    $claseNet = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $claves = @(Get-ChildItem $claseNet -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^\d{4}$' })
    foreach ($k in $claves) {
        $prop = $null
        try { $prop = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue } catch { }
        if ($prop -and $prop.DriverDesc -and $null -ne $prop.PSObject.Properties['PnPCapabilities']) {
            $d = ([string]$prop.DriverDesc).Trim()
            $capsPorDesc[$d] = [int]$prop.PnPCapabilities
        }
    }
    L "Claves de registro con PnPCapabilities: $($capsPorDesc.Count)"
    L ''

    $virtual = 'OpenVPN|WAN Miniport|TAP-|TAP Adapter|Kernel Debug|Wi-Fi Direct|Virtual Adapter|Loopback|VPN|Wintun|NordLynx|TeamViewer|Hyper-V|VMware|VirtualBox|Npcap|Pseudo'
    $pw = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop
    $todos = Get-PnpDevice
    $desacuerdos = 0
    $listaVirt = New-Object System.Collections.ArrayList
    foreach ($p in $pw) {
        $id  = $p.InstanceName -replace '_0$',''
        $dev = $todos | Where-Object { $_.InstanceId -eq $id }
        if ($dev -and $dev.Class -in @('Net','Bluetooth','USB') -and $dev.FriendlyName -match $virtual) {
            [void]$listaVirt.Add($dev.FriendlyName)
        }
        elseif ($dev -and $dev.Class -in @('Net','Bluetooth','USB')) {
            $nombre = $dev.FriendlyName
            $norm   = ($nombre -replace '\s*#\d+\s*$','').Trim()
            $cap    = $null
            if ($capsPorDesc.ContainsKey($norm)) { $cap = $capsPorDesc[$norm] }

            $wmiProtege = (-not $p.Enable)
            # El bit 0x10 (16) es el que desactiva la administracion de
            # energia. 24 = 16 + 8 es el valor habitual.
            $regProtege = ($null -ne $cap -and ($cap -band 16) -eq 16)

            $txtReg = if ($null -eq $cap) { 'sin valor' } else { "PnPCap=$cap" }
            $txtWmi = if ($wmiProtege) { 'protegido' } else { 'puede apagarse' }

            if ($wmiProtege -or $regProtege) {
                $estado = 'PROTEGIDO     '
            } else {
                $estado = 'PUEDE APAGARSE'
                $script:nEnergia++
            }
            if ($wmiProtege -ne $regProtege -and $null -ne $cap) { $desacuerdos++ }
            L ("{0}  {1}" -f $estado, $nombre)
            L ("                 WMI: {0}  |  Registro: {1}" -f $txtWmi, $txtReg)
        }
    }
    if ($listaVirt.Count -gt 0) {
        SUB 'Adaptadores virtuales (no se cuentan)'
        L 'No tienen administracion de energia real. Son VPN, WAN'
        L 'Miniport, Wi-Fi Direct y similares. No afectan al problema.'
        L ''
        foreach ($v in $listaVirt) { L "  $v" }
    }
    L ''
    L "Dispositivos fisicos desprotegidos por AMBOS mecanismos: $script:nEnergia"
    if ($desacuerdos -gt 0) {
        L ''
        L ">>> $desacuerdos dispositivos con los dos mecanismos en desacuerdo."
        L '>>> Es normal: algunos drivers reimponen el valor WMI al'
        L '>>> reiniciar, pero el registro sigue vigente. Se puede'
        L '>>> confirmar en el Administrador de dispositivos: si la'
        L '>>> pestana "Administracion de energia" no aparece, el'
        L '>>> ajuste esta aplicado.'
    }

    SUB 'Suspension selectiva de USB'
    if (-not (Test-Path $POWERCFG)) { L 'powercfg.exe no disponible.'; return }
    $q = & $POWERCFG /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 2>&1
    $hex = @([regex]::Matches(($q -join "`n"), '(?i):\s*0x([0-9a-f]+)') | ForEach-Object { $_.Groups[1].Value })
    if ($hex.Count -ge 1) {
        if ($hex[0] -match '^0+$') { L 'Estado: DESHABILITADA (correcto)' }
        else { L 'Estado: HABILITADA >>> conviene desactivarla' }
    } else { foreach ($l in $q) { L $l } }
}

# ===================== 9. PROPIEDADES AVANZADAS ======================
Seccion 'PROPIEDADES AVANZADAS DEL WIFI' 9 $TOT {
    $ws = @(Get-NetAdapter | Where-Object { $_.PhysicalMediaType -match '802.11|Native' })
    if ($ws.Count -eq 0) { L 'No hay adaptadores WiFi activos.'; return }
    foreach ($w in $ws) {
        SUB $w.Name
        $props = Get-NetAdapterAdvancedProperty -Name $w.Name
        foreach ($p in $props) { L ("  {0,-42} = {1}" -f $p.DisplayName, $p.DisplayValue) }
        SUB "Analisis de $($w.Name)"
        $b = $props | Where-Object { $_.DisplayName -match 'Preferred Band|Banda preferida' }
        if ($b) {
            L "Banda preferida: $($b.DisplayValue)"
            if ($b.DisplayValue -match 'No Preference|Sin preferencia') {
                L '>>> Sin preferencia: el adaptador suele quedarse en 2.4 GHz.'
                L '>>> Si hay red de 5 GHz, conviene forzarla.'
            }
        } else { L 'Sin opcion de banda preferida en este driver.' }
        $c = $props | Where-Object { $_.DisplayName -match 'Collaboration|Coexist' }
        if ($c) { L "Coexistencia BT: $($c.DisplayValue)" }
        else { L 'Este driver NO expone Bluetooth Collaboration.' }
        $cw = $props | Where-Object { $_.DisplayName -match 'Channel Width|Ancho de canal' }
        foreach ($x in $cw) { L "Ancho de canal: $($x.DisplayName) = $($x.DisplayValue)" }
    }
}

# ===================== 10. DISPOSITIVOS CON ERROR ====================
$script:nError = 0
Seccion 'DISPOSITIVOS CON PROBLEMAS' 10 $TOT {
    $mal = @(Get-PnpDevice | Where-Object { $_.Status -eq 'Error' })
    $script:nError = $mal.Count
    if ($mal.Count -eq 0) { L 'Ningun dispositivo reporta error.'; return }
    foreach ($d in $mal) {
        $nm = if ($d.FriendlyName) { $d.FriendlyName } else { '(sin nombre)' }
        L "[ERROR] $nm"
        L "        $($d.InstanceId)"
        if ($d.InstanceId -match 'VEN_1022|AMDIF') { L '        >>> Chipset AMD. Falta el paquete AMD Chipset Drivers.' }
        if ($d.InstanceId -match 'VEN_8086')       { L '        >>> Chipset Intel. Falta Intel Chipset Software.' }
    }
}

# ===================== 11. EVENTOS ===================================
Seccion 'EVENTOS DE RED Y BLUETOOTH (7 dias)' 11 $TOT {
    $ev = @(Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddDays(-7); Level=2,3} -MaxEvents 500 -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match 'WLAN|Netwtw|rtw|Bth|Wlansvc|Tcpip|nwifi|BTHUSB|USB|Qcamain|athr' })
    if ($ev.Count -eq 0) { L 'Sin errores relevantes registrados.'; return }
    SUB 'Resumen'
    $ev | Group-Object ProviderName, Id | Sort-Object Count -Descending |
        Select-Object -First 15 | ForEach-Object { L ("{0,4} x  {1}" -f $_.Count, $_.Name) }
    SUB 'Detalle (ultimos 12)'
    foreach ($e in ($ev | Select-Object -First 12)) {
        L "$($e.TimeCreated) [$($e.ProviderName)] ID $($e.Id)"
        $m = ($e.Message -replace "`r`n",' ' -replace '\s+',' ')
        if ($m.Length -gt 190) { $m = $m.Substring(0,190) + '...' }
        L "   $m"
    }
    SUB 'Interpretacion'
    if ($ev | Where-Object { $_.Id -eq 4266 }) {
        L 'Tcpip 4266: agotamiento de puertos UDP. Alguna aplicacion abre'
        L 'sockets y no los libera. La red se cae hasta que se liberen.'
    }
    if ($ev | Where-Object { $_.Id -eq 4199 }) {
        L 'Tcpip 4199: conflicto de IP. Dos equipos con la misma direccion.'
        L 'Se corrige en el router, no en la PC.'
    }
}

# ===================== RESUMEN =======================================
T 'RESUMEN'
$avisos = @()
if ($script:faltaPath.Count -gt 0) { $avisos += "PATH del sistema incompleto ($($script:faltaPath.Count) rutas)" }
if ($script:nEnergia -gt 0)        { $avisos += "$script:nEnergia dispositivos con ahorro de energia activo" }
if ($script:nError -gt 0)          { $avisos += "$script:nError dispositivos con error (drivers faltantes)" }
if ($avisos.Count -gt 0) {
    L 'Puntos detectados:'
    foreach ($a in $avisos) { L "  - $a" }
    L ''
    L 'Varios se corrigen con CoexFix-Reparar.'
} else {
    L 'No se detectaron problemas evidentes de configuracion.'
}
L ''
L ('=' * 68)
L 'FIN DEL INFORME - CoexFix'
L ('=' * 68)
Flush

# --- Cierre ----------------------------------------------------------
Write-Host ''
Write-Host '   LISTO' -ForegroundColor Green
Write-Host "   Lineas escritas: $($script:R.Count)" -ForegroundColor DarkGray
Write-Host '   Informe guardado en:' -ForegroundColor White
Write-Host "   $salida" -ForegroundColor Yellow
Write-Host ''
if (Test-Path $NOTEPAD) { Start-Sleep -Seconds 1; Start-Process $NOTEPAD $salida }
