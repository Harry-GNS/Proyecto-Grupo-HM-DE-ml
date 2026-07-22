#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";

use Test::More tests => 5;
use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::InternalZigZag;
use Market::Indicators::ATR;

# Create market data with synthetic candles spanning several hours
my $market = Market::MarketData->new();

# Generate 1m candles for 4 hours (240 minutes)
my $start_ts = 1704100800; # 2024-01-01 09:30:00 UTC
my $price = 100;

for my $i (0 .. 239) {
    my $t = $start_ts + $i * 60;
    my ($sec,$min,$hour,$mday,$mon,$year) = gmtime($t);
    my $ts_str = sprintf("%04d-%02d-%02dT%02d:%02d:00-05:00", $year+1900, $mon+1, $mday, $hour, $min);
    
    # Create sine-wave pattern
    my $trend = sin($i / 10) * 5;
    my $open  = $price + $trend;
    my $high  = $open + 1 + rand(0.5);
    my $low   = $open - 1 - rand(0.5);
    my $close = $open + rand(0.5);

    $market->add_candle({
        timestamp => $ts_str,
        open      => $open,
        high      => $high,
        low       => $low,
        close     => $close,
        volume    => 1000,
    });
}

$market->build_timeframes();
ok($market->size() == 240, '1m candles loaded successfully');

my $indicators = Market::IndicatorManager->new();
$indicators->register('ATR', Market::Indicators::ATR->new(14));
$indicators->register('InternalZigZag', Market::Indicators::InternalZigZag->new(pivot_length => 3, min_leg_bars => 2));

# Test 1: Calculate on Chart TF (default)
$indicators->recalculate_all($market);
my $res_chart = $indicators->get_raw('InternalZigZag');
ok(defined $res_chart && ref($res_chart->{pivots}) eq 'ARRAY', 'InternalZigZag calculated on Chart TF');

# Test 2: Calculate on 5m TF
$indicators->set_internal_zigzag_tf('5m');
$indicators->recalculate_all($market);
my $res_5m = $indicators->get_raw('InternalZigZag');
ok(defined $res_5m && ref($res_5m->{pivots}) eq 'ARRAY', 'InternalZigZag calculated on 5m TF');

# Test 3: Calculate on 1h TF
$indicators->set_internal_zigzag_tf('1h');
$indicators->recalculate_all($market);
my $res_1h = $indicators->get_raw('InternalZigZag');
ok(defined $res_1h && ref($res_1h->{pivots}) eq 'ARRAY', 'InternalZigZag calculated on 1h TF');

# Test 4: Verify mapped indices are within 1m chart bounds
my $all_valid = 1;
for my $p (@{ $res_1h->{pivots} // [] }) {
    if ($p->{index} < 0 || $p->{index} >= $market->size()) {
        $all_valid = 0;
    }
}
ok($all_valid, 'Mapped 1h pivot indices are strictly within 1m chart bounds');
