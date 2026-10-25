// build-static-deps.sh's check of libusbmuxd-inetcat-writes.patch, run against the inetcat just built: everything
// inetcat reads from stdin reaches the device's port, in order, while the port takes it slowly. A stand-in usbmuxd on
// a Unix socket lists one USB device, accepts the connect and then reads the stream a page at a time, so inetcat's
// non-blocking socket fills and its writes come back short or with EAGAIN.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define STREAM_BYTES (1 << 20)

struct header { // usbmuxd's message header, in host byte order
    uint32_t length, version, message, tag;
};

static const char *devices =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>DeviceList</key><array><dict>"
    "<key>DeviceID</key><integer>1</integer><key>MessageType</key><string>Attached</string>"
    "<key>Properties</key><dict><key>ConnectionType</key><string>USB</string><key>DeviceID</key><integer>1</integer>"
    "<key>LocationID</key><integer>1</integer><key>ProductID</key><integer>4761</integer>"
    "<key>SerialNumber</key><string>0000000000000000000000000000000000000001</string></dict></dict></array></dict>"
    "</plist>";
static const char *connected = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist "
                               "version=\"1.0\"><dict><key>MessageType</key><string>Result</string>"
                               "<key>Number</key><integer>0</integer></dict></plist>";

static int read_all(int fd, void *buffer, size_t size) {
    for (size_t done = 0; done < size;) {
        ssize_t n = read(fd, (char *)buffer + done, size - done);
        if (n <= 0)
            return -1;
        done += (size_t)n;
    }
    return 0;
}

static int answer(int listener, const char *plist) // one client: read its request, reply with the plist and its tag
{
    int fd = accept(listener, NULL, NULL);
    struct header request;
    if (fd < 0 || read_all(fd, &request, sizeof(request)) != 0 || request.length < sizeof(request))
        return -1;
    char *body = malloc(request.length - sizeof(request) + 1);
    int read = read_all(fd, body, request.length - sizeof(request));
    free(body);
    struct header reply = {(uint32_t)(sizeof(reply) + strlen(plist)), 1, 8, request.tag};
    if (read != 0 || write(fd, &reply, sizeof(reply)) != sizeof(reply) ||
        write(fd, plist, strlen(plist)) != (ssize_t)strlen(plist))
        return -1;
    return fd;
}

static uint8_t expected(size_t offset) // a position-dependent pattern, so a dropped or repeated page shows
{
    return (uint8_t)((offset >> 12) * 31 + offset);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: inetcat-writes INETCAT\n");
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    alarm(120);
    char directory[] = "/tmp/inetcat-writes.XXXXXX";
    if (!mkdtemp(directory))
        return 2;
    char input[PATH_MAX], address[PATH_MAX];
    snprintf(input, sizeof(input), "%s/in", directory);
    snprintf(address, sizeof(address), "%s/usbmuxd", directory);
    int in = open(input, O_RDWR | O_CREAT | O_TRUNC, 0600);
    uint8_t *data = malloc(STREAM_BYTES);
    for (size_t i = 0; i < STREAM_BYTES; i++)
        data[i] = expected(i);
    if (in < 0 || write(in, data, STREAM_BYTES) != STREAM_BYTES || lseek(in, 0, SEEK_SET) != 0)
        return 2;
    free(data);

    struct sockaddr_un name = {.sun_family = AF_UNIX};
    strlcpy(name.sun_path, address, sizeof(name.sun_path));
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0 || bind(listener, (struct sockaddr *)&name, sizeof(name)) != 0 || listen(listener, 4) != 0)
        return 2;

    pid_t inetcat = fork();
    if (inetcat == 0) {
        char variable[PATH_MAX + 32];
        snprintf(variable, sizeof(variable), "USBMUXD_SOCKET_ADDRESS=UNIX:%s", address);
        putenv(variable);
        dup2(in, STDIN_FILENO);
        int null = open("/dev/null", O_WRONLY);
        dup2(null, STDOUT_FILENO);
        execl(argv[1], argv[1], "22", (char *)NULL);
        _exit(127);
    }
    close(in);
    int list = answer(listener, devices);
    int stream = list < 0 ? -1 : answer(listener, connected);
    size_t received = 0, wrong = SIZE_MAX;
    uint8_t page[4096];
    for (ssize_t n; stream >= 0 && (n = read(stream, page, sizeof(page))) > 0;) {
        for (ssize_t i = 0; i < n && wrong == SIZE_MAX; i++)
            if (received + (size_t)i >= STREAM_BYTES || page[i] != expected(received + (size_t)i))
                wrong = received + (size_t)i;
        received += (size_t)n;
        usleep(2000); // slower than inetcat reads its stdin
    }
    int status = 0;
    waitpid(inetcat, &status, 0);
    unlink(input);
    unlink(address);
    rmdir(directory);
    if (list < 0 || stream < 0) {
        fprintf(stderr, "inetcat did not list and connect through the stand-in usbmuxd (status %d)\n", status);
        return 1;
    }
    if (wrong != SIZE_MAX) {
        fprintf(stderr, "inetcat's stream is wrong from byte %zu: libusbmuxd-inetcat-writes.patch is not in effect\n",
                wrong);
        return 1;
    }
    if (received != STREAM_BYTES) {
        fprintf(stderr, "inetcat delivered %zu of %d bytes: libusbmuxd-inetcat-writes.patch is not in effect\n",
                received, STREAM_BYTES);
        return 1;
    }
    return 0;
}
