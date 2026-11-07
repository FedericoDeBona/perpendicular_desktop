/* SPDX-License-Identifier: MIT
 * Exercise lifetime-owned metadata and the actual retirement gate, without a VM or GPU.
 * The producer side is a control sink; its confirmation is supplied explicitly.
 */
#ifdef NDEBUG
#error "Active assertions required (-UNDEBUG)."
#endif
#include "proxy-broker.c"
#include <assert.h>
static bool ordinary_present=true;
struct virgl_resource *virgl_resource_lookup(uint32_t id) {return ordinary_present && id?(struct virgl_resource *)(uintptr_t)1:NULL;}
enum { CHECK_LIFETIMES=300 };
static int producer=-1;
static PerpBrokerHeader requested;
static unsigned denies;
bool proxy_socket_send_request_with_fds(struct proxy_socket *socket,
                                        const void *bytes,size_t count,
                                        const int *fds,int fd_count)
{
    (void)socket;assert(count==sizeof(PerpBrokerHeader));
    const PerpBrokerHeader *h=bytes;
    if(h->kind==LIVE_ATTACH) {assert(fd_count==1);producer=dup(fds[0]);assert(producer>=0);}
    if(h->kind==LIVE_RETIRE)requested=*h;
    if(h->kind==LIVE_DENY)denies++;
    return true;
}
int main(void)
{
    setenv("PERP_NEPTUNE_SCANOUT_BROKER","1",1);
    struct proxy_socket control={0};assert(perp_live_context_start(1,7,&control));
    LiveWorker *w=worker(1);assert(w);
    perp_live_resource_created(7,1,70,4096);
    uint64_t epoch=resource(7)->epoch;
    PerpBrokerHeader claim={.magic=PERP_BROKER_MAGIC,.version=3,.session=session,
        .worker_epoch=w->epoch,.context_id=1,.bytes=sizeof(claim),.kind=PERP_CLAIM,
        .status=1,.resource_id=7,.blob_id=70};
    assert(accept_message(w,&claim,NULL));
    PerpBrokerHeader exported=claim;exported.kind=PERP_EXPORT;exported.object_id=700;
    assert(accept_message(w,&exported,NULL));
    PerpBrokerHeader reply=claim;reply.kind=LIVE_RETIRED;reply.resource_epoch=epoch;
    // An unsolicited or mismatched retirement cannot clear a live identity.
    assert(!accept_message(w,&reply,NULL) && resource(7)->epoch==epoch);
    perp_live_resource_destroy(7);collect_resources();
    assert(resource(7)->retiring && requested.resource_epoch==epoch);
    reply=requested;reply.kind=LIVE_RETIRED;
    reply.resource_epoch++;assert(!accept_message(w,&reply,NULL));reply.resource_epoch=epoch;
    // A Mac lease must survive destruction, even if a producer confirms early.
    PerpBrokerHeader frame=reply;frame.snapshot_generation=1;frame.status=1;
    frames[0]=(LiveFrame){.used=true,.leased=true,.header=frame,.fds={-1,-1}};
    PerpLiveLease lease={.version=3,.resource_id=7,.context_id=1,.generation=1,
        .worker_epoch=w->epoch,.resource_epoch=epoch,.blob_id=70};
    assert(!accept_message(w,&reply,NULL) && leased_frame(&lease));
    perp_live_scanout_done(&lease,true);
    assert(!leased_frame(&lease) && accept_message(w,&reply,NULL));
    assert(!resource(7) && !w->claims[0].blob);
    for(unsigned i=0;i<LIVE_MAX_SOURCES;i++)assert(!w->claims[i].blob && !w->exports[i].blob);
    // Reuse the ID with a fresh epoch; an old confirmation must not alias it.
    perp_live_resource_created(7,1,71,4096);
    assert(resource(7)->epoch>epoch && !accept_message(w,&reply,NULL));
    // A first command from a formerly passive importer may overlap RETIRE.
    // Its proof is the exact retirement, never a DENY sent after claim removal.
    resource(7)->granted=true;
    perp_live_resource_destroy(7);collect_resources();reply=requested;reply.kind=LIVE_RETIRED;
    assert(send(producer,&reply,sizeof(reply),0)==sizeof(reply));
    assert(perp_live_before_import(2,7) && !resource(7) && !denies && !w->bad);
    // More lifetime registrations than table slots, with one live resource.
    for(unsigned i=0;i<=CHECK_LIFETIMES;i++) {
        perp_live_resource_created(i+10,1,i+100,4096);
        assert(resource(i+10) && !w->bad && !permanently_failed);
        perp_live_resource_destroy(i+10);collect_resources();reply=requested;reply.kind=LIVE_RETIRED;
        assert(accept_message(w,&reply,NULL));
    }
    assert(resource_peak==1 && resource_retirements==CHECK_LIFETIMES+3);
    // Two real owners can each stay below their existing 256-source contract
    // while the aggregate exceeds the old VM-global prototype table.
    int first=producer;
    assert(perp_live_context_start(2,7,&control));int second=producer;
    // The first command may retire the current and the next list nodes in
    // one receive. No pointer into those nodes may survive the revocation.
    for(unsigned i=0;i<2;i++) {
        perp_live_resource_created(7000+i,1,70000+i,4096);
        resource(7000+i)->granted=true;
        resource(7000+i)->passive_contexts=1u<<(unsigned)(worker(2)-workers);
        perp_live_resource_destroy(7000+i);collect_resources();
        reply=requested;reply.kind=LIVE_RETIRED;
        assert(send(first,&reply,sizeof(reply),0)==sizeof(reply));
    }
    assert(perp_live_before_commands(2) && !resource(7000) && !resource(7001));
    for(unsigned i=0;i<200;i++) {
        perp_live_resource_created(1000+i,1,10000+i,4096);
        perp_live_resource_created(2000+i,2,20000+i,4096);
    }
    assert(resource_live_count==400 && resource_peak==400);
    assert(!worker(1)->bad && !worker(2)->bad && !permanently_failed);
    perp_live_context_stop(2,true);close(second);
    assert(resource_live_count==200 && !resource(2000) && resource(1000));
    // Every exact producer retirement frees its one metadata node.
    for(unsigned i=0;i<200;i++) {
        perp_live_resource_destroy(1000+i);collect_resources();reply=requested;reply.kind=LIVE_RETIRED;
        assert(accept_message(worker(1),&reply,NULL));
    }
    assert(!resources && resource_live_count==0);
    // Preserve the per-producer bound; no new capture/source budget is granted.
    for(unsigned i=0;i<LIVE_MAX_SOURCES;i++)perp_live_resource_created(3000+i,1,30000+i,4096);
    assert(resource_live_count==LIVE_MAX_SOURCES && !worker(1)->bad);
    perp_live_resource_created(4000,1,40000,4096);
    assert(worker(1)->bad && !resource(4000) && !permanently_failed);
    perp_live_context_stop(1,true);close(first);
    assert(!resources && resource_live_count==0);
    assert(perp_live_context_start(3,7,&control));ordinary_present=false;
    perp_live_resource_created(5000,3,50000,4096);
    assert(worker(3)->bad && !resources && !resource_live_count);
    perp_live_context_stop(3,true);close(producer);
    puts("Lifetime metadata spans owners, keeps producer bounds and exact retirement/leases, rejects stale epochs and absent ordinary resources.");
}
