{ pkgs, ... }:

{
  # https://devenv.sh/basics/
  env.FADO_VERSION = "0.1.0";
  env.PROJECT_ROOT = builtins.toString ./.;

  # https://devenv.sh/packages/
  packages = with pkgs; [
    zig
    pkg-config
    portaudio
    
    # Development tools
    gdb
    valgrind
    
    # Code formatting and analysis
    zls # Zig Language Server
    
    # Build tools
    gnumake
    cmake
    
    # Documentation
    man
    
    # Version control
    git
  ];

  enterShell = ''
    export PATH="$PROJECT_ROOT/zig-out/bin:$PATH"
    echo "Fado development environment loaded!"
    echo "Project root: $PROJECT_ROOT"
    echo "Version: $FADO_VERSION"
  '';

  # https://devenv.sh/languages/
  languages.nix.enable = true;
  languages.zig.enable = true;

  # https://devenv.sh/scripts/
  scripts.build.exec = "zig build";
  scripts.run.exec = "zig build run";

  # https://devenv.sh/processes/
  processes = {
    app.exec = "zig build run";
    watch.exec = "zig build watch";
  };
}
