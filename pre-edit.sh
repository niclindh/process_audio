#!/bin/bash

# Pre-Edit Audio Script
# Usage: ./pre-edit.sh input.wav
#
# Step 1: Find silences longer than 1.2 seconds.
# Step 2: Shorten them to 1.2 seconds, with a 10 ms crossfade at each cut, and
#         apply the acompressor settings from compress-audio.sh.
# Step 3: Measure loudness with ebur128.
# Step 4: Normalize to -19 LUFS. When loudnorm would use linear mode, apply the
#         same gain with volume. Otherwise run the two-pass loudnorm.
#
# Output: <source directory>/<name>-stripped.wav (WAV, PCM)
# The script also reports how many seconds of audio were removed.

# Check arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 <input_file.wav>"
    echo "Example: $0 episode.wav"
    exit 1
fi

INPUT_FILE="$1"
TARGET_LUFS="-19"
TARGET_TP="-1.5"
TARGET_LRA="11"
COMPRESSOR="acompressor=threshold=-21dB:ratio=3:attack=10:release=100"
SILENCE_THRESHOLD="-30dB"
SILENCE_DURATION="1.2"
CROSSFADE_DURATION="0.01"

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found!"
    exit 1
fi

# Only .wav input is supported
INPUT_FILE_LOWER="$(printf '%s' "$INPUT_FILE" | tr '[:upper:]' '[:lower:]')"
case "$INPUT_FILE_LOWER" in
    *.wav) ;;
    *)
        echo "Error: Input file must be a .wav file."
        exit 1
        ;;
esac

# Build the output path: same directory, "-stripped" before the extension
INPUT_DIR="$(dirname -- "$INPUT_FILE")"
INPUT_BASE="$(basename -- "$INPUT_FILE")"
INPUT_NAME="${INPUT_BASE%.*}"
OUTPUT_FILE="$INPUT_DIR/${INPUT_NAME}-stripped.wav"

# Temporary files
TEMP_STRIPPED="$(mktemp "${TMPDIR:-/tmp}/stripped.XXXXXX.wav")"
TEMP_OUTPUT="$(mktemp)"
TEMP_JSON="$(mktemp)"
TEMP_DETECT="$(mktemp)"
TEMP_GRAPH="$(mktemp)"

cleanup() {
    rm -f "$TEMP_STRIPPED" "$TEMP_OUTPUT" "$TEMP_JSON" "$TEMP_DETECT" "$TEMP_GRAPH"
}
trap cleanup EXIT

