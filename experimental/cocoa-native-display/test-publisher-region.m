/* SPDX-License-Identifier: MIT
 * Actual Metal crop/completion/immutability check; no drawable or guest. */
#define main original_publisher_fixture_main
#include "test-publisher.m"
#undef main
#include <stdatomic.h>

static void seed_pattern(id<MTLCommandQueue> queue, id<MTLTexture> target) {
    const NSUInteger pitch = 256;
    id<MTLBuffer> upload = [queue.device newBufferWithLength:pitch * target.height
        options:MTLResourceStorageModeShared];
    check(upload != nil, "pattern staging");
    uint8_t *bytes = upload.contents;
    for (NSUInteger y=0; y<target.height; y++) for (NSUInteger x=0; x<target.width; x++) {
        uint8_t *p = bytes + y*pitch + x*4;
        p[0] = 9 + 17*x; p[1] = 11 + 23*y; p[2] = 3*x + 5*y; p[3] = 255;
    }
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    [encoder copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:pitch sourceBytesPerImage:pitch*target.height
        sourceSize:MTLSizeMake(target.width,target.height,1) toTexture:target destinationSlice:0
        destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
    check(command.status == MTLCommandBufferStatusCompleted, "pattern GPU upload");
}
static uint64_t verify_crop(ndt_frame *frame, unsigned ox, unsigned oy, unsigned width, unsigned height) {
    check(frame->metadata.width == width && frame->metadata.height == height && frame->metadata.offset == 0,
          "cropped metadata geometry");
    const uint8_t *bytes = mmap(NULL, frame->memory_extent, PROT_READ, MAP_SHARED, frame->memory_fd, 0);
    check(bytes != MAP_FAILED, "crop consumer mmap");
    for (unsigned y=0; y<height; y++) for (unsigned x=0; x<width; x++) {
        const uint8_t *p = bytes + y*frame->metadata.pitch + x*4;
        check(p[0] == 9+17*(x+ox) && p[1] == 11+23*(y+oy) &&
              p[2] == 3*(x+ox)+5*(y+oy) && p[3] == 255, "exact nonzero crop pixel mismatch");
    }
    check(munmap((void *)bytes, frame->memory_extent) == 0, "crop consumer munmap");
    return width*height;
}
static int region_consumer(const char *path, pid_t server, int input, int output) {
    ndt_connection connection;
    int rc = ndt_client_start(&connection,path,geteuid(),server,session_hi,session_lo,1);
    check(rc == NDT_OK || rc == NDT_AGAIN, "region client start");
    for (unsigned i=0;i<30;i++) { pump(&connection); usleep(1000); }
    notify(output,'C'); control(input,'W');
    for (unsigned i=0;i<100;i++) {
        pump(&connection); ndt_frame frame;
        check(ndt_take_frame(&connection,&frame) == NDT_AGAIN, "region published before GPU completion");
        usleep(1000);
    }
    notify(output,'w');
    ndt_frame a = receive(&connection);
    uint64_t pixels = verify_crop(&a,3,2,5,4); notify(output,'A'); control(input,'O');
    pixels += verify_crop(&a,3,2,5,4); notify(output,'o');
    ndt_frame b = receive(&connection); pixels += verify_crop(&b,6,5,5,3);
    notify(output,'B'); control(input,'D');
    for (unsigned i=0;i<50;i++) {
        pump(&connection); ndt_frame frame;
        check(ndt_take_frame(&connection,&frame) == NDT_AGAIN, "region exceeded snapshot budget");
        usleep(1000);
    }
    acknowledge(&connection,&a); notify(output,'a');
    ndt_frame c = receive(&connection); pixels += verify_crop(&c,10,7,1,1);
    acknowledge(&connection,&b);
    for (unsigned i=0;i<20;i++) { pump(&connection); usleep(1000); }
    acknowledge(&connection,&c); notify(output,'E'); control(input,'e');
    ndt_close(&connection); close(input); close(output);
    printf("{\"region_consumer\":\"pass\",\"frames\":3,\"exact_crop_pixels\":%llu}\n",(unsigned long long)pixels);
    return 0;
}
static id<MTLCommandBuffer> crop(id<MTLCommandQueue> queue, id<MTLTexture> source,
    MTLOrigin origin, MTLSize size, id<MTLSharedEvent> gate) {
    id<MTLCommandBuffer> command = [queue commandBuffer];
    if (gate) [command encodeWaitForEvent:gate value:1];
    check(perp_native_display_capture_region(command,source,origin,size) == PND_CAPTURE_ENCODED,
          "region capture encoded");
    [command commit];
    if (!gate) { [command waitUntilCompleted]; check(command.status == MTLCommandBufferStatusCompleted,"region GPU complete"); }
    return command;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1],"--direct-flag")) {
            printf("{\"direct\":%s}\n",perp_native_display_direct() ? "true" : "false"); return 0;
        }
        if (argc == 6 && !strcmp(argv[1],"--region-consumer"))
            return region_consumer(argv[2],(pid_t)atoi(argv[3]),atoi(argv[4]),atoi(argv[5]));
        check(argc == 1,"region arguments");
        char directory[104];
        snprintf(directory,sizeof(directory),"%s",getenv("PERP_REGION_TEST_RUNTIME") ?: "/tmp/pnregion-XXXXXX");
        check(mkdtemp(directory) != NULL,"region private runtime");
        setenv("PERP_NATIVE_DISPLAY_DIR",directory,1);
        setenv("PERP_NATIVE_DISPLAY_SESSION","f123456789abcdef123456789abcdef1",1);
        setenv("PERP_NATIVE_DISPLAY_DIRECT","1",1);
        check(perp_native_display_direct(),"explicit direct mode");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); check(device != nil,"region Metal device");
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLTexture> source = texture(device,11,8); seed_pattern(queue,source);
        check(perp_native_display_enabled() && !perp_native_display_can_capture(),"no consumer admission");
        check(perp_native_display_capture_region(nil,source,MTLOriginMake(0,0,0),MTLSizeMake(1,1,1)) ==
              PND_CAPTURE_UNAVAILABLE,"unavailable result");
        int to_child[2],from_child[2]; check(pipe(to_child)==0 && pipe(from_child)==0,"region control pipes");
        char path[104],pid_text[32],read_text[32],write_text[32];
        check(snprintf(path,sizeof(path),"%s/native-display.sock",directory) < (int)sizeof(path),"region path");
        snprintf(pid_text,sizeof(pid_text),"%d",getpid());
        snprintf(read_text,sizeof(read_text),"%d",to_child[0]); snprintf(write_text,sizeof(write_text),"%d",from_child[1]);
        posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addclose(&actions,to_child[1]); posix_spawn_file_actions_addclose(&actions,from_child[0]);
        char *arguments[] = {argv[0],"--region-consumer",path,pid_text,read_text,write_text,NULL}; pid_t child;
        check(posix_spawn(&child,argv[0],&actions,NULL,arguments,environ)==0,"spawn crop verifier");
        posix_spawn_file_actions_destroy(&actions); close(to_child[0]); close(from_child[1]);
        control(from_child[0],'C'); check(perp_native_display_can_capture(),"connected admission");
        id<MTLCommandBuffer> invalid = [queue commandBuffer];
        MTLOrigin origins[] = {{0,0,0},{NSUIntegerMax,0,0},{0,NSUIntegerMax,0},{0,0,1},{10,7,0},{0,0,0},{0,0,0},{0,0,0}};
        MTLSize sizes[] = {{0,1,1},{1,1,1},{1,1,1},{1,1,1},{2,1,1},{1,1,2},{NSUIntegerMax,1,1},{12,8,1}};
        for (unsigned i=0;i<sizeof(origins)/sizeof(origins[0]);i++)
            check(perp_native_display_capture_region(invalid,source,origins[i],sizes[i]) == PND_CAPTURE_INVALID,"invalid crop accepted");
        check(perp_native_display_capture_region(nil,source,MTLOriginMake(0,0,0),MTLSizeMake(1,1,1)) == PND_CAPTURE_INVALID,"nil command accepted");
        check(perp_native_display_capture_region(invalid,nil,MTLOriginMake(0,0,0),MTLSizeMake(1,1,1)) == PND_CAPTURE_INVALID,"nil source accepted");
        MTLTextureDescriptor *rgba = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:11 height:8 mipmapped:NO];
        id<MTLTexture> wrong = [device newTextureWithDescriptor:rgba];
        check(perp_native_display_capture_region(invalid,wrong,MTLOriginMake(0,0,0),MTLSizeMake(1,1,1)) == PND_CAPTURE_INVALID,"wrong format accepted");
        [invalid commit]; [invalid waitUntilCompleted];
        check(perp_native_display_capture_region(invalid,source,MTLOriginMake(0,0,0),MTLSizeMake(1,1,1)) == PND_CAPTURE_INVALID,"committed command accepted");
        check([stats()[@"allocations"] unsignedIntValue] == 0 && perp_native_display_needs_refresh(),"invalid capture allocated/consumed demand");
        id<MTLSharedEvent> gate = [device newSharedEvent]; check(gate != nil,"crop completion gate");
        __block _Atomic unsigned done = 0;
        id<MTLCommandBuffer> first = [queue commandBuffer]; [first encodeWaitForEvent:gate value:1];
        check(perp_native_display_capture_region(first,source,MTLOriginMake(3,2,0),MTLSizeMake(5,4,1)) == PND_CAPTURE_ENCODED,"first crop encoded");
        [first addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            check(cb.status == MTLCommandBufferStatusCompleted, "crop completion status");
            atomic_fetch_add(&done,1);
        }]; [first commit];
        notify(to_child[1],'W'); control(from_child[0],'w');
        check(!atomic_load(&done) && [stats()[@"published"] unsignedIntValue] == 0,"crop completion before gate");
        gate.signaledValue = 1; control(from_child[0],'A'); [first waitUntilCompleted];
        check(atomic_load(&done)==1,"exact completion callback");
        draw(queue,source,MTLClearColorMake(1,0,1,1),NO,nil);
        notify(to_child[1],'O'); control(from_child[0],'o'); seed_pattern(queue,source);
        crop(queue,source,MTLOriginMake(6,5,0),MTLSizeMake(5,3,1),nil); control(from_child[0],'B');
        check(!perp_native_display_can_capture(),"full budget admission");
        id<MTLCommandBuffer> full = [queue commandBuffer];
        check(perp_native_display_capture_region(full,source,MTLOriginMake(10,7,0),MTLSizeMake(1,1,1)) == PND_CAPTURE_BACKPRESSURE,"full budget result");
        check([stats()[@"allocations"] unsignedIntValue] == 2,"full budget allocated");
        [full commit]; [full waitUntilCompleted];
        notify(to_child[1],'D'); control(from_child[0],'a'); wait_for("acknowledged",1); wait_for("occupied",1);
        check(perp_native_display_can_capture(),"ACK did not resume admission");
        crop(queue,source,MTLOriginMake(10,7,0),MTLSizeMake(1,1,1),nil);
        control(from_child[0],'E'); wait_for("acknowledged",3); wait_for("occupied",0);
        notify(to_child[1],'e'); int status;
        check(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0,"crop consumer exit");
        perp_native_display_shutdown();
        NSDictionary *result=stats();
        check([result[@"allocations"] unsignedIntValue]==3 && [result[@"releases"] unsignedIntValue]==3 &&
              [result[@"mappings"] isEqual:result[@"unmappings"]],"crop cleanup");
        close(to_child[1]); close(from_child[0]); check(rmdir(directory)==0,"crop runtime cleanup");
        printf("{\"region_producer\":\"pass\",\"gpu_gate\":true,\"immutable\":true,\"invalid_cases\":12,\"bounded_slots\":2,\"stats\":%s}\n",
            [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL] encoding:NSUTF8StringEncoding].UTF8String);
    }
    return 0;
}
