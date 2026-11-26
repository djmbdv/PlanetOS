# El dialecto `planc`: catálogo de capacidades

Referencia de lo que el compilador acepta, lo que rechaza y cómo se comporta en
ejecución. Todo lo marcado como soportado tiene un caso en `planc/tests/`; el
nombre del test va entre paréntesis para poder verificarlo.

`planc` compila un subconjunto **seguro y sin interoperabilidad con C** de Vala
0.56 a x86-64 (`--target=planetos`, `--target=windows`, `--target=spirv`). Cada
decisión de semántica se midió contra `valac` 0.56.19 antes de implementarla, y
las divergencias deliberadas están listadas en la sección 5.

---

## 1. Modelo de ejecución y ABI

`planc` no usa el ABI de C. Su unidad de medida es el **slot de 8 bytes**:

| Concepto | Regla |
|---|---|
| `int`, `uint`, `int64`, `bool`, `char`, punteros, referencias | 1 slot (8 B) |
| `float`/`double` | 1 slot, en registro XMM |
| `enum` | 1 slot; admite conversión a/desde `int` |
| `struct` | `8 * slots` bytes, campos en orden de declaración |
| `sizeof (T)` / `sizeof (expr)` | devuelve el tamaño **en este ABI** (`sizeof (int)` = 8, no 4) |
| `uint8`/`int8` | arrays *byte-view*: 1 byte por elemento |

Por eso `sizeof` de `planc` no sirve para calcular buffers de C: para datos
binarios hay que usar los arrays `uint8[]` y las vistas de bytes (sección 6).

### Objetos y memoria

Cada bloque del heap lleva cabecera de 16 B: `refcount` (`+0`), `kind` (`+4`),
clase de tamaño (`+5`), `magic 0x504C` (`+6`), longitud o vtable (`+8`), y
páginas reservadas para bloques grandes (`+12`). Los datos empiezan en `+16`.
El detalle completo, con las reglas de `unowned`/`weak`, los estados envenenado y
*dying*, `--debug-memory` y las arenas, está en
[memory-safety.md](memory-safety.md).

---

## 2. Léxico y preprocesador

| Capacidad | Notas | Test |
|---|---|---|
| Comentarios `//`, `/* */` | los anidados no se permiten (igual que valac) | — |
| `#if` / `#elif` / `#else` / `#endif` | por líneas, consciente de strings y comentarios; define `PLANC` y `VALA_0_<n>`; `-D NAME` | `preproc` |
| `#error` / `#warning` | se respetan | `preproc` |
| Literales de escape (`\n`, `\xNN`, `\u`, `\U`) | UTF-8 nativo | `escapes`, `char_escapes`, `utf8` |
| Cadenas verbatim `"""…"""` | sin escapes ni dedent | `string_slice_literals` |
| Interpolación `@"$(expr)"` | imprime/compone con `print` y concatenación | `template_print`, `template_value` |
| Identificadores escapados `@class` | permiten usar palabras reservadas | `escaped_ident` |
| Identificadores Unicode (`café`) | **no**: valac tampoco los acepta | `invalid/keyword_as_name` |

---

## 3. Tipos y expresiones

