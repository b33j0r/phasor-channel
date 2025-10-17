test "Channel basic send/recv" {
    const allocator = std.testing.allocator;
    var ch = try Channel(i32).create(allocator, 2);
    defer ch.sender.deinit();
    defer ch.receiver.deinit();

    try ch.sender.send(1);
    try ch.sender.send(2);

    const a = try ch.receiver.recv();
    try std.testing.expectEqual(@as(i32, 1), a);

    // Close the sender
    ch.sender.close();

    // Closing still allows draining
    const b = try ch.receiver.recv();
    try std.testing.expectEqual(@as(i32, 2), b);

    // now closed + empty -> Closed
    try std.testing.expectError(Channel(i32).Error.Closed, ch.receiver.recv());
}

test "Channel as iterator" {
    const allocator = std.testing.allocator;
    var ch = try Channel(i32).create(allocator, 2);
    defer ch.sender.deinit();
    defer ch.receiver.deinit();

    try ch.sender.send(10);
    try ch.sender.send(20);
    ch.sender.close();

    var sum: i32 = 0;
    while (ch.receiver.tryRecv()) |v| {
        sum += v;
    }
    try std.testing.expectEqual(@as(i32, 30), sum);
}

test "Channel across threads" {
    const allocator = std.testing.allocator;
    var ch = try Channel(usize).create(allocator, 3);
    defer ch.sender.deinit();
    defer ch.receiver.deinit();

    const Worker = struct {
        pub fn run(mut_sender: Channel(usize).Sender) !void {
            var sender = mut_sender;
            defer sender.deinit();
            for (0..10) |i| {
                try sender.send(i);
            }
            sender.close();
        }
    };

    var thread = try std.Thread.spawn(.{}, Worker.run, .{ch.sender.clone()});
    defer thread.join();

    var sum: usize = 0;
    while (true) {
        const res = ch.receiver.recv();
        if (res == Channel(usize).Error.Closed) break;
        sum += res catch unreachable;
    }
    try std.testing.expectEqual(@as(i32, 45), sum);
}

test "Channel idempotent deinit" {
    const allocator = std.testing.allocator;

    var ch = try Channel(i32).create(allocator, 2);

    // First deinit
    ch.sender.deinit();
    ch.receiver.deinit();

    // Second deinit should be safe (no-op)
    ch.sender.deinit();
    ch.receiver.deinit();

    // Third deinit should also be safe
    ch.sender.deinit();
    ch.receiver.deinit();
}

test "Channel operations after deinit" {
    const allocator = std.testing.allocator;

    var ch = try Channel(i32).create(allocator, 2);
    var sender = ch.sender.clone();
    var receiver = ch.receiver.clone();

    // Deinit original handles
    ch.sender.deinit();
    ch.receiver.deinit();

    // Operations on released handles should return appropriate errors
    const send_result = ch.sender.send(42);
    try std.testing.expect(send_result == Channel(i32).Error.Closed);

    const try_send_result = ch.sender.trySend(42);
    try std.testing.expect(try_send_result == Channel(i32).Error.Closed);

    const recv_result = ch.receiver.recv();
    try std.testing.expect(recv_result == Channel(i32).Error.Closed);

    const try_recv_result = ch.receiver.tryRecv();
    try std.testing.expect(try_recv_result == null);

    const next_result = ch.receiver.next();
    try std.testing.expect(next_result == null);

    // close() should be no-op
    ch.sender.close();
    ch.receiver.close();

    // Clean up clones
    sender.deinit();
    receiver.deinit();
}

test "Channel clone semantics" {
    const allocator = std.testing.allocator;

    var ch = try Channel(i32).create(allocator, 2);
    defer ch.sender.deinit();
    defer ch.receiver.deinit();

    // Clone both ends
    var sender_clone = ch.sender.clone();
    defer sender_clone.deinit();

    var receiver_clone = ch.receiver.clone();
    defer receiver_clone.deinit();

    // Send via original, receive via clone
    try ch.sender.send(1);
    const val1 = try receiver_clone.recv();
    try std.testing.expectEqual(@as(i32, 1), val1);

    // Send via clone, receive via original
    try sender_clone.send(2);
    const val2 = try ch.receiver.recv();
    try std.testing.expectEqual(@as(i32, 2), val2);

    // Closing via one clone affects all handles
    sender_clone.close();

    // Should get Closed error now
    const send_result = ch.sender.send(3);
    try std.testing.expect(send_result == Channel(i32).Error.Closed);

    // Drain should still work until empty
    const recv_result = ch.receiver.recv();
    try std.testing.expect(recv_result == Channel(i32).Error.Closed);
}

// Imports
const std = @import("std");

const channel = @import("phasor-channel");
const Channel = channel.Channel;
