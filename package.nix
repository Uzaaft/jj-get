{
  lib,
  stdenv,
  zig,
}:

stdenv.mkDerivation {
  pname = "jj-get";
  version = "0.0.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./src
    ];
  };

  nativeBuildInputs = [ zig.hook ];

  doCheck = true;

  meta = {
    description = "Clone and organize jujutsu repositories by URL";
    license = lib.licenses.mit;
    mainProgram = "jj-get";
    platforms = lib.platforms.unix;
  };
}
