#!/usr/bin/env zsh
# ---- youtube download -> media vm (server-side) ----

# Where the media VM should place final files (NFS mount already available there)
REMOTE_FINAL_BASE="/mnt/nfs/movies/youtube"

# Local cookies file on your Mac (Netscape cookies.txt format)
LOCAL_YT_COOKIES="$HOME/.config/yt-dlp/cookies/cookies.txt"

_ytdl_on_media_vm() {
  setopt local_options pipefail

  local category="$1"   # e.g. youtube, gym, create, music
  local url="$2"

  if [[ -z "$category" || -z "$url" ]]; then
    # shellcheck disable=SC2154  # funcstack is a zsh built-in array
    echo "Usage: ${funcstack[1]} <category> <url>"
    return 1
  fi

  # Validate URL format (basic check for supported video sites)
  if [[ ! "$url" =~ ^https?://(www\.)?(youtube\.com|youtu\.be|vimeo\.com|dailymotion\.com|twitch\.tv) ]]; then
    echo "⚠️  Warning: URL doesn't look like a supported video site"
    echo "   Supported: YouTube, Vimeo, Dailymotion, Twitch"
    echo "   Proceeding anyway..."
  fi

  # Check cookies file exists and has content
  if [[ ! -f "$LOCAL_YT_COOKIES" ]]; then
    echo "❌ Cookies file not found:"
    echo "   $LOCAL_YT_COOKIES"
    echo "Export youtube.com cookies to this file (Netscape cookies.txt)."
    return 1
  fi

  if [[ ! -s "$LOCAL_YT_COOKIES" ]]; then
    echo "❌ Cookies file is empty:"
    echo "   $LOCAL_YT_COOKIES"
    return 1
  fi

  # Warn if cookies are older than 7 days (likely stale)
  local cookie_age_days=$(( ($(date +%s) - $(stat -f %m "$LOCAL_YT_COOKIES" 2>/dev/null || stat -c %Y "$LOCAL_YT_COOKIES")) / 86400 ))
  if [[ $cookie_age_days -gt 7 ]]; then
    echo "⚠️  Warning: Cookies file is $cookie_age_days days old (may be stale)"
    echo "   Consider re-exporting fresh cookies from your browser"
  fi

  # Check if yt-dlp is installed on remote
  if ! /usr/bin/ssh -o BatchMode=yes media 'command -v yt-dlp >/dev/null 2>&1'; then
    echo "❌ yt-dlp not found on media VM"
    echo "   Install it with: ssh media 'pip install yt-dlp'"
    return 1
  fi

  # Remote temp paths
  local remote_tmpdir
  remote_tmpdir="$(/usr/bin/ssh -o BatchMode=yes media 'mktemp -d /tmp/yt.XXXXXX')" || {
    echo "❌ Failed to create remote temp dir"
    return 1
  }

  # Setup cleanup trap to ensure temp files are removed even on interrupt
  trap "/usr/bin/ssh media \"rm -rf '$remote_tmpdir' 2>/dev/null || true\" 2>/dev/null; trap - INT TERM; return 130" INT TERM

  # Put cookie inside tempdir to avoid collisions
  local remote_cookie="$remote_tmpdir/cookies.txt"

  # Upload cookies (lock down perms on remote)
  echo "🍪 Copying cookies to media VM..."
  # shellcheck disable=SC2029  # Intentional client-side expansion
  /usr/bin/scp -q "$LOCAL_YT_COOKIES" "media:$remote_cookie" || {
    echo "❌ Failed to copy cookies to media VM"
    # shellcheck disable=SC2029  # Intentional client-side expansion
    /usr/bin/ssh media "rm -rf '$remote_tmpdir' 2>/dev/null || true"
    return 1
  }
  # shellcheck disable=SC2029  # Intentional client-side expansion
  /usr/bin/ssh media "chmod 600 '$remote_cookie' >/dev/null 2>&1 || true" || true

  # Build remote final dir
  local remote_final_dir="${REMOTE_FINAL_BASE}/${category}"

  echo "⏬ Downloading on media VM to: $remote_tmpdir"
  echo "📦 Final destination: $remote_final_dir"
  echo ""

  # Fetch video info for display and duplicate checking
  echo "🔍 Fetching video info..."
  local video_info
  video_info="$(/usr/bin/ssh -o BatchMode=yes media "yt-dlp --print '%(id)s|%(title)s|%(height)sp' --cookies $(printf '%q' "$remote_cookie") $(printf '%q' "$url") 2>/dev/null" || echo "unknown|Unknown Video|0p")"

  local video_id="${video_info%%|*}"
  local video_title="${${video_info#*|}%%|*}"
  local new_quality="${video_info##*|}"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📹 VIDEO: $video_title"
  echo "🆔 ID: $video_id"
  echo "📊 Quality: $new_quality"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Check if video already exists
  echo "🔎 Checking for existing downloads..."
  local existing_file
  existing_file="$(/usr/bin/ssh -o BatchMode=yes media "find $(printf '%q' "$remote_final_dir") -type f -name '*\\[${video_id}\\]*' 2>/dev/null | head -1" || echo "")"

  if [[ -n "$existing_file" ]]; then
    echo "⚠️  Found existing file: $(basename "$existing_file")"

    # Get quality of existing file using ffprobe
    local existing_quality
    existing_quality="$(/usr/bin/ssh -o BatchMode=yes media "ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 $(printf '%q' "$existing_file") 2>/dev/null" || echo "0")"
    existing_quality="${existing_quality}p"

    echo "   Existing quality: $existing_quality"
    echo "   New quality: $new_quality"

    # Compare qualities (extract numeric values)
    local existing_num="${existing_quality%p}"
    local new_num="${new_quality%p}"

    if [[ "$new_num" -le "$existing_num" ]]; then
      echo ""
      echo "❌ Skipping download - existing file has equal or better quality"
      echo "   To force re-download, delete: $existing_file"
      # Clear trap and cleanup
      trap - INT TERM
      /usr/bin/ssh media "rm -rf '$remote_tmpdir' 2>/dev/null || true"
      return 0
    else
      echo ""
      echo "✅ New quality is better - proceeding with download"
      echo "   Old file will be replaced"
    fi
  else
    echo "✓ No existing download found"
  fi
  echo ""

  # Run yt-dlp remotely, then move results to final dir
  local remote_script='
set -euo pipefail

tmpdir="$1"
cookie="$2"
finaldir="$3"
url="$4"

mkdir -p "$finaldir"

yt-dlp \
  --cookies "$cookie" \
  --embed-metadata \
  --embed-chapters \
  --embed-thumbnail \
  --convert-thumbnails jpg \
  --sub-langs "en.*,nl,de,es" \
  --write-auto-subs \
  --embed-subs \
  -f bestvideo+bestaudio \
  --merge-output-format mkv \
  --restrict-filenames \
  -o "$tmpdir/%(uploader)s-%(title)s-[%(id)s].%(ext)s" \
  "$url"

shopt -s nullglob
files=("$tmpdir"/*.{mkv,mp4,jpg,webp,srt,vtt,json,nfo} "$tmpdir"/*info.json)
if (( ${#files[@]} == 0 )); then
  echo "❌ No output files found in $tmpdir"
  ls -la "$tmpdir" || true
  exit 2
fi

echo "✅ Download complete. Moving to final dir..."
mv -v "${files[@]}" "$finaldir/"

# cleanup secrets + tmp
rm -f "$cookie" || true
rmdir "$tmpdir" 2>/dev/null || rm -rf "$tmpdir"

echo "✅ Done."
'

  if /usr/bin/ssh -o BatchMode=yes media "bash -s -- $(printf '%q' "$remote_tmpdir") $(printf '%q' "$remote_cookie") $(printf '%q' "$remote_final_dir") $(printf '%q' "$url")" <<<"$remote_script"; then
    # Clear trap and cleanup manually on success
    trap - INT TERM
    /usr/bin/ssh media "rm -rf '$remote_tmpdir' 2>/dev/null || true"
    echo ""
    echo "✅ Successfully downloaded to: $remote_final_dir"
    return 0
  else
    local exit_code=$?
    echo "❌ Remote job failed (exit code: $exit_code)"
    # Clear trap and cleanup manually on failure
    trap - INT TERM
    # shellcheck disable=SC2029  # Intentional client-side expansion
    /usr/bin/ssh media "rm -rf '$remote_tmpdir' 2>/dev/null || true"
    return 1
  fi
}

# Convenience commands
alias ytg='noglob _ytdl_on_media_vm training'
alias yt='noglob _ytdl_on_media_vm youtube'
alias ytc='noglob _ytdl_on_media_vm create'
alias ytm='noglob _ytdl_on_media_vm music'
alias yth='noglob _ytdl_on_media_vm humanity'
alias ytt='noglob _ytdl_on_media_vm travel'
alias ytme='noglob _ytdl_on_media_vm math+engineering'
