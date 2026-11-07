/* Test-only entry cache. Other ucode programs and inline fault probes stay native. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *native = getenv("JZM_TEST_NATIVE_UCODE");
    const char *source = getenv("JZM_TEST_MAIN_SOURCE");
    const char *bytecode = getenv("JZM_TEST_MAIN_BYTECODE");
    if (native == NULL || source == NULL || bytecode == NULL) {
        fputs("test ucode: missing per-run compiler environment\n", stderr);
        return 127;
    }
    /* Only replace the entry after the launcher's and worker's exact options.
     * Never rewrite user arguments, compilation commands or inline programs. */
    if (argc > 4 && strcmp(argv[1], "-S") == 0 && strcmp(argv[2], "-L") == 0) {
        int entry = strcmp(argv[4], "--") == 0 ? 5 : 4;
        if (entry < argc && (strcmp(argv[entry], source) == 0 ||
                             strcmp(argv[entry], "src/main.uc") == 0))
            argv[entry] = (char *)bytecode;
    }
    execv(native, argv);
    perror("test ucode: exec");
    return 127;
}
