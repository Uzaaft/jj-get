{
  lib,
  stdenv,
  zig,
  git,
  jujutsu,
}:

let
  # Keep build.zig.zon the single source of truth for the version.
  zon = lib.splitString "\n" (builtins.readFile ./build.zig.zon);
  versionLine = lib.findFirst (
    line: builtins.match " *\\.version = \"(.*)\",.*" line != null
  ) null zon;
in
stdenv.mkDerivation {
  pname = "jj-get";
  version = builtins.head (builtins.match " *\\.version = \"(.*)\",.*" versionLine);

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./src
      ./test
    ];
  };

  nativeBuildInputs = [ zig.hook ];

  doCheck = true;
  nativeCheckInputs = [
    git
    jujutsu
  ];

  meta = {
    description = "Clone and organize jujutsu repositories by URL";
    license = lib.licenses.mit;
    mainProgram = "jj-get";
    platforms = lib.platforms.unix;
  };
}
