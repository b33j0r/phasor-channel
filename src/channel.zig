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
