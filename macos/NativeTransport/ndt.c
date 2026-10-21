/* SPDX-License-Identifier: MIT */
#include "ndt.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef __APPLE__
#error "This peer-identity implementation requires macOS getpeereid/LOCAL_PEERPID"
#endif

enum { PRODUCER = 1, CONSUMER = 2, CONNECTING = 1, CONNECTED = 2, CLOSED = 3 };
enum { EMPTY, AVAILABLE, TAKEN, ACK_TX, QUEUED, SENT, ACKED, CANCELLED };
enum { FRAME = 1, ACK = 2 };
static const uint8_t magic[8] = { 'P','E','R','P','F','D','0','1' };

static void close_fd(int *fd) { if (*fd >= 0) { (void)close(*fd); *fd = -1; } }
static int flags(int fd, int nonblock)
{
    int value = fcntl(fd, F_GETFD);
    if (value < 0 || fcntl(fd, F_SETFD, value | FD_CLOEXEC) < 0) return -1;
    if (nonblock) {
        value = fcntl(fd, F_GETFL);
        if (value < 0 || fcntl(fd, F_SETFL, value | O_NONBLOCK) < 0) return -1;
    }
    return 0;
}
static int socket_flags(int fd)
{
    int yes = 1;
    return flags(fd, 1) || setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) ? -1 : 0;
}
static int same(ndt_identity a, ndt_identity b)
{
    return a.session_hi == b.session_hi && a.session_lo == b.session_lo &&
           a.epoch == b.epoch && a.frame == b.frame;
}
static int expected(const ndt_connection *c, ndt_identity id)
{
    return id.session_hi == c->session_hi && id.session_lo == c->session_lo &&
           id.epoch == c->epoch && id.frame != 0;
}
static void initialize(ndt_connection *c, int role, uid_t uid, pid_t pid,
                       uint64_t hi, uint64_t lo, uint64_t epoch)
{
    memset(c, 0, sizeof(*c)); c->fd = -1; c->role = role;
    c->expected_uid = uid; c->expected_pid = pid;
    c->session_hi = hi; c->session_lo = lo; c->epoch = epoch; c->tx_slot = -1;
    for (int i = 0; i < 2; i++) {
        c->rx_fds[i] = c->tx_fds[i] = -1;
        c->slots[i].memory_fd = c->slots[i].ready_fd = -1;
    }
}
void ndt_close(ndt_connection *c)
{
    if (!c) return;
    close_fd(&c->fd);
    for (int i = 0; i < 2; i++) {
        close_fd(&c->rx_fds[i]); close_fd(&c->tx_fds[i]);
        close_fd(&c->slots[i].memory_fd); close_fd(&c->slots[i].ready_fd);
        if (c->slots[i].state != EMPTY && c->slots[i].state != ACKED)
            c->slots[i].state = CANCELLED;
    }
    c->state = CLOSED; c->tx_kind = 0; c->rx_fd_count = c->tx_fd_count = 0;
    c->rx_used = c->tx_used = 0;
}
static int fail(ndt_connection *c, int error, int system_error)
{
    c->error = error; c->system_error = system_error; ndt_close(c); return error;
}
static int peer(ndt_connection *c)
{
    uid_t uid; gid_t gid; pid_t pid = 0; socklen_t bytes = sizeof(pid);
    if (getpeereid(c->fd, &uid, &gid) < 0 ||
        getsockopt(c->fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &bytes) < 0)
        return fail(c, NDT_ERR_PEER, errno);
    if (uid != c->expected_uid || bytes != sizeof(pid) || pid <= 0 ||
        (c->role == CONSUMER && pid != c->expected_pid))
        return fail(c, NDT_ERR_PEER, 0);
    c->state = CONNECTED; return NDT_OK;
}

