/* SPDX-License-Identifier: MIT
 * An immutable copy of the console's existing Metal output, not an inferred
 * Windows Present fence. No pixel readback, CPU pixel copy or guest ABI change.
 * Build this file with ARC; QEMU's Cocoa implementation remains MRC. */
#import <Foundation/Foundation.h>
#import "publisher.h"
#include "ndt.h"
#include <stdatomic.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static _Atomic unsigned occupied;
static _Atomic uint64_t active_generation;
static _Atomic uint64_t refresh_generation;
static _Atomic uint64_t attempted, dropped, completed, published, acknowledged;
static _Atomic uint64_t allocations, releases, mappings, unmappings;
static _Atomic uint64_t backing_allocations, backing_releases, backing_reuses;
static _Atomic unsigned cached_backings;

@interface PNDBacking : NSObject
@property(nonatomic) id<MTLBuffer> buffer;
@property(nonatomic) id<MTLTexture> texture;
@property(nonatomic) int memoryFD;
@property(nonatomic) uint64_t generation;
@property(nonatomic) ndt_metadata layout;
@end
@implementation PNDBacking
- (instancetype)init {
    if ((self = [super init])) { _memoryFD = -1; atomic_fetch_add(&backing_allocations, 1); }
    return self;
}
- (void)dealloc {
    if (_memoryFD >= 0) close(_memoryFD);
    atomic_fetch_add(&backing_releases, 1);
}
@end

/* Only ACK-retired backing enters this cache. The lock covers object moves,
 * never GPU work, allocation, transport or a wait for the other process.
 * At most two idle backings supplement the existing two active reservations. */
static NSLock *pool_lock;
static NSMutableArray<PNDBacking *> *pool;
static void clear_pool(void) {
    [pool_lock lock];
    [pool removeAllObjects];
    atomic_store(&cached_backings, 0);
    [pool_lock unlock];
}
static PNDBacking *take_backing(id<MTLTexture> source, MTLSize size, uint64_t generation) {
    PNDBacking *result = nil;
    PNDBacking *retired __attribute__((objc_precise_lifetime)) = nil;
    [pool_lock lock];
    for (PNDBacking *backing in pool) {
        if (backing.generation == generation && backing.texture.device == source.device &&
            backing.layout.width == size.width && backing.layout.height == size.height) {
            result = backing;
            break;
        }
    }
    if (result) {
        [pool removeObjectIdenticalTo:result];
        atomic_fetch_sub(&cached_backings, 1);
        atomic_fetch_add(&backing_reuses, 1);
    } else if (pool.count) {
        /* Evict the oldest idle mismatch so new geometry/device can enter the
         * cache. A full cache of old sizes must not force allocation forever. */
        retired = pool.firstObject;
        [pool removeObjectAtIndex:0];
        atomic_fetch_sub(&cached_backings, 1);
    }
    [pool_lock unlock];
    (void)retired;
    return result;
}
static void cache_backing(PNDBacking *backing, uint64_t generation) {
    [pool_lock lock];
    if (backing && generation == atomic_load(&active_generation) && pool.count < NDT_SLOTS) {
        [pool addObject:backing];
        atomic_fetch_add(&cached_backings, 1);
    }
    [pool_lock unlock];
}

@interface PNDCapture : NSObject
@property(nonatomic) PNDBacking *storage;
@property(nonatomic) int readyFD;
@property(nonatomic) int signalFD;
@property(nonatomic) uint64_t generation;
@property(nonatomic) ndt_metadata metadata;
@property(nonatomic) BOOL sent;
@end
@implementation PNDCapture
- (instancetype)init {
    if ((self = [super init])) { _readyFD = _signalFD = -1; }
    return self;
}
- (void)dealloc {
    if (_readyFD >= 0) close(_readyFD);
    if (_signalFD >= 0) close(_signalFD);
    atomic_fetch_sub(&occupied, 1);
    atomic_fetch_add(&releases, 1);
}
@end

@interface PNDPublisher : NSObject {
    ndt_listener _listener;
    ndt_connection _connection;
    BOOL _connected, _closed;
    uint64_t _sessionHi, _sessionLo, _generation, _nextFrame;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    id<NSObject> _activity;
    NSMutableArray<PNDCapture *> *_captures;
}
- (instancetype)initWithDirectory:(NSString *)directory session:(NSString *)session;
- (void)tick;
- (void)submit:(PNDCapture *)capture;
- (void)reset;
- (void)shutdown;
@end

