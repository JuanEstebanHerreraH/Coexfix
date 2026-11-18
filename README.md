# CoexFix

**Diagnóstico de problemas entre WiFi de 2,4 GHz y Bluetooth en Windows 10/11.**

Herramientas PowerShell para reunir información del equipo, evaluar ajustes por software y conservar respaldos que permitan revertir cambios.

[Explorar las herramientas](https://github.com/JuanEstebanHerreraH/Coexfix) · [Guía PDF](CoexFix-Guia.pdf) · [Reportar un problema](https://github.com/JuanEstebanHerreraH/Coexfix/issues)

Empieza por el diagnóstico. Mantén cada archivo BAT junto a su PS1 correspondiente; la guía detalla qué hace cada opción.

**Decisión de implementación:** diagnóstico, reparación y respaldo se separan para poder revisar el estado antes de aplicar ajustes.

**Alcance:** una interferencia puede depender del hardware, sus antenas o el entorno. La herramienta no garantiza corregirla por software; las operaciones administrativas se describen en la guía.

<details>
<summary><strong>Funciones, requisitos y documentación técnica</strong></summary>

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

</details>
