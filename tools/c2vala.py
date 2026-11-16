#!/usr/bin/env python3
"""C -> Vala source translator for a restricted subset (tier 0 + tier 1).

The subset is what tools/c_coverage.py classifies as tier 0 / tier 1 plus a
handful of explicit rewrites. Anything outside it is *refused with a
diagnostic* rather than mistranslated:

  supported   functions, ints/floats/bools, enums (values constant-folded),
              structs (as Vala classes), struct pointers (nullable refs),
              char pointers (Vala string), struct arrays, if/while/do/for,
              switch with break/return/goto, continue, casts, ternary,
              sizeof of scalars, printf -> stdout.printf

  rewritten   `T *x` indexed or `&x[i]`   -> `T[]`
              `token->field`              -> `token!.field`
              uninitialized struct local  -> `new T ()`
              struct array local          -> allocated element by element
              `a = b = c;`                -> two statements
              `goto L` (L after the loop) -> flag + breaks

  refused     unions, bitfields, function pointers, varargs, inline asm,
              variable-length arrays, pointer arithmetic other than indexing,
              switch fallthrough with statements, global variables,
              initializer lists

Usage:
    python tools/c2vala.py input.c -o out.vala
    python tools/c2vala.py jsmn.h driver.c -o out.vala --cc gcc
"""

import argparse
import os
import sys
import tempfile

from pycparser import c_ast, c_parser

import c_coverage as cc


class Refuse(Exception):
    def __init__(self, node, why):
        loc = ""
        if node is not None and getattr(node, "coord", None) is not None:
            coord = node.coord
            if coord.file:
                loc = "%s:%s: " % (coord.file, coord.line)
        super().__init__(loc + why)


VALA_SCALAR = {
    "void": "void", "bool": "bool", "char": "char", "uchar": "uchar",
    "short": "short", "ushort": "ushort", "int": "int", "uint": "uint",
    "long": "long", "ulong": "ulong", "size_t": "size_t",
    "int8": "int8", "uint8": "uint8", "int16": "int16", "uint16": "uint16",
    "int32": "int32", "uint32": "uint32", "int64": "int64", "uint64": "uint64",
    "float": "float", "double": "double",
}

RANK = {
    "bool": 1, "char": 2, "uchar": 2, "int8": 2, "uint8": 2,
    "short": 3, "ushort": 3, "int16": 3, "uint16": 3,
    "int": 4, "uint": 4, "int32": 4, "uint32": 4,
    "long": 5, "ulong": 5, "size_t": 5, "int64": 5, "uint64": 5,
    "float": 6, "double": 7,
}

UNSIGNED = {"uchar", "ushort", "uint", "ulong", "size_t",
            "uint8", "uint16", "uint32", "uint64"}

IDENTS = {
    "int": ("scalar", "int"),
    "signed int": ("scalar", "int"),
    "unsigned int": ("scalar", "uint"),
    "unsigned": ("scalar", "uint"),
    "char": ("scalar", "char"),
    "signed char": ("scalar", "int8"),
    "unsigned char": ("scalar", "uchar"),
    "short": ("scalar", "short"),
    "short int": ("scalar", "short"),
    "unsigned short": ("scalar", "ushort"),
    "unsigned short int": ("scalar", "ushort"),
    "long": ("scalar", "long"),
    "long int": ("scalar", "long"),
    "unsigned long": ("scalar", "ulong"),
    "unsigned long int": ("scalar", "ulong"),
    "long long": ("scalar", "int64"),
    "unsigned long long": ("scalar", "uint64"),
    "float": ("scalar", "float"),
    "double": ("scalar", "double"),
    "long double": ("scalar", "double"),
    "_Bool": ("scalar", "bool"),
    "void": ("scalar", "void"),
    "size_t": ("scalar", "size_t"),
    "ssize_t": ("scalar", "long"),
    "int8_t": ("scalar", "int8"),
    "uint8_t": ("scalar", "uint8"),
    "int16_t": ("scalar", "int16"),
    "uint16_t": ("scalar", "uint16"),
    "int32_t": ("scalar", "int32"),
    "uint32_t": ("scalar", "uint32"),
    "int64_t": ("scalar", "int64"),
    "uint64_t": ("scalar", "uint64"),
    "bool": ("scalar", "bool"),
}


def unwrap_type(node):
    """pycparser 3.0 wraps typedef'd aggregates in a TypeDecl."""
    while isinstance(node, c_ast.TypeDecl):
        node = node.type
    return node


def kind_of(ct):
    return ct[1] if ct is not None and ct[0] == "scalar" else None


