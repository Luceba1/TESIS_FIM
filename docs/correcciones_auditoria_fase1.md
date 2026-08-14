# Correcciones técnicas – Fase 1 de la auditoría

Esta fase corrige los puntos del artefacto que afectaban directamente la validez de las métricas y la confiabilidad del motor. No contiene resultados experimentales inventados: las cifras del capítulo 6 deben recalcularse después de ejecutar el protocolo real.

## 1. MTTD: separación del constructo y la latencia interna

Antes, el dashboard calculaba MTTD como:

```text
detected_at - scan_run.started_at
```

Ese valor describe cuánto tardó el ciclo de escaneo en registrar el evento una vez iniciado, pero no cuánto transcurrió desde que ocurrió el cambio.

Ahora se conservan dos métricas distintas:

- **MTTD:** `detected_at - occurred_at`.
- **Latencia interna del escaneo:** `detected_at - scan_run.started_at`.

`occurred_at` puede provenir de:

- `FILE_MTIME` para CREATED/MODIFIED, como aproximación basada en el sistema de archivos.
- `EXPERIMENT_CONTROLLED` cuando el evento se ejecuta mediante el script de medición y se adjunta una marca temporal externa.
- `UNKNOWN` cuando no existe una referencia temporal válida. En particular, un borrado detectado por polling no permite reconstruir por sí solo el instante exacto de eliminación.

Los eventos sin `occurred_at` quedan fuera del promedio MTTD y el dashboard informa cuántos casos tienen o no una referencia válida.

## 2. Línea base aprobada vs. estado observado

Antes, cuando se detectaba una modificación, el hash guardado en `file_hashes` se reemplazaba automáticamente por el hash nuevo. Eso convertía el contenido alterado en la nueva referencia sin intervención del operador.

Ahora `file_hashes` separa:

- **línea base aprobada:** `sha256`, `md5`, `size_bytes`, `last_modified`;
- **estado observado:** `observed_sha256`, `observed_md5`, `observed_size_bytes`, `observed_last_modified`.

Un escaneo actualiza únicamente el estado observado. La línea base se modifica solo mediante una acción explícita:

```text
POST /api/v1/baseline/generate
POST /api/v1/baseline/{file_hash_id}/approve-current
```

Un archivo nuevo descubierto por el monitor se registra con `baseline_approved=false` hasta que el operador lo apruebe.

## 3. Fallas aisladas de archivos

Antes, una excepción durante la lectura de un archivo podía abortar el escaneo completo.

Ahora:

- cada archivo se procesa de forma tolerante a fallas;
- los archivos no legibles se contabilizan en `files_skipped`;
- las advertencias quedan en `warning_message`;
- el escaneo se marca `PARTIAL` cuando termina con omisiones;
- si la enumeración de una carpeta fue incompleta, no se infieren eliminaciones dentro de esa ruta.

## 4. Lectura concurrente

El hash y los metadatos ya no se aceptan sin verificar que el archivo permaneció estable durante la lectura. El motor compara tamaño y `mtime` antes y después del hashing y reintenta hasta tres veces si detecta una escritura concurrente.

## 5. Evidencia experimental

Se agregó:

```text
PATCH /api/v1/changes/{change_id}/event-time
```

para asociar una marca temporal de referencia a una detección, y el script:

```text
scripts/run_experiment_event.ps1
```

que ejecuta un evento controlado, espera su detección y vincula el tiempo de ocurrencia. El CSV exportado incluye todas las marcas necesarias para recalcular MTTD, latencia interna y MTTR fuera del sistema.

## 6. Esquema y documentación

`database/schema.sql` fue actualizado para corresponder con el modelo real del backend. También se actualizaron el payload de n8n, los DTO y el dashboard para mostrar las nuevas variables sin presentar la latencia de escaneo como MTTD.

## 7. Normalización temporal y zonas horarias

Durante la primera validación experimental se detectó una inconsistencia entre una marca `occurred_at` con zona horaria y columnas históricas creadas como `timestamp without time zone`. En un equipo UTC-3, por ejemplo, un evento podía quedar representado como `02:16` sin offset mientras la referencia experimental correspondía a `05:16 UTC`; al perderse la zona, el cálculo podía resultar negativo y terminar truncado a cero.

La corrección incorpora tres medidas:

- todas las columnas temporales operativas del modelo se declaran con `DateTime(timezone=True)`;
- al iniciar el backend, una migración idempotente convierte columnas legacy `timestamp without time zone` a `TIMESTAMPTZ`, interpretando sus valores con la zona horaria que PostgreSQL venía usando en esa sesión;
- la API de eventos, el CSV y el payload de n8n normalizan las marcas a UTC con offset explícito.

El script experimental utiliza `DateTimeOffset` para no perder información de zona al interpretar las fechas devueltas por la API. Como prueba de regresión se verifica que `2026-08-11T02:16:17.973707-03:00` y `2026-08-11T05:16:17.973707+00:00` representen el mismo instante y produzcan el mismo MTTD.
