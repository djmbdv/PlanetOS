[PointerType]
public struct Bytes {
    public uint8* data;
    public size_t length;
}
void main() { var b = Bytes(); b.length = 0; print("%zu\n", b.length); }
