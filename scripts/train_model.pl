#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use Storable;

my $data_csv = "$FindBin::Bin/../Data/lstm_dataset.csv";
my $model_path = "$FindBin::Bin/../Data/knn_model.dat";

print "Loading dataset from $data_csv...\n";

open(my $fh, '<', $data_csv) or die "Error: $!\n";
my $header = <$fh>;
chomp $header;
my @cols = split(/,/, $header);

my @feature_cols = (
    'supply_bottom_pips_60m', 'demand_top_pips_60m', 'demand_bottom_pips_60m',
    'trendline_upper_pips_60m', 'trendline_lower_pips_60m', 'channel_width_pips_60m',
    'ghost_high_pips_60m', 'ghost_low_pips_60m',
    'ob_top_pips', 'ob_bottom_pips', 'fvg_top_pips', 'fvg_bottom_pips',
    'bos_choch_pips', 'eq_level_pips', 'vwap_pips',
    'poc_pips', 'vah_pips', 'val_pips', 'atr_1m'
);

my %col_idx;
for my $i (0 .. $#cols) {
    $col_idx{$cols[$i]} = $i;
}

my @data;
my %min;
my %max;
for my $f (@feature_cols) {
    $min{$f} = 999999999;
    $max{$f} = -999999999;
}

print "Preprocessing data...\n";

while (my $line = <$fh>) {
    chomp $line;
    my @row = split(/,/, $line);
    
    # Check if target is empty
    my $target_5m = $row[$col_idx{'target_5m'}];
    next if (!defined $target_5m || $target_5m eq '');
    
    my %row_data;
    for my $f (@feature_cols) {
        my $val = $row[$col_idx{$f}];
        $val = 0 if (!defined $val || $val eq '');
        $val += 0;
        
        $row_data{$f} = $val;
        
        $min{$f} = $val if $val < $min{$f};
        $max{$f} = $val if $val > $max{$f};
    }
    $row_data{'target_5m'} = $target_5m + 0;
    
    push @data, \%row_data;
}
close($fh);

# Add a small epsilon to avoid division by zero
for my $f (@feature_cols) {
    if ($min{$f} == $max{$f}) {
        $max{$f} = $min{$f} + 1;
    }
}

print "Scaling features and saving to $model_path...\n";

my %model = (
    min => \%min,
    max => \%max,
    data => \@data,
    features => \@feature_cols
);

store(\%model, $model_path) or die "Cannot save model to $model_path!\n";

print "Training data shape: N=" . scalar(@data) . ", Features=" . scalar(@feature_cols) . "\n";
print "Process completed successfully.\n";
