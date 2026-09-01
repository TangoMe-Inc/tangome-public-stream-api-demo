#!/usr/bin/env python3
"""Tango Public API demo: mint a creator token, start a stream, push a video, stop it.

Every call here hits a public partner endpoint (https://api.tangoagent.io, docs at
https://business.tango.me/developers) — nothing internal-only. See README.md for the full
walkthrough; --help for the short version.
"""

import argparse
import base64
import getpass
import json
import os
import shutil
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

# The direct page to generate/manage an agency API key (clientId + clientSecret). It's what's
# shown right before init asks for one.
CREDENTIALS_URL = "https://www.tangoagent.io/agency-key"
# Full API docs and account setup - the general reference, separate from the key page above.
DOCS_URL = "https://business.tango.me/developers"
BASE_URL = os.environ.get("TANGO_API_BASE", "https://api.tangoagent.io")
AGENCY_PREFIX = "/api/v1/agencies"
CREATOR_PREFIX = "/api/v1/creators"

ENV_KEYS = ["TANGO_CLIENT_ID", "TANGO_CLIENT_SECRET", "TANGO_CREATOR_ID"]
SECRET_KEYS = {"TANGO_CLIENT_SECRET"}

# The one media shape the RTMP gateway accepts. B-frames are the decisive one: libx264 emits
# three by default, the downstream transcoder does not cope, and the result is a publish that is
# accepted and then shows nothing to anybody.
FPS, SAMPLE_RATE = 30, 48000
ACCEPTED_H264_PROFILES = {"baseline", "constrained baseline", "main", "high"}


# ---------------------------------------------------------------------------
# .env handling
# ---------------------------------------------------------------------------

def find_env_file():
    """Looks in the current directory, then the repo root (parent of this script's directory)."""
    override = os.environ.get("ENV_FILE")
    if override:
        return Path(override)
    here = Path.cwd() / ".env"
    if here.exists():
        return here
    repo_root = Path(__file__).resolve().parent.parent / ".env"
    return repo_root if repo_root.exists() else here


