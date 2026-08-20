#!/bin/bash
# VideoToolbox ffmpeg wrapper for Immich Accelerator
#
# Remaps software encoders to VideoToolbox hardware encoders.
# Uses jellyfin-ffmpeg which has tonemapx natively — no filter remapping needed.
#
# Immich doesn't support 'videotoolbox' as an accel option, so this wrapper
# remaps software encoder requests to VideoToolbox hardware equivalents.

REAL_FFMPEG="/opt/homebrew/bin/ffmpeg"

# macOS ships no `timeout`, and a hung qlmanage would hold a thumbnail job open
# forever. Run the command, kill it if it outstays the limit.
_ql_timeout() {
    local secs=$1; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
    local killer=$!
    wait "$pid" 2>/dev/null; local rc=$?
    kill "$killer" 2>/dev/null
    return $rc
}

# Used by the QuickLook fallback below to convert its PNG output to whatever
# format Immich asked for.
if [[ -n "${IMMICH_ACCELERATOR_VIPS:-}" ]]; then
    VIPS_BIN="$IMMICH_ACCELERATOR_VIPS"
elif [[ -x "/opt/homebrew/bin/vips" ]]; then
    VIPS_BIN="/opt/homebrew/bin/vips"
else
    VIPS_BIN="/usr/local/bin/vips"
fi

ARGS=("$@")
# USE_HW gates hardware *decoding* (-hwaccel videotoolbox); USE_VTENC gates
# hardware *encoding*. Splitting them allows the combination that actually
# serves a photo library: decode on the media engine, encode in software.
#
# Software encoding is chosen for bitrate efficiency, not for speed.
#
# Matched on quality against the downscaled source over six clips and five
# metrics (SSIM, MS-SSIM, LPIPS-AlexNet, LPIPS-VGG, DISTS), h264_videotoolbox
# needs 1.7x to 3.2x the bits of libx264 -preset veryfast for the same result.
# hevc_videotoolbox against libx265 -preset veryfast is about 2.0x. Both
# encoders must be forced to -pix_fmt yuv420p to compare: left alone, x264
# encodes a 10-bit source as High 10 while VideoToolbox falls back to 8-bit.
#
# VideoToolbox is cheaper in CPU, and by how much depends on the decode load.
# On a 4K60 HEVC source the whole job is decode bound and software encoding
# costs 11% more CPU (9.61s against 10.65s); on 1080p SDR it costs about 2.4x
# (1.94s against 4.15-4.83s).
#
# It is not a throughput win. Held at full load for ten minutes on the fanless
# Air, neither encoder throttled and macOS recorded no thermal or performance
# warning, but VideoToolbox sustained the higher rate (230 fps against 203).
# Short runs can reverse that, because VideoToolbox pays a session setup cost
# the average amortizes away.
#
# Keep the decode side on hardware regardless. Dropping -hwaccel videotoolbox
# took the same software encode of a 4K60 HEVC clip from 10.77s to 47.07s of
# CPU, 4.4x, and the wall clock from 3.48s to 6.23s.
#
# Set IMMICH_ACCELERATOR_SW_ENCODE=0 for the original all-VideoToolbox
# behavior: less CPU, at roughly twice the file size.
SW_ENCODE="${IMMICH_ACCELERATOR_SW_ENCODE:-1}"

USE_HW=false
USE_VTENC=false
USE_HEVC=false
HAS_HEVC_TAG=false
NEW_ARGS=()