# Original duration
ORIG_DURATION="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$INPUT_FILE")"
if ! [[ "$ORIG_DURATION" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Error: Could not determine the duration of '$INPUT_FILE'."
    exit 1
fi

# Original sample rate. The loudnorm filter upsamples to 192 kHz when it uses
# dynamic mode, so the output sample rate must be forced back to the input rate.
SAMPLE_RATE="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 "$INPUT_FILE")"
if ! [[ "$SAMPLE_RATE" =~ ^[0-9]+$ ]]; then
    echo "Error: Could not determine the sample rate of '$INPUT_FILE'."
    exit 1
fi

echo "Input file:        $INPUT_FILE"
echo "Output file:       $OUTPUT_FILE"
echo "Original duration: ${ORIG_DURATION}s"
echo "Sample rate:       ${SAMPLE_RATE} Hz"
echo ""

# Step 1: Find silences longer than SILENCE_DURATION seconds
echo "Step 1: Finding silences longer than ${SILENCE_DURATION}s (threshold ${SILENCE_THRESHOLD})..."
ffmpeg -hide_banner -nostats -loglevel info -i "$INPUT_FILE" \
    -af "silencedetect=noise=${SILENCE_THRESHOLD}:d=${SILENCE_DURATION}" \
    -f null - 2> "$TEMP_DETECT"

if [ $? -ne 0 ]; then
    echo "Error: Silence detection failed."
    cat "$TEMP_DETECT"
    exit 1
fi

# Step 2: Cut the silences, crossfade each cut, and compress
# The first SILENCE_DURATION seconds of each silence are kept and the rest is
# cut. Leading and trailing silences are shortened to SILENCE_DURATION seconds.
# The kept segments are joined with a CROSSFADE_DURATION crossfade. The
# crossfade overlaps two silent parts, so each shortened silence is still
# SILENCE_DURATION seconds long.
#
# asegment splits the audio at sample positions, so each frame goes to only
# one output. The unused segments go to anullsink. One acrossfade joins all
# kept segments. The awk program prints the number of crossfaded cuts.
CUT_COUNT="$(awk -v dur="$ORIG_DURATION" -v keep="$SILENCE_DURATION" -v xf="$CROSSFADE_DURATION" \
    -v rate="$SAMPLE_RATE" -v post="$COMPRESSOR" -v graph="$TEMP_GRAPH" '
function add(s, e) {
    if (done || e - s <= keep + xf) return
    if (s <= 0) { seg_start = e - keep; return }   # leading silence: no join
    if (e >= dur - 0.05) {                         # trailing silence: no join
        starts[n] = seg_start; ends[n] = s + keep; n++; done = 1; return
    }
    starts[n] = seg_start; ends[n] = s + keep; n++
    seg_start = e - xf
}
function split_at(t) { points = points (np++ ? "|" : "") int(t * rate + 0.5) }
BEGIN { n = 0; seg_start = 0; done = 0; in_sil = 0; np = 0; points = "" }
/silence_start:/ { s = $NF + 0; if (s < 0) s = 0; in_sil = 1; next }
/silence_end:/ {
    for (i = 1; i <= NF; i++) if ($i == "silence_end:") e = $(i + 1) + 0
    add(s, e); in_sil = 0; next
}
END {
    if (in_sil) add(s, dur)
    if (!done) { starts[n] = seg_start; ends[n] = -1; n++ }

    # Outputs alternate between unused audio ([dK]) and kept segments ([kK]).
    out = 0; outs = ""; sinks = ""; kept = ""
    for (i = 0; i < n; i++) {
        if (starts[i] > 0) {
            split_at(starts[i])
            outs = outs "[d" out "]"; sinks = sinks "[d" out "]anullsink;\n"; out++
        }
        outs = outs "[k" out "]"; kept = kept "[k" out "]"; out++
        if (ends[i] >= 0) split_at(ends[i])
    }
    if (ends[n - 1] >= 0) { outs = outs "[d" out "]"; sinks = sinks "[d" out "]anullsink;\n"; out++ }

    if (np > 0) {
        printf "[0:a]asegment=samples=%s%s;\n%s", points, outs, sinks > graph
        join = (n > 1) ? "acrossfade=inputs=" n ":d=" xf "," : ""
        printf "%s%s%s[out]\n", kept, join, post > graph
    } else {
        printf "[0:a]%s[out]\n", post > graph
    }
    print n - 1
}' "$TEMP_DETECT")"

if ! [[ "$CUT_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Error: Could not build the silence-cut filter graph."
    exit 1
fi

echo "Step 2: Cutting silences (${CUT_COUNT} cuts with ${CROSSFADE_DURATION}s crossfade) and compressing..."
ffmpeg -hide_banner -loglevel error -y -i "$INPUT_FILE" \
    -/filter_complex "$TEMP_GRAPH" -map "[out]" \
    -ar "$SAMPLE_RATE" \
    -c:a pcm_s16le "$TEMP_STRIPPED"

if [ $? -ne 0 ]; then
    echo "Error: Silence removal or compression failed."
    exit 1
fi

# Step 3: Measure loudness with ebur128
# ebur128 measures the same values as the loudnorm analysis pass, but it does
# not run the 192 kHz dynamic normalizer, so it is much faster.
echo "Step 3: Measuring loudness..."
ffmpeg -hide_banner -nostats -loglevel info -i "$TEMP_STRIPPED" \
    -af "ebur128=peak=true:framelog=quiet" \
    -f null - 2> "$TEMP_OUTPUT"

MEASURED="$(awk '
/Summary:/ { summary = 1 }
!summary { next }
$1 == "I:" { i = $2 }
$1 == "Threshold:" && thresh == "" { thresh = $2 }
$1 == "LRA:" { lra = $2 }
$1 == "Peak:" { tp = $2 }
END { print i, lra, tp, thresh }' "$TEMP_OUTPUT")"
read -r INPUT_I INPUT_LRA INPUT_TP INPUT_THRESH <<< "$MEASURED"

NUMBER_RE='^-?[0-9]+([.][0-9]+)?$'
if ! [[ "$INPUT_I" =~ $NUMBER_RE && "$INPUT_LRA" =~ $NUMBER_RE && "$INPUT_TP" =~ $NUMBER_RE && "$INPUT_THRESH" =~ $NUMBER_RE ]]; then
    echo "Error: Could not read the loudness measurement."
    echo "Measured values: I='$INPUT_I' LRA='$INPUT_LRA' TP='$INPUT_TP' thresh='$INPUT_THRESH'"
    cat "$TEMP_OUTPUT"
    exit 1
fi

# loudnorm uses linear mode (one gain for the whole file) when the gain does not
# push the true peak above TARGET_TP and the loudness range is within
# TARGET_LRA. Otherwise it uses dynamic mode.
GAIN="$(awk -v i="$INPUT_I" -v t="$TARGET_LUFS" 'BEGIN { printf "%.2f", t - i }')"
LINEAR="$(awk -v g="$GAIN" -v tp="$INPUT_TP" -v lra="$INPUT_LRA" -v ttp="$TARGET_TP" -v tlra="$TARGET_LRA" \
    'BEGIN { print (tp + g <= ttp && lra <= tlra) ? 1 : 0 }')"

echo "Measured: I=${INPUT_I} LUFS, LRA=${INPUT_LRA} LU, TP=${INPUT_TP} dBTP"

# Step 4: Loudness normalization, write WAV PCM
if [ "$LINEAR" = "1" ]; then
    # Linear mode is one gain change. volume applies it at the input sample
    # rate, without loudnorm's resampling to 192 kHz and back.
    echo "Step 4: Applying linear loudness normalization (${GAIN} dB)..."
    ffmpeg -hide_banner -loglevel error -y -i "$TEMP_STRIPPED" \
        -af "volume=${GAIN}dB" \
        -c:a pcm_s16le "$OUTPUT_FILE"
else
    # Dynamic mode needs target_offset from the loudnorm analysis pass, so run
    # the original two-pass loudnorm.
    echo "Step 4: Applying dynamic loudness normalization (two-pass loudnorm)..."
    ffmpeg -hide_banner -nostats -loglevel info -i "$TEMP_STRIPPED" \
        -af "loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:print_format=json" \
        -f null - 2> "$TEMP_OUTPUT"

    awk '/^{/,/^}/' "$TEMP_OUTPUT" > "$TEMP_JSON"
    if [ ! -s "$TEMP_JSON" ]; then
        echo "Error: Could not extract JSON from FFmpeg output"
        echo "FFmpeg output:"
        cat "$TEMP_OUTPUT"
        exit 1
    fi

    json_value() {
        grep "\"$1\"" "$TEMP_JSON" | sed "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/"
    }
    INPUT_I="$(json_value input_i)"
    INPUT_LRA="$(json_value input_lra)"
    INPUT_TP="$(json_value input_tp)"
    INPUT_THRESH="$(json_value input_thresh)"
    TARGET_OFFSET="$(json_value target_offset)"

    if [ -z "$INPUT_I" ] || [ -z "$INPUT_LRA" ] || [ -z "$INPUT_TP" ] || [ -z "$INPUT_THRESH" ] || [ -z "$TARGET_OFFSET" ]; then
        echo "Error: Failed to extract all required values from JSON"
        echo "Extracted values:"
        echo "  INPUT_I: '$INPUT_I'"
        echo "  INPUT_LRA: '$INPUT_LRA'"
        echo "  INPUT_TP: '$INPUT_TP'"
        echo "  INPUT_THRESH: '$INPUT_THRESH'"
        echo "  TARGET_OFFSET: '$TARGET_OFFSET'"
        exit 1
    fi

    ffmpeg -hide_banner -loglevel error -y -i "$TEMP_STRIPPED" \
        -af "loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:measured_I=${INPUT_I}:measured_LRA=${INPUT_LRA}:measured_TP=${INPUT_TP}:measured_thresh=${INPUT_THRESH}:offset=${TARGET_OFFSET}" \
        -ar "$SAMPLE_RATE" \
        -c:a pcm_s16le "$OUTPUT_FILE"
fi

if [ $? -ne 0 ]; then
    echo "Error: Loudness normalization failed."
    exit 1
fi

# Report how many seconds were stripped
OUTPUT_DURATION="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUTPUT_FILE")"
if ! [[ "$OUTPUT_DURATION" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Error: Could not determine the duration of '$OUTPUT_FILE'."
    exit 1
fi

STRIPPED_SECONDS="$(awk -v a="$ORIG_DURATION" -v b="$OUTPUT_DURATION" 'BEGIN { v = a - b; if (v < 0) v = 0; printf "%.2f", v }')"

echo ""
echo "✓ Done!"
echo "Output file:        $OUTPUT_FILE"
echo "Original duration:  ${ORIG_DURATION}s"
echo "Processed duration: ${OUTPUT_DURATION}s"
echo "Audio stripped:     ${STRIPPED_SECONDS}s"
