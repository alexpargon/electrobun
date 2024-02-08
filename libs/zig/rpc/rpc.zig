// needed to access grand central dispatch to dispatch things from
// other threads to the main thread
const dispatch = @cImport({
    @cInclude("dispatch/dispatch.h");
});
const std = @import("std");
const rpcSchema = @import("schema/schema.zig");
const rpcTypes = @import("types.zig");
const rpcSenders = @import("schema/senders.zig");
const rpcHandlers = @import("schema/handlers.zig");
const handlers = rpcHandlers.handlers;

const alloc = std.heap.page_allocator;

// We listen on stdin for stuff to do from bun and then dispatch it to the main thread where the gui stuff happens
fn stdInListener() void {
    const stdin = std.io.getStdIn().reader();
    // Note: this is a zig string.
    var buffer: [1024]u8 = undefined;

    while (true) {
        const bytesRead = stdin.readUntilDelimiterOrEof(&buffer, '\n') catch continue;
        if (bytesRead) |line| {
            std.log.info("received line: {s}", .{line});

            const messageWithType = std.json.parseFromSlice(rpcTypes._RPCMessage, alloc, line, .{ .ignore_unknown_fields = true }) catch |err| {
                std.log.info("Error parsing line from stdin - {}: \nreceived: {s}", .{ err, line });
                return;
            };

            std.log.info("parsed line {s}", .{messageWithType.value.type});
            if (std.mem.eql(u8, messageWithType.value.type, "response")) {

                // todo: handle _RPCResponsePacketError
                const _response = std.json.parseFromSlice(rpcTypes._RPCResponsePacketSuccess, alloc, line, .{}) catch |err| {
                    std.log.info("Error parsing line from stdin - {}: \nreceived: {s}", .{ err, line });
                    return;
                };
                // handle response
                // _response = payload.allow;

                std.log.info("decide Navigation - {}", .{_response.value.payload.?});

                rpcSenders.setResponse(messageWithType.value.id, _response.value.payload);
            } else {
                // Handle UI events on main thread
                // since line is re-used we need to copy it to the heap
                const lineCopy = alloc.dupe(u8, line) catch {
                    // Handle the error here, e.g., log it or set a default value
                    std.debug.print("Error: {s}\n", .{line});
                    continue;
                };

                messageQueue.append(lineCopy) catch {
                    std.log.info("Error appending to messageQueue: \nreceived: {s}", .{line});
                    continue;
                };

                dispatch.dispatch_async_f(dispatch.dispatch_get_main_queue(), null, processMessageQueue);

                std.log.info("sending over to main thread", .{});
            }
        }
    }
}

var messageQueue = std.ArrayList([]const u8).init(alloc);

fn processMessageQueue(context: ?*anyopaque) callconv(.C) void {
    std.log.info("processMessageQueue on main thread", .{});
    _ = context;

    const line = messageQueue.orderedRemove(0);
    defer alloc.free(line);

    std.log.info("parsed line on main thread {s}", .{line});

    // Do the main json parsing work on the stdin thread, add it to a queue, and then
    // process the generic jobs on the main thread
    const json = std.json.parseFromSlice(std.json.Value, alloc, line, .{ .ignore_unknown_fields = true }) catch |err| {
        std.log.info("Error parsing line from stdin - {}: \nreceived: {s}", .{ err, line });
        return;
    };

    defer json.deinit();

    const msgType = blk: {
        const obj = json.value.object.get("type").?;
        break :blk obj.string;
    };

    std.log.info("parsed line main thread {s}", .{msgType});

    if (std.mem.eql(u8, msgType, "request")) {
        const _request = std.json.parseFromValue(rpcTypes._RPCRequestPacket, alloc, json.value, .{}) catch |err| {
            std.log.info("Error parsing line from stdin - {}: \nreceived: {s}", .{ err, line });
            return;
        };

        const result = rpcHandlers.handleRequest(_request.value);

        if (result.errorMsg == null) {
            rpcSenders.sendResponseSuccess(_request.value.id, result.payload);
        } else {
            rpcSenders.sendResponseError(_request.value.id, result.errorMsg.?);
        }
    } else if (std.mem.eql(u8, msgType, "message")) {
        // todo: rpcHandlers.handleMessage(json.value);
        std.log.info("it's a message meatball", .{});
    } else {
        std.log.info("it's an unhandled meatball", .{});
    }
}

pub fn init() !void {
    _ = try std.Thread.spawn(.{}, stdInListener, .{});
    // Note: don't defer ipcThread.join() here, doing so will cause init() to wait for the thread to complete
    // which never happens, which will in turn block the calling functino (probably main()) blocking that execution path
}