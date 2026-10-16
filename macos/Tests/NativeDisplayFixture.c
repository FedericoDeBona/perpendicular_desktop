/* SPDX-License-Identifier: Apache-2.0
 * Owned CPU-memory producer for Swift/Metal receiver failure/lifetime tests.
 * No VM, GPU producer or arbitrary commands. */
#include "ndt.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void check(int value, const char *reason) {
    if (!value) { fprintf(stderr, "receiver fixture: %s\n", reason); exit(1); }
}
static void marker(const char *directory, unsigned count) {
    char path[1024]; check(snprintf(path, sizeof(path), "%s/acks", directory) < (int)sizeof(path), "marker path");
    FILE *out = fopen(path, "w"); check(out != NULL, "marker open");
    fprintf(out, "%u\n", count); check(fclose(out) == 0, "marker close");
}
int main(int argc, char **argv) {
    check(argc == 3, "arguments: mode runtime");
    const char *mode = argv[1], *directory = argv[2];
    check(!strcmp(mode, "controlled") || !strcmp(mode, "withheld") || !strcmp(mode, "token-eof") || !strcmp(mode, "alignment"), "fixed fixture mode");
    signal(SIGPIPE, SIG_IGN); alarm(12); setvbuf(stdout, NULL, _IOLBF, 0);
    ndt_listener listener; check(ndt_listen(&listener, directory, "display.sock") == NDT_OK, "listen");
    marker(directory, 0); puts("LISTENING");
    ndt_connection connection; int result;
    do { result = ndt_server_accept(&listener, &connection, geteuid(), 11, 22, 1); if (result == NDT_AGAIN) usleep(1000); } while (result == NDT_AGAIN);
    check(result == NDT_OK, "accept");
    uint32_t pitch = !strcmp(mode, "alignment") ? 260 : 256;
    ndt_metadata metadata = { .id = {11, 22, 1, 1}, .width = 64, .height = 32, .pitch = pitch, .format = NDT_BGRA8, .size = (uint64_t)pitch * 32 };
    char name[1024]; check(snprintf(name, sizeof(name), "%s/frame-XXXXXX", directory) < (int)sizeof(name), "frame path");
    int memory = mkstemp(name); check(memory >= 0 && unlink(name) == 0, "private unique memory");
    size_t page = (size_t)getpagesize(), length = ((size_t)metadata.size + page - 1) & ~(page - 1);
    check(ftruncate(memory, (off_t)length) == 0, "extent");
    uint8_t *mapping = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, memory, 0); check(mapping != MAP_FAILED, "map");
    for (unsigned y = 0; y < 32; y++) for (unsigned x = 0; x < 64; x++) {
        uint32_t pixel = y < 16 ? 0xffff0000u : 0xff0000ffu;
        memcpy(mapping + y * pitch + x * 4, &pixel, 4);
    }
    check(munmap(mapping, length) == 0, "unmap");
    int ready[2]; check(pipe(ready) == 0, "ready pipe");
    if (!strcmp(mode, "token-eof")) { close(ready[1]); ready[1] = -1; }
    else if (strcmp(mode, "withheld")) check(write(ready[1], "r", 1) == 1, "ready signal");
    check(ndt_queue_frame(&connection, &metadata, memory, ready[0]) == NDT_OK, "queue frame");
    unsigned acknowledgements = 0;
    for (;;) {
        result = ndt_pump(&connection);
        if (result == NDT_CLOSED || result < 0) break;
        ndt_event event;
        while (ndt_next_event(&connection, &event) == NDT_OK) {
            if (event.kind == NDT_EVENT_ACK) { acknowledgements++; marker(directory, acknowledgements); puts("ACK"); }
        }
        struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
        if (poll(&input, 1, 0) > 0 && (input.revents & POLLIN)) {
            char byte; if (read(STDIN_FILENO, &byte, 1) != 1 || byte == 'E') break;
        }
        usleep(1000);
    }
    ndt_close(&connection); ndt_listener_close(&listener);
    close(memory); close(ready[0]); if (ready[1] >= 0) close(ready[1]);
    printf("DONE ACKS=%u\n", acknowledgements); return 0;
}