@implementation PNDPublisher
- (instancetype)initWithDirectory:(NSString *)directory session:(NSString *)session {
    if (session.length != 32 || ![directory isAbsolutePath]) return nil;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    if ([session rangeOfCharacterFromSet:[hex invertedSet]].location != NSNotFound) return nil;
    if (!(self = [super init])) return nil;
    _listener.fd = _connection.fd = -1;
    _sessionHi = strtoull([[session substringToIndex:16] UTF8String], NULL, 16);
    _sessionLo = strtoull([[session substringFromIndex:16] UTF8String], NULL, 16);
    if (!(_sessionHi | _sessionLo)) return nil;
    if (ndt_listen(&_listener, directory.fileSystemRepresentation, "native-display.sock") != NDT_OK) return nil;
    _captures = [NSMutableArray arrayWithCapacity:NDT_SLOTS];
    pool_lock = [NSLock new];
    pool = [NSMutableArray arrayWithCapacity:NDT_SLOTS];
    _queue = dispatch_queue_create("org.perpendicular.native-display.publisher", DISPATCH_QUEUE_SERIAL);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    __weak PNDPublisher *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_resume(_timer);
    return self;
}
- (void)disconnect {
    atomic_store(&active_generation, 0);
    atomic_store(&refresh_generation, 0);
    if (_connected) { ndt_close(&_connection); _connected = NO; }
    /* Disconnect never permits reuse of unacknowledged storage. Drop those
     * backings; old consumer mappings retain their own independent memory.
     * Even ACK-retired cache entries do not cross connection generations. */
    clear_pool();
    [_captures removeAllObjects];
    if (_activity) { [[NSProcessInfo processInfo] endActivity:_activity]; _activity = nil; }
    ndt_event event;
    while (ndt_next_event(&_connection, &event) == NDT_OK) { }
}
- (void)tick {
    if (_closed) return;
    if (!_connected) {
        int rc = ndt_server_accept(&_listener, &_connection, geteuid(), _sessionHi, _sessionLo, 1);
        if (rc != NDT_OK) return;
        _connected = YES;
        // The VM's app window may be in another process. Keep this rendering
        // process responsive while a consumer is attached, without preventing
        // idle system sleep or changing any global power-management setting.
        _activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
            reason:@"Virtual machine display"];
        atomic_store(&active_generation, ++_generation);
        atomic_store(&refresh_generation, _generation);
    }
    int rc = ndt_pump(&_connection);
    if (rc != NDT_OK && rc != NDT_AGAIN) { [self disconnect]; return; }
    ndt_event event;
    while (ndt_next_event(&_connection, &event) == NDT_OK) {
        if (event.kind != NDT_EVENT_ACK) continue;
        for (PNDCapture *capture in [_captures copy]) {
            ndt_identity identity = capture.metadata.id;
            if (identity.session_hi == event.id.session_hi && identity.session_lo == event.id.session_lo &&
                identity.epoch == event.id.epoch && identity.frame == event.id.frame) {
                cache_backing(capture.storage, capture.generation);
                [_captures removeObjectIdenticalTo:capture];
                atomic_fetch_add(&acknowledged, 1);
                break;
            }
        }
    }
    for (PNDCapture *capture in _captures) {
        if (capture.sent) continue;
        ndt_metadata metadata = capture.metadata;
        rc = ndt_queue_frame(&_connection, &metadata, capture.storage.memoryFD, capture.readyFD);
        if (rc == NDT_AGAIN) break;
        if (rc != NDT_OK) { [self disconnect]; return; }
        capture.sent = YES;
        atomic_fetch_add(&published, 1);
        /* Only a queued, GPU-completed snapshot of this exact connection can
         * satisfy its initial refresh. An old completion cannot clear a new
         * consumer's request; allocation/GPU/send failures leave it pending. */
        uint64_t expected = capture.generation;
        atomic_compare_exchange_strong(&refresh_generation, &expected, 0);
        /* One queued record at a time; a later tick resumes a partial send. */
        break;
    }
    rc = ndt_pump(&_connection);
    if (rc != NDT_OK && rc != NDT_AGAIN) [self disconnect];
}
- (void)submit:(PNDCapture *)capture {
    dispatch_async(_queue, ^{
        if (self->_closed || !self->_connected || capture.generation != self->_generation) return;
        ndt_metadata metadata = capture.metadata;
        metadata.id = (ndt_identity){self->_sessionHi, self->_sessionLo, 1, ++self->_nextFrame};
        capture.metadata = metadata;
        [self->_captures addObject:capture];
        [self tick];
    });
}
- (void)reset { dispatch_async(_queue, ^{ [self disconnect]; }); }
- (void)shutdown {
    dispatch_sync(_queue, ^{
        self->_closed = YES;
        dispatch_source_cancel(self->_timer);
        [self disconnect];
        ndt_listener_close(&self->_listener);
    });
}
@end

