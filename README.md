# Compress Audio

Normalize loudness, then encode to a 128 kbps MP3 with metadata and cover art.

Compression (`acompressor`) is disabled in this script. The settings stay in the script as comments.

## Requirements
- `ffmpeg` available in your PATH
- Cover image: `amerikapodden2-2000.jpg`. The path is relative to the current directory, so run the script from this directory.

## Usage
```
./compress-audio.sh input.wav output.mp3 [target_lufs]
```

`target_lufs` defaults to `-19`.

The script will:
- Prompt for the episode title at the start of the run
- Measure loudness with the `loudnorm` analysis pass (integrated loudness, loudness range, true peak)
- Normalize to the target loudness, with a true peak limit of `-1.5 dBTP` and a loudness range target of `11 LU`:
  - If one gain change is enough (loudnorm linear mode), apply that gain with `volume`. This skips the slow second `loudnorm` pass.
  - Otherwise run the second `loudnorm` pass in dynamic mode.
- Encode to MP3 at 128 kbps with ID3v2.3 tags:
  - title: the episode title
  - artist: `Amerikapodden`
  - date: the current year
- Embed `amerikapodden2-2000.jpg` as the cover image

## Example
```
./compress-audio.sh input.wav output.mp3 -19
```

# Pre-Edit

Strip long silences, compress, and normalize a WAV file before editing.

## Requirements
- `ffmpeg` 7.0 or newer available in your PATH

## Usage
```
./pre-edit.sh input.wav
```

The script will:
- Find silences longer than 1.2 seconds with `silencedetect`. The threshold is `-30dB`.
- Shorten each long silence to 1.2 seconds, including leading and trailing silence. Each cut in the middle of the file gets a 10 ms crossfade.
- Compress with `acompressor=threshold=-21dB:ratio=3:attack=10:release=100`
- Measure and normalize to `-19 LUFS` in the same way as `compress-audio.sh`
- Write the result next to the source file as `<name>-stripped.wav` (16-bit WAV PCM, input sample rate)
- Report how many seconds of audio were removed

## Example
```
./pre-edit.sh episode.wav
```
