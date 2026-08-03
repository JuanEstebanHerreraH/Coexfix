# =====================================================================
#  CoexFix - Reparacion
#
#  Corrige la configuracion que provoca cortes de WiFi al usar
#  Bluetooth.
#
#  IMPORTANTE: comparte el mismo archivo de respaldo que
#  CoexFix-Respaldo (CoexFix_respaldo.json). Un solo sistema de
#  deshacer, un solo archivo. Nunca sobrescribe un respaldo previo.
# =====================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# Alinea la codificacion con la pagina de codigos de la consola.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(
        [int](Get-Culture).TextInfo.OEMCodePage)
} catch { }

$SYS      = "$env:SystemRoot\System32"
$POWERCFG = "$SYS\powercfg.exe"
$NETSH    = "$SYS\netsh.exe"
$PNPUTIL  = "$SYS\pnputil.exe"

$GUID_SUB_USB = '2a737441-1930-4402-8d77-b2bebba308a3'
$GUID_SUSP    = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$CLASE_NET    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$KEY_UBIC     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'

$esc = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($esc) -or -not (Test-Path $esc)) { $esc = Join-Path $env:USERPROFILE 'Desktop' }
if (-not (Test-Path $esc)) { $esc = $env:USERPROFILE }

$archivo = Join-Path $esc 'CoexFix_respaldo.json'
$pathTxt = Join-Path $esc 'CoexFix_respaldo_PATH.txt'
$logFile = Join-Path $esc ("CoexFix_log_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm'))

$script:CFVirtual = 'OpenVPN|WAN Miniport|TAP-|TAP Adapter|Kernel Debug|Wi-Fi Direct|Virtual Adapter|Loopback|VPN|Wintun|NordLynx|TeamViewer|Hyper-V|VMware|VirtualBox|Npcap|Pseudo'

$LOG = New-Object System.Collections.ArrayList
$script:SIMULAR = $false

function Log($t)  { [void]$LOG.Add("$(Get-Date -Format 'HH:mm:ss')  $t") }
function Ok($t)   { Write-Host "   [OK]  $t" -ForegroundColor Green;     Log "OK   - $t" }
function Sim($t)  { Write-Host "   [SIM] $t" -ForegroundColor Cyan;      Log "SIM  - $t" }
function Salto($t){ Write-Host "   [--]  $t" -ForegroundColor DarkGray;  Log "SKIP - $t" }
function Err($t)  { Write-Host "   [ERR] $t" -ForegroundColor Red;       Log "ERR  - $t" }
function Nota($t) { Write-Host "   $t" -ForegroundColor Gray }
function Aviso($t){ Write-Host "   $t" -ForegroundColor Yellow }
function Titulo($t) {
    Write-Host ''
    Write-Host ' --------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor White
    Write-Host ' --------------------------------------------------------' -ForegroundColor DarkCyan
    Log ''; Log "== $t =="
}
function Confirmar($txt) {
    Write-Host ''
    Write-Host "   $txt" -ForegroundColor Yellow
    return ((Read-Host '   (S/N)') -match '^[sSyY]')
}

# ---------------------------------------------------------------------
#  Adaptadores de red reales, para saber que claves del registro tocar.
#  Antes se filtraba por nombre (Wireless|WLAN|Bluetooth...) y las
#  placas Ethernet quedaban afuera: el ajuste se revertia al reiniciar
#  porque solo se aplicaba la capa WMI, que no persiste.
# ---------------------------------------------------------------------
function Normalizar-Desc {
    param([string]$t)
    # Windows numera los duplicados: "Adaptador X #2". La clave del
    # registro guarda el nombre SIN ese sufijo, asi que hay que
    # quitarlo para poder comparar.
    return ($t -replace '\s*#\d+\s*$','').Trim()
}

# Adaptadores de HARDWARE realmente presentes. Se excluyen adaptadores
# virtuales (WAN Miniport, TAP de VPN, Wi-Fi Direct, Kernel Debug):
# no tienen administracion de energia y no hay motivo para tocarlos.
function Adaptadores-Reales {
    $d = @{}
    try {
        foreach ($a in (Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
                        Where-Object { $_.HardwareInterface })) {
            if ($a.InterfaceDescription) {
                $d[(Normalizar-Desc $a.InterfaceDescription)] = $true
            }
        }
    } catch { }
    return $d
}

function Claves-Registro-Red {
    $script:CFClavesVistas = 0
    $reales = Adaptadores-Reales
    $lista  = New-Object System.Collections.ArrayList
    try {
        # SilentlyContinue, no Stop: algunas subclaves pertenecen a
        # TrustedInstaller y niegan acceso incluso al administrador.
        # Con Stop, la primera inaccesible aborta toda la enumeracion.
        $claves = @(Get-ChildItem $CLASE_NET -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match '^\d{4}$' })
        $script:CFClavesVistas = $claves.Count
        foreach ($k in $claves) {
            # SIN 'continue' dentro del try: en PowerShell corta el
            # bucle en lugar de continuarlo. Se usa if anidado.
            $prop = $null
            try { $prop = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue } catch { }
            if ($prop -and $prop.DriverDesc) {
                $desc = ([string]$prop.DriverDesc).Trim()
                $norm = Normalizar-Desc $desc
                # Criterio estricto: hardware presente, o el adaptador
                # de red del Bluetooth. Nada de virtuales ni de VPN.
                $esHardware  = $reales.ContainsKey($norm)
                $esBluetooth = $desc -match 'Bluetooth'
                $esVirtual   = $desc -match $script:CFVirtual
                if (($esHardware -or $esBluetooth) -and -not $esVirtual) {
                    [void]$lista.Add([pscustomobject]@{
                        PSPath = $k.PSPath
                        Desc   = $desc
                    })
                }
            }
        }
    } catch {
        Err "No se pudo leer el registro de red: $($_.Exception.Message)"
    }
    # Diagnostico util: distinguir 'sin acceso' de 'sin coincidencias'
    if ($lista.Count -eq 0) {
        Nota "Subclaves de red enumeradas: $($script:CFClavesVistas)"
        if ($script:CFClavesVistas -eq 0) {
            Nota 'No se pudo enumerar la rama del registro. Revisar permisos.'
        } else {
            Nota 'Se enumeraron subclaves pero ninguna corresponde a un'
            Nota 'adaptador de hardware presente en el equipo.'
        }
    }
    # La coma evita que PowerShell desenrolle la coleccion al retornar
    return ,@($lista)
}

