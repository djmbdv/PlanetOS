// Memory layout of array elements, in one place.
//
// Both code generators index arrays with this stride and every analysis that
// reasons about element width asks here, so a new width is added once instead of
// once per backend. `SLOT` is the 8-byte element; anything narrower is packed.

namespace Planc {

    public class ElemLayout : Object {
        public const int SLOT = 0;
        public const int U8 = 1;
        public const int I8 = 2;
        public const int U16 = 3;
        public const int I16 = 4;

        // Type names reach the backends either as the element name ("uint8") or
        // with the nullable marker ("uint8?"); both forms name the same layout.
        public static string base_name (string tname) {
            return tname.has_suffix ("?") ? tname.substring (0, tname.length - 1) : tname;
        }

#if PLANC
        [AlwaysInline]
#endif
        public static int kind (string tname) {
            var b = base_name (tname);
            if (b == "uint8" || b == "uchar" || b == "char") return U8;
            if (b == "int8") return I8;
            if (b == "uint16" || b == "ushort") return U16;
            if (b == "int16" || b == "short") return I16;
            return SLOT;
        }

#if PLANC
        [NoAlloc]
        [AlwaysInline]
#endif
        public static int stride (int kind) {
            if (kind == U8 || kind == I8) return 1;
            if (kind == U16 || kind == I16) return 2;
            return 8;
        }

#if PLANC
        [NoAlloc]
        [AlwaysInline]
#endif
        public static bool is_signed (int kind) {
            return kind == I8 || kind == I16;
        }

#if PLANC
        [AlwaysInline]
#endif
        public static bool is_packed (string tname) {
            return kind (tname) != SLOT;
        }

#if PLANC
        [AlwaysInline]
#endif
        public static int stride_of (string tname) {
            return stride (kind (tname));
        }
    }
}
