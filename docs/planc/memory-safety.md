# Memoria segura en `planc`: runtime, ownership y extensiones

Status: **implemented (2026-11-25).** Este documento describe la capa de seguridad de
memoria del dialecto `planc` y las restricciones que impone frente a Vala estándar.

El objetivo es que `planc` sea un *dialecto más seguro* de Vala: cuando una
construcción no se puede verificar, se rechaza (o se degrada a una forma segura)
aunque eso implique omitirla.

---

## 1. Modelo de objetos y ABI del runtime

Cada bloque del heap lleva una cabecera de 16 bytes delante de los datos:

| Offset | Campo | Contenido |
|--------|-------|-----------|
| `+0` | `refcount` | `u32`; `0` = bloque liberado, `0xDEADDEAD` = envenenado, `0xFFFFFFFE` = *dying* |
| `+4` | `kind` | `0` array de bytes, `1` array de referencias, `2` instancia de clase, `3` `[Compact]` |
| `+5` | `class` | clase de tamaño `0..7` (32…4096 bytes) o `255` para bloques grandes |
| `+6` | `magic` | `0x504C` (`"PL"`) |
| `+8` | `len` / `vtable` / next | longitud para arrays, puntero a vtable para clases, enlace de la lista libre una vez liberado |
| `+12` | `pages` | sólo bloques grandes: páginas reservadas, para poder reutilizar el bloque |

Los bloques de hasta 4096 bytes se reciclan en ocho *free lists* por clase de
tamaño. Los bloques mayores se encadenan en una lista LIFO cuyo tamaño se guarda
en `+12`; una asignación grande reutiliza el primer bloque con al menos las
páginas necesarias (búsqueda acotada a 64 entradas). Sin ese reciclaje, cada
array de más de 4 KiB perdía sus páginas para siempre.

Cuando no hay memoria, el runtime aborta con `planc: panic: out of memory`, un
diagnóstico distinto del de doble `free` o bloque corrupto.

Los datos empiezan en `+16`, por lo que `sizeof` de `planc` es un slot de 8 bytes
por escalar (no el tamaño de C).

`__planc_unref` realiza, en orden: descarte de `null`, de `[Compact]` y de
`refcount == 0`; **panics** ante `0xDEADDEAD` (*double free*) o `magic` inválido
(bloque corrupto); `lock dec`; y, al llegar a cero, liberación directa (kind `0`),
ejecución del destructor (kind `2`) o envenenado + `unref` de los elementos +
liberación (kind `1`).

## 2. Detección de errores de memoria: `--debug-memory`

`planc --debug-memory` cambia tres cosas en el binario generado:

1. El asignador **nunca recicla** bloques liberados (sin *free lists*), de modo que
   un bloque reutilizado no puede ocultar un *use after free*.
2. Los arrays liberados se rellenan con `0xDD` (`rep stosb`), así que una lectura
   después del `free` devuelve datos reconocibles en lugar de datos válidos.
3. Se inserta `__planc_check_ref` en cada desreferencia de un tipo referencia
   (lecturas y escrituras de campo, vía `emit_null_check_if_nullable` y
   `gen_lvalue_addr`). El chequeo acepta `null`, cabeceras con `magic` correcto y
   objetos estáticos de `.rodata` (cabecera a cero) y, en cualquier otro caso,
   dispara `use after free`.

### Estado *dying*

Antes de ejecutar el destructor de una clase se escribe `0xFFFFFFFE` en el
`refcount`. Cualquier `__planc_ref` sobre un objeto en ese estado significaría
resucitar un objeto que se libera en cuanto el destructor retorna, así que se
rechaza en **todas** las builds (el panic reutiliza el diagnóstico genérico de
memoria). `__planc_unref` sobre un objeto *dying* sí se acepta y se ignora: es el
caso normal de una referencia soltada durante la destrucción.

## 3. Ownership estricto: `--strict-ownership`

Opt-in. Endurece las comprobaciones que en modo normal son solo avisos.

### 3.1 `unowned` y *borrows*

* `unowned T x = <variable>` registra un *borrow* del dueño: si el dueño se
  reasigna o sale de ámbito, el borrow queda marcado como muerto
  (`local_borrow_dead`) y su uso posterior se diagnostica.
* `unowned T x = <temporal>` (resultado de una llamada, `new`, literal,
  interpolación, …) se **rechaza**: el runtime libera ese valor al final de la
  sentencia, así que el borrow colgaría de inmediato. Sin `--strict-ownership` la
  declaración se promociona a local con ownership propio (comportamiento previo,
  seguro).
* Reasignar un `unowned` a un temporal se rechaza por el mismo motivo.
* Un `unowned T x = <expresión cuyo origen es un temporal>` (`make ().field`,
  `a[i].field` sobre un temporal) también se trata como temporal: el receptor se
  libera al final de la sentencia.