def is_scalar(ct, kind=None):
    return ct is not None and ct[0] == "scalar" and (kind is None or ct[1] == kind)


def is_ptr(ct):
    return ct is not None and ct[0] == "ptr"


def is_class(ct):
    return ct is not None and ct[0] == "class"


def is_char_ptr(ct):
    return is_ptr(ct) and is_scalar(ct[1], "char")


def vala_of(ct, as_array=False):
    if ct is None:
        return "void"
    tag = ct[0]
    if tag == "scalar":
        return VALA_SCALAR[ct[1]]
    if tag == "enum" or tag == "class":
        return ct[1]
    if tag == "array":
        return "%s[]" % vala_of(ct[1])
    if tag == "ptr":
        inner = ct[1]
        if is_scalar(inner, "char"):
            return "string"
        if is_scalar(inner, "void"):
            return "void*"
        if as_array:
            return "%s[]" % vala_of(inner)
        return "%s?" % vala_of(inner)
    raise Refuse(None, "unsupported type")


def promote(a, b):
    ka, kb = kind_of(a), kind_of(b)
    if ka is None or kb is None:
        return a if ka is not None else b
    if "double" in (ka, kb):
        return ("scalar", "double")
    if "float" in (ka, kb):
        return ("scalar", "float")
    ra, rb = RANK[ka], RANK[kb]
    if ra == rb:
        if ka in UNSIGNED:
            return ("scalar", ka)
        if kb in UNSIGNED:
            return ("scalar", kb)
        return a
    return a if ra > rb else b


