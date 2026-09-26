# Backups y restauración

Una exportación .ics es intercambio legible y potencialmente incompleto; **no es un backup**. Un backup de Kansolendar conserva estructura, payloads cifrados, excepciones, UID y preferencias privadas. Nunca incluye la DEK ni el kit de recuperación.

Estado de implementación (2026-09-26): la app crea un snapshot `.kansobackup` mediante SQLite Online Backup mientras la bóveda está desbloqueada, comprueba integridad, claves foráneas y autenticación/decodificación de todos los payloads, sincroniza el archivo y lo publica con permisos `0600` sin sobrescribir destinos existentes. También exporta, tras una nueva autorización de macOS, un kit de recuperación textual v1 estricto y acotado sin entregar la DEK a la UI. La restauración copia el backup elegido a staging privado, valida esquema, identidad, clave y todas las filas antes de instalarlo, conserva una copia de seguridad de la bóveda activa durante la operación y revierte ante error.

## Tipos y riesgos

| Tipo | Comportamiento propuesto | Clave y limitación |
|---|---|---|
| Time Machine | No excluir por defecto Application Support de la bóveda | No confiar en que recupere el item Keychain en otro Mac; recomendar disco de backup cifrado y kit separado |
| Copia manual con app cerrada | Copiar conjunto consistente tras cierre limpio; preferir backup desde app | DB independiente requiere DEK; no copiar solo un archivo activo sin conocer journal |
| Duplicación con app abierta | No considerar copia de Finder un backup verificado | Puede omitir transacciones/journal; restaurar primero en staging |
| Backup explícito de app | Snapshot con SQLite Online Backup API hacia archivo privado de staging | Destino ya contiene solo payloads cifrados; separado de clave |
| Exportación .ics | Archivo legible en ubicación elegida, con advertencia | No necesita clave; puede filtrarse a índice, Quick Look o cloud |
| Kit de recuperación | Exportación distinta, autenticada y deliberada | Contiene DEK legible; no guardar con DB/copias |

SQLite proporciona una API de backup consistente; copiar un archivo abierto no es equivalente. El modo journal y los escritores afectan a consistencia. Se propone serializar el backup con el actor y verificar destino antes de publicarlo. [SQLite Online Backup API](https://www.sqlite.org/backup.html).

## Flujo de backup explícito

1. Sesión desbloqueada y acción del usuario. Selector con nombre neutro y extensión propia propuesta `.kansobackup`; es una DB snapshot, no un ZIP ni formato cifrado adicional.
2. Detener nuevas escrituras durante snapshot breve. Crear staging 0600 en contenedor usando nombre aleatorio, sin incluir títulos/fechas de eventos.
3. Online Backup API copia SQLite ya cifrada a nivel de payload; finalizar, comprobar integridad/FK y autenticación; cerrar destino y sincronizar según política de durabilidad.
4. Publicar al destino seleccionado, usando sustitución atómica cuando lo permita el filesystem y la autorización del panel. Un parcial nunca se anuncia como backup correcto. Si se requiere staging en destino, solo ciphertext y permisos restrictivos.
5. Retirar staging propio y acceso security-scoped. No añadir a recientes ni retener ruta. Al cancelar conservar el backup anterior si lo había; informar de cualquier parcial que no pueda eliminarse.

No guardar copia de plaintext, JSON de diagnóstico, SQL dump descifrado o .ics junto al backup. No «autoexportación» al cerrar. Un checksum externo podría detectar transporte accidental, pero integridad de SQLite y tags siguen siendo necesarios y no detectan replay completo.

## Time Machine y snapshots

No controlar ni configurar Time Machine desde la app. La DB contiene ciphertext también en versiones antiguas, siempre que nunca existiera persistencia previa en claro. El sistema puede conservar journals y snapshots; una captura en caliente requiere validación al restaurar, no asumir copia perfecta. No borrar manualmente el hot journal antes de dejar a SQLite recuperar una copia autorizada.

Time Machine, APFS y herramientas externas pueden retener archivos eliminados. No prometer purgar esas copias. Excluir la bóveda de backup por privacidad aumentaría pérdida de datos sin ocultar necesariamente otros snapshots; no se recomienda por defecto. La seguridad del soporte de backup importa porque conserva metadatos y quizá otros secretos del usuario fuera de Kansolendar.

## Matriz de restauración

| Situación | Resultado esperado |
|---|---|
| Mismo Mac, mismo Keychain y firma, clave válida | Autenticar, verificar copia y restaurar |
| Mismo Mac, llavero borrado/reset | Solicitar kit; no reconstruir clave |
| Nuevo Mac o nueva cuenta | Requerir kit, crear item local; no depender de migración del llavero |
| Solo .app | Programa sin datos; no es backup |
| Solo DB sin clave | Contenido no recuperable; conservar copia para localizar kit |
| DB + kit equivocado | Rechazar sin reemplazar nada |
| Backup previo a rotación futura | Necesita clave/kit de esa época |
| DB de versión futura | Rechazar escritura y ofrecer versión compatible; sin downgrade automático |
| Backup íntegro pero antiguo | Es restaurable; no se garantiza detectar antigüedad maliciosa |

## Restauración segura

Seleccionar archivo regular con límite de tamaño; copiar ciphertext a staging interno. Tratar esquema y cabecera como hostiles, verificar allowlist y límites antes de ejecutar escrituras. Resolver clave por identidad; si falta, pedir kit mediante selector. La autenticación de control no basta: validar todas las filas, relaciones, unicidad de UID/excepciones y reglas temporales antes de aceptar.

Crear snapshot previo de la bóveda activa, cuando sea legible, y cerrar conexiones. Instalar copia validada sin sobreescribir el único original recuperable; mantener journal/copia de la operación para decidir tras interrupción cuál está activa. El orden Keychain/archivo sigue [key-management.md](key-management.md), pues no hay transacción común. Publicar éxito solo cuando la app reabra y lea la bóveda instalada. No mezclar automáticamente dos bóvedas ni importar SQL del archivo.

Si restore requiere migración, trabajar sobre copia y seguir el proceso versionado. Si falla, conservar la activa anterior y el backup elegido. Una política de retención propuesta es conservar la copia previa hasta verificación de reapertura; antes de quitarla, comprobar que el usuario tiene vía de recuperación. Ninguna limpieza automática elimina backups externos.

## Limitación fundamental

El producto puede impedir sus propias subidas y cifrar su almacenamiento; no puede garantizar que datos nunca salgan del dispositivo si el usuario copia archivos, elige un proveedor sincronizado o tiene software de backup remoto. El MVP no incorpora esos servicios. Documentarlo es necesario para que «offline-only» describa capacidades reales y no el control absoluto del Mac.
