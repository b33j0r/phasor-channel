const std = @import("std");

/// A bounded channel for sending values of type `T` between threads.
pub fn Channel(comptime T: type) type {
    return struct {
        pub const Error = error{Closed};

        pub fn create(allocator: std.mem.Allocator, capacity: usize) !struct { sender: Sender, receiver: Receiver } {
            if (capacity == 0) return error.InvalidCapacity;
            std.debug.assert(capacity > 0); // invariant: capacity must be > 0

            const buf = try allocator.alloc(T, capacity);

            const inner = try allocator.create(Inner);
            inner.* = .{
                .buf = buf,
                .cap = capacity,
                .allocator = allocator,
                .refs = std.atomic.Value(usize).init(2),
            };

            return .{
                .sender = .{ .inner = inner },
                .receiver = .{ .inner = inner },
            };
        }

        const Inner = struct {
            mutex: std.Thread.Mutex = .{},
            not_full: std.Thread.Condition = .{},
            not_empty: std.Thread.Condition = .{},

            buf: []T,
            cap: usize,
            head: usize = 0, // next pop
            tail: usize = 0, // next push
            len: usize = 0,

            closed: bool = false,

            // one ref for Sender, one for Receiver (clones retain/release)
            refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(2),

            allocator: std.mem.Allocator,

            fn freeAll(self: *Inner) void {
                const alloc = self.allocator;
                alloc.free(self.buf);
                // Important: destroy the Inner itself to avoid leaking it.
                alloc.destroy(self);
            }

            fn retain(self: *Inner) void {
                // Just bump the count; no synchronizes-with needed here.
                _ = self.refs.fetchAdd(1, .monotonic);
            }

            fn release(self: *Inner) void {
                // Use a strong ordering so prior writes become visible before free.
                if (self.refs.fetchSub(1, .seq_cst) == 1) {
                    self.freeAll();
                }
            }

            fn push(self: *Inner, value: T) !void {
                // precondition: mutex locked
                if (self.closed) return Error.Closed;

                while (self.len == self.cap and !self.closed) {
                    self.not_full.wait(&self.mutex);
                }
                if (self.closed) return Error.Closed;

                self.buf[self.tail] = value;
                self.tail = (self.tail + 1) % self.cap;
                self.len += 1;

                self.not_empty.signal();
            }

            fn tryPush(self: *Inner, value: T) !bool {
                // precondition: mutex locked
                if (self.closed) return Error.Closed;
                if (self.len == self.cap) return false;

                self.buf[self.tail] = value;
                self.tail = (self.tail + 1) % self.cap;
                self.len += 1;

                self.not_empty.signal();
                return true;
            }

            fn pop(self: *Inner) !T {
                // precondition: mutex locked
                while (self.len == 0) {
                    if (self.closed) return Error.Closed; // closed and empty -> EOF
                    self.not_empty.wait(&self.mutex);
                }

                const idx = self.head;
                self.head = (self.head + 1) % self.cap;
                self.len -= 1;

                const val = self.buf[idx];
                self.buf[idx] = undefined; // avoid accidental reuse for resource types

                self.not_full.signal();
                return val;
            }

            fn tryPop(self: *Inner) ?T {
                // precondition: mutex locked
                if (self.len == 0) return null;

                const idx = self.head;
                self.head = (self.head + 1) % self.cap;
                self.len -= 1;

                const val = self.buf[idx];
                self.buf[idx] = undefined;

                self.not_full.signal();
                return val;
            }

            fn doClose(self: *Inner) void {
                // precondition: mutex locked
                if (!self.closed) {
                    self.closed = true;
                    self.not_full.broadcast();
                    self.not_empty.broadcast();
                }
            }
        };

        pub const Sender = struct {
            inner: *Inner,
            released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

            pub fn clone(self: Sender) Sender {
                if (self.released.load(.acquire)) {
                    std.debug.panic("attempted to clone released Sender", .{});
                }
                self.inner.retain();
                return .{ .inner = self.inner, .released = std.atomic.Value(bool).init(false) };
            }

            pub fn send(self: Sender, value: T) !void {
                if (self.released.load(.acquire)) {
                    return Error.Closed; // treat as closed
                }
                self.inner.mutex.lock();
                defer self.inner.mutex.unlock();
                try self.inner.push(value);
            }

            pub fn trySend(self: Sender, value: T) !bool {
                if (self.released.load(.acquire)) {
                    return Error.Closed; // treat as closed
                }
                self.inner.mutex.lock();
                defer self.inner.mutex.unlock();
                return try self.inner.tryPush(value);
            }

            pub fn close(self: Sender) void {
                if (self.released.load(.acquire)) {
                    return; // no-op if released
                }
                self.inner.mutex.lock();
                self.inner.doClose();
                self.inner.mutex.unlock();
            }

            pub fn deinit(self: *Sender) void {
                // Idempotent: only release once
                if (self.released.swap(true, .acq_rel) == false) {
                    self.inner.release();
                }
            }
        };

        pub const Receiver = struct {
            inner: *Inner,
            released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

            pub fn clone(self: Receiver) Receiver {
                if (self.released.load(.acquire)) {
                    std.debug.panic("attempted to clone released Receiver", .{});
                }
                self.inner.retain();
                return .{ .inner = self.inner, .released = std.atomic.Value(bool).init(false) };
            }

            pub fn recv(self: Receiver) !T {
                if (self.released.load(.acquire)) {
                    return Error.Closed; // treat as closed
                }
                self.inner.mutex.lock();
                defer self.inner.mutex.unlock();
                return try self.inner.pop();
            }

            pub fn tryRecv(self: Receiver) ?T {
                if (self.released.load(.acquire)) {
                    return null; // no-op if released
                }
                self.inner.mutex.lock();
                defer self.inner.mutex.unlock();
                return self.inner.tryPop();
            }

            /// Like `tryRecv`, but blocks until a value
            /// is available or the channel is closed.
            /// Used to iterate over all values until closed
            /// with a while loop.
            pub fn next(self: Receiver) ?T {
                return self.recv() catch |err| {
                    if (err == Error.Closed) return null else unreachable;
                };
            }

            pub fn close(self: Receiver) void {
                if (self.released.load(.acquire)) {
                    return; // no-op if released
                }
                self.inner.mutex.lock();
                self.inner.doClose();
                self.inner.mutex.unlock();
            }

            pub fn deinit(self: *Receiver) void {
                // Idempotent: only release once
                if (self.released.swap(true, .acq_rel) == false) {
                    self.inner.release();
                }
            }
        };
    };
}

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