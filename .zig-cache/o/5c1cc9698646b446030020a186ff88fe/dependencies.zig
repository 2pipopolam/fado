pub const packages = struct {
    pub const @"122055beff332830a391e9895c044d33b15ea21063779557024b46169fb1984c6e40" = struct {
        pub const build_root = "/home/dohodyaga/.cache/zig/p/122055beff332830a391e9895c044d33b15ea21063779557024b46169fb1984c6e40";
        pub const build_zig = @import("122055beff332830a391e9895c044d33b15ea21063779557024b46169fb1984c6e40");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"1220d49524b81bc8a371237b9b68620c2042a12d1b1492c0cd59148bfbc2873bd542" = struct {
        pub const build_root = "/home/dohodyaga/.cache/zig/p/1220d49524b81bc8a371237b9b68620c2042a12d1b1492c0cd59148bfbc2873bd542";
        pub const build_zig = @import("1220d49524b81bc8a371237b9b68620c2042a12d1b1492c0cd59148bfbc2873bd542");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zigimg", "1220dd654ef941fc76fd96f9ec6adadf83f69b9887a0d3f4ee5ac0a1a3e11be35cf5" },
            .{ "zg", "122055beff332830a391e9895c044d33b15ea21063779557024b46169fb1984c6e40" },
        };
    };
    pub const @"1220dd654ef941fc76fd96f9ec6adadf83f69b9887a0d3f4ee5ac0a1a3e11be35cf5" = struct {
        pub const build_root = "/home/dohodyaga/.cache/zig/p/1220dd654ef941fc76fd96f9ec6adadf83f69b9887a0d3f4ee5ac0a1a3e11be35cf5";
        pub const build_zig = @import("1220dd654ef941fc76fd96f9ec6adadf83f69b9887a0d3f4ee5ac0a1a3e11be35cf5");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "vaxis", "1220d49524b81bc8a371237b9b68620c2042a12d1b1492c0cd59148bfbc2873bd542" },
};
