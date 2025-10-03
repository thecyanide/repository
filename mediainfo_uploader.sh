#!/bin/bash
# set -euo pipefail # uncomment once script has no issues.

RADARR_HOST="http://host:port"
RADARR_APIKEY="apikey" # api key from radarr
NZB_API_TOKEN="apikey" # api key from the other site
OUTPUT_DIR="/config"
NZB_HOST="https://host"
INDEXER_NAME = "secretwebsite"

MAX_RETRIES=3
DELAY_FIRST=60
DELAY_RETRY=120

EVENT_TYPE="${radarr_eventtype:-}"
MOVIE_ID="${radarr_movie_id:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
trap 'rc=$?; log "Script exiting with status $rc"; exit $rc' ERR

log "Hook started. Event='${EVENT_TYPE:-}', MovieID='${MOVIE_ID:-}'"

if [ "$EVENT_TYPE" != "Download" ]; then
  log "Not a Download event. Exiting."
  exit 0
fi

# To check recent activity in Radarr for the triggered movie. Refer to Radarr api docs to get more info about the endpoint: https://radarr.video/docs/api/#/History/get_api_v3_history

grabbedRecord=""
attempt=1

# I've had issues on a couple of occassions where Radarr didn't give out the correct info on the first attempt. So the script will retry a couple of times after sleeping.

while [ $attempt -le $MAX_RETRIES ]; do
  history_json=$(curl -s \
    "${RADARR_HOST%/}/api/v3/history?page=1&pageSize=30&movieIds=${MOVIE_ID}&apikey=${RADARR_APIKEY}" \
    -H "accept: application/json" -H "X-Api-Key: ${RADARR_APIKEY}")

  grabbedRecord=$(echo "$history_json" | jq -c '.records[] | select(.eventType | contains("grabbed"))' | head -n 1 || true)
  [ -n "$grabbedRecord" ] && break

  sleep $([ $attempt -eq 1 ] && echo $DELAY_FIRST || echo $DELAY_RETRY)
  attempt=$((attempt+1))
done

[ -z "$grabbedRecord" ] && { log "No grabbed record found. Exiting."; exit 0; }

nzbInfoUrl=$(echo "$grabbedRecord" | jq -r '.data.nzbInfoUrl // empty')
indexer=$(echo "$grabbedRecord" | jq -r '.data.indexer // empty')
sourceTitle_from_history=$(echo "$grabbedRecord" | jq -r '.sourceTitle // empty')

log "Grabbed record found. Indexer='$indexer', SourceTitle='${sourceTitle_from_history:-}'"



# Now to get the file path for the movie. Endpoint docs: https://radarr.video/docs/api/#/Movie/get_api_v3_movie__id_

movieFilePath=""
sceneName=""
attempt=1

while [ $attempt -le $MAX_RETRIES ]; do
  movie_json=$(curl -s "${RADARR_HOST%/}/api/v3/movie/${MOVIE_ID}?apikey=${RADARR_APIKEY}" \
    -H "accept: application/json" -H "X-Api-Key: ${RADARR_APIKEY}")

  movieFilePath=$(echo "$movie_json" | jq -r '.movieFile.path // empty')
  sceneName=$(echo "$movie_json" | jq -r '.movieFile.sceneName // empty')
  hasFile=$(echo "$movie_json" | jq -r '.hasFile // false')

  [ -n "$movieFilePath" ] && break

  sleep $([ $attempt -eq 1 ] && echo $DELAY_FIRST || echo $DELAY_RETRY)
  attempt=$((attempt+1))
done

[ -z "$movieFilePath" ] && { log "No movie file path found. Exiting."; exit 0; }
[ ! -f "$movieFilePath" ] && { log "Movie file not found at $movieFilePath. Exiting."; exit 0; }



safe_sourceTitle="${sourceTitle_from_history:-$sceneName}"
[ -z "$safe_sourceTitle" ] && safe_sourceTitle="$(basename "$movieFilePath")"

outFile="${OUTPUT_DIR}/${safe_sourceTitle}.txt"
filename_only="$(basename "$movieFilePath")"


mediainfo "$movieFilePath" | \
  sed "s|^Complete name *:.*|Complete name                            : $filename_only|" \
  > "$outFile"

log "Mediainfo generated: $outFile"



if [ -n "$nzbInfoUrl" ] && echo "$indexer" | grep -qi "$INDEXER_NAME"; then
  uuid=$(basename "$nzbInfoUrl")
  status_json=$(curl -s -H "Authorization: Bearer ${NZB_API_TOKEN}" \
    "${NZB_HOST%/}/api/v1/releases/${uuid}/extras/status")

  release_name=$(echo "$status_json" | jq -r '.release_info.name // empty')
  mediainfo_current=$(echo "$status_json" | jq -r '.current_extras.mediainfo // false')
  can_add=$(echo "$status_json" | jq -r '.permissions.can_add // false')
  allowed=$(echo "$status_json" | jq -r '.allowed_operations.mediainfo // false')

  if [ "$sceneName" = "$release_name" ] && \
     [ "$mediainfo_current" = "false" ] && \
     [ "$can_add" = "true" ] && \
     [ "$allowed" = "true" ]; then

    log "Uploading mediainfo for release '$release_name' (uuid=$uuid)..."
    upload_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: Bearer ${NZB_API_TOKEN}" \
      -F "mediainfo=@${outFile}" \
      "${NZB_HOST%/}/api/v1/releases/${uuid}/extras")

    if echo "$upload_status" | grep -qE '^2'; then
      log "Upload succeeded (status $upload_status). Cleaning up..."
      rm -f "$outFile"
    else
      log "Upload failed (status $upload_status). Keeping mediainfo file for review."
    fi
  else
    log "Upload skipped (conditions not met)."
  fi
else
  log "Not the correct indexer or no nzbInfoUrl. Skipping upload."
fi

log "Hook finished."
exit 0

