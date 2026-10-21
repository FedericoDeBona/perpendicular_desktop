/* SPDX-License-Identifier: MIT
 * One check of the actual broker: admission refusal leaves healthy slots intact.
 * No server, guest or GPU is started. The attach sink only counts messages.
 */
#include "proxy-broker.c"
#include <assert.h>
static unsigned attachments;
bool proxy_socket_send_request_with_fds(struct proxy_socket *socket,
                                        const void *bytes,size_t count,
                                        const int *fds,int fd_count)
{
    (void)socket;(void)bytes;(void)count;(void)fds;(void)fd_count;
    attachments++;
    return true;
}
int main(void)
{
    setenv("PERP_NEPTUNE_SCANOUT_BROKER","1",1);
    struct proxy_socket control={0};
    for(unsigned i=1;i<=MAX_CONTEXTS;i++)
        assert(perp_live_context_start(i,7,&control));
    active=1;
    LiveWorker before[MAX_CONTEXTS];memcpy(before,workers,sizeof(before));
    uint64_t epoch=worker_epoch;
    assert(!perp_live_context_can_start(MAX_CONTEXTS+1,7));
    assert(!perp_live_context_start(MAX_CONTEXTS+1,7,&control));
    assert(!perp_live_context_can_start(1,7));
    assert(!perp_live_context_can_start(0,7));
    assert(!permanently_failed && active==1 && worker_epoch==epoch);
    assert(attachments==MAX_CONTEXTS && !memcmp(before,workers,sizeof(before)));
    perp_live_context_stop(1,true);
    assert(perp_live_context_can_start(MAX_CONTEXTS+1,7));
    assert(perp_live_context_start(MAX_CONTEXTS+1,7,&control));
    assert(worker(MAX_CONTEXTS+1)->epoch>epoch && !permanently_failed);
    for(unsigned i=2;i<=MAX_CONTEXTS+1;i++)perp_live_context_stop(i,true);
    puts("Full broker refuses admission without changing healthy contexts; confirmed retirement permits a new epoch.");
}
