package App::SubtitleUtils;

use strict;
use warnings;

use Exporter qw(import);

# AUTHORITY
# DATE
# DIST
# VERSION

our @EXPORT_OK = qw(
                       parse_srt
                       srtcombinetext
               );

our %SPEC;

my $secs_re = qr/[+-]?\d+(?:\.\d*)?/;
my $hms_re = qr/\d\d?:\d\d?:\d\d?(?:,\d{1,3})?/;
my $hms_re_catch = qr/(\d\d?):(\d\d?):(\d\d?)(?:,(\d{1,3}))?/;

sub _hms2secs { no warnings 'uninitialized'; local $_=shift; /^$hms_re_catch$/ or return; $1*3600+$2*60+$3+$4*0.001 }
# support negative
#sub _hms2secs { no warnings 'uninitialized'; local $_=shift; /^$hms_re_catch$/ or return; "${1}1" * ($2*3600+$3*60+$4+$5*0.001) }

sub _secs2hms { no warnings 'uninitialized'; local $_=shift; /^$secs_re$/ or return "00:00:00,000"; my $ms=1000*($_-int($_)); $_=int($_); my $s=$_%60; $_-=$s; $_/=60; my $m=$_%60; $_-=$m; $_/=60; sprintf "%02d:%02d:%02d,%03d",$_,$m,$s,$ms }

$SPEC{srtparse} = {
    v => 1.1,
    summary => 'Parse SRT and return data structure',
    args => {
        filename => {
            schema => 'filename*',
            pos => 0,
        },
        string => {
            schema => 'str*',
        },
    },
    args_rels => {
        req_one => [qw/filename string/],
    },
};
sub srtparse {
    my %args = @_;

    my $parsed = {
        entries => [],
        warnings => [],
    };

    my $string = $args{string};
    unless (defined $string) {
        open my $fh, "<", $args{filename} or return [500, "Can't open file $args{filename}: $!"];
        local $/;
        $string = <$fh>;
        close $fh;
        $parsed->{_filename} = $args{filename};
    }

    my $para = "";
    my $linenum = 0;
    my @lines = split /^/m, $string;
    if ($lines[-1] =~ /\S/) {
        # add extra blank line
        push @{ $parsed->{_warnings} }, "No extra blank line at the end";
        push @lines, "\n";
    }
    for my $line (@lines) {
        $linenum++;
	if ($line =~ /\S/) {
            $line =~ s/\015//g;
            $para .= $line;
	} elsif ($para =~ /\S/) {
            my ($no, $hms1, $hms2, $text) = $para =~ /(\d+)\n($hms_re) ---?> ($hms_re)(?:\s*X1:\d+\s+X2:\d+\s+Y1:\d+\s+Y2:\d+\s*)?\n(.+)/s or
                return [500, "Invalid entry in line $linenum: $para"];
            push @{$parsed->{entries}}, {
                no => $no,
                time1 => $hms1,
                time2 => $hms2,
                _time1_as_secs => _hms2secs($hms1),
                _time2_as_secs => _hms2secs($hms2),
                text => $text,
            };
            $para = "";
	} else {
            $para = "";
	}
    }

    $parsed->{_num_entries} = @{ $parsed->{entries} };

    [200, "OK", $parsed];
}

$SPEC{srtcheck} = {
    v => 1.1,
    summary => 'Check the properness of SRT file',
    args => {
        filename => {
            schema => 'filename*',
            req => 1,
            pos => 0,
        },
    },
};
sub srtcheck {
    my %args = @_;

    my $res = srtparse(filename => $args{filename});
    return $res unless $res->[0] == 200;
    my $parsed = $res->[2];

    return [400, "Parse has warnings: ".join(", ", @{ $parsed->{_warnings} })]
        if @{ $parsed->{_warnings} };

    for my $i (0 .. $#{ $parsed->{entries} }) {
        my $entry = $parsed->{entries}[$i];
        my $num = $entry->{no};
        return [400, "Number should be ".($i+1).", not $num"]
            if $num != $i+1;
    }
    [200, "OK"];
}

