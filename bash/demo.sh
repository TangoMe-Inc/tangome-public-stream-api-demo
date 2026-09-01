#!/usr/bin/env bash
# Tango Public API demo: mint a creator token, start a stream, push a video, stop it.
#
# Every call here hits a public partner endpoint (https://api.tangoagent.io, docs at
# https://business.tango.me/developers) - nothing internal-only. See README.md for the full
# walkthrough; --help for the short version.
set -euo pipefail

# The direct page to generate/manage an agency API key (clientId + clientSecret). It's what's
# shown right before init asks for one.
CREDENTIALS_URL="https://www.tangoagent.io/agency-key"
# Full API docs and account setup - the general reference, separate from the key page above.
DOCS_URL="https://business.tango.me/developers"
BASE_URL="${TANGO_API_BASE:-https://api.tangoagent.io}"
AGENCY_PREFIX="/api/v1/agencies"
CREATOR_PREFIX="/api/v1/creators"

# The one media shape the RTMP gateway accepts. B-frames are the decisive one: libx264 emits
# three by default, the downstream transcoder does not cope, and the result is a publish that is
# accepted and then shows nothing to anybody.
FPS=30
SAMPLE_RATE=48000
ACCEPTED_H264_PROFILES="baseline constrained_baseline main high"

die() {
  echo "Error: $*" >&2
  exit 1
}

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH. Install it and retry (see README.md > Prerequisites)."
}

need_ffmpeg() {
  command -v ffmpeg >/dev/null 2>&1 || die "'ffmpeg' not found on PATH. Install it: macOS 'brew install ffmpeg', Ubuntu/Debian 'sudo apt install ffmpeg', Fedora/RHEL 'sudo dnf install ffmpeg'. See README.md > Prerequisites."
}

need_ffprobe() {
  command -v ffprobe >/dev/null 2>&1 || die "'ffprobe' not found on PATH. It ships with ffmpeg - install ffmpeg and retry."
}

# ---------------------------------------------------------------------------
# .env handling
# ---------------------------------------------------------------------------

script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

find_env_file() {
  if [ -n "${ENV_FILE:-}" ]; then
    echo "$ENV_FILE"
    return
  fi
  if [ -f "$(pwd)/.env" ]; then
    echo "$(pwd)/.env"
    return
  fi
  local repo_root
  repo_root="$(dirname "$(script_dir)")"
  if [ -f "$repo_root/.env" ]; then
    echo "$repo_root/.env"
    return
  fi
  echo "$(pwd)/.env"
}

# Reads one key from a .env file (empty string if unset or the file doesn't exist).
env_file_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || { echo ""; return; }
  grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- || true
}

# Rewrites only the named key=value pairs; every other line (comments included) is left alone.
# Usage: env_file_write FILE KEY1 VALUE1 [KEY2 VALUE2 ...]
env_file_write() {
  local file="$1"; shift
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  local -a keys=() values=()
  while [ "$#" -gt 0 ]; do
    keys+=("$1"); values+=("$2"); shift 2
  done

  # Plain array of "written" flags parallel to keys[]/values[] - an associative array (bash 4+)
  # would be simpler, but macOS ships bash 3.2 as /bin/bash, so this stays bash-3-compatible.
  local -a written=()
  local i
  for i in "${!keys[@]}"; do
    written[i]=0
  done

  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      local matched=0
      for i in "${!keys[@]}"; do
        case "$line" in
          "${keys[$i]}="*)
            printf '%s=%s\n' "${keys[$i]}" "${values[$i]}" >> "$tmp"
            written[i]=1
            matched=1
            break
            ;;
        esac
      done
      [ "$matched" -eq 0 ] && printf '%s\n' "$line" >> "$tmp"
    done < "$file"
  fi

  for i in "${!keys[@]}"; do
    if [ "${written[$i]}" -eq 0 ]; then
      printf '%s=%s\n' "${keys[$i]}" "${values[$i]}" >> "$tmp"
    fi
  done

  mv "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true  # a real agency secret lives in this file
}

