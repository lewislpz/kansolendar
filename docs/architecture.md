# Arquitectura

Estado: implementación aprobada; persistencia segura aún bloqueada por pruebas de integración. Revisar [amenazas](threat-model.md) y [concerns](open-questions.md).

## Forma del producto y decisiones base

Aplicación macOS nativa `.app`, Swift 6 y SwiftUI. SQLite del SDK, sin ORM ni SwiftData. CryptoKit, Security/Keychain, Foundation y pequeños adaptadores AppKit cuando SwiftUI no exponga una integración necesaria. AppKit no sustituye la UI SwiftUI. Sin EventKit, red, servicios externos, procesos auxiliares, extensiones ni dependencias de terceros.

macOS 14 es el mínimo aprobado para implementación/MVP por el propietario el 2026-09-26. No es promesa de soporte indefinido; revisar antes de distribución futura. Fijar y probar la versión de Xcode/SDK disponible para macOS 14 antes de las pruebas firmadas de Keychain. Swift 6 no obliga por sí solo a usar la última versión del sistema operativo.

Hardware decidido por el propietario el 2026-09-25: Apple silicon exclusivamente (arm64), sin Intel ni Universal 2. En esa revisión se aplazó la importación de calendarios: no crear parser, UI de importación ni apertura de .ics en el MVP. La exportación y la restauración de backups permanecen incluidas.

Una bóveda por usuario, una ventana principal más diálogos de exportación/recuperación. MVVM para presentación; dominio con reglas temporales; servicios de aplicación solo para operaciones que coordinan pasos; repositorios explícitos; persistencia y seguridad locales. No CQRS, bus global, contenedor DI, plugins ni interfaces genéricas para todo.

## Dependencias de código

```text
Kansolendar.app (composition root, SwiftUI, adaptadores de sistema)
       |                                  |
       v                                  v
KansolendarCore <---------------- KansolendarStorage
 dominio + servicios + puertos     repositorios + SQLite + CryptoKit/Keychain
       ^                                  |
       |                                  v
       +--- contratos                  SQLite del SDK

Core NO importa SwiftUI, SQLite, Security ni Storage.
Storage implementa los puertos de Core; App ensambla implementaciones.
```

Dos módulos Swift dentro de **un paquete local**, más el target de aplicación. Una frontera adicional de importación C puede ser necesaria para SQLite según SDK/SPM; si lo es, será un shim mínimo del módulo del SDK sin compilar otra copia de SQLite. No un paquete remoto.

## Responsabilidades

| Componente | Tiene | No tiene |
|---|---|---|
| App/composition root | Construcción de dependencias, ciclo macOS, paneles, estado global de bloqueo | Reglas de recurrencia, SQL |
| Features/View | Rendering y entradas, accesibilidad | Acceso a DB/clave, parser |
| ViewModel `@MainActor` | Estado visible, validación de interacción, tareas cancelables, errores presentables | Criptografía, punteros C, fuente definitiva de datos |
| Domain | Entidades y valores, fechas, recurrencias, validaciones puras | I/O, globals de zona o reloj |
| Application services | Guardar, consultar intervalo, exportar, bloquear, backup/restore | Importador anticipado; servicio vacío por cada operación CRUD |
| Repository ports | Operaciones de negocio acotadas y resultados, semántica transaccional | SQL o payloads de cifrado expuestos |
| Storage actor | Conexión SQLite, clave de sesión, serialización/cifrado, repositorios, índice temporal de sesión | UI ni red |
| Keychain adapter | Crear/leer/borrar DEK con políticas explícitas y errores tipados | Calendarios/eventos, clave cacheada permanentemente |
| ICS exporter | Serialización y perfil de salida, valores acotados | Parser de entrada en MVP, apertura de URLs, escritura arbitraria |
| System adapters | Selección de archivos, señales de suspensión/actividad, logger seguro | Historial persistente de documentos |

Services y Repositories son capas lógicas, no targets adicionales. Security es una carpeta interna de Storage con superficie pequeña. El codec de sobres y `SymmetricKey` son internos al módulo de Storage; solo el actor de almacenamiento debe usar claves. No crear un «CryptoService» disponible a todas las vistas. El proceso completo comparte un espacio de memoria: los módulos son barreras de mantenibilidad, no aislamiento de seguridad.

## Estructura actual y evolución prevista

