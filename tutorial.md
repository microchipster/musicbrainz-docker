# MusicBrainz Mirror Tutorial

This tutorial describes the workflow for the patched setup in this worktree:

- bootstrap or repair the stack with `./setup-musicbrainz`
- query the local MusicBrainz API
- keep the replica current over time
- move the database to another machine if needed

## 1. Bring the stack up

Run everything through the host-side wrapper:

```bash
./setup-musicbrainz
```

What it does:

- reuses a validated dump cache under `${MUSICBRAINZ_CACHE_DIR:-${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}}/dbdump`
- reuses a validated Solr backup cache under `${MUSICBRAINZ_CACHE_DIR:-${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}}/solrdump`
- keeps live Postgres/RabbitMQ/Solr data under `${MUSICBRAINZ_LIVE_DATA_DIR:-${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}}` by default
- repairs broken volume layouts
- optionally configures Ubuntu UFW for the published web port when UFW is active
- imports or upgrades the database as needed
- enables live search indexing and bootstraps Solr from backup archives when it is still empty
- fails on incomplete Solr backup archives by default, or creates empty missing collections only when `MUSICBRAINZ_ALLOW_PARTIAL_SOLR_BOOTSTRAP=1` is explicitly set
- starts the web service
- verifies the homepage and a real artist lookup before exiting successfully
- finishes with the same reusable health gate available as `./verify-musicbrainz`

Important note:

- the wrapper now enables the replication-token and replication-cron compose overrides itself
- replication can now be automated inside the `musicbrainz` container
- the wrapper also enables the live-indexing compose override for Solr updates

The script is intended to be rerunnable. If the database is already healthy, it should skip the expensive import path and just ensure the stack is still correct.

Before first run, provide the MetaBrainz replication token either as an environment variable or a local secret file:

```bash
export MUSICBRAINZ_REPLICATION_TOKEN='your-token-here'
# or:
mkdir -p local/secrets
printf '%s\n' 'your-token-here' > local/secrets/metabrainz_access_token
chmod 600 local/secrets/metabrainz_access_token
```

Optional persistent local setup settings can go in `local/setup.env`. The wrapper sources this file before reading its environment variables, which is useful when the data root lives somewhere other than the default XDG location:

```bash
mkdir -p local
printf '%s\n' 'MUSICBRAINZ_DATA_DIR=/srv/musicbrainz-docker' > local/setup.env
chmod 600 local/setup.env
```

You can also split fast live data from large reusable caches. For example, keep live PostgreSQL/Solr/RabbitMQ state on SSD while keeping dump archives and Solr backup archives on larger HDD storage:

```bash
cat > local/setup.env <<'EOF'
MUSICBRAINZ_DATA_DIR=/srv/musicbrainz-docker
MUSICBRAINZ_LIVE_DATA_DIR=/srv/musicbrainz-docker
MUSICBRAINZ_CACHE_DIR=/mnt/large-disk/musicbrainz-docker
EOF
chmod 600 local/setup.env
```

## 2. Check that the services are up

```bash
docker compose ps
```

You should normally see at least:

- `db`
- `mq`
- `redis`
- `search`
- `musicbrainz`

Quick smoke test:

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:5000/
```

Expected result:

```text
200
```

For the full repo-local health gate that `./setup-musicbrainz` uses at the end, run:

```bash
./verify-musicbrainz
```

That verifies:

- the expected services are running
- replication cron is installed
- the homepage and a real `/ws/2` artist lookup succeed
- all expected Solr collections exist and answer normal `/select` requests

## 3. Interact with the API

The local MusicBrainz web service is exposed on `http://localhost:5000/ws/2`.

General tips:

- add `fmt=json` unless you specifically want XML
- use MBIDs when you want deterministic lookups
- use `jq` locally to inspect the JSON quickly

### Lookup by MBID

```bash
curl -fsS 'http://localhost:5000/ws/2/artist/b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d?fmt=json' | jq .
```

That should return the Beatles record on a healthy replica.

### Search by name

```bash
curl -G -fsS 'http://localhost:5000/ws/2/artist/' \
  --data-urlencode 'query=artist:Beatles' \
  --data-urlencode 'limit=5' \
  --data-urlencode 'fmt=json' \
  | jq '.artists[] | {id, name, country}'
```

### Browse releases for an artist

```bash
curl -G -fsS 'http://localhost:5000/ws/2/release' \
  --data-urlencode 'artist=b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d' \
  --data-urlencode 'limit=5' \
  --data-urlencode 'fmt=json' \
  | jq '.releases[] | {id, title, date}'
```

### Request more linked data

```bash
curl -fsS 'http://localhost:5000/ws/2/artist/b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d?inc=aliases+tags+ratings&fmt=json' | jq .
```

## 4. Keep the replica up to date indefinitely

There are still two moving parts:

1. the PostgreSQL mirror data
2. the Solr search indexes

But the patched setup now wires both of them automatically.

### 4.1 Replication now runs through in-container cron

`./setup-musicbrainz` now owns the compose override chain directly and includes:

- `compose/replication-token.yml`
- `compose/replication-cron.yml`
- `local/compose/bind-mounts.yml`

That means a healthy rerun should leave the `musicbrainz` container with:

- the MetaBrainz token secret mounted
- `/crons.conf` mounted from `default/replication.cron`
- root's crontab populated with `/usr/local/bin/replication.sh`

You can verify that with:

```bash
docker compose exec -T musicbrainz crontab -l
```

Expected line:

```text
0 3 * * * /usr/local/bin/replication.sh
```

### 4.2 Replication prerequisites

Replication needs the MetaBrainz access token secret available to the `musicbrainz` service.

