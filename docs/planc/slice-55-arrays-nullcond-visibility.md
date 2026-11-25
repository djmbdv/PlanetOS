# Slice 55 — Arrays avanzados, operador `?.` y visibilidad en tiempo de compilación

Status: **implemented as a safe subset (2026-11-25); see “Estado de implementación”.**

Este documento define el plan de implementación por fases para cerrar tres brechas del dialecto Vala en `planc`, ordenadas por prioridad e incorporando criterios de **rendimiento** y **seguridad** desde el diseño.

---

## Prioridad 1 — Manejo y operadores de arrays

### 1.1 Operador `in` como expresión booleana (`x in arr`, `sub in str`)
- **Alcance**: `x in arr` sobre arrays 1D (`T[]`), `sub in str` sobre `string`, y (opcional) tipos con método `contains ()`.
- **Parser ([parser.vala](../../planc/src/parser.vala))**:
  - Añadir `in` como operador binario relacional en `parse_relational ()` (`BinaryExpr { op = "in" }`), manteniendo `foreach (... in ...)` sin ambigüedad.
- **Codegen ([codegen.vala](../../planc/src/codegen.vala))**:
  - `expr_type_full ()` devuelve `ValaType.BOOL`.
  - Para `T[]`: emitir bucle inline comparando por valor (`==` para escalares/referencias, `__planc_str_eq` para `string`), con salida temprana en la primera coincidencia.
  - Para `string`: reutilizar `__planc_str_index_of != -1` (misma ruta que `str.contains ()`).
- **Seguridad y rendimiento**:
  - Guarda de `null` en el operando derecho (`emit_null_check_if_nullable`), sin asignaciones en heap ni llamadas indirectas.

### 1.2 Métodos `arr.resize (n)` y `arr.move (src, dst, len)`
- **Codegen ([codegen.vala](../../planc/src/codegen.vala))**:
  - Registrar `resize` y `move` sobre `ValaType.ARRAY` en `is_builtin_method_call ()` y `check_builtin_method_args ()`.
  - `resize (int new_len)`: exige receptor asignable (*lvalue*: variable local, parámetro `ref` o campo); valida `new_len >= 0` (dispara *bounds panic* si es negativo); asigna nuevo bloque, copia `0..min(old_len, new_len)-1`, inicializa a cero los nuevos elementos y ajusta `ref`/`unref` en elementos de tipo referencia si se encoge o reemplaza.
  - `move (int src, int dst, int len)`: valida `len >= 0`, `src >= 0`, `dst >= 0`, `src + len <= arr.length` y `dst + len <= arr.length` antes de copiar (usando copia segura ante solapamiento tipo `memmove` y limpiando los huecos liberados sin doble `unref`).

### 1.3 Arrays multidimensionales rectangulares (`int[,]`, `new int[r, c]`, `a[i, j]`)
- **AST y Parser ([ast.vala](../../planc/src/ast.vala), [parser.vala](../../planc/src/parser.vala))**:
  - Añadir `rank` (`dims >= 2`) a la representación de tipo array, lista de dimensiones en `ArrayNewExpr` y lista de índices en `IndexExpr` / `IndexAssignStatement`.
- **Layout y Codegen ([codegen.vala](../../planc/src/codegen.vala))**:
  - Bloque contiguo *row-major* con dimensiones almacenadas en cabecera para lectura de `a.length[d]` en $O(1)$.
  - Cálculo de índice lineal `((i * dim1) + j) * elem_size` con **comprobación de límites independiente por cada dimensión** (`0 <= i < dim0`, `0 <= j < dim1`) para impedir lecturas/escrituras cruzadas entre filas aunque el índice lineal cayera dentro del buffer total.

---

## Prioridad 2 — Operador *null-conditional* (`?.`)

- **Lexer ([lexer.vala](../../planc/src/lexer.vala))**:
  - Añadir `TokenKind.QUESTION_DOT` (`?.`), distinguiéndolo del operador ternario `?` (solo se emite `QUESTION_DOT` cuando `?` va seguido inmediatamente de `.` y no de un literal numérico `.5`).
