package MusicBrainzDocker::ImportPatch;

use strict;
use warnings;

use English qw(-no_match_vars);
use File::Path qw(remove_tree);
use Time::HiRes qw(gettimeofday tv_interval);

sub _debug {
    return unless $ENV{MUSICBRAINZ_IMPORT_PATCH_DEBUG};
    warn 'MusicBrainzDocker::ImportPatch: ' . join(' ', @_) . "\n";
}

sub _archive_member_for_table {
    my ($table) = @_;

    return ('/media/dbdump/mbdump.tar.bz2', "mbdump/$table")
        if $table =~ /\A(?:isrc|l_artist_recording|l_artist_work|l_label_recording|l_recording_url|l_release_group_release_group|l_release_url|medium|recording|track|url)\z/;

    return ('/media/dbdump/mbdump-cdstubs.tar.bz2', "mbdump/$table")
        if $table =~ /\A(?:cdtoc_raw|release_raw|track_raw)\z/;

    return ('/media/dbdump/mbdump-cover-art-archive.tar.bz2', 'mbdump/cover_art_archive.cover_art')
        if $table eq 'cover_art_archive.cover_art';

    return ('/media/dbdump/mbdump-stats.tar.bz2', 'mbdump/statistics.statistic')
        if $table eq 'statistics.statistic';

    return;
}

sub _force_stream_for_table {
    my ($table) = @_;

    return $table =~ /\A(?:cover_art_archive\.cover_art|isrc|l_artist_recording|l_artist_work|l_release_group_release_group|statistics\.statistic)\z/;
}

sub _psql_literal {
    my ($value) = @_;

    $value =~ s/'/''/g;
    return "'$value'";
}

sub _prepare_copy_source {
    my ($table, $file) = @_;
    my $source_dir = $ENV{MUSICBRAINZ_IMPORT_PATCH_SOURCE_DIR};

    my ($archive, $member) = _archive_member_for_table($table);

    if ($source_dir && !_force_stream_for_table($table)) {
        my $source_file = "$source_dir/mbdump/$table";

        if (-f $source_file) {
            _debug("using pre-extracted source for table=$table file=$source_file");
            return (undef, _psql_literal($source_file), $source_file);
        }
    }

    if ($archive) {
        my $program = "tar -xOf $archive $member";
        _debug("streaming table=$table member=$member from $archive via psql COPY PROGRAM");
        return (undef, 'PROGRAM ' . _psql_literal($program), undef);
    }

    return (undef, _psql_literal($file), $file);
}

sub _copy_table_from_file_via_psql {
    my ($sql, $table, $file, %opts) = @_;

    my $delete_first = $opts{delete_first};
    my $ignore_errors = $opts{ignore_errors};
    my $quiet = $opts{quiet};
    my ($cleanup_dir, $copy_source, $copy_file) = _prepare_copy_source($table, $file);

    _debug("using psql \\copy for table=$table source=$copy_source");

    print localtime() . " : load $table\n"
        unless $quiet;

    my $size = !defined $copy_file || -s($copy_file)
        or return 1;

    my $db_name = $sql->select_single_value('SELECT current_database()');
    my @cmd = (
        'psql',
        '-h', $ENV{MUSICBRAINZ_POSTGRES_SERVER},
        '-U', $ENV{POSTGRES_USER},
        '-d', $db_name,
        '-v', 'ON_ERROR_STOP=1',
        '-c', 'BEGIN',
    );

    push @cmd, '-c', "DELETE FROM $table" if $delete_first;
    push @cmd, '-c', qq{\\copy $table FROM $copy_source};
    push @cmd, '-c', 'COMMIT';

    my $rows = 0;
    my $t0 = [gettimeofday];

    local $ENV{PGPASSWORD} = $ENV{POSTGRES_PASSWORD};
    open my $pipe, '-|', @cmd
        or die "exec 'psql': $OS_ERROR";
    my $output = do {
        local $/;
        <$pipe> // '';
    };
    close $pipe;
    my $exit_code = $CHILD_ERROR >> 8;

    if (!$exit_code && $output =~ /COPY\s+(\d+)/) {
        $rows = $1;
    }

    my $interval = tv_interval($t0);
    printf "%-30.30s %9d %.2f sec\n", $table, $rows, $interval
        unless $quiet;

    if (!$exit_code) {
        die 'Error loading data'
            if defined $copy_file and -f $copy_file and MusicBrainz::Script::Utils::is_table_empty($sql, $table);

        remove_tree($cleanup_dir) if $cleanup_dir;

        return $rows;
    }

    warn "Error loading $file: $output";
    remove_tree($cleanup_dir) if $cleanup_dir;
    return 0 if $ignore_errors;
    exit 1;
}

INIT {
    require MusicBrainz::Script::Utils;

    _debug('INIT starting');

    my $orig = \&MusicBrainz::Script::Utils::copy_table_from_file;
    my $patched = sub {
        my ($sql, $table, $file, %opts) = @_;

        if ($opts{fix_utf8}) {
            _debug("falling back to original copy path for table=$table because fix_utf8 was requested");
            return $orig->(@_);
        }

        return _copy_table_from_file_via_psql(@_);
    };

    no warnings 'redefine';
    *MusicBrainz::Script::Utils::copy_table_from_file = $patched;
    *main::copy_table_from_file = $patched if defined &main::copy_table_from_file;

    _debug(
        'patched symbols: '
        . 'utils=' . \&MusicBrainz::Script::Utils::copy_table_from_file
        . ' main=' . (defined &main::copy_table_from_file ? \&main::copy_table_from_file : '<undef>')
    );
}

1;
