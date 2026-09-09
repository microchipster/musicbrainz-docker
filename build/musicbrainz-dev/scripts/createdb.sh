#!/bin/bash

set -e -o pipefail -u

BASE_DOWNLOAD_URL="${MUSICBRAINZ_BASE_FTP_URL:-$MUSICBRAINZ_BASE_DOWNLOAD_URL}"
IMPORT="fullexport"
FETCH_DUMPS=""
WGET_OPTIONS=""
TMP_DIR=/media/dbdump/tmp
LOCAL_DUMP_DIR="$TMP_DIR/dumps"
IMPORT_TMP_DIR="$TMP_DIR/import"

HELP=$(cat <<EOH
Usage: $0 [-wget-opts <options list>] [-sample] [-fetch] [MUSICBRAINZ_BASE_DOWNLOAD_URL]

Options:
  -fetch      Fetch latest dump from MusicBrainz download server
  -sample     Load sample data instead of full data
  -clean      Initialize an empty database
  -wget-opts  Pass additional space-separated options list (should be
              a single argument, escape spaces if necessary) to wget

Default MusicBrainz base download URL: $BASE_DOWNLOAD_URL
EOH
)

if [ $# -gt 4 ]; then
    echo "$0: too many arguments"
    echo "$HELP"
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -wget-opts )
            shift
            WGET_OPTIONS=$1
            ;;
        -sample )
            IMPORT="sample"
            ;;
        -fetch  )
            FETCH_DUMPS="$1"
            ;;
        -clean )
            IMPORT="clean"
            ;;
        -*      )
            echo "$0: unrecognized option '$1'"
            echo "$HELP"
            exit 1
            ;;
        *       )
            BASE_DOWNLOAD_URL="$1"
            ;;
    esac
    shift
done

stage_dumps_locally() {
    local source_dir=/media/dbdump
    local file
    local checksum_line

    mkdir -p "$LOCAL_DUMP_DIR" "$IMPORT_TMP_DIR"

    for file in "${DUMP_FILES[@]}"; do
        cp -f -- "$source_dir/$file" "$LOCAL_DUMP_DIR/$file"

        if [[ -r "$source_dir/MD5SUMS" ]]; then
            checksum_line=$(grep -F "*$file" "$source_dir/MD5SUMS" || true)
            if [[ -z "$checksum_line" ]]; then
                echo "$0: Missing checksum for staged dump '$file'"
                exit 70
            fi
            if ! (cd "$LOCAL_DUMP_DIR" && printf '%s\n' "$checksum_line" | md5sum -c --status); then
                echo "$0: Staged dump '$file' failed checksum validation"
                exit 70
            fi
        fi

        case "$file" in
            *.bz2)
                bzip2 -t -- "$LOCAL_DUMP_DIR/$file"
                ;;
            *.xz)
                xz -t -- "$LOCAL_DUMP_DIR/$file"
                ;;
        esac
    done
}

case "$IMPORT" in
    fullexport  )
        if [[ $MUSICBRAINZ_STANDALONE_SERVER -eq 1 ]]; then
            echo "$0: Only sample data can be loaded in standalone mode"
            echo "$HELP"
            exit 1
        fi
        DUMP_FILES=(
            mbdump.tar.bz2
            mbdump-cdstubs.tar.bz2
            mbdump-cover-art-archive.tar.bz2
            mbdump-event-art-archive.tar.bz2
            mbdump-derived.tar.bz2
            mbdump-stats.tar.bz2
            mbdump-wikidocs.tar.bz2
        );;
    sample      )
        if [[ $MUSICBRAINZ_STANDALONE_SERVER -eq 0 ]]; then
            echo "$0: Only full data can be loaded in mirror mode"
            echo "$HELP"
            exit 1
        fi
        DUMP_FILES=(
            mbdump-sample.tar.xz
        );;
    clean       )
        DUMP_FILES=()
        ;;
esac

if [[ $FETCH_DUMPS == "-fetch" ]]; then
    FETCH_OPTIONS=("${IMPORT/fullexport/replica}" --base-download-url "$BASE_DOWNLOAD_URL")
    if [[ -n "$WGET_OPTIONS" ]]; then
        FETCH_OPTIONS+=(--wget-options "$WGET_OPTIONS")
    fi
    fetch-dump.sh "${FETCH_OPTIONS[@]}"
fi

dockerize -wait "tcp://${MUSICBRAINZ_POSTGRES_SERVER}:5432" -timeout 60s sleep 0

update-perl.sh

stage_dumps_locally
cd "$LOCAL_DUMP_DIR"

INITDB_OPTIONS='--echo --import'
if ! /musicbrainz-server/script/database_exists MAINTENANCE; then
    INITDB_OPTIONS="--createdb $INITDB_OPTIONS"
fi

# shellcheck disable=SC2086
/musicbrainz-server/admin/InitDb.pl $INITDB_OPTIONS -- --skip-editor --tmp-dir "$IMPORT_TMP_DIR" "${DUMP_FILES[@]}"
