const std = @import("std");
const rpc = @import("../rpc/schema/request.zig");
const rpcSchema = @import("../rpc/schema/schema.zig");
const objc = @import("./objc.zig");
const pipesin = @import("../rpc/pipesin.zig");
const window = @import("./window.zig");
const rpcTypes = @import("../rpc/types.zig");
const rpcHandlers = @import("../rpc/schema/handlers.zig");

const alloc = std.heap.page_allocator;

const ELECTROBUN_BROWSER_API_SCRIPT = @embedFile("../build/index.js");

const WebviewMap = std.AutoHashMap(u32, WebviewType);
pub var webviewMap: WebviewMap = WebviewMap.init(alloc);
const ViewsScheme = "views://";

fn assetFileLoader(url: [*:0]const u8) objc.FileResponse {
    const relPath = url[ViewsScheme.len..std.mem.len(url)];
    const fileContents = readFileContentsFromDisk(relPath) catch "failed to load contents";
    const mimeType = getMimeType(relPath); // or dynamically determine MIME type

    return objc.FileResponse{
        .mimeType = toCString(mimeType),
        .fileContents = toCString(fileContents),
    };
}

const WebviewType = struct {
    id: u32,
    handle: *anyopaque,
    frame: struct {
        width: f64,
        height: f64,
        x: f64,
        y: f64,
    },
    // todo: de-init these using objc.releaseObjCObject() when the webview closes
    delegate: *anyopaque,
    bunBridgeHandler: *anyopaque,
    webviewTagHandler: *anyopaque,
    bun_out_pipe: ?anyerror!std.fs.File,
    bun_in_pipe: ?std.fs.File,
    // Function to send a message to Bun
    pub fn sendToBun(self: *WebviewType, message: []const u8) !void {
        if (self.bun_out_pipe) |result| {
            if (result) |file| {
                // convert null terminated string to slice
                // const message_slice: []const u8 = message[0..std.mem.len(message)];
                // Write the message to the named pipe
                file.writeAll(message) catch |err| {
                    std.debug.print("Failed to write to file: {}\n", .{err});
                };

                file.writeAll("\n") catch |err| {
                    std.debug.print("Failed to write to file: {}\n", .{err});
                };
            } else |err| {
                std.debug.print("Failed to open file: {}\n", .{err});
            }
            // If bun_out_pipe is not an error and not null, write the message
            // try file.writeAll(message);
        } else {
            // If bun_out_pipe is null, print an error or the message to stdio
            std.debug.print("Error: No valid pipe to write to. Message was: {s}\n", .{message});
        }
    }

    pub fn sendToWebview(self: *WebviewType, message: []const u8) void {
        objc.evaluateJavaScriptWithNoCompletion(self.handle, toCString(message));
    }
};

