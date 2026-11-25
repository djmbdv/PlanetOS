int main() {
    int[] nums = { 3, 7, 11 };
    if (7 in nums)
        print("int yes\n");
    if (!(5 in nums))
        print("int no\n");

    string[] names = { "doom", "freedoom" };
    string s = "freedoom";
    if (s in names)
        print("str yes\n");
    if ("doom" in names)
        print("lit yes\n");

    string hay = "planetos doom port";
    if ("doom" in hay)
        print("sub yes\n");
    if (!("quake" in hay))
        print("sub no\n");

    double[] ds = { 1.5, 2.5 };
    if (2.5 in ds)
        print("fp yes\n");

    uint8[] bytes = new uint8[] { 1, 2, 255 };
    if (255 in bytes)
        print("u8 yes\n");

    int n = 11;
    if (n in nums)
        print("var yes\n");

    string empty = "";
    if (!("x" in empty))
        print("empty no\n");

    return 0;
}
