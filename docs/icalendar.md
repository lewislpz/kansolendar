# Intercambio iCalendar local

Formato: `.ics`, texto UTF-8. No suscripciones, CalDAV, cuentas, iTIP operativo ni scheduling. Estado implementado el 2026-09-26: exportación de eventos únicos all-day/UTC y conversión explícita de eventos zoned únicos a UTC; importación estricta y atómica de eventos all-day/UTC en un calendario seleccionado. Series recurrentes, `VTIMEZONE`, floating time, invitaciones, alarmas, adjuntos y URLs no se importan ni se exportan silenciosamente: el archivo o la exportación se rechaza. Restaurar backups de Kansolendar sigue siendo una función distinta.

Las secciones siguientes documentan tanto el perfil estricto implementado como ampliaciones futuras. Serializar iCalendar es lógica del formato, no criptografía propia; los archivos `.ics` son plaintext deliberado.

## Perfil de importación y ampliaciones futuras

| Construcción | Perfil futuro propuesto | Política |
|---|---|---|
| VCALENDAR VERSION 2.0 / VEVENT | Sí | Un contenedor, PRODID admitido; CALSCALE ausente o GREGORIAN |
| UID y DTSTAMP | Sí | Exigir UID no vacío; DTSTAMP UTC válido en entrada; no usarlo como criterio automático de actualización |
| SUMMARY, DESCRIPTION, LOCATION | Sí | Texto plano acotado; SUMMARY ausente válido, sin contenido inventado |
| DTSTART DATE + DTEND DATE | Sí | Fin exclusivo, ausente implica un día; conservar tipo DATE |
| DTSTART UTC + DTEND UTC | Sí | Fin posterior; ausencia de fin sería instante sin duración, incompatible con este perfil futuro |
| DURATION | Solo horas/minutos/segundos positivos para timed UTC; días/semanas enteros para all-day | Mutuamente excluyente con DTEND; convertir a duración de dominio sin cambiar significado |
| RRULE | Perfil reducido del dominio para DATE/UTC | Sin combinaciones fuera de allowlist; no importar parcialmente una regla |
| EXDATE | Sí para DATE/UTC compatibles con maestro | Crear cancelaciones, deduplicar valores; exigir que identifiquen una ocurrencia de la serie dentro del presupuesto |
| DTSTART con TZID | No en el perfil futuro básico | Mostrar incompatibilidad de zona, no sustituir por UTC o zona actual |
| VTIMEZONE | No en el perfil futuro básico | Si lo referencia una serie/evento, rechazar grupo; definición no usada se informa y se omite tras aceptación |
| Floating date-time | No | Rechazar; conversión explícita con zona podría añadirse después |
| RECURRENCE-ID, RDATE, RANGE=THISANDFUTURE | No | Rechazar grupo de UID completo; no importar solo el maestro y perder excepciones |
| ATTENDEE, ORGANIZER, VALARM, ATTACH, URL | Sin modelo funcional | Advertencia de pérdida; omitir únicamente con aceptación explícita para importar evento restante; jamás ejecutar ni descargar |
| SEQUENCE, CREATED, LAST-MODIFIED | Admitir como metadatos validados y cifrados | Sin actualización automática basada en ellos; cambios locales ajustan metadatos de exportación |
| STATUS/TRANSP fuera del estado normal soportado | Sin soporte semántico inicial | Rechazar si perderlos cambia el significado; no convertir CANCELLED en cita activa |
| VTODO, VJOURNAL, VFREEBUSY | No | Informe de incompatibilidad, no tratarlos como VEVENT |
| METHOD operativo (REQUEST, REPLY, CANCEL…) | No | Rechazar archivo como intercambio de agenda, no responder ni ejecutar invitaciones |
| Propiedades X-/extensiones desconocidas | No persistidas por defecto | Informe; las que afecten tiempo/identidad impiden importar el grupo; otras requieren aceptación de pérdida |

El perfil implementado limita considerablemente archivos exportados por otros calendarios, muchos de los cuales usan VTIMEZONE. Q05 queda resuelta mediante un perfil DATE/UTC deliberadamente estricto: lo no soportado se rechaza sin importación parcial. No afirmar «compatible con Apple/Google/Outlook» sin fixtures y matriz de funciones; esas marcas serían fuentes de archivos manuales, no integraciones ni servicios del producto.

## Reglas de texto y compatibilidad sintáctica