* Reasignar un borrow (`u = otro`) **no libera** el objetivo anterior ni toma
  ownership del nuevo: un borrow no posee nada. Si el nuevo valor es un temporal,
  conserva su referencia para no dejar un puntero colgado (se filtra en lugar de
  corromper) y `--strict-ownership` lo rechaza de todos modos.
* Un `unowned` no toma referencia al declararse ni la libera al salir de ámbito:
  nunca puede provocar un *double free*, solo (si se abusa) un valor colgante, que
  es exactamente lo que detectan las reglas anteriores.

### 3.2 Escapes

`check_borrow_escape` rechaza que un valor prestado escape a través de:

* el valor de retorno de la función,
* un campo (`this.campo = ...`),
* una variable global,
* una asignación a través de un parámetro `ref`/`out`.

Se considera "prestado" a `&local`, a un parámetro `ref`/`out`, a un `unowned` y a
una referencia `weak`.

### 3.3 `ref`/`out` de tipos de referencia

Pasar un valor prestado (`unowned`, `weak`, parámetro `ref`/`out`, o un campo cuyo
dueño es prestado) como argumento `ref`/`out` se rechaza: el callee escribiría una
referencia con ownership dentro de un slot que este ámbito no posee, lo que
provoca fugas o *double free*.

## 4. `[AsmBody]`: asm solo en código confiable

`[AsmBody(@"...")]` solo se acepta en ficheros de `stdlib/`, `kernel/`,
`planetrt/` y en cabeceras `.hlib` precompiladas. `--allow-asm-anywhere` desactiva
la restricción y existe únicamente para los tests del propio compilador
(marcador `*.allow_asm`).

Las rutinas que necesitan instrucciones que el ensamblador de `planc` no emite se
escriben con `.byte` en `stdlib/`, nunca en código de usuario.

## 5. Extensiones seguras de GLib

### 5.1 `stdlib/glib/arena.vala`

`ArenaHandle` es un identificador opaco `{ offset, len, generation }`. La API es
total: ninguna operación puede leer fuera de la región ni reutilizar memoria
liberada sin detectarlo.

* `alloc (n)` devuelve `ArenaHandle?`; `n` negativo, cero o mayor que el espacio
  libre devuelve `null` (nunca un panic ni un desbordamiento).
* Cada `free ()` incrementa la *generation* de la región; un handle con
  generación obsoleta (`rejected = true`) no se puede leer ni escribir.
* Los accesos (`get_u64`, `set_u64`, `slice`) validan `offset + len` contra el
  tamaño de la región y la generación antes de tocar memoria.

### 5.2 `stdlib/glib/simd.vala`

`popcount`, `sum_u8`, `avg_u8` son las únicas puertas de entrada a SIMD; los
kernels (`[AsmBody]` privados) viven en la stdlib. La ABI de un array en asm es
`rdi` = puntero a la cabecera, datos en `+16`. Las funciones validan longitud
negativa y arrays vacíos antes de ejecutar el kernel.

`stdlib/planet_math_kernels.vala` sigue el mismo patrón para SSE4.1/AVX2/FMA3: los
kernels son funciones libres en el namespace `Planet` y `mathlib` solo reenvía.

## 6. Autohospedaje verificado

`planc.elf` compila y ejecuta dentro de PlanetOS con el runtime endurecido:
`planc.elf --target=planetos utf8.vala -o t1.elf` + `t1.elf` produce
`chars=5 valid=1` / `cp0=0xF1 cp1=0x20AC cp2=0x1F680`, y lo mismo con
`class_basic.vala` (`ops=24`).

Ese caso destapó el bug que el chequeo de `0xDEADDEAD`/`magic` había convertido en
panic: reasignar un `unowned` liberaba el objetivo prestado (el slot se comportaba
como poseído en la ruta de asignación) y dejaba caer el `refcount` del dueño a
cero. Ahora un slot prestado no libera ni toma ownership en la asignación, así que
el compilador auto-hospedado vuelve a funcionar y el patrón ya no puede corromper
memoria.

## 7. Tests

| Sección de `planc/tests/run.sh` | Qué cubre |
|---|---|
| `ownership/` | asm fuera de stdlib, escape de `&local`, de `ref`/`out`, de `unowned`, borrow de temporal, rebind a temporal, borrow obsoleto, caso correcto |
| `valid/unowned_*` | rebind de `unowned` sin liberar el objetivo (release) y borrow de un campo de un temporal (promovido a owned) |
| `debugmem/` | `--debug-memory`: programa correcto, lectura UAF, escritura UAF, doble `free`, `ref` a objeto *dying* |
| `safe_ext/` | `ArenaHandle` (alloc/uso/liberación) y kernels SIMD |
| `visibility/` | `--strict-visibility` / `--enforce-visibility` |
