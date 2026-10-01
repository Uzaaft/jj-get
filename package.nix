{
  lib,
  stdenv,
  zig,
  git,
  jujutsu,
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
