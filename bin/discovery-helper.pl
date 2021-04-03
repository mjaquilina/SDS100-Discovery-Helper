#!/usr/bin/perl

use strict;
use warnings;

use DateTime;
use File::Slurp qw(write_file);
use Spreadsheet::XLSX;

my $DEBUG              = 0;
my $PATH_TO_SDS100     = '/media/sysadmin/5F2D-7E0E/BCDx36HP';

###
### REFINING CONFIGURATION
###

# If enabled, CSQ hits will be treated with the utmost suspicion. We will ignore
# CSQ hits on the same frequency as DMR, and CSQ hits on any frequency where we
# already have a PL/DPL log in the database.
my $AVOID_CSQ_HITS = 1;

###
### SPREADSHEET CONFIGURATION
### All elements are 0-indexed. This means the first workbook in the spreadsheet
### is 0, and the first column in the workbook (A) is 0.
###

my $PATH_TO_FREQ_LOG   = '/home/sysadmin/Frequency Log.xlsx';
my $PATH_TO_WRITE_FILES = '/var/www/html/bearcat/';
my $WEB_PATH_TO_BOOTSTRAP = '../../../bootstrap-5.0.0-beta3-dist';

# Worksheet number in the spreadsheet to use for frequency lookup.
my $FREQ_LOG_WORKSHEET = 1;
# Column number in the worksheet containing the frequency in MHz.
my $FREQ_LOG_FREQ_COL  = 0;
# Column number in the worskheet containing the squelch tone.
my $FREQ_LOG_TONE_COL  = 3;
# Column number in the worskheet containing the identified user.
my $FREQ_LOG_USER_COL  = 4;
# Column number in the worksheet that, if filled in, means we should always
# preserve recordings, even if the user is identified. (Useful for frequencies
# we always want to know about activity on.)
my $FREQ_LOG_REC_COL   = 6;
# Column number in the worksheet that, if filled in, means we should always
# SKIP hits on the frequency, even if the user is unidentified. (Useful for 
# frequencies we never want to know about activity on, even if we have not
# identified the user.)
my $FREQ_LOG_SKIP_COL  = 7;

# State ID to use in links to radio reference search
my $RR_STATE_ID        = 42;

### END CONFIGURATION ###

my %FREQ_DB;

run_loop();

sub run_loop
{
    #copy_files_from_scanner();
    build_local_freq_db();
    my @sessions = refine_discovery();
    build_web_pages(@sessions);
    clean_up();
}

sub clean_up
{
    system("rm -rf ./tmp/*");
}

sub build_web_pages
{
    my @sessions = @_;

    my $time = DateTime->now->strftime("%Y-%m-%d-%H:%M:%S");
    mkdir( $PATH_TO_WRITE_FILES );
    mkdir( "$PATH_TO_WRITE_FILES/DiscoverySync-$time");
    for my $session (@sessions)
    {
        my $session_path = "$PATH_TO_WRITE_FILES/DiscoverySync-$time/$session->{name}";
        mkdir($session_path);
        my($count_hits, $count_skips);
        my $hit_html = '';
        for my $hit (@{ $session->{hits} })
        {
            $count_hits++;
            unless ($hit->{skip})
            {
                $count_skips++;
                mkdir("$session_path/$hit->{directory}");
                my $mv = 'cp'; # use cp for debugging
                my $file_html = '';
                for my $file (@{ $hit->{rec_files} || [] })
                {
                    my $orig_file = "./tmp/stage/Conventional/$session->{name}/$hit->{directory}/$file";
                    # skip silent files
                    my $size = -s $orig_file;
                    if ($size > 25000) {
                        $file_html .= qq|
                            <tr>
                                <td>$file</td>
                                <td><audio controls preload="metadata"><source src="./$hit->{directory}/$file" type="audio/wav"></audio></td>
                            </tr>
                        |;
                        system(qq|$mv "$orig_file" "$session_path/$hit->{directory}/$file"|);
                    }
                }

                $hit->{tag} ||= '';
                $hit->{tone} ||= '';
                $hit->{mode} ||= '';
                $hit->{frequency} ||= '';

                $hit_html .= qq|
                    <tr>
                        <td>$hit->{frequency}</td>
                        <td>$hit->{mode}</td>
                        <td>$hit->{tone}</td>
                        <td>$hit->{tag}</td>
                        <td>
                            <a target="_blank" href="https://www.radioreference.com/apps/db/?action=isf&stid%5B%5D=$RR_STATE_ID&freq=$hit->{frequency}&coid=1">Search RR DB</a> \|
                            <a target="_blank" href="https://www.radioreference.com/apps/db/?action=sf&stid=$RR_STATE_ID&freq=$hit->{frequency}">Search FCC DB</a>
                        </td>
                    </tr>
                    <tr>
                        <td colspan=5>
                            <table class="table table-dark">
                                $file_html
                            </table>
                        </td>
                    </tr>
                |;
            }
        }

        my $retain = $count_hits - $count_skips;
        write_file("$PATH_TO_WRITE_FILES/DiscoverySync-$time/$session->{name}/index.html", qq|
                <!doctype html>
                <html lang="en">
                  <head>
                    <meta charset="utf-8">
                    <link href="$WEB_PATH_TO_BOOTSTRAP/css/bootstrap.min.css" rel="stylesheet">
                </head>
                <body>
                    <header>
                      <div class="navbar navbar-dark bg-dark shadow-sm">
                        <div class="container">
                              <a href="#" class="navbar-brand d-flex align-items-center">
                                <strong>Frequency Discovery Results</strong>
                              </a>
                        </div>
                      </div>
                    </header>
                    <main>
                      <section class="py-5 text-center container">
                        $count_hits hits recorded this session, $count_skips skipped ($retain retained)
                        <hr/>
                        <table class="table table-hover table-striped">
                            $hit_html
                        </table>

                </body>
            </html>
        |);
    }
}