class Translator:
    def __init__(self, allowed):
        self.allowed = allowed
        self.typedefs = {}
        self.enums = {}        # name -> [(member, value)]
        self.enum_values = {}  # member -> value
        self.classes = {}      # name -> {field: ctype}
        self.signatures = {}
        self.scope = {}
        self.arrays = set()
        self.func_bodies = {}
        self.array_params = set()
        self.ret_type = None
        self.flags = []

    # ------------------------------------------------------------- types

    def from_type(self, node):
        if isinstance(node, c_ast.TypeDecl):
            return self.from_type(node.type)
        if isinstance(node, c_ast.IdentifierType):
            names = " ".join(node.names)
            if names in IDENTS:
                return IDENTS[names]
            if names in self.typedefs:
                return self.typedefs[names]
            if names in self.enums:
                return ("enum", names)
            if names in self.classes:
                return ("class", names)
            raise Refuse(node, "unknown type '%s'" % names)
        if isinstance(node, c_ast.PtrDecl):
            return ("ptr", self.from_type(node.type))
        if isinstance(node, c_ast.ArrayDecl):
            elem = self.from_type(node.type)
            size = None
            if node.dim is not None:
                if not isinstance(node.dim, c_ast.Constant):
                    raise Refuse(node, "variable-length arrays are not supported")
                size = int(node.dim.value, 0)
            return ("array", elem, size)
        if isinstance(node, c_ast.Enum):
            if not node.name:
                raise Refuse(node, "anonymous enum outside a typedef")
            return ("enum", node.name)
        if isinstance(node, c_ast.Struct):
            if not node.name:
                raise Refuse(node, "anonymous struct outside a typedef")
            return ("class", node.name)
        if isinstance(node, c_ast.Union):
            raise Refuse(node, "unions are not supported")
        if isinstance(node, c_ast.FuncDecl):
            raise Refuse(node, "function pointers are not supported")
        if isinstance(node, c_ast.BitField):
            raise Refuse(node, "bitfields are not supported")
        raise Refuse(node, "unsupported declarator %s" % type(node).__name__)

    def const_int(self, node):
        if isinstance(node, c_ast.Constant):
            return int(node.value, 0)
        if isinstance(node, c_ast.BinaryOp):
            a = self.const_int(node.left)
            b = self.const_int(node.right)
            if node.op == "+":
                return a + b
            if node.op == "-":
                return a - b
            if node.op == "*":
                return a * b
            if node.op == "/":
                return int(a / b) if b else 0
            if node.op == "%":
                return a % b if b else 0
            if node.op == "<<":
                return a << b
            if node.op == ">>":
                return a >> b
            if node.op == "|":
                return a | b
            if node.op == "&":
                return a & b
            if node.op == "^":
                return a ^ b
            raise Refuse(node, "unsupported constant operator '%s'" % node.op)
        if isinstance(node, c_ast.UnaryOp):
            v = self.const_int(node.expr)
            if node.op == "-":
                return -v
            if node.op == "+":
                return v
            if node.op == "~":
                return ~v
            raise Refuse(node, "unsupported constant unary '%s'" % node.op)
        if isinstance(node, c_ast.ID) and node.name in self.enum_values:
            return self.enum_values[node.name]
        raise Refuse(node, "non-constant enum initializer")

    # ----------------------------------------------------------- pre-pass

    def keep(self, node):
        if self.allowed is None:
            return True
        coord = getattr(node, "coord", None)
        if coord is None or coord.line is None:
            return True
        return coord.line in self.allowed

    def collect(self, ast):
        decls = [e for e in ast.ext if self.keep(e)]
        # enums first: their members are constants used by everything else
        for ext in decls:
            if isinstance(ext, c_ast.Typedef) and isinstance(unwrap_type(ext.type), c_ast.Enum):
                self.register_enum(ext.name, unwrap_type(ext.type))
            elif isinstance(ext, c_ast.Decl) and isinstance(ext.type, c_ast.Enum):
                self.register_enum(ext.type.name or "", ext.type)
        for ext in decls:
            if isinstance(ext, c_ast.Typedef):
                self.register_typedef(ext)
            elif isinstance(ext, c_ast.Decl) and isinstance(ext.type, c_ast.Struct):
                if ext.type.name:
                    self.register_struct(ext.type.name, ext.type)
        for ext in decls:
            if isinstance(ext, c_ast.FuncDef):
                ret = self.from_type(ext.decl.type.type)
                params = []
                args = ext.decl.type.args
                if args is not None:
                    for p in args.params:
                        if p.name is None:
                            # `int f(void)` declares no parameters
                            if len(args.params) == 1 and is_scalar(self.from_type(p.type), "void"):
                                continue
                            raise Refuse(p, "unnamed parameter")
                        params.append((p.name, self.from_type(p.type)))
                self.signatures[ext.decl.name] = (ret, params)
                self.func_bodies[ext.decl.name] = ext
        self.solve_array_params()

    def solve_array_params(self):
        """Decides, program-wide, which pointer parameters are arrays.

        A `T *tok` parameter is an array when the function indexes it (`tok[i]`,
        `&tok[i]`) *or* when it is forwarded to a callee that indexes it. Doing
        this globally keeps signatures consistent across the call graph.
        """
        arrays = set()
        for name, body in self.func_bodies.items():
            local = self.names_used_as_array(body)
            for idx, (pname, pct) in enumerate(self.signatures[name][1]):
                if is_ptr(pct) and pname in local:
                    arrays.add((name, idx))
        changed = True
        while changed:
            changed = False
            for name, body in self.func_bodies.items():
                params = self.signatures[name][1]
                by_name = {p[0]: i for i, p in enumerate(params)}
                for call in self.iter_calls(body):
                    callee = call.name.name if isinstance(call.name, c_ast.ID) else None
                    if callee not in self.signatures:
                        continue
                    for argidx, arg in enumerate(self.call_args(call)):
                        if not isinstance(arg, c_ast.ID):
                            continue
                        if (callee, argidx) not in arrays:
                            continue
                        if arg.name in by_name:
                            key = (name, by_name[arg.name])
                        else:
                            key = None
                        if key is not None and key not in arrays:
                            arrays.add(key)
                            changed = True
        self.array_params = arrays

    @staticmethod
    def iter_calls(node):
        found = []

        class V(c_ast.NodeVisitor):
            def visit_FuncCall(self, n):
                found.append(n)
                self.generic_visit(n)

        V().visit(node)
        return found

    def register_enum(self, name, node):
        members = []
        for item in (node.values.enumerators if node.values else []):
            value = self.const_int(item.value) if item.value is not None else len(members)
            members.append((item.name, value))
            self.enum_values[item.name] = value
        if name:
            self.enums[name] = members
            self.typedefs.setdefault(name, ("enum", name))

    def register_struct(self, name, node):
        self.classes[name] = {}
        self.typedefs.setdefault(name, ("class", name))
        for decl in (node.decls or []):
            if decl.name is None:
                raise Refuse(decl, "anonymous struct member")
            self.classes[name][decl.name] = self.from_type(decl.type)

    def register_typedef(self, node):
        t = unwrap_type(node.type)
        if isinstance(t, c_ast.Enum):
            return  # handled in the first pass
        if isinstance(t, c_ast.Struct):
            self.register_struct(node.name, t)
            if t.name and t.name != node.name:
                self.typedefs[t.name] = ("class", node.name)
                self.classes.pop(t.name, None)
            return
        if isinstance(t, c_ast.Union):
            raise Refuse(node, "unions are not supported")
        if isinstance(node.type, c_ast.PtrDecl) and isinstance(node.type.type, c_ast.FuncDecl):
            raise Refuse(node, "function pointers are not supported")
        if isinstance(node.type, c_ast.ArrayDecl):
            raise Refuse(node, "array typedefs are not supported")
        self.typedefs[node.name] = self.from_type(t)

    # ---------------------------------------------------------- emission

    def translate(self, parts, label):
        """parts: [(ast, allowed_lines)] — one entry per translation unit.

        Line numbers are per translation unit, so each AST must be filtered with
        its own set; mixing them would let a header's lines collide with the
        driver's.
        """
        for ast, allowed in parts:
            self.allowed = allowed
            self.collect(ast)
        chunks = []
        for ast, allowed in parts:
            self.allowed = allowed
            chunks.extend(self.emit_ast(ast))
        return "// generated by tools/c2vala.py from %s\n\n%s\n" % (label, "\n".join(chunks))

    def emit_ast(self, ast):
        chunks = []
        for ext in ast.ext:
            if not self.keep(ext):
                continue
            if isinstance(ext, c_ast.Typedef):
                text = self.emit_typedef(ext)
                if text:
                    chunks.append(text)
            elif isinstance(ext, c_ast.FuncDef):
                chunks.append(self.emit_function(ext))
            elif isinstance(ext, c_ast.Decl):
                if isinstance(ext.type, c_ast.FuncDecl):
                    continue
                if isinstance(ext.type, c_ast.Enum):
                    text = self.emit_enum(ext.type.name) if ext.type.name else None
                    if text:
                        chunks.append(text)
                    continue
                if isinstance(ext.type, c_ast.Struct):
                    continue
                raise Refuse(ext, "global variables are not supported")
            else:
                raise Refuse(ext, "unsupported top-level %s" % type(ext).__name__)
        return chunks

    def emit_enum(self, name):
        members = self.enums.get(name)
        if not members:
            return None
        lines = ["public enum %s {" % name]
        for i, (member, value) in enumerate(members):
            tail = "," if i + 1 < len(members) else ""
            lines.append("    %s = %d%s" % (member, value, tail))
        lines.append("}")
        return "\n".join(lines)

    def emit_typedef(self, node):
        t = unwrap_type(node.type)
        if isinstance(t, c_ast.Enum):
            return self.emit_enum(node.name)
        if isinstance(t, c_ast.Struct):
            fields = self.classes[node.name]
            lines = ["public class %s {" % node.name]
            for fname in fields:
                lines.append("    public %s %s;" % (vala_of(fields[fname]), fname))
            if len(lines) == 1:
                lines.append("    // no fields")
            lines.append("}")
            return "\n".join(lines)
        return None

    def emit_function(self, node):
        name = node.decl.name
        ret, params = self.signatures[name]
        self.arrays = set(self.names_used_as_array(node))
        for idx, (pname, pct) in enumerate(params):
            if (name, idx) in self.array_params:
                self.arrays.add(pname)
        self.scope = dict(params)
        self.ret_type = ret
        self.flags = self.goto_flags(node)
        if name == "main":
            sig = "int main (string[] args)"
        else:
            parts = []
            for pname, pct in params:
                parts.append("%s %s" % (vala_of(pct, as_array=pname in self.arrays), pname))
            sig = "%s %s (%s)" % (vala_of(ret), name, ", ".join(parts))
        body = self.emit_block(node.body)
        head = ""
        if self.flags:
            head = "".join("    bool %s = false;\n" % f for f in self.flags)
        return "%s {\n%s%s}\n" % (sig, head, body)

    def names_used_as_array(self, fnode):
        found = set()

        class V(c_ast.NodeVisitor):
            def visit_ArrayRef(self, node):
                if isinstance(node.name, c_ast.ID):
                    found.add(node.name.name)
                self.generic_visit(node)

            def visit_UnaryOp(self, node):
                if node.op == "&" and isinstance(node.expr, c_ast.ArrayRef):
                    if isinstance(node.expr.name, c_ast.ID):
                        found.add(node.expr.name.name)
                self.generic_visit(node)

        V().visit(fnode)
        return found

    def goto_flags(self, fnode):
        labels = []
        gotos = []

        class V(c_ast.NodeVisitor):
            def visit_Goto(self, node):
                gotos.append(node)
                self.generic_visit(node)

        V().visit(fnode.body)
        if not gotos:
            return []
        seen = set()
        for stmt in (fnode.body.block_items or []):
            if isinstance(stmt, c_ast.Label):
                labels.append(stmt.name)
        for g in gotos:
            if g.name not in labels:
                raise Refuse(g, "goto: the label must be a top-level statement after the loop")
            seen.add("c2v_goto_" + g.name)
        return sorted(seen)

    # ---------------------------------------------------------- statements

    def ind(self, text):
        return "".join("    " + line if line.strip() else line
                       for line in text.splitlines(True))

    def emit_block(self, node):
        out = []
        for stmt in (node.block_items or []):
            out.append(self.emit_stmt(stmt))
        return "".join(out)

    def emit_stmt(self, node):
        if isinstance(node, c_ast.Compound):
            return "{\n%s}\n" % self.emit_block(node)
        if isinstance(node, c_ast.Decl):
            return self.emit_decl(node) + "\n"
        if isinstance(node, c_ast.Return):
            if node.expr is None:
                return "return;\n"
            text, _ = self.emit_expr(node.expr, self.ret_type)
            return "return %s;\n" % text
        if isinstance(node, c_ast.If):
            cond, _ = self.emit_expr(node.cond, ("scalar", "bool"))
            text = "if (%s) %s" % (cond, self.emit_stmt(node.iftrue))
            if node.iffalse is not None:
                text += " else %s" % self.emit_stmt(node.iffalse)
            return text
        if isinstance(node, c_ast.While):
            cond, _ = self.emit_expr(node.cond, ("scalar", "bool"))
            return "while (%s) %s" % (cond, self.loop_body(node.stmt))
        if isinstance(node, c_ast.DoWhile):
            body = self.emit_stmt(node.stmt)
            cond, _ = self.emit_expr(node.cond, ("scalar", "bool"))
            return "do %s while (%s);\n" % (body, cond)
        if isinstance(node, c_ast.For):
            return self.emit_for(node)
        if isinstance(node, c_ast.Switch):
            return self.emit_switch(node)
        if isinstance(node, c_ast.Break):
            return "break;\n"
        if isinstance(node, c_ast.Continue):
            return "continue;\n"
        if isinstance(node, c_ast.Label):
            return self.emit_stmt(node.stmt) if node.stmt is not None else ""
        if isinstance(node, c_ast.Goto):
            return "%s = true;\nbreak;\n" % ("c2v_goto_" + node.name)
        if isinstance(node, c_ast.Assignment):
            return "".join("%s = %s;\n" % pair for pair in self.flatten_assignment(node))
        if isinstance(node, (c_ast.FuncCall, c_ast.UnaryOp, c_ast.BinaryOp,
                             c_ast.TernaryOp, c_ast.Cast, c_ast.ID, c_ast.Constant,
                             c_ast.ArrayRef, c_ast.StructRef)):
            text, _ = self.emit_expr(node, None)
            return text + ";\n"
        if isinstance(node, c_ast.EmptyStatement):
            return ""
        raise Refuse(node, "unsupported statement %s" % type(node).__name__)

    def flatten_assignment(self, node):
        """`a = b = c` becomes [(b, c), (a, c)] (Vala has no chained assignment)."""
        if isinstance(node.rvalue, c_ast.Assignment) and node.rvalue.op == "=":
            pairs = self.flatten_assignment(node.rvalue)
            outer_lhs, _ = self.emit_expr(node.lvalue, None)
            return pairs + [(outer_lhs, pairs[-1][1])]
        lhs, lct = self.emit_expr(node.lvalue, None)
        rhs, _ = self.emit_expr(node.rvalue, lct)
        if node.op == "=":
            return [(lhs, rhs)]
        return [(lhs, "%s %s %s" % (lhs, node.op, rhs))]

    def loop_body(self, stmt):
        text = self.emit_stmt(stmt)
        if not self.flags:
            return text
        guard = "".join("if (%s) {\n    break;\n}\n" % f for f in self.flags)
        if text.startswith("{"):
            return text[:-2] + self.ind(guard) + "}\n"
        return "{\n%s%s}\n" % (self.ind(text), self.ind(guard))

    def emit_for(self, node):
        init = ""
        if isinstance(node.init, c_ast.DeclList):
            init = ", ".join(self.emit_decl(d, inline=True) for d in node.init.decls)
        elif isinstance(node.init, c_ast.Assignment):
            init = ", ".join("%s = %s" % pair for pair in self.flatten_assignment(node.init))
        elif node.init is not None:
            init, _ = self.emit_expr(node.init, None)
        cond = "true"
        if node.cond is not None:
            cond, _ = self.emit_expr(node.cond, ("scalar", "bool"))
        nxt = ""
        if isinstance(node.next, c_ast.Assignment):
            nxt = ", ".join("%s = %s" % pair for pair in self.flatten_assignment(node.next))
        elif node.next is not None:
            nxt, _ = self.emit_expr(node.next, None)
        return "for (%s; %s; %s) %s" % (init, cond, nxt, self.loop_body(node.stmt))

    def emit_switch(self, node):
        cond, cond_ct = self.emit_expr(node.cond, None)
        lines = ["switch (%s) {\n" % cond]
        pending = []
        entries = node.stmt.block_items or []
        for idx, entry in enumerate(entries):
            if isinstance(entry, c_ast.Case):
                if not entry.stmts:
                    pending.append(self.emit_expr(entry.expr, cond_ct)[0])
                    continue
                body = "".join(self.emit_stmt(s) for s in entry.stmts)
                self.check_fallthrough(entry.stmts, entries, idx)
                head = "".join("case %s:\n" % p for p in pending)
                head += "case %s:\n" % self.emit_expr(entry.expr, cond_ct)[0]
                pending = []
                lines.append(self.ind(head + self.ind(body)))
            elif isinstance(entry, c_ast.Default):
                if not entry.stmts:
                    pending.append("default")
                    continue
                body = "".join(self.emit_stmt(s) for s in entry.stmts)
                self.check_fallthrough(entry.stmts, entries, idx)
                head = "".join("case %s:\n" % p for p in pending if p != "default")
                if "default" in pending:
                    head += "default:\n"
                head += "default:\n"
                pending = []
                lines.append(self.ind(head + self.ind(body)))
            else:
                raise Refuse(entry, "statement directly inside a switch")
        lines.append("}\n")
        return "".join(lines)

    def check_fallthrough(self, stmts, entries, idx):
        if not stmts:
            return
        last = stmts[-1]
        if isinstance(last, (c_ast.Break, c_ast.Return, c_ast.Goto, c_ast.Continue)):
            return
        if idx + 1 < len(entries):
            raise Refuse(last, "switch fallthrough with statements is not supported")

    def emit_decl(self, node, inline=False):
        name = node.name
        ct = self.from_type(node.type)
        if is_ptr(ct) and name in self.arrays:
            ct = ("array", ct[1], None)
        target = vala_of(ct, as_array=name in self.arrays)
        init = node.init
        if isinstance(init, c_ast.InitList):
            raise Refuse(node, "initializer lists are not supported")
        if init is not None:
            value, _ = self.emit_expr(init, ct)
            text = "%s %s = %s" % (target, name, value)
        elif is_ptr(ct):
            text = "%s %s = %s" % (target, name, '""' if is_char_ptr(ct) else "null")
        elif is_class(ct):
            text = "%s %s = new %s ()" % (target, name, target)
        elif ct[0] == "array":
            elem = ct[1]
            size = ct[2] or 0
            if elem[0] == "class":
                text = ("%s %s = new %s[%d];\nfor (int i = 0; i < %d; i++) {\n    %s[i] = new %s ();\n}"
                        % (target, name, vala_of(elem), size, size, name, vala_of(elem)))
            else:
                text = "%s %s = new %s[%d]" % (target, name, vala_of(elem), size)
        elif ct[0] == "enum":
            text = "%s %s = (%s) 0" % (target, name, target)
        elif is_scalar(ct):
            kind = ct[1]
            zero = "false" if kind == "bool" else ("0.0" if kind in ("float", "double") else "0")
            text = "%s %s = %s" % (target, name, zero)
        else:
            raise Refuse(node, "unsupported local declaration")
        self.scope[name] = ct
        if inline or text.endswith("}"):
            return text
        return text + ";"

    # --------------------------------------------------------- expressions

    def cast(self, text, frm, to):
        if to is None or frm is None:
            return text
        if frm == to:
            return text
        if (is_ptr(to) or is_class(to)) and text in ("0", "null", "NULL"):
            return "null"
        if frm[0] == "scalar" and to[0] == "scalar":
            fk, tk = frm[1], to[1]
            if tk == "void" or fk == tk:
                return text
            if tk == "bool":
                return "((%s) != 0)" % text
            return "(%s) %s" % (VALA_SCALAR[tk], text)
        if to[0] == "enum" and frm[0] == "scalar":
            return "(%s) %s" % (to[1], text)
        if to[0] == "scalar" and frm[0] == "enum":
            return "(%s) %s" % (VALA_SCALAR[to[1]], text)
        return text

    def emit_expr(self, node, want=None):
        text, ct = self.emit_raw(node)
        return self.cast(text, ct, want), ct

    def emit_raw(self, node):
        if isinstance(node, c_ast.ID):
            name = node.name
            if name == "NULL":
                return "null", None
            if name in ("true", "false"):
                return name, ("scalar", "bool")
            if name in self.scope:
                ct = self.scope[name]
                if is_ptr(ct) and name in self.arrays:
                    return name, ("array", ct[1], None)
                return name, ct
            if name in self.enum_values:
                return "%s.%s" % (self.enum_owner(name), name), ("enum", self.enum_owner(name))
            raise Refuse(node, "unknown identifier '%s'" % name)
        if isinstance(node, c_ast.Constant):
            if node.type == "string":
                return node.value, ("ptr", ("scalar", "char"))
            if node.type == "char":
                return node.value, ("scalar", "char")
            if node.type in ("float", "double"):
                return node.value, ("scalar", "double")
            if node.type == "unsigned int":
                return node.value, ("scalar", "uint")
            return node.value, ("scalar", "int")
        if isinstance(node, c_ast.BinaryOp):
            ltext, lct = self.emit_raw(node.left)
            rtext, rct = self.emit_raw(node.right)
            common = promote(lct, rct)
            ltext = self.cast(ltext, lct, common)
            rtext = self.cast(rtext, rct, common)
            if node.op in ("==", "!=", "<", "<=", ">", ">=", "&&", "||"):
                return "(%s %s %s)" % (ltext, node.op, rtext), ("scalar", "bool")
            return "(%s %s %s)" % (ltext, node.op, rtext), common
        if isinstance(node, c_ast.UnaryOp):
            return self.emit_unary(node)
        if isinstance(node, c_ast.ArrayRef):
            base, bct = self.emit_raw(node.name)
            idx, _ = self.emit_expr(node.subscript, ("scalar", "int"))
            if bct is None:
                raise Refuse(node, "indexing an unknown expression")
            if is_char_ptr(bct):
                return "%s[%s]" % (base, idx), ("scalar", "char")
            if bct[0] == "array":
                return "%s[%s]" % (base, idx), bct[1]
            if is_ptr(bct):
                return "%s[%s]" % (base, idx), bct[1]
            raise Refuse(node, "indexing something that is not a pointer")
        if isinstance(node, c_ast.StructRef):
            base, bct = self.emit_raw(node.name)
            field = node.field.name
            owner = None
            if bct is not None:
                if bct[0] == "class":
                    owner = bct[1]
                elif is_ptr(bct) and bct[1][0] == "class":
                    owner = bct[1][1]
            if owner is None or field not in self.classes.get(owner, {}):
                raise Refuse(node, "unknown field '%s'" % field)
            ftype = self.classes[owner][field]
            if node.type == "->" and is_ptr(bct):
                # Vala has no `!` non-null assertion: an explicit cast is the
                # documented way to dereference a nullable reference.
                base = "((%s) %s)" % (vala_of(bct[1]), base)
            return "%s.%s" % (base, field), ftype
        if isinstance(node, c_ast.Cast):
            target = self.from_type(node.to_type.type)
            text, _ = self.emit_expr(node.expr, target)
            return text, target
        if isinstance(node, c_ast.FuncCall):
            return self.emit_call(node)
        if isinstance(node, c_ast.TernaryOp):
            cond, _ = self.emit_expr(node.cond, ("scalar", "bool"))
            a, act = self.emit_raw(node.iftrue)
            b, bct = self.emit_raw(node.iffalse)
            common = promote(act, bct)
            return ("(%s ? %s : %s)" % (cond, self.cast(a, act, common),
                                        self.cast(b, bct, common))), common
        if isinstance(node, c_ast.Assignment):
            raise Refuse(node, "chained assignment is only supported as a statement")
        raise Refuse(node, "unsupported expression %s" % type(node).__name__)

    def emit_unary(self, node):
        op = node.op
        if op == "sizeof":
            inner = None
            if hasattr(node.expr, "type"):
                inner = self.from_type(node.expr.type)
            elif isinstance(node.expr, c_ast.ID) and node.expr.name in self.scope:
                inner = self.scope[node.expr.name]
            if is_scalar(inner):
                return "(int) sizeof (%s)" % VALA_SCALAR[inner[1]], ("scalar", "int")
            raise Refuse(node, "sizeof of a non-scalar")
        if op == "&":
            if isinstance(node.expr, c_ast.ArrayRef) and isinstance(node.expr.name, c_ast.ID):
                base = node.expr.name.name
                idx, _ = self.emit_expr(node.expr.subscript, ("scalar", "int"))
                return "%s[%s]" % (base, idx), None
            if isinstance(node.expr, c_ast.ID):
                name = node.expr.name
                return name, self.scope.get(name)
            raise Refuse(node, "address-of a non-lvalue")
        if op == "*":
            text, ict = self.emit_raw(node.expr)
            if ict is not None and is_ptr(ict):
                return "((%s) %s)" % (vala_of(ict[1]), text), ict[1]
            return text, ict
        if op in ("p++", "p--"):
            text, ct = self.emit_raw(node.expr)
            return "%s%s" % (text, op[1:]), ct
        if op in ("++", "--"):
            text, ct = self.emit_raw(node.expr)
            return "%s%s" % (op, text), ct
        text, ct = self.emit_raw(node.expr)
        if op == "!":
            return "!(%s)" % text, ("scalar", "bool")
        return "%s%s" % (op, text), ct

    def enum_owner(self, member):
        for name, members in self.enums.items():
            for m, _v in members:
                if m == member:
                    return name
        raise Refuse(None, "unknown enum member '%s'" % member)

    @staticmethod
    def call_args(node):
        args = node.args
        if args is None:
            return []
        if isinstance(args, c_ast.ExprList):
            return args.exprs
        return list(args)

    def emit_call(self, node):
        if not isinstance(node.name, c_ast.ID):
            raise Refuse(node, "indirect calls are not supported")
        callee = node.name.name
        args = self.call_args(node)
        if callee == "printf":
            text = ", ".join(self.emit_expr(a, None)[0] for a in args)
            return "stdout.printf (%s)" % text, ("scalar", "int")
        if callee == "fprintf":
            if not args:
                raise Refuse(node, "fprintf needs a stream")
            stream = args[0].name if isinstance(args[0], c_ast.ID) else "stdout"
            text = ", ".join(self.emit_expr(a, None)[0] for a in args[1:])
            return "%s.printf (%s)" % (stream, text), ("scalar", "int")
        runtime = {
            "strlen": "c_strlen", "strcmp": "c_strcmp", "strncmp": "c_strncmp",
            "memcpy": "c_memcpy", "memset": "c_memset",
        }
        if callee in runtime:
            text = ", ".join(self.emit_expr(a, None)[0] for a in args)
            return "%s (%s)" % (runtime[callee], text), ("scalar", "int")
        if callee not in self.signatures:
            raise Refuse(node, "call to unknown function '%s'" % callee)
        ret, params = self.signatures[callee]
        if len(args) != len(params):
            raise Refuse(node, "arity mismatch calling '%s'" % callee)
        parts = []
        for arg, (_pname, pct) in zip(args, params):
            text, _ = self.emit_expr(arg, pct)
            parts.append(text)
        return "%s (%s)" % (callee, ", ".join(parts)), ret