# =====================================================================
#  LECTURA DEL ESTADO (identica a CoexFix-Respaldo: mismo esquema)
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
#  RESTAURACION (identica a CoexFix-Respaldo)
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
#  RESPALDO (compartido con CoexFix-Respaldo)
# =====================================================================
function Asegurar-Respaldo {
    if (Test-Path $archivo) {
        try {
            $r = Get-Content -LiteralPath $archivo -Raw | ConvertFrom-Json
            Ok "Respaldo existente del $($r.fecha) - se conserva intacto"
            Nota 'Ese archivo tiene el estado PREVIO a cualquier reparacion.'
            Nota 'No se sobrescribe: es la referencia para deshacer.'
            return $true
        } catch {
            Err 'El respaldo existente esta danado.'
            if (-not (Confirmar 'Crear uno nuevo con el estado actual? (se archiva el danado)')) { return $false }
            Copy-Item -LiteralPath $archivo -Destination ($archivo + '.danado') -Force
        }
    }
    Nota 'Creando respaldo del estado actual...'
    try {
        (Leer-Estado) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $archivo -Encoding UTF8 -Force
        $orig = Join-Path $esc 'CoexFix_respaldo_ORIGINAL.json'
        if (-not (Test-Path $orig)) { Copy-Item -LiteralPath $archivo -Destination $orig -Force }
        Ok "Respaldo creado: $archivo"
        return $true
    } catch { Err "No se pudo crear el respaldo: $($_.Exception.Message)"; return $false }
}

function Punto-Restauracion {
    Nota 'Creando punto de restauracion del sistema...'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' `
            -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'CoexFix' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Ok 'Punto de restauracion creado'
    } catch {
        Aviso 'No se pudo crear el punto de restauracion.'
        Nota  'Suele pasar si la Proteccion del sistema esta desactivada.'
        Nota  'El respaldo propio de CoexFix igual funciona.'
    }
}

