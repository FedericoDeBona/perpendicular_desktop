/* SPDX-License-Identifier: MIT
 * Reconnect regression: a static texture exists before any consumer. No guest
 * updates or additional render passes occur after connecting/reconnecting.
 * Reuse the existing real-Metal/two-process fixture's pixel/transport helpers. */
#define main original_publisher_fixture_main
#include "test-publisher.m"
#undef main

static void connect_consumer(ndt_connection *connection, const char *path, pid_t server) {
    int result = ndt_client_start(connection, path, geteuid(), server, session_hi, session_lo, 1);
    check(result == NDT_OK || result == NDT_AGAIN, "refresh client start");
    for (unsigned i = 0; i < 30; i++) { pump(connection); usleep(1000); }
}

static int refresh_consumer(const char *path, pid_t server, int input, int output) {
    ndt_connection connection;
    connect_consumer(&connection, path, server);
    notify(output, 'A');
    ndt_frame first = receive(&connection);
    uint64_t pixels = verify(&first, 64, 32, 0, 0, 255);
    uint64_t first_id = first.metadata.id.frame;
    acknowledge(&connection, &first);
    for (unsigned i = 0; i < 30; i++) { pump(&connection); usleep(1000); }
    ndt_close(&connection);
    notify(output, 'a');

    connect_consumer(&connection, path, server);
    notify(output, 'B');
    control(input, 'G');
    for (unsigned i = 0; i < 100; i++) {
        pump(&connection); ndt_frame unexpected;
        check(ndt_take_frame(&connection, &unexpected) == NDT_AGAIN, "blocked GPU published on second connection");
        usleep(1000);
    }
    notify(output, 'g');
    control(input, 'R');
    double end = now() + 5;
    int result = NDT_AGAIN;
    while (now() < end) {
        result = ndt_pump(&connection);
        if (result != NDT_OK && result != NDT_AGAIN) break;
        usleep(1000);
    }
    check(result == NDT_CLOSED, "reset did not close old consumer");
    ndt_close(&connection);

    connect_consumer(&connection, path, server);
    notify(output, 'C');
    ndt_frame fresh = receive(&connection);
    check(fresh.metadata.id.frame > first_id, "reconnect reused frame identity");
    pixels += verify(&fresh, 64, 32, 0, 0, 255);
    acknowledge(&connection, &fresh);
    for (unsigned i = 0; i < 30; i++) { pump(&connection); usleep(1000); }
    ndt_close(&connection);
    notify(output, 'Z');
    close(input); close(output);
    printf("{\"refresh_consumer\":\"pass\",\"connections\":3,\"static_pixels\":%llu}\n",
        (unsigned long long)pixels);
    return 0;
}

static void wait_refresh(BOOL expected) {
    double end = now() + 5;
    while (now() < end) {
        if (perp_native_display_needs_refresh() == expected) return;
        usleep(1000);
    }
    check(NO, expected ? "initial refresh was not requested" : "refresh was not satisfied/cancelled");
}

