/* SPDX-License-Identifier: MIT
 * Two owned processes and actual Metal work. The consumer reads pixels only
 * for this diagnostic; the publisher's production path performs no readback. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "publisher.h"
#include "ndt.h"
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <spawn.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
extern char **environ;

static const uint64_t session_hi = 0xf123456789abcdefULL;
static const uint64_t session_lo = 0x123456789abcdef1ULL;
static const char *pixel_mismatch = "GPU snapshot pixel mismatch";
static void check(BOOL value, const char *message) {
    if (!value) {
        char *raw = perp_native_display_stats();
        fprintf(stderr, "publisher fixture pid=%d: %s; stats=%s\n", getpid(), message, raw);
        free(raw); exit(1);
    }
}
static double now(void) { return [NSDate timeIntervalSinceReferenceDate]; }
static void notify(int fd, char value) { check(write(fd, &value, 1) == 1, "control write"); }
static void control(int fd, char expected) {
    struct pollfd p = {.fd=fd, .events=POLLIN};
    check(poll(&p, 1, 5000) == 1 && (p.revents & POLLIN), "control timeout");
    char value; check(read(fd, &value, 1) == 1 && value == expected, "control phase mismatch");
}
static void pump(ndt_connection *connection) {
    int result = ndt_pump(connection);
    check(result == NDT_OK || result == NDT_AGAIN, "transport pump");
}
static ndt_frame receive(ndt_connection *connection) {
    double end = now() + 5;
    ndt_frame frame;
    while (now() < end) {
        pump(connection);
        if (ndt_take_frame(connection, &frame) == NDT_OK) {
            check(ndt_ready(frame.ready_fd) == NDT_OK, "published before producer completion");
            return frame;
        }
        usleep(1000);
    }
    check(NO, "frame timeout"); return (ndt_frame){0};
}
static uint64_t verify(ndt_frame *frame, unsigned width, unsigned height,
                       uint8_t blue, uint8_t green, uint8_t red) {
    check(frame->metadata.width == width && frame->metadata.height == height, "frame geometry");
    uint8_t *mapped = mmap(NULL, frame->memory_extent, PROT_READ, MAP_SHARED, frame->memory_fd, 0);
    check(mapped != MAP_FAILED, "consumer mmap");
    for (unsigned y = 0; y < height; y++) for (unsigned x = 0; x < width; x++) {
        const uint8_t *pixel = mapped + y * frame->metadata.pitch + x * 4;
        check(pixel[0] == blue && pixel[1] == green && pixel[2] == red && pixel[3] == 255,
              pixel_mismatch);
    }
    check(munmap(mapped, frame->memory_extent) == 0, "consumer munmap");
    return (uint64_t)width * height;
}
static void acknowledge(ndt_connection *connection, ndt_frame *frame) {
    ndt_identity identity = frame->metadata.id;
    /* All reads above have ended; no GPU work exists in this CPU verifier. */
    ndt_frame_close(frame);
    double end = now() + 5;
    int result;
    do {
        pump(connection);
        result = ndt_queue_ack(connection, &identity);
        if (result == NDT_AGAIN) usleep(1000);
    } while (result == NDT_AGAIN && now() < end);
    check(result == NDT_OK, "ACK queue"); pump(connection);
}
static int consumer(const char *path, pid_t server, int read_control, int write_control) {
    ndt_connection connection;
    int result = ndt_client_start(&connection, path, geteuid(), server, session_hi, session_lo, 1);
    check(result == NDT_OK || result == NDT_AGAIN, "client start");
    for (unsigned i=0; i<30; i++) { pump(&connection); usleep(1000); }
    notify(write_control, 'C');
    control(read_control, 'W');
    for (unsigned i=0; i<100; i++) {
        pump(&connection); ndt_frame unexpected;
        check(ndt_take_frame(&connection, &unexpected) == NDT_AGAIN, "withheld GPU work was published");
        usleep(1000);
    }
    notify(write_control, 'w');
    ndt_frame a = receive(&connection);
    uint64_t pixels = verify(&a, 800, 600, 0, 0, 255);
    notify(write_control, 'A'); control(read_control, 'O');
    pixels += verify(&a, 800, 600, 0, 0, 255);
    notify(write_control, 'o');
    ndt_frame b = receive(&connection);
    pixels += verify(&b, 803, 607, 0, 255, 0);
    notify(write_control, 'B'); control(read_control, 'D');
    for (unsigned i=0; i<100; i++) {
        pump(&connection); ndt_frame unexpected;
        check(ndt_take_frame(&connection, &unexpected) == NDT_AGAIN, "two-slot budget exceeded");
        usleep(1000);
    }
    acknowledge(&connection, &a); notify(write_control, 'a');
    control(read_control, 'G');
    for (unsigned i=0; i<100; i++) {
        pump(&connection); ndt_frame unexpected;
        check(ndt_take_frame(&connection, &unexpected) == NDT_AGAIN, "reused backing bypassed new GPU gate");
        usleep(1000);
    }
    notify(write_control, 'g');
    ndt_frame c = receive(&connection);
    pixels += verify(&c, 800, 600, 255, 0, 0);
    acknowledge(&connection, &b);
    /* Pump the first ACK before using the single transmit-record slot again. */
    for (unsigned i=0; i<20; i++) { pump(&connection); usleep(1000); }
    acknowledge(&connection, &c); notify(write_control, 'E');
    control(read_control, 'e');
    for (unsigned i=0; i<32; i++) {
        ndt_frame next = receive(&connection);
        pixels += verify(&next, 800, 600, (i & 1) ? 0 : 255, 0, (i & 1) ? 255 : 0);
        acknowledge(&connection, &next); notify(write_control, 'F');
    }
    for (unsigned i=0; i<3; i++) {
        ndt_frame next = receive(&connection);
        pixels += verify(&next, i < 2 ? 809 : 800, i < 2 ? 611 : 600, 0, 255, 0);
        acknowledge(&connection, &next); notify(write_control, 'F');
    }
    /* Keep this exported allocation after disconnect, without ACK. A new
     * connection's blue snapshot must never rewrite the old red snapshot. */
    ndt_frame held = receive(&connection);
    pixels += verify(&held, 800, 600, 0, 0, 255);
    notify(write_control, 'H'); control(read_control, 'R');
    double end = now() + 5;
    do { result = ndt_pump(&connection); usleep(1000); }
    while ((result == NDT_OK || result == NDT_AGAIN) && now() < end);
    check(result == NDT_CLOSED, "pool reset did not disconnect");
    ndt_close(&connection);
    result = ndt_client_start(&connection, path, geteuid(), server, session_hi, session_lo, 1);
    check(result == NDT_OK || result == NDT_AGAIN, "pool reconnect");
    for (unsigned i=0; i<30; i++) { pump(&connection); usleep(1000); }
    notify(write_control, 'C');
    ndt_frame fresh = receive(&connection);
    check(fresh.metadata.id.frame > held.metadata.id.frame, "pool reused frame identity");
    pixels += verify(&fresh, 800, 600, 255, 0, 0);
    pixel_mismatch = "unacknowledged old snapshot changed after reconnect";
    pixels += verify(&held, 800, 600, 0, 0, 255);
    ndt_frame_close(&held);
    acknowledge(&connection, &fresh); notify(write_control, 'Z'); control(read_control, 'z');
    ndt_close(&connection); close(read_control); close(write_control);
    printf("{\"consumer\":\"pass\",\"frames\":40,\"exact_pixels_including_immutability_recheck\":%llu}\n",
           (unsigned long long)pixels);
    return 0;
}
static id<MTLTexture> texture(id<MTLDevice> device, unsigned width, unsigned height) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:width height:height mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate; desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> result = [device newTextureWithDescriptor:desc]; check(result != nil, "private console output"); return result;
}
static void draw(id<MTLCommandQueue> queue, id<MTLTexture> target, MTLClearColor color,
                 BOOL capture, id<MTLSharedEvent> gate) {
    @autoreleasepool {
        id<MTLCommandBuffer> command = [queue commandBuffer];
        if (gate) [command encodeWaitForEvent:gate value:1];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = color;
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        check(encoder != nil, "render encoder"); [encoder endEncoding];
        if (capture) perp_native_display_capture(command, target);
        [command commit];
        if (!gate) { [command waitUntilCompleted]; check(command.status == MTLCommandBufferStatusCompleted, "GPU completion"); }
    }
}
static NSDictionary *stats(void) {
    char *raw = perp_native_display_stats();
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)]; free(raw);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}
static void wait_for(const char *name, unsigned value) {
    double end = now() + 5; NSString *key = [NSString stringWithUTF8String:name];
    while (now() < end) { if ([stats()[key] unsignedIntValue] == value) return; usleep(1000); }
    check(NO, "publisher counter timeout");
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 6 && !strcmp(argv[1], "--consumer"))
            return consumer(argv[2], (pid_t)atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
        check(argc == 1, "unexpected arguments");
        char directory[104];
        const char *runtime = getenv("PERP_PUBLISHER_TEST_RUNTIME");
        check(strlcpy(directory, runtime ? runtime : "/tmp/perp-native-publisher-XXXXXX", sizeof(directory)) < sizeof(directory),
            "publisher test path too long");
        check(mkdtemp(directory) != NULL, "private runtime");
        setenv("PERP_NATIVE_DISPLAY_DIR", directory, 1);
        setenv("PERP_NATIVE_DISPLAY_SESSION", "f123456789abcdef123456789abcdef1", 1);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); check(device != nil, "Metal device");
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLTexture> first = texture(device, 800, 600), second = texture(device, 803, 607);
        id<MTLTexture> resized = texture(device, 809, 611);
        draw(queue, first, MTLClearColorMake(0,0,0,1), YES, nil); /* creates listener, no client yet */
        int to_child[2], from_child[2]; check(pipe(to_child) == 0 && pipe(from_child) == 0, "control pipes");
        char path[104], pid_text[32], read_text[32], write_text[32];
        snprintf(path, sizeof(path), "%s/native-display.sock", directory);
        snprintf(pid_text, sizeof(pid_text), "%d", getpid());
        snprintf(read_text, sizeof(read_text), "%d", to_child[0]); snprintf(write_text, sizeof(write_text), "%d", from_child[1]);
        posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addclose(&actions, to_child[1]); posix_spawn_file_actions_addclose(&actions, from_child[0]);
        char *arguments[] = {argv[0], "--consumer", path, pid_text, read_text, write_text, NULL}; pid_t child;
        check(posix_spawn(&child, argv[0], &actions, NULL, arguments, environ) == 0, "spawn verifier");
        posix_spawn_file_actions_destroy(&actions); close(to_child[0]); close(from_child[1]);
        control(from_child[0], 'C');
        id<MTLSharedEvent> gate = [device newSharedEvent]; check(gate != nil, "real producer gate");
        draw(queue, first, MTLClearColorMake(1,0,0,1), YES, gate);
        notify(to_child[1], 'W'); control(from_child[0], 'w');
        check([stats()[@"published"] unsignedIntValue] == 0, "publication before GPU gate");
        gate.signaledValue = 1; control(from_child[0], 'A');
        draw(queue, first, MTLClearColorMake(1,0,1,1), NO, nil);
        notify(to_child[1], 'O'); control(from_child[0], 'o');
        draw(queue, second, MTLClearColorMake(0,1,0,1), YES, nil); control(from_child[0], 'B');
        wait_for("occupied", 2);
        draw(queue, first, MTLClearColorMake(0,0,1,1), YES, nil);
        notify(to_child[1], 'D'); control(from_child[0], 'a'); wait_for("acknowledged", 1); wait_for("occupied", 1);
        id<MTLSharedEvent> reuse_gate = [device newSharedEvent]; check(reuse_gate != nil, "reuse GPU gate");
        draw(queue, first, MTLClearColorMake(0,0,1,1), YES, reuse_gate);
        notify(to_child[1], 'G'); control(from_child[0], 'g');
        check([stats()[@"published"] unsignedIntValue] == 2, "reused snapshot published before GPU gate");
        reuse_gate.signaledValue = 1;
        control(from_child[0], 'E'); wait_for("acknowledged", 3); wait_for("occupied", 0);
        notify(to_child[1], 'e');
        for (unsigned i=0; i<32; i++) {
            draw(queue, first, MTLClearColorMake((i & 1) ? 1 : 0, 0, (i & 1) ? 0 : 1, 1), YES, nil);
            control(from_child[0], 'F'); wait_for("acknowledged", 4+i); wait_for("occupied", 0);
        }
        check([stats()[@"backing_allocations"] unsignedIntValue] == 2 &&
            [stats()[@"backing_reuses"] unsignedIntValue] == 33, "steady frames did not reuse backing");
        for (unsigned i=0; i<3; i++) {
            draw(queue, i < 2 ? resized : first, MTLClearColorMake(0,1,0,1), YES, nil);
            control(from_child[0], 'F'); wait_for("acknowledged", 36+i); wait_for("occupied", 0);
        }
        check([stats()[@"backing_allocations"] unsignedIntValue] == 3 &&
            [stats()[@"backing_reuses"] unsignedIntValue] == 35, "resize cache did not replace idle mismatch");
        draw(queue, first, MTLClearColorMake(1,0,0,1), YES, nil); control(from_child[0], 'H');
        perp_native_display_reset(); wait_for("occupied", 0);
        notify(to_child[1], 'R'); control(from_child[0], 'C');
        double end = now() + 5;
        while (!perp_native_display_can_capture() && now() < end) usleep(1000);
        check(perp_native_display_can_capture(), "new pool generation admission");
        draw(queue, first, MTLClearColorMake(0,0,1,1), YES, nil);
        control(from_child[0], 'Z'); wait_for("acknowledged", 39); wait_for("occupied", 0);
        notify(to_child[1], 'z'); int status; check(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0, "consumer exit");
        perp_native_display_shutdown();
        NSDictionary *result = stats(); check([result[@"allocations"] isEqual:result[@"releases"]] &&
            [result[@"mappings"] isEqual:result[@"unmappings"]] && [result[@"published"] unsignedIntValue] == 40 &&
            [result[@"backing_allocations"] unsignedIntValue] == 4 &&
            [result[@"backing_allocations"] isEqual:result[@"backing_releases"]] &&
            [result[@"backing_reuses"] unsignedIntValue] == 36 && [result[@"cached_backings"] unsignedIntValue] == 0,
            "snapshot cleanup/count mismatch");
        close(to_child[1]); close(from_child[0]); check(rmdir(directory) == 0, "private runtime cleanup");
        printf("{\"producer\":\"pass\",\"gpu_gate\":true,\"immutable\":true,\"bounded_slots\":2,\"stats\":%s}\n",
            [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL] encoding:NSUTF8StringEncoding].UTF8String);
    }
    return 0;
}