# =====================================================================
#  CORRECCIONES
# =====================================================================
function Fix-EnergiaUSB {
    Titulo '1. Ahorro de energia USB'
    Nota 'Impide que Windows suspenda por su cuenta los adaptadores de'
    Nota 'red, Bluetooth y concentradores USB.'

    $items    = @()
    $virtuales = 0
    try {
        $todos = Get-PnpDevice
        foreach ($p in (Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop)) {
            $id  = $p.InstanceName -replace '_0$',''
            $dev = $todos | Where-Object { $_.InstanceId -eq $id }
            if ($dev -and $dev.Class -in @('Net','Bluetooth','USB') -and $p.Enable) {
                # Los adaptadores virtuales (VPN, WAN Miniport, Wi-Fi
                # Direct) no tienen administracion de energia real: la
                # escritura falla siempre y no aportan nada al problema.
                if ($dev.FriendlyName -match $script:CFVirtual) { $virtuales++ }
                else { $items += [pscustomobject]@{ obj = $p; nombre = $dev.FriendlyName } }
            }
        }
    } catch { Err 'No se pudo leer la configuracion de energia'; return }
    if ($virtuales -gt 0) {
        Nota "Se omiten $virtuales adaptadores virtuales (VPN, Wi-Fi Direct, etc.)"
    }

    if ($items.Count -eq 0) { Salto 'Todos ya estan protegidos.' }
    else {
        Write-Host ''
        Nota "Dispositivos a proteger: $($items.Count)"
        foreach ($i in $items) { Nota "  - $($i.nombre)" }
        foreach ($i in $items) {
            if ($script:SIMULAR) { Sim "Protegeria: $($i.nombre)"; continue }
            try {
                $o = $i.obj; $o.Enable = $false
                Set-CimInstance -InputObject $o -ErrorAction Stop
                Ok "Protegido: $($i.nombre)"
            } catch { Err "No se pudo: $($i.nombre)" }
        }
    }

    # Capa de registro: es la que hace que el ajuste sobreviva al
    # reinicio. Se aplica a TODOS los adaptadores de red, no solo a
    # las radios: antes las placas Ethernet quedaban afuera y el
    # ajuste se revertia al arrancar.
    Write-Host ''
    $claves = Claves-Registro-Red
    if ($claves.Count -eq 0) { Salto 'No se encontraron claves de registro de red.'; return }
    Nota "Reforzando en el registro: $($claves.Count) entradas"
    foreach ($c in $claves) {
        if ($script:SIMULAR) { Sim "Registro: $($c.Desc)"; continue }
        try {
            Set-ItemProperty -Path $c.PSPath -Name 'PnPCapabilities' -Value 24 -Type DWord -Force -ErrorAction Stop
            Ok "Registro: $($c.Desc)"
        } catch { Err "Registro: $($c.Desc)" }
    }
}

function Fix-SuspensionSelectiva {
    Titulo '2. Suspension selectiva de USB'
    Nota 'Desactiva la suspension automatica de puertos USB en el plan'
    Nota 'de energia activo.'
    if ($script:SIMULAR) { Sim 'Desactivaria la suspension selectiva de USB'; return }
    try {
        & $POWERCFG /setacvalueindex SCHEME_CURRENT $GUID_SUB_USB $GUID_SUSP 0 | Out-Null
        & $POWERCFG /setdcvalueindex SCHEME_CURRENT $GUID_SUB_USB $GUID_SUSP 0 | Out-Null
        & $POWERCFG /setactive SCHEME_CURRENT | Out-Null
        Ok 'Suspension selectiva de USB desactivada'
    } catch { Err 'No se pudo modificar el plan de energia' }
}

