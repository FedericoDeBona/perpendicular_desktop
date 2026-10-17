/* SPDX-License-Identifier: MIT
 * Real Metal-produced shared backing -> external ready lease -> owned process.
 * Source destruction after disconnect models abandoning a worker allocation. */
#define main original_publisher_fixture_main
#include "test-publisher.m"
#undef main
#include <stdatomic.h>

static _Atomic unsigned provider_acked, provider_abandoned, provider_released;
@interface ExternalSource : NSObject {
@public
    int fd, ready[2]; void *mapping;
    id<MTLBuffer> buffer; id<MTLTexture> image;
    BOOL retired;
}
- (instancetype)initWithQueue:(id<MTLCommandQueue>)queue color:(MTLClearColor)color;
@end
@implementation ExternalSource
- (instancetype)initWithQueue:(id<MTLCommandQueue>)queue color:(MTLClearColor)color {
    if (!(self = [super init])) return nil;
    fd = ready[0] = ready[1] = -1; mapping = MAP_FAILED;
    char name[] = "/tmp/pnext-source-XXXXXX";
    fd = mkstemp(name); check(fd >= 0, "external source file"); unlink(name);
    check(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && ftruncate(fd, 16384) == 0, "external source extent");
    mapping = mmap(NULL, 16384, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    check(mapping != MAP_FAILED, "external source mapping");
    buffer = [queue.device newBufferWithBytesNoCopy:mapping length:16384 options:MTLResourceStorageModeShared deallocator:nil];
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:64 height:32 mipmapped:NO];
    desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    image = [buffer newTextureWithDescriptor:desc offset:0 bytesPerRow:256];
    check(image != nil, "external source texture");
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = image; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = color;
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
    check(command.status == MTLCommandBufferStatusCompleted, "external source real GPU completion");
    check(pipe(ready) == 0, "external producer-ready pipe");
    for (unsigned i=0; i<2; i++) check(fcntl(ready[i], F_SETFD, FD_CLOEXEC) == 0, "external ready CLOEXEC");
    return self;
}
- (void)dealloc {
    check(retired, "provider destroyed before retirement callback");
    image = nil; buffer = nil;
    if (mapping != MAP_FAILED) check(munmap(mapping, 16384) == 0, "external provider unmap");
    if (fd >= 0) close(fd);
    for (unsigned i=0; i<2; i++) if (ready[i] >= 0) close(ready[i]);
    atomic_fetch_add(&provider_released, 1);
}
@end

