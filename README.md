# Process Audio

Normalize and compress audio, then encode to a 128 kbps MP3 with metadata and cover art.

## Requirements
- `ffmpeg` available in your PATH
- Cover image: `amerikapodden2-2000.jpg` in this directory

## Usage
```
./process_audio.sh input.wav output.mp3 [-19]
```

The script will:
- Prompt for the episode title at the start of the run
- Analyze loudness and apply compression + loudness normalization
- Use the current year for the MP3 metadata
- Set artist to `Amerikapodden`
- Embed `amerikapodden2-2000.jpg` as the cover image

## Example
```
./process_audio.sh input.wav output.mp3 -19
```

# Pre-Edit

Strip long silences and compress a WAV file before editing.

## Requirements
- `ffmpeg` available in your PATH

## Usage
```
./pre-edit.sh input.wav
```

The script will:
- Strip silences longer than 1.5 seconds. The threshold is `-30dB`. Each long silence is shortened to 1.5 seconds.
- Apply the compression and loudness normalization settings from `compress-audio.sh` (target `-19 LUFS`)
- Write the result next to the source file as `<name>-stripped.wav` (WAV PCM)
- Report how many seconds of audio were removed

## Example
```
./pre-edit.sh episode.wav
```