sub refine_discovery
{
    my @sessions = find_sessions();
    fatal_exit("No sessions found") unless @sessions;

    my @session_data;
    for my $session (@sessions)
    {
        my @hits = find_session_hits($session);

        HIT: for my $hit (@hits)
        {
            my $with_tone = $hit->{tone}
                ? $hit->{tone} : "CSQ";

            # skip if this hit is all blank recordings (<25kb seems to be the trick)
            if ($AVOID_CSQ_HITS and !$hit->{tone})
            {
                log_msg(0, "Checking recording integrity for $hit->{frequency} CSQ");

                my $has_real_rec = 0;
                for my $file (@{ $hit->{rec_files} })
                {
                    my $size = -s "./tmp/stage/Conventional/$session/$hit->{directory}/$file";
                    if ($size > 25000) {
                        $has_real_rec = 1;
                    }
                }

                if ($has_real_rec)
                {
                    log_msg(0, "... recording integrity ok!");
                }
                else
                {
                    log_msg(0, "... skipping, no good recordings found");
                    $hit->{skip} = 1;
                    next HIT;
                }
            }

            # If this is a DMR hit, ignore any CSQ hits on the same frequency,
            # as it's probably undecoded DMR.
            if ($hit->{tone} =~ /ColorCode/ and $AVOID_CSQ_HITS)
            {
                my @csq_hits = grep {
                    $_->{tone} eq '' and
                    $_->{frequency} eq $hit->{frequency}
                } @hits;

                for (@csq_hits)
                {
                    $_->{skip} = 1;
                }
            }

            if ($hit->{skip})
            {
                log_msg(0, "... skipping $hit->{frequency} $with_tone, we have DMR traffic recorded for this frequency");
                next if $hit->{skip};
            }

            my @all_freq_matches = grep { $_->{exists} } values %{ $FREQ_DB{ $hit->{frequency} } };
            if ($FREQ_DB{ $hit->{frequency} }{ $hit->{tone} }{exists})
            {
                log_msg(0, "$hit->{frequency} $with_tone is in the frequency db");
                if ($FREQ_DB{ $hit->{frequency} }{ $hit->{tone} }{always_record})
                {
                    log_msg(0, "... set to always record in frequency db, keeping");
                    $hit->{tag} = 'always_record';
                }
                elsif ($FREQ_DB{ $hit->{frequency} }{ $hit->{tone} }{always_ignore})
                {
                    log_msg(0, "... set to always skip in frequency db, skipping");
                    $hit->{skip} = 1;
                }
                else
                {
                    if ( $FREQ_DB{ $hit->{frequency} }{ $hit->{tone} }{user} )
                    {
                        log_msg(0, "... and user is identified, skipping");
                        $hit->{skip} = 1;
                    }
                    else
                    {
                        $hit->{tag} = 'unidentified_user';
                        log_msg(0, "... but user is unidentified, keeping");
                    }
                }
            }
            elsif ($AVOID_CSQ_HITS and $hit->{tone} eq '' and @all_freq_matches)
            {
                log_msg(0, "$hit->{frequency} $with_tone is in the frequency db with a tone");
                if (grep { $_->{always_record} } @all_freq_matches)
                {
                    log_msg(0, "... but is set to always record, keeping");
                    $hit->{tag} = 'always_record';
                }
                else
                {
                    $hit->{skip} = 1;
                    log_msg(0, "... skipping");
                }
            }
            else
            {
                log_msg(0, "$hit->{frequency} $with_tone is not in the frequency db");
            }
        }

        push @session_data, {
            name => $session,
            hits => \@hits,
        };
    }

    return @session_data;
}