def read_env_file(path: Path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        values[key.strip()] = value.strip()
    return values


def write_env_file(path: Path, updates: dict):
    """Rewrites only the named keys; every other line (comments included) is left alone."""
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    seen = set()
    out = []
    for line in lines:
        stripped = line.strip()
        if "=" in stripped and not stripped.startswith("#"):
            key = stripped.split("=", 1)[0].strip()
            if key in updates:
                out.append(f"{key}={updates[key]}")
                seen.add(key)
                continue
        out.append(line)
    for key, value in updates.items():
        if key not in seen:
            out.append(f"{key}={value}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    try:
        path.chmod(0o600)  # a real agency secret lives in this file
    except OSError:
        pass


def load_config(cli_args):
    """CLI arg > environment variable > .env file > default."""
    env_path = find_env_file()
    file_values = read_env_file(env_path)

    def resolve(cli_value, env_key):
        if cli_value is not None:
            return cli_value
        if os.environ.get(env_key):
            return os.environ[env_key]
        return file_values.get(env_key) or None

    return {
        "client_id": resolve(cli_args.client_id, "TANGO_CLIENT_ID"),
        "client_secret": resolve(cli_args.client_secret, "TANGO_CLIENT_SECRET"),
        "creator_id": resolve(getattr(cli_args, "creator_id", None), "TANGO_CREATOR_ID"),
        "env_path": env_path,
    }


# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------

def cmd_init(args):
    env_path = find_env_file()
    if args.env:
        env_path = Path(args.env)
    current = read_env_file(env_path)

    # Any flag at all switches to flag mode: only the named keys are touched, nothing is asked.
    # No flags means the full interactive dialog. This is what lets a bare `init --creator-id X`
    # update just that one key silently, for a script or a quick fixup.
    flag_mode = args.client_id is not None or args.client_secret is not None or args.creator_id is not None

    updates = {}
    if flag_mode:
        if args.client_id is not None:
            updates["TANGO_CLIENT_ID"] = args.client_id
        if args.client_secret is not None:
            updates["TANGO_CLIENT_SECRET"] = args.client_secret
        if args.creator_id is not None:
            updates["TANGO_CREATOR_ID"] = args.creator_id
    else:
        print(f"Don't have an agency API key yet? Get one at {CREDENTIALS_URL}")

        def ask(key, prompt, secret=False, optional=False):
            existing = current.get(key)
            if secret:
                hint = "already set, Enter keeps it" if existing else "required"
                raw = getpass.getpass(f"{prompt} [{hint}]: ")
                return raw if raw else existing
            suffix = f" [{existing}]" if existing else (" (optional)" if optional else "")
            raw = input(f"{prompt}{suffix}: ").strip()
            return raw if raw else existing

        # Creator ID isn't asked here - set it with --creator-id (or TANGO_CREATOR_ID) instead;
        # most partners manage several creators, so a single dialog default isn't a good fit.
        client_id = ask("TANGO_CLIENT_ID", "Client ID")
        client_secret = ask("TANGO_CLIENT_SECRET", "Client secret", secret=True)
        if client_id:
            updates["TANGO_CLIENT_ID"] = client_id
        if client_secret:
            updates["TANGO_CLIENT_SECRET"] = client_secret

    if not updates:
        print("Nothing to write.")
        return

    existed = env_path.exists()
    write_env_file(env_path, updates)
    verb = "Updated" if existed else "Wrote"
    if len(updates) == 1 and existed:
        (key,) = updates
        print(f"Updated {key} in {env_path}")
    else:
        print(f"{verb} {env_path}")


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

class ApiError(RuntimeError):
    pass


def basic_auth_header(client_id, client_secret):
    raw = f"{client_id}:{client_secret}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


def request(method, path, headers, body=None, ok_statuses=(200,)):
    url = BASE_URL.rstrip("/") + path
    data = body.encode("utf-8") if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status = resp.status
            payload = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        status = e.code
        payload = e.read().decode("utf-8", errors="replace")
    except urllib.error.URLError as e:
        if isinstance(e.reason, ssl.SSLCertVerificationError):
            raise ApiError(
                "TLS certificate verification failed - this is a local Python/macOS setup "
                "issue, not a problem with the API. Fix it once with:\n"
                "  export SSL_CERT_FILE=\"$(python3 -c 'import certifi; print(certifi.where())')\"\n"
                "(install certifi first if needed: pip3 install certifi). See README.md > "
                "Troubleshooting."
            ) from e
        raise ApiError(f"{method} {url} failed: {e.reason}") from e

    if status not in ok_statuses:
        hint = ""
        if status in (401, 403):
            hint = f" (invalid credentials - get keys at {CREDENTIALS_URL})"
        raise ApiError(f"{method} {url} -> HTTP {status}{hint}: {payload}")
    return status, payload


def require_credentials(cfg):
    if not cfg["client_id"] or not cfg["client_secret"]:
        raise ApiError(
            "Missing agency credentials. Run 'demo.py init' to set them, "
            f"or get keys at {CREDENTIALS_URL}")


def mint_creator_token(cfg, creator_id):
    require_credentials(cfg)
    auth = basic_auth_header(cfg["client_id"], cfg["client_secret"])
    _, body = request(
        "POST", f"{AGENCY_PREFIX}/creators/{creator_id}/tokens",
        headers={"Authorization": auth, "Accept": "application/json"},
        ok_statuses=(200, 201))
    return json.loads(body)["creatorToken"]


def create_stream(bearer_token, stream_type=None, ticket_price=None):
    """With neither type nor price this sends no body at all - a plain public stream. Otherwise
    it sends only the fields given, as-is: the service owns the validation (e.g. a premium type
    without a price, or a price on a public one), and seeing its own 400 for that is the point."""
    headers = {"Authorization": f"Bearer {bearer_token}", "Accept": "application/json"}
    if stream_type is None and ticket_price is None:
        _, body = request(
            "POST", f"{CREATOR_PREFIX}/streams/create", headers=headers, ok_statuses=(200, 201))
    else:
        payload = {}
        if stream_type is not None:
            payload["type"] = stream_type
        if ticket_price is not None:
            payload["ticketPriceInCredits"] = ticket_price
        headers = {**headers, "Content-Type": "application/json"}
        _, body = request(
            "POST", f"{CREATOR_PREFIX}/streams/create", headers=headers,
            body=json.dumps(payload), ok_statuses=(200, 201))
    return json.loads(body)


def terminate_stream(bearer_token, stream_id):
    request(
        "POST", f"{CREATOR_PREFIX}/streams/{stream_id}/terminate",
        headers={"Authorization": f"Bearer {bearer_token}"},
        ok_statuses=(200, 204))


def list_creators(cfg):
    require_credentials(cfg)
    auth = basic_auth_header(cfg["client_id"], cfg["client_secret"])
    _, body = request(
        "GET", f"{AGENCY_PREFIX}/creators?size=20",
        headers={"Authorization": auth, "Accept": "application/json"})
    return json.loads(body)


def cmd_creators(args, cfg):
    data = list_creators(cfg)
    creators = data.get("data") or []
    if not creators:
        print("No creators for this agency.")
        return
    print("Creators (agencyId scoped):")
    for c in creators:
        print(f"  id={c.get('id')}  status={c.get('status')}  name={c.get('displayName')}")


def watch_url(stream_id):
    return f"https://www.tango.me/stream/{stream_id}"


# ---------------------------------------------------------------------------
# ffmpeg / ffprobe
# ---------------------------------------------------------------------------

def find_ffmpeg_tool(name):
    path = shutil.which(name)
    if path:
        return path
    raise ApiError(
        f"'{name}' not found on PATH. Install it: macOS 'brew install ffmpeg', "
        f"Ubuntu/Debian 'sudo apt install ffmpeg', Fedora/RHEL 'sudo dnf install ffmpeg'. "
        "See README.md > Prerequisites."
    )


def encoder_args():
    return [
        "-c:v", "libx264",
        "-profile:v", "main",
        "-pix_fmt", "yuv420p",
        "-r", str(FPS),
        "-g", str(FPS),
        "-keyint_min", str(FPS),
        "-sc_threshold", "0",
        "-bf", "0",
        # -bf 0 alone is not always honoured; x264 gets told twice, on purpose.
        "-x264-params", f"bframes=0:keyint={FPS}:min-keyint={FPS}:scenecut=0",
        "-c:a", "aac",
        "-profile:a", "aac_low",
        "-ac", "1",
        "-ar", str(SAMPLE_RATE),
        "-b:a", "128k",
    ]


def publish_command(ffmpeg, ingress_url, stream_key, duration_sec, video_file):
    # Note: unlike the standalone `validate`-fixing workflow the original test-kit ships as
    # `convert`, publishing never resizes the picture - it only fixes the encoder settings
    # (codec, GOP, no B-frames, audio). The gateway accepts 180-1920px on either side, so most
    # clips pass through as-is; only the encoder shape is non-negotiable.
    cmd = [ffmpeg, "-hide_banner"]
    # Loop the clip so a short file still fills the requested duration; -re reads it at
    # playback speed so the encoder does not race ahead of the ingest.
    cmd += ["-stream_loop", "-1", "-re", "-i", video_file]
    cmd += ["-t", str(duration_sec)]
    cmd += encoder_args()
    cmd += ["-f", "flv"]
    # RTMP carries the app name in `connect` and the stream name in `publish`; the key belongs in
    # the latter. Handed rtmps://host/<key> with no app segment, the key would be taken for the
    # app name and the stream would publish under an empty name. So the key always goes through
    # -rtmp_playpath and the ingress URL is passed through untouched.
    cmd += ["-rtmp_playpath", stream_key, ingress_url.rstrip("/")]
    return cmd


def run_ffmpeg_publish(ffmpeg, ingress_url, stream_key, duration_sec, video_file):
    cmd = publish_command(ffmpeg, ingress_url, stream_key, duration_sec, video_file)
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, encoding="utf-8", errors="replace")
    lines = proc.stdout.splitlines() if proc.stdout else []
    if proc.returncode != 0:
        print("Publish failed. Last output:")
        for line in lines[-12:]:
            print(f"  {line}")
        raise ApiError("ffmpeg exited with a non-zero status; see README.md > Troubleshooting.")
    print("Publish finished normally.")


# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------

def probe_stream(ffprobe, file_path, selector, entries):
    cmd = [ffprobe, "-v", "error", "-select_streams", selector,
           "-show_entries", f"stream={entries}", "-of", "default=noprint_wrappers=1", file_path]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, encoding="utf-8", errors="replace", timeout=20)
    except FileNotFoundError as e:
        raise ApiError(f"ffprobe not runnable ('{ffprobe}'). It ships with ffmpeg.") from e
    values = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    return values