const CreateWebviewOpts = struct { //
    id: u32,
    url: ?[]const u8,
    html: ?[]const u8,
    preload: ?[]const u8,
    frame: struct { //
        width: f64,
        height: f64,
        x: f64,
        y: f64,
    },
    autoResize: bool,
};
pub fn createWebview(opts: CreateWebviewOpts) void {
    const bunPipeIn = blk: {
        const bunPipeInPath = concatOrFallback("/private/tmp/electrobun_ipc_pipe_{}_1_in", .{opts.id});
        const bunPipeInFileResult = std.fs.cwd().openFile(bunPipeInPath, .{ .mode = .read_only });

        if (bunPipeInFileResult) |file| {
            break :blk file;
        } else |err| {
            std.debug.print("Failed to open file: {}\n", .{err});
            break :blk null;
        }
    };

    if (bunPipeIn) |pipeInFile| {
        pipesin.addPipe(pipeInFile.handle, opts.id);
    }

    const bunPipeOutPath = concatOrFallback("/private/tmp/electrobun_ipc_pipe_{}_1_out", .{opts.id});
    const bunPipeOutFileResult = std.fs.cwd().openFile(bunPipeOutPath, .{ .mode = .read_write });
    const objcWebview = objc.createAndReturnWKWebView(.{
        // .frame = .{ //
        .origin = .{ .x = opts.frame.x, .y = opts.frame.y },
        .size = .{ .width = opts.frame.width, .height = opts.frame.height },
        // },
    }, assetFileLoader, opts.autoResize);

    if (opts.preload) |preload| {
        addPreloadScriptToWebview(objcWebview, preload, true);
    }

    // Can only define functions inline in zig within a struct
    const delegate = objc.setNavigationDelegateWithCallback(objcWebview, opts.id, struct {
        fn decideNavigation(webviewId: u32, url: [*:0]const u8) bool {
            // todo: right now this reaches a generic rpc request, but it should be attached
            // to this specific webview's pipe so navigation handlers can be attached to specific webviews
            const _response = rpc.request.decideNavigation(.{
                .webviewId = webviewId,
                .url = fromCString(url),
            });

            return _response.allow;
        }
    }.decideNavigation);

    const bunBridgeHandler = objc.addScriptMessageHandlerWithCallback(objcWebview, opts.id, "bunBridge", struct {
        fn HandlePostMessageCallback(webviewId: u32, message: [*:0]const u8) void {
            // bun bridge just forwards messages to the bun

            var webview = webviewMap.get(webviewId) orelse {
                std.debug.print("Failed to get webview from hashmap for id {}\n", .{webviewId});
                return;
            };

            webview.sendToBun(fromCString(message)) catch |err| {
                std.debug.print("Failed to send message to bun: {}\n", .{err});
            };
        }
    }.HandlePostMessageCallback);

    // todo: only set this up if the webview tag is enabled for this webview
    const webviewTagHandler = objc.addScriptMessageHandlerWithCallback(objcWebview, opts.id, "webviewTagBridge", struct {
        fn HandlePostMessageCallback(webviewId: u32, message: [*:0]const u8) void {
            const msgString = fromCString(message);

            const json = std.json.parseFromSlice(std.json.Value, alloc, msgString, .{ .ignore_unknown_fields = true }) catch |err| {
                std.log.info("Error parsing line from stdin - {}: \nreceived: {s}", .{ err, msgString });
                return;
            };

            defer json.deinit();

            const msgType = blk: {
                const obj = json.value.object.get("type").?;
                break :blk obj.string;
            };

            if (std.mem.eql(u8, msgType, "request")) {
                const _request = std.json.parseFromValue(rpcTypes._RPCRequestPacket, alloc, json.value, .{}) catch |err| {
                    std.log.info("Error parsing line from stdin - {}: \nreceived: {s}", .{ err, msgString });
                    return;
                };

                const result = rpcHandlers.fromBrowserHandleRequest(_request.value);

                if (result.errorMsg == null) {
                    const responseSuccess = .{ .id = _request.value.id, .type = "response", .success = true, .payload = result };

                    var buffer = std.json.stringifyAlloc(alloc, responseSuccess, .{}) catch {
                        return;
                    };
                    defer alloc.free(buffer);

                    // Prepare the JavaScript function call
                    var jsCall = std.fmt.allocPrint(alloc, "window.__electrobun.receiveMessageFromZig({s})\n", .{buffer}) catch {
                        return;
                    };
                    defer alloc.free(jsCall);

                    sendLineToWebview(webviewId, jsCall);
                } else {
                    // todo: this doesn't work yet
                    // rpcStdout.sendResponseError(_request.value.id, result.errorMsg.?);
                }
            } else if (std.mem.eql(u8, msgType, "message")) {
                const _message = std.json.parseFromValue(rpcTypes._RPCMessagePacket, alloc, json.value, .{}) catch |err| {
                    std.log.info("Error parsing line from stdin - {}: \nreceived: {s}", .{ err, msgString });
                    return;
                };

                rpcHandlers.fromBrowserHandleMessage(_message.value);
            } else {
                std.log.info("it's an unhandled meatball", .{});
            }
        }
    }.HandlePostMessageCallback);

    const _webview = WebviewType{ //
        .id = opts.id,
        .frame = .{
            .width = opts.frame.width,
            .height = opts.frame.height,
            .x = opts.frame.x,
            .y = opts.frame.y,
        },
        .handle = objcWebview,
        .bun_out_pipe = bunPipeOutFileResult,
        .bun_in_pipe = bunPipeIn,
        .delegate = delegate,
        .bunBridgeHandler = bunBridgeHandler,
        .webviewTagHandler = webviewTagHandler,
    };

    webviewMap.put(opts.id, _webview) catch {
        std.log.info("Error putting webview into hashmap: ", .{});
        return;
    };
}

