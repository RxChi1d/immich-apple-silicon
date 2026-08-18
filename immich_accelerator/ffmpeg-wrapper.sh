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
# Transcoding to 720p on an M1 Air, matched on SSIM against the downscaled
# source, hardware encoding costs 2.2x the bitrate and is not even faster:
#
#     libx264 -preset veryfast -crf 23   0.75 Mbps   SSIM 0.9544   379% CPU
#     h264_videotoolbox -q:v 55          1.62 Mbps   SSIM 0.9546   279% CPU
#
# The gap is not a thermal artifact of a short run. Held at full load for ten
# minutes on the fanless Air, libx264 settled 4.4% below its opening rate
# (345 -> 330 fps) while VideoToolbox stayed flat (311 -> 314 fps), and macOS
# recorded no thermal warning at all. Software still finished ahead: 11.4x
# realtime sustained against 10.7x.
#
# HEVC behaves the same way, more so: libx265 -preset veryfast -crf 28 gives
# 0.35 Mbps against hevc_videotoolbox -q:v 55 at 1.01 Mbps, same SSIM.
#
# Keep the decode side hardware regardless. Dropping -hwaccel videotoolbox
# along with the encoder remap took the same software encode from 379% CPU to
# 751%, because decoding 1920x1440 HEVC in software dominates everything else.
#
# Set IMMICH_ACCELERATOR_SW_ENCODE=0 for the original all-VideoToolbox
# behavior: one fewer core busy, at 2.2x the file size.
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
