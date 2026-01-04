#!/usr/bin/env zsh
# ---- youtube download -> media vm (server-side) ----

# Where the media VM should place final files (NFS mount already available there)
REMOTE_FINAL_BASE="/mnt/nfs/movies/finals"

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

  # Must exist locally BEFORE we do anything
  if [[ ! -f "$LOCAL_YT_COOKIES" ]]; then
    echo "❌ Cookies file not found:"
    echo "   $LOCAL_YT_COOKIES"
    echo "Export youtube.com cookies to this file (Netscape cookies.txt)."
    return 1
  fi

  # Remote temp paths
  local remote_tmpdir
  remote_tmpdir="$(/usr/bin/ssh -o BatchMode=yes media 'mktemp -d /tmp/yt.XXXXXX')" || {
    echo "❌ Failed to create remote temp dir"
    return 1
  }

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
    : # success
  else
    echo "❌ Remote job failed"
    # best-effort cleanup
    # shellcheck disable=SC2029  # Intentional client-side expansion
    /usr/bin/ssh media "rm -rf '$remote_tmpdir' 2>/dev/null || true"
    return 1
  fi
}

# Convenience commands
alias yt='noglob _ytdl_on_media_vm youtube'
alias ytc='noglob _ytdl_on_media_vm create'
alias ytg='noglob _ytdl_on_media_vm gym'
alias ytm='noglob _ytdl_on_media_vm music'
