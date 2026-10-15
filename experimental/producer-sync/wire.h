/* SPDX-License-Identifier: MIT
 * Development-only, fixed-layout same-host Unix socket protocol. */
#pragma once
#include <directx-native/dxn_shared.h>
#include <sys/socket.h>
#include <poll.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <stdexcept>
#include <string>

static inline void check(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(std::string(message)+" (errno="+std::to_string(errno)+")");
}
struct Frame {
    uint32_t magic = 0x50525046, version = 1, sequence = 0, flags = 0;
    dxn_shared_texture texture{};
};
static_assert(sizeof(Frame) == 168, "local fixture wire layout");
static inline void exact_io(int fd, void *bytes, size_t count, bool writing) {
    auto *data = static_cast<char *>(bytes);
    while (count) {
        ssize_t size = writing ? send(fd, data, count, 0) : recv(fd, data, count, 0);
        if (size < 0 && errno == EINTR) continue;
        check(size > 0, "Control socket EOF/error/timeout");
        count -= size; data += size;
    }
}
static inline void control(int fd, char expected) {
    char value = 0; exact_io(fd, &value, 1, false);
    check(value == expected, "Invalid control transition");
}
static inline void notify(int fd, char value) { exact_io(fd, &value, 1, true); }
static inline void configure_socket(int fd) {
    timeval timeout{10,0};
    check(setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout))==0, "Socket receive timeout");
    check(setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout))==0, "Socket send timeout");
    int enabled = 1;
    check(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled))==0, "Socket no SIGPIPE");
}
static inline void send_frame(int fd, Frame frame, int shared_fd, int event_fd) {
    frame.texture.fd = -1; // fd numbers and all pointers stay process-local.
    iovec io{&frame,sizeof(frame)};
    union { cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int)*2)]; } ancillary{};
    msghdr message{}; message.msg_iov = &io; message.msg_iovlen = 1;
    message.msg_control = ancillary.bytes; message.msg_controllen = sizeof(ancillary.bytes);
    cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int)*2);
    int fds[] = {shared_fd,event_fd}; std::memcpy(CMSG_DATA(header),fds,sizeof(fds));
    ssize_t sent = sendmsg(fd,&message,0);
    check(sent > 0 && size_t(sent) <= sizeof(frame), "Send frame/SCM_RIGHTS");
    if (size_t(sent) < sizeof(frame)) exact_io(fd,reinterpret_cast<char *>(&frame)+sent,sizeof(frame)-sent,true);
}
static inline Frame receive_frame(int fd, int (&fds)[2]) {
    Frame frame{}; iovec io{&frame,sizeof(frame)};
    union { cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int)*2)]; } ancillary{};
    msghdr message{}; message.msg_iov=&io; message.msg_iovlen=1;
    message.msg_control=ancillary.bytes; message.msg_controllen=sizeof(ancillary.bytes);
    ssize_t size=recvmsg(fd,&message,0);
    check(size>0 && size_t(size)<=sizeof(frame) && !(message.msg_flags & MSG_CTRUNC), "Receive frame/SCM_RIGHTS");
    cmsghdr *header=CMSG_FIRSTHDR(&message);
    check(header && header->cmsg_level==SOL_SOCKET && header->cmsg_type==SCM_RIGHTS &&
        header->cmsg_len==CMSG_LEN(sizeof(int)*2) && CMSG_NXTHDR(&message,header)==nullptr, "Expected exactly two descriptors");
    std::memcpy(fds,CMSG_DATA(header),sizeof(fds));
    if (size_t(size)<sizeof(frame)) exact_io(fd,reinterpret_cast<char *>(&frame)+size,sizeof(frame)-size,false);
    check(frame.magic==0x50525046 && frame.version==1 && frame.texture.fd==-1, "Invalid frame envelope");
    return frame;
}
static inline short wait_fd(int fd, int milliseconds) {
    pollfd descriptor{fd,POLLIN,0}; int result;
    do { result=poll(&descriptor,1,milliseconds); } while(result<0 && errno==EINTR);
    check(result>=0, "Poll failed"); return result ? descriptor.revents : 0;
}
