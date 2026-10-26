{
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
  emscripten,
  cmake,
  ninja,
  python3,
  unzip,
  nlohmann_json,
  libzip,
  zstd,
}:

# OpenRCT2 compiled to WebAssembly (Release, scripting on), its web shell, the
# OpenRCT2 data it loads, and the loopback server + `orct2` agent CLI.
# The port URLs and hashes below are emscripten 6.0.9's; another version
# fetches different archives, which the sandbox refuses.
assert lib.assertMsg (emscripten.version == "6.0.9")
  "openrct2-web: port hashes match emscripten 6.0.9, got ${emscripten.version}";
let
  version = "0.5.6";

  src = fetchFromGitHub {
    owner = "OpenRCT2";
    repo = "OpenRCT2";
    rev = "v${version}";
    hash = "sha256-tEwTrk0iYBco/N4fa7HEwDKRo/WJihQEzVevzul/nKg=";
  };

  # OpenRCT2's own data dir (g2.dat, languages, objects, title sequences, sound
  # asset pack); the cross build skips generating it.
  portable = fetchurl {
    url = "https://github.com/OpenRCT2/OpenRCT2/releases/download/v${version}/OpenRCT2-v${version}-windows-portable-x64.zip";
    sha256 = "6c07393312a828f845c71c9c18cefe2da5b759fe2b17ee02fbb9e4540b396280";
  };

  # Emscripten ports, URLs and sha512s verbatim from tools/ports/*.py of the
  # emscripten in use; emscripten skips the download when .emscripten_url matches.
  ports = {
    sdl2 = {
      url = "https://github.com/libsdl-org/SDL/archive/release-2.32.10.zip";
      sha512 = "001738b610b42a8f8badfd6af3402f0a1a8601034adef0b8c702dd2b1951dc1b71b733a6779d97499b6f7314d226ec0c8dcffeb753f35a5c51e995ca20bdd459";
    };
    zlib = {
      url = "https://github.com/madler/zlib/archive/refs/tags/v1.3.2.tar.gz";
      sha512 = "16fea4df307a68cf0035858abe2fd550250618a97590e202037acd18a666f57afc10f8836cbbd472d54a0e76539d0e558cb26f059d53de52ff90634bbf4f47d4";
    };
    libpng = {
      url = "https://storage.googleapis.com/webassembly/emscripten-ports/libpng-1.6.58.tar.gz";
      sha512 = "177d81fd1ba1a46ff64da7f24260814876bd0a27ee5bed6dc9dbdd1fe28f3a67cb6f11c74a68f8380a9a7ab0d95c0022b847b1a3e4d939f2a562274627205789";
    };
    icu = {
      url = "https://github.com/unicode-org/icu/releases/download/release-68-2/icu4c-68_2-src.zip";
      sha512 = "12c3db5966c234c94e7918fb8acc8bd0838edc36a620f3faa788e7ff27b06f1aa431eb117401026e3963622b9323212f444b735d5c9dd3d0b82d772a4834b993";
    };
  };

  portFlags = "-sUSE_SDL=2 -sUSE_ZLIB=1 -sUSE_LIBPNG=1 -sUSE_ICU=1";

  seedPorts = lib.concatStrings (
    lib.mapAttrsToList (
      name: p:
      let
        archive = fetchurl { inherit (p) url sha512; };
      in
      ''
        mkdir -p "$EM_CACHE/ports/${name}"
        python3 -c 'import shutil,sys; shutil.unpack_archive(sys.argv[1], sys.argv[2], sys.argv[3])' \
          ${archive} "$EM_CACHE/ports/${name}" ${if lib.hasSuffix ".zip" p.url then "zip" else "gztar"}
        echo '${p.url}' > "$EM_CACHE/ports/${name}/.emscripten_url"
      ''
    ) ports
  );

  # Writable copy of emscripten's cache in $EM_CACHE.
  useCache = cache: ''
    export HOME=$TMPDIR EM_CACHE=$TMPDIR/emcache
    cp -r ${cache}/. "$EM_CACHE"
    chmod -R u+w "$EM_CACHE"
  '';

  # Ports built for OpenRCT2's flags plus zstd and libzip, all with -pthread.
  deps = stdenvNoCC.mkDerivation {
    pname = "openrct2-wasm-deps";
    inherit version;
    dontUnpack = true;
    dontUseCmakeConfigure = true;
    dontFixup = true;
    nativeBuildInputs = [
      emscripten
      cmake
      ninja
      python3
    ];
    buildPhase = ''
      runHook preBuild
      ${useCache "${emscripten}/share/emscripten/cache"}
      ${seedPorts}

      echo 'int main(){try{throw 1;}catch(int){}}' > warm.cpp
      em++ -O3 -pthread -fexceptions --bind ${portFlags} warm.cpp -o warm.js

      unpackSrc() {
        if [ -d "$1" ]; then cp -r "$1" "$2"; else mkdir "$2" && tar xf "$1" -C "$2" --strip-components=1; fi
        chmod -R u+w "$2"
      }
      prefix=$out
      sysroot=$EM_CACHE/sysroot
      emflags="-O3 -pthread"

      unpackSrc ${zstd.src} zstd
      emcmake cmake -S zstd/build/cmake -B zstd-build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$prefix \
        -DCMAKE_C_FLAGS="$emflags" \
        -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF \
        -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_MULTITHREAD_SUPPORT=OFF
      cmake --build zstd-build && cmake --install zstd-build

      unpackSrc ${libzip.src} libzip
      emcmake cmake -S libzip -B libzip-build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$prefix \
        -DCMAKE_C_FLAGS="$emflags" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF \
        -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF \
        -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF \
        -DENABLE_OPENSSL=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_COMMONCRYPTO=OFF \
        -DZLIB_INCLUDE_DIR=$sysroot/include \
        -DZLIB_LIBRARY=$sysroot/lib/wasm32-emscripten/libz.a
      cmake --build libzip-build && cmake --install libzip-build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -r "$EM_CACHE" $out/cache
      runHook postInstall
    '';
  };

  wasm = stdenvNoCC.mkDerivation {
    pname = "openrct2-wasm";
    inherit version src;
    patches = [
      ./patches/01-audio-samples.patch
      ./patches/02-skip-sleep.patch
      ./patches/03-sccontext-null-plugin.patch
      ./patches/04-agent-exports.patch
      ./patches/05-jobpool-inline.patch
      ./patches/06-png-to-file.patch
    ];
    nativeBuildInputs = [
      emscripten
      cmake
      ninja
      python3
    ];
    dontUseCmakeConfigure = true;

    # nixpkgs' clang is newer than the emsdk upstream CI pins; its new
    # warnings must not fail the build.
    postPatch = ''
      substituteInPlace CMakeLists.txt --replace-fail ' -Werror ' ' '
    '';

    configurePhase = ''
      runHook preConfigure
      ${useCache "${deps}/cache"}
      sysroot=$EM_CACHE/sysroot
      emcmake cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Emscripten \
        -DDISABLE_IPO=ON \
        -DOPENRCT2_USE_CCACHE=OFF \
        -DDISABLE_NETWORK=ON -DDISABLE_HTTP=ON -DDISABLE_TTF=ON -DDISABLE_FLAC=ON \
        -DDISABLE_VORBIS=ON -DDISABLE_DISCORD_RPC=ON -DDISABLE_OPENGL=ON \
        -DDISABLE_VERSION_CHECKER=ON -DENABLE_SCRIPTING=ON \
        -DDOWNLOAD_OBJECTS=OFF -DDOWNLOAD_TITLE_SEQUENCES=OFF \
        -DDOWNLOAD_OPENSFX=OFF -DDOWNLOAD_OPENMUSIC=OFF -DDOWNLOAD_REPLAYS=OFF \
        -DICU_INCLUDE_DIR=$sysroot/include \
        -DICU_DATA_LIBRARIES= -DICU_DT_LIBRARY_RELEASE= \
        -DLIBZIP_INCLUDE_DIRS=${deps}/include -DLIBZIP_LIBRARIES=${deps}/lib/libzip.a \
        -DZSTD_INCLUDE_DIRS=${deps}/include -DZSTD_LIBRARIES=${deps}/lib/libzstd.a \
        -DCMAKE_C_FLAGS="-pthread -O3" \
        -DEMSCRIPTEN_FLAGS="${portFlags} -pthread -O3 -isystem ${nlohmann_json}/include" \
        -DEMSCRIPTEN_EXPORTED_FUNCTIONS="_GetVersion,_main,_orct2_agent_call,_orct2_load_park,_orct2_advance" \
        -DEMSCRIPTEN_LDFLAGS="${portFlags} -sDEFAULT_TO_CXX -Wno-pthreads-mem-growth -sSAFE_HEAP=0 -sASSERTIONS=0 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=4GB -sINITIAL_MEMORY=1GB -sSTACK_SIZE=8388608 -sPTHREAD_POOL_SIZE=navigator.hardwareConcurrency+2 -pthread -sEXPORTED_RUNTIME_METHODS=ccall,FS,callMain,UTF8ToString,stringToNewUTF8 -lidbfs.js -sMODULARIZE=1 -sEXPORT_NAME=OPENRCT2_WEB -Wl,--export-if-defined=LoadGameCallback"
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      cmake --build build --target openrct2
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp build/openrct2.js build/openrct2.wasm $out/
      runHook postInstall
    '';
  };