function Fix-Coexistencia {
    Titulo '3. Coexistencia WiFi / Bluetooth'
    Nota 'Activa la funcion que hace que WiFi y Bluetooth se turnen el'
    Nota 'uso del aire en lugar de pisarse.'
    $hallado = $false
    foreach ($w in (Get-NetAdapter | Where-Object { $_.PhysicalMediaType -match '802.11|Native' })) {
        foreach ($p in (Get-NetAdapterAdvancedProperty -Name $w.Name |
                        Where-Object { $_.DisplayName -match 'Collaboration|Coexist' })) {
            $hallado = $true
            $destino = $p.ValidDisplayValues | Where-Object { $_ -match 'Enable|Habilit|On' } | Select-Object -First 1
            if (-not $destino) { Salto "Sin valor 'Habilitado' en $($p.DisplayName)"; continue }
            if ($p.DisplayValue -eq $destino) { Salto "$($p.DisplayName) ya esta en '$destino'"; continue }
            if ($script:SIMULAR) { Sim "$($p.DisplayName): '$($p.DisplayValue)' -> '$destino'"; continue }
            try {
                Set-NetAdapterAdvancedProperty -Name $w.Name -DisplayName $p.DisplayName -DisplayValue $destino -ErrorAction Stop
                Ok "$($p.DisplayName) = $destino"
            } catch { Err "No se pudo cambiar $($p.DisplayName)" }
        }
    }
    if (-not $hallado) {
        Salto 'Este driver no expone la opcion de coexistencia.'
        Nota  'Es normal en adaptadores genericos. No es un error.'
    }
}

function Fix-Fantasmas {
    Titulo '4. Dispositivos fantasma'
    Nota 'Elimina registros de adaptadores Bluetooth y de red que ya no'
    Nota 'estan conectados. Evita conflictos al reconectarlos.'
    $g = @(Get-PnpDevice | Where-Object {
        $_.Status -eq 'Unknown' -and $_.Class -in @('Bluetooth','Net') -and
        ($_.InstanceId -like 'USB*' -or $_.InstanceId -like 'BTH*')
    })
    if ($g.Count -eq 0) { Salto 'No hay dispositivos fantasma.'; return }
    Write-Host ''
    Nota "Encontrados: $($g.Count)"
    foreach ($d in $g) { Nota "  - $($d.FriendlyName)" }
    foreach ($d in $g) {
        if ($script:SIMULAR) { Sim "Eliminaria: $($d.FriendlyName)"; continue }
        try {
            & $PNPUTIL /remove-device "$($d.InstanceId)" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Ok "Eliminado: $($d.FriendlyName)" }
            else { Salto "No se pudo eliminar: $($d.FriendlyName)" }
        } catch { Salto "No se pudo eliminar: $($d.FriendlyName)" }
    }
    Write-Host ''
    Nota 'Si el dispositivo se vuelve a conectar, Windows lo reinstala'
    Nota 'automaticamente. No se pierde nada.'
}

function Fix-Ubicacion {
    Titulo '5. Servicios de ubicacion'
    Nota 'Windows los exige para listar las redes WiFi cercanas. Sin'
    Nota 'esto no se puede verificar si hay red de 5 GHz.'
    $actual = $null
    try { $actual = (Get-ItemProperty -Path $KEY_UBIC -Name Value -ErrorAction Stop).Value } catch { }
    if ($actual -eq 'Allow') { Salto 'Ya estan activados.'; return }
    if ($script:SIMULAR) { Sim 'Activaria los servicios de ubicacion'; return }
    try {
        Set-ItemProperty -Path $KEY_UBIC -Name Value -Value 'Allow' -Force -ErrorAction Stop
        Set-Service -Name lfsvc -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service -Name lfsvc -ErrorAction SilentlyContinue
        Ok 'Servicios de ubicacion activados'
    } catch { Err 'No se pudo activar' }
}

function Fix-PuertosUDP {
    Titulo '6. Rango de puertos UDP'
    Nota 'Amplia el rango disponible. Corrige el error Tcpip 4266'
    Nota '(agotamiento de puertos), que corta la red temporalmente.'
    if ($script:SIMULAR) { Sim 'Ampliaria el rango UDP a 16384-65534'; return }
    try {
        & $NETSH int ipv4 set dynamicport udp start=16384 num=49151 | Out-Null
        & $NETSH int ipv6 set dynamicport udp start=16384 num=49151 | Out-Null
        Ok 'Rango de puertos UDP ampliado'
    } catch { Err 'No se pudo modificar el rango de puertos' }
}