# Resolution order: CLI arg > environment variable > .env file > default.
load_config() {
  local env_path
  env_path="$(find_env_file)"
  CLIENT_ID="${CLI_CLIENT_ID:-${TANGO_CLIENT_ID:-$(env_file_get "$env_path" TANGO_CLIENT_ID)}}"
  CLIENT_SECRET="${CLI_CLIENT_SECRET:-${TANGO_CLIENT_SECRET:-$(env_file_get "$env_path" TANGO_CLIENT_SECRET)}}"
  CREATOR_ID="${CLI_CREATOR_ID:-${TANGO_CREATOR_ID:-$(env_file_get "$env_path" TANGO_CREATOR_ID)}}"
}

require_credentials() {
  if [ -z "${CLIENT_ID:-}" ] || [ -z "${CLIENT_SECRET:-}" ]; then
    die "Missing agency credentials. Run './demo.sh init' to set them, or get keys at $CREDENTIALS_URL"
  fi
}

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------

cmd_init() {
  local flag_client_id="" flag_client_secret="" flag_creator_id="" env_override=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --client-id) flag_client_id="$2"; shift 2 ;;
      --client-secret) flag_client_secret="$2"; shift 2 ;;
      --creator-id) flag_creator_id="$2"; shift 2 ;;
      --env) env_override="$2"; shift 2 ;;
      *) die "Unknown option for init: $1" ;;
    esac
  done

  local env_path
  env_path="${env_override:-$(find_env_file)}"

  local -a keys=() values=()

  # Any flag at all switches to flag mode: only the named keys are touched, nothing is asked.
  # No flags means the full interactive dialog. This is what lets a bare `init --creator-id X`
  # update just that one key silently, for a script or a quick fixup.
  if [ -n "$flag_client_id" ] || [ -n "$flag_client_secret" ] || [ -n "$flag_creator_id" ]; then
    [ -n "$flag_client_id" ] && { keys+=(TANGO_CLIENT_ID); values+=("$flag_client_id"); }
    [ -n "$flag_client_secret" ] && { keys+=(TANGO_CLIENT_SECRET); values+=("$flag_client_secret"); }
    [ -n "$flag_creator_id" ] && { keys+=(TANGO_CREATOR_ID); values+=("$flag_creator_id"); }
  else
    echo "Don't have an agency API key yet? Get one at $CREDENTIALS_URL"
    local existing_id existing_secret answer
    existing_id="$(env_file_get "$env_path" TANGO_CLIENT_ID)"
    existing_secret="$(env_file_get "$env_path" TANGO_CLIENT_SECRET)"

    if [ -n "$existing_id" ]; then
      read -r -p "Client ID [$existing_id]: " answer
    else
      read -r -p "Client ID: " answer
    fi
    answer="${answer:-$existing_id}"
    [ -n "$answer" ] && { keys+=(TANGO_CLIENT_ID); values+=("$answer"); }

    # The secret is typed hidden, so a typo goes unnoticed - ask for it twice and require a match
    # before moving on, the way `passwd` does. Pressing Enter on the first prompt keeps the
    # existing value and skips confirmation entirely.
    local secret1 secret2
    while :; do
      if [ -n "$existing_secret" ]; then
        read -r -s -p "Client secret [already set, Enter keeps it]: " secret1
      else
        read -r -s -p "Client secret [required]: " secret1
      fi
      echo
      if [ -z "$secret1" ]; then
        secret1="$existing_secret"
        break
      fi
      read -r -s -p "Confirm client secret: " secret2
      echo
      if [ "$secret1" = "$secret2" ]; then
        break
      fi
      echo "Secrets didn't match - try again."
    done
    [ -n "$secret1" ] && { keys+=(TANGO_CLIENT_SECRET); values+=("$secret1"); }

    # Creator ID isn't asked here - set it with --creator-id (or TANGO_CREATOR_ID) instead; most
    # partners manage several creators, so a single dialog default isn't a good fit.
  fi

  if [ "${#keys[@]}" -eq 0 ]; then
    echo "Nothing to write."
    return
  fi

  local existed=0
  [ -f "$env_path" ] && existed=1

  local -a pairs=()
  local i
  for i in "${!keys[@]}"; do
    pairs+=("${keys[$i]}" "${values[$i]}")
  done
  env_file_write "$env_path" "${pairs[@]}"

  if [ "$existed" -eq 1 ] && [ "${#keys[@]}" -eq 1 ]; then
    echo "Updated ${keys[0]} in $env_path"
  elif [ "$existed" -eq 1 ]; then
    echo "Updated $env_path"
  else
    echo "Wrote $env_path"
  fi
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# Runs curl, printing the body on success and dying with a readable message otherwise.
# Usage: api_call METHOD PATH AUTH_HEADER "OK_STATUS[,OK_STATUS...]" [EXTRA_CURL_ARGS...]
api_call() {
  local method="$1" path="$2" auth="$3" ok_statuses="$4"
  shift 4
  local url="${BASE_URL%/}${path}"
  local response status body
  response="$(curl -sS -w '\n%{http_code}' -X "$method" -H "$auth" -H "Accept: application/json" "$@" "$url")"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  local ok
  IFS=',' read -ra ok_list <<< "$ok_statuses"
  for ok in "${ok_list[@]}"; do
    if [ "$status" = "$ok" ]; then
      echo "$body"
      return 0
    fi
  done

  local hint=""
  if [ "$status" = "401" ] || [ "$status" = "403" ]; then
    hint=" (invalid credentials - get keys at $CREDENTIALS_URL)"
  fi
  die "$method $url -> HTTP $status${hint}: $body"
}

