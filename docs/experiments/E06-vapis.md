# E-06 — `[CCode]` surface in the `.vapi` files

- **Risk it attacks:** R-01, TC-07
- **Assumption it answers:** V-04

## 1. Measured count

Over `glib-2.0.vapi`, `gobject-2.0.vapi` and `gio-2.0.vapi` from Vala 0.56:

| Attribute | Occurrences | Does `planc` accept it? |
|---|---|---|
| `cname` | 1179 | yes — symbol name (VL-10) |
| `cheader_filename` | 752 | **no** — it is ignored |
| `type_id` | 462 | no — it presupposes a run-time type registry |
| `array_length` | 283 | no — C layout |
| `cprefix` | 148 | no — C prefix |
| `has_type_id` | 127 | no |
| `array_null_terminated` | 121 | no |
| `instance_pos` | 71 | partially: it shifts `this`; without C it is not needed |
| `ref_function` / `unref_function` | 54 / 54 | no — foreign reference counting |
| `free_function` | 40 | no |
| `simple_generics` | 32 | no |
| `destroy_function` / `copy_function` | 14 / 14 | no |
| `lower_case_csuffix` | 8 | no |
| `floating` | 3 | our own semantics, not a foreign attribute |

**Relevant datum:** `cheader_filename` appears 752 times. Almost any third-party `.vapi` declares it on the first line. If the compiler rejected the whole `.vapi`, none of them would be reusable.

## 2. Rule adopted

Rejection happens **at the point of use, not at load**:

| Moment | Behavior |
|---|---|
| `.vapi` load | all attributes are accepted and kept as metadata |
| Use of a symbol | only the attributes with their own meaning are applied; the rest are ignored with a `-Wincompatible-vapi` warning |
| Use of a symbol that **only** makes sense with C (`cheader_filename` without `cname`) | TC-07 error |

This makes it possible to describe a library in a `.vapi` and use the compatible part, which is the only practical way to reuse declarations.

## 3. Consequence for `planetrt`

The `planetrt` `.vapi` files are written by hand and do **not** declare C attributes. They are the source of truth for the public API and, being our own, they define the dialect instead of inheriting it.

## 4. Conclusion

- **Passes.** V-04 answered with numbers.
- **Change to the plan:** [02 §14](../02-compiler.md#14-vapi) must specify deferred rejection at the point of use, which was not written down.
