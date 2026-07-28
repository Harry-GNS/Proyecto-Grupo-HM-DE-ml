#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";

use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::Indicators::ZigZagTrend;
use Market::Indicators::InternalZigZag;
use Market::Indicators::PivotMissedReversal;
use Market::Indicators::SMC_Structures;
use Market::Indicators::Liquidity;
use Market::Indicators::Strategy_Builder;
use Market::Indicators::Anchored_VWAP;
use Market::Indicators::Volume_Profile;

my $input_file  = "$FindBin::Bin/../Data/datos.csv";
my $output_file = "$FindBin::Bin/../Data/lstm_dataset.csv";

print "Loading data from $input_file...\n";
open(my $fh_in, '<', $input_file) or die "Error: $!\n";
my $header = <$fh_in>;

my $md = Market::MarketData->new();
while (my $line = <$fh_in>) {
    chomp $line;
    next unless $line =~ /\S/;
    my ($ts, $open, $high, $low, $close, $volume) = split(/,/, $line);
    $md->add_candle({
        timestamp => $ts,
        open      => $open + 0,
        high      => $high + 0,
        low       => $low + 0,
        close     => $close + 0,
        volume    => (defined $volume ? $volume + 0 : 0),
    });
}
close($fh_in);

print "Loaded " . $md->size() . " candles.\n";

my $im = Market::IndicatorManager->new();
$im->register('ATR', Market::Indicators::ATR->new(14));
$im->register('ZigZagTrend', Market::Indicators::ZigZagTrend->new());
$im->register('PivotMissedReversal', Market::Indicators::PivotMissedReversal->new());
$im->register('SMC_Structures', Market::Indicators::SMC_Structures->new());
$im->register('Liquidity', Market::Indicators::Liquidity->new());
$im->register('Strategy_Builder', Market::Indicators::Strategy_Builder->new());
$im->register('Anchored_VWAP', Market::Indicators::Anchored_VWAP->new());
$im->register('Volume_Profile', Market::Indicators::Volume_Profile->new());

print "Computing indicators...\n";
$im->recalculate_all($md);

my $candles = $md->get_slice(0, $md->size() - 1);
my $sb_res = $im->get_raw('Strategy_Builder') || {};
my $pmr_res = $im->get_raw('PivotMissedReversal') || {};
my $smc_res = $im->get_raw('SMC_Structures') || {};
my $liq_res = $im->get_raw('Liquidity') || {};
my $vwap_res = $im->get_raw('Anchored_VWAP') || {};
my $vp_res = $im->get_raw('Volume_Profile') || {};
my $atr_res = $im->get_raw('ATR') || {};

my $supply_zones = $sb_res->{supply_zones} // [];
my $demand_zones = $sb_res->{demand_zones} // [];
my $trendlines = $sb_res->{trendlines} // [];
my $channels = $sb_res->{channels} // [];
my $ghost_levels = $pmr_res->{ghostLevels} // [];

my $obs = $smc_res->{order_blocks} // [];
my $fvgs = $smc_res->{fvgs} // [];
my $structures = $smc_res->{structures} // [];
my $eq_levels = $liq_res->{levels} // [];
my $vwap_segments = $vwap_res->{segments} // [];
my $profiles = $vp_res->{profiles} // [];
my $atr_vals = $atr_res->{values} // [];

open(my $fh_out, '>', $output_file) or die "Error: $!\n";
print $fh_out join(',',
    'index', 'time', 'close',
    'supply_bottom_pips_60m', 'demand_top_pips_60m', 'demand_bottom_pips_60m',
    'trendline_upper_pips_60m', 'trendline_lower_pips_60m', 'channel_width_pips_60m',
    'ghost_high_pips_60m', 'ghost_low_pips_60m',
    'ob_top_pips', 'ob_bottom_pips', 'fvg_top_pips', 'fvg_bottom_pips',
    'bos_choch_pips', 'eq_level_pips', 'vwap_pips',
    'poc_pips', 'vah_pips', 'val_pips', 'atr_1m',
    'target_3m', 'target_5m', 'target_10m', 'target_15m'
) . "\n";

print "Generating dataset...\n";