function Fix-Banda5GHz {
    Titulo 'AVANZADO - Forzar banda de 5 GHz'
    Aviso 'Solo conviene si la senal de 5 GHz es buena Y el router la'
    Aviso 'emite. Si no, la conexion puede empeorar.'
    $hallado = $false
    foreach ($w in (Get-NetAdapter | Where-Object { $_.PhysicalMediaType -match '802.11|Native' })) {
        foreach ($p in (Get-NetAdapterAdvancedProperty -Name $w.Name |
                        Where-Object { $_.DisplayName -match 'Preferred Band|Banda preferida' })) {
            $hallado = $true
            $destino = $p.ValidDisplayValues | Where-Object { $_ -match '5\s*GHz|5G' } | Select-Object -First 1
            if (-not $destino) { Salto 'Sin opcion de 5 GHz en este driver'; continue }
            if ($script:SIMULAR) { Sim "Banda preferida: '$($p.DisplayValue)' -> '$destino'"; continue }
            try {
                Set-NetAdapterAdvancedProperty -Name $w.Name -DisplayName $p.DisplayName -DisplayValue $destino -ErrorAction Stop
                Ok "Banda preferida = $destino"
            } catch { Err 'No se pudo cambiar la banda preferida' }
        }
    }
    if (-not $hallado) { Salto 'Este driver no expone la banda preferida.' }
}

function Fix-AnchoCanal {
    Titulo 'AVANZADO - Ancho de canal 2.4 GHz a 20 MHz'
    Nota 'En 2.4 GHz, un canal de 40 MHz ocupa el DOBLE de espectro en'
    Nota 'una banda que solo tiene 83 MHz. Con Bluetooth saltando por'
    Nota 'encima, la probabilidad de colision se dispara.'
    Aviso 'Baja la velocidad maxima teorica a cambio de estabilidad.'
    $hallado = $false
    foreach ($w in (Get-NetAdapter | Where-Object { $_.PhysicalMediaType -match '802.11|Native' })) {
        $props = @(Get-NetAdapterAdvancedProperty -Name $w.Name -ErrorAction SilentlyContinue)

        # 1) Propiedades que nombran explicitamente la banda de 2.4 GHz
        $cand = @($props | Where-Object {
            $_.DisplayName -match '(Channel Width|Ancho de canal|Bandwidth|Ancho de banda).*2[\.,]4'
        })

        # 2) Si no hay ninguna, puede ser un adaptador de banda unica,
        #    donde la propiedad generica se refiere a 2.4 GHz. Solo se
        #    acepta si NADA en el driver menciona 5 GHz: en un adaptador
        #    de doble banda, tocar la generica podria bajar el 5 GHz.
        if ($cand.Count -eq 0) {
            $mencion5 = @($props | Where-Object {
                $_.DisplayName -match '5\s*GHz|5G' -or $_.DisplayValue -match '5\s*GHz'
            })
            if ($mencion5.Count -eq 0) {
                $cand = @($props | Where-Object {
                    $_.DisplayName -match '^(Channel Width|Ancho de canal|Bandwidth|Ancho de banda)$'
                })
                if ($cand.Count -gt 0) {
                    Nota 'Adaptador de banda unica: se usa la propiedad generica.'
                }
            } else {
                Nota 'Adaptador de doble banda sin propiedad especifica de'
                Nota '2.4 GHz: no se toca para no afectar la banda de 5 GHz.'
            }
        }

        foreach ($p in $cand) {
            $hallado = $true
            $destino = $p.ValidDisplayValues | Where-Object { $_ -match '^20($|[^_0-9])' } | Select-Object -First 1
            if (-not $destino) {
                $destino = $p.ValidDisplayValues | Where-Object { $_ -match '20\s*MHz' } | Select-Object -First 1
            }
            if (-not $destino) {
                Salto "Sin opcion de 20 MHz en '$($p.DisplayName)'"
                Nota  "Valores disponibles: $($p.ValidDisplayValues -join ', ')"
                continue
            }
            if ($p.DisplayValue -eq $destino) { Salto "$($p.DisplayName) ya esta en '$destino'"; continue }
            if ($script:SIMULAR) { Sim "$($p.DisplayName): '$($p.DisplayValue)' -> '$destino'"; continue }
            try {
                Set-NetAdapterAdvancedProperty -Name $w.Name -DisplayName $p.DisplayName -DisplayValue $destino -ErrorAction Stop
                Ok "$($p.DisplayName) = $destino"
            } catch { Err "No se pudo cambiar $($p.DisplayName)" }
        }
    }
    if (-not $hallado) { Salto 'Este driver no expone el ancho de canal.' }
}