int ndt_listen(ndt_listener *l, const char *runtime, const char *name)
{
    if (!l) return NDT_ERR_ARGUMENT;
    memset(l, 0, sizeof(*l)); l->fd = -1;
    if (!runtime || !name || runtime[0] != '/' || !*name || strchr(name, '/') ||
        !strcmp(name, ".") || !strcmp(name, "..")) return NDT_ERR_ARGUMENT;
    size_t a = strlen(runtime), b = strlen(name);
    if (!a || runtime[a - 1] == '/' || a + b + 2 > sizeof(l->path)) return NDT_ERR_BOUNDS;
    struct stat st;
    if (lstat(runtime, &st) < 0) return NDT_ERR_SYSTEM;
    if (!S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 0777) != 0700)
        return NDT_ERR_PEER;
    memcpy(l->path, runtime, a); l->path[a] = '/'; memcpy(l->path + a + 1, name, b + 1);
    if (lstat(l->path, &st) == 0) return NDT_ERR_ARGUMENT;
    if (errno != ENOENT) return NDT_ERR_SYSTEM;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NDT_ERR_SYSTEM;
    if (socket_flags(fd) < 0) { close(fd); return NDT_ERR_SYSTEM; }
    struct sockaddr_un address; memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX; memcpy(address.sun_path, l->path, a + b + 2);
    address.sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) + a + b + 2);
    if (bind(fd, (struct sockaddr *)&address, address.sun_len) < 0) { close(fd); return NDT_ERR_SYSTEM; }
    l->fd = fd;
    if (lstat(l->path, &st) < 0 || !S_ISSOCK(st.st_mode)) { ndt_listener_close(l); return NDT_ERR_SYSTEM; }
    l->device = st.st_dev; l->inode = st.st_ino;
    if (chmod(l->path, 0600) < 0 || listen(fd, 2) < 0) { ndt_listener_close(l); return NDT_ERR_SYSTEM; }
    return NDT_OK;
}
void ndt_listener_close(ndt_listener *l)
{
    if (!l) return;
    close_fd(&l->fd);
    struct stat st;
    if (l->inode && lstat(l->path, &st) == 0 && S_ISSOCK(st.st_mode) &&
        st.st_dev == l->device && st.st_ino == l->inode) (void)unlink(l->path);
    l->inode = 0;
}
int ndt_client_start(ndt_connection *c, const char *path, uid_t uid,
                     pid_t pid, uint64_t hi, uint64_t lo, uint64_t epoch)
{
    if (!c) return NDT_ERR_ARGUMENT;
    initialize(c, CONSUMER, uid, pid, hi, lo, epoch);
    if (!path || !*path || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path) ||
        pid <= 0 || !(hi | lo) || !epoch) return fail(c, NDT_ERR_ARGUMENT, 0);
    struct stat st;
    if (lstat(path, &st) < 0) return fail(c, NDT_ERR_SYSTEM, errno);
    if (!S_ISSOCK(st.st_mode) || st.st_uid != uid || (st.st_mode & 0777) != 0600)
        return fail(c, NDT_ERR_PEER, 0);
    c->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (c->fd < 0 || socket_flags(c->fd) < 0) return fail(c, NDT_ERR_SYSTEM, errno);
    struct sockaddr_un address; memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX; memcpy(address.sun_path, path, strlen(path) + 1);
    address.sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1);
    c->state = CONNECTING;
    if (connect(c->fd, (struct sockaddr *)&address, address.sun_len) == 0) return peer(c);
    if (errno == EINPROGRESS || errno == EAGAIN || errno == EWOULDBLOCK) return NDT_AGAIN;
    return fail(c, NDT_ERR_SYSTEM, errno);
}
int ndt_server_accept(ndt_listener *l, ndt_connection *c, uid_t uid,
                      uint64_t hi, uint64_t lo, uint64_t epoch)
{
    if (!l || !c) return NDT_ERR_ARGUMENT;
    initialize(c, PRODUCER, uid, 0, hi, lo, epoch);
    if (!(hi | lo) || !epoch || l->fd < 0) return NDT_ERR_ARGUMENT;
    c->fd = accept(l->fd, NULL, NULL);
    if (c->fd < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? NDT_AGAIN : NDT_ERR_SYSTEM;
    if (socket_flags(c->fd) < 0) return fail(c, NDT_ERR_SYSTEM, errno);
    return peer(c);
}

int ndt_memory_extent(int fd, uint64_t *extent)
{
    struct stat st; int mode = fcntl(fd, F_GETFL);
    if (!extent || fstat(fd, &st) < 0 || mode < 0) return NDT_ERR_SYSTEM;
    /* Darwin POSIX shm fstat can have permission bits without S_IFREG. */
    if ((!S_ISREG(st.st_mode) && (st.st_mode & S_IFMT) != 0) ||
        (mode & O_ACCMODE) == O_WRONLY || st.st_size <= 0 ||
        (uint64_t)st.st_size > NDT_MAX_EXTENT || st.st_size % getpagesize()) return NDT_ERR_BOUNDS;
    *extent = (uint64_t)st.st_size; return NDT_OK;
}
static int token_type(int fd)
{
    struct stat st; int mode = fcntl(fd, F_GETFL);
    if (mode < 0 || fstat(fd, &st) < 0 || (mode & O_ACCMODE) == O_WRONLY) return 0;
    if (S_ISFIFO(st.st_mode)) return 1;
    if (S_ISSOCK(st.st_mode)) {
        struct sockaddr_storage address; socklen_t bytes = sizeof(address);
        return getsockname(fd, (struct sockaddr *)&address, &bytes) == 0 &&
               bytes >= offsetof(struct sockaddr, sa_data) && address.ss_family == AF_UNIX;
    }
    return 0;
}
int ndt_ready(int fd)
{
    if (!token_type(fd)) return NDT_ERR_TOKEN;
    struct pollfd p = { .fd = fd, .events = POLLIN };
    int result = poll(&p, 1, 0);
    if (result < 0) return errno == EINTR ? NDT_AGAIN : NDT_ERR_TOKEN;
    if (p.revents & (POLLHUP | POLLERR | POLLNVAL)) return NDT_ERR_TOKEN;
    return p.revents & POLLIN ? NDT_OK : NDT_AGAIN;
}
static int metadata(const ndt_metadata *m)
{
    uint64_t pixels = (uint64_t)m->width * m->height;
    if (!m->width || !m->height || m->width > NDT_MAX_DIMENSION || m->height > NDT_MAX_DIMENSION ||
        pixels > NDT_MAX_PIXELS || m->format != NDT_BGRA8 || m->offset ||
        m->pitch < (uint64_t)m->width * 4 || m->pitch % 4 ||
        m->size != (uint64_t)m->pitch * m->height || !m->size || m->size > NDT_MAX_EXTENT)
        return NDT_ERR_BOUNDS;
    return NDT_OK;
}
static void put(uint8_t *p, uint64_t value, int bytes) { for (int i = 0; i < bytes; i++) p[i] = (uint8_t)(value >> (i * 8)); }
static uint64_t get(const uint8_t *p, int bytes) { uint64_t value = 0; for (int i = 0; i < bytes; i++) value |= (uint64_t)p[i] << (i * 8); return value; }
static void encode(uint8_t *p, int type, const ndt_metadata *m)
{
    memset(p, 0, NDT_WIRE_BYTES); memcpy(p, magic, 8);
    put(p + 8, type, 2); put(p + 10, 1, 2); put(p + 12, NDT_WIRE_BYTES, 4);
    put(p + 16, m->id.session_hi, 8); put(p + 24, m->id.session_lo, 8);
    put(p + 32, m->id.epoch, 8); put(p + 40, m->id.frame, 8);
    if (type == FRAME) {
        put(p + 48, m->width, 4); put(p + 52, m->height, 4); put(p + 56, m->pitch, 4);
        put(p + 60, m->format, 4); put(p + 64, m->offset, 8); put(p + 72, m->size, 8);
    }
}
static int decode(const uint8_t *p, ndt_metadata *m)
{
    if (memcmp(p, magic, 8) || get(p + 10, 2) != 1 || get(p + 12, 4) != NDT_WIRE_BYTES) return NDT_ERR_PROTOCOL;
    for (int i = 80; i < NDT_WIRE_BYTES; i++) if (p[i]) return NDT_ERR_PROTOCOL;
    memset(m, 0, sizeof(*m));
    m->id = (ndt_identity){ get(p + 16, 8), get(p + 24, 8), get(p + 32, 8), get(p + 40, 8) };
    int type = (int)get(p + 8, 2);
    if (type == ACK) {
        for (int i = 48; i < 80; i++) if (p[i]) return NDT_ERR_PROTOCOL;
    } else if (type == FRAME) {
        m->width = (uint32_t)get(p + 48, 4); m->height = (uint32_t)get(p + 52, 4);
        m->pitch = (uint32_t)get(p + 56, 4); m->format = (uint32_t)get(p + 60, 4);
        m->offset = get(p + 64, 8); m->size = get(p + 72, 8);
    } else return NDT_ERR_PROTOCOL;
    return type;
}
static int empty_slot(ndt_connection *c) { for (int i = 0; i < NDT_SLOTS; i++) if (c->slots[i].state == EMPTY) return i; return -1; }
int ndt_queue_frame(ndt_connection *c, const ndt_metadata *m, int mem, int ready)
{
    if (!c || !m || c->role != PRODUCER || c->state != CONNECTED) return NDT_ERR_ARGUMENT;
    if (c->tx_kind || empty_slot(c) < 0) return NDT_AGAIN;
    if (!expected(c, m->id) || m->id.frame <= c->last_frame) return NDT_ERR_IDENTITY;
    int result = metadata(m); uint64_t extent = 0;
    if (result != NDT_OK) return result;
    result = ndt_memory_extent(mem, &extent);
    if (result != NDT_OK || extent < m->size) return NDT_ERR_BOUNDS;
    if (!token_type(ready)) return NDT_ERR_TOKEN;
    int a = fcntl(mem, F_DUPFD_CLOEXEC, 0);
    if (a < 0) return NDT_ERR_SYSTEM;
    int b = fcntl(ready, F_DUPFD_CLOEXEC, 0);
    if (b < 0) { close(a); return NDT_ERR_SYSTEM; }
    int slot = empty_slot(c); c->slots[slot].metadata = *m; c->slots[slot].state = QUEUED;
    c->tx_fds[0] = a; c->tx_fds[1] = b; c->tx_fd_count = 2;
    c->tx_kind = FRAME; c->tx_slot = slot; c->tx_used = 0; c->last_frame = m->id.frame;
    encode(c->tx, FRAME, m); return NDT_OK;
}
int ndt_take_frame(ndt_connection *c, ndt_frame *out)
{
    if (!c || !out || c->role != CONSUMER) return NDT_ERR_ARGUMENT;
    int chosen = -1;
    for (int i = 0; i < NDT_SLOTS; i++) if (c->slots[i].state == AVAILABLE &&
        (chosen < 0 || c->slots[i].metadata.id.frame < c->slots[chosen].metadata.id.frame)) chosen = i;
    if (chosen < 0) return NDT_AGAIN;
    ndt_slot *s = &c->slots[chosen];
    *out = (ndt_frame){ s->metadata, s->memory_fd, s->ready_fd, s->extent };
    s->memory_fd = s->ready_fd = -1; s->state = TAKEN; return NDT_OK;
}
int ndt_queue_ack(ndt_connection *c, const ndt_identity *id)
{
    if (!c || !id || c->role != CONSUMER || c->state != CONNECTED) return NDT_ERR_ARGUMENT;
    if (c->tx_kind) return NDT_AGAIN;
    for (int i = 0; i < NDT_SLOTS; i++) if (c->slots[i].state == TAKEN && same(c->slots[i].metadata.id, *id)) {
        encode(c->tx, ACK, &c->slots[i].metadata); c->tx_kind = ACK; c->tx_slot = i;
        c->tx_used = 0; c->slots[i].state = ACK_TX; return NDT_OK;
    }
    return NDT_ERR_IDENTITY;
}
int ndt_next_event(ndt_connection *c, ndt_event *event)
{
    if (!c || !event) return NDT_ERR_ARGUMENT;
    for (int i = 0; i < NDT_SLOTS; i++) if (c->slots[i].state == ACKED || c->slots[i].state == CANCELLED) {
        event->kind = c->slots[i].state == ACKED ? NDT_EVENT_ACK : NDT_EVENT_CANCEL;
        event->id = c->slots[i].metadata.id; c->slots[i].state = EMPTY; return NDT_OK;
    }
    return NDT_AGAIN;
}
void ndt_frame_close(ndt_frame *frame) { if (frame) { close_fd(&frame->memory_fd); close_fd(&frame->ready_fd); } }
short ndt_poll_events(const ndt_connection *c)
{
    if (!c || c->fd < 0 || c->state == CLOSED) return 0;
    return (short)(POLLIN | ((c->state == CONNECTING || c->tx_kind) ? POLLOUT : 0));
}
int ndt_socket_fd(const ndt_connection *c) { return c ? c->fd : -1; }
int ndt_status(const ndt_connection *c)
{
    if (!c) return NDT_ERR_ARGUMENT;
    if (c->error) return c->error;
    if (c->fd < 0 || c->state == CLOSED) return NDT_CLOSED;
    return c->state == CONNECTED ? NDT_OK : NDT_AGAIN;
}
static int transmit(ndt_connection *c)
{
    if (!c->tx_kind) return NDT_AGAIN;
    struct iovec iov = { c->tx + c->tx_used, NDT_WIRE_BYTES - c->tx_used };
    union { struct cmsghdr alignment; uint8_t bytes[CMSG_SPACE(2 * sizeof(int))]; } control;
    struct msghdr message; memset(&message, 0, sizeof(message)); message.msg_iov = &iov; message.msg_iovlen = 1;
    if (c->tx_fd_count) {
        memset(&control, 0, sizeof(control)); message.msg_control = control.bytes; message.msg_controllen = sizeof(control);
        struct cmsghdr *header = CMSG_FIRSTHDR(&message); header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(2 * sizeof(int)); memcpy(CMSG_DATA(header), c->tx_fds, 2 * sizeof(int));
    }
    ssize_t n = sendmsg(c->fd, &message, MSG_DONTWAIT);
    if (n < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? NDT_AGAIN : fail(c, NDT_ERR_SYSTEM, errno);
    if (!n) return fail(c, NDT_ERR_SYSTEM, EPIPE);
    for (int i = 0; i < 2; i++) close_fd(&c->tx_fds[i]);
    c->tx_fd_count = 0; c->tx_used += (size_t)n;
    if (c->tx_used == NDT_WIRE_BYTES) {
        c->slots[c->tx_slot].state = c->tx_kind == FRAME ? SENT : EMPTY;
        c->tx_kind = 0; c->tx_used = 0; c->tx_slot = -1;
    }
    return NDT_OK;
}
static int receive_record(ndt_connection *c)
{
    /* Darwin externalizes all rights before copying/truncating control data.
     * Cover its entire UIPC_MAX_CMSG_FD/MCLBYTES envelope, not just our 2 FDs,
     * so surplus descriptors remain visible and can all be closed. */
    int fds[512], count = 0, bad = 0;
    struct iovec iov = { c->rx + c->rx_used, NDT_WIRE_BYTES - c->rx_used };
    union { struct cmsghdr alignment; uint8_t bytes[CMSG_SPACE(512 * sizeof(int))]; } control;
    struct msghdr message; memset(&message, 0, sizeof(message)); memset(&control, 0, sizeof(control));
    message.msg_iov = &iov; message.msg_iovlen = 1; message.msg_control = control.bytes; message.msg_controllen = sizeof(control);
    ssize_t n = recvmsg(c->fd, &message, MSG_DONTWAIT);
    if (n < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? NDT_AGAIN : fail(c, NDT_ERR_SYSTEM, errno);
    for (struct cmsghdr *h = CMSG_FIRSTHDR(&message); h; h = CMSG_NXTHDR(&message, h)) {
        size_t start = (size_t)((uint8_t *)h - control.bytes);
        if (start > message.msg_controllen || h->cmsg_len < CMSG_LEN(0)) { bad = 1; break; }
        /* Darwin can retain the original cmsg_len on MSG_CTRUNC. Close every
         * complete descriptor actually present before rejecting that record. */
        size_t available = message.msg_controllen - start;
        size_t span = h->cmsg_len;
        if (span > available) { span = available; bad = 1; }
        if (span < CMSG_LEN(0)) { bad = 1; break; }
        if (h->cmsg_level != SOL_SOCKET || h->cmsg_type != SCM_RIGHTS) { bad = 1; continue; }
        size_t size = span - CMSG_LEN(0);
        if (size % sizeof(int)) bad = 1;
        for (size_t i = 0; i < size / sizeof(int); i++) {
            int fd; memcpy(&fd, (uint8_t *)CMSG_DATA(h) + i * sizeof(int), sizeof(fd));
            if (count == 512) { close(fd); bad = 1; } else {
                fds[count++] = fd; if (flags(fd, 0) < 0) bad = 1;
            }
        }
        if (h->cmsg_len > available) break;
    }
    if (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) bad = 1;
    if (count && (c->rx_used || count != 2 || c->rx_fd_count)) bad = 1;
    if (bad) { for (int i = 0; i < count; i++) close(fds[i]); return fail(c, NDT_ERR_PROTOCOL, 0); }
    if (count) { c->rx_fds[0] = fds[0]; c->rx_fds[1] = fds[1]; c->rx_fd_count = 2; }
    if (!n) {
        if (c->rx_used || c->rx_fd_count) return fail(c, NDT_ERR_PROTOCOL, 0);
        ndt_close(c); return NDT_CLOSED;
    }
    c->rx_used += (size_t)n;
    if (c->rx_used < NDT_WIRE_BYTES) return NDT_OK;
    ndt_metadata m; int type = decode(c->rx, &m);
    if (type < 0) return fail(c, type, 0);
    if (!expected(c, m.id)) return fail(c, NDT_ERR_IDENTITY, 0);
    if (type == FRAME && c->role == CONSUMER && c->rx_fd_count == 2) {
        if (metadata(&m) != NDT_OK) return fail(c, NDT_ERR_BOUNDS, 0);
        if (m.id.frame <= c->last_frame) return fail(c, NDT_ERR_IDENTITY, 0);
        int slot = empty_slot(c); uint64_t extent = 0;
        if (slot < 0) return fail(c, NDT_ERR_PROTOCOL, 0);
        if (ndt_memory_extent(c->rx_fds[0], &extent) != NDT_OK || extent < m.size) return fail(c, NDT_ERR_BOUNDS, 0);
        if (!token_type(c->rx_fds[1])) return fail(c, NDT_ERR_TOKEN, 0);
        c->slots[slot] = (ndt_slot){ m, extent, AVAILABLE, c->rx_fds[0], c->rx_fds[1] };
        c->rx_fds[0] = c->rx_fds[1] = -1; c->rx_fd_count = 0; c->last_frame = m.id.frame;
    } else if (type == ACK && c->role == PRODUCER && !c->rx_fd_count) {
        int slot = -1;
        for (int i = 0; i < NDT_SLOTS; i++) if (c->slots[i].state == SENT && same(c->slots[i].metadata.id, m.id)) slot = i;
        if (slot < 0) return fail(c, NDT_ERR_IDENTITY, 0);
        c->slots[slot].state = ACKED;
    } else return fail(c, NDT_ERR_PROTOCOL, 0);
    c->rx_used = 0; return NDT_OK;
}
int ndt_pump(ndt_connection *c)
{
    if (!c || c->fd < 0) return c && c->error ? c->error : NDT_CLOSED;
    if (c->state == CONNECTING) {
        struct pollfd p = { .fd = c->fd, .events = POLLOUT };
        int result = poll(&p, 1, 0);
        if (result < 0) return errno == EINTR ? NDT_AGAIN : fail(c, NDT_ERR_SYSTEM, errno);
        if (!result) return NDT_AGAIN;
        int error = 0; socklen_t size = sizeof(error);
        if (getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &error, &size) < 0 || error) return fail(c, NDT_ERR_SYSTEM, error ? error : errno);
        result = peer(c); if (result != NDT_OK) return result;
    }
    int a = transmit(c); if (a < 0) return a;
    int b = receive_record(c); if (b < 0 || b == NDT_CLOSED) return b;
    return a == NDT_OK || b == NDT_OK ? NDT_OK : NDT_AGAIN;
}
