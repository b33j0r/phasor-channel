const std = @import("std");

/// A bounded broadcast channel with multiple subscribers.
/// Each subscriber maintains its own cursor into a shared ring buffer.
/// If a slow reader falls behind, events are dropped and a warning is logged.
pub fn BroadcastChannel(comptime T: type) type {
    return struct {
        pub const Error = error{Closed};

        pub fn create(allocator: std.mem.Allocator, capacity: usize) !struct { sender: Sender, controller: Controller } {
            if (capacity == 0) return error.InvalidCapacity;

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
                .controller = .{ .inner = inner },
            };
        }

        const Inner = struct {
            lock: std.Thread.Mutex = .{},
            not_full: std.Thread.Condition = .{},
            not_empty: std.Thread.Condition = .{},

            buf: []T,
            cap: usize,
            head: u64 = 0, // monotonic write position
            tail: u64 = 0, // monotonic read position (slowest reader)

            closed: bool = false,

            subscribers: std.ArrayListUnmanaged(*Subscription) = .empty,
            refs: std.atomic.Value(usize),

            allocator: std.mem.Allocator,

            fn freeAll(self: *Inner) void {
                const alloc = self.allocator;

                // Clean up all subscribers
                for (self.subscribers.items) |sub| {
                    alloc.destroy(sub);
                }
                self.subscribers.deinit(alloc);

                alloc.free(self.buf);
                alloc.destroy(self);
            }

            fn retain(self: *Inner) void {
                _ = self.refs.fetchAdd(1, .monotonic);
            }

            fn release(self: *Inner) void {
                if (self.refs.fetchSub(1, .seq_cst) == 1) {
                    self.freeAll();
                }
            }

            fn push(self: *Inner, value: T) !void {
                self.lock.lock();
                defer self.lock.unlock();

                if (self.closed) return Error.Closed;

                // Wait while buffer is full
                while ((self.head - self.tail) >= self.cap and !self.closed) {
                    self.not_full.wait(&self.lock);
                }
                if (self.closed) return Error.Closed;

                // Write to ring buffer
                const idx = self.head % self.cap;
                self.buf[idx] = value;
                self.head += 1;

                self.not_empty.broadcast();
            }

            fn tryPush(self: *Inner, value: T) !bool {
                self.lock.lock();
                defer self.lock.unlock();

                if (self.closed) return Error.Closed;
                if ((self.head - self.tail) >= self.cap) return false;

                const idx = self.head % self.cap;
                self.buf[idx] = value;
                self.head += 1;

                self.not_empty.broadcast();
                return true;
            }

            fn subscribe(self: *Inner) !*Subscription {
                self.lock.lock();
                defer self.lock.unlock();

                const sub = try self.allocator.create(Subscription);
                sub.* = .{
                    .cursor = std.atomic.Value(u64).init(self.tail), // Start at tail (oldest available)
                    .inner = self,
                };

                try self.subscribers.append(self.allocator, sub);
                self.retain(); // Each subscription holds a reference

                return sub;
            }

            fn unsubscribe(self: *Inner, sub: *Subscription) void {
                self.lock.lock();
                defer self.lock.unlock();

                // Find and remove the subscription
                for (self.subscribers.items, 0..) |s, i| {
                    if (s == sub) {
                        _ = self.subscribers.swapRemove(i);
                        break;
                    }
                }

                // Update tail to be the slowest remaining reader
                self.updateTail();
                self.not_full.signal();
            }

            fn updateTail(self: *Inner) void {
                // Must be called with lock held
                if (self.subscribers.items.len == 0) {
                    self.tail = self.head;
                    return;
                }

                var min_cursor: u64 = std.math.maxInt(u64);
                for (self.subscribers.items) |sub| {
                    const cursor = sub.cursor.load(.monotonic);
                    if (cursor < min_cursor) {
                        min_cursor = cursor;
                    }
                }
                self.tail = min_cursor;
            }

            fn doClose(self: *Inner) void {
                self.lock.lock();
                defer self.lock.unlock();

                if (!self.closed) {
                    self.closed = true;
                    self.not_full.broadcast();
                    self.not_empty.broadcast();
                }
            }
        };

        const Subscription = struct {
            cursor: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
            inner: *Inner,
            released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

            fn tryRecv(self: *Subscription) ?T {
                if (self.released.load(.acquire)) return null;

                self.inner.lock.lock();
                defer self.inner.lock.unlock();

                const cursor = self.cursor.load(.monotonic);
                const head = self.inner.head;
                const tail = self.inner.tail;

                // Check if we've fallen behind
                if (cursor < tail) {
                    const dropped = tail - cursor;
                    std.log.warn("BroadcastChannel subscriber dropped {} events, advancing cursor", .{dropped});
                    self.cursor.store(tail, .monotonic);
                    self.inner.updateTail();
                    self.inner.not_full.signal();
                    return self.tryRecv();
                }

                // Check if data is available
                if (cursor >= head) return null;

                const idx = cursor % self.inner.cap;
                const value = self.inner.buf[idx];
                self.cursor.store(cursor + 1, .monotonic);

                // Update global tail if we were the slowest reader
                if (cursor == tail) {
                    self.inner.updateTail();
                    self.inner.not_full.signal();
                }

                return value;
            }

            fn recv(self: *Subscription) !T {
                if (self.released.load(.acquire)) return Error.Closed;

                while (true) {
                    if (self.tryRecv()) |value| {
                        return value;
                    }

                    // Wait for new data
                    self.inner.lock.lock();
                    if (self.inner.closed) {
                        self.inner.lock.unlock();
                        return Error.Closed;
                    }
                    self.inner.not_empty.wait(&self.inner.lock);
                    self.inner.lock.unlock();

                    // Check for closed state after wait - this was missing
                    self.inner.lock.lock();
                    const is_closed = self.inner.closed;
                    self.inner.lock.unlock();
                    
                    if (is_closed) return Error.Closed;
                }
            }

            pub fn deinit(self: *Subscription) void {
                if (self.released.swap(true, .acq_rel) == false) {
                    // Save allocator before releasing inner (which may free it)
                    const allocator = self.inner.allocator;
                    self.inner.unsubscribe(self);
                    self.inner.release();
                    allocator.destroy(self);
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
                if (self.released.load(.acquire)) return Error.Closed;
                try self.inner.push(value);
            }

            pub fn trySend(self: Sender, value: T) !bool {
                if (self.released.load(.acquire)) return Error.Closed;
                return try self.inner.tryPush(value);
            }

            pub fn close(self: Sender) void {
                if (self.released.load(.acquire)) return;
                self.inner.doClose();
            }

            pub fn deinit(self: *Sender) void {
                if (self.released.swap(true, .acq_rel) == false) {
                    self.inner.release();
                }
            }
        };

        pub const Controller = struct {
            inner: *Inner,
            released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

            pub fn subscribe(self: Controller) !Receiver {
                if (self.released.load(.acquire)) return Error.Closed;
                const sub = try self.inner.subscribe();
                return .{ .subscription = sub };
            }

            pub fn close(self: Controller) void {
                if (self.released.load(.acquire)) return;
                self.inner.doClose();
            }

            pub fn deinit(self: *Controller) void {
                if (self.released.swap(true, .acq_rel) == false) {
                    self.inner.release();
                }
            }
        };

        pub const Receiver = struct {
            subscription: ?*Subscription,

            pub fn recv(self: Receiver) !T {
                if (self.subscription) |sub| {
                    return try sub.recv();
                } else {
                    return Error.Closed;
                }
            }

            pub fn tryRecv(self: Receiver) ?T {
                if (self.subscription) |sub| {
                    return sub.tryRecv();
                } else {
                    return null;
                }
            }

            pub fn next(self: Receiver) ?T {
                return self.recv() catch |err| {
                    if (err == Error.Closed) return null else unreachable;
                };
            }

            pub fn deinit(self: *Receiver) void {
                if (self.subscription) |sub| {
                    sub.deinit();
                    self.subscription = null;
                }
            }
        };
    };
}
