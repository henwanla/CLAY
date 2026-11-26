#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/prctl.h>
#include <unistd.h>
#include <signal.h>

enum { TUN_FD = 100, PROTECT_FD = 101 };

static int inherit_fd(int source, int target) {
    if (source == target) return fcntl(source, F_SETFD, 0);
    if (dup2(source, target) != target) return -1;
    close(source);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 6 || (strcmp(argv[5], "off") && strcmp(argv[5], "protect"))) return 64;
    const int protect = !strcmp(argv[5], "protect");
#ifdef CLAY_REQUIRE_PROTECTION
    if (!protect) return 64;
#endif
    char *end = NULL;
    errno = 0;
    long expected = strtol(argv[1], &end, 10);
    if (errno || *end || expected <= 1 || expected > INT_MAX || getppid() != expected ||
        prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) || getppid() != expected) return 65;
    pid_t owner = (pid_t) expected;
    umask(077);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    int path_length = snprintf(address.sun_path, sizeof(address.sun_path), "%s/t", argv[3]);
    if (path_length < 0 || (size_t)path_length >= sizeof(address.sun_path)) return 66;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, offsetof(struct sockaddr_un,sun_path)+path_length+1) || listen(fd, 1)) { perror("listen"); return 67; }
    int peer = accept4(fd, NULL, NULL, SOCK_CLOEXEC);
    close(fd);
    unlink(address.sun_path);
    struct ucred cred;
    socklen_t cred_len = sizeof(cred);
    if (peer < 0 || getsockopt(peer, SOL_SOCKET, SO_PEERCRED, &cred, &cred_len) || cred.pid != owner || cred.uid != getuid()) { perror("cred"); return 68; }
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } ancillary;
    char body;
    struct iovec v = { &body, 1 };
    struct msghdr msg = { .msg_iov = &v, .msg_iovlen = 1, .msg_control = ancillary.bytes, .msg_controllen = sizeof(ancillary.bytes) };
    if (recvmsg(peer, &msg, MSG_CMSG_CLOEXEC) != 1 || body != 42 || (msg.msg_flags & (MSG_CTRUNC|MSG_TRUNC))) { perror("recv"); return 69; }
    struct cmsghdr *h = CMSG_FIRSTHDR(&msg);
    if (!h || h->cmsg_len != CMSG_LEN(sizeof(int)) || h->cmsg_level != SOL_SOCKET ||
        h->cmsg_type != SCM_RIGHTS || CMSG_NXTHDR(&msg, h)) return 70;
    int tun;
    memcpy(&tun, CMSG_DATA(h), sizeof tun);
    if (peer == TUN_FD) {
        int moved = fcntl(peer, F_DUPFD_CLOEXEC, PROTECT_FD + 1);
        if (moved < 0) return 71;
        close(peer);
        peer = moved;
    }
    if (inherit_fd(tun, TUN_FD) < 0) return 71;
    if (protect) {
        if (inherit_fd(peer, PROTECT_FD) < 0 || setenv("CLAY_VPN_LAB_PROTECT", "1", 1)) return 71;
    } else {
        close(peer);
        if (unsetenv("CLAY_VPN_LAB_PROTECT")) return 71;
    }
    fprintf(stderr,"CLAY_PROBE_FD_RECEIVED\n");
    execl(argv[2], argv[2], "-d", argv[3], "-f", argv[4], NULL);
    perror("exec"); return 72;
}
