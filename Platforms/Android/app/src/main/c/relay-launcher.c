#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
    // The expected parent also closes the race before PR_SET_PDEATHSIG.
    if (argc != 7) return 64;
    char *end = NULL;
    errno = 0;
    const long owner = strtol(argv[1], &end, 10);
    if (errno || *end || owner <= 1 || owner > INT_MAX || getppid() != owner ||
        prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) || getppid() != owner) return 69;
    umask(077);
    execv(argv[2], argv + 2);
    return 69;
}
