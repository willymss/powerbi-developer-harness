# SaveClip — social video downloader

A mobile app (iOS + Android, built with Expo / React Native) that downloads videos from
**YouTube, TikTok, Instagram, Facebook and X/Twitter**. Paste the link, pick a quality, tap
**Download** — the video is saved to your phone's gallery and can be shared from the app.

```
video-downloader/
├── mobile/   Expo app (the thing on your phone)
└── server/   FastAPI + yt-dlp service that resolves links and returns the video file
```

Why a server? The platforms don't expose direct video links, and extracting them (plus merging
YouTube's separate audio/video streams with ffmpeg) needs [yt-dlp](https://github.com/yt-dlp/yt-dlp),
which can't run inside a phone app. The app sends the link to your server; the server sends back an MP4.

## 1. Run the server

**With Docker (recommended):**

```bash
cd video-downloader/server
docker build -t saveclip-server .
docker run -p 8000:8000 saveclip-server
```

**Or with Python 3.10+ and ffmpeg installed:**

```bash
cd video-downloader/server
pip install -r requirements.txt
python app.py            # listens on http://0.0.0.0:8000
```

Check it: open `http://<your-computer-ip>:8000/api/health`.

Optional environment variables:

| Variable | Purpose |
| --- | --- |
| `DOWNLOADER_API_KEY` | Require this key (sent by the app as `X-API-Key`). Set it whenever the server is on the internet. |
| `MAX_FILESIZE_MB` | Largest allowed download, default `500`. |
| `COOKIES_FILE` | Path to a Netscape `cookies.txt`, for posts that only load when logged in. |
| `PORT` | Port to listen on, default `8000`. |

To use the app away from home Wi-Fi, deploy the Docker image to any container host
(Render, Railway, Fly.io, a VPS, …) and use its **https** URL in the app.

Keep yt-dlp current — platforms change often and an old yt-dlp is the usual cause of failures:
`pip install -U yt-dlp` (or rebuild the Docker image).

## 2. Run the app

```bash
cd video-downloader/mobile
npm install
cp .env.example .env     # set EXPO_PUBLIC_API_URL to your server, e.g. http://192.168.1.10:8000
npx expo start
```

Scan the QR code with **Expo Go** on your phone (phone and computer on the same Wi-Fi).
You can also change the server URL any time in the app's **⚙︎ Settings** and tap *Test connection*.

### Install it as a real app

```bash
npm install -g eas-cli
eas login
eas build -p android --profile preview   # gives you an .apk to install
eas build -p ios                         # needs an Apple developer account
```

## Using it

1. In TikTok / Instagram / YouTube / Facebook / X, tap **Share → Copy link**.
2. Open SaveClip and tap **Paste link** (or paste into the box) → **Find video**.
3. Pick a quality (Best, 1080p, 720p, … or Audio only) and tap **Download**.
4. The file is saved to your gallery; **Recent downloads** lets you share or remove it.

Videos are downloaded as H.264/AAC MP4 where available so they play in the iOS Photos and
Android Gallery apps.

## Tests

```bash
cd video-downloader/server
pip install pytest httpx
python -m pytest tests      # offline: link validation + a full download of a locally generated clip
```

## Limits & responsible use

- Private posts, stories and age-restricted videos need a login; provide `COOKIES_FILE` for those.
- Some platforms rate-limit or block datacenter IPs; a home server works most reliably.
- Download only content you own or have permission to save, and respect each platform's terms
  of service and creators' copyright. App stores (especially Apple's) may reject apps that download
  from YouTube, so plan on side-loading / personal use.
