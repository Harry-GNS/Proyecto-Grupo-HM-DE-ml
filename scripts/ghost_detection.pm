package GhostDetection;

use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(detect_ghosts);

# detect_ghosts($candles_ref, $ghost_file)
# $candles_ref : arrayref of candle hashes with at least a timestamp field
# $ghost_file  : path to Ghosts_in_swings.txt (one timestamp per line)
# Returns a hash where keys are candle indices (0‑based) that contain a ghost.
sub detect_ghosts {
    my ($candles_ref, $ghost_file) = @_;
    open my $fh, '<', $ghost_file or die "Unable to open ghost file '$ghost_file': $!";
    my %ghost_ts;
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /\S/;
        $ghost_ts{$line} = 1;
    }
    close $fh;

    my %ghost_indexes;
    for my $i (0 .. $#$candles_ref) {
        my $ts = $candles_ref->[$i]{timestamp};
        if (exists $ghost_ts{$ts}) {
            $ghost_indexes{$i} = 1;
        }
    }
    return %ghost_indexes;
}

1;
