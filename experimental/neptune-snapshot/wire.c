/* SPDX-License-Identifier: MIT */
#include "wire.h"
#include <sys/socket.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

int perp_snapshot_send(int channel,const PerpSnapshotPacket *packet,int memory_fd,int ready_fd)
{
    struct iovec io={ (void *)packet,sizeof(*packet) };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int)*2)]; } ancillary={0};
    struct msghdr message={0};
    message.msg_iov=&io; message.msg_iovlen=1;
    message.msg_control=ancillary.bytes; message.msg_controllen=sizeof(ancillary.bytes);
    struct cmsghdr *header=CMSG_FIRSTHDR(&message);
    header->cmsg_level=SOL_SOCKET; header->cmsg_type=SCM_RIGHTS;
    header->cmsg_len=CMSG_LEN(sizeof(int)*2);
    int fds[]={memory_fd,ready_fd}; memcpy(CMSG_DATA(header),fds,sizeof(fds));
    ssize_t sent=sendmsg(channel,&message,MSG_DONTWAIT);
    /* Tiny packets on an empty owned channel must be atomic. On a short write
     * the channel is failed, never retried with duplicate descriptor rights. */
    return sent==(ssize_t)sizeof(*packet) ? 0 : -1;
}

int perp_snapshot_receive(int channel,PerpSnapshotPacket *packet,int fds[2])
{
    struct iovec io={ packet,sizeof(*packet) };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int)*2)]; } ancillary={0};
    struct msghdr message={0};
    message.msg_iov=&io; message.msg_iovlen=1;
    message.msg_control=ancillary.bytes; message.msg_controllen=sizeof(ancillary.bytes);
    fds[0]=fds[1]=-1;
    ssize_t got=recvmsg(channel,&message,MSG_DONTWAIT);
    if(got<0 && (errno==EAGAIN || errno==EWOULDBLOCK)) return 1;
    struct cmsghdr *header=CMSG_FIRSTHDR(&message);
    if(!header || header->cmsg_level!=SOL_SOCKET || header->cmsg_type!=SCM_RIGHTS ||
       header->cmsg_len!=CMSG_LEN(sizeof(int)*2) || CMSG_NXTHDR(&message,header)) {
        /* Even a rejected bounded message transfers ownership of rights that
         * fit. Close those rights; never retain them while reporting failure. */
        for(struct cmsghdr *item=header;item;item=CMSG_NXTHDR(&message,item)) {
            if(item->cmsg_level==SOL_SOCKET && item->cmsg_type==SCM_RIGHTS && item->cmsg_len>=CMSG_LEN(0)) {
                size_t bytes=item->cmsg_len-CMSG_LEN(0);
                if(bytes>sizeof(int)*2) bytes=sizeof(int)*2;
                for(size_t index=0;index<bytes/sizeof(int);index++) {
                    int right; memcpy(&right,(char *)CMSG_DATA(item)+index*sizeof(int),sizeof(right)); close(right);
                }
            }
        }
        return -1;
    }
    memcpy(fds,CMSG_DATA(header),sizeof(int)*2);
    if(got!=(ssize_t)sizeof(*packet) || message.msg_flags&MSG_CTRUNC ||
       packet->magic!=PERP_SNAPSHOT_MAGIC || packet->version!=1 ||
       !packet->generation || packet->texture.fd!=-1) {
        close(fds[0]); close(fds[1]); fds[0]=fds[1]=-1; return -1;
    }
    return 0;
}
