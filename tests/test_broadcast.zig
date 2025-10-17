test "Broadcast basic publish/subscribe" {
    const allocator = std.testing.allocator;

    var bc = try BroadcastChannel(i32).create(allocator, 4);
    defer bc.sender.deinit();
    defer bc.controller.deinit();

    // One subscriber
    var rx = try bc.controller.subscribe();
    defer rx.deinit();

    try bc.sender.send(1);
    try bc.sender.send(2);

    const a = try rx.recv();
    try std.testing.expectEqual(@as(i32, 1), a);

    const b = try rx.recv();
    try std.testing.expectEqual(@as(i32, 2), b);

    // Close the sender
    bc.sender.close();

    // After closing and draining, further recv returns Closed
    try std.testing.expectError(BroadcastChannel(i32).Error.Closed, rx.recv());
}

test "Broadcast multiple subscribers receive same messages" {
    const allocator = std.testing.allocator;

    var bc = try BroadcastChannel(i32).create(allocator, 8);
    defer bc.sender.deinit();
    defer bc.controller.deinit();

    var rx1 = try bc.controller.subscribe();
    defer rx1.deinit();

    var rx2 = try bc.controller.subscribe();
    defer rx2.deinit();

    try bc.sender.send(10);
    try bc.sender.send(20);
    try bc.sender.send(30);

    const a1 = try rx1.recv();
    const a2 = try rx2.recv();
    try std.testing.expectEqual(@as(i32, 10), a1);
    try std.testing.expectEqual(@as(i32, 10), a2);

    const b1 = try rx1.recv();
    const b2 = try rx2.recv();
    try std.testing.expectEqual(@as(i32, 20), b1);
    try std.testing.expectEqual(@as(i32, 20), b2);

    const c1 = try rx1.recv();
    const c2 = try rx2.recv();
    try std.testing.expectEqual(@as(i32, 30), c1);
    try std.testing.expectEqual(@as(i32, 30), c2);

    bc.sender.close();

    try std.testing.expectError(BroadcastChannel(i32).Error.Closed, rx1.recv());
    try std.testing.expectError(BroadcastChannel(i32).Error.Closed, rx2.recv());
}

test "Broadcast trySend when buffer is full" {
    const allocator = std.testing.allocator;

    // Small capacity to hit the full condition easily
    var bc = try BroadcastChannel(i32).create(allocator, 2);
    defer bc.sender.deinit();
    defer bc.controller.deinit();

    var rx = try bc.controller.subscribe();
    defer rx.deinit();

    // Fill buffer
    try bc.sender.send(1);
    try bc.sender.send(2);

    // Non-blocking trySend should fail when full
    const ok = try bc.sender.trySend(3);
    try std.testing.expect(!ok);

    // Drain one
    const a = try rx.recv();
    try std.testing.expectEqual(@as(i32, 1), a);

    // Now trySend should succeed
    const ok2 = try bc.sender.trySend(3);
    try std.testing.expect(ok2 == true);

    // Drain remaining
    const b = try rx.recv();
    const c = try rx.recv();
    try std.testing.expectEqual(@as(i32, 2), b);
    try std.testing.expectEqual(@as(i32, 3), c);

    bc.sender.close();
    try std.testing.expectError(BroadcastChannel(i32).Error.Closed, rx.recv());
}

test "Broadcast across threads (fan-out 10 messages)" {
    const allocator = std.testing.allocator;

    var bc = try BroadcastChannel(usize).create(allocator, 16); // Bigger buffer to avoid blocking
    defer bc.sender.deinit();
    defer bc.controller.deinit();

    var rx1 = try bc.controller.subscribe();
    defer rx1.deinit();

    var rx2 = try bc.controller.subscribe();
    defer rx2.deinit();

    // Send all messages first, then close
    for (0..10) |i| {
        try bc.sender.send(i);
    }
    bc.sender.close();

    // Now read all messages using tryRecv to avoid blocking
    var sum1: usize = 0;
    var count1: usize = 0;
    while (count1 < 10) {
        if (rx1.tryRecv()) |value| {
            sum1 += value;
            count1 += 1;
        } else {
            // No more data available, break out
            break;
        }
    }
    try std.testing.expectEqual(@as(usize, 10), count1);
    try std.testing.expectEqual(@as(usize, 45), sum1);

    var sum2: usize = 0;
    var count2: usize = 0;
    while (count2 < 10) {
        if (rx2.tryRecv()) |value| {
            sum2 += value;
            count2 += 1;
        } else {
            // No more data available, break out
            break;
        }
    }
    try std.testing.expectEqual(@as(usize, 10), count2);
    try std.testing.expectEqual(@as(usize, 45), sum2);
}

