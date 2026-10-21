"""Video Downloader API.

A small FastAPI service the mobile app talks to. It uses yt-dlp to resolve a
public post link (YouTube, TikTok, Instagram, Facebook, X/Twitter) into a video
file and streams that file back to the phone.

Endpoints:
  GET  /api/health                  -> {"ok": true, "platforms": [...]}
  POST /api/info     {"url": "..."} -> title, thumbnail, duration, quality options
  GET  /api/download ?url=&quality= -> the video (or audio) file

Environment:
  DOWNLOADER_API_KEY   optional; when set, every /api/info and /api/download call
                       must send it in the X-API-Key header
  MAX_FILESIZE_MB      optional cap on a single download (default 500)
  COOKIES_FILE         optional Netscape cookies.txt for posts that need a login
"""

from __future__ import annotations

import os
import re
import shutil
import tempfile
from pathlib import Path
from urllib.parse import urlparse

import yt_dlp
from fastapi import BackgroundTasks, Depends, FastAPI, Header, HTTPException, Query
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel

API_KEY = os.environ.get("DOWNLOADER_API_KEY", "")
MAX_FILESIZE_MB = int(os.environ.get("MAX_FILESIZE_MB", "500"))
COOKIES_FILE = os.environ.get("COOKIES_FILE", "")

# host suffix -> platform name shown in the app
PLATFORMS: dict[str, str] = {
    "youtube.com": "YouTube",
    "youtu.be": "YouTube",
    "tiktok.com": "TikTok",
    "instagram.com": "Instagram",
    "facebook.com": "Facebook",
    "fb.watch": "Facebook",
    "fb.com": "Facebook",
    "twitter.com": "X / Twitter",
    "x.com": "X / Twitter",
}

# quality id -> (label, max height or None, audio only)
QUALITIES: dict[str, tuple[str, int | None, bool]] = {
    "best": ("Best quality", None, False),
    "1080": ("1080p", 1080, False),
    "720": ("720p", 720, False),
    "480": ("480p", 480, False),
    "360": ("360p", 360, False),
    "audio": ("Audio only", None, True),
}