in
stdenv.mkDerivation {
  pname = "openrct2-web";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [
    python3
    unzip
  ];
  buildInputs = [ python3 ];

  installPhase = ''
    runHook preInstall
    www=$out/share/openrct2-web/www
    mkdir -p $www/openrct2-data $out/bin

    cp ${wasm}/openrct2.js ${wasm}/openrct2.wasm $www/
    cp ${./web/index.html} $www/index.html
    cp ${./web/index.js} $www/index.js
    cp ${./web/bridge.js} $www/bridge.js
    cp ${./web/orct2-agent.js} $www/orct2-agent.js

    unzip -q ${portable} 'data/*' -d $TMPDIR/portable
    cp -r $TMPDIR/portable/data/. $www/openrct2-data/
    python3 - "$www/openrct2-data" "${version}" <<'PY'
    import json, os, sys
    root, version = sys.argv[1], sys.argv[2]
    files = sorted(
        os.path.relpath(os.path.join(d, f), root)
        for d, _, fs in os.walk(root) for f in fs
    )
    with open(os.path.join(root, "manifest.json"), "w") as fh:
        json.dump({"version": version, "files": files}, fh)
    PY

    install -m755 ${./server.py} $out/bin/openrct2-web
    install -m755 ${./orct2} $out/bin/orct2
    patchShebangs $out/bin
    runHook postInstall
  '';

  passthru = { inherit wasm deps; };

  meta = {
    description = "OpenRCT2 as WebAssembly with a loopback server and an agent API";
    homepage = "https://github.com/ocasazza/tern-openrct2";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
    mainProgram = "openrct2-web";
  };
}
