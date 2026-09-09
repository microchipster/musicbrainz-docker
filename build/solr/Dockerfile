ARG MB_SOLR_VERSION=4.1.0
ARG APACHE_SOLR_VERSION=9.7.0

FROM metabrainz/mb-solr:${MB_SOLR_VERSION} AS mb_solr

FROM solr:${APACHE_SOLR_VERSION}

ARG MB_SOLR_VERSION
ARG APACHE_SOLR_VERSION

USER root

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq zstd \
 && rm -rf /var/lib/apt/lists/*

USER 8983

LABEL org.metabrainz.based-on-image="solr:${APACHE_SOLR_VERSION}"
LABEL org.metabrainz.musicbrainz-solr-assets="metabrainz/mb-solr:${MB_SOLR_VERSION}"

COPY --from=mb_solr /usr/lib/mbsssss /usr/lib/mbsssss
COPY --from=mb_solr /opt/solr-9.7.0/lib/mb-solr-0.0.1-SNAPSHOT-jar-with-dependencies.jar /usr/lib/mbsssss/lib/
COPY --from=mb_solr /docker-entrypoint-initdb.d/10-install-musicbrainz-conf.sh /docker-entrypoint-initdb.d/
COPY --from=mb_solr /opt/solr/docker/scripts/create-musicbrainz-collections /opt/solr/docker/scripts/
COPY --from=mb_solr /opt/solr/docker/scripts/fetch-backup-archives /opt/solr/docker/scripts/
COPY --from=mb_solr /opt/solr/docker/scripts/load-backup-archives /opt/solr/docker/scripts/
COPY --from=mb_solr /opt/solr/docker/scripts/remove-backup-archives /opt/solr/docker/scripts/
COPY --from=mb_solr /opt/solr/docker/scripts/start-local-solrcloud /opt/solr/docker/scripts/
COPY --from=mb_solr /opt/solr/docker/scripts/start-musicbrainz-solrcloud /opt/solr/docker/scripts/

USER root

RUN sed -i '/musicbrainz-solrcloud-first-run/d' /docker-entrypoint-initdb.d/10-install-musicbrainz-conf.sh

USER 8983

ENV SOLR_OPTS="-Dsolr.sharedLib=/usr/lib/mbsssss/lib"

CMD ["/bin/sh", "-c", "start-musicbrainz-solrcloud"]
