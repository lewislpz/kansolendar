# Roadmap con dependencias y gates

La «Fase 1» solicitada inicialmente corresponde a **A: documentación**. Las letras evitan confundirla con las fases de implementación. El usuario autorizó después la implementación. A fecha 2026-09-26 están implementados el dominio, la bóveda cifrada, backup/restauración, la interfaz principal y un perfil iCalendar DATE/UTC estricto. El soporte sigue siendo arm64; distribución/notarización continúa aplazada.

```text
A documentación/revisión
          |
          v
B viabilidad nativa, firma, Keychain, formato y skeleton
          |
          +------> C dominio temporal ------+
          |                                |
          +------> D storage seguro --------+--> E calendario usable
                                           |          |
                                           +----------+--> F exportación
                                                           |
                       pruebas continuas en B–F ---------> G auditoría
                                                           |
                                                           v
                                                      H distribución
```

C y D pueden avanzar en ramas de trabajo independientes una vez fijados contratos; D valida serialización usando valores de C antes de cerrar su gate. La implementación actual vive en `KansolendarCore`; la capa Storage aún no persiste los tipos de dominio.

| Fase | Entrega | Dependencias | Criterio de salida |
|---|---|---|---|
| A — Arquitectura y revisión | Documentos, amenazas, ADRs, MVP y decisiones abiertas | Requisitos | Q01 y elecciones Q03/Q04 aceptadas; Q05 aplaza importación y Q06 fija Apple silicon. macOS/Xcode/SDK y revisión restante pendientes; sin autorización de implementación |
| B — Base nativa y probes iniciales | Proyecto Xcode arm64, paquete local, sandbox, pruebas AES-GCM y probes Keychain | A revisada y autorización de implementación | **Base creada.** La prueba real de `userPresence` sobre un elemento guardado y firmado, identidad/canal de distribución y formato envelope v1 completo siguen pendientes antes de guardar datos reales |
| C — Dominio y tiempo | Entidades/validación, motor de recurrencias acotado, búsquedas de referencia | B, contratos de dominio | Fixtures independientes de DST/historia/límites y cancelaciones correctas; perfil reducido cerrado. **Implementación de Core completada en 2026-09-26; validación continua y revisión integradas en esta fase** |
| D — Persistencia, cifrado y recuperación | SQLite, actor, AEAD, migración inicial, bloqueo de acceso, backup/restore y kit | B; valores C para integración | Ningún plaintext interno; CRUD/migraciones/fallos/recovery en otra cuenta pasan; Q01/03/04 cerradas |
| E — Calendario local usable | SwiftUI/MVVM, mes/lista/editor, calendarios, búsqueda, bloqueo visible y UX de recuperación | C + D | Flujos offline completos, accesibilidad, ocultación/borrado lógico de sesión; tests UI críticos |
| F — Intercambio .ics limitado | Exportador e importador DATE/UTC, selección explícita, conversión zoned única a UTC | C + D + flujo de E | Round-trip y rechazo de input hostil/semántica no soportada; atomicidad, sin pérdida silenciosa ni red |
| G — Auditoría integral y estabilización | Matriz privacidad, revisión memoria/FS/entitlements, rendimiento y restore de candidato | E + F | Cero hallazgos críticos, P01–P06 con evidencia; límites comunicados; ningún permiso innecesario |
| H — Distribución directa | Archive, firma, notarización, .app/DMG, documentación usuario | G | Primera instalación/upgrade/restore y funcionamiento offline de artefacto final verificados |
| I — Evaluación posterior, no comprometida | Importación si aparece necesidad; mejoras de recurrencias/VTIMEZONE o recordatorios genéricos; tienda si conviene | Uso del MVP y nuevos ADRs | No ampliar superficie sin amenaza, permisos y pruebas asociados |

Seguridad y testing comienzan en B y acompañan cada fase; no reservarlos para G. G comprueba el producto ensamblado, no sustituye las pruebas de capa. Nunca trabajar con calendarios reales durante prototipos de cifrado.

## Dependencias que no se pueden invertir

No UI persistiendo datos antes de cifrado/keys; no backups sin restauración; no importar texto externo antes de límites de parser; no datos reales antes de validación Keychain/envelope; no distribución antes de auditar artefacto firmado. Una «demo» que salte estas reglas solo usaría fixtures desechables y no se presentaría como aplicación privada.

## Siguiente paso recomendado

Las elecciones Q01/Q03/Q04 están aceptadas; Q05 aplaza importación y Q06 fija Apple silicon. La siguiente fase de producto es D: persistencia y cifrado, pero requiere cerrar la prueba de Keychain con el artefacto firmado, especificar envelope v1 y resolver versión mínima de macOS/canal de distribución (Q03, Q06, Q11 y Q12). No deben guardarse datos reales antes de completar esos gates. También se deben cerrar Q02, Q07, Q08 y Q09 antes de comprometer las garantías correspondientes.
