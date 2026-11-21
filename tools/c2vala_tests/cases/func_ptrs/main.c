#include <stdio.h>
#include <stdlib.h>

typedef int (*OpFn)(int a, int b);

struct VfsOps {
    OpFn add;
    int (*mul)(int x, int y);
    int (*read_byte)(const char *buf, int idx);
};

int add_impl(int a, int b) {
    return a + b;
}

int mul_impl(int x, int y) {
    return x * y;
}

int read_byte_impl(const char *buf, int idx) {
    return (int) buf[idx];
}

int apply_op(OpFn fn, int a, int b) {
    if (fn == NULL)
        return -1;
    return fn(a, b);
}

int main(void) {
    OpFn cb = NULL;
    printf("null=%d\n", apply_op(cb, 3, 4));
    cb = add_impl;
    printf("add=%d\n", apply_op(cb, 3, 4));
    cb = &mul_impl;
    printf("mul=%d\n", cb(5, 6));

    struct VfsOps *ops = (struct VfsOps *) 0;
    struct VfsOps inst;
    inst.add = add_impl;
    inst.mul = mul_impl;
    inst.read_byte = read_byte_impl;
    ops = &inst;

    if (ops != NULL && ops->mul != NULL) {
        printf("ops=%d,%d,%d\n",
               ops->add(10, 20),
               ops->mul(7, 8),
               ops->read_byte("XYZ", 1));
    }
    return 0;
}
