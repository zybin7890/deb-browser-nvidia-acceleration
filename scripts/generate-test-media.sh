#!/usr/bin/env bash
# Original, locally generated 1080p30 8-bit samples. No user media is uploaded.
set -euo pipefail
output_dir=${1:-test-media}
command -v ffmpeg >/dev/null || { echo 'Install ffmpeg with libx264, libvpx-vp9 and libsvtav1 encoders.' >&2; exit 1; }
mkdir -p "$output_dir"
ffmpeg -n -hide_banner -loglevel warning -f lavfi \
 -i testsrc2=size=1920x1080:rate=30 -t 6 -an -pix_fmt yuv420p \
 -c:v libx264 -preset veryfast -crf 25 "$output_dir/test-h264.mp4"
ffmpeg -n -hide_banner -loglevel warning -f lavfi \
 -i testsrc2=size=1920x1080:rate=30 -t 6 -an -pix_fmt yuv420p \
 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -crf 35 -b:v 0 \
 "$output_dir/test-vp9.webm"
ffmpeg -n -hide_banner -loglevel warning -f lavfi \
 -i testsrc2=size=1920x1080:rate=30 -t 6 -an -pix_fmt yuv420p \
 -c:v libsvtav1 -preset 12 -crf 40 -svtav1-params lp=4 \
 "$output_dir/test-av1.webm"
printf 'Generated samples in %s\n' "$output_dir"