El proyecto Xcode ya existe con un solo target de app (`Kansolendar`) y un paquete local `KansolendarKit` con los módulos `KansolendarCore` y `KansolendarStorage`. Storage mantiene una única conexión SQLite y la sesión de clave dentro de un actor; `KansolendarVault` es la fachada pública hacia la app. La primera pantalla implementa creación, desbloqueo y bloqueo explícitos. Todavía no presenta eventos y la app no carga contenido al abrirse. El botón de creación/desbloqueo sí intenta usar el Keychain real, por lo que su prueba sigue bloqueada hasta validar un build firmado con identidad de desarrollo.

La app presenta ahora un calendario mensual de seis semanas tras el desbloqueo, con filtros por calendario, búsqueda, navegación, selección de día y agenda contextual. Los eventos normales, de varios días y las ocurrencias del perfil recurrente se colocan en los días visibles. Un doble clic sobre un día inicia un evento con esa fecha; los eventos no recurrentes se pueden arrastrar a otro día conservando duración y semántica horaria. La agenda permite crear, editar y eliminar eventos, y borrar un calendario elimina transaccionalmente sus eventos cifrados tras confirmación destructiva. Los editores usan cabeceras contextuales, campos agrupados y acciones fijas. La apariencia Sistema/Claro/Oscuro se aplica a AppKit para actualizar ventanas y hojas existentes; una preferencia independiente de acento controla selecciones, botones y énfasis del workspace sin sustituir el color propio de los eventos. Ambas preferencias son locales, persisten fuera de la bóveda y están disponibles en la barra y en Ajustes. Las series recurrentes no se arrastran hasta disponer de una elección explícita entre ocurrencia y serie. El bloqueo retira inmediatamente calendarios y eventos del estado observable antes de invalidar la sesión de Storage. La edición de reglas recurrentes y la cobertura UI aislada siguen pendientes.

La siguiente estructura describe la evolución de carpetas dentro de esos targets; no implica crear targets o paquetes separados por cada capa:

```text
Kansolendar/
  Kansolendar.xcodeproj/           proyecto futuro
  App/
    Bootstrap/                    composición y escena principal
    Features/                     Calendar, EventEditor, Vault, Export
    UI/                           componentes comunes realmente reutilizados
    System/                       AppKit, archivos, señales de sesión
    Resources/                    iconos/localización, sin contenido remoto
  Packages/KansolendarKit/
    Package.swift                 solo targets locales; cero dependencies remotas
    Sources/
      KansolendarCore/
        Domain/                   valores y reglas
        Services/                 casos de uso coordinados
        Ports/                    repositorios, reloj y sesión
        Interchange/              exportador .ics puro; sin parser anticipado
      KansolendarStorage/
        Persistence/              conexión, esquema, migraciones y repositorios
        Security/                 envelope CryptoKit, Keychain
        Backup/                   snapshot y restauración
    Tests/
      KansolendarCoreTests/        Swift Testing
      KansolendarStorageTests/     Swift Testing, DB aisladas
  Tests/
    KansolendarIntegrationTests/   host firmado cuando haga falta
    KansolendarUITests/            XCTest/XCUITest
  docs/                           esta entrega
```

Core y Storage son módulos internos del producto, no SDKs públicos a distribuir. RecurrenceEngine e ICSExporter son componentes independientes y probables dentro de Core, no frameworks separados. Los tests que necesitan firma, Keychain o sandbox se ejecutan en un host macOS; `swift test` por sí solo no reproduce esas garantías.

## Flujos

```text
guardar
View -> VM -> validación dominio -> repositorio (Storage actor)
     -> validar sesión/revisión -> cifrar payload -> transacción SQLite
     -> commit -> actualizar índice RAM -> snapshot -> VM -> View

consultar
View -> VM -> servicio (rango, zona, filtros)
     -> índice RAM de sesión + expansión acotada
     -> descifrar detalles necesarios -> resultados -> View

exportar
selección explícita -> snapshot autorizado -> codec -> archivo elegido
                    (plaintext solo en esta salida deliberada)
```

La fachada de bóveda actual ofrece consulta local de eventos. Desbloquea y autentica los registros, filtra títulos/calendarios en memoria y expande recurrencias solo dentro del presupuesto de Core. No hay índice de búsqueda en claro en SQLite; el coste inicial es proporcional a los eventos almacenados. Los resultados son series coincidentes, no una lista de ocurrencias para dibujar.

Una escritura solo se confirma a UI tras commit. Si falla, el borrador queda visible en RAM mientras la sesión siga abierta; al bloquear se descarta. Sin autosave en disco ni promesa de recuperar edición no guardada tras cierre o crash. El flujo de importación se conserva únicamente como diseño futuro en [icalendar.md](icalendar.md); no forma parte de los servicios actuales.

