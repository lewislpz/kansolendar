# Seguridad y cifrado

Estado: el alcance fue aceptado el 2026-09-25 y el codec de envelope v1, el ciclo de clave, el actor SQLite, el codec de payloads y la fachada de bóveda tienen implementación y pruebas con fixtures. La primera pantalla permite pedir crear/desbloquear/bloquear la bóveda. La validación firmada de Keychain pasó el 2026-09-26 para creación, lectura con presencia, cancelación y reapertura. El flujo de backup/recuperación y la revisión independiente siguen pendientes; esos límites impiden considerar completa la Fase D. Amenazas de referencia: T01–T30. Q01 / [ADR-0004](adr/0004-encryption.md) registra la aceptación; Q02/Q08 siguen abiertos.

La importación .ics está fuera del MVP por decisión posterior del propietario. Los requisitos de seguridad del importador se conservan para una ampliación futura, sin código ni entrada anticipados. Backup/restore y decodificación de payloads sí mantienen todas las defensas de entrada hostil desde el MVP.

## Cuatro protecciones distintas

| Capa | Protege | No protege |
|---|---|---|
| FileVault | Volumen del dispositivo ante acceso offline no autorizado | Archivos copiados desde sesión autorizada, exportaciones o malware en sesión |
| Bloqueo de aplicación | Presentación y acceso de operaciones a datos durante sesión cerrada | Capturas previas, usuario con credenciales, dumps ya obtenidos |
| Cifrado de contenido persistido | Datos sensibles en DB/copias sin la clave | Metadatos dejados en claro, datos en uso, pérdida de disponibilidad |
| Keychain | Custodia y políticas de acceso a la clave | Todo compromiso del OS ni secreto que se exportó para recuperación |

