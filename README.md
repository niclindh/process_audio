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
- Analyze loudness and apply compression + loudness normalization
- Prompt for the episode title
- Use the current year for the MP3 metadata
- Set artist to `Amerikapodden`
- Embed `amerikapodden2-2000.jpg` as the cover image

## Example
```
./process_audio.sh input.wav output.mp3 -19
```
