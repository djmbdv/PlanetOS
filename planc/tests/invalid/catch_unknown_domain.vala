errordomain KnownError {
    ONE
}

void work() throws KnownError {
    throw new KnownError.ONE("err");
}

int main() {
    try {
        work();
    } catch (UnknownDomain e) {
        return 1;
    }
    return 0;
}
