# CoexFix

**¿Se te cae el WiFi cuando conectás los auriculares Bluetooth?** Ese síntoma tiene causa concreta y solución. CoexFix la diagnostica y corrige lo que se puede corregir por software.

Windows 10 y 11. Sin instalación, sin dependencias, sin telemetría.

---

## El problema

El WiFi de 2.4 GHz y el Bluetooth ocupan la misma banda del espectro (2.400–2.4835 GHz). No es que se parezcan: comparten el aire. Bluetooth salta entre 79 canales unas 1600 veces por segundo, pisando los que usa el WiFi.

Cuando ambos adaptadores están enchufados uno al lado del otro aparece un segundo mecanismo, más severo que la colisión de paquetes: **desensibilización del receptor**. El WiFi intenta escuchar señales de unos −70 dBm mientras un transmisor Bluetooth emite a +4 dBm desde centímetros de distancia. Son ~74 dB de diferencia entrando por la misma antena. Un front-end con filtro SAW y buen blindaje lo tolera; un dongle genérico no.

Por eso el síntoma aparece **al habilitar Bluetooth**, sin importar si se reproduce audio o no. Y por eso suele notarse más bajo carga: con varias aplicaciones abiertas, el margen para absorber retransmisiones desaparece.

Los fabricantes lo saben. Varias fichas de adaptadores WiFi+BT recomiendan explícitamente usar 5 GHz cuando se usan auriculares Bluetooth.

## Estructura

```
CoexFix/
├── CoexFix-Guia.pdf
├── README.md
├── Diagnostico/
│   ├── CoexFix-Diagnostico.bat
│   └── CoexFix-Diagnostico.ps1
├── Reparar/
│   ├── CoexFix-Reparar.bat
│   └── CoexFix-Reparar.ps1
└── Respaldo/
    ├── CoexFix-Respaldo.bat
    └── CoexFix-Respaldo.ps1
```

> ### ⚠️ No separar los pares
>
> Cada `.bat` busca su `.ps1` **en la misma carpeta y con el mismo nombre**. Si movés uno solo, o descargás solo el `.bat`, la herramienta no funciona.
>
> - `CoexFix-Diagnostico.bat` necesita `CoexFix-Diagnostico.ps1` al lado
> - `CoexFix-Reparar.bat` necesita `CoexFix-Reparar.ps1` al lado
> - `CoexFix-Respaldo.bat` necesita `CoexFix-Respaldo.ps1` al lado
>
> Las tres carpetas sí pueden moverse por separado: cada herramienta es independiente. Lo que no se puede romper es el par.
>
> **Tampoco renombrar los archivos**, y **no abrirlos con un editor de texto** antes de ejecutarlos: algunos editores cambian los finales de línea al guardar y eso rompe el `.bat`.
>
> Si falta el `.ps1`, el programa avisa con un mensaje claro en vez de fallar en silencio.

## Instalación

No hay. Se descarga el repositorio, se ejecuta el `.bat` que corresponda con doble clic. Los permisos de administrador se solicitan solos.

```
Code → Download ZIP → extraer → ejecutar el .bat
```

Ambos archivos de cada par usan **rutas absolutas a `System32`**, así que funcionan incluso en equipos con el `PATH` del sistema dañado — un escenario más común de lo que parece y que rompe la mayoría de los scripts en silencio.

## Uso

| Paso | Carpeta | Acción |
|---|---|---|
| 1 | `Respaldo` | Ejecutar el `.bat`. Guarda el estado actual. **Hacerlo antes que nada.** |
| 2 | `Diagnostico` | Ejecutar el `.bat`. Genera un informe en el Escritorio. Solo lee. |
| 3 | `Reparar` | Ejecutar el `.bat` → **opción 3** (simulación). Muestra qué haría sin tocar nada. |
| 4 | `Reparar` | **Opción 1** (reparación segura). Reiniciar al terminar. |
| 5 | — | Probar 15 minutos con el Bluetooth conectado. |

Si algo empeoró, ejecutar `CoexFix-Respaldo` otra vez y restaurar.

### Menú de reparación

```
[1] Reparación segura (recomendado)
[2] Elegir paso por paso
[3] Simulación — no modifica nada
[4] Ajustes avanzados (pueden empeorar la conexión)
[5] DESHACER los cambios
[6] Informe de drivers (solo lectura)
```

## Qué revisa el diagnóstico

