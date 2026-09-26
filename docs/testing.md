# Estrategia de pruebas y evidencia

Esta fase no crea tests de implementación. Aquí se define el contrato de verificación futuro. No hay resultados de tests de app que reportar todavía.

Alcance revisado el 2026-09-26: Apple silicon exclusivamente; backup/recuperación e intercambio `.ics` DATE/UTC forman parte del MVP. Compatibilidad amplia con zonas, recurrencias e invitaciones continúa fuera de alcance.

Swift Testing para dominio, codecs, repositorios y pruebas parametrizadas; XCTest/XCUITest para UI y las integraciones que requieran su infraestructura. No mezclar APIs de ambos frameworks dentro del mismo test. Host firmado para políticas macOS reales. [Apple: Swift Testing](https://developer.apple.com/documentation/testing), [XCTest](https://developer.apple.com/documentation/xctest).

## Infraestructura

Fixtures sintéticas, temporales aislados y bundle ID/servicio Keychain propios de test. Clock y timezone resolver inyectables, IDs deterministas solo en fixture y RNG de tests separado de producción. Tests ordinarios sin red; corpus .ics versionado localmente. Tests de Keychain real nunca usan el item de usuario ni lo enumeran/borran por comodines. UI screenshots/logs con datos ficticios únicamente.

Ejecutar lógica en paquete local; usar xcodebuild en integración; las pruebas de sandbox, firma, Touch ID, suspensión y FileVault requieren cuenta/VM/equipo apropiado y algunas comprobaciones manuales. No fingir que un mock de Keychain valida ACL. Definir matriz de macOS mínimo y versiones soportadas únicamente en Apple silicon; comprobar que el artefacto es arm64, sin slice Intel ni requisito Rosetta. Separar canarios de test para no empaquetarlos en Release.

## Matriz de cobertura

| Grupo / amenazas | Casos obligatorios | Evidencia/criterio |
|---|---|---|
| Dominio T24 | IDs, pertenencia, títulos/longitudes, revisión, delete calendar, intervalos | Rechaza inválidos, conserva válidos; ningún write ante validación fallida |
| Fechas T24/T26 | Negativos pre-1970, bisiestos 1900/2000, 31/04, rango 0001/9999, overflow, medianoche | Componentes ida/vuelta; finales exclusivos, sin normalización silenciosa |
| Zonas/DST T24 | Madrid gap/fold, America/New_York, Australia/Lord_Howe (cambio de media hora), Pacific/Apia (día omitido), UTC | Sin asumir saltos de una hora; hora local/instante según variante; fixtures revisadas por reglas de zona |
| Recurrencias T24/T26 | COUNT/UNTIL, DTSTART, intervalos, weekly días, 31 mensual, 29 febrero anual, EXDATE, hora inexistente | Oráculos de secuencias finitas calculados independientemente; COUNT no cambia por exclusión |
| Búsquedas T22/T24 | Rango vacío, event largo desde antes, medianoche, Unicode/acento, calendario, límite | No omisiones por índice; resultado incompleto se señala, no truncamiento silencioso |
| CRUD SQLite T05/T24 | create/update/delete/mover, FK, cascade, unicidad cifrada y payload | Estado de DB y dominio concordantes tras reopen; no plaintext en binds |
| Migraciones T24/T28 | Cada versión soportada, nuevo formato, fallo mitad, disco lleno, cierre abrupto | Original o nueva versión íntegra; user_version coherente; backup previo usable |
| Concurrencia T24 | Lecturas/escrituras simultáneas, reentrancia, segunda ventana/instancia, cancelación | Una conexión propietaria; sin lost update ni callback viejo mostrado |
| AEAD T05/T22/T27 | Round-trip, clave incorrecta, nonce nuevo, bit flip en ciphertext/tag/AAD, swap filas/padres | Toda alteración vinculada falla; jamás datos parciales; casos documentados de replay no detectado |
| Keychain T03/T20/T28 | Crear/leerse, cancelación, item ausente/duplicate, firma distinta, no biometría, llavero no disponible | No fallback inseguro; item protegido de verdad en host firmado; UI no confunde fallo con bóveda vacía |
| Bloqueo T01/T10/T11 | Manual, inactividad, suspensión, sesión, panel/auth, exportación/restauración en curso | Ocultación inmediata, tareas/generación invalidadas, secretos no accesibles por API tras cierre |
| Backup/restore T06/T28 | DB sola, kit correcto/erróneo, otro Mac, corrupta, versión futura, interrupciones | Solo restaura pareja válida; original conservado ante fallo; kit nunca dentro de copia |
| Exportador .ics | Fixtures canónicas, Unicode/plegado, UID, fechas/DST, conversiones, límite/cancelación, destino fallido | Salida semánticamente correcta; pérdidas explícitas; sin parser de producción para probarla |
| Parser T26 | UTF-8, líneas gigantes, escapes, URLs, attachments, propiedades no soportadas, duplicados | Rechazo acotado y atómico; fuzzing amplio y perfiles TZID/RRULE siguen como ampliación |
| UI | Crear/editar/borrar, zona/all-day, bloquear, error de disco, backup/restore, export/import | Flujos accesibles por teclado y VoiceOver; importación solo mediante selector explícito |

**Cobertura ya implementada:** el paquete prueba migración inicial/repetida y rollback, rechazo de versión futura, metadata, envelopes opacos, foreign keys restrict/cascade, CRUD de eventos, límites de tamaño, integridad y una escritura concurrente serializada. También escanea el archivo temporal por un sentinel plaintext. No incluye todavía reopen con repositorios, concurrencia de transacciones multioperación ni prueba real de ACL Keychain; esos gates siguen pendientes.

## Pruebas específicas de privacidad

**P01 — Red (T16/T26/T30).** Inspección estática de imports/APIs y entitlements finales más ejecución observada por proceso, con y sin conectividad. Cubrir todos los flujos del MVP, contenido con URLs en notas/ubicación y backups hostiles. Verificar que intentar abrir un .ics no active ningún importador del producto. Las entradas ALTREP/TZURL y demás corpus de importación se reservan para esa función futura. Resultado: cero intentos DNS/TCP/UDP de app y cero delegación de apertura remota. Control negativo de sandbox en test host independiente. Captura global del Mac sin atribución no permite culpar o absolver a Kansolendar.

**P02 — Dependencias/endpoints (T04/T21).** Verificar ausencia de paquetes remotos, SDKs analytics/crash, frameworks embebidos ajenos, scripts que descargan ejecutables y endpoints en resources. Comparar frameworks y entitlements del archive con allowlist. URLs documentales no se consideran llamadas; investigar strings de dominio en binario y justificar metadatos legítimos. Foundation del sistema enlazado no es un analytics SDK.

**P03 — Logs (T08/T09/T25).** Inyectar canarios distintos en cada campo, ruta/UID y errores malformados. Revisar stdout/stderr, Unified Logging y reportes de crash sintéticos en Debug y Release. Ningún canario ni representación serializada/Base64 conocida; revisión de la allowlist del logger evita depender solo de búsquedas. No subir esos artefactos a servicio externo.

**P04 — Disco (T05/T07/T12/T23).** Snapshot antes/después de CRUD, migración, cancelación, crash y bloqueo: contenedor, caches, Preferences, Saved Application State, staging, DB/journal y WAL/SHM si apareciesen. Buscar canarios y extraer todos los campos SQLite legibles. Excepciones permitidas: .ics o kit que el usuario de test exportó explícitamente al destino designado; no copias extra. Ausencia de strings es evidencia parcial: además verificar arquitectura de binding y usar inspección estructural.

**P05 — Integración de sistema (T13–T15/T29).** Buscar canarios con Spotlight, abrir Quick Look de backup, revisar recientes, menús, título, Dock y árbol Accessibility tras bloqueo. Verificar que el nombre de la .app siga encontrándose. No exigir que exportación .ics quede oculta al sistema. Probar Mission Control/suspensión y advertir límites de captura.

**P06 — Secretos (T10/T11/T20).** Verificar ámbito/lifetime de DEK, ausencia en UserDefaults/archivos/errores, no sincronización del item y revocación de APIs al bloquear. Instrumentación de memoria puede detectar retenciones, pero no demuestra zeroización completa ni ausencia de swap. No convertir una prueba puntual en garantía ante root.

## Fallos y recuperación

Inyección de fallos en cada frontera: antes/después de Keychain add, staging, commit, snapshot, rename y actualización de índice. Interrumpir proceso de test para simular crash; probar disco lleno y permisos en volumen/fixtures aislados. Tras reinicio debe existir un estado explicado y recuperable, nunca una bóveda vacía creada encima de otra.

Backup hostil: esquema con triggers/views inesperados, blobs enormes, filas sin padres, tags inválidos y replay de copia válida. Replay debe documentarse como límite conocido, no falsear un test que «lo detecta». Pruebas de restauración reales en cuenta nueva sin item Keychain, usando kit separado. Un backup no validado por restauración no cierra el gate de recuperación.

Fuzzing local del decodificador de payloads/recuperación con corpus sintético, límites de tiempo/memoria e input minimizado para bugs. Para exportación, generar valores de dominio válidos y comparar resultados con fixtures/oráculos independientes. Fuzzing del parser .ics se aplaza con la importación. Sanitizers/Thread Sanitizer donde soportados para puente C y concurrencia; sin datos reales. No escribir tests que repitan la misma lógica de expansión como oráculo.

## Rendimiento y gates

Medir 10 000 maestros/100 MiB de payload acumulado, consulta de mes con series y desbloqueo. No exigir rendimiento antes de corrección; límites y tiempos objetivo se fijarán tras primer prototipo autorizado. La UI debe seguir respondiendo y la cancelación tener latencia acotada. Si hay límite, mensaje explícito; no persistir índices en claro para pasar benchmark.

Gate de release: suites de dominio/persistencia/seguridad/codec aprobadas, migraciones/restore probadas, auditoría P01–P06 sin hallazgos críticos, firma/entitlements revisados, primera ejecución sin red y revisión humana de privacidad. Evidencia local por versión/commit, OS/SDK/hardware/configuración, pasos y resultado. No porcentaje de cobertura como sustituto de escenarios. Repetir controles afectados por cada cambio; la auditoría completa se reserva para candidatos de distribución o cambios de superficie.