function Informe-Drivers {
    Titulo 'INFORME DE DRIVERS - solo informativo'
    Nota 'CoexFix no instala drivers. Aqui solo se indica cuales'
    Nota 'conviene revisar.'
    Write-Host ''
    $hoy = Get-Date
    foreach ($a in (Get-NetAdapter -IncludeHidden | Where-Object { $_.HardwareInterface })) {
        if (-not $a.DriverDate) { continue }
        $d = ($hoy - [datetime]$a.DriverDate).Days
        $col = if ($d -gt 1095) { 'Yellow' } else { 'Gray' }
        Write-Host ("   {0,-45} {1}  ({2} anios)" -f $a.InterfaceDescription, $a.DriverVersion, [int]($d/365)) -ForegroundColor $col
    }
    Write-Host ''
    $mal = @(Get-PnpDevice | Where-Object { $_.Status -eq 'Error' })
    if ($mal.Count -eq 0) { Write-Host '   Ningun dispositivo sin driver.' -ForegroundColor Green; return }
    Aviso 'Dispositivos SIN driver:'
    foreach ($d in $mal) {
        $nm = if ($d.FriendlyName) { $d.FriendlyName } else { '(sin nombre)' }
        Write-Host "     - $nm" -ForegroundColor Yellow
        if ($d.InstanceId -match 'VEN_1022|AMDIF') { Nota '       Chipset AMD -> amd.com/support (AMD Chipset Drivers)' }
        if ($d.InstanceId -match 'VEN_8086')       { Nota '       Chipset Intel -> intel.com (Chipset Software)' }
    }
}

# =====================================================================
#  DESHACER
# =====================================================================
function Deshacer-Todo {
    Titulo 'DESHACER CAMBIOS'
    if (-not (Test-Path $archivo)) {
        Err 'No hay respaldo.'
        Nota "Archivo esperado: $archivo"
        Nota 'Ejecutar CoexFix-Respaldo para crear uno.'
        return
    }
    $resp = $null
    try { $resp = Get-Content -LiteralPath $archivo -Raw | ConvertFrom-Json }
    catch { Err 'El respaldo esta danado o ilegible.'; return }

    Nota "Respaldo del $($resp.fecha)  |  equipo $($resp.equipo)"
    if (-not (Confirmar 'Volver al estado del respaldo?')) { Salto 'Cancelado.'; return }
    Restaurar $resp
}

# =====================================================================
#  EJECUCION
# =====================================================================
function Correr($lista, $unoAUno) {
    if (-not $script:SIMULAR) {
        Punto-Restauracion
        if (-not (Asegurar-Respaldo)) {
            Err 'Sin respaldo no se continua. Operacion cancelada.'
            return
        }
    }
    foreach ($f in $lista) {
        if ($unoAUno) {
            Write-Host ''
            Write-Host "   Siguiente: $($f.desc)" -ForegroundColor White
            if (-not (Confirmar 'Ejecutar este paso?')) { Salto "Omitido: $($f.desc)"; continue }
        }
        & $f.fn
    }
}

$SEGURAS = @(
    @{ desc = 'Ahorro de energia USB';       fn = { Fix-EnergiaUSB } }
    @{ desc = 'Suspension selectiva de USB'; fn = { Fix-SuspensionSelectiva } }
    @{ desc = 'Coexistencia WiFi/Bluetooth'; fn = { Fix-Coexistencia } }
    @{ desc = 'Dispositivos fantasma';       fn = { Fix-Fantasmas } }
    @{ desc = 'Servicios de ubicacion';      fn = { Fix-Ubicacion } }
    @{ desc = 'Rango de puertos UDP';        fn = { Fix-PuertosUDP } }
)
$AVANZADAS = @(
    @{ desc = 'Forzar banda de 5 GHz'; fn = { Fix-Banda5GHz } }
    @{ desc = 'Ancho de canal 20 MHz'; fn = { Fix-AnchoCanal } }
)

