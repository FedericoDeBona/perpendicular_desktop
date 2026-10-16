/* SPDX-License-Identifier: MIT
 * CPU-only, two-owned-process SCM_RIGHTS fixture; no VM, window or GPU. */
#include "ndt.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

/* Test-only syscall shim. ndt.c is built with recvmsg renamed in run.sh;
 * every ordinary case still performs the real recvmsg/SCM_RIGHTS exchange. */
static int force_ctrunc;
ssize_t ndt_fixture_recvmsg(int fd, struct msghdr *message, int flags)
{
    ssize_t n = recvmsg(fd, message, flags);
    if (force_ctrunc && n > 0 && CMSG_FIRSTHDR(message)) message->msg_flags |= MSG_CTRUNC;
    return n;
}
ssize_t ndt_fixture_sendmsg(int fd, const struct msghdr *message, int flags)
{
    struct msghdr copy = *message; struct iovec iov = message->msg_iov[0];
    if (iov.iov_len > 1) iov.iov_len = 1;
    copy.msg_iov = &iov; copy.msg_iovlen = 1;
    return sendmsg(fd, &copy, flags);
}

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL pid=%d line=%d: %s errno=%d\n", getpid(), __LINE__, #x, errno); exit(1); } } while (0)
static int descriptors(void) { int n = 0; for (int i = 0; i < 4096; i++) if (fcntl(i, F_GETFD) >= 0) n++; return n; }
static void tick(void) { (void)poll(NULL, 0, 1); }
static void byte(int fd, char b) { CHECK(write(fd, &b, 1) == 1); }
static char read_byte(int fd)
{
    struct pollfd p = { .fd = fd, .events = POLLIN }; CHECK(poll(&p, 1, 3000) > 0);
    char b; CHECK(read(fd, &b, 1) == 1); return b;
}
static ndt_metadata meta(uint64_t frame)
{
    ndt_metadata m = { .id = { 11, 22, 1, frame }, .width = frame == 2 ? 80 : 64,
        .height = frame == 2 ? 40 : 32, .pitch = frame == 2 ? 512 : 256, .format = NDT_BGRA8 };
    m.size = (uint64_t)m.pitch * m.height; return m;
}
typedef struct { int mem, read, write; } capture;
static capture allocate(ndt_metadata m)
{
    char name[] = "/tmp/perp-ndt-memory-XXXXXX"; int fd = mkstemp(name); CHECK(fd >= 0); CHECK(unlink(name) == 0);
    uint64_t page = (uint64_t)getpagesize(), extent = (m.size + page - 1) / page * page;
    CHECK(ftruncate(fd, (off_t)extent) == 0);
    void *map = mmap(NULL, (size_t)extent, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); CHECK(map != MAP_FAILED);
    memset(map, (int)m.id.frame, (size_t)extent); CHECK(munmap(map, (size_t)extent) == 0);
    int pipefd[2]; CHECK(pipe(pipefd) == 0); return (capture){ fd, pipefd[0], pipefd[1] };
}
static void release(capture *c) { CHECK(close(c->mem) == 0); CHECK(close(c->read) == 0); CHECK(close(c->write) == 0); c->mem = c->read = c->write = -1; }
static void accept_client(ndt_listener *l, ndt_connection *c)
{
    for (int i = 0; i < 3000; i++) {
        int r = ndt_server_accept(l, c, geteuid(), 11, 22, 1);
        if (r == NDT_OK) return; CHECK(r == NDT_AGAIN); tick();
    }
    CHECK(0);
}
static void sent(ndt_connection *c)
{
    for (int i = 0; i < 3000 && c->tx_kind; i++) { CHECK(ndt_pump(c) >= 0); tick(); }
    CHECK(!c->tx_kind);
}
static ndt_frame take(ndt_connection *c)
{
    ndt_frame frame;
    for (int i = 0; i < 3000; i++) {
        if (ndt_take_frame(c, &frame) == NDT_OK) return frame;
        CHECK(ndt_pump(c) >= 0); tick();
    }
    CHECK(0); return (ndt_frame){0};
}
static void pixels(ndt_frame *f)
{
    CHECK(fcntl(f->memory_fd, F_GETFD) & FD_CLOEXEC); CHECK(fcntl(f->ready_fd, F_GETFD) & FD_CLOEXEC);
    CHECK(f->memory_extent % (uint64_t)getpagesize() == 0 && f->memory_extent >= f->metadata.size);
    uint8_t *map = mmap(NULL, (size_t)f->memory_extent, PROT_READ, MAP_SHARED, f->memory_fd, 0); CHECK(map != MAP_FAILED);
    CHECK(map[0] == f->metadata.id.frame && map[f->metadata.size - 1] == f->metadata.id.frame);
    CHECK(munmap(map, (size_t)f->memory_extent) == 0);
}
static void put(uint8_t *p, uint64_t x, int bytes) { for (int i = 0; i < bytes; i++) p[i] = (uint8_t)(x >> (8 * i)); }
static void wire(uint8_t *p, int kind, ndt_metadata m)
{
    memset(p, 0, 128); memcpy(p, "PERPFD01", 8); put(p + 8, kind, 2); put(p + 10, 1, 2); put(p + 12, 128, 4);
    put(p + 16, m.id.session_hi, 8); put(p + 24, m.id.session_lo, 8); put(p + 32, m.id.epoch, 8); put(p + 40, m.id.frame, 8);
    if (kind == 1) { put(p + 48, m.width, 4); put(p + 52, m.height, 4); put(p + 56, m.pitch, 4); put(p + 60, m.format, 4); put(p + 64, m.offset, 8); put(p + 72, m.size, 8); }
}
static void raw(int fd, const uint8_t *data, size_t bytes, int count, capture c)
{
    union { struct cmsghdr align; char bytes[CMSG_SPACE(254 * sizeof(int))]; } control;
    struct iovec iov = { (void *)data, bytes }; struct msghdr msg; memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov; msg.msg_iovlen = 1;
    if (count) {
        memset(&control, 0, sizeof(control)); msg.msg_control = control.bytes; msg.msg_controllen = CMSG_SPACE((size_t)count * sizeof(int));
        struct cmsghdr *h = CMSG_FIRSTHDR(&msg); h->cmsg_level = SOL_SOCKET; h->cmsg_type = SCM_RIGHTS; h->cmsg_len = CMSG_LEN((size_t)count * sizeof(int));
        for (int i = 0; i < count; i++) { int value = i % 2 ? c.read : c.mem; memcpy((char *)CMSG_DATA(h) + i * sizeof(int), &value, sizeof(value)); }
    }
    CHECK(sendmsg(fd, &msg, 0) == (ssize_t)bytes);
}
static void server(const char *mode, const char *runtime, int out, int in)
{
    int baseline = descriptors(); ndt_listener l; CHECK(ndt_listen(&l, runtime, "display.sock") == NDT_OK); byte(out, 'L');
    ndt_connection c;
    if (!strcmp(mode, "peer")) {
        int r = NDT_AGAIN;
        for (int i = 0; i < 3000 && r == NDT_AGAIN; i++) { r = ndt_server_accept(&l, &c, geteuid(), 11, 22, 1); tick(); }
        /* Rejected client can close before server credential lookup finishes. */
        CHECK(r == NDT_OK || r == NDT_ERR_PEER || r == NDT_ERR_SYSTEM);
        ndt_close(&c); ndt_listener_close(&l); CHECK(descriptors() == baseline); return;
    }
    accept_client(&l, &c);
    ndt_metadata m = meta(1); capture a = allocate(m);
    if (!strcmp(mode, "normal") || !strcmp(mode, "badack") || !strcmp(mode, "ackfds")) {
        CHECK(ndt_queue_frame(&c, &m, a.mem, a.read) == NDT_OK); sent(&c);
        ndt_metadata second = meta(2); capture b = allocate(second);
        CHECK(ndt_queue_frame(&c, &second, b.mem, b.read) == NDT_OK); sent(&c);
        ndt_metadata third = meta(3); CHECK(ndt_queue_frame(&c, &third, a.mem, a.read) == NDT_AGAIN);
        byte(out, 'F');
        if (strcmp(mode, "normal")) {
            int r = NDT_AGAIN;
            for (int i = 0; i < 3000 && r >= 0; i++) { r = ndt_pump(&c); tick(); }
            CHECK(r == (!strcmp(mode, "badack") ? NDT_ERR_IDENTITY : NDT_ERR_PROTOCOL));
            ndt_event e; CHECK(ndt_next_event(&c, &e) == NDT_OK && e.kind == NDT_EVENT_CANCEL);
            CHECK(ndt_next_event(&c, &e) == NDT_OK && e.kind == NDT_EVENT_CANCEL);
            release(&a); release(&b);
        } else {
            CHECK(read_byte(in) == 'R'); byte(a.write, 'r'); byte(b.write, 'r'); byte(out, 'R');
            int acknowledged = 0; capture third_capture = { -1, -1, -1 };
            for (int i = 0; i < 3000 && acknowledged < 3; i++) {
                CHECK(ndt_pump(&c) >= 0); ndt_event e;
                while (ndt_next_event(&c, &e) == NDT_OK) {
                    CHECK(e.kind == NDT_EVENT_ACK); acknowledged++;
                    if (e.id.frame == 1) {
                        CHECK(fcntl(a.mem, F_GETFD) >= 0); release(&a); third_capture = allocate(third); byte(third_capture.write, 'r');
                        CHECK(ndt_queue_frame(&c, &third, third_capture.mem, third_capture.read) == NDT_OK);
                    } else if (e.id.frame == 2) release(&b);
                    else { CHECK(e.id.frame == 3); release(&third_capture); }
                }
                tick();
            }
            CHECK(acknowledged == 3);
        }
    } else {
        uint8_t p[128]; wire(p, 1, m); int count = 2; size_t length = 128;
        if (!strcmp(mode, "magic")) p[0] ^= 1;
        if (!strcmp(mode, "version")) p[10] = 2;
        if (!strcmp(mode, "recordsize")) p[12] = 127;
        if (!strcmp(mode, "reserved")) p[127] = 1;
        if (!strcmp(mode, "width")) put(p + 48, 4097, 4);
        if (!strcmp(mode, "pitch")) put(p + 56, 4, 4);
        if (!strcmp(mode, "format")) put(p + 60, 88, 4);
        if (!strcmp(mode, "offset")) put(p + 64, 16384, 8);
        if (!strcmp(mode, "size")) put(p + 72, UINT64_MAX, 8);
        if (!strcmp(mode, "session")) put(p + 16, 99, 8);
        if (!strcmp(mode, "epoch")) put(p + 32, 2, 8);
        if (!strcmp(mode, "nofds")) count = 0;
        if (!strcmp(mode, "onefd")) count = 1;
        if (!strcmp(mode, "extrafd")) count = 3;
        if (!strcmp(mode, "ancillary20")) count = 20;
        if (!strcmp(mode, "ancillary254")) count = 254;
        if (!strcmp(mode, "memorypipe")) { CHECK(close(a.mem) == 0); a.mem = dup(a.read); CHECK(a.mem >= 0); }
        if (!strcmp(mode, "readyfile")) { CHECK(close(a.read) == 0); a.read = dup(a.mem); CHECK(a.read >= 0); }
        if (!strcmp(mode, "readywrite")) { CHECK(close(a.read) == 0); a.read = dup(a.write); CHECK(a.read >= 0); }
        if (!strcmp(mode, "truncated")) length = 17;
        if (!strcmp(mode, "latefds")) {
            raw(c.fd, p, 1, 0, a); byte(out, 'P'); CHECK(read_byte(in) == 'C'); raw(c.fd, p + 1, 127, 2, a);
        } else if (!strcmp(mode, "partial")) {
            byte(a.write, 'r');
            raw(c.fd, p, 1, 2, a); byte(out, 'P'); CHECK(read_byte(in) == 'C');
            for (size_t i = 1; i < 128; i++) raw(c.fd, p + i, 1, 0, a);
            byte(out, 'F'); CHECK(read_byte(in) == 'D');
        } else if (!strcmp(mode, "hangup")) {
            byte(a.write, 'r'); CHECK(close(a.write) == 0); a.write = -1;
            raw(c.fd, p, 128, 2, a); byte(out, 'F'); CHECK(read_byte(in) == 'D');
        } else if (!strcmp(mode, "eof-held")) {
            byte(a.write, 'r');
            raw(c.fd, p, 128, 2, a); byte(out, 'F'); CHECK(read_byte(in) == 'D');
        } else raw(c.fd, p, length, count, a);
        CHECK(close(a.mem) == 0); CHECK(close(a.read) == 0); if (a.write >= 0) CHECK(close(a.write) == 0);
    }
    ndt_close(&c); ndt_close(&c); ndt_listener_close(&l); CHECK(descriptors() == baseline);
}
static void run(const char *mode)
{
    char runtime[] = "/tmp/perp-ndt-XXXXXX"; CHECK(mkdtemp(runtime)); CHECK(chmod(runtime, 0700) == 0);
    int to_child[2], from_child[2]; CHECK(pipe(to_child) == 0 && pipe(from_child) == 0);
    pid_t child = fork(); CHECK(child >= 0);
    if (!child) { close(to_child[1]); close(from_child[0]); server(mode, runtime, from_child[1], to_child[0]); _exit(0); }
    close(to_child[0]); close(from_child[1]); CHECK(read_byte(from_child[0]) == 'L');
    force_ctrunc = !strcmp(mode, "forcedctrunc");
    int baseline = descriptors(); char path[104]; CHECK(snprintf(path, sizeof(path), "%s/display.sock", runtime) < (int)sizeof(path));
    ndt_connection c; int r = ndt_client_start(&c, path, geteuid(), !strcmp(mode, "peer") ? getpid() : child, 11, 22, 1);
    if (!strcmp(mode, "peer")) {
        for (int i = 0; i < 3000 && r >= 0; i++) { r = ndt_pump(&c); tick(); } CHECK(r == NDT_ERR_PEER);
    } else if (!strcmp(mode, "normal") || !strcmp(mode, "badack") || !strcmp(mode, "ackfds")) {
        CHECK(r >= 0); CHECK(read_byte(from_child[0]) == 'F');
        ndt_frame a = take(&c), b = take(&c); CHECK(a.metadata.id.frame == 1 && b.metadata.id.frame == 2);
        CHECK(a.metadata.width != b.metadata.width);
        CHECK(ndt_ready(a.ready_fd) == NDT_AGAIN && ndt_ready(b.ready_fd) == NDT_AGAIN);
        if (!strcmp(mode, "normal")) {
            ndt_identity wrong = a.metadata.id; wrong.frame = 999; CHECK(ndt_queue_ack(&c, &wrong) == NDT_ERR_IDENTITY);
            byte(to_child[1], 'R'); CHECK(read_byte(from_child[0]) == 'R');
            CHECK(ndt_ready(a.ready_fd) == NDT_OK && ndt_ready(a.ready_fd) == NDT_OK && ndt_ready(b.ready_fd) == NDT_OK);
            pixels(&a); pixels(&b);
            ndt_frame_close(&a); ndt_frame_close(&a); CHECK(ndt_queue_ack(&c, &a.metadata.id) == NDT_OK); sent(&c);
            ndt_frame d = take(&c); CHECK(d.metadata.id.frame == 3); CHECK(ndt_ready(d.ready_fd) == NDT_OK); pixels(&d);
            ndt_frame_close(&b); CHECK(ndt_queue_ack(&c, &b.metadata.id) == NDT_OK); sent(&c);
            ndt_frame_close(&d); CHECK(ndt_queue_ack(&c, &d.metadata.id) == NDT_OK); sent(&c);
        } else {
            uint8_t p[128]; ndt_metadata bad = meta(99); wire(p, 2, bad);
            capture extra = allocate(meta(1)); raw(c.fd, p, 128, !strcmp(mode, "ackfds") ? 2 : 0, extra); release(&extra);
            ndt_frame_close(&a); ndt_frame_close(&b);
        }
    } else if (!strcmp(mode, "partial") || !strcmp(mode, "hangup") || !strcmp(mode, "eof-held")) {
        if (!strcmp(mode, "partial")) {
            CHECK(read_byte(from_child[0]) == 'P');
            for (int i = 0; i < 3000 && c.rx_used != 1; i++) { CHECK(ndt_pump(&c) >= 0); tick(); }
            CHECK(c.rx_used == 1); ndt_frame none; CHECK(ndt_take_frame(&c, &none) == NDT_AGAIN); byte(to_child[1], 'C');
        }
        CHECK(read_byte(from_child[0]) == 'F'); ndt_frame f = take(&c);
        if (!strcmp(mode, "hangup")) CHECK(ndt_ready(f.ready_fd) == NDT_ERR_TOKEN);
        else { CHECK(ndt_ready(f.ready_fd) == NDT_OK); pixels(&f); }
        byte(to_child[1], 'D');
        for (int i = 0; i < 3000 && c.fd >= 0; i++) { CHECK(ndt_pump(&c) >= 0); tick(); }
        CHECK(c.fd < 0); ndt_event e; CHECK(ndt_next_event(&c, &e) == NDT_OK && e.kind == NDT_EVENT_CANCEL && e.id.frame == 1);
        /* Ownership survives disconnect, but a HUP token never licenses reads. */
        CHECK(fcntl(f.memory_fd, F_GETFD) >= 0); ndt_frame_close(&f); ndt_frame_close(&f);
    } else {
        if (!strcmp(mode, "latefds")) {
            CHECK(read_byte(from_child[0]) == 'P');
            for (int i = 0; i < 3000 && c.rx_used != 1; i++) { CHECK(ndt_pump(&c) >= 0); tick(); }
            CHECK(c.rx_used == 1); byte(to_child[1], 'C');
        }
        for (int i = 0; i < 3000 && r >= 0; i++) { r = ndt_pump(&c); tick(); }
        CHECK(r < 0); CHECK(c.fd < 0);
    }
    ndt_close(&c); ndt_close(&c);
    if (descriptors() != baseline) fprintf(stderr, "descriptor imbalance mode=%s before=%d after=%d\n", mode, baseline, descriptors());
    CHECK(descriptors() == baseline);
    int status = 0; CHECK(waitpid(child, &status, 0) == child); CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(to_child[1]); close(from_child[0]); CHECK(rmdir(runtime) == 0); printf("PASS %s\n", mode);
}
static void external_producer(const char *runtime)
{
    ndt_listener listener; CHECK(ndt_listen(&listener, runtime, "display.sock") == NDT_OK);
    puts("LISTENING session_hi=11 session_lo=22 epoch=1 socket=display.sock");
    ndt_connection c; accept_client(&listener, &c); capture captures[2];
    for (int i = 0; i < 2; i++) {
        ndt_metadata m = meta((uint64_t)i + 1); captures[i] = allocate(m);
        uint32_t *p = mmap(NULL, (size_t)m.size, PROT_READ | PROT_WRITE, MAP_SHARED, captures[i].mem, 0); CHECK(p != MAP_FAILED);
        for (uint32_t y = 0; y < m.height; y++) for (uint32_t x = 0; x < m.width; x++)
            p[(size_t)y * (m.pitch / 4) + x] = y < m.height / 2 ? 0xffff0000u : 0xff0000ffu;
        CHECK(munmap(p, (size_t)m.size) == 0); byte(captures[i].write, 'r');
        CHECK(ndt_queue_frame(&c, &m, captures[i].mem, captures[i].read) == NDT_OK); sent(&c);
    }
    int retired = 0;
    for (int i = 0; i < 10000 && retired < 2; i++) {
        CHECK(ndt_pump(&c) >= 0); ndt_event e;
        while (ndt_next_event(&c, &e) == NDT_OK) {
            CHECK(e.kind == NDT_EVENT_ACK && e.id.frame >= 1 && e.id.frame <= 2);
            release(&captures[e.id.frame - 1]); retired++;
        }
        tick();
    }
    CHECK(retired == 2); ndt_close(&c); ndt_listener_close(&listener); puts("ACKED 2");
}
static void local_guards(void)
{
    int baseline = descriptors(); char runtime[] = "/tmp/perp-ndt-guard-XXXXXX";
    CHECK(mkdtemp(runtime)); CHECK(chmod(runtime, 0755) == 0);
    ndt_listener a, b; CHECK(ndt_listen(&a, runtime, "display.sock") == NDT_ERR_PEER);
    CHECK(chmod(runtime, 0700) == 0); CHECK(ndt_listen(&a, runtime, "display.sock") == NDT_OK);
    struct stat before, after; CHECK(lstat(a.path, &before) == 0 && (before.st_mode & 0777) == 0600);
    CHECK(ndt_listen(&b, runtime, "display.sock") == NDT_ERR_ARGUMENT);
    CHECK(lstat(a.path, &after) == 0 && before.st_ino == after.st_ino);
    ndt_listener_close(&b); ndt_listener_close(&a); ndt_listener_close(&a);
    CHECK(ndt_listen(&a, runtime, "../escape") == NDT_ERR_ARGUMENT);
    char name[31]; CHECK(snprintf(name, sizeof(name), "/pn-ndt-%d", getpid()) < (int)sizeof(name));
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600); CHECK(fd >= 0); CHECK(shm_unlink(name) == 0);
    CHECK(ftruncate(fd, getpagesize()) == 0); uint64_t extent = 0;
    CHECK(ndt_memory_extent(fd, &extent) == NDT_OK && extent == (uint64_t)getpagesize());
    CHECK(close(fd) == 0);
    capture short_memory = allocate(meta(1)); CHECK(ftruncate(short_memory.mem, 1) == 0);
    CHECK(ndt_memory_extent(short_memory.mem, &extent) == NDT_ERR_BOUNDS); release(&short_memory);
    CHECK(rmdir(runtime) == 0); CHECK(descriptors() == baseline);
    puts("PASS private socket and actual POSIX-shm extent guards");
}
int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(25); signal(SIGPIPE, SIG_IGN);
    if (argc == 3 && !strcmp(argv[1], "--serve")) { external_producer(argv[2]); return 0; }
    if (argc == 3 && !strcmp(argv[1], "--case")) { run(argv[2]); return 0; }
    CHECK(argc == 1);
    local_guards();
    const char *cases[] = { "normal", "partial", "peer", "magic", "version", "recordsize", "reserved", "width", "pitch", "format", "offset", "size", "session", "epoch", "nofds", "onefd", "extrafd", "ancillary20", "ancillary254", "memorypipe", "readyfile", "readywrite", "truncated", "latefds", "hangup", "eof-held", "badack", "ackfds" };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) run(cases[i]);
    puts("PASS actual two-process Unix FD transport; synthetic CPU pixels, no GPU/VM claim"); return 0;
}
