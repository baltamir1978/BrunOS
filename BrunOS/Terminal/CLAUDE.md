# Terminal SSH

## Fase 2 — Terminal SSH

**Terminada y funcionando: Bruno confirmó el 22-sep-2026 que la conexión SSH conecta de verdad**
contra una máquina suya. Era la mayor incógnita del proyecto y está despejada.

Lo que sigue sin probarse de esta fase: tmux y vim con ratón, la selección con arrastre, el
`known_hosts` ante una clave que cambie, y la reconexión tras una caída real.

Lo que hay:

- `SSHHost` + `HostStore`: perfiles en JSON en Application Support. **Los secretos no entran ahí**,
  van al Keychain con `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: no se sincronizan con iCloud
  y no se leen con el teléfono bloqueado.
- `TailscaleAuthentication`: el método SSH `none`. **Citadel no lo expone** —sus constructores
  llegan hasta `passwordBased` y las claves— pero sí expone `SSHAuthenticationMethod.custom(_:)`,
  que acepta un delegado propio. Con eso basta y **no hizo falta bajar a SwiftNIO a pelo**, que era
  el plan B del prompt.
- `SSHSession`: conexión, PTY, `window-change` al redimensionar, keepalive de 30 s y comando
  inicial. La reconexión es a mano, con Intro, desde el propio terminal.
- `TerminalPane` + `TerminalTab` + `TerminalTabBar`: SwiftTerm con 10.000 líneas de scrollback
  (las de serie son 500), traducción de teclas a secuencias de terminal, y pestañas por sesión.
- `TailscaleMonitor`: busca una interfaz `utun` con dirección de `100.64.0.0/10` o
  `fd7a:115c:a1e0::/48`. **Es un aviso y nunca bloquea**: no hay forma de preguntarle a Tailscale
  por su estado y la deducción puede fallar.
- `HostsView`: alta, edición y borrado de máquinas desde el iPhone.

Trampas de esta fase:

- **Ni Citadel ni NIO están migrados a la concurrencia estricta de Swift 6.** Hacen falta
  importaciones `@preconcurrency`. Y `TTYStdinWriter` no es `Sendable`, así que **no puede salir de
  la closure de `withPTY`**: `SSHSession` le manda órdenes por un `AsyncStream` y el writer se
  queda dentro, que es lo que hace que compile sin trampas.
- `TerminalViewDelegate` de SwiftTerm no está declarado `@MainActor` aunque siempre se llame desde
  la interfaz: la conformidad se marca `@preconcurrency`.
### SSH sin Tailscale, y el agujero de keyboard-interactive

**SSH funciona sin Tailscale**: con el método «Contraseña» se conecta a cualquier máquina
alcanzable desde la red del iPhone. Tailscale sólo aporta llegar a máquinas no expuestas y entrar
sin contraseña. El aviso de «Tailscale no parece activo» **sólo sale si hay algún host configurado
con ese método**, para no dar la lata a quien no lo use.

Pero hay una limitación seria, comprobada en la librería y **no arreglable desde BrunOS**:

**NIOSSH no implementa `keyboard-interactive`.** `NIOSSHAvailableUserAuthenticationMethods` sólo
contempla `publicKey`, `password` y `hostBased`, y la cadena "keyboard-interactive" no aparece en
ningún fichero de la librería. Importa porque hay servidores OpenSSH configurados con
`KbdInteractiveAuthentication yes` y `PasswordAuthentication no`, y **contra ésos la contraseña no
entra**. Las salidas son dos: usar clave pública, que Citadel sí admite (`ed25519`, `p256`, `rsa`;
quedaron fuera de esta versión por decisión del prompt, pero el diseño está preparado), o parchear
NIOSSH.

### Lo que queda fuera de la Fase 2, y por qué

- **`keyboard-interactive`**: **no es posible con NIOSSH**, ver arriba.
- **Banner de autenticación del servidor** (`SSH_MSG_USERAUTH_BANNER`): NIOSSH sólo lo contempla
  **del lado servidor**, en `SSHServerConfiguration.banner`. Un cliente no tiene forma de leerlo.
  El MOTD de después del login sí sale, porque llega por stdout como cualquier otra salida.
- **Cmd+clic sobre una URL** la abre en una pestaña nueva del navegador de BrunOS. Safari sólo
  sin monitor o para lo que no es una web (`mailto:`, `tel:`).

### Claves de host (known_hosts)

**Ya está hecho**, en `KnownHosts.swift`. El cifrado de SSH impide que nadie escuche por el camino,
pero no dice **con quién** se está hablando: eso lo dice la clave del servidor. Sin comprobarla,
cualquiera que se meta en medio se presenta como tu máquina y le entregas la contraseña.

Se sigue el modelo de OpenSSH, **confianza en el primer uso**: la primera vez se guarda la huella
y a partir de ahí tiene que coincidir. Si cambia, **la conexión se corta** y se avisa en
Ajustes › SSH › Claves conocidas, donde Bruno decide. No es infalible —si el primer encuentro ya
estuviera interceptado, se guardaría la clave del atacante— pero es lo que hace `ssh` de siempre.

La huella es **SHA-256 en base64 sin el `=` final**, que es el formato que enseña OpenSSH, para
poder cotejarla a ojo contra `ssh-keyscan`.

`SSHHostKeyValidator.custom(_:)` de Citadel es público, así que no hizo falta rodearlo. El
validador es `Sendable` y sin estado mutable a propósito: NIO lo llama desde su event loop, no
desde el actor principal.

### Clave ed25519 (22-sep-2026)

Método «Clave ed25519» (`SSHHost.Authentication.key`), para terminal y SFTP. Hay **una clave del
iPhone para todas las máquinas**, como `~/.ssh/id_ed25519` (`SSHKeyStore`): se genera en el
teléfono con CryptoKit o se importa del portapapeles en formato OpenSSH, cifrada o no (la lectura
es la de Citadel, `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)`). Va al Keychain con
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` y la privada no sale de ahí: la app sólo copia la
pública, desde Ajustes del terminal › Clave SSH.