En Apple silicon/T2 el cifrado del almacenamiento y FileVault tienen matices diferentes; no interpretar «disco cifrado por hardware» como autenticación FileVault activada. Kansolendar recomienda FileVault sin requerir permisos para activarlo o administrarlo. [Apple: cifrado de volúmenes](https://support.apple.com/en-au/guide/security/sec4c6dc1b6e/web).

## Conflicto SQLite cifrada / cero dependencias

SQLite ordinario no proporciona cifrado transparente de páginas; SEE es una extensión adicional con licencia y otra distribución de SQLite. CryptoKit aporta primitivas, no un motor SQL cifrado. [SQLite: SEE](https://www.sqlite.org/see/doc/trunk/www/readme.wiki).

| Alternativa | Ventajas | Límites y decisión |
|---|---|---|
| SQLite + solo FileVault | Máxima sencillez, índices SQL normales | Copiar DB desde sesión deja datos legibles; insuficiente para T05/T06 |
| Payloads CryptoKit dentro de SQLite | APIs nativas; contenido nunca entra legible al motor | Estructura/relaciones visibles; consultas en RAM; propuesta MVP |
| SQLite en RAM + snapshot completo AES-GCM | Archivo exterior opaco; cero dependencias criptográficas | Serializar DB completa, alto uso RAM, durabilidad/atomicidad propias y recuperación compleja; no elegido |
| Imagen de disco/volumen cifrado macOS | Cifrado de filesystem sin librería adicional | Montaje, UX, permisos y datos expuestos mientras montado; no equivale a DB integrada; no elegido |
| SQLCipher / SEE | Solución especializada de páginas; índices SQL sobre contenido al abrir | Dependencia y mantenimiento/licencia; cambia stack cerrado; solo alternativa si se aprueba excepción |
| VFS/codec SQLite propio | Control de páginas | Criptografía de almacenamiento y journals difícil de auditar; contradice simplicidad y no cripto propia; rechazado |

SQLCipher es una alternativa externa, no una dependencia añadida: [proyecto oficial](https://www.zetetic.net/sqlcipher/). No se ha seleccionado una edición, versión ni licencia. El propietario ha aceptado **cifrado del contenido**, con sus metadatos visibles (2026-09-25). Una exigencia posterior de ocultar toda la DB requeriría revisar el stack; este diseño no ofrece esa propiedad.

## Envelope concreto propuesto

Una clave simétrica DEK aleatoria de 256 bits por bóveda. AES-256-GCM mediante CryptoKit; API genera nonce aleatorio fresco de 96 bits para **cada** sellado, incluidos retries, modificaciones, control, migraciones y copias transformadas. Tag completo de 128 bits. No derivar nonce del ID, hora, revisión o número de fila; no reutilizar nonce al cambiar plaintext. No hashes de contraseñas, ciphers caseros ni RNG propio. CryptoKit proporciona cifrado autenticado con AES.GCM. [Apple: AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm).

### Formato congelado v1

El codec `PayloadEnvelope` implementa el siguiente layout, sin longitudes redundantes:

```text
magic[4] = 4b 4e 53 4c (ASCII KNSL)
version[1] = 01
nonce[12] = nonce aleatorio AES-GCM
ciphertext[n], 0 <= n <= 131072
tag[16] = tag completo AES-GCM
```

El tamaño mínimo es 33 bytes; máximo 131105. Valores de longitud inválidos o fuera de límite fallan antes de abrir. Versiones desconocidas se rechazan sin fallback. El nonce se genera con `AES.GCM.Nonce()` en el camino público de sellado. La inyección determinista de nonce solo es interna para construir vectores de prueba.

AAD es la concatenación exacta, sin longitud dinámica: UTF-8 `com.kansolendar.payload`, byte cero, magic `KNSL`, version `01`, UUID de vault (16 bytes en orden `UUID.uuid` de Foundation), UUID de key (16 bytes), kind (1 byte), UUID de registro (16 bytes), parent marker (`00` ausente o `01` presente) y, si es `01`, UUID parent (16 bytes). Kinds v1: control `01`, calendar `10`, event `11`, reminder `12`, event exception `13`. No hay enteros multibyte que necesiten endian. Cambiar estructura, kind o identidad produce fallo AEAD. No incluir versión SQL mutable.

El vector de regresión vive en `PayloadEnvelopeTests.swift`; usa datos/clave/nonce ficticios y nonce fijo exclusivamente en pruebas. Cada implementación futura del codec debe conservarlo o introducir explícitamente otra versión. Tag/nonce/ciphertext alterados y contextos cruzados se rechazan sin plaintext parcial.

Plaintext = payload versionado de la entidad en una codificación UTF-8 estructurada determinista acordada durante implementación (JSON con esquema estricto es suficiente; no requiere JSON1). Límites y tipos se validan después de autenticar; JSON no puede ejecutar tipos ni aceptar decodificación arbitraria. El texto temporal exacto se representa mediante números/componentes, nunca formatos localizados.

La AAD v1 ya está congelada y usa campos fijos:

`producto/formato + envelopeVersion + vaultID + keyID + tipoDeRegistro + recordID + parentID`

Para control no hay parentID, y se usa un discriminante explícito. Para evento, parentID es calendarID; para excepción, parentID es eventID. Mover un evento entre calendarios exige nuevo sellado. Esto impide intercambiar blobs entre filas, padres, tipos o bóvedas sin fallar autenticación. AAD no es secreto. Reminder y exception son tipos reservados para persistencia futura, todavía fuera del MVP.

No incluir versión SQL mutable ni estado de UI en AAD. Clave identificada por keyID público único; MVP admite una activa por bóveda. Los envelopes desconocidos se rechazan, no se intentan algoritmos alternativos. Una operación que falla al autenticar no devuelve texto parcial.

AES-GCM autentica cada registro, no la existencia de todos los registros ni su frescura. Un atacante con escritura puede borrar filas o restaurar una copia previa válida; la PK/FK no lo detecta en todos los casos. No proponer un contador local como garantía antirrollback. Añadir inventario autenticado requeriría otro ADR y tampoco impediría replay de una copia completa sin estado confiable exterior.

## Qué permanece visible

Cabecera SQLite, nombres de tablas/columnas, versiones, vaultID/keyID y UUID de registros, relaciones calendario→eventos→excepciones, número de filas, tamaños de payload, tamaño/fechas del archivo y patrones de cambio entre copias. Cifrar nombre del calendario, color, orden, contenido, fechas, zonas, reglas, UID y preferencias privadas.

Sin padding inicial: longitud del ciphertext aproxima longitud del contenido. No cifrado determinista, hash de título ni HMAC indexado en disco. La distribución de índices/memoria está en [database.md](database.md). La metadata residual es una concesión revisable, no un defecto oculto.

## Datos en uso y bloqueo

Solo Storage conserva DEK durante sesión desbloqueada. Las vistas reciben los datos que necesitan, nunca la clave. El índice y los editores tienen contenido legible; módulos no crean barreras de memoria. Al bloquear se invalidan operaciones, se oculta UI, se eliminan referencias y cachés, undo, selección e importaciones pendientes; se libera la clave y el contexto de autenticación. No retrasar ocultación esperando al disco.

Swift/ARC, strings, copy-on-write y frameworks pueden producir copias; vaciar una variable no garantiza borrado físico de RAM, swap o dumps. Evitar convertir claves en String salvo exportación de recuperación explícita, evitar copias grandes y no usar memoria mapeada para plaintext. No prometer «memoria segura» basada en `mlock` o zeroización parcial. FileVault reduce riesgos de almacenamiento pero no sustituye la gestión de sesión.

## Entrada hostil y código nativo

Todo .ics, backup, payload, preferencia y ruta externa se valida. Límites antes de reservar memoria; sumas/multiplicaciones con detección de overflow; ningún `fatalError` para entradas del usuario. No ejecutar scripts, HTML, acciones de alarma, consultas SQL ni abrir URI de documentos. Usar descriptores locales, rechazar archivos especiales/directorios inesperados y controlar sustitución de ruta/symlinks durante operaciones sensibles. No descomprimir contenedores recibidos en MVP.

SQLite C encapsulado; no exponer punteros, ownership de buffers explícito y binding que no retenga memoria Swift de vida insuficiente. No shared mutable state ni `@unchecked Sendable` sin justificación localizada. Cada `await` exige revalidar sesión; no guardar tras logout por callback antiguo. Statements SQL constantes; errores de parser sin el contenido ofensivo.

Release firmada, sandbox y hardened runtime; no JIT, carga de plugins, Apple Events, librerías inyectadas permitidas ni get-task-allow. Sanitizers y fuzzing con datos sintéticos en desarrollo. Firma/notarización no prueban que el código sea seguro. Ver [distribución](distribution.md) y [testing](testing.md).

## Borrado y recuperación

Borrar evento elimina la fila y referencias activas. Pueden quedar ciphertext y versiones antiguas en páginas, journals y backups, descifrables con la DEK vigente. Rotar DEK no revoca copias que incluyen la clave anterior; borrar item Keychain tampoco borra recuperación externa. Sin garantía de borrado forense ni «destrucción criptográfica» absoluta.

Restaurar no es resetear: validar copia y clave antes de sustituir datos. La pérdida de DEK y recuperación es irreversible. [Claves](key-management.md) y [backups](backups.md) definen la única vía portable propuesta.
