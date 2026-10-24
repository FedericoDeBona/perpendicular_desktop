/* SPDX-License-Identifier: MIT
 * Opt-in descriptor forwarding for the single-window WGC experiment.
 * Included only in a private npt_shared.c build, after the Darwin layout.
 * No pixels copied and no change to the ordinary blob export ABI. */
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
static void perp_wgc_export(struct npt_context *ctx, uint64_t blob,
                            const struct npt_darwin_shared_texture *d)
{
    const char *path=getenv("PERP_WGC_EXPORT_SOCKET");
    if(!path ||
       !d || d->magic!=NPT_DARWIN_SHARED_TEXTURE_MAGIC || d->version!=2 ||
       d->fd<0 || d->offset || d->dxgi_format!=87 || d->width<32 ||
       d->width>4096 || d->height<2 || d->height>4096 || d->width%64 || d->height%64!=1 ||
       d->stride<d->width*4ull || d->stride%256 || d->size!=d->stride*d->height ||
       d->size>34*1024*1024ull)return;
    struct sockaddr_un address={0};address.sun_family=AF_UNIX;
    if(strlen(path)>=sizeof(address.sun_path))return;
    strcpy(address.sun_path,path);
    int fd=socket(AF_UNIX,SOCK_DGRAM,0);if(fd<0)return;
    char data[512];int count=snprintf(data,sizeof(data),
       "{\"width\":%u,\"height\":%u,\"stride\":%llu,\"size\":%llu,\"blob\":%llu,\"context\":%u}",
       d->width,d->height,(unsigned long long)d->stride,(unsigned long long)d->size,
       (unsigned long long)blob,ctx->ctx_id);
    if(count<=0 || count>=(int)sizeof(data)){close(fd);return;}
    struct iovec io={data,(size_t)count};
    union {struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))];} control={0};
    struct msghdr message={0};message.msg_name=&address;message.msg_namelen=sizeof(address);
    message.msg_iov=&io;message.msg_iovlen=1;message.msg_control=control.bytes;message.msg_controllen=sizeof(control.bytes);
    struct cmsghdr *c=CMSG_FIRSTHDR(&message);c->cmsg_level=SOL_SOCKET;c->cmsg_type=SCM_RIGHTS;c->cmsg_len=CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c),&d->fd,sizeof(int));
    ssize_t sent=sendmsg(fd,&message,MSG_DONTWAIT);close(fd);
    npt_log("wgc-export: context=%u blob=%llu size=%ux%u sent=%zd",ctx->ctx_id,(unsigned long long)blob,d->width,d->height,sent);
}
