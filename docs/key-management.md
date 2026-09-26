# Gestión de claves y Keychain

Estado: Kansolendar no tendrá cuentas, login, identidad de usuario propia ni contraseña de cuenta. El propietario confirmó el 2026-09-26 que quiere bloqueo local por Touch ID o una clave exclusiva generada para Kansolendar. La decisión concreta es generar una DEK aleatoria por bóveda, guardarla en Keychain protegido por `userPresence` y ofrecer recuperación separada; Touch ID autoriza el uso de la clave y no la reemplaza. `KeychainVaultKeyStore` implementa creación/lectura/borrado con error tipado y sin fallback. La prueba interactiva firmada del 2026-09-26 validó creación, lectura protegida tras bloqueo, cancelación que permanece bloqueada y reapertura de la misma bóveda. La aplicación se firmó con Apple Development y el grupo efectivo `6WXG2F9KW5.local.kansolendar.development`; `codesign --verify --deep --strict` pasó. El error previo `-34018` (`errSecMissingEntitlement`) quedó atribuido al build ad hoc sin identificador de aplicación. La firma de desarrollo es una precondición técnica de la prueba, no un login de la aplicación ni de sus usuarios.

## Inventario exacto

| Elemento | Ubicación | Política |
|---|---|---|
| DEK de 32 bytes | Item Keychain de clase generic password | Un item por `(vaultID, keyID)`; secreto real de cifrado |
| Identificación de item | service estable del producto + account opaco con vaultID/keyID | No nombre personal, título ni email en atributos |
| DEK en uso | Memoria del Storage actor | Solo mientras desbloqueado |
| Clave de recuperación | Copia externa explícita de la DEK generada por Kansolendar, en kit separado | No se crea automáticamente ni junto a DB; equivalente al secreto completo |
| vaultID/keyID/versiones | Cabecera de DB y kit | No secretos; ayudan a detectar pareja incorrecta |

No guardar en Keychain: eventos, notas, títulos, ubicaciones, búsquedas, calendarios, DB completa, logs, backups, preferences de UI. No tokens, credenciales de servidor, cuentas ni secretos «por si acaso». No claves derivadas persistentes en MVP; sin clave maestra fija en binario. La firma del desarrollador y credenciales de notarización pertenecen al entorno de distribución, no al llavero de la app instalada.

## Política de item propuesta

- API SecItem, seleccionando explícitamente Data Protection Keychain en macOS con `kSecUseDataProtectionKeychain=true`.
- `kSecAttrSynchronizable=false`, sin grupo iCloud/compartido ni otros productos autorizados.
- Accesibilidad propuesta: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, a través de SecAccessControl con `userPresence`. No combinar atributos incompatibles duplicando accesibilidad al construir el item.
- No declarar un grupo de Keychain compartido en MVP. Usar el grupo de aplicación por defecto que provee una firma de producto válida; solo añadir un grupo explícito si la prueba demuestra que es necesario y el perfil lo autoriza. No acceso genérico a grupos del equipo ni compartir con otro producto. Validar `application-identifier`/`com.apple.application-identifier`, entitlements firmados y autorización efectiva en la identidad elegida; el build ad hoc no demuestra acceso Data Protection Keychain. En el futuro, verificar por separado App Store.
- Lectura solo tras acción explícita de desbloquear; contexto de autenticación nuevo por sesión. No accesos en background que provoquen prompts ni reutilización ilimitada de credenciales.

`userPresence` permite mecanismo elegido por el sistema y no significa Touch ID obligatorio. Debe existir flujo para Mac sin biometría y cancelación. No basar seguridad en un `evaluatePolicy` separado seguido de una clave sin ACL: la restricción debe proteger el **item**. [Apple: restricciones de accesibilidad](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility).

La combinación exacta se debe ensayar en las versiones/macOS/hardware soportados y con firma real. Si falla, **no** degradar a llavero tradicional sin autenticación ni a archivo de clave. Revisar Q03. `ThisDeviceOnly` implica no diseñar restauración en otro Mac dependiendo del item; `synchronizable=false` evita sincronización del item, no constituye una política global de backups del sistema.

## Creación y estados de fallo

1. Usuario decide crear bóveda. Verificar que no exista otra ilegible; generar vaultID, keyID y DEK con fuente segura de CryptoKit/Security.
2. Guardar item y confirmar operación. Preparar DB nueva de staging con control cifrado y calendario inicial; nunca plaintext.
3. Cerrar/verificar staging y sustituir atómicamente el destino inexistente; publicar estado solo tras éxito.
4. Ofrecer recuperación separada y advertir limitación si se pospone.

