/* SPDX-License-Identifier: MIT
 * Diagnostic Metal consumer for the real QEMU publisher. GPU readback here is
 * solely a pixel verifier; it is not part of the application's display path. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "ndt.h"
#include <sys/mman.h>
#include <unistd.h>

static void check(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "QEMU Metal receiver: %s\n", message); exit(1); }
}
static double now(void) { return [NSDate timeIntervalSinceReferenceDate]; }
static unsigned live_frames;
static void pump(ndt_connection *connection) {
    int rc = ndt_pump(connection);
    check(rc == NDT_OK || rc == NDT_AGAIN, "transport pump");
}
static void acknowledge(ndt_connection *connection, const ndt_identity *identity) {
    double end = now() + 5;
    int rc;
    do { pump(connection); rc = ndt_queue_ack(connection, identity); if (rc == NDT_AGAIN) usleep(1000); }
    while (rc == NDT_AGAIN && now() < end);
    check(rc == NDT_OK, "ACK queue"); pump(connection);
}

@interface Held : NSObject {
@public
    ndt_frame frame;
    void *mapping;
    id<MTLBuffer> backing;
    id<MTLTexture> texture;
}
@end
@implementation Held
- (instancetype)init {
    if ((self = [super init])) { frame.memory_fd = frame.ready_fd = -1; live_frames++; }
    return self;
}
- (void)dealloc {
    texture = nil; backing = nil;
    if (mapping && mapping != MAP_FAILED) check(munmap(mapping, frame.memory_extent) == 0, "snapshot munmap");
    ndt_frame_close(&frame);
    live_frames--;
}
@end

static Held *receive(ndt_connection *connection, id<MTLDevice> device) {
    double end = now() + 10;
    while (now() < end) {
        pump(connection);
        ndt_frame value;
        int rc = ndt_take_frame(connection, &value);
        if (rc == NDT_OK) {
            check(ndt_ready(value.ready_fd) == NDT_OK, "frame arrived before producer GPU completion");
            Held *result = [Held new]; result->frame = value;
            result->mapping = mmap(NULL, value.memory_extent, PROT_READ | PROT_WRITE, MAP_SHARED, value.memory_fd, 0);
            check(result->mapping != MAP_FAILED, "snapshot mmap");
            result->backing = [device newBufferWithBytesNoCopy:result->mapping length:value.memory_extent
                options:MTLResourceStorageModeShared deallocator:nil];
            check(result->backing != nil, "Metal shared-buffer import");
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:value.metadata.width height:value.metadata.height mipmapped:NO];
            desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead;
            result->texture = [result->backing newTextureWithDescriptor:desc offset:value.metadata.offset
                bytesPerRow:value.metadata.pitch];
            check(result->texture != nil, "Metal linear-texture import");
            return result;
        }
        check(rc == NDT_AGAIN, "frame receive"); usleep(1000);
    }
    check(NO, "native frame timeout"); return nil;
}

static BOOL verify(Held *held, id<MTLCommandQueue> queue, unsigned width, unsigned height, char color) {
    if (held->frame.metadata.width != width || held->frame.metadata.height != height) return NO;
    NSUInteger pitch = (width * 4 + 255) & ~(NSUInteger)255;
    id<MTLBuffer> readback = [queue.device newBufferWithLength:pitch * height options:MTLResourceStorageModeShared];
    check(readback != nil, "diagnostic readback buffer");
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromTexture:held->texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(width,height,1) toBuffer:readback destinationOffset:0
        destinationBytesPerRow:pitch destinationBytesPerImage:pitch * height];
    [blit endEncoding]; [command commit]; [command waitUntilCompleted];
    check(command.status == MTLCommandBufferStatusCompleted, "consumer GPU completion");
    uint8_t expected[4] = {color == 'B' || color == 'M' ? 255 : 0,
        color == 'G' ? 255 : 0, color == 'R' || color == 'M' ? 255 : 0, 255};
    const uint8_t *bytes = readback.contents;
    for (unsigned y=0; y<height; y++) for (unsigned x=0; x<width; x++)
        if (memcmp(bytes + y*pitch + x*4, expected, 4)) return NO;
    return YES;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        check(argc == 4, "arguments: socket PID session-hex");
        check(strlen(argv[3]) == 32, "session length");
        char high[17]; memcpy(high, argv[3], 16); high[16] = 0;
        uint64_t hi = strtoull(high, NULL, 16), lo = strtoull(argv[3] + 16, NULL, 16);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); check(device != nil, "Metal device");
        id<MTLCommandQueue> queue = [device newCommandQueue]; check(queue != nil, "Metal queue");
        NSMutableDictionary<NSNumber *, Held *> *held = [NSMutableDictionary new];
        ndt_connection connection = {.fd = -1};
        unsigned connections = 0; uint64_t total = 0;
        char line[128]; setvbuf(stdout, NULL, _IOLBF, 0);
        while (fgets(line, sizeof(line), stdin)) {
          @autoreleasepool {
            char verb[20], color = 0; unsigned slot = 0, width = 0, height = 0;
            check(sscanf(line, "%19s", verb) == 1, "command");
            if (!strcmp(verb, "connect")) {
                check(connection.fd == -1, "already connected");
                int rc = ndt_client_start(&connection, argv[1], geteuid(), (pid_t)atoi(argv[2]), hi, lo, 1);
                check(rc == NDT_OK || rc == NDT_AGAIN, "connect");
                double end = now() + 10;
                while (ndt_status(&connection) != NDT_OK) { pump(&connection); check(now() < end, "connect timeout"); usleep(1000); }
                connections++;
            } else if (!strcmp(verb, "frame") || !strcmp(verb, "recheck")) {
                check(sscanf(line, "%19s %u %c %u %u", verb, &slot, &color, &width, &height) == 5 &&
                    slot < 3 && width && height && strchr("RGBM", color), "frame command");
                if (!strcmp(verb, "frame")) {
                    check(held[@(slot)] == nil, "occupied verifier slot");
                    unsigned skipped = 0;
                    double end = now() + 15;
                    for (;;) {
                        Held *value = receive(&connection, device);
                        if (verify(value, queue, width, height, color)) { held[@(slot)] = value; break; }
                        /* Older already-queued frames can precede an update.
                         * Retire their actual GPU read before ACK and retry. */
                        acknowledge(&connection, &value->frame.metadata.id);
                        skipped++; check(now() < end && skipped < 16, "expected updated pixels did not arrive");
                    }
                    printf("{\"ok\":true,\"frame\":%llu,\"skipped\":%u}\n",
                        (unsigned long long)held[@(slot)]->frame.metadata.id.frame, skipped);
                } else {
                    check(held[@(slot)] != nil && verify(held[@(slot)], queue, width, height, color), "held snapshot changed");
                    printf("{\"ok\":true}\n");
                }
                total += (uint64_t)width * height; continue;
            } else if (!strcmp(verb, "ack") || !strcmp(verb, "drop")) {
                check(sscanf(line, "%19s %u", verb, &slot) == 2 && held[@(slot)] != nil, "retire command");
                if (!strcmp(verb, "ack")) acknowledge(&connection, &held[@(slot)]->frame.metadata.id);
                [held removeObjectForKey:@(slot)];
            } else if (!strcmp(verb, "disconnect")) {
                ndt_close(&connection);
            } else if (!strcmp(verb, "quit")) {
                check(held.count == 0 && live_frames == 0, "verifier mappings still held"); ndt_close(&connection);
                printf("{\"ok\":true,\"connections\":%u,\"exact_pixels\":%llu,\"active_frames\":%u}\n",
                    connections, (unsigned long long)total, live_frames);
                return 0;
            } else { check(NO, "unknown command"); }
            printf("{\"ok\":true}\n");
          }
        }
        check(NO, "unexpected control EOF"); return 1;
    }
}
