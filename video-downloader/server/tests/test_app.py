"""Offline tests: link validation and the download pipeline against a locally generated video.

Run from the server folder:  python -m pytest tests
Needs ffmpeg on PATH to generate the sample clip.
"""

import functools
import http.server
import shutil
import subprocess
import sys
import threading
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app as server  # noqa: E402


@pytest.mark.parametrize(
    "url,platform",
    [
        ("https://www.youtube.com/watch?v=abc", "YouTube"),
        ("https://youtu.be/abc", "YouTube"),
        ("https://m.youtube.com/shorts/abc", "YouTube"),
        ("https://vm.tiktok.com/ZM123/", "TikTok"),
        ("https://www.instagram.com/reel/abc/", "Instagram"),
        ("https://fb.watch/abc/", "Facebook"),
        ("https://www.facebook.com/watch/?v=1", "Facebook"),
        ("https://x.com/user/status/1", "X / Twitter"),
        ("https://twitter.com/user/status/1", "X / Twitter"),
        ("https://notyoutube.com/watch", None),
        ("ftp://youtube.com/x", None),
        ("youtube.com/watch?v=abc", None),
    ],
)
def test_detect_platform(url, platform):
    assert server.detect_platform(url) == platform


def test_rejects_unsupported_link():
    client = TestClient(server.app)
    r = client.post("/api/info", json={"url": "https://example.com/video"})
    assert r.status_code == 400


def test_api_key(monkeypatch):
    monkeypatch.setattr(server, "API_KEY", "secret")
    client = TestClient(server.app)
    assert client.post("/api/info", json={"url": "https://youtu.be/x"}).status_code == 401


@pytest.fixture(scope="module")
def sample_url(tmp_path_factory):
    if not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg not installed")
    root = tmp_path_factory.mktemp("media")
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=25",
         "-f", "lavfi", "-i", "sine=frequency=440", "-t", "2", "-c:v", "libx264", "-c:a", "aac",
         "-shortest", str(root / "clip.mp4")],
        check=True,
    )
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root))
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_port}/clip.mp4"
    httpd.shutdown()


def test_download_endpoint(sample_url, monkeypatch):
    # let the local sample through the platform allow-list
    monkeypatch.setattr(server, "detect_platform", lambda url: "Test")
    client = TestClient(server.app)
    info = client.post("/api/info", json={"url": sample_url}).json()
    assert info["platform"] == "Test" and info["qualities"]
    r = client.get("/api/download", params={"url": sample_url, "quality": "best"})
    assert r.status_code == 200
    assert r.headers["content-type"] == "video/mp4"
    assert len(r.content) > 1000