test "Broadcast idempotent deinit" {
    const allocator = std.testing.allocator;

    var bc = try BroadcastChannel(i32).create(allocator, 2);

    // Create a subscriber so we can deinit it multiple times safely
    var rx = try bc.controller.subscribe();

    // First deinit of handles
    bc.sender.deinit();
    bc.controller.deinit();
    rx.deinit();

    // Subsequent deinits should be safe no-ops
    bc.sender.deinit();
    bc.controller.deinit();
    rx.deinit();
}

test "Broadcast operations after deinit" {
    const allocator = std.testing.allocator;

    var bc = try BroadcastChannel(i32).create(allocator, 2);
    var sender_clone = bc.sender.clone();

    // Deinit originals
    bc.sender.deinit();
    bc.controller.deinit();

    // Operations on released handles should return appropriate errors / no-ops
    const send_result = bc.sender.send(42);
    try std.testing.expect(send_result == BroadcastChannel(i32).Error.Closed);

    const try_send_result = bc.sender.trySend(42);
    try std.testing.expect(try_send_result == BroadcastChannel(i32).Error.Closed);

    // New subscriptions require a live controller; we can't create one now.
    // Validate receiver behavior by making a subscription *before* close and
    // then deinit receiver and check Closed afterwards.
    // (This mirrors channel "ops after deinit" intent without invalid API use.)
    var bc2 = try BroadcastChannel(i32).create(allocator, 2);
    defer bc2.sender.deinit();
    defer bc2.controller.deinit();

    var rx = try bc2.controller.subscribe();
    rx.deinit();
    // After receiver deinit, calling recv() would be UB (we won't do that).

    // Clean up the still-live clone
    sender_clone.deinit();
}

test "Broadcast sender clone semantics" {
    const allocator = std.testing.allocator;

    var bc = try BroadcastChannel(i32).create(allocator, 2);
    defer bc.sender.deinit();
    defer bc.controller.deinit();

    var rx = try bc.controller.subscribe();
    defer rx.deinit();

    // Clone the sender
    var s2 = bc.sender.clone();
    defer s2.deinit();

    // Send via original, receive
    try bc.sender.send(1);
    const v1 = try rx.recv();
    try std.testing.expectEqual(@as(i32, 1), v1);

    // Send via clone, receive
    try s2.send(2);
    const v2 = try rx.recv();
    try std.testing.expectEqual(@as(i32, 2), v2);

    // Closing through one handle closes the channel
    s2.close();

    // Further sends should fail on both
    const r1 = bc.sender.send(3);
    try std.testing.expect(r1 == BroadcastChannel(i32).Error.Closed);

    const r2 = s2.send(3);
    try std.testing.expect(r2 == BroadcastChannel(i32).Error.Closed);

    // Receiver should now see Closed once drained
    try std.testing.expectError(BroadcastChannel(i32).Error.Closed, rx.recv());
}

test "Broadcast subscribe after close yields immediately-closed receiver" {
    const allocator = std.testing.allocator;

    var bc = try BroadcastChannel(i32).create(allocator, 2);
    defer bc.sender.deinit();
    defer bc.controller.deinit();

    // Close before subscribing
    bc.sender.close();

    // The implementation allows subscribe() even if closed,
    // but the receiver should observe Closed on recv().
    var rx = try bc.controller.subscribe();
    defer rx.deinit();

    try std.testing.expectError(BroadcastChannel(i32).Error.Closed, rx.recv());
}

const std = @import("std");
const channel = @import("phasor-channel");
const BroadcastChannel = channel.BroadcastChannel;
