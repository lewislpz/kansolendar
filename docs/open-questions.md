# Open Questions / Architectural Concerns

Este registro hace revisables las decisiones pendientes. Ninguna cambia silenciosamente el stack. «Recomendación» es la propuesta del arquitecto; «pendiente» requiere revisión del propietario y/o evidencia técnica en una fase autorizada. No se necesitan respuestas para terminar **esta documentación**.

## Decisiones aceptadas — 2026-09-25

El propietario ha respondido afirmativamente a las preguntas 1, 2 y 3 de la revisión:

- **Q01:** cifrar el contenido sensible, aceptando estructura, conteos y tamaños visibles.
- **Q03, elección de producto:** desbloqueo mediante macOS (Touch ID o contraseña del sistema), sin contraseña independiente de Kansolendar en el MVP.
- **Q04, elección de producto:** archivo de recuperación separado del backup, entendiendo que ambos juntos permiten descifrar y que sin Keychain ni recuperación no se recuperan los datos.

Esta aceptación no valida todavía las APIs/ACL de Keychain, la restauración ni el formato criptográfico. La implementación de Fase D fue autorizada en un plan de alto riesgo el 2026-09-26; sus gates técnicos siguen siendo obligatorios.

La aclaración del propietario del 2026-09-26 fija además que **no debe existir login/cuenta de Kansolendar**. La bóveda usa una DEK aleatoria propia, generada por la app; Touch ID o el mecanismo local de presencia de macOS autoriza su uso. La prueba de Data Protection Keychain con firma de desarrollo es una necesidad técnica de validación y no implica autenticación de usuarios dentro del producto.

En una revisión posterior de la misma fecha, el propietario indicó que no necesita importar calendarios de momento y que no quiere soporte Intel:

- **Q05:** importación de calendarios aplazada, fuera del MVP. No crear parser, preview, comandos de importación ni asociación de apertura `.ics`. La exportación `.ics` y la restauración de backups se mantienen; el diseño de importación queda como referencia futura.
- **Q06, plataforma:** Apple silicon exclusivamente, binario arm64; sin Intel ni Universal 2. El propietario aprobó macOS 14 como mínimo para la implementación/MVP el 2026-09-26. Revisar el baseline antes de una futura distribución si las pruebas o soporte lo justifican.

