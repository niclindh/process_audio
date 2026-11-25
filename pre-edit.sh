#!/bin/bash

# Pre-Edit Audio Script
# Usage: ./pre-edit.sh input.wav
#
# Step 1: Strip silences longer than 1.2 seconds. Each cut gets a 10 ms
#         crossfade.
# Step 2: Apply the compression + loudness normalization chain from
#         compress-audio.sh (acompressor + two-pass loudnorm).
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

# Step 1: Strip silences longer than 1.2 seconds, with a crossfade at each cut
# silencedetect finds each silence longer than SILENCE_DURATION seconds. The
# first SILENCE_DURATION seconds of each silence are kept and the rest is cut.
# Leading and trailing silences are shortened to SILENCE_DURATION seconds.
# The kept segments are joined with a CROSSFADE_DURATION crossfade. The
# crossfade overlaps two silent parts, so each shortened silence is still
# SILENCE_DURATION seconds long.
echo "Step 1: Stripping silences longer than ${SILENCE_DURATION}s (threshold ${SILENCE_THRESHOLD}, ${CROSSFADE_DURATION}s crossfade)..."
ffmpeg -hide_banner -nostats -loglevel info -i "$INPUT_FILE" \
    -af "silencedetect=noise=${SILENCE_THRESHOLD}:d=${SILENCE_DURATION}" \
    -f null - 2> "$TEMP_DETECT"

if [ $? -ne 0 ]; then
    echo "Error: Silence detection failed."
    cat "$TEMP_DETECT"
    exit 1
fi

# Build the filter graph: one atrim per kept segment, then one acrossfade
# over all segments. Prints the number of crossfaded cuts.
CUT_COUNT="$(awk -v dur="$ORIG_DURATION" -v keep="$SILENCE_DURATION" -v xf="$CROSSFADE_DURATION" -v graph="$TEMP_GRAPH" '
function add(s, e) {
    if (done || e - s <= keep + xf) return
    if (s <= 0) { seg_start = e - keep; return }   # leading silence: no join
    if (e >= dur - 0.05) {                         # trailing silence: no join
        starts[n] = seg_start; ends[n] = s + keep; n++; done = 1; return
    }
    starts[n] = seg_start; ends[n] = s + keep; n++
    seg_start = e - xf
}
BEGIN { n = 0; seg_start = 0; done = 0; in_sil = 0 }
/silence_start:/ { s = $NF + 0; if (s < 0) s = 0; in_sil = 1; next }
/silence_end:/ {
    for (i = 1; i <= NF; i++) if ($i == "silence_end:") e = $(i + 1) + 0
    add(s, e); in_sil = 0; next
}
END {
    if (in_sil) add(s, dur)
    if (!done) { starts[n] = seg_start; ends[n] = -1; n++ }
    if (n > 1) {
        line = "[0:a]asplit=" n
        for (i = 0; i < n; i++) line = line "[a" i "]"
        print line ";" > graph
    }
    for (i = 0; i < n; i++) {
        src = (n > 1) ? "[a" i "]" : "[0:a]"
        dst = (n > 1) ? "[s" i "]" : "[out]"
        end_opt = (ends[i] >= 0) ? sprintf(":end=%.6f", ends[i]) : ""
        printf "%satrim=start=%.6f%s,asetpts=PTS-STARTPTS%s%s\n", src, starts[i], end_opt, dst, (n > 1) ? ";" : "" > graph
    }
    if (n > 1) {
        line = ""
        for (i = 0; i < n; i++) line = line "[s" i "]"
        print line "acrossfade=inputs=" n ":d=" xf "[out]" > graph
    }
    print n - 1
}' "$TEMP_DETECT")"

if ! [[ "$CUT_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Error: Could not build the silence-cut filter graph."
    exit 1
fi

echo "Cuts with crossfade: ${CUT_COUNT}"
ffmpeg -hide_banner -loglevel error -y -i "$INPUT_FILE" \
    -/filter_complex "$TEMP_GRAPH" -map "[out]" \
    -ar "$SAMPLE_RATE" \
    -c:a pcm_s16le "$TEMP_STRIPPED"

if [ $? -ne 0 ]; then
    echo "Error: Silence removal failed."
    exit 1
fi

# Step 2: Pass 1 - analysis of the silence-stripped audio
echo "Step 2: Analyzing loudness of the stripped audio..."
ffmpeg -hide_banner -loglevel info -i "$TEMP_STRIPPED" \
    -af "acompressor=threshold=-21dB:ratio=3:attack=10:release=100,loudnorm=I=${TARGET_LUFS}:TP=-1.5:LRA=11:print_format=json" \
    -f null - 2> "$TEMP_OUTPUT"

# Extract the loudnorm JSON block
awk '/^{/,/^}/' "$TEMP_OUTPUT" > "$TEMP_JSON"
if [ ! -s "$TEMP_JSON" ]; then
    sed -n '/^{$/,/^}$/p' "$TEMP_OUTPUT" > "$TEMP_JSON"
fi
if [ ! -s "$TEMP_JSON" ]; then
    grep -A 20 "loudnorm" "$TEMP_OUTPUT" | sed -n '/^{$/,/^}$/p' > "$TEMP_JSON"
fi

if [ ! -s "$TEMP_JSON" ]; then
    echo "Error: Could not extract JSON from FFmpeg output"
    echo "FFmpeg output:"
    cat "$TEMP_OUTPUT"
    exit 1
fi

# Extract values from JSON
INPUT_I=$(grep '"input_i"' "$TEMP_JSON" | sed 's/.*"input_i"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
INPUT_LRA=$(grep '"input_lra"' "$TEMP_JSON" | sed 's/.*"input_lra"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
INPUT_TP=$(grep '"input_tp"' "$TEMP_JSON" | sed 's/.*"input_tp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
INPUT_THRESH=$(grep '"input_thresh"' "$TEMP_JSON" | sed 's/.*"input_thresh"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
TARGET_OFFSET=$(grep '"target_offset"' "$TEMP_JSON" | sed 's/.*"target_offset"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

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

# Step 3: Pass 2 - apply compression + normalization, write WAV PCM
echo "Step 3: Applying compression and loudness normalization..."
ffmpeg -hide_banner -loglevel error -y -i "$TEMP_STRIPPED" \
    -af "acompressor=threshold=-21dB:ratio=3:attack=10:release=100,loudnorm=I=${TARGET_LUFS}:TP=-1.5:LRA=11:measured_I=${INPUT_I}:measured_LRA=${INPUT_LRA}:measured_TP=${INPUT_TP}:measured_thresh=${INPUT_THRESH}:offset=${TARGET_OFFSET}" \
    -ar "$SAMPLE_RATE" \
    -c:a pcm_s16le "$OUTPUT_FILE"

if [ $? -ne 0 ]; then
    echo "Error: Compression/normalization failed."
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
