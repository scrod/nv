/* Runs a cross-built Swift Testing bundle through SwiftPM's documented main entrypoint. */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 3 || strcmp(argv[1], "--test-bundle-path")) {
        fputs("Expected --test-bundle-path and an actual test bundle executable\n", stderr);
        return 2;
    }
    void *image = dlopen(argv[2], RTLD_LAZY | RTLD_FIRST);
    if (!image) { fprintf(stderr, "Test bundle load failed: %s\n", dlerror()); return 2; }
    void *symbol = dlsym(image, "main");
    if (!symbol) { fprintf(stderr, "Test entrypoint lookup failed: %s\n", dlerror()); return 2; }
    int (*entry)(int, char **);
    _Static_assert(sizeof(entry) == sizeof(symbol), "Darwin entrypoint pointer representation");
    memcpy(&entry, &symbol, sizeof(entry));
    return entry(argc, argv);
}