static ndt_metadata layout(void) {
    return (ndt_metadata){.width=64,.height=32,.pitch=256,.format=NDT_BGRA8,.size=8192};
}
static void publish_external(ExternalSource *source) {
    uint8_t value = 1; check(write(source->ready[1], &value, 1) == 1, "external producer readiness");
    ndt_metadata metadata = layout();
    check(perp_native_display_publish_ready(source->fd, source->ready[0], &metadata, ^(bool acknowledged) {
        source->retired = YES;
        if (acknowledged) atomic_fetch_add(&provider_acked, 1);
        else atomic_fetch_add(&provider_abandoned, 1);
    }), "external lease accepted");
}
static void wait_provider(unsigned ack, unsigned abandon, unsigned released) {
    double end = now() + 5;
    while (now() < end) {
        if (atomic_load(&provider_acked) == ack && atomic_load(&provider_abandoned) == abandon &&
            atomic_load(&provider_released) == released) return;
        usleep(1000);
    }
    check(NO, "external retirement counters");
}
static void connect_external(ndt_connection *c, const char *path, pid_t server) {
    int rc = ndt_client_start(c, path, geteuid(), server, session_hi, session_lo, 1);
    check(rc == NDT_OK || rc == NDT_AGAIN, "external consumer connect");
    for (unsigned i=0; i<30; i++) { pump(c); usleep(1000); }
}
static int external_consumer(const char *path, pid_t server, int input, int output) {
    ndt_connection c; connect_external(&c, path, server); notify(output, 'C'); control(input, 'W');
    for (unsigned i=0; i<100; i++) {
        pump(&c); ndt_frame unexpected;
        check(ndt_take_frame(&c, &unexpected) == NDT_AGAIN, "external unready lease was published"); usleep(1000);
    }
    notify(output, 'w');
    ndt_frame red = receive(&c); uint64_t pixels = verify(&red,64,32,0,0,255);
    acknowledge(&c, &red);
    for (unsigned i=0; i<30; i++) { pump(&c); usleep(1000); }
    notify(output, 'A');
    ndt_frame old = receive(&c); pixels += verify(&old,64,32,0,255,0);
    ndt_close(&c); notify(output, 'D'); control(input, 'B');
    connect_external(&c, path, server); notify(output, 'C');
    ndt_frame fresh = receive(&c); pixels += verify(&fresh,64,32,255,0,0);
    pixel_mismatch = "external abandoned backing was rewritten";
    pixels += verify(&old,64,32,0,255,0); // provider object/FD/map already destroyed
    ndt_frame_close(&old); acknowledge(&c, &fresh);
    for (unsigned i=0; i<30; i++) { pump(&c); usleep(1000); }
    ndt_close(&c); notify(output, 'Z'); close(input); close(output);
    printf("{\"external_consumer\":\"pass\",\"exact_pixels\":%llu,\"connections\":2}\n", (unsigned long long)pixels);
    return 0;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 6 && !strcmp(argv[1], "--external-consumer"))
            return external_consumer(argv[2], (pid_t)atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
        check(argc == 1, "external producer arguments");
        char directory[104];
        check(strlcpy(directory,getenv("PERP_EXTERNAL_TEST_RUNTIME") ?: "/tmp/pnext-XXXXXX",sizeof(directory)) < sizeof(directory),"external runtime length");
        check(mkdtemp(directory) != NULL, "external runtime");
        setenv("PERP_NATIVE_DISPLAY_DIR",directory,1);
        setenv("PERP_NATIVE_DISPLAY_SESSION","f123456789abcdef123456789abcdef1",1);
        check(perp_native_display_enabled(), "external publisher");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue]; check(queue != nil, "external Metal queue");
        int to_child[2], from_child[2]; check(pipe(to_child) == 0 && pipe(from_child) == 0, "external control pipes");
        char path[104], pid_text[24], read_text[24], write_text[24];
        snprintf(path,sizeof(path),"%s/native-display.sock",directory);
        snprintf(pid_text,sizeof(pid_text),"%d",getpid());
        snprintf(read_text,sizeof(read_text),"%d",to_child[0]); snprintf(write_text,sizeof(write_text),"%d",from_child[1]);
        posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addclose(&actions,to_child[1]); posix_spawn_file_actions_addclose(&actions,from_child[0]);
        char *arguments[] = {argv[0],"--external-consumer",path,pid_text,read_text,write_text,NULL}; pid_t child;
        check(posix_spawn(&child,argv[0],&actions,NULL,arguments,environ) == 0,"external verifier spawn");
        posix_spawn_file_actions_destroy(&actions); close(to_child[0]); close(from_child[1]); control(from_child[0],'C');
        @autoreleasepool {
            ExternalSource *red = [[ExternalSource alloc] initWithQueue:queue color:MTLClearColorMake(1,0,0,1)];
            ndt_metadata metadata = layout();
            check(!perp_native_display_publish_ready(red->fd,red->ready[0],&metadata,^(bool value) {
                (void)value; check(NO,"rejected call invoked retirement");
            }),"unready external lease accepted");
            uint8_t ready = 1;
            check(write(red->ready[1], &ready, 1) == 1, "layout control producer ready");
            metadata.height = NDT_MAX_DIMENSION + 1;
            check(!perp_native_display_publish_ready(red->fd,red->ready[0],&metadata,^(bool value) {
                (void)value; check(NO,"invalid layout invoked retirement");
            }),"invalid external layout accepted");
            metadata = layout(); metadata.offset = 4;
            check(!perp_native_display_publish_ready(red->fd,red->ready[0],&metadata,^(bool value) {
                (void)value; check(NO,"invalid offset invoked retirement");
            }),"nonzero external offset accepted");
            metadata = layout(); metadata.size--;
            check(!perp_native_display_publish_ready(red->fd,red->ready[0],&metadata,^(bool value) {
                (void)value; check(NO,"invalid logical size invoked retirement");
            }),"invalid external logical size accepted");
            notify(to_child[1],'W'); control(from_child[0],'w');
            publish_external(red);
        }
        control(from_child[0],'A'); wait_provider(1,0,1);
        int unsafe_fd = -1;
        @autoreleasepool {
            ExternalSource *green = [[ExternalSource alloc] initWithQueue:queue color:MTLClearColorMake(0,1,0,1)];
            if (getenv("PERP_EXTERNAL_UNSAFE_REUSE")) {
                unsafe_fd = dup(green->fd); check(unsafe_fd >= 0,"unsafe private control FD");
            }
            publish_external(green);
        }
        control(from_child[0],'D'); wait_provider(1,1,2);
        notify(to_child[1],'B'); control(from_child[0],'C');
        @autoreleasepool {
            ExternalSource *blue = [[ExternalSource alloc] initWithQueue:queue color:MTLClearColorMake(0,0,1,1)];
            if (unsafe_fd >= 0) {
                /* Deliberate test-only violation after the original provider
                 * object is gone. The old consumer still owns its mapping. */
                uint8_t *old = mmap(NULL,16384,PROT_READ|PROT_WRITE,MAP_SHARED,unsafe_fd,0);
                check(old != MAP_FAILED,"unsafe private mapping");
                for (unsigned i=0;i<8192;i+=4) { old[i]=255; old[i+1]=old[i+2]=0; old[i+3]=255; }
                check(munmap(old,16384) == 0,"unsafe control unmap"); close(unsafe_fd);
            }
            publish_external(blue);
        }
        control(from_child[0],'Z'); wait_provider(2,1,3);
        int status; check(waitpid(child,&status,0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,"external verifier exit");
        perp_native_display_shutdown();
        char *stats = perp_native_display_stats();
        printf("{\"external_producer\":\"pass\",\"provider_acked\":%u,\"provider_abandoned\":%u,\"provider_released\":%u,\"stats\":%s}\n",
            atomic_load(&provider_acked),atomic_load(&provider_abandoned),atomic_load(&provider_released),stats); free(stats);
        close(to_child[1]); close(from_child[0]); check(rmdir(directory) == 0,"external runtime cleanup");
        return 0;
    }
}