app = FastAPI(title="Video Downloader API", version="1.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


class InfoRequest(BaseModel):
    url: str


def require_key(x_api_key: str | None = Header(default=None)) -> None:
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key.")


def detect_platform(url: str) -> str | None:
    """Return the platform name for a supported http(s) link, else None."""
    try:
        parsed = urlparse(url.strip())
    except ValueError:
        return None
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return None
    host = parsed.hostname.lower()
    for suffix, name in PLATFORMS.items():
        if host == suffix or host.endswith("." + suffix):
            return name
    return None


def checked_url(url: str) -> tuple[str, str]:
    url = url.strip()
    platform = detect_platform(url)
    if not platform:
        raise HTTPException(
            status_code=400,
            detail="Unsupported link. Paste a YouTube, TikTok, Instagram, Facebook or X/Twitter URL.",
        )
    return url, platform


def base_opts() -> dict:
    opts: dict = {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "noplaylist": True,
        "socket_timeout": 30,
    }
    if COOKIES_FILE:
        opts["cookiefile"] = COOKIES_FILE
    return opts


def format_opts(quality: str) -> dict:
    """yt-dlp options for a quality id. Prefers H.264/AAC in MP4 so the file plays in the phone gallery."""
    _, height, audio_only = QUALITIES[quality]
    if audio_only:
        return {"format": "ba[ext=m4a]/ba/b", "format_sort": ["acodec:aac"]}
    sort = ["vcodec:h264", "res", "acodec:aac", "ext:mp4:m4a"]
    if height:
        sort = [f"res:{height}", "vcodec:h264", "acodec:aac", "ext:mp4:m4a"]
    return {"format": "bv*+ba/b", "format_sort": sort, "merge_output_format": "mp4"}


def friendly_error(exc: Exception) -> HTTPException:
    msg = re.sub(r"\x1b\[[0-9;]*m", "", str(exc)).replace("ERROR: ", "")
    lowered = msg.lower()
    if "private" in lowered or "login" in lowered or "log in" in lowered or "cookies" in lowered:
        detail = "This post is private or needs a login, so it can't be downloaded."
    elif "unavailable" in lowered or "not found" in lowered or "404" in lowered:
        detail = "This video is unavailable or was removed."
    elif "unable to connect" in lowered or "timed out" in lowered or "connection" in lowered:
        detail = "Couldn't reach the platform. Check the server's internet connection and try again."
    elif "file is larger" in lowered or "max-filesize" in lowered:
        detail = f"The video is larger than the {MAX_FILESIZE_MB} MB limit."
    else:
        detail = msg[:300] or "Could not process this link."
    return HTTPException(status_code=422, detail=detail)


def extract_info(url: str) -> dict:
    with yt_dlp.YoutubeDL(base_opts()) as ydl:
        info = ydl.extract_info(url, download=False)
    if info and info.get("_type") == "playlist":
        entries = [e for e in (info.get("entries") or []) if e]
        if not entries:
            raise yt_dlp.utils.DownloadError("No video found in this post.")
        info = entries[0]
    return ydl.sanitize_info(info)


def quality_options(info: dict) -> list[dict]:
    heights = {f.get("height") for f in info.get("formats") or [] if f.get("vcodec") not in (None, "none")}
    heights.discard(None)
    has_audio = any(f.get("acodec") not in (None, "none") for f in info.get("formats") or [])
    top = max(heights) if heights else info.get("height")
    options = []
    for qid, (label, height, audio_only) in QUALITIES.items():
        if audio_only and not has_audio:
            continue
        # only offer capped qualities that are actually below the source's best
        if height and (not top or height >= top):
            continue
        options.append({"id": qid, "label": label})
    return options


def download_file(url: str, quality: str, workdir: str) -> Path:
    opts = base_opts() | format_opts(quality) | {
        "outtmpl": os.path.join(workdir, "%(title).80B [%(id)s].%(ext)s"),
        "restrictfilenames": False,
        "max_filesize": MAX_FILESIZE_MB * 1024 * 1024,
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([url])
    files = [p for p in Path(workdir).iterdir() if p.is_file() and not p.name.endswith((".part", ".ytdl"))]
    if not files:
        raise yt_dlp.utils.DownloadError("Download produced no file (it may exceed the size limit).")
    return max(files, key=lambda p: p.stat().st_size)


@app.get("/api/health")
def health() -> dict:
    return {"ok": True, "platforms": sorted(set(PLATFORMS.values())), "yt_dlp": yt_dlp.version.__version__}


@app.post("/api/info", dependencies=[Depends(require_key)])
async def info(body: InfoRequest) -> dict:
    url, platform = checked_url(body.url)
    try:
        data = await run_in_threadpool(extract_info, url)
    except Exception as exc:  # yt-dlp raises many error types; all become a readable message
        raise friendly_error(exc) from exc
    return {
        "url": url,
        "platform": platform,
        "id": data.get("id"),
        "title": data.get("title") or data.get("description") or "Untitled video",
        "uploader": data.get("uploader") or data.get("channel"),
        "duration": data.get("duration"),
        "thumbnail": data.get("thumbnail"),
        "qualities": quality_options(data),
    }


@app.get("/api/download", dependencies=[Depends(require_key)])
async def download(
    background: BackgroundTasks,
    url: str = Query(...),
    quality: str = Query("best"),
) -> FileResponse:
    url, _ = checked_url(url)
    if quality not in QUALITIES:
        raise HTTPException(status_code=400, detail=f"Unknown quality '{quality}'.")
    workdir = tempfile.mkdtemp(prefix="vdl-")
    try:
        path = await run_in_threadpool(download_file, url, quality, workdir)
    except Exception as exc:
        shutil.rmtree(workdir, ignore_errors=True)
        raise friendly_error(exc) from exc
    background.add_task(shutil.rmtree, workdir, ignore_errors=True)
    media_type = "audio/mp4" if path.suffix == ".m4a" else "video/mp4" if path.suffix == ".mp4" else None
    return FileResponse(path, media_type=media_type, filename=path.name)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))
