#!/usr/bin/env python3
"""Prepare pinned build dependencies for Impeller2D on Apple Silicon."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = "6e79542b39c1859158abf6f288c963bf0f855aab"
SKIA = "d87a6c04da74bda165bee5d5de67e8c60f7df3a9"
FLATBUFFERS = "067bfdbde9b10c1beb5d6b02d67ae9db8b96f736"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(cache, name, url, digest, local=None):
    if local:
        if sha256(local) != digest:
            raise SystemExit(f"SHA-256 mismatch for {local}")
        return local
    path = cache / name
    if path.is_file() and sha256(path) == digest:
        return path
    partial = path.with_suffix(".partial")
    run("curl", "--fail", "--location", "--retry", "3", "--output", partial, url)
    if sha256(partial) != digest:
        partial.unlink()
        raise SystemExit(f"SHA-256 mismatch for {url}")
    partial.replace(path)
    return path


def unpack_source(archive, destination, revision):
    marker = destination / ".impeller2d-revision"
    if marker.is_file() and marker.read_text().strip() == revision:
        return
    if destination.exists():
        raise SystemExit(f"Move {destination} aside before installing {revision}")
    with tempfile.TemporaryDirectory(dir=destination.parent) as temp:
        with tarfile.open(archive) as source:
            source.extractall(temp, filter="data")
        checkout, = Path(temp).iterdir()
        (checkout / marker.name).write_text(revision + "\n")
        checkout.rename(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deps", type=Path, default=ROOT / ".deps")
    parser.add_argument("--sdk-zip", type=Path, help="Install impellerc from a local SDK archive")
    parser.add_argument("--shader-tools", action="store_true", help="Install the optional impellerc tool")
    parser.add_argument("--gn", type=Path, help="Use an existing GN executable")
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 4, 12))
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("This bootstrap supports native Apple Silicon macOS.")
    if sys.version_info < (3, 12):
        raise SystemExit("Use Python 3.12 or newer to bootstrap dependencies.")
    if args.jobs < 1:
        parser.error("--jobs must be positive")

    deps = args.deps.resolve()
    cache = deps / "downloads"
    cache.mkdir(parents=True, exist_ok=True)
    skia = deps / "skia"
    flatbuffers = deps / "flatbuffers"
    for name, revision, destination, digest in [
        ("google/skia", SKIA, skia,
         "e05690f528bd07297773f42f92aeb929d8b0d10c19ce6d05a1266d72c9771e55"),
        ("google/flatbuffers", FLATBUFFERS, flatbuffers,
         "2856cd1d36515e381620ef6d58802c8edf2061e694c06004b1a4f0e1f7998f95"),
    ]:
        archive = download(cache, f"{destination.name}-{revision}.tar.gz",
                           f"https://codeload.github.com/{name}/tar.gz/{revision}", digest)
        unpack_source(archive, destination, revision)

    compiler = deps / "impellerc"
    compiler_marker = deps / "impellerc-revision"
    if args.shader_tools or args.sdk_zip:
        if (not compiler.is_file() or not compiler_marker.is_file()
                or compiler_marker.read_text().strip() != UPSTREAM):
            sdk = download(
                cache, f"impeller-sdk-{UPSTREAM}-darwin-arm64.zip",
                f"https://storage.googleapis.com/flutter_infra_release/flutter/{UPSTREAM}"
                "/darwin-arm64/impeller_sdk.zip",
                "e2ab1b7f9f5c622b0153c45b0af71c4ad2fda3cb387cf8eb03e680122f38fb71",
                args.sdk_zip,
            )
            partial = compiler.with_suffix(".partial")
            with ZipFile(sdk) as archive, archive.open("bin/impellerc") as shader_tool:
                with partial.open("wb") as dest:
                    shutil.copyfileobj(shader_tool, dest)
            partial.chmod(0o755)
            partial.replace(compiler)
            compiler_marker.write_text(UPSTREAM + "\n")

    icu = Path(output("brew", "--prefix", "icu4c"))
    harfbuzz = Path(output("brew", "--prefix", "harfbuzz"))
    if args.gn:
        gn = args.gn.resolve()
    else:
        gn = skia / "bin/gn"
        if not gn.is_file():
            run(sys.executable, skia / "bin/fetch-gn")

    skia_build = skia / "out/impeller"
    cflags = json.dumps([f"-I{icu / 'include'}",
                         f"-I{harfbuzz / 'include/harfbuzz'}"])
    gn_args = [
        "is_official_build=true", "is_debug=false", 'target_cpu="arm64"',
        "skia_use_partition_alloc=false", "skia_enable_tools=false",
        "skia_enable_ganesh=false", "skia_enable_graphite=false",
        "skia_enable_pdf=false", "skia_enable_skottie=false",
        "skia_enable_svg=false", "skia_use_expat=false",
        "skia_use_libjpeg_turbo_decode=false", "skia_use_libjpeg_turbo_encode=false",
        "skia_use_libpng_decode=false", "skia_use_libpng_encode=false",
        "skia_use_libwebp_decode=false", "skia_use_libwebp_encode=false",
        "skia_use_wuffs=false", "skia_use_piex=false", "skia_use_dng_sdk=false",
        "skia_use_zlib=false", "skia_use_freetype=false",
        "skia_use_icu=true", "skia_use_system_icu=true",
        "skia_use_harfbuzz=true", "skia_use_system_harfbuzz=true",
        f"extra_cflags={cflags}",
    ]
    run(gn, "gen", skia_build, f"--root={skia}", "--args=" + " ".join(gn_args))
    run("ninja", "-C", skia_build, "-j", args.jobs,
        "skia", "skparagraph", "skshaper", "skunicode_core", "skunicode_icu")

    flat_build = deps / "flatbuffers-build"
    run("cmake", "-S", flatbuffers, "-B", flat_build, "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release", "-DFLATBUFFERS_BUILD_TESTS=OFF")
    run("cmake", "--build", flat_build, "--target", "flatc", "--parallel", args.jobs)
    print(f"Dependencies ready in {deps}")


if __name__ == "__main__":
    main()
