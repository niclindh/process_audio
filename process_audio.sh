#!/bin/bash

# Audio Loudness Normalization Script
# Usage: ./process_audio.sh input.wav output.mp3 [target_lufs]

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <input_file> <output_file> [target_lufs]"
    echo "Example: ./process_audio.sh input.wav output.mp3 -19"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"
TARGET_LUFS="${3:--19}"  # Default to -19 LUFS if not specified
COVER_IMAGE="amerikapodden2-2000.jpg"

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found!"
    exit 1
fi

echo "Analyzing audio file: $INPUT_FILE"
echo "Target loudness: $TARGET_LUFS LUFS"
echo ""

# Pass 1: Analysis - Capture all FFmpeg output
echo "Pass 1: Analyzing audio properties..."
TEMP_OUTPUT=$(mktemp)
TEMP_JSON=$(mktemp)

# Run FFmpeg and capture all stderr output (keep info loglevel for loudnorm JSON)
ffmpeg -hide_banner -loglevel info -i "$INPUT_FILE" -af acompressor=threshold=-21dB:ratio=3:attack=200:release=1000,loudnorm=I=$TARGET_LUFS:TP=-1.5:LRA=11:print_format=json -f null - 2> "$TEMP_OUTPUT"

# Extract JSON from the output (more flexible approach)
# Look for lines starting with { and ending with }
awk '/^{/,/^}/' "$TEMP_OUTPUT" > "$TEMP_JSON"

# If that didn't work, try alternative extraction
if [ ! -s "$TEMP_JSON" ]; then
    echo "Trying alternative JSON extraction..."
    # Look for the JSON block in a different way
    sed -n '/^{$/,/^}$/p' "$TEMP_OUTPUT" > "$TEMP_JSON"
fi

# If still no JSON, try extracting from loudnorm filter output
if [ ! -s "$TEMP_JSON" ]; then
    echo "Trying loudnorm-specific extraction..."
    grep -A 20 "loudnorm" "$TEMP_OUTPUT" | sed -n '/^{$/,/^}$/p' > "$TEMP_JSON"
fi

# Check if we got valid JSON
if [ ! -s "$TEMP_JSON" ]; then
    echo "Error: Could not extract JSON from FFmpeg output"
    echo "FFmpeg output:"
    cat "$TEMP_OUTPUT"
    rm -f "$TEMP_OUTPUT" "$TEMP_JSON"
    exit 1
fi

# Extract values from JSON - more robust parsing
INPUT_I=$(grep '"input_i"' "$TEMP_JSON" | sed 's/.*"input_i"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
INPUT_LRA=$(grep '"input_lra"' "$TEMP_JSON" | sed 's/.*"input_lra"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
INPUT_TP=$(grep '"input_tp"' "$TEMP_JSON" | sed 's/.*"input_tp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
INPUT_THRESH=$(grep '"input_thresh"' "$TEMP_JSON" | sed 's/.*"input_thresh"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
TARGET_OFFSET=$(grep '"target_offset"' "$TEMP_JSON" | sed 's/.*"target_offset"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

# Validate extracted values
if [ -z "$INPUT_I" ] || [ -z "$INPUT_LRA" ] || [ -z "$INPUT_TP" ] || [ -z "$INPUT_THRESH" ] || [ -z "$TARGET_OFFSET" ]; then
    echo "Error: Failed to extract all required values from JSON"
    echo "Extracted values:"
    echo "  INPUT_I: '$INPUT_I'"
    echo "  INPUT_LRA: '$INPUT_LRA'"
    echo "  INPUT_TP: '$INPUT_TP'"
    echo "  INPUT_THRESH: '$INPUT_THRESH'"
    echo "  TARGET_OFFSET: '$TARGET_OFFSET'"
    rm -f "$TEMP_OUTPUT" "$TEMP_JSON"
    exit 1
fi

# Pass 2: Normalization
echo "Pass 2: Applying loudness normalization..."
TEMP_NORMALIZED="$(mktemp "${TMPDIR:-/tmp}/normalized.XXXXXX.wav")"
ffmpeg -hide_banner -loglevel error -y -i "$INPUT_FILE" \
    -af acompressor=threshold=-21dB:ratio=3:attack=200:release=1000,loudnorm=I=$TARGET_LUFS:TP=-1.5:LRA=11:measured_I=$INPUT_I:measured_LRA=$INPUT_LRA:measured_TP=$INPUT_TP:measured_thresh=$INPUT_THRESH:offset=$TARGET_OFFSET \
    "$TEMP_NORMALIZED"

# Check if normalization was successful
if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Normalization complete!"
    echo "Target loudness: $TARGET_LUFS LUFS"
else
    echo "✗ Error: Normalization failed"
    rm -f "$TEMP_OUTPUT" "$TEMP_JSON" "$TEMP_NORMALIZED"
    exit 1
fi

# Pass 3: Encode MP3 with metadata and cover art
if [ ! -f "$COVER_IMAGE" ]; then
    echo "Error: Cover image '$COVER_IMAGE' not found!"
    rm -f "$TEMP_OUTPUT" "$TEMP_JSON" "$TEMP_NORMALIZED"
    exit 1
fi

read -r -p "Episode title: " EPISODE_TITLE
EPISODE_YEAR="$(date +%Y)"

if [ -z "$EPISODE_TITLE" ]; then
    echo "Error: Episode title is required."
    rm -f "$TEMP_OUTPUT" "$TEMP_JSON" "$TEMP_NORMALIZED"
    exit 1
fi

echo "Pass 3: Encoding MP3 with metadata..."
ffmpeg -hide_banner -loglevel error -y -i "$TEMP_NORMALIZED" -i "$COVER_IMAGE" \
    -map 0:a -map 1:v \
    -c:a libmp3lame -b:a 128k \
    -id3v2_version 3 \
    -metadata title="$EPISODE_TITLE" \
    -metadata artist="Amerikapodden" \
    -metadata date="$EPISODE_YEAR" \
    -metadata:s:v title="Album cover" \
    -metadata:s:v comment="Cover (front)" \
    "$OUTPUT_FILE"

if [ $? -eq 0 ]; then
    echo "✓ MP3 encoding complete!"
    echo "Output file: $OUTPUT_FILE"
else
    echo "✗ Error: MP3 encoding failed"
    rm -f "$TEMP_OUTPUT" "$TEMP_JSON" "$TEMP_NORMALIZED"
    exit 1
fi

# Cleanup
rm -f "$TEMP_OUTPUT" "$TEMP_JSON" "$TEMP_NORMALIZED"