- **AST y Parser ([ast.vala](../../planc/src/ast.vala), [parser.vala](../../planc/src/parser.vala))**:
  - Añadir `bool is_null_cond` en `MemberAccessExpr` y `MethodCallExpr`.
  - Soportar encadenamiento en `parse_postfix ()` (`a?.b?.c ()`).
- **Codegen ([codegen.vala](../../planc/src/codegen.vala))**:
  - Evaluar el receptor **una sola vez** en `rax` (sin duplicar efectos secundarios).
  - Emitir `test rax, rax; je l_is_null`; si no es `null`, evaluar el acceso/llamada y saltar a `l_done`; en `l_is_null`, devolver `null`/`0` **en cortocircuito** sin evaluar los argumentos de `method (args)`.
  - Si el tipo del miembro/retorno no es nullable, promover el resultado de `expr_type_full ()` a nullable (`T?` en referencias) o rechazar si es un tipo valor incompatible sin `?`.

---

## Prioridad 3 — Visibilidad real en tiempo de compilación (`private`, `protected`, `internal`, `public`)

El objetivo es hacer cumplir la visibilidad **100 % en tiempo de compilación** (costo cero en runtime), manteniendo compatibilidad con `stdlib/` y `user/`.

- **AST y Parser ([ast.vala](../../planc/src/ast.vala), [parser.vala](../../planc/src/parser.vala))**:
  - Guardar `Visibility { PUBLIC, PRIVATE, PROTECTED, INTERNAL }` explícitamente en declaraciones de clases, structs, enums, interfaces, métodos, campos, propiedades, señales y constantes (respetando los valores por defecto de Vala 0.56).
- **Verificación semántica ([codegen.vala](../../planc/src/codegen.vala))**:
  - Centralizar un helper `check_member_visibility (Visibility vis, string owner_type, string member, int line, int col)`:
    - `PUBLIC`: permitido siempre.
    - `PRIVATE`: permitido solo dentro de `owner_type`.
    - `PROTECTED`: permitido dentro de `owner_type` y sus subclases (`is_subclass_of ()`).
    - `INTERNAL`: permitido dentro de la misma unidad/compilación (bloqueado para símbolos importados vía `.hlib`).
  - Aplicarlo en `MemberAccessExpr`, `MethodCallExpr`, constructores (`ClassNewExpr`), propiedades, señales y accesos estáticos (`Tipo.miembro`).
- **Despliegue seguro**:
  - Introducir primero un modo de diagnóstico (`--strict-visibility` / warnings) para detectar miembros en `stdlib/` y `user/` que dependían de la relajación actual, corregirlos a `public`/`protected`, y luego activar el rechazo por defecto con pruebas en `planc/tests/invalid/`.

---

## Plan de verificación

- **Pruebas válidas (`planc/tests/valid/`)**: casos para `in`, `resize`/`move`, arrays `[,]`, `?.` encadenado con cortocircuito de efectos secundarios, y acceso válido a `protected`/`private`.
- **Pruebas inválidas (`planc/tests/invalid/`)**: índices fuera de rango por dimensión en `[,]`, `resize(-1)`, acceso indebido a `private`/`protected` desde fuera de la clase/subclase.
- **Regresión**: `planc/tests/run.sh`, compilación de `stdlib/` (`.dlib`) y *self-hosting* (`valac` stage 0).

---

## Estado de implementación (2026-11-25)

La prioridad de seguridad se aplicó por encima del alcance original: las
funciones que no podían garantizar seguridad de memoria se restringieron o se
rechazan con un diagnóstico posicionado.

### 1.1 `in` — implementado
- `x in arr` (arrays 1D de enteros, flotantes, bytes, strings y referencias) y
  `sub in str` (`__planc_str_index_of`), con evaluación única de ambos operandos.