Keychain y filesystem no comparten transacción. Si el proceso cae después de crear item y antes de instalar DB, queda un item huérfano: no borrar automáticamente items en base a una única ausencia de archivo. Se puede reanudar usando staging compatible o presentar limpieza explícita. Si DB existe y item falta, estado `recovery-required`, nunca generar otra clave para ella. Un duplicate-item exige leer/verificar el par correcto, no reemplazarlo a ciegas.

Desbloqueo: recuperar secreto, autenticar control y registros, construir sesión; cancelar autenticación mantiene bloqueo. Diferenciar cancelado, acceso denegado/interacción no permitida, item no encontrado, clave incompatible y DB corrupta; mensajes genéricos sin detalles secretos. Invalidar el contexto al bloquear, liberar DEK y cancelar consumidores según [arquitectura](architecture.md).

## Contraseña, recuperación y pérdida

MVP sin contraseña ni cuenta propias: desbloqueo local mediante macOS. La clave exclusiva de Kansolendar es aleatoria y no se deriva de una contraseña humana. Cambiar la contraseña de macOS no deriva una DEK nueva ni obliga a reencriptar eventos. No prometer que resetear credenciales o llavero preserve el item. Si en el futuro se ofrece una contraseña propia como método alternativo, necesitará KDF resistente a ataques de diccionario, diseño de recuperación y pruebas; CryptoKit no convierte HKDF en KDF para contraseñas humanas. No introducir CommonCrypto u otra librería silenciosamente.

**Kit de recuperación v1:** archivo de texto versionado que contiene el marcador `KANSOLENDAR-RECOVERY-KIT`, versión, vaultID, keyID y DEK de 32 bytes codificada en Base64; nombre genérico, sin nombre del usuario. Base64 **no cifra**. El codec rechaza campos duplicados o desconocidos, versiones futuras, claves de longitud incorrecta y entradas mayores de 512 bytes. La exportación vuelve a autenticar el item Keychain, comprueba el envelope de control y escribe directamente un archivo nuevo `0600`; no sobrescribe otro kit ni entrega la DEK a la UI. La restauración todavía debe validar la pareja y todos los tags antes de instalarla.

El usuario lo exporta tras autenticar de nuevo, mediante selector independiente con explicación concreta: permite abrir cualquier copia de esa bóveda. No enviarlo, no clipboard automático, no ruta recordada. Recomendar medio separado y cifrado bajo control del usuario. No garantizar detectar todos los proveedores cloud/volúmenes sincronizados en el selector. Si el kit se guarda junto al backup, quien obtenga ambos puede leerlo. El propietario aceptó este riesgo y la recuperación separada el 2026-09-25 (Q04); la futura UI debe seguir explicándolo al exportar.

Recuperación en otro Mac: seleccionar backup y kit; validar pareja y tags en staging, crear item local con ACL actual y nueva sesión de autenticación, mantener vaultID/keyID para leer la copia; instalar solo después de validación. Restaurar una **misma** bóveda conserva identidades. Duplicarla como bóveda independiente exigiría IDs/DEK nuevos y reencriptación: fuera del MVP.

Sin item usable ni kit, los datos no son recuperables por el desarrollador. No puerta trasera, preguntas personales ni escrow. Exponer esa consecuencia antes de que el usuario confíe datos irremplazables. El kit no sustituye un backup y el backup no sustituye el kit.

## Rotación y compromiso

No rotación automática ni cambio de contraseña propio en MVP. Si se sospecha compromiso de DEK/kit, bloquear uso sensible y orientar a crear bóveda nueva desde un dispositivo confiable; una migración asistida con rotación pertenece a una fase posterior.

Diseño futuro de rotación: crear keyID/DEK nuevos, construir DB nueva cifrada y verificada, instalarla atómicamente, registrar nueva recuperación y conservar la antigua mientras el usuario quiera abrir backups anteriores. Un fallo no debe dejar DB activa con clave borrada. La retirada del item anterior es acción separada tras verificación. Rotar no vuelve secretas copias ya exfiltradas ni invalida kits antiguos frente a backups antiguos.

Borrar la app no debe asumirse que elimina Keychain o datos. Una futura acción «eliminar bóveda» debe distinguir DB, item, copias y recuperación; no prometer eliminación de soportes externos.
