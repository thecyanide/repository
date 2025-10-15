#!/bin/bash
# set -euo pipefail # uncomment once script has no issues.

SONARR_HOST="http://host:port"
SONARR_APIKEY="apikey"
IMGBB_APIKEY="apikey"
NZB_API_TOKEN="api for the other website"
OUTPUT_DIR="/config"
NZB_HOST="https://secret-website-address.com"
INDEXER_NAME="secret-website-name"
SCREENS_COUNT=6
IMGBB_TIMEOUT=60  # in seconds.
SCREENSHOTS_ENABLE=true
MAX_RETRIES=3
DELAY_FIRST=60
DELAY_RETRY=120

EVENT_TYPE="${sonarr_eventtype:-}"
DOWNLOAD_ID="${sonarr_download_id:-}"
EPISODE_IDS="${sonarr_episodefile_episodeids:-}"

echo "$EPISODE_IDS"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
trap 'rc=$?; log "Script exiting with status $rc"; exit $rc' ERR

log "Script started. Event='${EVENT_TYPE:-}', Download ID='${DOWNLOAD_ID:-}'"

if [ "$EVENT_TYPE" != "Download" ]; then
  log "Not a Download event. Exiting."
  exit 0
fi

grabbedRecord=""
attempt=1

while [ $attempt -le $MAX_RETRIES ]; do
  history_json=$(curl -s \
    "${SONARR_HOST}/api/v3/history?pageSize=100&downloadId=${DOWNLOAD_ID}&apikey=${SONARR_APIKEY}" \
    -H "accept: application/json")
  grabbedRecord=$(echo "$history_json" | jq -c '.records[] | select(.eventType | contains("grabbed"))' | head -n 1 || true)
  [ -n "$grabbedRecord" ] && break
  sleep $([ $attempt -eq 1 ] && echo $DELAY_FIRST || echo $DELAY_RETRY)
  attempt=$((attempt + 1))
done

[ -z "$grabbedRecord" ] && { log "No grabbed record found. Exiting."; exit 0; }

echo "Grabbed record: $grabbedRecord"

nzbInfoUrl=$(echo "$grabbedRecord" | jq -r '.data.nzbInfoUrl // empty')
indexer=$(echo "$grabbedRecord" | jq -r '.data.indexer // empty')
sourceTitle_from_history=$(echo "$grabbedRecord" | jq -r '.sourceTitle // empty')

log "Grabbed record found. Indexer='$indexer', SourceTitle='${sourceTitle_from_history:-}'"

echo "Info URL: $nzbInfoUrl"

if ! echo "$indexer" | grep -qi "$INDEXER_NAME"; then
  log "Indexer '$indexer' does not match target '$INDEXER_NAME'. Skipping mediainfo and upload."
  log "Hook finished successfully (nothing to do)."
  exit 0
fi

SMALLEST_ID=$(echo "$sonarr_episodefile_episodeids" | tr ',' '\n' | sort -n | head -n1)
EPISODE_JSON=$(curl -s "${SONARR_HOST}/api/v3/episode/${SMALLEST_ID}?apikey=${SONARR_APIKEY}")
EPISODE_FILE_PATH=$(echo "$EPISODE_JSON" | jq -r '.episodeFile.path')

SCENE_NAME=$(echo "$EPISODE_JSON" | jq -r '.episodeFile.sceneName')
if [ -z "$SCENE_NAME" ] || [ "$SCENE_NAME" = "null" ]; then
    SCENE_NAME=$(echo "$EPISODE_JSON" | jq -r '.title')
fi

