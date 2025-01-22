const std = @import("std");
const vaxis = @import("vaxis");
const c = @cImport({
    @cInclude("portaudio.h");
    @cInclude("minimp3.h");
    @cInclude("minimp3_ex.h");
});

const MAX_SAMPLES = 1024;
const SAMPLE_RATE = 44100;
const MP3_FRAME_MAX_SAMPLES = 1152 * 2;

const AudioError = error{
    PortAudioInitFailed,
    StreamOpenFailed,
    NoAudioLoaded,
    FileOpenError,
    DecodingError,
    OutOfMemory,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const PlayerState = enum {
    stopped,
    playing,
    paused,
};

const Timer = struct {
    const Self = @This();
    start_time: i128,
    interval_ns: i128,

    pub fn init(interval_ms: i128) Self {
        return Self{
            .start_time = std.time.nanoTimestamp(),
            .interval_ns = interval_ms * std.time.ns_per_ms,
        };
    }

    pub fn check(self: *Self) bool {
        const current_time = std.time.nanoTimestamp();
        if (current_time - self.start_time >= self.interval_ns) {
            self.start_time = current_time;
            return true;
        }
        return false;
    }
};

const AudioCache = struct {
    samples: []f32,
    sample_count: usize,
    sample_rate: i32,
    channels: i32,
};

const AudioPlayer = struct {
    stream: ?*c.PaStream,
    is_playing: bool,
    current_file: []const u8,
    samples: []f32,
    sample_count: usize,
    current_sample: usize,
    sample_rate: i32,
    channels: i32,
    allocator: std.mem.Allocator,
    state: PlayerState,
    cache: std.StringHashMap(AudioCache),
    is_loading: bool,
    total_size: usize,
    loaded_size: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        if (c.Pa_Initialize() != c.paNoError) {
            return AudioError.PortAudioInitFailed;
        }

        return Self{
            .stream = null,
            .is_playing = false,
            .current_file = "",
            .samples = &[_]f32{},
            .sample_count = 0,
            .current_sample = 0,
            .sample_rate = 44100,
            .channels = 2,
            .allocator = allocator,
            .state = .stopped,
            .cache = std.StringHashMap(AudioCache).init(allocator),
            .is_loading = false,
            .total_size = 0,
            .loaded_size = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.stream) |stream| {
            _ = c.Pa_CloseStream(stream);
        }
        _ = c.Pa_Terminate();

        var cache_iter = self.cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.samples);
        }
        self.cache.deinit();

        if (self.samples.len > 0) {
            self.allocator.free(self.samples);
        }
        if (self.current_file.len > 0) {
            self.allocator.free(self.current_file);
        }
    }

    fn audioCallback(
        _: ?*const anyopaque,
        output: ?*anyopaque,
        frameCount: c_ulong,
        _: [*c]const c.PaStreamCallbackTimeInfo,
        _: c.PaStreamCallbackFlags,
        userData: ?*anyopaque,
    ) callconv(.C) c_int {
        const self = if (userData) |data| @as(*Self, @ptrCast(@alignCast(data))) else return c.paAbort;
        const out = if (output) |out_data| @as([*]f32, @ptrCast(@alignCast(out_data))) else return c.paAbort;

        var i: usize = 0;
        while (i < frameCount) : (i += 1) {
            if (self.current_sample >= self.sample_count) {
                self.current_sample = 0;
            }

            const left_idx = self.current_sample;
            const right_idx = self.current_sample + 1;

            out[i * 2] = self.samples[left_idx];
            out[i * 2 + 1] = self.samples[right_idx];

            self.current_sample += 2;
        }

        return c.paContinue;
    }

    pub fn loadFile(self: *Self, file_path: []const u8) !void {
        if (self.is_playing) {
            try self.stop();
        }

        if (self.stream) |stream| {
            _ = c.Pa_CloseStream(stream);
            self.stream = null;
        }

        const abs_path = if (std.fs.path.isAbsolute(file_path))
            try self.allocator.dupe(u8, file_path)
        else
            try std.fs.cwd().realpathAlloc(self.allocator, file_path);
        defer self.allocator.free(abs_path);

        if (self.cache.get(abs_path)) |cached| {
            if (self.samples.len > 0) {
                self.allocator.free(self.samples);
            }
            self.samples = try self.allocator.dupe(f32, cached.samples);
            self.sample_count = cached.sample_count;
            self.sample_rate = cached.sample_rate;
            self.channels = cached.channels;
            self.current_sample = 0;
            self.current_file = try self.allocator.dupe(u8, abs_path);
            return;
        }

        const file = try std.fs.openFileAbsolute(abs_path, .{});
        defer file.close();

        const file_size = file.getEndPos() catch {
            return AudioError.FileOpenError;
        };

        const buffer = self.allocator.alloc(u8, file_size) catch {
            return AudioError.OutOfMemory;
        };
        defer self.allocator.free(buffer);

        if (file.readAll(buffer) catch null) |bytes_read| {
            if (bytes_read != file_size) {
                return AudioError.FileOpenError;
            }
        } else {
            return AudioError.FileOpenError;
        }

        var mp3 = c.mp3dec_t{};
        c.mp3dec_init(&mp3);
        var first_frame = true;

        var mp3_info: c.mp3dec_frame_info_t = undefined;
        const pcm = self.allocator.alloc(i16, MP3_FRAME_MAX_SAMPLES) catch {
            return AudioError.OutOfMemory;
        };
        defer self.allocator.free(pcm);

        var total_samples = std.ArrayList(f32).init(self.allocator);
        defer total_samples.deinit();

        try total_samples.ensureTotalCapacityPrecise(@divFloor(file_size * 12, 1000));

        var input_pos: usize = 0;
        while (input_pos < buffer.len) {
            const samples = c.mp3dec_decode_frame(
                &mp3,
                buffer.ptr + input_pos,
                @intCast(@min(buffer.len - input_pos, std.math.maxInt(c_int))),
                pcm.ptr,
                &mp3_info,
            );

            if (samples > 0 and mp3_info.channels > 0) {
                if (first_frame) {
                    self.sample_rate = mp3_info.hz;
                    self.channels = mp3_info.channels;
                    first_frame = false;
                }

                const frame_samples = @as(usize, @intCast(samples));
                var i: usize = 0;
                while (i < frame_samples) : (i += 1) {
                    const channels = @as(usize, @intCast(mp3_info.channels));
                    const base_idx = i * channels;

                    const left = @as(f32, @floatFromInt(pcm[base_idx])) / 32768.0;
                    const right = if (channels > 1)
                        @as(f32, @floatFromInt(pcm[base_idx + 1])) / 32768.0
                    else
                        left;

                    try total_samples.append(left);
                    try total_samples.append(right);
                }
            }

            if (mp3_info.frame_bytes == 0) break;
            input_pos += @intCast(mp3_info.frame_bytes);
        }

        self.samples = try total_samples.toOwnedSlice();
        self.sample_count = self.samples.len;
        self.current_sample = 0;
        self.current_file = try self.allocator.dupe(u8, abs_path);

        try self.cache.put(try self.allocator.dupe(u8, abs_path), .{
            .samples = try self.allocator.dupe(f32, self.samples),
            .sample_count = self.sample_count,
            .sample_rate = self.sample_rate,
            .channels = self.channels,
        });
    }

    pub fn play(self: *Self) !void {
        if (self.sample_count == 0) return AudioError.NoAudioLoaded;

        if (self.is_playing) {
            try self.stop();
        }

        var output_params = std.mem.zeroes(c.PaStreamParameters);
        output_params.device = c.Pa_GetDefaultOutputDevice();
        output_params.channelCount = 2;
        output_params.sampleFormat = c.paFloat32;

        const device_info = c.Pa_GetDeviceInfo(output_params.device);
        if (device_info == null) return AudioError.StreamOpenFailed;
        output_params.suggestedLatency = device_info.*.defaultLowOutputLatency;
        output_params.hostApiSpecificStreamInfo = null;

        const err = c.Pa_OpenStream(
            &self.stream,
            null,
            &output_params,
            @floatFromInt(self.sample_rate),
            MAX_SAMPLES,
            c.paNoFlag,
            audioCallback,
            self,
        );

        if (err != c.paNoError) {
            return AudioError.StreamOpenFailed;
        }

        _ = c.Pa_StartStream(self.stream.?);
        self.is_playing = true;
        self.state = .playing;
    }

    pub fn pause(self: *Self) !void {
        if (!self.is_playing) return;
        _ = c.Pa_StopStream(self.stream.?);
        self.is_playing = false;
        self.state = .paused;
    }

    pub fn stop(self: *Self) !void {
        if (!self.is_playing) return;
        _ = c.Pa_StopStream(self.stream.?);
        self.current_sample = 0;
        self.is_playing = false;
        self.state = .stopped;
    }

    pub fn togglePlayPause(self: *Self) !void {
        if (self.is_playing) {
            try self.pause();
        } else {
            try self.play();
        }
    }

    pub fn clearCache(self: *Self) void {
        var cache_iter = self.cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.samples);
        }
        self.cache.clearAndFree();
    }
};

