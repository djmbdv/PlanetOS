[SimpleType]
public struct Meters : int { }
[IntegerType]
public struct Id : uint { }
void main() { Meters m = 5; Id i = 3; print("%d %u\n", (int)m, (uint)i); }