$SPEC{srtdump} = {
    v => 1.1,
    args => {
        parsed => {
            schema => 'hash*',
            req => 1,
            pos => 0,
        },
    },
};
sub srtdump {
    my %args = @_;

    my $parsed = $args{parsed};

    my $text = 0;
    for my $entry (@{ $parsed->{entries} }) {
        $text .= "$entry->{no}\n$entry->{time1} --> $entry->{time2}\n$entry->{text}\n";
    }

    [200, "OK", $text];
}

$SPEC{srtcombinetext} = {
    v => 1.1,
    summary => 'Combine the text of two or more subtitle files (e.g. for different languages) into one',
    args => {
        filenames => {
            schema => ['array*', of=>'filename*', min_len=>2],
            req => 1,
            pos => 0,
            slurpy => 1,
        },
        eval => {
            summary => 'Perl code to evaluate on every text',
            schema => 'str*', # XXX or code
            cmdline_aliases => {e=>{}},
            description => <<'_',

This code will be evaluated for every text of each entry of each SRT. `$_` will
be set to the text, `$entry` to the entry hash, `$j` to the index of the files
(starts at 0).

The code is expected to modify `$_`.

_
        },
    },
    examples => [
        {
            summary => 'Display English and French subtitles together',
            src_plang => 'bash',
            src => q|[[prog]] azur-et-asmar.en.srt azur-et-asmar.fr.srt -e 'if ($main::j) { chomp; $_ = "<i></i>\n<i>$_</i>\n" }'|,
            test => 0,
            'x.doc.show_result' => 0,
        },
    ],
};
sub srtcombinetext {
    my %args = @_;

    my @parsed;
    my $filenum = 0;
    my $num_entries;
    for my $filename (@{ $args{filenames} }) {
        $filenum++;
        my $res = srtparse(filename => $filename);
        return [500, "Can't parse SRT #$filenum '$filename': $res->[0] - $res->[1]"]
            unless $res->[0] == 200;
        my $parsed = $res->[2];
        if ($filenum == 1) {
            $num_entries = @{ $parsed->{entries} };
        } elsif (@{ $parsed->{entries} } != $num_entries) {
            return [412, "SRT #$filenum '$filename' has different number of entries (".scalar(@{ $parsed->{entries} })." vs $num_entries)"];
        }
        push @parsed, $parsed;
    }

    my $code;
    my $merged = {entries=>[]};
    for my $i (0 .. $num_entries-1) {
        my ($time1, $time2, $merged_text);
        $merged_text = "";
        for my $j (0..$#parsed) {
            if ($j == 0) {
                $time1 = $parsed[$j]{entries}[$i]{time1};
                $time2 = $parsed[$j]{entries}[$i]{time2};
            } else {
                return [412, "SRT #".($j+1)." '$args{filename}[$j]' entry ".($i+1).": different timestamp"]
                    if
                    $parsed[$j]{entries}[$i]{time1} ne $time1 ||
                    $parsed[$j]{entries}[$i]{time2} ne $time2;
            }
            {
                local $_ = $parsed[$j]{entries}[$i]{text};
                if (defined $args{eval}) {
                    if (!$code) {
                        $code = eval "package main; no strict; no warnings; sub { $args{eval} }"; ## no critic: BuiltinFunctions::ProhibitStringyEval
                        return [400, "Eval code does not compile: $@"] if $@;
                    }
                    no warnings 'once';
                    local $main::entry = $parsed[$j]{entries}[$i];
                    local $main::j = $j;
                    $code->();
                }
                $merged_text .= $_;
            }
        }
        push @{ $merged->{entries} }, {
            no => $i+1,
            time1 => $time1,
            time2 => $time2,
            _time1_as_secs => _hms2secs($time1),
            _time2_as_secs => _hms2secs($time2),
            text => $merged_text,
        };
    }

    srtdump(parsed => $merged);
}

1;
#ABSTRACT: Utilities related to video subtitles

=head1 DESCRIPTION

This distributions provides the following command-line utilities:

# INSERT_EXECS_LIST


=head1 HISTORY

Most of them are scripts I first wrote in 2003 and first packaged as CPAN
distribution in late 2020. They need to be rewritten to properly use
L<Getopt::Long> etc; someday.


=head1 SEE ALSO

=cut