mint_creator_token() {
  require_credentials
  local auth="Authorization: Basic $(printf '%s:%s' "$CLIENT_ID" "$CLIENT_SECRET" | base64 | tr -d '\n')"
  local body
  body="$(api_call POST "${AGENCY_PREFIX}/creators/${1}/tokens" "$auth" "200,201" -X POST)"
  echo "$body" | jq -r '.creatorToken'
}

# With neither type nor price this sends no body at all - a plain public stream. Otherwise it
# sends only the fields given, as-is: the service owns the validation (e.g. a premium type
# without a price, or a price on a public one), and seeing its own 400 for that is the point.
create_stream() {
  local bearer="Authorization: Bearer $1" stream_type="${2:-}" ticket_price="${3:-}"
  if [ -z "$stream_type" ] && [ -z "$ticket_price" ]; then
    api_call POST "${CREATOR_PREFIX}/streams/create" "$bearer" "200,201" -X POST
    return
  fi
  local payload
  payload="$(jq -n --arg type "$stream_type" --arg price "$ticket_price" '
    {}
    + (if $type  != "" then {type: $type} else {} end)
    + (if $price != "" then {ticketPriceInCredits: ($price | tonumber)} else {} end)
  ')"
  api_call POST "${CREATOR_PREFIX}/streams/create" "$bearer" "200,201" \
    -X POST -H "Content-Type: application/json" -d "$payload"
}

terminate_stream() {
  local bearer="Authorization: Bearer $1"
  api_call POST "${CREATOR_PREFIX}/streams/${2}/terminate" "$bearer" "200,204" -X POST >/dev/null
}

cmd_creators() {
  need_tool jq
  require_credentials
  local auth="Authorization: Basic $(printf '%s:%s' "$CLIENT_ID" "$CLIENT_SECRET" | base64 | tr -d '\n')"
  local body
  body="$(api_call GET "${AGENCY_PREFIX}/creators?size=20" "$auth" "200")"
  local count
  count="$(echo "$body" | jq '.data | length')"
  if [ "$count" -eq 0 ]; then
    echo "No creators for this agency."
    return
  fi
  echo "Creators (agencyId scoped):"
  echo "$body" | jq -r '.data[] | "  id=\(.id)  status=\(.status)  name=\(.displayName)"'
}

watch_url() {
  echo "https://www.tango.me/stream/${1}"
}

# ---------------------------------------------------------------------------
# ffmpeg / ffprobe
# ---------------------------------------------------------------------------

