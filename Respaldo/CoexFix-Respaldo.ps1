# =====================================================================
#  CoexFix - Respaldo y Restauracion
#
#  Primera ejecucion  : crea un respaldo del estado actual.
#  Ejecuciones siguientes:
#     - Si nada cambio  -> avisa que no hace falta restaurar.
#     - Si algo cambio  -> muestra que cambio y ofrece restaurar.
#
#  Pensado para ejecutarse ANTES de CoexFix-Reparar, como red de
#  seguridad, y despues si algo salio mal.
# =====================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# Alinea la codificacion con la pagina de codigos de la consola.
# Sin esto, la salida acentuada de netsh y powercfg llega destrozada.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(
        [int](Get-Culture).TextInfo.OEMCodePage)
} catch { }

$SYS      = "$env:SystemRoot\System32"
$POWERCFG = "$SYS\powercfg.exe"
$NETSH    = "$SYS\netsh.exe"

$GUID_SUB_USB = '2a737441-1930-4402-8d77-b2bebba308a3'
$GUID_SUSP    = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$CLASE_NET    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$KEY_UBIC     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'

$esc = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($esc) -or -not (Test-Path $esc)) { $esc = Join-Path $env:USERPROFILE 'Desktop' }
if (-not (Test-Path $esc)) { $esc = $env:USERPROFILE }

$archivo   = Join-Path $esc 'CoexFix_respaldo.json'
$pathTxt   = Join-Path $esc 'CoexFix_respaldo_PATH.txt'

function Titulo($t) {
    Write-Host ''
    Write-Host ' --------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor White
    Write-Host ' --------------------------------------------------------' -ForegroundColor DarkCyan
}
function Ok($t)   { Write-Host "   [OK]  $t" -ForegroundColor Green }
function Err($t)  { Write-Host "   [ERR] $t" -ForegroundColor Red }
function Nota($t) { Write-Host "   $t" -ForegroundColor Gray }
function Aviso($t){ Write-Host "   $t" -ForegroundColor Yellow }

function Confirmar($txt) {
    Write-Host ''
    Write-Host "   $txt" -ForegroundColor Yellow
    return ((Read-Host '   (S/N)') -match '^[sSyY]')
}

