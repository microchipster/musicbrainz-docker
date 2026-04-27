ARG MUSICBRAINZ_SERVER_VERSION=v-2026-04-27.0
ARG MUSICBRAINZ_BUILD_SEQUENCE=0
FROM metabrainz/musicbrainz-docker-musicbrainz:${MUSICBRAINZ_SERVER_VERSION}-build${MUSICBRAINZ_BUILD_SEQUENCE}

RUN mkdir -p /var/cache/musicbrainz/solr-backups
COPY scripts/createdb.sh scripts/fetch-dump.sh /usr/local/bin/
COPY lib/ /opt/musicbrainz-docker/perl/
RUN chmod 755 /usr/local/bin/createdb.sh /usr/local/bin/fetch-dump.sh
RUN perl -0pi -e 's{system\(\$\^X, "\$FindBin::Bin/MBImport\.pl", \@opts, \@\$import\);}{system(\$^X, "-I/opt/musicbrainz-docker/perl", "-MMusicBrainzDocker::ImportPatch", "\$FindBin::Bin/MBImport.pl", \@opts, \@\$import);}' /musicbrainz-server/admin/InitDb.pl
RUN grep -F 'MusicBrainzDocker::ImportPatch' /musicbrainz-server/admin/InitDb.pl \
    && grep -F 'CreateSearchConfiguration.sql' /musicbrainz-server/admin/InitDb.pl