static PNDPublisher *publisher;
static PNDPublisher *get_publisher(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *directory = getenv("PERP_NATIVE_DISPLAY_DIR");
        const char *session = getenv("PERP_NATIVE_DISPLAY_SESSION");
        if (directory && session) {
            publisher = [[PNDPublisher alloc] initWithDirectory:[NSString stringWithUTF8String:directory]
                                                      session:[NSString stringWithUTF8String:session]];
            if (!publisher) fprintf(stderr, "native-display: rejected listener configuration\n");
        }
    });
    return publisher;
}

static PNDBacking *allocate_backing(id<MTLTexture> source, MTLSize size, uint64_t generation) {
    size_t alignment = [source.device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    if (!alignment || (alignment & (alignment - 1)) || !page || (page & (page - 1))) return nil;
    size_t pitch = (size.width * 4 + alignment - 1) & ~(alignment - 1);
    size_t logical = pitch * size.height, extent = (logical + page - 1) & ~(page - 1);
    if (extent > NDT_MAX_EXTENT || pitch > UINT32_MAX) return nil;
    PNDBacking *storage = [PNDBacking new];
    storage.generation = generation;
    int memory = -1;
    for (unsigned attempt = 0; attempt < 4; attempt++) {
        char name[96];
        /* Darwin POSIX shared-memory names have a short implementation limit. */
        snprintf(name, sizeof(name), "/pn-%x-%08x%08x", getpid(), arc4random(), arc4random());
        memory = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (memory >= 0) { shm_unlink(name); break; }
        if (errno != EEXIST) return nil;
    }
    if (memory < 0) return nil;
    storage.memoryFD = memory;
    if (fcntl(memory, F_SETFD, FD_CLOEXEC) < 0 || ftruncate(memory, (off_t)extent) < 0) return nil;
    void *mapping = mmap(NULL, extent, PROT_READ | PROT_WRITE, MAP_SHARED, memory, 0);
    if (mapping == MAP_FAILED) return nil;
    atomic_fetch_add(&mappings, 1);
    storage.buffer = [source.device newBufferWithBytesNoCopy:mapping length:extent
        options:MTLResourceStorageModeShared deallocator:^(void *pointer, NSUInteger length) {
            munmap(pointer, length); atomic_fetch_add(&unmappings, 1);
        }];
    if (!storage.buffer) { munmap(mapping, extent); atomic_fetch_add(&unmappings, 1); return nil; }
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:size.width height:size.height mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;
    storage.texture = [storage.buffer newTextureWithDescriptor:descriptor offset:0 bytesPerRow:pitch];
    if (!storage.texture) return nil;
    storage.layout = (ndt_metadata){.width=(uint32_t)size.width, .height=(uint32_t)size.height,
        .pitch=(uint32_t)pitch, .format=NDT_BGRA8, .offset=0, .size=logical};
    return storage;
}

static PNDCapture *allocate_capture(id<MTLTexture> source, MTLSize size, uint64_t generation) {
    unsigned count = atomic_load(&occupied);
    do { if (count >= NDT_SLOTS) return nil; }
    while (!atomic_compare_exchange_weak(&occupied, &count, count + 1));
    PNDCapture *capture = [PNDCapture new];
    atomic_fetch_add(&allocations, 1);
    capture.generation = generation;
    if (generation != atomic_load(&active_generation)) return nil;
    capture.storage = take_backing(source, size, generation);
    if (!capture.storage) capture.storage = allocate_backing(source, size, generation);
    if (!capture.storage) return nil;
    /* A readiness pipe belongs to one frame, never to the pooled backing.
     * Its previous signalled token cannot authorize a new GPU copy. */
    int ready[2];
    if (pipe(ready) < 0) return nil;
    capture.readyFD = ready[0]; capture.signalFD = ready[1];
    for (unsigned i = 0; i < 2; i++) {
        int flags = fcntl(ready[i], F_GETFL);
        if (flags < 0 || fcntl(ready[i], F_SETFL, flags | O_NONBLOCK) < 0 ||
            fcntl(ready[i], F_SETFD, FD_CLOEXEC) < 0) return nil;
    }
    capture.metadata = capture.storage.layout;
    return capture;
}

bool perp_native_display_enabled(void) { return get_publisher() != nil; }
static bool refresh_pending(void) {
    uint64_t generation = atomic_load(&active_generation);
    return generation && atomic_load(&refresh_generation) == generation;
}
bool perp_native_display_needs_refresh(void) {
    return refresh_pending() && atomic_load(&occupied) < NDT_SLOTS;
}
bool perp_native_display_direct(void) {
    static bool direct;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("PERP_NATIVE_DISPLAY_DIRECT");
        direct = value && !strcmp(value, "1");
    });
    return direct;
}
bool perp_native_display_can_capture(void) {
    return get_publisher() && atomic_load(&active_generation) && atomic_load(&occupied) < NDT_SLOTS;
}
PNDCaptureResult perp_native_display_capture_region(id<MTLCommandBuffer> command,
    id<MTLTexture> output, MTLOrigin origin, MTLSize size) {
    PNDPublisher *owner = get_publisher();
    if (!owner) return PND_CAPTURE_UNAVAILABLE;
    atomic_fetch_add(&attempted, 1);
    uint64_t generation = atomic_load(&active_generation);
    if (!generation) { atomic_fetch_add(&dropped, 1); return PND_CAPTURE_UNAVAILABLE; }
    /* Subtraction after the size bound avoids origin+size integer overflow. */
    if (!command || command.status != MTLCommandBufferStatusNotEnqueued || !output ||
        output.pixelFormat != MTLPixelFormatBGRA8Unorm ||
        output.textureType != MTLTextureType2D || output.sampleCount != 1 ||
        output.device != command.commandQueue.device || origin.z || size.depth != 1 ||
        !size.width || !size.height || size.width > NDT_MAX_DIMENSION || size.height > NDT_MAX_DIMENSION ||
        size.width * size.height > NDT_MAX_PIXELS || size.width > output.width || size.height > output.height ||
        origin.x > output.width - size.width || origin.y > output.height - size.height) {
        atomic_fetch_add(&dropped, 1); return PND_CAPTURE_INVALID;
    }
    if (atomic_load(&occupied) >= NDT_SLOTS) { atomic_fetch_add(&dropped, 1); return PND_CAPTURE_BACKPRESSURE; }
    PNDCapture *capture = allocate_capture(output, size, generation);
    if (!capture) {
        atomic_fetch_add(&dropped, 1);
        return atomic_load(&occupied) >= NDT_SLOTS ? PND_CAPTURE_BACKPRESSURE : PND_CAPTURE_FAILED;
    }
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    if (!encoder) { atomic_fetch_add(&dropped, 1); return PND_CAPTURE_FAILED; }
    [encoder copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:origin
        sourceSize:size toTexture:capture.storage.texture
        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [encoder endEncoding];
    [command addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        if (finished.status != MTLCommandBufferStatusCompleted || finished.error) {
            atomic_fetch_add(&dropped, 1); return;
        }
        uint8_t token = 1;
        ssize_t written;
        do { written = write(capture.signalFD, &token, 1); } while (written < 0 && errno == EINTR);
        if (written != 1) { atomic_fetch_add(&dropped, 1); return; }
        atomic_fetch_add(&completed, 1);
        [owner submit:capture];
    }];
    return PND_CAPTURE_ENCODED;
}
void perp_native_display_capture(id<MTLCommandBuffer> command, id<MTLTexture> output) {
    (void)perp_native_display_capture_region(command, output, MTLOriginMake(0, 0, 0),
        MTLSizeMake(output.width, output.height, 1));
}
void perp_native_display_reset(void) { [publisher reset]; }
void perp_native_display_shutdown(void) { [publisher shutdown]; }
char *perp_native_display_stats(void) {
    char *result = NULL;
    asprintf(&result, "{\"attempted\":%llu,\"dropped\":%llu,\"completed\":%llu,\"published\":%llu,\"acknowledged\":%llu,\"occupied\":%u,\"allocations\":%llu,\"releases\":%llu,\"mappings\":%llu,\"unmappings\":%llu,\"backing_allocations\":%llu,\"backing_releases\":%llu,\"backing_reuses\":%llu,\"cached_backings\":%u,\"refresh_pending\":%s}",
        (unsigned long long)atomic_load(&attempted), (unsigned long long)atomic_load(&dropped),
        (unsigned long long)atomic_load(&completed), (unsigned long long)atomic_load(&published),
        (unsigned long long)atomic_load(&acknowledged), atomic_load(&occupied),
        (unsigned long long)atomic_load(&allocations), (unsigned long long)atomic_load(&releases),
        (unsigned long long)atomic_load(&mappings), (unsigned long long)atomic_load(&unmappings),
        (unsigned long long)atomic_load(&backing_allocations), (unsigned long long)atomic_load(&backing_releases),
        (unsigned long long)atomic_load(&backing_reuses), atomic_load(&cached_backings),
        refresh_pending() ? "true" : "false");
    return result;
}