| Área | Soportado | Test |
|---|---|---|
| Enteros `int`, `int8…64`, `uint8…64`, `uintptr` | aritmética, *divmod*, *shifts*, bit a bit, promociones | `unsigned_ints`, `bitwise`, `divmod`, `uintptr_ptr` |
| Coma flotante `float`/`double` | intrínsecos y comparaciones | `float_double`, `math_int_fp_intrinsics` |
| `bool` | `&&`, `\|\|`, `!`, cortocircuito | `bool_type`, `shortcircuit`, `not_operator` |
| `char` / `unichar` | métodos de carácter, UTF-8 | `char_methods`, `unichar_and_chunk` |
| `string` | concatenación, `==`/`!=` por contenido, `length`, indexación (solo lectura), slicing, literales | `string_*` (varios) |
| `string?` + *narrowing* | `!= null` estrecha el tipo | `nullable_narrowing` |
| Asignación a índice de string | **no** (inmutable) | `invalid/string_index_assign` |
| Arrays 1D `T[]` | `new T[n]`, `.length`, indexación con *bounds check*, literales | `array_int`, `array_string`, `slice_*` |
| Arrays byte `uint8[]` | 1 B/elemento, base de los datos binarios | `byte_arrays_and_stdlib` |
| `in (array)` y `in (string)` | evaluación única, `NaN` nunca coincide | `in_operator` |
| `arr.resize (n)`, `arr.move (src, dst, len)` | guards de signo/overflow, receptor *lvalue*, no sobre `[Compact]` ni structs | `array_resize_move` |
| Arrays 2D `T[,]` / `new T[r,c]` / `a[i,j]` / `a.length[d]` | **jagged** (`T[][]`): filas independientes, bounds por dimensión | `multidim_2d` |
| `?.` (*null-conditional*) | receptor no poseído, rechaza struct y `?.resize` | `null_cond_operator` |
| `?:` y `??` | ternario y *coalesce* | `ternary_coalesce` |
| Casts `(T)`, `as`, `is` | conversión de tipos y comprobación dinámica | `null_and_cast`, `object_root` |
| `sizeof`, `assert`, `exit (n)` | `exit` exige entero | `sizeof`, `exit_code`, `exit_expr` |
| `print` | **exige** `string` o plantilla | `hello`, `invalid/print_needs_string` |
| `main` | `int main ()` sin parámetros; no `string` | `invalid/main_with_params`, `invalid/string_main` |

---

## 4. Sentencias y control de flujo

`if`/`else`, `while`, `do … while`, `for (…)`, `foreach` sobre arrays y sobre
tipos con `iterator ()`, `break`, `continue`, `return` en mitad de bucle,
`switch` con `case a, b:` apilados, `fallthrough`, `lock (expr) { }` (spinlock no
recursivo) y `using` de namespace.

Tests: `if_else`, `while_loop`, `do_while`, `for_break_continue`, `foreach_array`,
`foreach_iterable`, `switch_stmt`, `case_list`, `fallthrough`, `lock_stmt`,
`using_namespace_qualified`.

---

## 5. Objetos, interfaces y structs

| Construcción | Estado | Test |
|---|---|---|
| `class` con campos, métodos, constructores, `this`, `new` | soportado | `class_basic` |
| Herencia, `virtual`/`override`, `abstract` | soportado; heredar de `sealed` es error | `class_inheritance`, `bad_override`, `instantiate_abstract`, `sealed_inherited` |
| Propiedades (auto y con cuerpo), campos + getter | soportado | `properties_and_initializers`, `field_and_getter` |
| Indexadores `T this[I i]` | **extensión de planc** (valac no tiene sintaxis) | `indexer` |
| `static` campos y métodos | campo estático = global `Clase.campo` | `static_fields` |
| Destructor `~Clase ()` + ARC | se ejecuta al llegar el refcount a 0 | `class_dtor_arc`, `refcount_loop` |
| `Object` como raíz universal | toda clase sin base deriva de `Object` (divergencia, sección 6) | `object_root` |
| Interfaces: métodos, propiedades, señales, `static`, defaults | soportado | `interfaces`, `iface_property`, `iface_signals`, `iface_static`, `iface_default_sibling` |
| Señales de clase: `signal`, `.connect`, `.disconnect`, handler por defecto | soportado | `signals` |
| `[Compact]` | clase sin vtable ni destructor, `free ()` manual | `compact_manual`, `compact_nested` |
| `struct` | valor: copia en asignación, paso y retorno; campos anidados; campos `string`; dentro de `[Compact]` | `struct_type` |
| Arrays de `struct` (`P[]`, slab contiguo con stride) | un solo bloque de `n * stride` bytes, cero-inicializado; `arr[i].campo` es un *lvalue*, `P a = arr[i]` copia, `ref arr[i]` alcanza el slab, `foreach` copia el elemento; solo structs **POD** | `struct_array`, `bounds/struct_array_oob`, `invalid/struct_array_ref_field`, `invalid/struct_array_resize` |
| `union` | se parsea; el caso con arrays de delegates **falla** (único test rojo de la suite) | `struct_union_delegate_arrays` |
| `enum` (+ conversión con `int`) | soportado | `enum_type` |
| Delegates y lambdas | capturas, `weak`, tipos anidados | `delegates_and_lambdas`, `nullable_delegate` |
| Genéricos: clases, métodos, funciones, interfaces | monomorfización por lista de argumentos; inferencia desde `T`/`T[]`; tope anti-DoS | `generics_and_array`, `generic_methods`, `generic_interfaces` |
| Namespaces y tipos hacia delante | soportado | `namespaces_and_forward_types` |