- Integridad del `PATH` del sistema, con detección de truncamiento por longitud
- Adaptadores de red: chipset, versión y antigüedad del driver
- Conexión actual: señal, canal, banda
- Escaneo de redes visibles clasificadas por banda — **responde si hay 5 GHz disponible**
- Adaptadores Bluetooth activos y fantasma; alerta si hay más de un stack activo
- Controladoras USB y radios conectadas por USB
- Ahorro de energía leyendo **los dos mecanismos** (WMI y `PnPCapabilities`), que pueden discrepar
- Propiedades avanzadas del WiFi: banda preferida, coexistencia, ancho de canal
- Dispositivos con error, identificando el chipset responsable
- Eventos de red y Bluetooth de los últimos 7 días, con interpretación de los códigos frecuentes

El informe se escribe **después de cada sección**. Si el script falla, el archivo muestra hasta dónde llegó y cuál fue el error.

## Qué corrige la reparación

**Seguras y reversibles:**

| Corrección | Por qué |
|---|---|
| Ahorro de energía USB | Windows suspende adaptadores por su cuenta; con drivers genéricos falla y cuelga al vecino |
| Suspensión selectiva de USB | Lo mismo, a nivel de plan de energía |
| Bluetooth Collaboration | Hace que ambas radios se turnen el aire; existe justamente para esto |
| Dispositivos fantasma | Dos stacks Bluetooth simultáneos generan conflictos |
| Servicios de ubicación | Windows los exige para listar redes WiFi |
| Rango de puertos UDP | Corrige el error `Tcpip 4266` (agotamiento de puertos) |

**Avanzadas, con confirmación individual:**

- **Forzar banda 5 GHz** — resuelve el problema de raíz, pero si la señal de 5 GHz es débil empeora la conexión. Y si el router no emite 5 GHz, no hace nada.
- **Ancho de canal 20 MHz** — en 2.4 GHz un canal de 40 MHz ocupa el doble de espectro en una banda de 83 MHz. Gana estabilidad, pierde velocidad máxima.

## Seguridad

Antes de cualquier modificación:

1. Punto de restauración de Windows
2. `CoexFix_respaldo.json` en el Escritorio, con el valor previo de cada opción
3. Copia inmutable como `CoexFix_respaldo_ORIGINAL.json`
4. Registro completo de las acciones realizadas

Reparación y respaldo **comparten el mismo archivo y el mismo esquema**: un solo sistema de deshacer, imposible que se desincronicen. Un respaldo existente nunca se sobrescribe sin archivar antes una copia.

**No borrar los archivos del Escritorio.**

### Límites deliberados

CoexFix **no**:

- **Instala drivers.** Los detecta y reporta cuáles faltan, pero descargarlos y aceptar licencias le corresponde al usuario.
- **Toca el `PATH`.** Si lo detecta dañado, avisa y guarda una copia legible. Escribirlo mal deja el equipo peor.
- **Configura el router.** Conflictos de IP y activación de 5 GHz se resuelven ahí.
- **Envía datos.** Todo queda en el equipo.

## Si no lo resuelve

El problema es físico, no de configuración:

| Solución | Efectividad |
|---|---|
| Cable Ethernet | Total — elimina el WiFi de la ecuación |
| Pasar el WiFi a 5 GHz | Alta — requiere router **y** adaptador con 5 GHz |
| Adaptador combo de un solo chip | Alta — coordina ambas radios por hardware |
| Alargue USB para separar los dongles | Parcial |
| Auriculares con cable | Total, si el BT solo se usa para audio |

**Antes de comprar cualquier adaptador**, verificá que el router emita 5 GHz. El informe de diagnóstico lo indica. Sin 5 GHz, cambiar de adaptador da una mejora parcial, no una solución.

## Advertencia de SmartScreen

Windows va a mostrar *"Windows protegió su PC"*. Es esperable: cualquier `.bat` sin firma digital comercial lo dispara.

**Más información → Ejecutar de todas formas.**

El código es texto plano. Se puede abrir con el Bloc de notas y leer completo antes de ejecutarlo — pero **no guardarlo desde el editor**. El diagnóstico usa exclusivamente cmdlets de lectura (`Get-*`, `show`, `query`).

## Estado del proyecto

Probado en **Windows 11 build 26200** y **Windows 10 22H2 build 19045**. Funciona, pero se probó en pocas máquinas: es esperable que aparezcan fallas en otras configuraciones.

Si algo no funciona, abrí un issue y adjuntá el informe del diagnóstico. Revisá antes que no incluya datos que no quieras compartir: contiene direcciones MAC y nombres de las redes WiFi cercanas.

## Licencia

MIT
