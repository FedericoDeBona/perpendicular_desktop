/* SPDX-License-Identifier: MIT
 * Actual broker, one producer and two scanout resources. Pipes stand in for
 * GPU completion events; no VM, rendering or completion is simulated as fact.
 */
#ifdef NDEBUG
#error "This check requires active assertions (-UNDEBUG after build flags)."
#endif
#include "proxy-broker.c"
#include <assert.h>
static int producer=-1;
static unsigned acknowledgements;
bool proxy_socket_send_request_with_fds(struct proxy_socket *socket,
                                        const void *bytes,size_t count,
                                        const int *fds,int fd_count)
{
    (void)socket;assert(count==sizeof(PerpBrokerHeader));
    const PerpBrokerHeader *h=bytes;
    if(h->kind==LIVE_ATTACH) {assert(fd_count==1);producer=dup(fds[0]);assert(producer>=0);}
    if(h->kind==PERP_ACK) {assert(h->status==1 || h->status==0);acknowledgements++;}
    return true;
}
static int put_frame(unsigned slot,uint32_t id,unsigned generation,bool leased,bool signalled)
{
    LiveResource *r=resource(id);assert(r);
    int event[2];assert(!pipe(event));
    if(signalled)assert(write(event[1],"x",1)==1);
    frames[slot]=(LiveFrame){.used=true,.leased=leased,.received=now(),
        .fds={open("/dev/zero",O_RDONLY),event[0]},
        .header={.context_id=r->context,.worker_epoch=r->worker_epoch,
            .resource_id=id,.resource_epoch=r->epoch,.blob_id=r->blob,
            .snapshot_generation=generation,.status=generation}};
    assert(frames[slot].fds[0]>=0);
    return event[1];
}
int main(void)
{
    setenv("PERP_NEPTUNE_SCANOUT_BROKER","1",1);
    struct proxy_socket control={0};assert(perp_live_context_start(1,7,&control));
    LiveWorker *w=worker(1);assert(w);w->hello=w->enabled=true;active=1;
    perp_live_resource_created(7,1,70,4096);
    perp_live_resource_created(8,1,80,4096);
    w->exports[0]=(LiveExport){.resource=7,.blob=70,.object=700};
    w->exports[1]=(LiveExport){.resource=8,.blob=80,.object=800};
    resource(7)->granted=resource(8)->granted=true;
    w->capture_resource=7;assert(perp_live_scanout_select(7));
    int a=put_frame(0,7,1,false,true),b=put_frame(1,7,2,false,true);
    assert(perp_live_scanout_select(8));perp_live_scanout_pump();
    // Changing resource on the same worker must not retain unusable old copies.
    assert(!frames[0].used && !frames[1].used && acknowledgements==2);
    close(a);close(b);
    a=put_frame(0,7,3,true,true);b=put_frame(1,7,4,false,false);
    perp_live_scanout_pump();
    assert(frames[0].used && frames[0].leased && frames[1].used && acknowledgements==2);
    assert(write(b,"x",1)==1);perp_live_scanout_pump();
    assert(frames[0].used && !frames[1].used && acknowledgements==3);
    // Exact leased identities survive selection changes until consumer release.
    PerpLiveLease held={.version=3,.resource_id=7,.context_id=1,.generation=3,
        .worker_epoch=w->epoch,.resource_epoch=resource(7)->epoch,.blob_id=70};
    assert(leased_frame(&held));perp_live_scanout_done(&held,false);
    assert(!frames[0].used && acknowledgements==4);close(a);close(b);
    a=put_frame(0,8,5,false,true);perp_live_scanout_pump();
    assert(frames[0].used && acknowledgements==4);
    PerpLiveLease current;assert(perp_live_scanout_take(8,&current));
    perp_live_scanout_done(&current,true);close(current.memory_fd);close(a);
    assert(acknowledgements==5 && !permanently_failed && !w->bad);
    perp_live_context_stop(1,true);close(producer);
    puts("Selection releases only completed unleased old resources; current frames and exact leases survive.");
}