function Menu {
    Clear-Host
    Write-Host ''
    Write-Host '   ==============================================' -ForegroundColor Yellow
    Write-Host '     CoexFix - REPARACION' -ForegroundColor Yellow
    Write-Host '     WiFi que se cae al usar Bluetooth' -ForegroundColor DarkGray
    Write-Host '   ==============================================' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '     [1]  Reparacion segura (recomendado)'    -ForegroundColor White
    Write-Host '     [2]  Elegir paso por paso'                -ForegroundColor White
    Write-Host '     [3]  Simulacion - no modifica nada'       -ForegroundColor Cyan
    Write-Host '     [4]  Ajustes avanzados (leer los avisos)' -ForegroundColor DarkYellow
    Write-Host '     [5]  DESHACER los cambios'                -ForegroundColor Magenta
    Write-Host '     [6]  Informe de drivers (solo lectura)'   -ForegroundColor Gray
    Write-Host '     [0]  Salir'                               -ForegroundColor DarkGray
    Write-Host ''
    if (Test-Path $archivo) {
        try {
            $r = Get-Content -LiteralPath $archivo -Raw | ConvertFrom-Json
            Write-Host "     Respaldo disponible del $($r.fecha)" -ForegroundColor DarkGreen
        } catch { Write-Host '     Respaldo presente pero ilegible' -ForegroundColor Red }
    } else {
        Write-Host '     SIN RESPALDO. Se creara al reparar.' -ForegroundColor DarkYellow
    }
    Write-Host ''
    return (Read-Host '   Opcion')
}

# =====================================================================
#  PRINCIPAL
# =====================================================================
Log 'CoexFix - Reparacion'
Log "Equipo: $env:COMPUTERNAME  |  $(Get-Date)"

$admin = $false
try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if (-not $admin) {
    Clear-Host
    Write-Host ''
    Aviso 'Sin permisos de administrador.'
    Nota  'La reparacion no funciona correctamente asi.'
    Nota  'Cerrar, clic derecho sobre el .bat, "Ejecutar como administrador".'
    Write-Host ''
    Read-Host '   ENTER para cerrar'
    exit 1
}

$salir = $false
while (-not $salir) {
    $script:SIMULAR = $false
    switch (Menu) {
        '1' {
            Clear-Host
            Titulo 'REPARACION SEGURA'
            Nota 'Se aplican 6 correcciones reversibles.'
            Nota 'Antes se crea un punto de restauracion y, si no existe,'
            Nota 'un respaldo del estado actual.'
            if (Confirmar 'Continuar?') { Correr $SEGURAS $false } else { Salto 'Cancelado.' }
            Write-Host ''
            Aviso 'REINICIAR para que los cambios tomen efecto.'
            Read-Host '   ENTER para volver al menu'
        }
        '2' { Clear-Host; Titulo 'PASO POR PASO'; Correr $SEGURAS $true; Read-Host "`n   ENTER para volver al menu" }
        '3' {
            Clear-Host
            $script:SIMULAR = $true
            Titulo 'SIMULACION - no se modifica nada'
            Correr ($SEGURAS + $AVANZADAS) $false
            Write-Host ''
            Nota 'Fin de la simulacion. No se toco el sistema.'
            Read-Host '   ENTER para volver al menu'
        }
        '4' {
            Clear-Host
            Titulo 'AJUSTES AVANZADOS'
            Aviso 'Estos ajustes pueden EMPEORAR la conexion segun el'
            Aviso 'entorno. Leer la descripcion de cada uno.'
            if (Asegurar-Respaldo) { Correr $AVANZADAS $true }
            Read-Host "`n   ENTER para volver al menu"
        }
        '5' { Clear-Host; Deshacer-Todo; Read-Host "`n   ENTER para volver al menu" }
        '6' { Clear-Host; Informe-Drivers; Read-Host "`n   ENTER para volver al menu" }
        '0' { $salir = $true }
        default { }
    }
}

try { $LOG | Out-File -LiteralPath $logFile -Encoding UTF8 } catch { }
Clear-Host
Write-Host ''
Write-Host '   CoexFix finalizado.' -ForegroundColor Green
Write-Host "   Registro: $logFile" -ForegroundColor Gray
if (Test-Path $archivo) {
    Write-Host "   Respaldo: $archivo" -ForegroundColor Gray
    Write-Host '   NO borrar ese archivo si se quiere revertir.' -ForegroundColor DarkYellow
}
Write-Host ''
Write-Host '   Conviene REINICIAR el equipo.' -ForegroundColor Yellow
Write-Host ''
Read-Host '   ENTER para cerrar'