# Builds the ffmpeg args into the FFMPEG_CMD array.
# RTMP carries the app name in `connect` and the stream name in `publish`; the key belongs in the
# latter. Handed rtmps://host/<key> with no app segment, the key would be taken for the app name
# and the stream would publish under an empty name. So the key always goes through
# -rtmp_playpath and the ingress URL is passed through untouched.
#
# Note: unlike the standalone `validate`-fixing workflow the original test-kit ships as `convert`,
# publishing never resizes the picture - it only fixes the encoder settings (codec, GOP, no
# B-frames, audio). The gateway accepts 180-1920px on either side, so most clips pass through
# as-is; only the encoder shape is non-negotiable.
build_publish_command() {
  local ingress_url="$1" stream_key="$2" duration="$3" video_file="$4"
  FFMPEG_CMD=(ffmpeg -hide_banner)
  # Loop the clip so a short file still fills the requested duration; -re reads it at
  # playback speed so the encoder does not race ahead of the ingest.
  FFMPEG_CMD+=(-stream_loop -1 -re -i "$video_file")
  FFMPEG_CMD+=(-t "$duration")
  FFMPEG_CMD+=(
    -c:v libx264 -profile:v main -pix_fmt yuv420p
    -r "$FPS" -g "$FPS" -keyint_min "$FPS" -sc_threshold 0 -bf 0
    # -bf 0 alone is not always honoured; x264 gets told twice, on purpose.
    -x264-params "bframes=0:keyint=${FPS}:min-keyint=${FPS}:scenecut=0"
    -c:a aac -profile:a aac_low -ac 1 -ar "$SAMPLE_RATE" -b:a 128k
  )
  FFMPEG_CMD+=(-f flv -rtmp_playpath "$stream_key" "${ingress_url%/}")
}

run_ffmpeg_publish() {
  local ingress_url="$1" stream_key="$2" duration="$3" video_file="$4"
  build_publish_command "$ingress_url" "$stream_key" "$duration" "$video_file"

  local out
  local status=0
  out="$("${FFMPEG_CMD[@]}" 2>&1)" || status=$?

  if [ "$status" -ne 0 ]; then
    echo "Publish failed. Last output:"
    echo "$out" | tail -12 | sed 's/^/  /'
    die "ffmpeg exited with a non-zero status; see README.md > Troubleshooting."
  fi
  echo "Publish finished normally."
}

# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------

probe_stream() {
  local file="$1" selector="$2" entries="$3"
  ffprobe -v error -select_streams "$selector" -show_entries "stream=${entries}" \
    -of default=noprint_wrappers=1 "$file" 2>/dev/null
}

probe_get() {
  # $1 = probe output (one KEY=VALUE per line), $2 = key
  echo "$1" | grep "^${2}=" | tail -1 | cut -d= -f2-
}

cmd_validate() {
  need_ffmpeg
  need_ffprobe
  local file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file="$2"; shift 2 ;;
      *) die "Unknown option for validate: $1" ;;
    esac
  done
  [ -n "$file" ] || die "Missing --file"

  local video audio
  video="$(probe_stream "$file" v:0 "codec_name,profile,width,height,has_b_frames,pix_fmt,r_frame_rate")"
  audio="$(probe_stream "$file" a:0 "codec_name,profile,channels,sample_rate")"

  echo "  video: $(echo "$video" | tr '\n' ' ')"
  echo "  audio: $(echo "$audio" | tr '\n' ' ')"

  local -a problems=()

  if [ -z "$video" ]; then
    problems+=("no video stream")
  else
    local codec profile has_b pix_fmt
    codec="$(probe_get "$video" codec_name)"
    profile="$(probe_get "$video" profile)"
    has_b="$(probe_get "$video" has_b_frames)"
    pix_fmt="$(probe_get "$video" pix_fmt)"
    [ "$codec" = "h264" ] || problems+=("video codec is ${codec:-?}, expected h264")
    local profile_norm accepted=0
    profile_norm="$(echo "${profile:-?}" | tr 'A-Z ' 'a-z_')"
    for p in $ACCEPTED_H264_PROFILES; do
      [ "$profile_norm" = "$p" ] && accepted=1
    done
    [ "$accepted" -eq 1 ] || problems+=("H.264 profile is ${profile:-?}, expected Baseline/Main/High")
    [ "$has_b" = "0" ] || problems+=("has B-frames (has_b_frames=${has_b:-?}) - the stream will be accepted and then show nothing")
    [ "$pix_fmt" = "yuv420p" ] || problems+=("pixel format is ${pix_fmt:-?}, expected yuv420p")
  fi

  if [ -z "$audio" ]; then
    problems+=("no audio stream")
  else
    local acodec aprofile channels rate
    acodec="$(probe_get "$audio" codec_name)"
    aprofile="$(probe_get "$audio" profile)"
    channels="$(probe_get "$audio" channels)"
    rate="$(probe_get "$audio" sample_rate)"
    [ "$acodec" = "aac" ] || problems+=("audio codec is ${acodec:-?}, expected aac")
    [ "$(echo "${aprofile:-?}" | tr 'a-z' 'A-Z')" = "LC" ] || problems+=("AAC profile is ${aprofile:-?}, expected LC")
    { [ "$channels" = "1" ] || [ "$channels" = "2" ]; } || problems+=("audio has ${channels:-?} channels, expected mono or stereo")
    [ "$rate" = "$SAMPLE_RATE" ] || problems+=("sample rate is ${rate:-?}, expected $SAMPLE_RATE")
  fi

  if [ "${#problems[@]}" -eq 0 ]; then
    echo "$file matches what the gateway accepts."
    echo "Note: 'stream' re-encodes on the fly regardless - this only checks your own"
    echo "pipeline/encoder output against the gateway's requirements."
  else
    echo "$file does NOT match what the gateway accepts:"
    local p
    for p in "${problems[@]}"; do
      echo "  - $p"
    done
  fi
}