This compose stack provides that through `compose/replication-token.yml`, which reads:

- `local/secrets/metabrainz_access_token`

If you already ran `./setup-musicbrainz`, that secret file should already exist.

### 4.3 Manual replication command

When you want to catch up immediately, run:

```bash
docker compose up -d --no-build db mq redis search musicbrainz
docker compose exec -T musicbrainz replication.sh
```

Useful checks afterward:

```bash
docker compose exec -T musicbrainz tail -n 50 mirror.log
docker compose exec -T db psql -U musicbrainz -d musicbrainz_db -c 'SELECT * FROM musicbrainz.replication_control;'
```

### 4.4 Search indexing is now automated too

`./setup-musicbrainz` now includes `compose/live-indexing-search.yml` in the compose chain and bootstraps the existing SIR AMQP path.

On a healthy setup it will:

- ensure RabbitMQ has the `sir` user and `/search-index-rebuilder` vhost
- install the PostgreSQL `amqp` extension if it is missing
- install the SIR trigger set if it is missing
- verify or repair the local Solr backup cache under the configured cache root
- load those backup archives into Solr when the collections are still empty
- create the collections that are not reliably supplied by backup restore (`editor`, and `work` when needed)
- start the `indexer` watcher and run `python -m sir amqp_setup`
- keep the `indexer` service running in AMQP watch mode afterward

That means the normal steady state is:

- PostgreSQL stays current through the in-container replication cron
- Solr is seeded from backup archives once and then stays current through the `indexer` AMQP watcher

You can verify that the live-indexing watcher is part of the stack with:

```bash
docker compose ps indexer
```

And you can verify that the `artist` collection is populated with:

```bash
docker compose exec -T search sh -lc "wget -qO- 'http://localhost:8983/solr/artist/select?q=*:*&rows=0&wt=json'" | jq '.response.numFound'
```

On a healthy indexed mirror that value should be greater than `0`.

### 4.5 Manual search rebuild when you explicitly want one

The wrapper should make this unnecessary for normal operation. If you intentionally want to rebuild search directly from the database instead:

```bash
docker compose exec -T indexer python -m sir reindex
```

### 4.6 Safe steady-state routine

For day-to-day operations, a practical routine is:

1. Let the in-container replication cron run normally.
2. Leave the `indexer` service running so AMQP live indexing can consume updates.
3. Check `mirror.log` after upstream schema releases or after any long outage.
4. Re-run `./setup-musicbrainz` after pulling repo changes, after a host reboot, or any time you want the wrapper to verify the stack end to end.
5. Leave `search` and `indexer` running so Solr stays current through backup restore plus AMQP live indexing.

## 5. Migrate the database to another machine

There are two reasonable approaches.

### 5.1 Fast same-version move

Use this when the destination will run the same Docker images and Postgres major version.

What must be preserved:

- data root `${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}`
- cache root `${MUSICBRAINZ_CACHE_DIR:-$MUSICBRAINZ_DATA_DIR}` if it differs from the data root
- live data root `${MUSICBRAINZ_LIVE_DATA_DIR:-$MUSICBRAINZ_DATA_DIR}` if it differs from the data root
- repo checkout and local secrets/config files

On the source machine:

1. Stop the stack cleanly.

```bash
docker compose stop musicbrainz search mq db
```

2. Copy the configured data roots and local config.

```bash
mkdir -p backup
rsync -a "${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}/" backup/musicbrainz/
rsync -a "${MUSICBRAINZ_CACHE_DIR:-${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}}/" backup/musicbrainz-cache/
rsync -a "${MUSICBRAINZ_LIVE_DATA_DIR:-${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}}/" backup/musicbrainz-live/
rsync -a local/ backup/local/
cp default/postgres.env backup/postgres.env
```

3. Transfer `backup/` and the repo checkout to the new machine.

On the destination machine:

1. Check out the same repo revision and keep the same project directory name if possible (`musicbrainz-docker`).
2. Restore the configured data roots.

```bash
mkdir -p "${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}"
rsync -a backup/musicbrainz/ "${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}/"
rsync -a backup/musicbrainz-cache/ "${MUSICBRAINZ_CACHE_DIR:-${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}}/"
rsync -a backup/musicbrainz-live/ "${MUSICBRAINZ_LIVE_DATA_DIR:-${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}}/"
```

3. Restore `local/` and run the wrapper.

```bash
rsync -a backup/local/ local/
./setup-musicbrainz
```

Expected result:

- the wrapper should detect the database is already initialized
- it should not redownload the dumps
- it should bring the services back up and rerun the HTTP sanity checks

### 5.2 Slower but more portable logical backup

If you cannot guarantee the same Docker/Postgres environment, use a logical dump instead of copying raw `pgdata`.

Example:

```bash
docker compose exec -T db pg_dump -U musicbrainz -Fc musicbrainz_db > musicbrainz_db.dump
```

Then restore it on the destination into a compatible PostgreSQL instance before starting the app stack.

This is slower for a full mirror, but it is safer across machine changes.

## 6. Useful recovery checks

Check whether the DB looks initialized:

```bash
docker compose exec -T db psql -U musicbrainz -d musicbrainz_db -Atc "SELECT to_regclass('musicbrainz.replication_control') IS NOT NULL, EXISTS (SELECT 1 FROM musicbrainz.replication_control), to_regclass('musicbrainz.track') IS NOT NULL, EXISTS (SELECT 1 FROM musicbrainz.track);"
```

Check the homepage and API again:

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:5000/
curl -fsS 'http://localhost:5000/ws/2/artist/b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d?fmt=json' | jq -e '.id == "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"'
```

If either fails, rerun:

```bash
./setup-musicbrainz
```