| ID / problema | Impacto | Alternativas | Recomendación técnica | Decisión pendiente / gate |
|---|---|---|---|---|
| Q01 SQLite del sistema no cifra páginas y CryptoKit no añade codec | No es posible prometer archivo SQLite completamente cifrado con el diseño directo propuesto | Payloads; snapshot cifrado completo; excepción SQLCipher/SEE; solo FileVault | Payloads AES-GCM, también horarios/UID, con metadata residual declarada | **Alcance aceptado por el propietario, 2026-09-25.** Envelope v1 implementado; validación Keychain/SQLite y revisión independiente pendientes. ADR-0004 |
| Q02 Privacidad de horarios vs índices SQL | Desbloqueo O(N), RAM sensible y límite de escala | Índices en RAM; fechas en claro; DB integral externa | RAM y límites MVP; no filtrar agenda por rendimiento | Aprobar objetivo 10k/100 MiB y medir después; no se ha realizado benchmark |
| Q03 Keychain/userPresence en macOS y contraseña compartida con OS | No protege frente a quien ya puede autenticarse; acceso DP Keychain depende del grupo de firma y ACL real | Data Protection Keychain; ACL tradicional; password propia futura | Sin cuenta/login de producto; DEK aleatoria exclusiva, DP Keychain local, ThisDeviceOnly y userPresence, sin fallback silencioso | **Validado en build Apple Development firmado, 2026-09-26.** Creación, lectura tras bloqueo, cancelación que permanece bloqueada y reapertura pasaron con el grupo de aplicación efectivo. El `-34018` previo correspondía al build ad hoc sin app ID. Mantener pruebas por canal de distribución |
| Q04 Recuperación portable frente a secreto no migrable | Pérdida de clave destruye acceso; kit legible reduce seguridad si se almacena mal | Sin recuperación; copia manual DEK; recovery con passphrase y KDF adicional | Kit explícito de DEK, separado del backup, advertencia inequívoca | **Archivo separado y riesgo aceptados, 2026-09-25.** Concretar UX y probar restauración real **antes de confiar datos** |
| Q05 .ics completo sin dependencias es demasiado amplio | Parser de entrada aumenta superficie y complejidad sin necesidad actual | Exportación solamente; importar perfil limitado en una fase futura | MVP solo exporta .ics; conservar análisis de importación como referencia, sin implementarlo | **Importación aplazada por el propietario, 2026-09-25.** Ya no bloquea el MVP; revisar perfil de exportación y sus conversiones |
| Q06 OS mínimo y Xcode pendientes; hardware decidido | Cambia disponibilidad de APIs, firma y esfuerzo de QA | macOS 14 técnico inicial o mínimo más reciente; Intel descartado | Apple silicon exclusivamente, arm64; validar toolchain sobre target macOS 14 | **macOS 14 aprobado como mínimo de implementación/MVP el 2026-09-26; build local comprobado con Xcode 27/macOS 27 SDK; sin Intel por decisión del 2026-09-25.** Pin release de Xcode/SDK y canal de distribución aún pendiente |
| Q07 Bloqueo automático y paneles macOS | Demasiado agresivo interrumpe uso; demasiado laxo deja datos visibles | Pérdida de actividad, timeout, solo manual | Pérdida de actividad salvo flujo propio, suspensión/sesión y 5 min sin uso | Validar señales públicas sin permisos de monitor global y revisar UX **antes de UI con datos** |
| Q08 AEAD por fila no prueba conjunto/frescura | Borrado de filas o replay válido puede ser indetectable | Inventario autenticado; estado confiable externo; aceptar límite | Aceptar límite adversarial MVP, mantener backups y validación | Aprobar límite; no presentar «tamper-proof». Inventario no resuelve replay completo |
| Q09 Servicios del OS pueden usar red/capturar contenido | Sandbox no controla dictado, escritura asistida, diagnósticos ni exportación a nube | Restringir integraciones; controlar Mac administrado fuera del producto | Sin servicios remotos propios, ayudas automáticas desactivadas donde posible; límites claros | Probar versiones elegidas, documentar configuración real; no garantía de aislamiento del OS |
| Q10 Cambios de reglas de zona/historia | Futuros horarios pueden variar tras actualización; offsets antiguos pueden ser incompletos | Conservar snapshots tzdata/VTIMEZONE; reglas del OS; fijar instantes | Eventos únicos fijos; series por hora local con resolver del OS y conflictos explícitos | Aprobar semántica histórica/futura; no prometer calendario civil universal |
| Q11 App «cero dependencias» y distribución convencional | Firma/notarización usan servicios Apple al publicar | Distribución no notarizada; Developer ID; futura tienda | Developer ID + notarización/stapling; runtime offline | Aceptar separación build/distribución/uso y fijar identidad antes de Keychain |
| Q12 Formato envelope v1 necesita especificación exacta | Cambiar AAD/codificación después puede romper datos | Congelar temprano; versionar y migrar | Layout `KNSL/v1`, AAD fija y vector determinista; revisión independiente antes del primer release | Especificación y codec v1 implementados con pruebas el 2026-09-26; revisión independiente y uso productivo pendientes |

## Qué no se discute como alternativa de conveniencia

No sustituir Swift 6/SwiftUI por web, Electron u otro runtime. No SwiftData/ORM sin justificación futura. No red, cuentas, sincronización ni analytics. No justificar acceso a calendarios del sistema para facilitar parser .ics. No crear criptografía de páginas propia para aparentar cumplir cero dependencias.

## Criterio de revisión

Las elecciones de producto de Q01/Q03/Q04 están aceptadas; sus verificaciones técnicas siguen siendo obligatorias. Q05 aplaza importación y Q06 fija Apple silicon y macOS 14 para implementación/MVP; falta fijar el toolchain de release y canal de distribución. Q07/Q09 requieren pruebas de sistema. Los riesgos aceptados quedan en ADR con fecha/decisor; los no aceptados originan revisión del diseño y pruebas, no un comentario TODO en código de producción.