sub find_session_hits
{   
    my $session = shift;
    opendir( my $dh, "./tmp/stage/Conventional/$session" );
    my @files = grep { $_ ne '.' and $_ ne '..' } readdir($dh);
    closedir $dh; 

    my @hits;
    for my $file (sort @files)
    {
        $file =~ /^(\d+)_(\w+)_(\w+)$/ or next;
        my ($freq, $mode, $tone) = ($1, $2, $3);
        $tone = '' if $tone eq 'None';

        opendir( my $dh2, "./tmp/stage/Conventional/$session/$file" );
        my @rec_files = grep { $_ ne '.' and $_ ne '..' } readdir($dh2);
        closedir $dh2;

        push @hits, {
            frequency => sprintf("%.04f", $freq / 1_000_000),
            mode      => $mode,
            tone      => "$tone",
            directory => $file,
            rec_files => \@rec_files,
        };
    }

    return @hits;
}

sub find_sessions
{
    fatal_exit('No tmp files found') unless -e './tmp/stage/Conventional';
    opendir( my $dh, './tmp/stage/Conventional' );
    my @files = grep { $_ ne '.' and $_ ne '..' } readdir($dh);
    closedir $dh;
    return @files;
}

sub build_local_freq_db
{
    if (-e $PATH_TO_FREQ_LOG)
    {
        my $parser = Spreadsheet::XLSX->new($PATH_TO_FREQ_LOG);
        my @sheets = @{ $parser->{Worksheet} };
        my $sheet  = $sheets[ $FREQ_LOG_WORKSHEET ];
        $sheet->{MaxRow} ||= $sheet->{MinRow};
        my @rows;
        foreach my $row ($sheet->{MinRow} .. $sheet->{MaxRow})
        {
            $sheet->{MaxCol} ||= $sheet->{MinCol};
            my @cols;
            foreach my $col ($sheet->{MinCol}..$sheet->{MaxCol})
            {
                my $cell = $sheet -> {Cells} [$row] [$col];
                push @cols, $cell ? $cell->{Val} : undef;
            }
            push @rows, \@cols;
        }
        shift @rows;
        for my $row (@rows)
        {
            my $tone = $row->[ $FREQ_LOG_TONE_COL ] || '';
            # This should be a text field ("D123" is not a number) but sometimes
            # Excel thinks it knows better. Avoid magic floating point numbers
            # appearing out of nowhere.
            if ($tone and ($tone =~ /^(\d+)$/ or $tone =~ /^(\d+)\.(\d+)$/))
            {
                my $decimals = $2 || 0;
                $decimals =~ s/0+$//g;

                if (length($decimals) == 0 or length($decimals) > 2)
                {
                    $tone = sprintf("%.02f", $tone);
                    $tone =~ s/00$/0/g;
                }

                $tone = "$tone.0" if $tone !~ /\.(\d+)$/;
            }

            $FREQ_DB{ sprintf("%.04f", $row->[ $FREQ_LOG_FREQ_COL ]) }{ $tone || '' } = {
                user          => $row->[ $FREQ_LOG_USER_COL ] || undef,
                always_record => $row->[ $FREQ_LOG_REC_COL ]  || undef,
                always_ignore => $row->[ $FREQ_LOG_SKIP_COL ] || undef,
                exists        => 1,
                full_row      => $row,
            };
        }
    }
    else
    {
        fatal_exit("Path provided for frequency database incorrect");
    }
}

sub copy_files_from_scanner
{
    my $discovery_path = "$PATH_TO_SDS100/discovery/Conventional";
    if (-e $discovery_path)
    {
        log_msg(0, 'Creating tmp directory');
        mkdir("./tmp");
        log_msg(0, 'Creating stage directory');
        mkdir("./tmp/stage");
        log_msg(0, 'Copying files from SDS100 to local storage');
        system("cp -r $discovery_path ./tmp/stage");
    }
    else
    {
        fatal_exit("Path provided for scanner incorrect or device not connected");
    }
}

sub log_msg
{
    my ($severity, $msg) = @_;

    if ($severity == 0 and $DEBUG)
    {
        print STDERR $msg . "\n";
    }
    elsif ($severity >= 1)
    {
        print STDERR $msg . "\n";
    }
}

sub fatal_exit
{
    my ($message) = @_;
    log_msg(2, $message);
    exit;
}

