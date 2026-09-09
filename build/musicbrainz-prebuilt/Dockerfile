ARG MUSICBRAINZ_SERVER_VERSION=v-2026-07-30.1
ARG MUSICBRAINZ_BUILD_SEQUENCE=0
FROM metabrainz/musicbrainz-docker-musicbrainz:${MUSICBRAINZ_SERVER_VERSION}-build${MUSICBRAINZ_BUILD_SEQUENCE}

RUN mkdir -p /var/cache/musicbrainz/solr-backups
COPY scripts/createdb.sh scripts/fetch-dump.sh /usr/local/bin/
COPY lib/ /opt/musicbrainz-docker/perl/
RUN chmod 755 /usr/local/bin/createdb.sh /usr/local/bin/fetch-dump.sh
RUN perl -0pi -e 's{system\(\$\^X, "\$FindBin::Bin/MBImport\.pl", \@opts, \@\$import\);}{system(\$^X, "-I/opt/musicbrainz-docker/perl", "-MMusicBrainzDocker::ImportPatch", "\$FindBin::Bin/MBImport.pl", \@opts, \@\$import);}' /musicbrainz-server/admin/InitDb.pl
RUN perl -0pi -e 's{(Schema sequence mismatch - codebase is %d, snapshot files are %d\\n",\n\s+scalar localtime,\n\s+DBDefs->DB_SCHEMA_SEQUENCE,\n\s+\$SCHEMA_SEQUENCE,\n\s+;\n)\s+exit 1;\n}{\1    if (\$SCHEMA_SEQUENCE > DBDefs->DB_SCHEMA_SEQUENCE) {\n        exit 1;\n    }\n}s; s{(Schema sequence mismatch - codebase is %d, \$tar is %d\\n",\n\s+scalar localtime,\n\s+DBDefs->DB_SCHEMA_SEQUENCE,\n\s+\$all,\n\s+;\n)\s+exit 1;\n}{\1                if (\$all > DBDefs->DB_SCHEMA_SEQUENCE) {\n                        exit 1;\n                }\n}s' /musicbrainz-server/admin/MBImport.pl
RUN grep -F 'MusicBrainzDocker::ImportPatch' /musicbrainz-server/admin/InitDb.pl \
    && grep -F 'CreateSearchConfiguration.sql' /musicbrainz-server/admin/InitDb.pl