// todo: move everything to cStrings or non-CStrings. just pick one.
pub fn addPreloadScriptToWebview(objcWindow: *anyopaque, scriptOrPath: []const u8, allFrames: bool) void {
    var script: []const u8 = undefined;

    // If it's a views:// url safely load from disk otherwise treat it as js
    if (std.mem.startsWith(u8, scriptOrPath, ViewsScheme)) {
        const fileResult = assetFileLoader(toCString(scriptOrPath));
        script = fromCString(fileResult.fileContents);
    } else {
        script = scriptOrPath;
    }

    objc.addPreloadScriptToWebView(objcWindow, toCString(script), allFrames);
}

pub fn resizeWebview(opts: rpcSchema.BrowserSchema.messages.webviewTagResize) void {
    var webview = webviewMap.get(opts.id) orelse {
        std.debug.print("Failed to get webview from hashmap for id {}\n", .{opts.id});
        return;
    };
    // todo: update webview frame in the webviewMap.
    // not doing this yet to see when we run into issues. it's possible
    // we don't need to store this in zig at all since the "last one set"
    // is in bun or webview (in the case of webview tags) and "current one"
    // is in objc
    objc.resizeWebview(webview.handle, .{
        .origin = .{ .x = opts.frame.x, .y = opts.frame.y },
        .size = .{ .width = opts.frame.width, .height = opts.frame.height },
    });
}

pub fn loadURL(opts: rpcSchema.BunSchema.requests.loadURL.params) void {
    var webview = webviewMap.get(opts.webviewId) orelse {
        std.debug.print("Failed to get webview from hashmap for id {}\n", .{opts.webviewId});
        return;
    };

    // todo: consider updating url. we may not need it stored in zig though.
    // webview.url = need to use webviewMap.getPtr() then webview.*.url = opts.url
    objc.loadURLInWebView(webview.handle, toCString(opts.url));
}

pub fn loadHTML(opts: rpcSchema.BunSchema.requests.loadHTML.params) void {
    var webview = webviewMap.get(opts.webviewId) orelse {
        std.debug.print("Failed to get webview from hashmap for id {}\n", .{opts.webviewId});
        return;
    };

    // webview.html = opts.html;
    objc.loadHTMLInWebView(webview.handle, toCString(opts.html));
}

pub fn sendLineToWebview(webviewId: u32, line: []const u8) void {
    var webview = webviewMap.get(webviewId) orelse {
        std.debug.print("Failed to get webview from hashmap for id {}\n", .{webviewId});
        return;
    };

    webview.sendToWebview(line);
}

// todo: move to a util and dedup with window.zig
// todo: make buffer an arg
// todo: use a for loop with mem.copy for simpler concat
// template string concat with arbitrary number of params
fn concatOrFallback(comptime fmt: []const u8, params: anytype) []const u8 {
    var buffer: [250]u8 = undefined;
    const result = std.fmt.bufPrint(&buffer, fmt, params) catch |err| {
        std.log.info("Error concatenating string {}", .{err});
        return fmt;
    };

    return result;
}