## Sesión, ciclo de vida y estado

```text
starting -> locked -> unlocking -> unlocked -> locking -> locked
               |         |                         ^
               |         +-- cancel/error ---------+
               +-> recovery-required / incompatible / corrupt
```

Inicio: resolver contenedor, comprobar presencia/versiones sin cargar contenido, mostrar ventana neutra. Bóveda inexistente inicia flujo explícito de creación; un archivo existente ilegible nunca se trata como primera instalación. Desbloqueo: solicitud del usuario, autenticar Keychain, verificar envelope de control, leer/validar registros, construir índice de sesión y publicar datos. Toda operación pertenece a una generación de sesión.

Bloqueo propuesto: manual; suspensión; cambio de sesión/usuario; y pérdida de actividad de la app, excepto autenticación o panel modal propio mientras la app siga en un flujo controlado. Añadir 5 minutos de inactividad dentro de la app, medidos con reloj monotónico y sin monitor global de teclado. Si se omite una señal, comprobar estado antes de volver a mostrar datos. La cobertura exacta de señales públicas debe validarse en macOS (Q07); no confiar únicamente en `scenePhase`.

Al bloquear, primero ocultar vistas y cerrar editores; invalidar generación, cancelar trabajos, impedir nuevos accesos, finalizar/abortar transacción corta, retirar claves, vaciar índice, resultados, undo y búsquedas, y cerrar conexión cuando sea seguro. La cancelación no revoca datos ya entregados: también se limpian todos los consumidores y se descartan callbacks antiguos. No se puede garantizar zeroización física de cada copia Swift.

Cerrar última ventana bloquea. Se puede mantener proceso vacío para comportamiento macOS convencional; salir no requiere servicios de fondo. Al reabrir por Finder/Dock/Spotlight se muestra bloqueo. No contenido privado en títulos de ventanas ni menús. Guardados ya confirmados sobreviven al cierre; los borradores no.

## Concurrencia y consistencia

`@MainActor` limita estado UI. Un **Storage actor por bóveda** posee conexión, statements, secreto de sesión e índices; adaptador Keychain sin segundo almacén de claves. El dominio usa valores `Sendable` e inmutables y reloj/zona inyectados. Swift diferencia aislamiento de actor y posibilidad de transferir valores; ello no elimina carreras lógicas al suspender. [Swift: concurrencia](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html), [Sendable](https://docs.swift.org/latest/documentation/swift/sendable/).

No mantener transacciones SQL abiertas durante un `await`. Preparar entradas, revalidar generación/revisión al reentrar y ejecutar bind/step/commit sin suspensión. Autenticación y selección de archivos ocurren fuera de transacción. No marcar punteros SQLite `@unchecked Sendable` para silenciar el compilador. El actor serializa acceso pero no garantiza un hilo fijo; las APIs elegidas deben tolerarlo.

SQLite es síncrono: actor no lo transforma en I/O no bloqueante. Mantener lotes y busy timeout cortos; parser/expansión cancelables fuera de MainActor; medir bloqueo del executor. Solo si la medición lo justifica, añadir executor/cola serial dedicada a llamadas C, manteniendo una única propiedad de la conexión. No crear actors por entidad.

Revisión de evento cifrada para detectar ediciones obsoletas; validación y actualización dentro de la misma transacción. El índice RAM se actualiza después del commit; si falla su actualización, invalidarlo y reconstruirlo antes de responder a consultas. La DB es la fuente de verdad. No reutilizar resultados de una generación anterior tras desbloquear.

## Contratos transversales

Errores tipados y sin datos privados: validación, cancelación, bloqueo, autenticación, clave ausente, formato incompatible, integridad, conflicto, almacenamiento ocupado/lleno y error interno. No propagar `sqlite3_errmsg` ni `NSError.userInfo` a logs. Ver [logging](logging.md).

No consultas arbitrarias desde UI. Una operación transaccional de repositorio puede abarcar evento, excepciones e índice invalidado; no abstraer transacciones como closures UI. Exportación y restauración tienen límites y cancelación explícita. Backups nunca usan exportación .ics como sustituto. Ver [SQLite](database.md), [.ics](icalendar.md), [backups](backups.md).

La revisión de esta arquitectura debe aprobar los gates del [roadmap](roadmap.md). Las pruebas acompañan cada capa desde su implementación, y seguridad precede a persistencia de datos reales.
