# Pinned Zstandard implementation

Upstream: https://github.com/facebook/zstd
Version: 1.5.7; revision `f8745da6ff1ad1e7bab384bd1f9d742439278e99`.
LICENSE, lib/zstd.h, lib/zstd_errors.h and lib/{common,compress,decompress}
are unmodified upstream bytes extracted with `git archive` at that revision.
NV uses the BSD license in LICENSE. `include/NVZstd.h` is the NV bridge header.

SwiftPM statically builds the portable C compressor/decompressor with assembly
and pre-1.0 Zstandard decoding disabled. No external libzstd installation is
needed, and the same sources build for Intel macOS, Apple Silicon and Linux.
Dictionary training and command-line tools are outside this target's current
source set. Future private-row dictionaries use this codec with separately
versioned, locally retained dictionary metadata.

`ZstdFrameV1` enforces NV's dictionary-free, single-frame provider profile through
the stable C API and the documented frame header. Node's independent Zstandard
implementation supplies fixed reader vectors and checks actual writer frames;
compressed-byte equality across encoder versions is not a protocol requirement.
