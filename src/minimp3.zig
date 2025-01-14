const std = @import("std");

pub const mp3dec_t = extern struct {
    mdct_overlap: [2][9 * 32]f32,
    qmf_state: [15 * 2 * 32]f32,
    reserv: i32,
    free_format_bytes: i32,
    header: [4]u8,
    reserv_buf: [511]u8,
};

pub const mp3dec_frame_info_t = extern struct {
    frame_bytes: i32,
    channels: i32,
    hz: i32,
    layer: i32,
    bitrate_kbps: i32,
};

pub extern fn mp3dec_init(dec: *mp3dec_t) void;
pub extern fn mp3dec_decode_frame(dec: *mp3dec_t, mp3: [*]const u8, mp3_bytes: i32, pcm: [*]i16, info: *mp3dec_frame_info_t) i32;
