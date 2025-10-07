#!/bin/bash
# set -euo pipefail # uncomment once script has no issues.

OUTPUT_DIR="/config"

RADARR_HOST="http://host:port"
RADARR_APIKEY="apikey"

INDEXER_NAME="secretwebsite"
NZB_HOST="https://host"
NZB_API_TOKEN="apikey" # api key from the other site

IMGBB_APIKEY="apikey" # register on imgbb.com, then go here: https://api.imgbb.com/ and generate an api key
SCREENS_COUNT=6
IMGBB_TIMEOUT=60  # in seconds.
SCREENSHOTS_ENABLE=true

MAX_RETRIES=3
DELAY_FIRST=60
DELAY_RETRY=120

EVENT_TYPE="${radarr_eventtype:-}"
MOVIE_ID="${radarr_movie_id:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
trap 'rc=$?; log "Script exiting with status $rc"; exit $rc' ERR

log "Event='${EVENT_TYPE:-}', MovieID='${MOVIE_ID:-}'"

if [ "$EVENT_TYPE" != "Download" ]; then
  log "Not a Download event. Exiting."
  exit 0
fi

grabbedRecord=""
attempt=1

while [ $attempt -le $MAX_RETRIES ]; do
  history_json=$(curl -s \
    "${RADARR_HOST%/}/api/v3/history?page=1&pageSize=30&movieIds=${MOVIE_ID}&apikey=${RADARR_APIKEY}" \
    -H "accept: application/json")

  grabbedRecord=$(echo "$history_json" | jq -c '.records[] | select(.eventType | contains("grabbed"))' | head -n 1 || true)
  [ -n "$grabbedRecord" ] && break

  sleep $([ $attempt -eq 1 ] && echo $DELAY_FIRST || echo $DELAY_RETRY)
  attempt=$((attempt + 1))
done

[ -z "$grabbedRecord" ] && { log "No grabbed record found. Exiting."; exit 0; }

nzbInfoUrl=$(echo "$grabbedRecord" | jq -r '.data.nzbInfoUrl // empty')
indexer=$(echo "$grabbedRecord" | jq -r '.data.indexer // empty')
sourceTitle_from_history=$(echo "$grabbedRecord" | jq -r '.sourceTitle // empty')

log "Grabbed record found. Indexer='$indexer', SourceTitle='${sourceTitle_from_history:-}'"


if ! echo "$indexer" | grep -qi "$INDEXER_NAME"; then
  log "Indexer '$indexer' does not match target '$INDEXER_NAME'. Skipping mediainfo and upload."
  log "Script finished successfully (nothing to do)."
  exit 0
fi

# Now to get the file path for the movie. Endpoint docs: https://radarr.video/docs/api/#/Movie/get_api_v3_movie__id_

movieFilePath=""
sceneName=""
attempt=1

while [ $attempt -le $MAX_RETRIES ]; do
  movie_json=$(curl -s "${RADARR_HOST%/}/api/v3/movie/${MOVIE_ID}?apikey=${RADARR_APIKEY}" \
    -H "accept: application/json")

  movieFilePath=$(echo "$movie_json" | jq -r '.movieFile.path // empty')
  sceneName=$(echo "$movie_json" | jq -r '.movieFile.sceneName // empty')

  [ -n "$movieFilePath" ] && break

  sleep $([ $attempt -eq 1 ] && echo $DELAY_FIRST || echo $DELAY_RETRY)
  attempt=$((attempt + 1))
done

[ -z "$movieFilePath" ] && { log "No movie file path found. Exiting."; exit 0; }
[ ! -f "$movieFilePath" ] && { log "Movie file not found at $movieFilePath. Exiting."; exit 0; }

safe_sourceTitle="${sourceTitle_from_history:-$sceneName}"
[ -z "$safe_sourceTitle" ] && safe_sourceTitle="$(basename "$movieFilePath")"

outFile="${OUTPUT_DIR}/${safe_sourceTitle}.txt"
filename_only="$(basename "$movieFilePath")"

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

  if [ "$sceneName" = "$release_name" ] && \
     [ "$mediainfo_current" = "false" ] && \
     [ "$can_add" = "true" ] && \
     [ "$mediainfo_allowed" = "true" ]; then

	mediainfo "$movieFilePath" | \
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
  if [ "$sceneName" = "$release_name" ] && \
     [ "$screenshots_current" = "false" ] && \
     [ "$can_add" = "true" ] && \
	 [ "$SCREENSHOTS_ENABLE" = "true" ] && \
     [ "$screenshots_allowed" = "true" ]; then

    log "Uploading screenshots for release '$release_name' (uuid=$uuid)..."
	
	SCREENS_OUTPUT_DIR="/config/$sceneName"
	mkdir -p "$SCREENS_OUTPUT_DIR"
	duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$movieFilePath")
	echo "Duration: $duration seconds"
	
	echo "Capturing $SCREENS_COUNT screenshots for $sceneName..."

	for i in $(seq 1 $SCREENS_COUNT); do
		# Calculate timestamp
		ts=$(echo "$duration * $i / ($SCREENS_COUNT + 1)" | bc -l)
		ts_fmt=$(printf "%.3f" "$ts")

		outFile=$(printf "%s/screenshot_%02d_%s.jpg" "$SCREENS_OUTPUT_DIR" "$i" "$ts_fmt")
		echo "Frame at $ts_fmt sec -> $outFile"

		ffmpeg -v error -ss "$ts_fmt" -i "$movieFilePath" -vframes 1 -q:v 1 -update 1 "$outFile"
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

log "Script finished."
exit 0