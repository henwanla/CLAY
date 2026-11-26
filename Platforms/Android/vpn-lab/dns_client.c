// An unprivileged UDP client for the disposable guest's shell UID.
#include <arpa/inet.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

int main(void) {
    unsigned char packet[512];
    size_t query = fread(packet, 1, sizeof(packet), stdin);
    if (ferror(stdin) || query < 12 || query == sizeof(packet)) return 64;

    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 65;
    struct sockaddr_in server = { .sin_family = AF_INET, .sin_port = htons(53) };
    struct timeval timeout = { .tv_sec = 2 };
    if (inet_pton(AF_INET, "198.18.0.2", &server.sin_addr) != 1 ||
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
        connect(fd, (const struct sockaddr *)&server, sizeof(server)) ||
        send(fd, packet, query, 0) != (ssize_t)query) {
        close(fd);
        return 66;
    }
    ssize_t received = recv(fd, packet, sizeof(packet), 0);
    close(fd);
    if (received <= 0 || fwrite(packet, 1, (size_t)received, stdout) != (size_t)received) return 67;
    return fflush(stdout) ? 68 : 0;
}
