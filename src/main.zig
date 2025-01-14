const std = @import("std");
const c = @cImport({
    @cInclude("portaudio.h");
    @cInclude("minimp3.h");
    @cInclude("minimp3_ex.h");
});

const MAX_SAMPLES = 1024;
const SAMPLE_RATE = 44100;
const MP3_FRAME_MAX_SAMPLES = 1152 * 2; // Max samples per frame * 2 channels

const AudioError = error{
    PortAudioInitFailed,
    StreamOpenFailed,
    NoAudioLoaded,
    FileOpenError,
    DecodingError,
    OutOfMemory,
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
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.stream) |stream| {
            _ = c.Pa_CloseStream(stream);
        }
        _ = c.Pa_Terminate();
        if (self.samples.len > 0) {
            self.allocator.free(self.samples);
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

            // Get stereo samples
            const left_idx = self.current_sample;
            const right_idx = self.current_sample + 1;
            
            out[i * 2] = self.samples[left_idx];       // Left channel
            out[i * 2 + 1] = self.samples[right_idx];  // Right channel
            
            self.current_sample += 2; // Go to next stereo
        }

        return c.paContinue;
    }

    pub fn loadFile(self: *Self, file_path: []const u8) !void {
        // Clean up existing resources
        if (self.stream) |stream| {
            _ = c.Pa_CloseStream(stream);
            self.stream = null;
        }
        if (self.samples.len > 0) {
            self.allocator.free(self.samples);
            self.samples = &[_]f32{};
        }

        // Open and read the file
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            return AudioError.FileOpenError;
        };
        defer file.close();

        const file_size = file.getEndPos() catch {
            return AudioError.FileOpenError;
        };

        // Allocate buffer with error handling
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

        // Initialize decoder
        var mp3 = c.mp3dec_t{};
        c.mp3dec_init(&mp3);
        var first_frame = true;

        // Prepare decoding buffers with max frame size
        var mp3_info: c.mp3dec_frame_info_t = undefined;
        const pcm = self.allocator.alloc(i16, MP3_FRAME_MAX_SAMPLES) catch {
            return AudioError.OutOfMemory;
        };
        defer self.allocator.free(pcm);

        var total_samples = std.ArrayList(f32).init(self.allocator);
        defer total_samples.deinit();

        // Pre-allocate based on typical compression ratio
        try total_samples.ensureTotalCapacityPrecise(
            @divTrunc(file_size * 12, 1000) // Approximate based on 128kbps MP3
        );

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
                    std.debug.print("Detected sample rate: {d} Hz, Channels: {d}\n", .{self.sample_rate, self.channels});
                }
                
                const frame_samples = @as(usize, @intCast(samples));  // samples per channel
                var i: usize = 0;
                while (i < frame_samples) : (i += 1) {
                    // Calculate base index for stereo pair
                    const channels = @as(usize, @intCast(mp3_info.channels));
                    const base_idx = i * channels;
                    
                    // Store interleaved samples
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
        self.current_file = file_path;

        std.debug.print("Loaded file: {s} ({d} samples, {d}Hz, {d} channels)\n", .{
            file_path, 
            self.sample_count,
            self.sample_rate,
            self.channels
        });
    }

    pub fn play(self: *Self) !void {
        if (self.is_playing) return;
        if (self.sample_count == 0) return AudioError.NoAudioLoaded;

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
        std.debug.print("Playing: {s}\n", .{self.current_file});
    }

    pub fn pause(self: *Self) !void {
        if (!self.is_playing) return;
        _ = c.Pa_StopStream(self.stream.?);
        self.is_playing = false;
        std.debug.print("Paused\n", .{});
    }

    pub fn stop(self: *Self) !void {
        if (!self.is_playing) return;
        _ = c.Pa_StopStream(self.stream.?);
        self.current_sample = 0;
        self.is_playing = false;
        std.debug.print("Stopped\n", .{});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var player = try AudioPlayer.init(allocator);
    defer player.deinit();

    const stdin = std.io.getStdIn().reader();
    var buffer: [1024]u8 = undefined;

    std.debug.print("Fado - Terminal Music Player\n", .{});
    std.debug.print("Commands: load <file>, play, pause, stop, quit\n", .{});

    while (true) {
        std.debug.print("> ", .{});
        if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |input| {
            var iter = std.mem.split(u8, input, " ");
            const command = iter.next() orelse continue;

            if (std.mem.eql(u8, command, "quit")) {
                break;
            } else if (std.mem.eql(u8, command, "load")) {
                const file = iter.next() orelse {
                    std.debug.print("Usage: load <file>\n", .{});
                    continue;
                };
                player.loadFile(file) catch |err| {
                    std.debug.print("Error loading file: {}\n", .{err});
                    continue;
                };
            } else if (std.mem.eql(u8, command, "play")) {
                player.play() catch |err| {
                    std.debug.print("Error playing: {}\n", .{err});
                };
            } else if (std.mem.eql(u8, command, "pause")) {
                player.pause() catch |err| {
                    std.debug.print("Error pausing: {}\n", .{err});
                };
            } else if (std.mem.eql(u8, command, "stop")) {
                player.stop() catch |err| {
                    std.debug.print("Error stopping: {}\n", .{err});
                };
            } else {
                std.debug.print("Unknown command: {s}\n", .{command});
            }
        }
    }
}