Desplegar líneas plegadas antes de interpretar propiedades; contar bytes y no romper UTF-8 multibyte al exportar. Salida con CRLF y plegado de 75 octetos. Escapar TEXT con backslash para barra inversa, coma, punto y coma y salto de línea. No aplicar esos escapes a todos los tipos indiscriminadamente. Identificadores de propiedad/parámetro se comparan sin case; valores textuales y UID se preservan. Estas reglas proceden de [RFC 5545, sección 3.1](https://www.rfc-editor.org/rfc/rfc5545).

Los valores de parámetros requieren tokenización que respete comillas; no separar ingenuamente por cada `;` o `:`. Cuando se admitan parámetros que usan la extensión, tratar `^^`, `^n` y `^'` según [RFC 6868](https://www.rfc-editor.org/rfc/rfc6868); no confundir con escape de TEXT. Rechazar controles inválidos y contenido binario no soportado. No completar campos obligatorios en silencio. Tolerancias documentadas propuestas: BOM UTF-8 inicial y líneas LF, con salida siempre canónica; UTF-8 inválido se rechaza.

## Pipeline y límites hostiles de importación

```text
archivo seleccionado -> tamaño/tipo local -> lectura incremental acotada
 -> unfolded lines -> árbol limitado -> grupos UID completos
 -> validación de perfil/tiempo -> informe -> selección explícita
 -> dominio -> cifrar -> una transacción de importación -> resultado
```

Límites iniciales: 10 MiB por archivo; 10 000 VEVENT; 4 niveles de componentes; 256 KiB por línea desplegada; 512 propiedades por componente; 1 024 valores EXDATE por maestro; contenido por campo según dominio; expansión bajo presupuesto común. La bóveda completa respeta 10 000 maestros y 100 MiB de payloads acumulados inicialmente. Validar antes de acumular buffers, no solo al final. Archivos comprimidos, symlinks inesperados, pipes y dispositivos se rechazan. Límite de trabajo/cancelación cooperativa, sin regex con backtracking no acotado.

No URLs dereferenciadas: `http:`, `https:`, `file:`, `data:`, `mailto:`, TZURL, ALTREP y adjuntos son texto no confiable. No WebView ni HTML renderizado; sin procesos externos. Límites se aplicarían también a valores que luego se omitan. No interpretar alarmas de audio/procedure ni abrir enlaces por previsualizar. Estas reglas de entrada se activarán únicamente si se autoriza un importador futuro; no crear ahora un parser oculto.

Error estructural/encoding/límites del archivo: cancelar todo. Incompatibilidad semántica de un grupo UID: informar y dejarlo sin seleccionar. Antes de aceptar otros grupos, explicar cuántos quedarían fuera y cuáles perderían propiedades; nunca importar menos de lo que el usuario confirmó. La escritura de todos los grupos aceptados es una única transacción; error a mitad revierte lote completo. La selección/preview vive en RAM y se invalida al bloquear.

## UID, duplicados y actualizaciones en importación

UID se conservaría para importación sin transformación semántica; IDs SQLite nuevos. En mismo calendario destino, UID existente no se sobreescribiría automáticamente. El perfil futuro básico ofrecería saltar el grupo o cancelar importación; «actualizar versión» y merge necesitarían más diseño. En otro calendario podría coexistir. Importar dos veces el mismo archivo en el mismo destino no duplicaría maestros si se elige saltar. Dentro del archivo, dos maestros con mismo UID serían conflicto: rechazar grupo en lugar de decidir por SEQUENCE/DTSTAMP.

Informes por ordinal de componente y código; títulos pueden mostrarse solo en preview desbloqueada, nunca logs. UID no se envía a ningún sistema ni forma nombres de archivo. No inferir personas de UID/dominios.

## Exportación y límites de zona — incluida en el MVP

Exportar selección explícita y destino mediante panel; nombre neutro. Avisar que .ics queda **sin cifrar** y puede contener datos personales. Sin ficheros intermedios legibles internos. Si la escritura necesita staging en el directorio elegido, es una copia legible deliberada: permisos restrictivos, cleanup al cancelar, advertir parcial si falla y no prometer borrado forense. Usar stream acotado y no escribir fuera del destino autorizado.

Perfil de salida:

- Evento all-day y serie DATE admitida: conservar fecha/rule/exclusiones.
- Evento UTC y serie UTC admitida: conservar instantes/rule/exclusiones.
- Evento zoned único: se puede exportar en UTC conservando instante/duración; se pierde la zona editorial. Preview lo indica y requiere aceptar conversión. Si se exige fidelidad completa, usar backup.
- Serie zoned: **no** convertir simplemente DTSTART a UTC manteniendo RRULE; cambiaría horas locales tras DST. MVP permite únicamente exportación de ocurrencias materializadas en un rango finito elegido, con advertencia de pérdida de serie y zona; o cancelar. Una serie infinita nunca se «exporta completa» mediante truncación silenciosa.

Materialización: rango máximo 366 días y presupuesto de expansión; incluir ocurrencias que solapen rango, aplicando cancelaciones. Generar UID nuevos para eventos independientes, no reutilizar UID de maestro repetido. Son una copia de intercambio: reimportar exportaciones materializadas repetidas no tiene deduplicación garantizada respecto de serie original; explicarlo. No ofrecer el archivo resultante como backup reversible.

Generar VERSION/PRODID estáticos, UID, DTSTAMP y demás campos admitidos; no incluir usuario/equipo/ruta. Notas/ubicación se incluyen solo dentro de la selección confirmada; posibilidad de excluir campos sin crear un formato distinto. Omitir asistentes/alarmas/adjuntos no presentes en modelo. Una salida redacted modifica deliberadamente contenido y no sirve para round-trip exacto.

## Ampliación posterior

VTIMEZONE custom requiere resolver transiciones y posibles discrepancias con IANA; el nombre coincidente no prueba reglas iguales. No ignorar una definición embebida porque Foundation reconozca el TZID. Diseño futuro: intérprete acotado o conversión explícita a ocurrencias finitas con informe; nunca descargar TZURL. Exportar serie zoned fiel exige VTIMEZONE correcto para su alcance, también futuro. Este coste explica el perfil inicial.

Pruebas del MVP: round-trip DATE/UTC, escapes y plegado Unicode, UID duplicados, finales exclusivos, límites, propiedades semánticas no soportadas, atomicidad y ausencia de conexiones. Fixtures amplias de TZID/VTIMEZONE, recurrencia e invitaciones quedan para una ampliación futura. Los backups hostiles se prueban desde el MVP.
