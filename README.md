# public-api-demo

A minimal client for Tango's public partner API (`https://api.tangoagent.io`). Given agency keys
and a video file, it starts a live stream, publishes the video, and terminates the stream.

Full docs: **https://business.tango.me/developers**.

## What this is

One run does the whole partner flow:

```
mint a creator token  →  create a stream  →  push RTMP(S) video with ffmpeg  →  terminate it
```

All endpoints used are public. Two equivalent implementations are provided; use either one:

| | Needs |
|---|---|
| [`python/demo.py`](python/demo.py) | Python 3.9+ |
| [`bash/demo.sh`](bash/demo.sh) | bash, `curl`, `jq` |

Both need `ffmpeg` — see [Prerequisites](#prerequisites).

## Quickstart

### Python

```bash
# 1. Save your agency credentials (interactive prompt, or pass them as flags - see Configuration)
python3 python/demo.py init

# 2. Find a creator to stream as
python3 python/demo.py creators

# 3. Start a stream, push 30 seconds of video, stop it
python3 python/demo.py stream --creator-id ID --file clip.mp4 --duration 30
```

### Bash

```bash
# 1. Save your agency credentials (interactive prompt, or pass them as flags - see Configuration)
./bash/demo.sh init

# 2. Find a creator to stream as
./bash/demo.sh creators

# 3. Start a stream, push 30 seconds of video, stop it
./bash/demo.sh stream --creator-id ID --file clip.mp4 --duration 30
```

The gateway applies content moderation: `--file` must reference a video of a real person.
Synthetic or test-pattern video is rejected. See [Video requirements](#video-requirements) for
the encoding constraints.

## Prerequisites

### ffmpeg (required)

Both the streaming and the validation commands shell out to ffmpeg/ffprobe. ffprobe ships with
ffmpeg, so one install covers both.

| OS | Install |
|---|---|
| macOS | `brew install ffmpeg` |
| Ubuntu/Debian | `sudo apt install ffmpeg` |
| Fedora/RHEL | `sudo dnf install ffmpeg` |

Verify:

```bash
ffmpeg -version
ffprobe -version
```

The build must include the `libx264` and `aac` encoders. All packages listed above include them.
Confirm with:

```bash
ffmpeg -encoders | grep -E 'libx264|aac'
```

### Per implementation

| Python | Bash |
|---|---|
| Python 3.9+ (usually already installed) | `jq` — `brew install jq` / `sudo apt install jq` |

## Getting credentials

1. Register an agency at **https://business.tango.me/developers**.
2. Create an API key at **https://www.tangoagent.io/agency-key** — you get a `clientId` and a
   `clientSecret`.
3. Add the creator accounts you want to stream as to the agency.

This repository only consumes credentials issued by those pages. It does not manage account
setup.

## Commands

| Command | Python | Bash | What it does |
|---|---|---|---|
| Save credentials | `demo.py init` | `demo.sh init` | Writes/updates `.env`. Flags and/or an interactive prompt — see [Configuration](#configuration) |
| List creators | `demo.py creators` | `demo.sh creators` | `GET /api/v1/agencies/creators` |
| Check a video file | `demo.py validate --file PATH` | `demo.sh validate --file PATH` | Local ffprobe check against the gateway's requirements. No network, no credentials |
| Full round trip | `demo.py stream [...]` | `demo.sh stream [...]` | Create → publish → terminate |

`stream` options (same names, same defaults, in both implementations):

| Flag | Meaning | Default |
|---|---|---|
| `--creator-id ID` | Creator to stream as | `TANGO_CREATOR_ID` from config |
| `--file PATH` | Video of a real person to publish — moderation rejects synthetic content | required |
| `--duration N` | Seconds to stream | 30 |
| `--type TYPE` | `PUBLIC` / `PREMIUM` / `PREMIUM_HOT` — see [Ticketed streams](#ticketed-streams) | public stream |
| `--price N` | Ticket price in credits, required for `PREMIUM` / `PREMIUM_HOT` | — |

### Ticketed streams

A premium stream requires viewers to pay `--price` credits to view it. Omitting `--type` creates a
public stream (the default):

```bash
python3 python/demo.py stream --creator-id ID --file clip.mp4 --duration 20                                   # public
python3 python/demo.py stream --creator-id ID --file clip.mp4 --duration 20 --type PREMIUM     --price 199
python3 python/demo.py stream --creator-id ID --file clip.mp4 --duration 20 --type PREMIUM_HOT --price 499

./bash/demo.sh stream --creator-id ID --file clip.mp4 --duration 20 --type PREMIUM --price 199
```

`--type` is not validated locally; it is passed to the API as given. The API returns `400` for an
invalid combination:

```bash
python3 python/demo.py stream --creator-id ID --file clip.mp4 --type PREMIUM               # 400 Ticket price required.
python3 python/demo.py stream --creator-id ID --file clip.mp4 --type PUBLIC --price 199    # 400 Ticket price not allowed.
```

Two behaviors are expected, not errors: the `watch` link for a premium stream requires a purchased
ticket to view, even while the stream is live; and a `PREMIUM_HOT` stream does not appear in the
default feed.

## Configuration

Precedence: **CLI flag > environment variable > `.env` file > default**. `.env` is looked up in
the current directory, then in the repo root, so either implementation works run from either
location.

| Key | Meaning |
|---|---|
| `TANGO_CLIENT_ID` | Agency client id — the API key's id, **not** a Tango user account (HTTP Basic) |
| `TANGO_CLIENT_SECRET` | Agency client secret |
| `TANGO_CREATOR_ID` | Default creator, so you can drop `--creator-id` |

`init` writes these values. Running `init` with no flags opens an interactive prompt for the
client ID and secret. The secret is entered without echo; the bash implementation requires it
twice and verifies the two entries match. Passing any flag switches to non-interactive mode: only
the named keys are written, and no prompt is shown. `--creator-id` is available only as a flag; it
is not requested interactively, because agencies typically manage more than one creator. An
existing `.env` file is updated one key at a time; all other lines, including comments, are
preserved:

```bash
python3 python/demo.py init                                   # interactive: client id + secret
python3 python/demo.py init --creator-id Cr9z                 # updates just this one key
python3 python/demo.py init --client-id ID --client-secret S  # fully scriptable, e.g. in CI
```

`.env.example` lists the same three keys. Copy it to `.env` to edit manually.

This demo communicates only with `https://api.tangoagent.io`. A `401` response indicates invalid
credentials for that endpoint.

## The API, call by call

The following requests make up the full flow. `curl` examples are shown for reference; `demo.py`
and `demo.sh` issue the same requests.

**1. Mint a creator token** — agency credentials, HTTP Basic:

```bash
curl -u "$CLIENT_ID:$CLIENT_SECRET" -X POST \
  https://api.tangoagent.io/api/v1/agencies/creators/$CREATOR_ID/tokens
```
```json
{"creatorToken": "tagt_...", "tokenType": "Bearer", "agencyId": "Ag7x",
 "creatorId": "Cr4y", "tokenExpiresAt": "2026-09-02T10:00:00Z"}
```

**2. Create a stream** — creator token, Bearer. Full reference:
https://business.tango.me/developers/reference#createStream. A public stream takes no request
body:

```bash
curl -H "Authorization: Bearer $CREATOR_TOKEN" -X POST \
  https://api.tangoagent.io/api/v1/creators/streams/create
```

A premium stream requires `type` and `ticketPriceInCredits` in the request body. See
[Ticketed streams](#ticketed-streams):

```bash
curl -H "Authorization: Bearer $CREATOR_TOKEN" -H "Content-Type: application/json" -X POST \
  -d '{"type":"PREMIUM","ticketPriceInCredits":199}' \
  https://api.tangoagent.io/api/v1/creators/streams/create
```

Both return:

```json
{"streamId": "L2PmQx9...", "ingressUrl": "rtmps://ingest.rtmp.tango.me/ant-media",
 "streamKey": "eyJhbGciOi..."}
```

Watch it live at `https://www.tango.me/stream/{streamId}`.

**3. Publish** — RTMP(S) to `ingressUrl`, with `streamKey` as the RTMP *stream name* (playpath),
not appended to the URL. In OBS: *Server* = `ingressUrl`, *Stream Key* = `streamKey`. See
[Video requirements](#video-requirements) for what the gateway accepts.

**4. Terminate**:

```bash
curl -H "Authorization: Bearer $CREATOR_TOKEN" -X POST \
  https://api.tangoagent.io/api/v1/creators/streams/$STREAM_ID/terminate
# -> 204
```

**Listing creators** (used to find a `$CREATOR_ID`):

```bash
curl -u "$CLIENT_ID:$CLIENT_SECRET" \
  "https://api.tangoagent.io/api/v1/agencies/creators?size=20"
```
```json
{"data": [{"id": "Cr4y", "status": "ACTIVE", "displayName": "Cr4y",
           "registeredAt": "...", "avatarUrl": "..."}],
 "pagination": {"page": 0, "size": 20, "hasMore": false}}
```

## Video requirements

These requirements are enforced by the RTMP gateway. A stream that violates them is often accepted
and produces no visible output; ffmpeg exits successfully in this case, so the failure is not
visible on the command line.

| | Requirement |
|---|---|
| Video codec | H.264, profile Baseline / Main / High |
| B-frames | None. `libx264` emits 3 by default; the transcoder does not support them |
| GOP | Fixed, 1 second, no scene-cut keyframes |
| Resolution | 180–1920px on either side; 720×1280 (vertical) is the safe default |
| Pixel format | `yuv420p` |
| Audio codec | AAC-LC, mono or stereo, 48 kHz |

B-frames are the most common cause of failure. `stream` re-encodes the input with the required
settings regardless of source format, so publishing through it always produces compliant output.
`validate` checks the output of an independent encoding pipeline against the same requirements:

```bash
python3 python/demo.py validate --file clip.mp4
```

To generate a compliant test clip:

```bash
ffmpeg -f lavfi -i testsrc2=size=720x1280:rate=30:duration=10 \
       -f lavfi -i sine=frequency=1000:sample_rate=48000:duration=10 \
       -c:v libx264 -profile:v main -pix_fmt yuv420p \
       -g 30 -keyint_min 30 -sc_threshold 0 -bf 0 \
       -x264-params bframes=0:keyint=30:min-keyint=30:scenecut=0 \
       -c:a aac -profile:a aac_low -ac 1 -ar 48000 -b:a 128k \
       sample.mp4
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `401` / `403` | Invalid credentials. Verify or regenerate your key at https://www.tangoagent.io/agency-key |
| `404` on create | Wrong endpoint. Confirm requests target `https://api.tangoagent.io` |
| `429` | Rate limit exceeded. Wait and retry |
| `ffmpeg: not found` | Install ffmpeg. See [Prerequisites](#prerequisites) |
| `Publish finished normally` but the stream shows no video | Run `validate --file yourclip.mp4`. Likely cause: B-frames or an incorrect audio sample rate |
| Stream still shows as live after `terminate` | Expected. `terminate` returns `204` immediately; the broadcast ends shortly after |
| Missing `--creator-id` | Pass it, or set `TANGO_CREATOR_ID` with `init` |
| `demo.py`: `[SSL: CERTIFICATE_VERIFY_FAILED]` | A Python build from python.org does not use the macOS system root certificates. Fix: `pip3 install certifi`, then `export SSL_CERT_FILE="$(python3 -c 'import certifi; print(certifi.where())')"` (add to your shell profile to persist it). Does not affect `demo.sh`, which uses the system certificates via `curl` |

## Project layout

```
public-api-demo/
├── README.md          this file
├── .env.example       the three settings, documented
├── python/demo.py      init / creators / validate / stream — stdlib only
└── bash/demo.sh        same commands — curl + jq + ffmpeg
```