- `NaN` nunca coincide; arrays multidimensionales se rechazan.
- Pruebas: `valid/in_operator`, `invalid/in_operator_type`.

### 1.2 `resize`/`move` — implementado con límites
- `resize(n)` acepta variables, campos y elementos como receptor; copia con
  retención de elementos de referencia, rellena strings no anulables con `""` y
  libera el array anterior.
- **Guardas de seguridad**: longitud negativa → panic; longitud por encima de
  `(INT64_MAX-16)/stride` → panic (evita overflow en `n*stride`); arrays de
  structs, `[Compact]` y multidimensionales se rechazan.
- `move(src, dst, len)` valida cada argumento y ambos extremos, copia con
  solapamiento y limpia los huecos de origen en arrays de referencias.
- Pruebas: `valid/array_resize_move`, `bounds/array_resize_negative`,
  `bounds/array_resize_overflow`, `bounds/array_move_oob`,
  `invalid/array_resize_lvalue`, `invalid/array_resize_compact`.

### 1.3 Arrays multidimensionales — implementado (solo rango 2, representación jagged)
- `T[,]`, `new T[r,c]`, `a[i,j]` y `a.length[d]`.
- **Desviación de seguridad**: la representación es `T[][]` (filas
  independientes), no un bloque contiguo. Cada dimensión conserva su propia
  comprobación de límites y ninguna multiplicación de índices puede desbordar;
  a cambio se pierde la contigüidad row-major.
- **Restricciones**: solo rango 2; se rechazan elementos struct/delegate/array,
  clases `[Compact]`, strings anulables, `resize()`, `move()`, `in` y el
  `.length` sin dimensión. `new` valida ambas extensiones (negativas y overflow)
  y `length[d]` comprueba la dimensión y la ausencia de fila 0.
- Pruebas: `valid/multidim_2d`, `bounds/multidim_oob_row`,
  `bounds/multidim_oob_col`, `bounds/multidim_negative_dim`,
  `bounds/multidim_overflow`, `invalid/multidim_*`.

### 2. `?.` — implementado con restricciones
- Acceso a miembro y llamada a método con evaluación única del receptor y
  cortocircuito total (los argumentos no se evalúan si el receptor es nulo).
- **Restricciones de seguridad**: el receptor debe ser un tipo referencia; el
  receptor se cachea en un temporal **no poseído** (sin `ref`/`unref` extra);
  `?.` se rechaza sobre `resize()` porque reasigna el receptor.
- Pruebas: `valid/null_cond_operator`, `invalid/null_cond_struct_receiver`,
  `invalid/null_cond_resize`.

### 3. Visibilidad — implementado en modo opt-in
- Se almacenan `private`/`protected`/`internal`/`public` en funciones y campos
  de clase/struct; `private` solo dentro del tipo, `protected` también en
  subclases; `internal` se trata como público por ahora.
- `--strict-visibility` emite warnings y `--enforce-visibility` rechaza con
  diagnóstico posicionado; el modo por defecto sigue siendo permisivo hasta
  auditar `stdlib/` y `user/`.
- Cobertura: lecturas/escrituras de campos, llamadas a métodos y constructores.
  **Pendiente**: propiedades, señales y accesos estáticos (`Tipo.miembro`), y
  activar el rechazo por defecto.
- Pruebas: `planc/tests/visibility/` (integrado en `run.sh`).

### Revisión de seguridad aplicada
Se corrigieron cuatro hallazgos de la revisión del diff: doble `unref` del
receptor de `?.`, overflow de `n*stride` en `resize`/`new T[n]`, `?.resize`
reasignando sobre el temporal, y receptores struct aceptados en `?.`; además se
rechaza `resize` sobre arrays de clases `[Compact]`.

### Verificación
`planc/tests/run.sh`: **260 casos, 259 pasan**. El único fallo
(`struct_union_delegate_arrays`, array literal de delegates) es preexistente y
ya fallaba antes de esta slice.
