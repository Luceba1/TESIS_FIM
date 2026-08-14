# Protocolo experimental v2 – WatchDogs FIM

## Objetivo

Medir de forma reproducible el tiempo de detección y de respuesta del prototipo sin confundir el instante de ocurrencia del cambio con el inicio del ciclo de escaneo.

## Parámetros que deben fijarse antes de comenzar

Registrar en la planilla experimental y conservar sin cambios durante una serie:

- versión/commit exacto del proyecto;
- versión de Windows;
- hardware básico del equipo de prueba;
- `SCAN_INTERVAL_SECONDS`;
- ruta monitoreada;
- cantidad inicial de archivos y tamaño aproximado del conjunto;
- estado inicial de la línea base;
- estado del agente y del webhook n8n.

No modificar estos parámetros en mitad de una serie sin iniciar una serie nueva.

## Escenario automatizado

Como mínimo se ejecutarán 12 pruebas, cuatro por tipo de evento. Para una versión final orientada a una evaluación alta se recomienda aumentar las repeticiones, siempre que todas se documenten de forma completa.

Para cada repetición:

1. verificar que el agente esté activo;
2. verificar que la línea base corresponda al estado esperado;
3. ejecutar `scripts/run_experiment_event.ps1` indicando `CREATED`, `MODIFIED` o `DELETED`;
4. conservar la salida de consola del script;
5. comprobar la fila correspondiente en `file_changes`;
6. comprobar el estado en `file_hashes`;
7. comprobar el evento en el dashboard;
8. comprobar el webhook en n8n;
9. realizar la primera acción de revisión desde el panel para obtener MTTR;
10. exportar el CSV al finalizar la serie.

Ejemplos:

```powershell
.\scripts\run_experiment_event.ps1 -EventType CREATED -Path "C:\watchdogs_demo\sistema_academico\prueba_01.txt"
.\scripts\run_experiment_event.ps1 -EventType MODIFIED -Path "C:\watchdogs_demo\sistema_academico\config.json"
.\scripts\run_experiment_event.ps1 -EventType DELETED -Path "C:\watchdogs_demo\sistema_academico\backup_notas.sql"
```

## Escenario manual

El procedimiento manual debe fijarse antes de medir. Como mínimo hay que documentar:

- cantidad de operadores;
- experiencia o rol del operador;
- instrucciones exactas;
- periodicidad de revisión;
- si conoce o no qué archivo será alterado;
- mecanismo utilizado para registrar la hora de ejecución, detección y primera respuesta;
- orden de las pruebas y cantidad de repeticiones.

El mismo operador no debe cambiar la frecuencia de revisión entre pruebas. Si se utilizan varios operadores, los resultados deben conservar la identificación anónima del operador para poder explicar su variabilidad.

## Variables por fila

Cada prueba debe conservar, como mínimo:

- ID de prueba;
- escenario;
- tipo de evento;
- ruta;
- hora de comienzo de la acción;
- `occurred_at` de referencia;
- fuente de `occurred_at`;
- `detected_at`;
- `reviewed_at`;
- MTTD;
- latencia interna del escaneo;
- MTTR;
- scan run;
- coincidencia contra baseline;
- estado del webhook;
- referencia a captura/log/CSV.

## Cálculo

Para una prueba con referencia temporal válida:

```text
MTTD = detected_at - occurred_at
```

La latencia del ciclo se informa aparte:

```text
latencia_escaneo = detected_at - scan_run.started_at
```

Y la respuesta inicial documentada:

```text
MTTR = reviewed_at - detected_at
```

Nunca completar un valor faltante mediante estimación silenciosa. Si no existe una referencia válida, registrar `N/D` y explicar por qué.

## Evidencia

Cada resultado agregado del capítulo de resultados debe ser reconstruible a partir de filas del CSV y evidencia concreta. Las capturas sirven como evidencia visual; el CSV y la base de datos son la evidencia estructurada para los cálculos.

## Convención temporal

Todas las marcas de tiempo utilizadas en la matriz experimental deben conservar offset explícito y se exportan en UTC (`+00:00`). No se aceptarán timestamps sin zona horaria para calcular MTTD o MTTR. Esta convención evita que la zona local de Windows, PostgreSQL o PowerShell altere la interpretación de una medición.
