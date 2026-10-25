/* SPDX-License-Identifier: MIT */
#include "gpu-receiver.h"
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>
int perp_wgc_receive(int socket,char *metadata,size_t capacity)
{
    if(capacity<2)return -1;
    struct iovec io={metadata,capacity-1};
    union {struct cmsghdr alignment;char bytes[CMSG_SPACE(sizeof(int)*16)];} control={0};
    struct msghdr msg={0};msg.msg_iov=&io;msg.msg_iovlen=1;msg.msg_control=control.bytes;msg.msg_controllen=sizeof(control.bytes);
    ssize_t count=recvmsg(socket,&msg,MSG_DONTWAIT);if(count<0)return -1;
    int result=-1,total=0;
    for(struct cmsghdr *c=CMSG_FIRSTHDR(&msg);c;c=CMSG_NXTHDR(&msg,c)) {
        if(c->cmsg_level!=SOL_SOCKET || c->cmsg_type!=SCM_RIGHTS || c->cmsg_len<CMSG_LEN(0))continue;
        size_t n=(c->cmsg_len-CMSG_LEN(0))/sizeof(int);int *fds=(int *)CMSG_DATA(c);
        for(size_t i=0;i<n;i++){total++;if(result<0)result=fds[i];else close(fds[i]);}
    }
    if(count<=0 || (msg.msg_flags&(MSG_TRUNC|MSG_CTRUNC)) || total!=1){if(result>=0)close(result);return -1;}
    metadata[count]=0;return result;
}
