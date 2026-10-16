// SPDX-License-Identifier: MIT
// Type-check only: this file does not execute transport, windows or GPU work.
func checkNDTBinding(_ connection: UnsafeMutablePointer<ndt_connection>) {
    var frame = ndt_frame()
    var event = ndt_event()
    _ = ndt_socket_fd(connection)
    _ = ndt_status(connection)
    _ = ndt_poll_events(connection)
    _ = ndt_pump(connection)
    _ = ndt_take_frame(connection, &frame)
    _ = ndt_ready(frame.ready_fd)
    _ = ndt_queue_ack(connection, &frame.metadata.id)
    _ = ndt_next_event(connection, &event)
    ndt_frame_close(&frame)
    ndt_close(connection)
}