const FileEntry = struct {
    name: []const u8,
    is_dir: bool,
};

fn scanDirectory(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList(FileEntry) {
    var entries = std.ArrayList(FileEntry).init(allocator);

    if (!std.mem.eql(u8, dir_path, "/")) {
        try entries.append(.{ .name = try allocator.dupe(u8, ".."), .is_dir = true });
    }

    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        // dont show hidden dits
        if (entry.name[0] == '.' and !std.mem.eql(u8, entry.name, "..")) continue;

        switch (entry.kind) {
            .directory => {
                try entries.append(.{
                    .name = try allocator.dupe(u8, entry.name),
                    .is_dir = true,
                });
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".mp3")) {
                    try entries.append(.{
                        .name = try allocator.dupe(u8, entry.name),
                        .is_dir = false,
                    });
                }
            },
            else => {},
        }
    }

    // dirs first
    std.sort.insertion(FileEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            if (a.is_dir and !b.is_dir) return true;
            if (!a.is_dir and b.is_dir) return false;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    return entries;
}

fn drawInterface(
    allocator: std.mem.Allocator,
    win: *const vaxis.Window,
    entries: []FileEntry,
    selected: usize,
    current_dir: []const u8,
    player: *AudioPlayer,
) !void {
    const window_gap = 2;

    // file window
    const file_list = win.child(.{
        .width = @divFloor(win.width - window_gap, 3),
        .height = win.height - 3,
        .border = .{
            .where = .all,
            .style = .{ .fg = .{ .rgb = .{ 64, 128, 255 } } },
        },
    });

    // show dir
    _ = file_list.print(&[_]vaxis.Cell.Segment{.{
        .text = current_dir,
        .style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true },
    }}, .{});

    // show files
    for (entries, 0..) |entry, i| {
        var style = vaxis.Style{};
        if (i == selected) {
            style.reverse = true;
            style.bold = true;
        }

        const row_offset = @as(u16, @intCast(i + 1));

        if (entry.is_dir) {
            style.fg = .{ .rgb = .{ 255, 255, 0 } };
            _ = file_list.print(&[_]vaxis.Cell.Segment{.{
                .text = if (std.mem.eql(u8, entry.name, ".."))
                    ".."
                else
                    try std.fmt.allocPrint(allocator, "📁 {s}", .{entry.name}),
                .style = style,
            }}, .{ .row_offset = row_offset });
        } else {
            // is it currently playing ?
            if (player.current_file.len > 0) {
                const current_path = try std.fs.path.join(allocator, &[_][]const u8{ current_dir, entry.name });
                defer allocator.free(current_path);

                if (std.mem.eql(u8, current_path, player.current_file)) {
                    style.fg = .{ .rgb = .{ 0, 255, 0 } };
                }
            }

            _ = file_list.print(&[_]vaxis.Cell.Segment{.{
                .text = try std.fmt.allocPrint(allocator, "♪ {s}", .{entry.name}),
                .style = style,
            }}, .{ .row_offset = row_offset });
        }
    }

    if (player.is_loading) {
        const progress = @as(f32, @floatFromInt(player.loaded_size)) / @as(f32, @floatFromInt(player.total_size)) * 100;
        _ = file_list.print(&[_]vaxis.Cell.Segment{.{
            .text = try std.fmt.allocPrint(allocator, "Loading: {d:.1}%", .{progress}),
            .style = .{ .fg = .{ .rgb = .{ 255, 255, 0 } } },
        }}, .{});
    }

    const visualizer = win.child(.{
        .x_off = file_list.width + window_gap,
        .width = win.width - file_list.width - window_gap,
        .height = win.height - 3,
        .border = .{
            .where = .all,
            .style = .{ .fg = .{ .rgb = .{ 64, 128, 255 } } },
        },
    });

    // Draw visualizer
    if (player.sample_count > 0) {
        const viz_height = visualizer.height - 2;
        const viz_width = visualizer.width - 2;

        if (viz_width < 2 or viz_height < 1) return;

        const viz_column_gap = 1;
        const num_columns = @divFloor(viz_width, (1 + viz_column_gap));
        if (num_columns == 0) return;

        const window_samples = 8192;
        const current_pos = player.current_sample;
        const window_start = if (current_pos > window_samples / 2)
            current_pos - window_samples / 2
        else
            0;
        const window_end = @min(window_start + window_samples, player.sample_count);

        const samples_per_column = @divFloor(window_samples, num_columns);
        if (samples_per_column == 0) return;

        var column: usize = 0;
        while (column < num_columns) : (column += 1) {
            const start = window_start + column * samples_per_column;
            const end = @min(start + samples_per_column, window_end);

            var sum: f32 = 0;
            var count: usize = 0;

            var i = start;
            while (i < end) : (i += 2) {
                if (i >= player.sample_count) break;

                const left = @abs(player.samples[i]);
                const right = if (i + 1 < player.sample_count)
                    @abs(player.samples[i + 1])
                else
                    left;
                sum += (left + right) / 2.0;
                count += 1;
            }

            const avg = if (count > 0) sum / @as(f32, @floatFromInt(count)) else 0;
            const height = @as(usize, @intFromFloat(avg * @as(f32, @floatFromInt(viz_height)) * 3));

            const x = column * (1 + viz_column_gap);
            if (x < viz_width) {
                var row: usize = 0;
                while (row < height and row < viz_height) : (row += 1) {
                    visualizer.writeCell(
                        @intCast(x),
                        @intCast(viz_height - row),
                        .{
                            .char = .{ .grapheme = "█" },
                            .style = .{ .fg = .{ .rgb = .{ 64, 128, 255 } } },
                        },
                    );
                }
                while (row < viz_height) : (row += 1) {
                    visualizer.writeCell(
                        @intCast(x),
                        @intCast(viz_height - row),
                        .{
                            .char = .{ .grapheme = " " },
                            .style = .{},
                        },
                    );
                }
            }
        }
    }

    //controls window
    const controls = win.child(.{
        .y_off = win.height - 3,
        .width = win.width,
        .height = 3,
        .border = .{
            .where = .all,
            .style = .{ .fg = .{ .rgb = .{ 64, 128, 255 } } },
        },
    });

    const inner_controls = controls.child(.{
        .x_off = 1,
        .y_off = 1,
        .width = controls.width - 2,
        .height = 1,
    });

    _ = inner_controls.print(&[_]vaxis.Cell.Segment{
        .{ .text = " Controls: ", .style = .{ .bold = true } },
        .{ .text = "[", .style = .{} },
        .{ .text = "SPACE", .style = .{ .fg = .{ .rgb = .{ 0, 255, 0 } }, .bold = true } },
        .{ .text = "]", .style = .{} },
        .{ .text = " Play/Pause  " },
        .{ .text = "[", .style = .{} },
        .{ .text = "S", .style = .{ .fg = .{ .rgb = .{ 255, 0, 0 } }, .bold = true } },
        .{ .text = "]", .style = .{} },
        .{ .text = " Stop  " },
        .{ .text = "[", .style = .{} },
        .{ .text = "↑↓", .style = .{ .fg = .{ .rgb = .{ 255, 255, 0 } }, .bold = true } },
        .{ .text = "]", .style = .{} },
        .{ .text = " Navigate  " },
        .{ .text = "[", .style = .{} },
        .{ .text = "Enter", .style = .{ .fg = .{ .rgb = .{ 0, 255, 255 } }, .bold = true } },
        .{ .text = "]", .style = .{} },
        .{ .text = " Select  " },
        .{ .text = "[", .style = .{} },
        .{ .text = "Q", .style = .{ .fg = .{ .rgb = .{ 255, 128, 128 } }, .bold = true } },
        .{ .text = "]", .style = .{} },
        .{ .text = " Quit" },
    }, .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var player = try AudioPlayer.init(allocator);
    defer player.deinit();

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.anyWriter());

    // start from home
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch ".";
    var current_dir = try allocator.dupe(u8, home_dir);
    if (!std.mem.eql(u8, home_dir, ".")) {
        allocator.free(home_dir);
    }
    defer allocator.free(current_dir);

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    var entries = try scanDirectory(allocator, current_dir);
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }
        entries.deinit();
    }

    var selected_idx: usize = 0;

    // Add timer (30 fps)
    var refresh_timer = Timer.init(33);

    while (true) {
        const event = loop.tryEvent();

        if (event) |e| {
            switch (e) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                        break;
                    }

                    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                        if (selected_idx < entries.items.len -| 1) selected_idx += 1;
                    }
                    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                        if (selected_idx > 0) selected_idx -= 1;
                    }

                    if (key.matches(vaxis.Key.enter, .{})) {
                        if (selected_idx < entries.items.len) {
                            const selected = entries.items[selected_idx];
                            if (selected.is_dir) {
                                var new_path: []u8 = undefined;
                                if (std.mem.eql(u8, selected.name, "..")) {
                                    const parent = std.fs.path.dirname(current_dir) orelse "/";
                                    new_path = try allocator.dupe(u8, parent);
                                } else {
                                    new_path = try std.fs.path.join(allocator, &[_][]const u8{ current_dir, selected.name });
                                }

                                //clear old data
                                allocator.free(current_dir);
                                for (entries.items) |entry| {
                                    allocator.free(entry.name);
                                }
                                entries.clearAndFree();

                                //update dir
                                current_dir = new_path;
                                entries = try scanDirectory(allocator, current_dir);
                                selected_idx = 0;
                            } else {
                                // Play MP3
                                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ current_dir, selected.name });
                                defer allocator.free(full_path);
                                try player.loadFile(full_path);
                                try player.play();
                            }
                        }
                    }

                    if (key.matches(vaxis.Key.space, .{})) {
                        try player.togglePlayPause();
                    }

                    if (key.matches('s', .{})) {
                        try player.stop();
                    }
                },
                .winsize => |ws| try vx.resize(allocator, tty.anyWriter(), ws),
            }
        }

        // Refresh display
        if (refresh_timer.check()) {
            const win = vx.window();
            win.clear();
            try drawInterface(allocator, &win, entries.items, selected_idx, current_dir, &player);
            try vx.render(tty.anyWriter());
        }

        //Small delay
        std.time.sleep(1 * std.time.ns_per_ms);
    }
}
