errordomain BoomError {
    FAIL
}

int explode() throws BoomError {
    throw new BoomError.FAIL("boom");
}

int main() {
    return explode();
}