SAFE_TITLE=$(echo "$SCENE_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_.-')

[ -z "$EPISODE_FILE_PATH" ] && { log "No episode file path found. Exiting."; exit 0; }
[ ! -f "$EPISODE_FILE_PATH" ] && { log "Episode file not found at $EPISODE_FILE_PATH. Exiting."; exit 0; }

outFile="${OUTPUT_DIR}/${SCENE_NAME}.txt"
filename_only="$(basename "$EPISODE_FILE_PATH")"

if [ -n "$nzbInfoUrl" ]; then
  uuid=$(basename "$nzbInfoUrl")
  status_json=$(curl -s -H "Authorization: Bearer ${NZB_API_TOKEN}" \
    "${NZB_HOST%/}/api/v1/releases/${uuid}/extras/status")

  release_name=$(echo "$status_json" | jq -r '.release_info.name // empty')
  mediainfo_current=$(echo "$status_json" | jq -r '.current_extras.mediainfo // false')
  screenshots_current=$(echo "$status_json" | jq -r '.current_extras.screenshots // false')
  can_add=$(echo "$status_json" | jq -r '.permissions.can_add // false')
  mediainfo_allowed=$(echo "$status_json" | jq -r '.allowed_operations.mediainfo // false')
  screenshots_allowed=$(echo "$status_json" | jq -r '.allowed_operations.screenshots // false')

  if [ "$mediainfo_current" = "false" ] && \
     [ "$can_add" = "true" ] && \
     [ "$mediainfo_allowed" = "true" ]; then

	mediainfo "$EPISODE_FILE_PATH" | \
	  sed "s|^Complete name *:.*|Complete name                            : $filename_only|" \
	  > "$outFile"

	log "Mediainfo generated: $outFile"

    log "Uploading mediainfo for release '$release_name' (uuid=$uuid)..."
    upload_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: Bearer ${NZB_API_TOKEN}" \
      -F "mediainfo=@${outFile}" \
      "${NZB_HOST%/}/api/v1/releases/${uuid}/extras")

    if echo "$upload_status" | grep -qE '^2'; then
      log "Upload succeeded (status $upload_status)."
    else
      log "Upload failed (status $upload_status)."
    fi
	rm -f "$outFile"
  else
    log "Upload skipped (conditions not met)."
  fi
  if [ "$screenshots_current" = "false" ] && \
     [ "$can_add" = "true" ] && \
	 [ "$SCREENSHOTS_ENABLE" = "true" ] && \
     [ "$screenshots_allowed" = "true" ]; then

    log "Uploading screenshots for release '$release_name' (uuid=$uuid)..."

	SCREENS_OUTPUT_DIR="/config/$SCENE_NAME"
	mkdir -p "$SCREENS_OUTPUT_DIR"
	duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$EPISODE_FILE_PATH")
	echo "Duration: $duration seconds"

	echo "Capturing $SCREENS_COUNT screenshots for $sceneName..."

	for i in $(seq 1 $SCREENS_COUNT); do
		# Calculate timestamp
		ts=$(echo "$duration * $i / ($SCREENS_COUNT + 1)" | bc -l)
		ts_fmt=$(printf "%.3f" "$ts")

		outFile=$(printf "%s/screenshot_%02d_%s.jpg" "$SCREENS_OUTPUT_DIR" "$i" "$ts_fmt")
		echo "Frame at $ts_fmt sec -> $outFile"

		ffmpeg -v error -ss "$ts_fmt" -i "$EPISODE_FILE_PATH" -vframes 1 -q:v 1 -update 1 "$outFile"
	done

	echo "Screenshots saved in: $SCREENS_OUTPUT_DIR"

	urls=()
	pids=()
	tmp_urls_file=$(mktemp)

	for img in "$SCREENS_OUTPUT_DIR"/*.jpg; do
		(
			echo "Uploading $img..."
			response=$(curl -s --max-time $IMGBB_TIMEOUT --location --request POST \
				"https://api.imgbb.com/1/upload?key=${IMGBB_APIKEY}" \
				--form "image=@${img}")

			url=$(echo "$response" | jq -r '.data.url')
			if [[ "$url" != "null" && -n "$url" ]]; then
				echo "$url" >> "$tmp_urls_file"
				echo "Uploaded $img"
			else
				echo "Upload failed or timed out for $img" >&2
			fi
		) &
		pids+=($!)
	done

	for pid in "${pids[@]}"; do
		wait "$pid"
	done
	mapfile -t urls < "$tmp_urls_file"
	rm "$tmp_urls_file"

	echo "All uploads completed. Collected URLs:"
	printf '%s\n' "${urls[@]}"
	screenshots_json=$(printf '%s\n' "${urls[@]}" | jq -R . | jq -s .)

	upload_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: Bearer ${NZB_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --argjson s "$screenshots_json" '{screenshots: $s}')" \
      "${NZB_HOST%/}/api/v1/releases/${uuid}/extras")

	echo "Upload status: $upload_status"

    if echo "$upload_status" | grep -qE '^2'; then
      log "Upload succeeded (status $upload_status)."
    else
      log "Upload failed (status $upload_status)."
    fi
	rm -rf "$SCREENS_OUTPUT_DIR"
  else
    log "Upload skipped (conditions not met)."
  fi
else
  log "No nzbInfoUrl found. Skipping upload."
fi

log "Script finished running."
exit 0