def problems_with(video, audio):
    problems = []
    if not video:
        problems.append("no video stream")
    else:
        if video.get("codec_name") != "h264":
            problems.append(f"video codec is {video.get('codec_name', '?')}, expected h264")
        profile = video.get("profile", "?")
        if profile.lower() not in ACCEPTED_H264_PROFILES:
            problems.append(f"H.264 profile is {profile}, expected Baseline/Main/High")
        if video.get("has_b_frames") != "0":
            problems.append(
                f"has B-frames (has_b_frames={video.get('has_b_frames', '?')}) - the stream "
                "will be accepted and then show nothing")
        if video.get("pix_fmt") != "yuv420p":
            problems.append(f"pixel format is {video.get('pix_fmt', '?')}, expected yuv420p")
    if not audio:
        problems.append("no audio stream")
    else:
        if audio.get("codec_name") != "aac":
            problems.append(f"audio codec is {audio.get('codec_name', '?')}, expected aac")
        if audio.get("profile", "?").upper() != "LC":
            problems.append(f"AAC profile is {audio.get('profile', '?')}, expected LC")
        if audio.get("channels") not in ("1", "2"):
            problems.append(f"audio has {audio.get('channels', '?')} channels, expected mono or stereo")
        if audio.get("sample_rate") != str(SAMPLE_RATE):
            problems.append(f"sample rate is {audio.get('sample_rate', '?')}, expected {SAMPLE_RATE}")
    return problems