for ((i=0; i<${#ARGS[@]}; i++)); do
    arg="${ARGS[$i]}"

    # Remap Immich's encoder request. Either way this is a video encode, so
    # turn on hardware decoding; only the encoder itself is conditional.
    if [[ "$arg" == "-c:v" || "$arg" == "-vcodec" ]]; then
        next="${ARGS[$((i+1))]:-}"
        case "$next" in
            h264|libx264|libx264rgb)
                if [[ "$SW_ENCODE" == "1" ]]; then
                    NEW_ARGS+=("$arg" "libx264")
                else
                    NEW_ARGS+=("$arg" "h264_videotoolbox")
                    USE_VTENC=true
                fi
                ((i++))
                USE_HW=true
                continue
                ;;
            hevc|libx265)
                if [[ "$SW_ENCODE" == "1" ]]; then
                    NEW_ARGS+=("$arg" "libx265")
                else
                    NEW_ARGS+=("$arg" "hevc_videotoolbox")
                    USE_VTENC=true
                fi
                ((i++))
                USE_HW=true
                USE_HEVC=true
                continue
                ;;
        esac
    fi

    # Strip -preset for VideoToolbox (doesn't support CPU presets). Under
    # software encoding libx264 wants it, and it is the only reason Immich's
    # own preset setting has any effect at all on this platform.
    if [[ "$arg" == "-preset" && "$USE_VTENC" == true ]]; then
        ((i++))
        continue
    fi

    # Track if -tag:v is already specified (including stream-specific -tag:v:0 etc.)
    [[ "$arg" == -tag:v* ]] && HAS_HEVC_TAG=true

    NEW_ARGS+=("$arg")
done

if [[ "$USE_HW" == true ]]; then
    # Ensure HEVC output uses hvc1 tag (Apple-compatible).
    # hev1 (ffmpeg default) stores parameter sets in-band — Apple's
    # decoder rejects it. Immich usually passes -tag:v hvc1 itself,
    # but if it's absent we inject it before the output filename.
    # libx265 defaults to hev1 as well, so this applies to both encoders.
    if [[ "$USE_HEVC" == true && "$HAS_HEVC_TAG" == false ]]; then
        len=${#NEW_ARGS[@]}
        LAST="${NEW_ARGS[$((len-1))]}"
        NEW_ARGS=("${NEW_ARGS[@]:0:$((len-1))}" "-tag:v" "hvc1" "$LAST")
    fi
    RUN_ARGS=(-hwaccel videotoolbox "${NEW_ARGS[@]}")
else
    RUN_ARGS=("${NEW_ARGS[@]}")
fi

# Run ffmpeg with stderr captured, so the fallback below can tell a decoder
# rejection (what it is for) from a broken file or bad arguments (what it must
# not paper over). The wrapper is the parent rather than exec'ing, because it
# has work to do afterwards; forward the usual signals so killing the wrapper
# still kills ffmpeg instead of orphaning it.
# Explicit X's: BSD mktemp accepts a bare -t template, GNU requires them,
# and the wrapper's tests run on Linux in CI even though it only ever
# executes on macOS.
FF_ERR=$(mktemp "${TMPDIR:-/tmp}/immich-ffmpeg-err.XXXXXX")
cleanup() { rm -f "$FF_ERR"; [[ -n "${QL_DIR:-}" ]] && rm -rf "$QL_DIR"; }
trap cleanup EXIT
"$REAL_FFMPEG" "${RUN_ARGS[@]}" 2> >(tee "$FF_ERR" >&2) &
FF_PID=$!
trap 'kill -TERM "$FF_PID" 2>/dev/null' TERM INT
wait "$FF_PID"
STATUS=$?
trap - TERM INT
[[ $STATUS -eq 0 ]] && exit 0

# ffmpeg's HEVC decoder can hard-reject a stream that macOS's AVFoundation
# decodes fine (seen on real HDR10 phone clips; a stock Homebrew ffmpeg build
# fails identically, so this isn't jellyfin-ffmpeg-specific). Only retry via
# QuickLook for a single-frame thumbnail (`-frames:v 1`): a full transcode has
# no single frame for QuickLook to hand back.
IS_SINGLE_FRAME=false
INPUT=""
for ((i=0; i<${#ARGS[@]}; i++)); do
    if [[ "${ARGS[$i]}" == "-frames:v" && "${ARGS[$((i+1))]:-}" == "1" ]]; then
        IS_SINGLE_FRAME=true
    fi
    if [[ "${ARGS[$i]}" == "-i" ]]; then
        INPUT="${ARGS[$((i+1))]:-}"
    fi
done
OUTPUT="${ARGS[${#ARGS[@]}-1]}"

# Only a decode failure. Falling back on ANY non-zero exit meant a truncated
# upload, a seek past the end, or a file ffmpeg cannot demux still produced a
# poster frame from container metadata and exited 0, so Immich recorded a
# corrupt asset as successfully thumbnailed and nobody ever found out.
DECODE_REJECTED=false
if grep -qiE "(error while decoding|failed to open codec|no frame|invalid data found|decoder.*(not found|failed)|hevc.*(error|unsupported))" "$FF_ERR" 2>/dev/null; then
    DECODE_REJECTED=true
fi

if [[ "$IS_SINGLE_FRAME" == true && "$DECODE_REJECTED" == true && -n "$INPUT" \
      && ( "$OUTPUT" == *.jpg || "$OUTPUT" == *.jpeg || "$OUTPUT" == *.png || "$OUTPUT" == *.webp ) ]]; then
    QL_DIR=$(mktemp -d)
    # Immich's own `scale=W:H` filter carries the target; one side is -2,
    # meaning "preserve aspect ratio", so take whichever side is positive.
    SCALE_ARG=$(printf '%s\n' "${ARGS[@]}" | grep -o 'scale=[0-9-]*:[0-9-]*' | head -1)
    QL_SIZE=$(echo "$SCALE_ARG" | grep -oE '[0-9]+' | sort -rn | head -1)
    [[ -z "$QL_SIZE" ]] && QL_SIZE=1080
    # Which side that number refers to matters: qlmanage -s fits the frame in
    # an N-by-N box, so asking for 1440 on a landscape clip returns 1440 wide,
    # not 1440 tall. Measured on a real video: -s 1440 gave 960x720. Ask
    # QuickLook for something generous and let vips do the actual resize to
    # the dimension Immich asked for, or every fallback thumbnail is smaller
    # than requested and permanently so, because Immich records success.
    SCALE_W=${SCALE_ARG#scale=}; SCALE_W=${SCALE_W%%:*}
    SCALE_H=${SCALE_ARG##*:}
    # qlmanage needs a WindowServer session and can hang without one, so cap
    # it: a thumbnail job that never returns is worse than one that fails.
    if command -v qlmanage >/dev/null 2>&1 \
       && _ql_timeout 30 qlmanage -t -s $((QL_SIZE * 2)) -o "$QL_DIR" "$INPUT" >/dev/null 2>&1; then
        QL_RESULT=$(find "$QL_DIR" -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) -print -quit)
        if [[ -n "$QL_RESULT" ]]; then
            # vips, not sips: sips cannot write webp, which this install uses.
            if [[ "$SCALE_H" =~ ^[0-9]+$ ]]; then
                RESIZE=("--height" "$SCALE_H")
            else
                RESIZE=("--width" "${SCALE_W:-$QL_SIZE}")
            fi
            if "$VIPS_BIN" thumbnail "$QL_RESULT" "$OUTPUT" "${RESIZE[@]:1:1}" >/dev/null 2>&1 \
               || "$VIPS_BIN" copy "$QL_RESULT" "$OUTPUT" >/dev/null 2>&1; then
                echo "[immich-accelerator] ffmpeg couldn't decode $INPUT for a thumbnail; QuickLook/AVFoundation produced one instead" >&2
                exit 0
            fi
        fi
    fi
fi

exit "$STATUS"
