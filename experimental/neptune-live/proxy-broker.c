/* SPDX-License-Identifier: MIT
 * VM-global host registry on the actual proxy caller thread. No background
 * reader races the proxy's ordinary request/reply channel. */
#include "live.h"
#include "wire.h"
#include "proxy/proxy_socket.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_CONTEXTS 32
#define MAX_RESOURCES 256
typedef struct LiveExport {uint64_t blob,object;uint32_t resource;} LiveExport;
typedef struct LiveWorker {
    uint32_t id;uint64_t epoch;int fd;struct proxy_socket *control;
    bool hello,bad,enabled,revoking;
    uint32_t retired_batch;
    uint32_t capture_resource;
    LiveExport exports[LIVE_MAX_SOURCES];
    LiveExport claims[LIVE_MAX_SOURCES];
    _Alignas(8) unsigned char input[248];size_t have,want;int rights[2];unsigned fd_count;
} LiveWorker;
typedef struct LiveResource {
    uint32_t id,context,last_generation;uint64_t worker_epoch,epoch,blob,object,bytes;
    bool tainted,granted,deny_acked;
} LiveResource;
typedef struct LiveFrame {
    PerpBrokerHeader header;PerpSnapshotPacket packet;int fds[2];bool used,leased;uint64_t received;
} LiveFrame;
static LiveWorker workers[MAX_CONTEXTS];
static LiveResource resources[MAX_RESOURCES];
static LiveFrame frames[LIVE_MAX_CANDIDATES];
static uint64_t session,worker_epoch,resource_epoch;
static uint32_t selected,active;
static uint64_t received,completed,cancelled,rejected,imports_denied,peak_bytes,max_pending;
static bool permanently_failed;
static bool enabled(void) {const char *value=getenv("PERP_NEPTUNE_SCANOUT_BROKER");return value && !strcmp(value,"1");}
static uint64_t now(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000ull+t.tv_nsec;}
static LiveWorker *worker(uint32_t id) {for(unsigned i=0;i<MAX_CONTEXTS;i++)if(workers[i].id==id && id)return &workers[i];return NULL;}
static LiveResource *resource(uint32_t id) {for(unsigned i=0;i<MAX_RESOURCES;i++)if(resources[i].id==id && id)return &resources[i];return NULL;}
static void close_rights(int *fds,unsigned count) {for(unsigned i=0;i<count;i++)if(fds[i]>=0)close(fds[i]);}
static bool send_control(LiveWorker *w,PerpBrokerHeader *h,const int *fds,unsigned count)
{
    if(!w || w->bad || !w->control)return false;
    h->magic=PERP_BROKER_MAGIC;h->version=1;h->bytes=sizeof(*h);h->fd_count=count;
    h->session=session;h->worker_epoch=w->epoch;h->context_id=w->id;
    return proxy_socket_send_request_with_fds(w->control,h,sizeof(*h),fds,count);
}
static bool ready(LiveFrame *f)
{
    struct pollfd p={f->fds[1],POLLIN,0};int result=poll(&p,1,0);
    return result==1 && (p.revents&POLLIN) && !(p.revents&(POLLHUP|POLLERR|POLLNVAL));
}
static void retire(LiveFrame *f,bool read)
{
    LiveWorker *w=worker(f->header.context_id);
    if(w && w->epoch==f->header.worker_epoch && !w->bad) {
        PerpBrokerHeader ack=f->header;ack.kind=PERP_ACK;ack.status=read?0:1;
        if(!send_control(w,&ack,NULL,0))w->bad=true;
    }
    close_rights(f->fds,2);memset(f,0,sizeof(*f));if(read)completed++;else cancelled++;
}
static void fail_worker(LiveWorker *w,const char *reason)
{
    if(!w->bad)fprintf(stderr,"perp-live: context %u capture closed: %s\n",w->id,reason);
    w->bad=true;rejected++;
    /* A bad sender cannot cause another worker to be enabled while its
     * snapshot allocation budget is unknown. Keep the VM gate closed. */
    if(active==w->id)permanently_failed=true;
    if(w->fd>=0)close(w->fd);w->fd=-1;close_rights(w->rights,w->fd_count);w->fd_count=0;
    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)if(frames[i].used && frames[i].header.context_id==w->id && !frames[i].leased)retire(&frames[i],false);
}
void perp_live_context_start(uint32_t id,uint32_t capset,struct proxy_socket *control)
{
    if(!enabled() || capset!=7)return;
    if(!session)session=((uint64_t)arc4random()<<32)|arc4random();
    LiveWorker *w=NULL;for(unsigned i=0;i<MAX_CONTEXTS;i++)if(!workers[i].id) {w=&workers[i];break;}
    if(!w || worker(id) || ++worker_epoch==0) {permanently_failed=true;return;}
    int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair)) {permanently_failed=true;return;}
    *w=(LiveWorker){.id=id,.epoch=worker_epoch,.fd=pair[0],.control=control,.want=sizeof(PerpBrokerHeader),.rights={-1,-1}};
    int flags=fcntl(pair[0],F_GETFL);if(flags<0 || fcntl(pair[0],F_SETFL,flags|O_NONBLOCK)) {close(pair[1]);fail_worker(w,"nonblocking channel");return;}
    PerpBrokerHeader attach={.kind=LIVE_ATTACH};
    if(!send_control(w,&attach,&pair[1],1))fail_worker(w,"attach broker channel");
    close(pair[1]);
}
void perp_live_context_stop(uint32_t id)
{
    LiveWorker *w=worker(id);if(!w)return;
    if(active==id) {active=0;permanently_failed=true;}
    if(w->fd>=0)close(w->fd);close_rights(w->rights,w->fd_count);
    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)if(frames[i].used && frames[i].header.context_id==id && !frames[i].leased) {
        close_rights(frames[i].fds,2);memset(&frames[i],0,sizeof(frames[i]));
    }
    for(unsigned i=0;i<MAX_RESOURCES;i++)if(resources[i].context==id)memset(&resources[i],0,sizeof(resources[i]));
    memset(w,0,sizeof(*w));
}
void perp_live_resource_created(uint32_t id,uint32_t context,uint64_t blob,uint64_t bytes)
{
    LiveWorker *w=worker(context);if(!w || !blob)return;
    LiveResource *r=NULL;for(unsigned i=0;i<MAX_RESOURCES;i++)if(!resources[i].id) {r=&resources[i];break;}
    if(!r || resource(id) || !id || !bytes || bytes>LIVE_MAX_BYTES || ++resource_epoch==0) {fail_worker(w,"resource identity/bound");return;}
    *r=(LiveResource){.id=id,.context=context,.worker_epoch=w->epoch,.epoch=resource_epoch,.blob=blob,.bytes=bytes};
}
void perp_live_resource_destroy(uint32_t id)
{
    LiveResource *r=resource(id);if(!r)return;
    r->tainted=true;if(selected==id)selected=0;
    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)if(frames[i].used && frames[i].header.resource_id==id && !frames[i].leased && ready(&frames[i]))retire(&frames[i],false);
    /* Keep the epoch tombstone until the creating context stops: reuse of a
     * resource ID in this first live prototype fails closed, never aliases. */
}
static bool accept_message(LiveWorker *w,const PerpBrokerHeader *h,const void *body)
{
    if(h->magic!=PERP_BROKER_MAGIC || h->version!=1 || h->session!=session || h->worker_epoch!=w->epoch || h->context_id!=w->id || h->fd_count!=w->fd_count)return false;
    if(h->kind==PERP_HELLO && h->bytes==sizeof(*h) && !h->fd_count) {w->hello=true;return true;}
    if(h->kind==PERP_CLAIM && h->bytes==sizeof(*h) && !h->fd_count && h->status==2) {
        LiveResource *r=resource(h->resource_id);
        if(!r || r->context!=w->id || r->worker_epoch!=w->epoch || r->blob!=h->blob_id)return false;
        r->tainted=true;return true;
    }
    if(h->kind==PERP_EXPORT && h->bytes==sizeof(*h) && !h->fd_count) {
        LiveExport *e=NULL;
        for(unsigned i=0;i<LIVE_MAX_SOURCES;i++) {
            if(w->exports[i].blob==h->blob_id)return false;
            if(!w->exports[i].blob)e=&w->exports[i];
        }
        if(!e || !h->blob_id || !h->object_id)return false;
        *e=(LiveExport){.blob=h->blob_id,.object=h->object_id};
        for(unsigned i=0;i<LIVE_MAX_SOURCES;i++)if(w->claims[i].blob==h->blob_id)e->resource=w->claims[i].resource;
        return true;
    }
    if(h->kind==PERP_CLAIM && h->bytes==sizeof(*h) && !h->fd_count && h->status==1) {
        LiveExport *claim=NULL;
        for(unsigned i=0;i<LIVE_MAX_SOURCES;i++) {
            if(w->claims[i].blob==h->blob_id)return false;
            if(!w->claims[i].blob)claim=&w->claims[i];
        }
        if(!claim || !h->resource_id || !h->blob_id)return false;
        *claim=(LiveExport){.blob=h->blob_id,.resource=h->resource_id};
        for(unsigned i=0;i<LIVE_MAX_SOURCES;i++)if(w->exports[i].blob==h->blob_id)w->exports[i].resource=h->resource_id;
        return true;
    }
    if(h->kind==PERP_ACKED && h->bytes==sizeof(*h) && !h->fd_count)return true;
    if(h->kind==LIVE_REVOKED && h->bytes==sizeof(*h) && !h->fd_count && w->revoking) {
        w->revoking=w->enabled=false;w->capture_resource=0;if(active==w->id)active=0;
        for(unsigned i=0;i<MAX_RESOURCES;i++)if(resources[i].context==w->id)resources[i].granted=false;return true;
    }
    if(h->kind==LIVE_DENIED && h->bytes==sizeof(*h) && !h->fd_count) {
        LiveResource *r=resource(h->resource_id);
        if(!r || r->worker_epoch!=w->epoch || r->epoch!=h->resource_epoch || r->blob!=h->blob_id)return false;
        r->deny_acked=true;return true;
    }
    if(h->kind!=PERP_FRAME || h->bytes!=248 || h->fd_count!=2 || !h->snapshot_generation || !h->status || !w->enabled || active!=w->id)return false;
    LiveResource *r=resource(h->resource_id);const PerpSnapshotPacket *p=body;
    if(!r || r->context!=w->id || r->worker_epoch!=w->epoch || r->epoch!=h->resource_epoch || r->blob!=h->blob_id ||
       r->object!=h->object_id || !r->granted || h->snapshot_generation<=r->last_generation ||
       p->magic!=PERP_SNAPSHOT_MAGIC || p->version!=1 || p->generation!=h->snapshot_generation || p->context_id!=w->id || p->blob_id!=r->blob ||
       p->texture.fd!=-1 || !p->texture.size || p->texture.size!=r->bytes || p->texture.size>LIVE_MAX_BYTES)return false;
    LiveFrame *frame=NULL;uint64_t bytes=p->texture.size,count=1;
    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++) {
        if(!frames[i].used)frame=&frames[i];
        else {bytes+=frames[i].packet.texture.size;count++;if(frames[i].header.resource_id==r->id)return false;}
    }
    if(!frame || bytes>LIVE_MAX_BYTES)return false;
    *frame=(LiveFrame){.header=*h,.packet=*p,.fds={w->rights[0],w->rights[1]},.used=true,.received=now()};w->fd_count=0;
    r->last_generation=h->snapshot_generation;received++;if(bytes>peak_bytes)peak_bytes=bytes;if(count>max_pending)max_pending=count;return true;
}
static void receive_messages(LiveWorker *w)
{
    for(unsigned attempt=0;attempt<64 && !w->bad;attempt++) {
        struct iovec io={w->input+w->have,w->want-w->have};
        union {struct cmsghdr align;char bytes[CMSG_SPACE(3*sizeof(int))];} rights={0};
        struct msghdr message={.msg_iov=&io,.msg_iovlen=1,.msg_control=rights.bytes,.msg_controllen=sizeof(rights.bytes)};
        ssize_t count=recvmsg(w->fd,&message,MSG_DONTWAIT);
        if(count<0 && (errno==EAGAIN || errno==EWOULDBLOCK))return;
        if(count<0 && errno==EINTR)continue;
        bool good=count>0 && !(message.msg_flags&MSG_CTRUNC);
        for(struct cmsghdr *c=CMSG_FIRSTHDR(&message);c;c=CMSG_NXTHDR(&message,c)) {
            if(c->cmsg_level!=SOL_SOCKET || c->cmsg_type!=SCM_RIGHTS || c->cmsg_len<CMSG_LEN(0)) {good=false;continue;}
            unsigned n=(c->cmsg_len-CMSG_LEN(0))/sizeof(int);int *fds=(void *)CMSG_DATA(c);
            for(unsigned i=0;i<n;i++) {
                if(w->have || w->fd_count>=2) {close(fds[i]);good=false;}else w->rights[w->fd_count++]=fds[i];
            }
        }
        if(!good) {fail_worker(w,"EOF or malformed descriptor framing");return;}
        w->have+=count;
        if(w->have==sizeof(PerpBrokerHeader) && w->want==sizeof(PerpBrokerHeader)) {
            PerpBrokerHeader *h=(void *)w->input;
            if(h->bytes<sizeof(*h) || h->bytes>sizeof(w->input)) {fail_worker(w,"broker length");return;}
            w->want=h->bytes;
        }
        if(w->have==w->want) {
            PerpBrokerHeader *h=(void *)w->input;
            if(!accept_message(w,h,w->input+sizeof(*h))) {
                fprintf(stderr,"perp-live: rejected message context=%u kind=%u status=%u resource=%u\n",w->id,h->kind,h->status,h->resource_id);
                fail_worker(w,"identity, ownership, operation or budget");return;
            }
            close_rights(w->rights,w->fd_count);w->fd_count=0;w->have=0;w->want=sizeof(*h);
        }
    }
}
bool perp_live_before_import(uint32_t context,uint32_t id)
{
    (void)context;LiveResource *r=resource(id);if(!r)return true;r->tainted=true;
    if(!r->granted)return true;
    LiveWorker *w=worker(r->context);if(!w || w->bad)return false;
    PerpBrokerHeader deny={.kind=LIVE_DENY,.resource_id=r->id,.resource_epoch=r->epoch,.blob_id=r->blob,.object_id=r->object};
    if(!send_control(w,&deny,NULL,0))return false;
    uint64_t deadline=now()+1100000000ull;
    while(!r->deny_acked && !w->bad && now()<deadline) {receive_messages(w);struct pollfd p={w->fd,POLLIN,0};poll(&p,1,1);}
    if(!r->deny_acked) {imports_denied++;return false;}return true;
}
bool perp_live_scanout_select(uint32_t id)
{
    if(!id) {selected=0;return enabled();}
    LiveResource *r=resource(id);if(!enabled() || !r)return false;selected=id;return true;
}
void perp_live_scanout_pump(void)
{
    if(!enabled() || permanently_failed)return;
    for(unsigned i=0;i<MAX_CONTEXTS;i++)if(workers[i].id && !workers[i].bad)receive_messages(&workers[i]);
    LiveResource *target=resource(selected);LiveWorker *desired=target && !target->tainted?worker(target->context):NULL;
    LiveWorker *current=worker(active);
    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)if(frames[i].used && !frames[i].leased && !ready(&frames[i]) && now()-frames[i].received>1000000000ull) {
        LiveWorker *w=worker(frames[i].header.context_id);if(w)fail_worker(w,"producer completion timeout");return;
    }
    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)if(frames[i].used && !frames[i].leased && ready(&frames[i])) {
        LiveWorker *source=worker(frames[i].header.context_id);
        if((current && desired!=current) || !resource(frames[i].header.resource_id) ||
           (source && frames[i].header.status<=source->retired_batch))retire(&frames[i],false);
    }
    if(current && desired!=current && !current->revoking) {
        bool pending=false;for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)pending|=frames[i].used;
        if(!pending) {PerpBrokerHeader revoke={.kind=LIVE_REVOKE};if(send_control(current,&revoke,NULL,0))current->revoking=true;else fail_worker(current,"revoke channel");}
        return;
    }
    if(!desired || desired->bad || !desired->hello || (active && active!=desired->id))return;
    /* A reset may leave a consumer callback retaining an old epoch's fd.
     * Do not allocate a fresh worker's snapshot budget until it retires. */
    if(!active)for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)if(frames[i].used)return;
    LiveExport *entry=NULL;
    for(unsigned i=0;i<LIVE_MAX_SOURCES;i++)if(desired->exports[i].blob==target->blob &&
        desired->exports[i].resource==target->id)entry=&desired->exports[i];
    if(!entry)return;
    target->object=entry->object;
    if(desired->capture_resource!=target->id) {
        PerpBrokerHeader grant={.kind=LIVE_GRANT,.resource_id=target->id,.resource_epoch=target->epoch,
            .blob_id=target->blob,.object_id=target->object};
        if(!send_control(desired,&grant,NULL,0)) {fail_worker(desired,"grant channel");return;}
        /* Keep historical grants valid for frames already queued before the
         * selection change. The worker replaces only future capture admission. */
        target->granted=true;desired->capture_resource=target->id;
    }
    if(!desired->enabled) {
        PerpBrokerHeader enable={.kind=LIVE_ENABLE};if(!send_control(desired,&enable,NULL,0)) {fail_worker(desired,"enable channel");return;}
        desired->enabled=true;active=desired->id;
    }
}
bool perp_live_scanout_needs_pump(void)
{
    if(!enabled() || permanently_failed)return false;
    if(active)return true;
    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)if(frames[i].used)return true;
    return false;
}
bool perp_live_scanout_take(uint32_t id,PerpLiveLease *lease)
{
    LiveResource *r=resource(id);if(!r || r->tainted || id!=selected || active!=r->context || permanently_failed)return false;
    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)if(frames[i].used && !frames[i].leased && frames[i].header.resource_id==id && ready(&frames[i])) {
        LiveFrame *f=&frames[i];int fd=dup(f->fds[0]);if(fd<0)return false;
        LiveWorker *w=worker(r->context);if(!w || f->header.status<=w->retired_batch) {close(fd);continue;}
        *lease=(PerpLiveLease){.version=1,.resource_id=id,.context_id=r->context,.generation=f->header.snapshot_generation,
            .worker_epoch=r->worker_epoch,.resource_epoch=r->epoch,.blob_id=r->blob,.texture=f->packet.texture,.memory_fd=fd};
        f->leased=true;return true;
    }
    return false;
}
void perp_live_scanout_done(const PerpLiveLease *lease,bool read)
{
    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)if(frames[i].used && frames[i].leased) {
        PerpBrokerHeader *h=&frames[i].header;
        if(h->resource_id==lease->resource_id && h->context_id==lease->context_id && h->worker_epoch==lease->worker_epoch &&
           h->resource_epoch==lease->resource_epoch && h->snapshot_generation==lease->generation) {
            LiveWorker *w=worker(h->context_id);
            if(w && w->epoch==h->worker_epoch && h->status>w->retired_batch)w->retired_batch=h->status;
            retire(&frames[i],read);
            /* Nonselected candidates are not inferred to be backbuffers.
             * Cancel only immutable snapshots whose real token is ready. */
            for(unsigned j=0;j<LIVE_MAX_CANDIDATES;j++)if(frames[j].used && !frames[j].leased && frames[j].header.resource_id!=selected && ready(&frames[j]))retire(&frames[j],false);
            return;
        }
    }
}
void perp_live_renderer_reset(void)
{
    for(unsigned i=0;i<MAX_CONTEXTS;i++)if(workers[i].id)perp_live_context_stop(workers[i].id);
    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)if(frames[i].used && !frames[i].leased) {close_rights(frames[i].fds,2);memset(&frames[i],0,sizeof(frames[i]));}
    selected=active=0;permanently_failed=false;
}
char *perp_live_scanout_stats(void)
{
    unsigned pending=0;for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++)pending+=frames[i].used;
    char *result=NULL;asprintf(&result,"{\"received\":%llu,\"completed\":%llu,\"cancelled\":%llu,\"rejected\":%llu,\"pending\":%u,\"selected\":%u,\"active_context\":%u,\"peak_snapshot_bytes\":%llu,\"max_pending\":%llu,\"closed\":%s}",
        (unsigned long long)received,(unsigned long long)completed,(unsigned long long)cancelled,(unsigned long long)rejected,pending,selected,active,
        (unsigned long long)peak_bytes,(unsigned long long)max_pending,permanently_failed?"true":"false");return result;
}