static void capture_static(id<MTLCommandQueue> queue, id<MTLTexture> source, id<MTLSharedEvent> gate) {
    @autoreleasepool {
        id<MTLCommandBuffer> command = [queue commandBuffer];
        if (gate) [command encodeWaitForEvent:gate value:1];
        /* No render pass/source mutation: model Cocoa refreshing its unchanged
         * existing output through the original command-buffer capture hook. */
        perp_native_display_capture(command, source);
        [command commit];
        if (!gate) {
            [command waitUntilCompleted];
            check(command.status == MTLCommandBufferStatusCompleted, "refresh GPU completion");
        }
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 6 && !strcmp(argv[1], "--refresh-consumer"))
            return refresh_consumer(argv[2], (pid_t)atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
        check(argc == 1, "unexpected refresh arguments");
        char directory[104];
        const char *runtime = getenv("PERP_REFRESH_TEST_RUNTIME");
        check(strlcpy(directory, runtime ? runtime : "/tmp/perp-refresh-XXXXXX", sizeof(directory)) < sizeof(directory),
            "refresh test path too long");
        check(mkdtemp(directory) != NULL, "refresh private runtime");
        setenv("PERP_NATIVE_DISPLAY_DIR", directory, 1);
        setenv("PERP_NATIVE_DISPLAY_SESSION", "f123456789abcdef123456789abcdef1", 1);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); check(device != nil, "refresh Metal device");
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLTexture> source = texture(device, 64, 32);
        draw(queue, source, MTLClearColorMake(1, 0, 0, 1), NO, nil);
        check(perp_native_display_enabled(), "refresh publisher unavailable");
        check(!perp_native_display_needs_refresh(), "refresh requested without a consumer");

        int to_child[2], from_child[2];
        check(pipe(to_child) == 0 && pipe(from_child) == 0, "refresh control pipes");
        char path[104], pid_text[32], read_text[32], write_text[32];
        snprintf(path, sizeof(path), "%s/native-display.sock", directory);
        snprintf(pid_text, sizeof(pid_text), "%d", getpid());
        snprintf(read_text, sizeof(read_text), "%d", to_child[0]);
        snprintf(write_text, sizeof(write_text), "%d", from_child[1]);
        posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addclose(&actions, to_child[1]);
        posix_spawn_file_actions_addclose(&actions, from_child[0]);
        char *arguments[] = {argv[0], "--refresh-consumer", path, pid_text, read_text, write_text, NULL};
        pid_t child;
        check(posix_spawn(&child, argv[0], &actions, NULL, arguments, environ) == 0, "refresh spawn consumer");
        posix_spawn_file_actions_destroy(&actions); close(to_child[0]); close(from_child[1]);

        control(from_child[0], 'A'); wait_refresh(YES);
        /* Failed/no-drawable work must not consume the generation demand. */
        perp_native_display_capture(nil, source);
        check(perp_native_display_needs_refresh(), "invalid capture consumed refresh demand");
        capture_static(queue, source, nil);
        control(from_child[0], 'a'); wait_for("acknowledged", 1); wait_for("occupied", 0);
        check(!perp_native_display_needs_refresh(), "published static frame left a refresh loop");

        control(from_child[0], 'B'); wait_refresh(YES);
        id<MTLSharedEvent> gate = [device newSharedEvent]; check(gate != nil, "refresh GPU gate");
        capture_static(queue, source, gate);
        check(perp_native_display_needs_refresh(), "GPU-inflight capture consumed refresh demand");
        capture_static(queue, source, gate);
        wait_for("occupied", 2);
        check(!perp_native_display_needs_refresh(), "full snapshot budget requested more GPU work");
        notify(to_child[1], 'G'); control(from_child[0], 'g');
        perp_native_display_reset(); notify(to_child[1], 'R');
        control(from_child[0], 'C');
        wait_for("refresh_pending", 1); /* accept completed despite no free slot */
        check(!perp_native_display_needs_refresh(), "old GPU captures did not retain two-slot bound");
        gate.signaledValue = 1;
        wait_for("occupied", 0); wait_refresh(YES);
        check([stats()[@"published"] unsignedIntValue] == 1, "old completion published to replacement consumer");
        /* Retry only the current generation; source is still the original red. */
        capture_static(queue, source, nil);
        control(from_child[0], 'Z'); wait_for("acknowledged", 2); wait_for("occupied", 0);
        check(!perp_native_display_needs_refresh(), "reconnect static publication did not satisfy demand");
        int status;
        check(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "refresh consumer exit");
        perp_native_display_shutdown();
        check(!perp_native_display_needs_refresh(), "shutdown left refresh demand active");
        NSDictionary *result = stats();
        check([result[@"published"] unsignedIntValue] == 2 && [result[@"allocations"] unsignedIntValue] == 4 &&
            [result[@"allocations"] isEqual:result[@"releases"]] && [result[@"mappings"] isEqual:result[@"unmappings"]],
            "refresh cleanup/publication mismatch");
        close(to_child[1]); close(from_child[0]); check(rmdir(directory) == 0, "refresh directory cleanup");
        printf("{\"refresh_producer\":\"pass\",\"guest_updates_after_connect\":0,\"stale_gpu_completions\":2,\"stats\":%s}\n",
            [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL]
            encoding:NSUTF8StringEncoding].UTF8String);
    }
    return 0;
}