def cmd_validate(args):
    ffmpeg = find_ffmpeg_tool("ffmpeg")
    ffprobe = find_ffmpeg_tool("ffprobe")
    video = probe_stream(ffprobe, args.file, "v:0",
                          "codec_name,profile,width,height,has_b_frames,pix_fmt,r_frame_rate")
    audio = probe_stream(ffprobe, args.file, "a:0", "codec_name,profile,channels,sample_rate")
    print(f"  video: {video if video else '(none)'}")
    print(f"  audio: {audio if audio else '(none)'}")
    problems = problems_with(video, audio)
    if not problems:
        print(f"{args.file} matches what the gateway accepts.")
        print("Note: 'stream' re-encodes on the fly regardless - this only checks your own")
        print("pipeline/encoder output against the gateway's requirements.")
    else:
        print(f"{args.file} does NOT match what the gateway accepts:")
        for p in problems:
            print(f"  - {p}")


# ---------------------------------------------------------------------------
# stream
# ---------------------------------------------------------------------------

def cmd_stream(args, cfg):
    creator_id = args.creator_id or cfg["creator_id"]
    if not creator_id:
        raise ApiError("Missing --creator-id (or set TANGO_CREATOR_ID via 'demo.py init').")

    ffmpeg = find_ffmpeg_tool("ffmpeg")

    token = mint_creator_token(cfg, creator_id)
    stream = create_stream(token, args.type, args.price)
    stream_id = stream["streamId"]
    print(f"Stream {stream_id} created.")
    if args.type:
        # The response looks the same for every stream type, so this is the only place you can
        # see that a premium stream was actually requested.
        suffix = f", ticket price: {args.price} credits" if args.price is not None else ""
        print(f"  type: {args.type}{suffix}")
    print(f"  watch: {watch_url(stream_id)}")

    try:
        print(f"Publishing {args.file} to {stream['ingressUrl']} for {args.duration}s...")
        run_ffmpeg_publish(ffmpeg, stream["ingressUrl"], stream["streamKey"],
                            args.duration, args.file)
    finally:
        terminate_stream(token, stream_id)
        print(f"Stream {stream_id} terminated (204); the broadcast may linger for a while.")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog="demo.py",
        description="Tango Public API demo: mint a creator token, stream a video, stop it.",
        epilog=f"Get your agency keys at {CREDENTIALS_URL}\nFull docs: {DOCS_URL}",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init", help="Write or update .env with your agency credentials")
    p_init.add_argument("--client-id")
    p_init.add_argument("--client-secret")
    p_init.add_argument("--creator-id")
    p_init.add_argument("--env", help="Path to the .env file to write (default: ./.env)")

    sub.add_parser("creators", help="List the agency's creators")

    p_validate = sub.add_parser("validate", help="Check whether a video file fits the gateway's requirements")
    p_validate.add_argument("--file", required=True)

    p_stream = sub.add_parser("stream", help="Create a stream, publish a video, terminate it")
    p_stream.add_argument("--creator-id")
    p_stream.add_argument("--file", required=True,
                           help="Video of a real person to publish - moderation rejects "
                                "synthetic/test-pattern content")
    p_stream.add_argument("--duration", type=int, default=30)
    p_stream.add_argument("--type",
                           help="PUBLIC (default, no --type at all) / PREMIUM / PREMIUM_HOT. "
                                "Sent as-is - the service validates it, this doesn't")
    p_stream.add_argument("--price", type=int,
                           help="Ticket price in credits, required for PREMIUM/PREMIUM_HOT")

    # --client-id/--client-secret let a command override the .env credentials one-off; init has
    # its own copies above with real help text, so only creators/stream get them here.
    for p in (sub.choices["creators"], p_stream, p_validate):
        p.add_argument("--client-id", dest="client_id", help=argparse.SUPPRESS, default=None)
        p.add_argument("--client-secret", dest="client_secret", help=argparse.SUPPRESS, default=None)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "init":
            cmd_init(args)
            return 0

        cfg = load_config(args)
        if args.command == "creators":
            cmd_creators(args, cfg)
        elif args.command == "validate":
            cmd_validate(args)
        elif args.command == "stream":
            cmd_stream(args, cfg)
        return 0
    except ApiError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