# Guarda un respaldo SIN destruir el anterior: lo archiva con fecha.
# El primer respaldo de la maquina se marca como ORIGINAL y no se
# reemplaza nunca: es el unico registro del estado previo a cualquier
# reparacion.
function Guardar-Respaldo($estado) {
    if (Test-Path $archivo) {
        $orig = Join-Path $esc 'CoexFix_respaldo_ORIGINAL.json'
        if (-not (Test-Path $orig)) {
            Copy-Item -LiteralPath $archivo -Destination $orig -Force
            Ok "Respaldo previo preservado como ORIGINAL:"
            Nota "  $orig"
        }
        $hist = Join-Path $esc ("CoexFix_respaldo_{0}.json" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
        Copy-Item -LiteralPath $archivo -Destination $hist -Force
        Nota "Copia archivada: $(Split-Path $hist -Leaf)"
    }
    $estado | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $archivo -Encoding UTF8 -Force
}

# =====================================================================
#  LECTURA DEL ESTADO ACTUAL
# =====================================================================
function Leer-Estado {
    $e = [ordered]@{
        version    = 3
        fecha      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        equipo     = $env:COMPUTERNAME
        usuario    = $env:USERNAME
        energia    = @()
        pnpcap     = @()
        suspUSB    = @{ ac = $null; dc = $null }
        propsWifi  = @()
        udp        = @{ v4inicio = $null; v4num = $null; v6inicio = $null; v6num = $null }
        ubicacion  = @{ existia = $false; valor = $null }
        pathMaquina= $null
        pathUsuario= $null
    }

    # --- Ahorro de energia por dispositivo ---
    try {
        $todos = Get-PnpDevice
        foreach ($p in (Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop)) {
            $id  = $p.InstanceName -replace '_0$',''
            $dev = $todos | Where-Object { $_.InstanceId -eq $id }
            if ($dev -and $dev.Class -in @('Net','Bluetooth','USB')) {
                $e.energia += [ordered]@{
                    instancia = $p.InstanceName
                    nombre    = $dev.FriendlyName
                    valor     = [bool]$p.Enable
                }
            }
        }
    } catch { }

    # --- PnPCapabilities en el registro (tarjetas de red) ---
    # Nota: nada de 'continue' dentro del try. En PowerShell, 'continue'
    # dentro de un bloque try corta el bucle en vez de continuarlo.
    try {
        # SilentlyContinue, no Stop: algunas subclaves pertenecen a
        # TrustedInstaller y niegan acceso incluso al administrador.
        # Con Stop, la primera inaccesible aborta toda la enumeracion.
        $claves = @(Get-ChildItem $CLASE_NET -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match '^\d{4}$' })
        foreach ($k in $claves) {
            $prop = $null
            try { $prop = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue } catch { }
            if ($prop -and $prop.DriverDesc) {
                $tiene = $null -ne $prop.PSObject.Properties['PnPCapabilities']
                $e.pnpcap += [ordered]@{
                    ruta    = ([string]$k.PSPath).Replace('Microsoft.PowerShell.Core\Registry::','')
                    desc    = [string]$prop.DriverDesc
                    existia = $tiene
                    valor   = $(if ($tiene) { [int]$prop.PnPCapabilities } else { $null })
                }
            }
        }
    } catch { }

    # --- Suspension selectiva de USB ---
    # Igual que arriba: no se depende de las etiquetas traducidas.
    # powercfg imprime primero el valor de CA y luego el de bateria.
    try {
        $q = & $POWERCFG /query SCHEME_CURRENT $GUID_SUB_USB $GUID_SUSP 2>&1
        $t = ($q -join "`n")
        $hex = @([regex]::Matches($t, '(?i):\s*0x([0-9a-f]+)') | ForEach-Object { $_.Groups[1].Value })
        if ($hex.Count -ge 2) { $e.suspUSB.ac = $hex[0]; $e.suspUSB.dc = $hex[1] }
        elseif ($hex.Count -eq 1) { $e.suspUSB.ac = $hex[0] }
    } catch { }

    # --- Propiedades avanzadas del WiFi ---
    try {
        foreach ($w in (Get-NetAdapter | Where-Object { $_.PhysicalMediaType -match '802.11|Native' })) {
            foreach ($p in (Get-NetAdapterAdvancedProperty -Name $w.Name -ErrorAction SilentlyContinue)) {
                $e.propsWifi += [ordered]@{
                    adaptador = $w.Name
                    propiedad = $p.DisplayName
                    valor     = [string]$p.DisplayValue
                }
            }
        }
    } catch { }

    # --- Rango dinamico de puertos UDP ---
    # No se depende del texto de las etiquetas: el idioma y la
    # codificacion de la consola las destrozan. Se toman los dos
    # primeros numeros que aparecen despues de dos puntos, en orden:
    # el primero es el puerto inicial, el segundo la cantidad.
    try {
        foreach ($v in @('ipv4','ipv6')) {
            $o = (& $NETSH int $v show dynamicport udp 2>&1) -join "`n"
            $nums = @([regex]::Matches($o, ':\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
            if ($nums.Count -ge 2) {
                if ($v -eq 'ipv4') { $e.udp.v4inicio = $nums[0]; $e.udp.v4num = $nums[1] }
                else               { $e.udp.v6inicio = $nums[0]; $e.udp.v6num = $nums[1] }
            } elseif ($nums.Count -eq 1) {
                if ($v -eq 'ipv4') { $e.udp.v4inicio = $nums[0] }
                else               { $e.udp.v6inicio = $nums[0] }
            }
        }
    } catch { }

    # --- Servicios de ubicacion ---
    try {
        $u = Get-ItemProperty -Path $KEY_UBIC -Name Value -ErrorAction SilentlyContinue
        if ($u) { $e.ubicacion.existia = $true; $e.ubicacion.valor = [string]$u.Value }
    } catch { }

    # --- PATH (solo se guarda; nunca se restaura automaticamente) ---
    $e.pathMaquina = [Environment]::GetEnvironmentVariable('Path','Machine')
    $e.pathUsuario = [Environment]::GetEnvironmentVariable('Path','User')

    return $e
}

# =====================================================================
#  COMPARACION
# =====================================================================
function Comparar($resp, $act) {
    $difs = New-Object System.Collections.ArrayList

    foreach ($b in $resp.energia) {
        $a = $act.energia | Where-Object { $_.instancia -eq $b.instancia }
        if (-not $a) { [void]$difs.Add("Dispositivo ausente ahora: $($b.nombre)"); continue }
        if ([bool]$a.valor -ne [bool]$b.valor) {
            $de = if ($b.valor) { 'puede apagarse' } else { 'protegido' }
            $a2 = if ($a.valor) { 'puede apagarse' } else { 'protegido' }
            [void]$difs.Add("Energia | $($b.nombre): $de -> $a2")
        }
    }
    foreach ($b in $resp.pnpcap) {
        $a = $act.pnpcap | Where-Object { $_.ruta -eq $b.ruta }
        if (-not $a) { continue }
        if ([bool]$a.existia -ne [bool]$b.existia -or "$($a.valor)" -ne "$($b.valor)") {
            $de = if ($b.existia) { $b.valor } else { '(sin valor)' }
            $a2 = if ($a.existia) { $a.valor } else { '(sin valor)' }
            [void]$difs.Add("Registro | $($b.desc): $de -> $a2")
        }
    }
    if ("$($resp.suspUSB.ac)" -ne "$($act.suspUSB.ac)") {
        [void]$difs.Add("Suspension USB (AC): 0x$($resp.suspUSB.ac) -> 0x$($act.suspUSB.ac)")
    }
    if ("$($resp.suspUSB.dc)" -ne "$($act.suspUSB.dc)") {
        [void]$difs.Add("Suspension USB (DC): 0x$($resp.suspUSB.dc) -> 0x$($act.suspUSB.dc)")
    }
    foreach ($b in $resp.propsWifi) {
        $a = $act.propsWifi | Where-Object { $_.adaptador -eq $b.adaptador -and $_.propiedad -eq $b.propiedad }
        if (-not $a) { continue }
        if ("$($a.valor)" -ne "$($b.valor)") {
            [void]$difs.Add("WiFi | $($b.propiedad): '$($b.valor)' -> '$($a.valor)'")
        }
    }
    foreach ($c in @('v4inicio','v4num','v6inicio','v6num')) {
        if ("$($resp.udp.$c)" -ne "$($act.udp.$c)") {
            [void]$difs.Add("Puertos UDP ($c): $($resp.udp.$c) -> $($act.udp.$c)")
        }
    }
    if ("$($resp.ubicacion.valor)" -ne "$($act.ubicacion.valor)") {
        [void]$difs.Add("Ubicacion: '$($resp.ubicacion.valor)' -> '$($act.ubicacion.valor)'")
    }
    if ("$($resp.pathMaquina)" -ne "$($act.pathMaquina)") {
        [void]$difs.Add("PATH de sistema cambio (no se restaura automaticamente)")
    }
    return $difs
}

# =====================================================================
#  RESTAURACION
# =====================================================================
function Restaurar($resp) {
    Titulo 'RESTAURANDO'
    $n = 0

    # Energia
    # El bucle va FUERA del try: un 'continue' dentro de un try corta
    # el bucle en PowerShell, y bastaba con que un dispositivo del
    # respaldo ya no existiera para abortar toda la restauracion.
    $pw = $null
    try { $pw = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop }
    catch { Err 'No se pudo acceder a la configuracion de energia' }
    if ($pw) {
        $ausentes = 0
        foreach ($b in $resp.energia) {
            $o = $pw | Where-Object { $_.InstanceName -eq $b.instancia }
            if (-not $o) { $ausentes++ }
            elseif ([bool]$o.Enable -ne [bool]$b.valor) {
                try { $o.Enable = [bool]$b.valor; Set-CimInstance -InputObject $o -ErrorAction Stop
                      Ok "Energia: $($b.nombre)"; $n++ }
                catch { Err "Energia: $($b.nombre)" }
            }
        }
        if ($ausentes -gt 0) {
            Nota "$ausentes dispositivos del respaldo ya no estan presentes (se omiten)."
        }
    }

    # Registro PnPCapabilities
    foreach ($b in $resp.pnpcap) {
        $ruta = "Registry::$($b.ruta)"
        if (-not (Test-Path $ruta)) { continue }
        try {
            if ($b.existia) {
                Set-ItemProperty -Path $ruta -Name 'PnPCapabilities' -Value ([int]$b.valor) -Type DWord -Force -ErrorAction Stop
            } else {
                Remove-ItemProperty -Path $ruta -Name 'PnPCapabilities' -Force -ErrorAction SilentlyContinue
            }
            Ok "Registro: $($b.desc)"; $n++
        } catch { Err "Registro: $($b.desc)" }
    }

    # Suspension selectiva
    if ($resp.suspUSB.ac) {
        try {
            $v = [Convert]::ToInt32($resp.suspUSB.ac, 16)
            & $POWERCFG /setacvalueindex SCHEME_CURRENT $GUID_SUB_USB $GUID_SUSP $v | Out-Null
            if ($resp.suspUSB.dc) {
                $d = [Convert]::ToInt32($resp.suspUSB.dc, 16)
                & $POWERCFG /setdcvalueindex SCHEME_CURRENT $GUID_SUB_USB $GUID_SUSP $d | Out-Null
            }
            & $POWERCFG /setactive SCHEME_CURRENT | Out-Null
            Ok 'Suspension selectiva de USB'; $n++
        } catch { Err 'Suspension selectiva de USB' }
    }

    # Propiedades WiFi
    foreach ($b in $resp.propsWifi) {
        $a = Get-NetAdapterAdvancedProperty -Name $b.adaptador -DisplayName $b.propiedad -ErrorAction SilentlyContinue
        if (-not $a) { continue }
        if ("$($a.DisplayValue)" -eq "$($b.valor)") { continue }
        try {
            Set-NetAdapterAdvancedProperty -Name $b.adaptador -DisplayName $b.propiedad -DisplayValue $b.valor -ErrorAction Stop
            Ok "WiFi: $($b.propiedad) = $($b.valor)"; $n++
        } catch { Err "WiFi: $($b.propiedad)" }
    }

    # Puertos UDP
    if ($resp.udp.v4inicio -and $resp.udp.v4num) {
        try {
            & $NETSH int ipv4 set dynamicport udp start=$($resp.udp.v4inicio) num=$($resp.udp.v4num) | Out-Null
            if ($resp.udp.v6inicio -and $resp.udp.v6num) {
                & $NETSH int ipv6 set dynamicport udp start=$($resp.udp.v6inicio) num=$($resp.udp.v6num) | Out-Null
            }
            Ok "Puertos UDP: inicio $($resp.udp.v4inicio), cantidad $($resp.udp.v4num)"; $n++
        } catch { Err 'Puertos UDP' }
    }

    # Ubicacion
    if ($resp.ubicacion.existia) {
        try {
            Set-ItemProperty -Path $KEY_UBIC -Name Value -Value $resp.ubicacion.valor -Force -ErrorAction Stop
            Ok "Ubicacion: $($resp.ubicacion.valor)"; $n++
        } catch { Err 'Ubicacion' }
    }

    Write-Host ''
    if ($n -eq 0) { Nota 'No hubo nada que aplicar.' }
    else {
        Ok "$n cambios revertidos."
        Aviso 'REINICIAR el equipo para que tomen efecto.'
    }

    if ("$($resp.pathMaquina)" -ne "$([Environment]::GetEnvironmentVariable('Path','Machine'))") {
        Write-Host ''
        Aviso 'El PATH de sistema cambio desde el respaldo.'
        Nota  'No se restaura de forma automatica: escribirlo mal deja'
        Nota  'el equipo peor. El valor original quedo guardado en:'
        Nota  "  $pathTxt"
    }
}

# =====================================================================
#  PRINCIPAL
# =====================================================================
Clear-Host
Write-Host ''
Write-Host '   CoexFix - RESPALDO Y RESTAURACION' -ForegroundColor Cyan
Write-Host ''

$admin = $false
try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if (-not $admin) {
    Aviso 'Sin permisos de administrador.'
    Nota  'El respaldo puede quedar incompleto y la restauracion fallar.'
    Nota  'Cerrar, clic derecho sobre el archivo, "Ejecutar como administrador".'
    Write-Host ''
    Read-Host '   ENTER para continuar igual'
}

Nota 'Leyendo el estado actual del sistema...'
$actual = Leer-Estado
Ok "Dispositivos de energia   : $(@($actual.energia).Count)"
Ok "Claves de registro de red : $(@($actual.pnpcap).Count)"
Ok "Propiedades de WiFi       : $(@($actual.propsWifi).Count)"
Ok "Rango UDP                 : inicio $($actual.udp.v4inicio), cantidad $($actual.udp.v4num)"
if (@($actual.pnpcap).Count -eq 0) {
    Write-Host ''
    Aviso 'No se leyo ninguna clave de registro de red. Eso no es'
    Aviso 'esperable: deberia haber varias. Avisar de este resultado.'
}

# ---------- Sin respaldo previo: crearlo ----------
if (-not (Test-Path $archivo)) {
    Titulo 'PRIMERA EJECUCION - creando respaldo'
    Nota 'No existe un respaldo previo. Se va a guardar el estado'
    Nota 'actual para poder volver a el mas adelante.'
    Write-Host ''
    try {
        Guardar-Respaldo $actual
        Ok "Respaldo creado: $archivo"
    } catch { Err "No se pudo guardar el respaldo: $($_.Exception.Message)"; Read-Host '   ENTER'; exit 1 }

    try {
        $t = @()
        $t += "CoexFix - copia del PATH  ($($actual.fecha))"
        $t += ''
        $t += '--- PATH DE SISTEMA (Machine) ---'
        $t += ($actual.pathMaquina -split ';')
        $t += ''
        $t += '--- PATH DE USUARIO (User) ---'
        $t += ($actual.pathUsuario -split ';')
        $t | Set-Content -LiteralPath $pathTxt -Encoding UTF8 -Force
        Ok "Copia del PATH: $pathTxt"
    } catch { }

    Write-Host ''
    Nota 'A partir de ahora, ejecutar este mismo archivo:'
    Nota '  - Si nada cambio, lo va a avisar.'
    Nota '  - Si algo cambio, ofrece volver a este estado.'
    Write-Host ''
    Aviso 'NO borrar los archivos del Escritorio.'
    Write-Host ''
    Nota 'Ya se puede ejecutar CoexFix-Reparar con red de seguridad.'
    Write-Host ''
    Read-Host '   ENTER para cerrar'
    exit 0
}

# ---------- Hay respaldo: comparar ----------
try { $resp = Get-Content -LiteralPath $archivo -Raw | ConvertFrom-Json }
catch {
    Err 'El respaldo existe pero esta danado o ilegible.'
    Nota "Archivo: $archivo"
    Write-Host ''
    if (Confirmar 'Crear un respaldo nuevo con el estado actual? (se pierde el anterior)') {
        Guardar-Respaldo $actual
        Ok 'Respaldo nuevo creado.'
    }
    Read-Host '   ENTER para cerrar'
    exit 0
}

Titulo 'COMPARANDO CON EL RESPALDO'
Nota "Respaldo del $($resp.fecha)  |  equipo $($resp.equipo)"
Write-Host ''

# --- Respaldo viejo o incompleto ---
$vieja = ($null -eq $resp.version -or [int]$resp.version -lt 3)
$vacio = (@($resp.pnpcap).Count -eq 0 -or $null -eq $resp.udp.v4num)
if ($vieja -or $vacio) {
    Aviso 'Este respaldo fue creado por una version anterior y le'
    Aviso 'faltan datos (claves de registro y/o rango de puertos UDP).'
    Write-Host ''
    Aviso 'ATENCION antes de reemplazarlo:'
    Nota  'Si ya se ejecutaron reparaciones en este equipo, este archivo'
    Nota  'puede ser el UNICO registro del estado previo a esas'
    Nota  'reparaciones. Reemplazarlo guarda el estado YA MODIFICADO y'
    Nota  'se pierde la referencia de como estaba el equipo antes.'
    Write-Host ''
    Nota  'Si no hubo reparaciones todavia, reemplazarlo es correcto.'
    Nota  'Ante la duda, responder N y usarlo tal cual esta.'
    Nota  '(De todos modos se archiva una copia antes de reemplazar.)'
    Write-Host ''
    if (Confirmar 'Reemplazarlo por un respaldo nuevo y completo del estado actual?') {
        Guardar-Respaldo $actual
        Ok 'Respaldo nuevo creado con el estado actual.'
        Nota "Claves de registro guardadas : $(@($actual.pnpcap).Count)"
        Nota "Rango UDP                    : inicio $($actual.udp.v4inicio), cantidad $($actual.udp.v4num)"
        Write-Host ''
        Read-Host '   ENTER para cerrar'
        exit 0
    }
    Nota 'Se continua con el respaldo viejo. La comparacion puede ser parcial.'
    Write-Host ''
}

$difs = Comparar $resp $actual

if ($difs.Count -eq 0) {
    Ok 'El sistema esta IGUAL que en el respaldo.'
    Write-Host ''
    Nota 'No hace falta restaurar nada. Todo esta como estaba.'
    Write-Host ''
    if (Confirmar 'Actualizar el respaldo con la fecha de hoy?') {
        Guardar-Respaldo $actual
        Ok 'Respaldo actualizado.'
    }
    Write-Host ''
    Read-Host '   ENTER para cerrar'
    exit 0
}

Aviso "Se detectaron $($difs.Count) diferencias respecto al respaldo:"
Write-Host ''
$i = 0
foreach ($d in $difs) {
    $i++
    if ($i -le 40) { Write-Host "   $i. $d" -ForegroundColor White }
}
if ($difs.Count -gt 40) { Nota "   ... y $($difs.Count - 40) mas." }

Write-Host ''
Nota 'El formato es:  valor del respaldo  ->  valor actual'
Write-Host ''

if (Confirmar 'Volver al estado del respaldo?') {
    Restaurar $resp
} else {
    Nota 'No se modifico nada.'
    Write-Host ''
    if (Confirmar 'Guardar el estado ACTUAL como nuevo respaldo?') {
        Guardar-Respaldo $actual
        Ok 'Respaldo actualizado al estado actual.'
    }
}

Write-Host ''
Read-Host '   ENTER para cerrar'
