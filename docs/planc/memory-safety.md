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
| `+6` | `magic` | `0x504C` (`"PL"`) |
| `+8` | `len` / `vtable` | longitud para arrays, puntero a vtable para clases |

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
resucitar un objeto a medio destruir y dispara un panic. El estado se diagnostica
solo bajo `--debug-memory`: en release se mantiene el comportamiento histórico,
porque hay código legítimo que guarda `this` durante la destrucción.

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
* Un `unowned` no toma referencia al declararse ni la libera al salir de ámbito:
  nunca puede provocar un *double free*, solo (si se abusa) un valor colgante, que
  es exactamente lo que detectan las dos reglas anteriores.

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

## 6. Límite conocido

`planc.elf` auto-hospedado aborta con `planc: panic: memory error (double free or
corrupted block)` al compilar cualquier `.vala` dentro de PlanetOS (también con
`--dump-text`, es decir, antes del codegen). El chequeo de `0xDEADDEAD`/`magic` es
nuevo, así que el panic **destapa** un doble `unref` latente en la ruta de
parseo/AST del propio compilador; el bug no está corregido todavía y es el
siguiente trabajo de esta línea.

## 7. Tests

| Sección de `planc/tests/run.sh` | Qué cubre |
|---|---|
| `ownership/` | asm fuera de stdlib, escape de `&local`, de `ref`/`out`, de `unowned`, borrow de temporal, rebind a temporal, borrow obsoleto, caso correcto |
| `debugmem/` | `--debug-memory`: programa correcto, lectura UAF, escritura UAF, doble `free`, `ref` a objeto *dying* |
| `safe_ext/` | `ArenaHandle` (alloc/uso/liberación) y kernels SIMD |
| `visibility/` | `--strict-visibility` / `--enforce-visibility` |