for my $i (0 .. $#$candles) {
    my $c = $candles->[$i];
    my $close = $c->{close};

    # Supply zones
    my $closest_supply_low = undef;
    for my $z (@$supply_zones) {
        if ($z->{confirmed_index} <= $i && (!defined $z->{end_index} || $z->{end_index} >= $i)) {
            if (!defined $closest_supply_low || $z->{low} < $closest_supply_low) {
                $closest_supply_low = $z->{low};
            }
        }
    }
    
    # Demand zones
    my $closest_demand_top = undef;
    my $closest_demand_bottom = undef;
    for my $z (@$demand_zones) {
        if ($z->{confirmed_index} <= $i && (!defined $z->{end_index} || $z->{end_index} >= $i)) {
            if (!defined $closest_demand_top || $z->{high} > $closest_demand_top) {
                $closest_demand_top = $z->{high};
                $closest_demand_bottom = $z->{low};
            }
        }
    }

    # Trendlines
    my $tl_upper = undef;
    my $tl_lower = undef;
    for my $tl (@$trendlines) {
        if (defined $tl->{confirmed_index} && $tl->{confirmed_index} <= $i && (!defined $tl->{end_index} || $tl->{end_index} >= $i)) {
            my $price = $tl->{start_price} + ($i - $tl->{start_index}) * $tl->{slope};
            if ($tl->{type} eq 'resistance' && (!defined $tl_upper || $price < $tl_upper)) {
                $tl_upper = $price;
            } elsif ($tl->{type} eq 'support' && (!defined $tl_lower || $price > $tl_lower)) {
                $tl_lower = $price;
            }
        }
    }

    # Channels
    my $ch_width = undef;
    for my $ch (@$channels) {
        if (defined $ch->{confirmed_index} && $ch->{confirmed_index} <= $i && (!defined $ch->{end_index} || $ch->{end_index} >= $i)) {
            $ch_width = $ch->{width};
        }
    }

    # Ghost levels
    my $gh_high = undef;
    my $gh_low = undef;
    for my $g (@$ghost_levels) {
        if ($g->{createdIndex} <= $i && (!defined $g->{endIndex} || $g->{endIndex} >= $i)) {
            if ($g->{type} eq 'high' && (!defined $gh_high || $g->{startPrice} < $gh_high)) {
                $gh_high = $g->{startPrice};
            } elsif ($g->{type} eq 'low' && (!defined $gh_low || $g->{startPrice} > $gh_low)) {
                $gh_low = $g->{startPrice};
            }
        }
    }

    # Order blocks
    my $ob_top = undef;
    my $ob_bottom = undef;
    for my $ob (@$obs) {
        if ($ob->{confirmed_index} <= $i && (!defined $ob->{mitigated_index} || $ob->{mitigated_index} >= $i)) {
            $ob_top = $ob->{top} if !defined $ob_top || $ob->{top} < $ob_top;
            $ob_bottom = $ob->{bottom} if !defined $ob_bottom || $ob->{bottom} > $ob_bottom;
        }
    }

    # FVG
    my $fvg_top = undef;
    my $fvg_bottom = undef;
    for my $fvg (@$fvgs) {
        if ($fvg->{start_index} <= $i && (!defined $fvg->{mitigated_index} || $fvg->{mitigated_index} >= $i)) {
            $fvg_top = $fvg->{top} if !defined $fvg_top || $fvg->{top} < $fvg_top;
            $fvg_bottom = $fvg->{bottom} if !defined $fvg_bottom || $fvg->{bottom} > $fvg_bottom;
        }
    }

    # BOS/CHOCH
    my $bos_choch = undef;
    for my $st (@$structures) {
        if ($st->{confirmed_index} <= $i && $st->{confirmed_index} > $i - 50) {
            $bos_choch = $st->{price} if !defined $bos_choch || abs($st->{price} - $close) < abs($bos_choch - $close);
        }
    }

    # EQH/EQL
    my $eq_level = undef;
    for my $eq (@$eq_levels) {
        if ($eq->{start_index} <= $i && (!defined $eq->{end_index} || $eq->{end_index} >= $i)) {
            $eq_level = $eq->{price} if !defined $eq_level || abs($eq->{price} - $close) < abs($eq_level - $close);
        }
    }

    # VWAP
    my $vwap_val = undef;
    for my $seg (@$vwap_segments) {
        if ($seg->{start_index} <= $i && (!defined $seg->{end_index} || $seg->{end_index} >= $i)) {
            my $rel_i = $i - $seg->{start_index};
            if (defined $seg->{vwap_values} && $rel_i >= 0 && $rel_i < @{$seg->{vwap_values}}) {
                $vwap_val = $seg->{vwap_values}->[$rel_i];
            }
        }
    }

    # Volume Profile (POC/VAH/VAL)
    my $poc = undef;
    my $vah = undef;
    my $val = undef;
    for my $prof (@$profiles) {
        if ($prof->{start_index} <= $i && (!defined $prof->{end_index} || $prof->{end_index} >= $i)) {
            $poc = $prof->{poc};
            $vah = $prof->{vah};
            $val = $prof->{val};
        }
    }

    # ATR
    my $atr_val = $atr_vals->[$i] // '';

    my $fmt = sub { defined $_[0] ? sprintf("%.2f", abs($_[0] - $close)) : '' };
    my $fmt_raw = sub { defined $_[0] ? sprintf("%.2f", $_[0]) : '' };
    
    # Targets
    my $t3  = ($i + 3 <= $#$candles)  ? $candles->[$i+3]->{close} - $close : '';
    my $t5  = ($i + 5 <= $#$candles)  ? $candles->[$i+5]->{close} - $close : '';
    my $t10 = ($i + 10 <= $#$candles) ? $candles->[$i+10]->{close} - $close : '';
    my $t15 = ($i + 15 <= $#$candles) ? $candles->[$i+15]->{close} - $close : '';

    print $fh_out join(',',
        $i,
        $c->{timestamp},
        $close,
        $fmt->($closest_supply_low),
        $fmt->($closest_demand_top),
        $fmt->($closest_demand_bottom),
        $fmt->($tl_upper),
        $fmt->($tl_lower),
        defined $ch_width ? sprintf("%.2f", $ch_width) : '',
        $fmt->($gh_high),
        $fmt->($gh_low),
        $fmt->($ob_top),
        $fmt->($ob_bottom),
        $fmt->($fvg_top),
        $fmt->($fvg_bottom),
        $fmt->($bos_choch),
        $fmt->($eq_level),
        $fmt->($vwap_val),
        $fmt->($poc),
        $fmt->($vah),
        $fmt->($val),
        $fmt_raw->($atr_val),
        $t3 ne '' ? sprintf("%.2f", $t3) : '',
        $t5 ne '' ? sprintf("%.2f", $t5) : '',
        $t10 ne '' ? sprintf("%.2f", $t10) : '',
        $t15 ne '' ? sprintf("%.2f", $t15) : ''
    ) . "\n";
}

close($fh_out);
print "Export complete to $output_file\n";