### `struct` en arrays (slab contiguo)

`T[]` con `T` struct es **un solo bloque** de `16 + n * stride` bytes, con
`stride = 8 * slots del struct`:

* el header guarda `n` como número de elementos, así que `.length` y el
  *bounds check* (`indice < n`) no cambian;
* `arr[i]` calcula la dirección del elemento (`i * stride`); en x86 `lea` solo
  escala por 1/2/4/8, así que cualquier otro stride multiplica el índice antes
  (`imul`) y luego suma;
* `P a = arr[i]` y `f (arr[i])` copian los slots a un temporal de pila: el valor
  nunca aliasa el slab;
* `arr[i].campo = v`, `ref arr[i]` y `arr[i]++` operan sobre el elemento real;
* `foreach (var p in arr)` copia el elemento en cada iteración;
* el bloque llega **cero-inicializado** (clases recicladas y bloques grandes se
  limpian al asignar, y las páginas nuevas vienen a cero del kernel).

Restricciones, por seguridad del runtime:

* solo structs **POD**: un struct con campos de referencia (`string`, arrays,
  clases) se rechaza, porque el bloque se libera sin recorrer elementos;
* `resize` y `move` se rechazan sobre arrays de structs (moverían elementos
  inline sin refcount);
* `in` se rechaza (los structs no tienen `==`);
* 2D (`P[,]`, `P[][]`) sigue rechazado.

Límites que quedan: no hay campo array de tamaño fijo dentro de un struct
(`int16 lumps[8]`), y `&local` sigue prohibido, así que un struct no puede
direccionarse ni escapar de su ámbito.
* Un struct **POD** puede copiarse en crudo; uno con campos `string`/array
  necesita las rutinas de ref/unref (las tiene en asignación, no en `memcpy`).

---

## 6. Diferencias deliberadas con Vala estándar

| Regla | Motivo | Alternativa |
|---|---|---|
| `&local` es error duro ("use `ref` or a class/array slot") | una dirección de pila muere con el frame y el frame se reutiliza: sería corrupción silenciosa | `ref`/`out`, campo de clase, elemento de array, o dejar ese struct como objeto de heap |
| `[AsmBody]` solo en `stdlib/`, `kernel/`, `planetrt/` y `.hlib` | el asm no se puede auditar en código de usuario | helpers en la stdlib (`Planet.Unsafe`, `Simd`, kernels de `mathlib`) |
| `--strict-ownership`: `unowned` no puede nacer de un temporal ni rebindearse a uno; los `ref`/`out` no pueden recibir valores prestados; un préstamo muerto es error | elimina UAF y dobles `free` evadibles desde código normal | copia con ownership propio |
| `--debug-memory`: bloques que nunca se reciclan, relleno `0xDD` y `__planc_check_ref` en cada desreferencia | convierte UAF silencioso en panic localizado | — |
| `[Compact]` no tiene destructor | no hay vtable donde engancharlo | no metas campos con dueño dentro de un `[Compact]`; usa una `class` |
| `resize`/`move` no admiten `[Compact]` ni structs | reciclar el bloque de elementos dejaría referencias colgando o copias a medias | arrays de tipos escalares/referencia, o reasignar |
| Sin `.vapi`, `--pkg`, `[CCode]`, `typeof` | decisión de diseño: el dialecto es el lenguaje, no los bindings | `--import-lib`/`--library-dir` con `.dlib`/`.hlib` propias |
| `Object` es la base implícita de toda clase | permite `Object o = cualquierCosa` sin declarar la base | ninguno: es una comodidad, no rompe semántica (`is`/`as`/`==` idénticos) |
| Visibilidad `private`/`protected`/`internal` se acepta y se ignora salvo `--strict-visibility`/`--enforce-visibility` | activarla puede romper fuentes existentes | compilar con `--strict-visibility` |
| `new string[n]` rellena cada hueco con `""`, no con `null` | un array de `string` no admitidos como nulos evita el `NullPointerError` a mitad de un literal o de un `.length` | declarar el array como `string?[]` si de verdad hacen falta huecos nulos; el idioma C de tabla terminada en `NULL` no se traduce solo |
| `#pragma`/`#line`, `typeof`, `[NoReturn]`, `[SimpleType]`, `[PointerType]` | aceptados e inertes o no implementados | — |