Citadel usa `swift-crypto`, que en plataformas de Apple es CryptoKit por debajo: los tipos son los
mismos y basta `import CryptoKit`.

**Comprobado**: la línea pública que genera BrunOS la lee `ssh-keygen -l` y da la misma huella.
**Sin probar**: la importación de una clave cifrada y la conexión contra un servidor real.

### Terminal: lista de conexiones y tema propio

El terminal **ya no se conecta solo** al abrirse: enseña `TerminalHomeView`, la lista de máquinas
con su botón, y Cmd+T o el «+» de la barra vuelven a ella. La barra va siempre, con la rueda de
ajustes.

**`exit` dejaba el terminal muerto**: cuando el servidor cierra el canal, `run()` vuelve sin
error, y el estado se quedaba en «conectado». Ahora pasa a `.ended`, se cierra la pestaña y se
vuelve a la lista de conexiones.

En modo claro, **el terminal pintaba texto casi negro sobre fondo negro**: el fondo era fijo y el
texto era el color dinámico del escritorio. SwiftTerm convierte los `UIColor` al asignarlos y no
se entera de los cambios, así que `TerminalTab.applyTheme` le pasa colores ya resueltos y una
paleta ANSI clara propia (la de xterm no se lee sobre blanco). El modo sigue al escritorio por
defecto y se puede fijar aparte (`TerminalTheme`).

### Seleccionar marcaba lejos del cursor (24-sep-2026)

En iOS, la `TerminalView` de SwiftTerm es un `UIScrollView` con todo el historial dentro, y
`getText(start:end:)` cuenta las filas **desde el principio del historial**. BrunOS usaba filas
de la pantalla visible para todo: con historial acumulado, el resaltado caía lejísimos y se
copiaban otras líneas. Además la capa del resaltado se colocaba en `bounds`, cuyo origen es por
dónde va el scroll. Ahora:

- `position(at:)` da filas del historial (visible + `getTopVisibleRow()`), para seleccionar,
  resaltar y copiar; `visiblePosition(at:)` da las visibles, para el protocolo de ratón de tmux y
  vim y para los enlaces (`.screen`).
- La capa del resaltado va en el origen del contenido. SwiftTerm guarda
  `contentOffset.y == yDisp * cellHeight`, así que la fila N está en `N × alto de celda`.
- El tamaño de celda sale de `getOptimalFrameSize()` (columnas × celda), no del ancho de la vista,
  que incluye el sobrante del borde.

**Sin probar en el iPhone.**

### El scroll iba al revés que en el resto (24-sep-2026)

Con scroll natural o inverso, el navegador iba bien y el terminal al contrario (Bruno). Todos los
paneles mueven el contenido al revés que el evento (`scrollOffset - delta.dy`); el terminal lo
hacía al derecho, tanto el historial (`scrollDown(lines:)`) como la rueda que se manda a tmux y
vim (64/65 de xterm). Ahora usa `-delta.dy` en los dos. **Regla: un panel nuevo, con el mismo
convenio**, para que el ajuste de dirección valga igual en todos.
