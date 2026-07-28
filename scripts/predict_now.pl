#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use Storable;

my $data_csv = "$FindBin::Bin/../Data/lstm_dataset.csv";
my $model_path = "$FindBin::Bin/../Data/knn_model.dat";

if (!-e $model_path) {
    die "Error: The model does not exist. Please run train_model.pl first.\n";
}

print "Loading model and scalers...\n";
my $model = retrieve($model_path) or die "Cannot load model from $model_path!\n";
my $min = $model->{min};
my $max = $model->{max};
my $training_data = $model->{data};
my @feature_cols = @{$model->{features}};

print "Loading latest market data from $data_csv...\n";
open(my $fh, '<', $data_csv) or die "Error: $!\n";
my $header = <$fh>;
chomp $header;
my @cols = split(/,/, $header);
my %col_idx;
for my $i (0 .. $#cols) {
    $col_idx{$cols[$i]} = $i;
}

my @rows;
while (my $line = <$fh>) {
    chomp $line;
    push @rows, [split(/,/, $line)];
}
close($fh);

if (@rows == 0) {
    die "Error: Not enough data for prediction.\n";
}

my $last_row = $rows[-1];
my %current_features;
for my $f (@feature_cols) {
    my $val = $last_row->[$col_idx{$f}];
    $val = 0 if (!defined $val || $val eq '');
    $val += 0;
    
    # Scale feature
    my $scaled = ($val - $min->{$f}) / ($max->{$f} - $min->{$f});
    $current_features{$f} = $scaled;
}

print "Predicting target_5m using K-Nearest Neighbors (K=5)...\n";

# Calculate distances
my @distances;
for my $train_row (@$training_data) {
    my $sum_sq = 0;
    for my $f (@feature_cols) {
        my $train_val = $train_row->{$f};
        my $scaled_train = ($train_val - $min->{$f}) / ($max->{$f} - $min->{$f});
        my $diff = $current_features{$f} - $scaled_train;
        $sum_sq += $diff * $diff;
    }
    push @distances, {
        distance => sqrt($sum_sq),
        target => $train_row->{target_5m}
    };
}

# Sort by distance
@distances = sort { $a->{distance} <=> $b->{distance} } @distances;

# Take top 5
my $k = 5;
my $sum_target = 0;
for my $i (0 .. $k-1) {
    last if $i >= @distances;
    $sum_target += $distances[$i]->{target};
}
my $target_value = $sum_target / $k;

my $current_close = $last_row->[$col_idx{'close'}] + 0;
my $current_time = $last_row->[$col_idx{'time'}];

print "\n=========================================\n";
print "CURRENT STATE (Time: $current_time)\n";
printf "Current Close Price: %.2f\n", $current_close;
print "=========================================\n";
print "PREDICTION (5 minutes ahead):\n";
if ($target_value > 0) {
    print "Direction: UP \xE2\xAC\x86\xEF\xB8\x8F\n";
    printf "Expected Move: +%.2f points\n", $target_value;
    printf "Projected Price: %.2f\n", $current_close + $target_value;
} else {
    print "Direction: DOWN \xE2\xAC\x87\xEF\xB8\x8F\n";
    printf "Expected Move: %.2f points\n", $target_value;
    printf "Projected Price: %.2f\n", $current_close + $target_value;
}
print "=========================================\n\n";