def translate(paths, includes, defines, cc_bin, out_path):
    workdir = tempfile.mkdtemp(prefix="c2vala-")
    fake, stubs = cc.prepare_includes(workdir)
    parts = []
    parser = c_parser.CParser()
    for path in paths:
        text, lines, err, _stubbed = cc.preprocess(
            path, cc_bin, fake, stubs, includes, defines=defines,
            main_only=os.path.basename(path))
        if text is None:
            raise Refuse(None, "%s: %s" % (path, err))
        text, _subs = cc.sanitize(text)
        try:
            ast = parser.parse(text, filename=os.path.basename(path))
        except Exception as exc:
            raise Refuse(None, "%s: cannot parse: %s" % (path, str(exc).splitlines()[0]))
        parts.append((ast, lines))
    tr = Translator(None)
    source = tr.translate(parts, ", ".join(os.path.basename(p) for p in paths))
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(source)
    return source


def main(argv):
    ap = argparse.ArgumentParser(description="C -> Vala translator (restricted subset)")
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("-I", "--include", action="append", default=[])
    ap.add_argument("-D", "--define", action="append", default=[])
    ap.add_argument("--cc", default="gcc")
    args = ap.parse_args(argv)
    try:
        source = translate(args.inputs, args.include, args.define, args.cc, args.output)
    except Refuse as exc:
        sys.stderr.write("c2vala: refused: %s\n" % exc)
        return 2
    lines = source.count("\n")
    print("c2vala: wrote %s (%d lines)" % (args.output, lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
