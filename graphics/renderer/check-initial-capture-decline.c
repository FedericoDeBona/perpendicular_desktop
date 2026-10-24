/* SPDX-License-Identifier: MIT
 * Actual broker transitions: initial unsupported capture preserves rendering;
 * stale identity and any prior snapshot budget still fail closed.
 */
#include "proxy-broker.c"
#include <assert.h>
static unsigned controls;
static int peers[MAX_CONTEXTS];
bool proxy_socket_send_request_with_fds(struct proxy_socket *socket,
                                        const void *bytes,size_t count,
                                        const int *fds,int fd_count)
{
    (void)socket;(void)count;
    const PerpBrokerHeader *h=bytes;
    if(h->kind==LIVE_ATTACH && fd_count==1)peers[h->context_id-1]=dup(fds[0]);
    controls++;return true;
}
static PerpBrokerHeader unavailable(LiveWorker *w)
{
    return (PerpBrokerHeader){.magic=PERP_BROKER_MAGIC,.version=3,
        .kind=LIVE_UNSUPPORTED,.bytes=sizeof(PerpBrokerHeader),
        .session=session,.worker_epoch=w->epoch,.context_id=w->id,
        .status=LIVE_UNSUPPORTED_MULTI_RING};
}
int main(void)
{
    setenv("PERP_NEPTUNE_SCANOUT_BROKER","1",1);
    struct proxy_socket control={0};
    assert(perp_live_context_start(1,7,&control));
    assert(perp_live_context_start(2,7,&control));
    LiveWorker *first=worker(1),*second=worker(2);
    first->hello=first->enabled=true;active=1;
    PerpBrokerHeader h=unavailable(first);
    assert(accept_message(first,&h,NULL));
    assert(first->capture_unsupported && !first->enabled && !first->bad);
    assert(!active && !permanently_failed);
    assert(accept_message(first,&h,NULL)); /* Idempotent, still no budget. */
    assert(perp_live_before_commands(1));
    perp_live_resource_created(10,1,20,4096);selected=10;
    unsigned sent=controls;perp_live_scanout_pump();
    assert(controls==sent && !active);
    assert(!first->bad && !second->bad && !permanently_failed);
    assert(perp_live_context_start(3,7,&control));
    second->hello=second->enabled=true;active=2;h=unavailable(second);
    h.worker_epoch++;
    assert(!accept_message(second,&h,NULL));
    h=unavailable(second);second->capture_seen=true;
    assert(!accept_message(second,&h,NULL));
    second->capture_seen=false;second->pool.allocations=1;
    assert(!accept_message(second,&h,NULL));
    assert(second->enabled && !second->capture_unsupported && active==2);
    second->pool.allocations=0;second->revoking=true;
    assert(accept_message(second,&h,NULL)); /* Revoke already queued after ENABLE. */
    h.kind=LIVE_REVOKED;h.status=0;
    assert(accept_message(second,&h,NULL));
    assert(second->capture_unsupported && !second->enabled && !second->revoking && !active);
    assert(!permanently_failed);
    for(unsigned i=1;i<=3;i++) {perp_live_context_stop(i,true);close(peers[i-1]);}
    puts("Initial capture unavailability preserves rendering and new contexts; stale identity and prior budget are rejected.");
}