# ---------------------------------------------------------------------------
# stream
# ---------------------------------------------------------------------------

cmd_stream() {
  need_ffmpeg
  local file="" duration=30 cli_creator_id="" stream_type="" price=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --creator-id) cli_creator_id="$2"; shift 2 ;;
      --file) file="$2"; shift 2 ;;
      --duration) duration="$2"; shift 2 ;;
      --type) stream_type="$2"; shift 2 ;;
      --price) price="$2"; shift 2 ;;
      *) die "Unknown option for stream: $1" ;;
    esac
  done

  [ -n "$file" ] || die "Missing --file (a real video of a person - moderation rejects synthetic/test-pattern content)."

  local creator_id="${cli_creator_id:-$CREATOR_ID}"
  [ -n "$creator_id" ] || die "Missing --creator-id (or set TANGO_CREATOR_ID via './demo.sh init')."

  local token stream_json stream_id ingress_url stream_key
  token="$(mint_creator_token "$creator_id")"
  stream_json="$(create_stream "$token" "$stream_type" "$price")"
  stream_id="$(echo "$stream_json" | jq -r '.streamId')"
  ingress_url="$(echo "$stream_json" | jq -r '.ingressUrl')"
  stream_key="$(echo "$stream_json" | jq -r '.streamKey')"

  echo "Stream $stream_id created."
  if [ -n "$stream_type" ]; then
    # The response looks the same for every stream type, so this is the only place you can see
    # that a premium stream was actually requested.
    if [ -n "$price" ]; then
      echo "  type: $stream_type, ticket price: $price credits"
    else
      echo "  type: $stream_type"
    fi
  fi
  echo "  watch: $(watch_url "$stream_id")"

  # terminate must run even if the publish is interrupted (Ctrl-C) or fails.
  trap 'terminate_stream "$token" "$stream_id"; echo "Stream $stream_id terminated (204); the broadcast may linger for a while."' EXIT

  echo "Publishing $file to $ingress_url for ${duration}s..."
  run_ffmpeg_publish "$ingress_url" "$stream_key" "$duration" "$file"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: demo.sh COMMAND [OPTIONS]

Commands:
  init [--client-id ID] [--client-secret SECRET] [--creator-id ID] [--env PATH]
                                  Write or update .env with your agency credentials
  creators                        List the agency's creators
  validate --file PATH            Check whether a video file fits the gateway's requirements
  stream --file PATH [--creator-id ID] [--duration N] [--type TYPE] [--price N]
                                  Create a stream, publish a video, terminate it
                                  --file: video of a real person - moderation rejects synthetic content
                                  --type: PUBLIC (default) / PREMIUM / PREMIUM_HOT
                                  --price: ticket price in credits, required for PREMIUM/PREMIUM_HOT

Get your agency keys at $CREDENTIALS_URL
Full docs: $DOCS_URL
EOF
}

main() {
  local command="${1:-}"
  [ -n "$command" ] && shift || true

  case "$command" in
    -h|--help|"")
      usage
      exit 0
      ;;
    init)
      cmd_init "$@"
      ;;
    creators)
      CLI_CLIENT_ID="" CLI_CLIENT_SECRET="" load_config
      cmd_creators
      ;;
    validate)
      cmd_validate "$@"
      ;;
    stream)
      CLI_CLIENT_ID="" CLI_CLIENT_SECRET="" load_config
      cmd_stream "$@"
      ;;
    *)
      die "Unknown command: $command (try --help)"
      ;;
  esac
}

main "$@"