Otras divergencias medidas y por qué no se implementan (comentario anidado,
identificadores Unicode, `foreach` sobre `string`) están en
[slice-50-dialect-gaps.md](slice-50-dialect-gaps.md).

---

## 7. Memoria y concurrencia

| Área | Capacidad | Test |
|---|---|---|
| Ownership | `unowned`, `weak`, `ref`, `out`, ARC por refcount, `--check-leaks` | `unowned_ownership`, `weak_refs`, `out_ref_params`, `check_leaks_*` |
| Punteros | `void*`, `uintptr`, `C2VPtr`, `poke`/`peek` acotados a la stdlib (`Planet.Unsafe`) | `safe_pointers`, `uintptr_ptr` |
| Arenas seguras | `ArenaHandle` (offset + longitud + generación) en [stdlib/glib/arena.vala](../../stdlib/glib/arena.vala) | `safe_ext/arena`, `arena_stale`, `goose_arena_escape` |
| SIMD | `popcount`, `sum_u8`, `avg_u8` y kernels SSE4.1/AVX2/FMA3 privados | `safe_ext/simd`, `math_int_fp_intrinsics` |
| `async`/`yield` | `Async.run ()`, `Async.run_parallel (n)`, máquinas de estado en heap | `async_goroutines` |
| Canales y cerrojos | `Channel<T>`, `Mutex`, `lock`, hilos `GLib.Thread` → `SYS_THREAD_SPAWN` en PlanetOS | `channels_and_mutex`, `lock_stmt` |
| Errores | `errordomain`, `throw`, `throws`, `try`/`catch`; dominio desconocido y error no capturado son error de compilación | `error_handling`, `invalid/catch_unknown_domain`, `invalid/unhandled_error` |

---

## 8. Modos de compilación

```
planc <fuentes.vala>… -o <salida> [flags]
```

| Flag | Efecto |
|---|---|
| `--target=planetos` | ELF64 de userland (`0x800000`..), syscalls `int 0x80`, runtime `planetrt` |
| `--target=windows` | PE/COFF para ejecutar en el host (lo usa la suite) |
| `--target=spirv` | compilador de shaders determinista (`frag_color`) |
| `--format=elf\|plan\|dlib` | binario, formato intermedio `plan`, o librería |
| `--import-lib=NAME`, `--import-dlib=PATH`, `--library-dir=DIR` | enlazar `.dlib`/`.hlib` |
| `--image-base=ADDR` | base de carga del ELF |
| `--freestanding`, `--nostdlib` | sin libc/host: kernel y `planetrt` |
| `--no-bounds-check`, `--no-null-check` | desactivan las comprobaciones (solo para benchmarks/tests del compilador) |
| `--check-leaks`, `--check-overflow` | instrumentación de fugas y de desbordamiento aritmético |
| `--debug-memory` | UAF: sin reciclado, relleno `0xDD`, `__planc_check_ref` |
| `--strict-ownership` | reglas de préstamos de la sección 6 |
| `--strict-null`, `--strict-unused`, `--no-warn-unused` | rigor de nulos y de variables sin usar |
| `--strict-visibility`, `--enforce-visibility` | aplican `private`/`internal`/`protected` |
| `--allow-asm-anywhere`, `--no-asm` | excepción de asm / rechazo total de asm |
| `--dump-text` | volcado del texto generado |
| `--error-limit=N`, `--no-error-recovery` | control de la recuperación de errores |

