# Inicio automático en Windows - WatchDogs FIM

Esta versión usa la **opción 1** definida para la tesis: iniciar el sistema mediante una **Tarea Programada de Windows**.

La idea central es que el navegador no necesita abrirse al iniciar Windows. El navegador solo muestra el panel visual. Lo que debe iniciarse automáticamente es el **backend/agente**, porque ese proceso contiene el monitor FIM que escanea los entornos activos.

## Componentes

- **Frontend React**: panel web para administrar entornos, rutas, eventos y métricas.
- **Backend FastAPI**: API del sistema y control del monitor.
- **Monitor FIM**: proceso en segundo plano integrado al backend. Escanea los entornos activos y detecta archivos creados, modificados o eliminados.
- **PostgreSQL**: persistencia de evidencia.

## Archivos incluidos

```txt
scripts/start_watchdogs_backend.ps1
scripts/start_watchdogs_backend.bat
scripts/install_watchdogs_task.ps1
scripts/uninstall_watchdogs_task.ps1
logs/watchdogs_backend.log
```

## Instalación como tarea programada

Abrir PowerShell en la raíz del proyecto y ejecutar:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\install_watchdogs_task.ps1
```

Esto crea una tarea llamada:

```txt
WatchDogs FIM Agent
```

La tarea se ejecuta **al iniciar sesión en Windows** y lanza el backend con el monitor automático.

## Iniciar la tarea manualmente

Para probar sin reiniciar la PC:

```powershell
Start-ScheduledTask -TaskName "WatchDogs FIM Agent"
```

Después se puede verificar el estado desde:

```txt
http://127.0.0.1:8000/docs
GET /api/v1/agent/status
```

O desde el panel web si el frontend está corriendo.

## Ver logs

El log del backend se guarda en:

```txt
logs/watchdogs_backend.log
```

Ahí se puede revisar si Docker, PostgreSQL, FastAPI o el monitor tuvieron algún error al iniciar.

## Desinstalar la tarea

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\uninstall_watchdogs_task.ps1
```

## Aclaración para la tesis

Esta implementación corresponde a una solución reproducible y simple para la etapa de prototipo. Permite demostrar que el monitor se ejecuta automáticamente al iniciar Windows sin requerir que el usuario abra manualmente una consola.

Como mejora futura, se propone evolucionar este mecanismo hacia un **instalador ejecutable** que registre el agente como **Servicio de Windows**. De esa forma, el sistema podría instalarse con un asistente, iniciar automáticamente con el sistema operativo, administrarse desde Servicios de Windows y ejecutarse con mayor robustez operativa.
