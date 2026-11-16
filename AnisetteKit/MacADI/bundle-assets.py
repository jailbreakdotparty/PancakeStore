#!/usr/bin/env python3
"""Stage already-extracted Apple guest images for the native iOS runtime.

No ipatool executable or Go runtime is packaged. The input is the seven Apple
images matching ipatool v2.8.0's pinned macOS 27.0.1 (26A434) asset profile.
"""
import argparse
import hashlib
from pathlib import Path
import shutil

PROFILE = {
    "AppleMediaServices": (14813888, "95f4558aa2c0ccd9f96ed479e336b630b46bf4b4e0baabc1c1ac8c7d55e21ab4"),
    "commerce": (8092640, "76de40a4a32f691947cb926ce3b128d2fc446f7cac9755f831c406cf5a316ac9"),
    "adid": (9797952, "1fec225b6917206e3d9b00fe636c04878f82bfd06a87a4b6941711de60efab5b"),
    "CoreFP": (94842464, "2c30fa2b5f695fd66c0360dce72f54757d03ddb7107549715c12cb359a003b46"),
    "CoreFP.icxs": (7365344, "cb8f55330ec567da3e692dab5f5388bed0312dd9093340477c5759078cc2aa7b"),
    "fairplayd": (37689264, "28b4c7b2a5a0409c5020da55fc3984713a8e2b0eec8557076c8717f7166d003e"),
    "FairPlayIOKit": (2132320, "47452960ec010d3a80b02cceec73a65f8a9758850fd0fb7b2fdac7a5d1b81025"),
}


def stage(source: Path, destination: Path) -> None:
    # Validate the entire profile before publishing any file. Never ship a mix
    # of unverified images whose entry offsets no longer match the runtime.
    for name, (size, digest) in PROFILE.items():
        image = source / name
        if image.stat().st_size != size:
            raise ValueError(f"{name}: wrong size (expected {size})")
        if hashlib.sha256(image.read_bytes()).hexdigest() != digest:
            raise ValueError(f"{name}: SHA-256 does not match macOS 26A434")
    destination.mkdir(parents=True, exist_ok=True)
    for name in PROFILE:
        target = destination / name
        if (source / name).resolve() != target.resolve():
            shutil.copyfile(source / name, target)
    print(f"Staged {len(PROFILE)} verified Apple guest images in {destination}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="directory containing the seven extracted Apple images")
    parser.add_argument("--destination", type=Path,
                        default=Path(__file__).resolve().parents[1] / "SourcesMac/Resources/ModernADI")
    args = parser.parse_args()
    stage(args.source, args.destination)


if __name__ == "__main__":
    main()