// join two strings
pub fn concatStrings(a: []const u8, b: []const u8) []u8 {
    var totalLength: usize = a.len + b.len;
    var result = alloc.alloc(u8, totalLength) catch unreachable;

    std.mem.copy(u8, result[0..a.len], a);
    std.mem.copy(u8, result[a.len..totalLength], b);

    return result;
}

fn toCString(input: []const u8) [*:0]const u8 {
    // Attempt to allocate memory, handle error without bubbling it up
    const allocResult = alloc.alloc(u8, input.len + 1) catch {
        return "console.error('failed to allocate string');";
    };

    std.mem.copy(u8, allocResult, input); // Copy input to the allocated buffer
    allocResult[input.len] = 0; // Null-terminate
    return allocResult[0..input.len :0]; // Correctly typed slice with null terminator
}

fn fromCString(input: [*:0]const u8) []const u8 {
    return input[0..std.mem.len(input)];
}

pub fn readFileContentsFromDisk(filePath: []const u8) ![]const u8 {
    const ELECTROBUN_VIEWS_FOLDER = std.os.getenv("ELECTROBUN_VIEWS_FOLDER") orelse {
        // todo: return an error here
        return error.ELECTROBUN_VIEWS_FOLDER_NOT_SET;
    };

    // Note: resolve the path, then check if it's not a descendant
    const joinedPath = try std.fs.path.join(alloc, &.{ ELECTROBUN_VIEWS_FOLDER, filePath });
    const resolvedPath = try std.fs.path.resolve(alloc, &.{joinedPath});
    defer alloc.free(resolvedPath);
    const relativePath = try std.fs.path.relative(alloc, ELECTROBUN_VIEWS_FOLDER, resolvedPath);
    defer alloc.free(relativePath);

    // Should defend against trying to load content outside of the build/views folder
    // eg: relative and absolute urls
    // url: 'assets://mainview/index.html',
    // url: 'assets://mainview/../../bun/index.js', // /Users/yoav/code/electrobun/example/build/bun/index.js
    // url: 'assets://../bun/index.js', // /Users/yoav/code/electrobun/example/build/bun/index.js
    // url: 'assets://%2E%2E/bun/index.js',
    // url: 'assets:////Users/yoav/code/electrobun/example/build/bun/index.js', ///Users/yoav/code/electrobun/example/build/bun/index.js
    if (relativePath[0] == '.' and relativePath[1] == '.') {
        return error.InvalidPath;
    }

    const file = try std.fs.cwd().openFile(resolvedPath, .{});
    defer file.close();

    const fileSize = try file.getEndPos();
    var fileContents = try alloc.alloc(u8, fileSize);

    // Read the file contents into the allocated buffer
    _ = try file.readAll(fileContents);

    return fileContents;
}

// todo: move to string utils
pub fn getMimeType(filePath: []const u8) []const u8 {
    const extension = std.fs.path.extension(filePath);

    if (strEql(extension, ".html")) {
        return "text/html";
    } else if (strEql(extension, ".htm")) {
        return "text/html";
    } else if (strEql(extension, ".js")) {
        return "application/javascript";
    } else if (strEql(extension, ".json")) {
        return "application/json";
    } else if (strEql(extension, ".css")) {
        return "text/css";
    } else if (strEql(extension, ".png")) {
        return "image/png";
    } else if (strEql(extension, ".jpg")) {
        return "image/jpeg";
    } else if (strEql(extension, ".jpeg")) {
        return "image/jpeg";
    } else if (strEql(extension, ".gif")) {
        return "image/gif";
    } else if (strEql(extension, ".svg")) {
        return "image/svg+xml";
    } else if (strEql(extension, ".txt")) {
        return "text/plain";
    } else {
        return "application/octet-stream";
    }
}

fn findLastIndexOfChar(slice: []const u8, char: u8) ?usize {
    var i: usize = slice.len;
    while (i > 0) : (i -= 1) {
        if (slice[i - 1] == char) {
            return i - 1;
        }
    }
    return null;
}

// todo: move to string util (duplicated in handlers.zig)
pub fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
