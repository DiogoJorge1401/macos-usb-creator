#!/usr/bin/env python3
"""
Decode Apple pbzx streamed payload format.
pbzx is used inside .pkg files (Payload) — it wraps xz-compressed cpio data.

Usage: python3 pbzx_extract.py <input_pbzx> <output_dir>
"""
import struct, sys, lzma, subprocess, os, tempfile

def decode_pbzx(inpath, outpath):
    """Decode pbzx to raw cpio, then extract with cpio or bsdtar."""
    cpio_path = outpath + ".cpio"

    with open(inpath, "rb") as f:
        magic = f.read(4)
        if magic != b"pbzx":
            # Not pbzx — try raw cpio/gzip
            f.seek(0)
            with open(cpio_path, "wb") as out:
                out.write(f.read())
            extract_cpio(cpio_path, outpath)
            return

        flags = struct.unpack(">Q", f.read(8))[0]

        with open(cpio_path, "wb") as out:
            while True:
                hdr = f.read(16)
                if len(hdr) < 16:
                    break
                uncompressed_size, compressed_size = struct.unpack(">QQ", hdr)
                if compressed_size == 0:
                    break
                chunk = f.read(compressed_size)
                if len(chunk) == 0:
                    break

                # Check if chunk is xz compressed (magic: FD 37 7A 58 5A 00)
                if chunk[:6] == b"\xfd7zXZ\x00":
                    try:
                        decompressed = lzma.decompress(chunk)
                        out.write(decompressed)
                    except lzma.LZMAError:
                        out.write(chunk)
                else:
                    out.write(chunk)

    extract_cpio(cpio_path, outpath)
    os.unlink(cpio_path)

def extract_cpio(cpio_path, outpath):
    """Extract cpio archive using bsdtar (handles Apple's cpio variant)."""
    os.makedirs(outpath, exist_ok=True)

    # bsdtar handles Apple cpio better than GNU cpio
    try:
        subprocess.run(
            ["bsdtar", "-xf", cpio_path, "-C", outpath],
            check=True, capture_output=True
        )
        return
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    # Fallback to cpio
    try:
        with open(cpio_path, "rb") as f:
            subprocess.run(
                ["cpio", "-idm", "--no-absolute-filenames"],
                stdin=f, cwd=outpath, check=True, capture_output=True
            )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"Error extracting cpio: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <payload_file> <output_dir>")
        sys.exit(1)
    decode_pbzx(sys.argv[1], sys.argv[2])
    print(f"Extracted to {sys.argv[2]}")