### Diagnósticos de runtime

| Mensaje | Cuándo |
|---|---|
| `planc: panic: index out of bounds` | índice fuera de rango (por defecto activo) |
| `planc: panic: null pointer dereference` | desreferencia de `null` |
| `planc: panic: memory error (double free or corrupted block)` | `0xDEADDEAD`, `magic` roto, o resurrección de un objeto *dying* |
| `planc: panic: use after free or corrupted reference (debug memory)` | `--debug-memory` |
| `planc: panic: out of memory` | el asignador no consigue páginas |
| `planc: panic: integer overflow` | `--check-overflow` |
| `planc: panic: invalid class cast` | `as`/cast a una clase incompatible |
| `planc: panic: memory leak detected` | `--check-leaks` al terminar |

---

## 9. Verificación

```
planc/tests/run.sh          # suite completa (work dir temporal; KEEP=1 lo conserva)
```

Estado actual: **287 casos, 286 pasan**. El único fallo es
`valid/struct_union_delegate_arrays` (arrays de delegates dentro de `union`).
Secciones:

| Sección | Qué prueba | Casos |
|---|---|---|
| `valid/` | compila, ejecuta y compara stdout/exit | 120 |
| `invalid/` | rechazo con diagnóstico posicionado | 80 |
| `bounds/` | panics de rango, tamaños negativos y overflow de `n*stride` | 15 |
| `visibility/` | `--strict-visibility` / `--enforce-visibility` | 5 |
| `safe_ext/` | arena y kernels SIMD | 3 |
| `ownership/` | asm confinado, escapes, `unowned`/`ref`/`out` | 11 |
| `debugmem/` | UAF de lectura y escritura, doble `free`, objeto *dying* | 5 |
| `check_leaks/`, `null_and_cast/`, `compact/`, `multifile/`, `dwarf/`, `-O1`, `-O2` | instrumentación e interoperabilidad | resto |

Convenciones: un caso `valid/` puede llevar un `.out` con la salida esperada; los
`invalid/` deben fallar en compilación; los `bounds/` y `debugmem/` deben abortar
con el panic declarado en su `.panic`; los tests que necesitan asm propio llevan
el marcador `*.allow_asm`.

El traductor C→Vala tiene su propia suite diferencial (compila con gcc y compara
la salida con la del Vala generado):

```
python tools/c2vala_tests/run.py    # 21 casos, incluido struct_array_members
```

---

## 10. Huecos conocidos (orden de prioridad)

1. **Arrays de C con inicializador** (`c2vala`): los globales `T[]` sin
   inicializador, los miembros array de un struct y las dimensiones internas de un
   array multidimensional ya se asignan (ver §9 y el caso
   `c2vala_tests/cases/struct_array_members`). Lo que sigue sin cubrirse son los
   inicializadores de tablas de structs (`state_t states[] = {{...}}`) cuando el
   struct contiene una unión de punteros a función: el literal elige un delegado
   de 0 parámetros y las acciones de DOOM llevan 2.
2. **Array literal con elementos delegate** (`Op[] ops = { f, g }`): único test
   rojo de la suite (`struct_union_delegate_arrays`). Los structs y uniones de ese
   caso ya funcionan.
3. **Campos array de tamaño fijo** dentro de un struct: no hay sintaxis; `c2vala`
   los emite como `T[]` y los asigna en el constructor por defecto (con
   `this.campo`, porque un campo no ensombrece a un global homónimo dentro de un
   constructor).
4. **`--dump-text`/`typeof`/`.vapi`**: fuera de alcance por decisión, no por falta
   de tiempo.
