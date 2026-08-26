# docs

The demo recording in the top-level `README.md` is **not committed to the repo**
— it's hosted as a GitHub attachment (drop the file onto an issue/PR comment and
use the resulting `user-attachments` URL in the `<img>` tag). This keeps the
repository small; no binary `demo.gif` lives in git.

## Capturing it

The sample app auto-runs a couple of chat turns when launched with the
`LITERT_DEMO=1` environment variable — handy for a clean recording without
manual typing.

1. Build & install `Samples/LiteRTDemo` on a device (see the top-level README).
2. Start an iOS screen recording (Control Center), then launch the app — either
   normally (and chat: type, attach a photo / record audio / pick a video) or
   with `LITERT_DEMO=1` for the scripted two-turn demo.
3. Trim the recording, then convert to a GIF, e.g.:

   ```bash
   ffmpeg -i demo.mov -vf "fps=12,scale=400:-1:flags=lanczos,palettegen" palette.png
   ffmpeg -i demo.mov -i palette.png \
     -filter_complex "fps=12,scale=400:-1:flags=lanczos[x];[x][1:v]paletteuse" demo.gif
   ```
4. Upload `demo.gif` to a GitHub issue/PR comment and copy its
   `https://github.com/user-attachments/assets/…` URL into the top-level
   `README.md` `<img src=…>` (don't commit the file).
