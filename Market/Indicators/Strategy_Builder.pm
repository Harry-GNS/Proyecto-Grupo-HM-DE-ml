package Market::Indicators::Strategy_Builder;

use strict;
use warnings;
use POSIX qw(floor);

use Market::MarketData;

# Indicators
use Market::Indicators::ATR;
use Market::Indicators::Volume_Profile;
use Market::Indicators::Anchored_VWAP;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;

sub new {
    my ($class, %args) = @_;
    my $self = {
        md => $args{market_data},
        atr_period => $args{atr_period} || 14,
        super_mult => $args{super_mult} || 3,
        halftrend_period => $args{halftrend_period} || 8,
        range_period => $args{range_period} || 20,

        # storage
        atr => [],
        supertrend => [],
        halftrend => [],
        range_filter => [],
        fvgs => [],
        sd_zones => [],
        liquidity_levels => [],
        fibonacci_levels => [],

        indicators => {

        vp => Market::Indicators::Volume_Profile->new(
            market_data => $args{market_data}
        ),

        avwap => Market::Indicators::Anchored_VWAP->new(
            market_data => $args{market_data}
        ),

    },
    };
    bless $self, $class;
    return $self;
}

sub update_last {
    my ($self, $market_data) = @_;
    $market_data //= $self->{md};

    my $last_idx = $market_data->last_index();
    return unless defined $last_idx && $last_idx >= 0;

    # Recalculate rolling indicators for the last candle
    $self->_calc_atr($market_data, $last_idx);
    $self->_calc_supertrend($market_data, $last_idx);
    $self->_calc_halftrend($market_data, $last_idx);
    $self->_calc_range_filter($market_data, $last_idx);

    # Detect S&D zones and FVGs on close
    $self->_detect_fvg($market_data, $last_idx);
    $self->_detect_supply_demand($market_data, $last_idx);

    # Update auxiliary indicators
    $self->{vp}->update_on_new_candle($market_data, $last_idx);
    $self->{avwap}->update_on_new_candle($market_data, $last_idx);
    $self->_compute_liquidity_levels($market_data, $last_idx);
    $self->_compute_fibonacci_levels($market_data, $last_idx);
}

sub get_values {
    my ($self) = @_;
    return {
        atr => $self->{atr},
        supertrend => $self->{supertrend},
        halftrend => $self->{halftrend},
        range_filter => $self->{range_filter},
        fvgs => $self->{fvgs},
        sd_zones => $self->{sd_zones},
        liquidity_levels => $self->{liquidity_levels},
        fibonacci_levels => $self->{fibonacci_levels},
        volume_profile => $self->{vp}->export(),
        anchored_vwap => $self->{avwap}->export(),
    };
}

sub _compute_liquidity_levels {
    my ($self, $md, $idx) = @_;
    my @levels;
    # From sd_zones relevant
    for my $z (@{ $self->{sd_zones} }) {
        next unless defined $z->{price};
        if ($z->{relevant}) { push @levels, $z->{price}; }
        if ($z->{type} && $z->{type} eq 'liquidity_take') { push @levels, $z->{price}; }
    }

    # From recent wick extremes with volume spikes
    my $lookback = 50;
    my $start = $idx - $lookback; $start = 0 if $start < 0;
    my $avg_vol = _avg_volume($md, $idx, 50) || 1;
    for my $i ($start .. $idx) {
        my $c = $md->get_candle($i) or next;
        if (($c->{volume}||0) > 1.5 * $avg_vol) {
            # consider wick tips
            push @levels, $c->{high};
            push @levels, $c->{low};
        }
    }

    # deduplicate within tolerance (relative)
    my @uniq;
    LEVEL: for my $p (sort { $b <=> $a } @levels) {
        for my $q (@uniq) {
            my $tol = 0.0005 * ($p || 1);
            next LEVEL if abs($p - $q) <= $tol;
        }
        push @uniq, $p;
    }
    $self->{liquidity_levels} = [ @uniq ];
}

sub _compute_fibonacci_levels {
    my ($self, $md, $idx) = @_;
    # find last relevant supply (high) and demand (low)
    my ($last_supply) = grep { $_->{type} eq 'supply' && $_->{relevant} } reverse @{ $self->{sd_zones} };
    my ($last_demand) = grep { $_->{type} eq 'demand' && $_->{relevant} } reverse @{ $self->{sd_zones} };
    my ($high, $low);
    if ($last_supply && $last_demand) {
        $high = $last_supply->{price};
        $low  = $last_demand->{price};
    } else {
        # fallback: use highest high and lowest low in lookback
        my $lookback = 200;
        my $start = $idx - $lookback; $start = 0 if $start < 0;
        $high = -1E12; $low = 1E12;
        for my $i ($start .. $idx) {
            my $c = $md->get_candle($i) or next;
            $high = $c->{high} if $c->{high} > $high;
            $low  = $c->{low}  if $c->{low}  < $low;
        }
        return unless $high > $low;
    }

    my @ratios = (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1);
    my @levels;
    for my $r (@ratios) {
        my $p = $high - ($high - $low) * $r;
        push @levels, { ratio => $r, price => $p };
    }
    $self->{fibonacci_levels} = [ @levels ];
}

# -------------------- Indicadores --------------------
sub _calc_atr {
    my ($self, $md, $idx) = @_;
    my $p = $self->{atr_period};

    my $start = $idx - $p;
    $start = 0 if $start < 0;
    my @trs;
    for my $i ($start+1 .. $idx) {
        my $c = $md->get_candle($i);
        my $pc = $md->get_candle($i-1);
        next unless $c && $pc;
        my $tr = _true_range($c, $pc);
        push @trs, $tr;
    }

    if (@trs) {
        my $atr = 0;
        $atr += $_ for @trs;
        $atr /= scalar @trs;
        push @{ $self->{atr} }, $atr;
    } else {
        push @{ $self->{atr} }, undef;
    }
}

sub _true_range {
    my ($c, $pc) = @_;
    my $h = $c->{high};
    my $l = $c->{low};
    my $pc_close = $pc->{close};
    my $a = $h - $l;
    my $b = abs($h - $pc_close);
    my $c2 = abs($l - $pc_close);
    return ($a > $b ? $a : $b) > $c2 ? ($a > $b ? $a : $b) : $c2;
}

sub _calc_supertrend {
    my ($self, $md, $idx) = @_;
    my $atr = $self->{atr}->[-1];
    push @{ $self->{supertrend} }, undef unless defined $atr;
    return unless defined $atr;

    my $mult = $self->{super_mult};
    my $c = $md->get_candle($idx);
    my $hl2 = ($c->{high} + $c->{low})/2;
    my $upper = $hl2 + $mult * $atr;
    my $lower = $hl2 - $mult * $atr;

    # previous trend
    my $prev = $self->{supertrend}->[-1];
    my $trend = { upper => $upper, lower => $lower, dir => 'bull' };
    if ($prev && $prev->{dir} eq 'bull') {
        $trend->{upper} = $upper < $prev->{upper} ? $upper : $prev->{upper};
        $trend->{dir} = ($c->{close} < $trend->{upper}) ? 'bear' : 'bull';
    } elsif ($prev && $prev->{dir} eq 'bear') {
        $trend->{lower} = $lower > $prev->{lower} ? $lower : $prev->{lower};
        $trend->{dir} = ($c->{close} > $trend->{lower}) ? 'bull' : 'bear';
    } else {
        $trend->{dir} = ($c->{close} > $hl2) ? 'bull' : 'bear';
    }

    push @{ $self->{supertrend} }, $trend;
}

sub _calc_halftrend {
    my ($self, $md, $idx) = @_;
    my $p = $self->{halftrend_period};
    my $start = $idx - $p + 1; $start = 0 if $start < 0;
    my $sum_high = 0; my $sum_low = 0; my $n=0;
    for my $i ($start .. $idx) {
        my $c = $md->get_candle($i) or next;
        $sum_high += $c->{high};
        $sum_low  += $c->{low};
        $n++;
    }
    if ($n) {
        my $avg_h = $sum_high/$n;
        my $avg_l = $sum_low/$n;
        push @{ $self->{halftrend} }, { avg_high => $avg_h, avg_low => $avg_l };
    } else { push @{ $self->{halftrend} }, undef }
}

sub _calc_range_filter {
    my ($self, $md, $idx) = @_;
    my $p = $self->{range_period};
    my $start = $idx - $p + 1; $start = 0 if $start < 0;
    my $high = -1E12; my $low = 1E12; my $vol=0;
    for my $i ($start .. $idx) {
        my $c = $md->get_candle($i) or next;
        $high = $c->{high} if $c->{high} > $high;
        $low  = $c->{low}  if $c->{low}  < $low;
        $vol += $c->{volume} || 0;
    }
    push @{ $self->{range_filter} }, { high=>$high, low=>$low, vol=>$vol };
}

# -------------------- SMC: FVG & Supply/Demand --------------------
sub _detect_fvg {
    my ($self, $md, $idx) = @_;
    # Simplified FVG detection: three-candle gap between bodies
    return if $idx < 2;
    my $c1 = $md->get_candle($idx-2);
    my $c2 = $md->get_candle($idx-1);
    my $c3 = $md->get_candle($idx);
    return unless $c1 && $c2 && $c3;

    # Bullish FVG: middle candle high < next candle low
    if ($c2->{high} < $c3->{low}) {
        my $fvg = { type=>'bullish_fvg', start_idx=>$idx-1, top=>$c3->{low}, bottom=>$c2->{high}, mitigated_idx=>undef };
        push @{ $self->{fvgs} }, $fvg;
    }
    # Bearish FVG: middle candle low > next candle high
    if ($c2->{low} > $c3->{high}) {
        my $fvg = { type=>'bearish_fvg', start_idx=>$idx-1, top=>$c2->{low}, bottom=>$c3->{high}, mitigated_idx=>undef };
        push @{ $self->{fvgs} }, $fvg;
    }
}

sub _detect_supply_demand {
    my ($self, $md, $idx) = @_;
    # Detect swings validated by volume spikes => create SD zone
    return if $idx < 2;
    my $c_prev = $md->get_candle($idx-1) or return;
    my $c = $md->get_candle($idx) or return;
    # swing high
    if ($c_prev->{high} > $c->{high} && $c_prev->{high} > $md->get_candle($idx-2)->{high}) {
        # require volume validation: prev volume > 1.5x average of last 10
        my $avg = _avg_volume($md, $idx-1, 10);
        if (($c_prev->{volume} || 0) > 1.5 * ($avg||1)) {
            my $zone = { type=>'supply', price=>$c_prev->{high}, start_idx=>$idx-2, end_idx=>$idx, vol=>$c_prev->{volume} };
            # mark relevant if volume >> avg or aligns with recent FVG
            $zone->{relevant} = (($c_prev->{volume}||0) > 2 * ($avg||1));
            push @{ $self->{sd_zones} }, $zone;
        }
    }
    # swing low
    if ($c_prev->{low} < $c->{low} && $c_prev->{low} < $md->get_candle($idx-2)->{low}) {
        my $avg = _avg_volume($md, $idx-1, 10);
        if (($c_prev->{volume} || 0) > 1.5 * ($avg||1)) {
            my $zone = { type=>'demand', price=>$c_prev->{low}, start_idx=>$idx-2, end_idx=>$idx, vol=>$c_prev->{volume} };
            $zone->{relevant} = (($c_prev->{volume}||0) > 2 * ($avg||1));
            push @{ $self->{sd_zones} }, $zone;
        }
    }

    # Detect liquidity-taking candle: large wick beyond recent zone and volume spike
    my $avg10 = _avg_volume($md, $idx, 10);
    if (($c->{volume}||0) > 1.8*($avg10||1)) {
        # wick up or down
        my $upper_wick = $c->{high} - ($c->{close} > $c->{open} ? $c->{close} : $c->{open});
        my $lower_wick = ($c->{close} < $c->{open} ? $c->{open} : $c->{close}) - $c->{low};
        if ($upper_wick > ($c->{high}-$c->{low})*0.4 || $lower_wick > ($c->{high}-$c->{low})*0.4) {
            push @{ $self->{sd_zones} }, { type=>'liquidity_take', price=>$c->{close}, idx=>$idx, vol=>$c->{volume}, relevant=>1 };
        }
    }
}

sub _avg_volume {
    my ($md, $center_idx, $window) = @_;
    my $start = $center_idx - $window; $start = 0 if $start < 0;
    my $sum=0; my $n=0;
    for my $i ($start .. $center_idx) {
        my $c = $md->get_candle($i) or next;
        $sum += $c->{volume} || 0; $n++;
    }
    return $n ? $sum/$n : 0;
}

sub reset {
    my ($self) = @_;
    $self->{atr} = [];
    $self->{supertrend} = [];
    $self->{halftrend} = [];
    $self->{range_filter} = [];
    $self->{fvgs} = [];
    $self->{sd_zones} = [];
    $self->{vp}->reset();
    $self->{avwap}->reset();
}

1;

# -------------------- Volume Profile --------------------
package Market::Indicators::VolumeProfile;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        md => $args{market_data},
        buckets => {},
        last_profile => {},
    };
    bless $self, $class;
    return $self;
}

sub reset { my ($self) = @_; $self->{buckets} = {}; $self->{last_profile} = {}; }

sub update_on_new_candle {
    my ($self, $candle) = @_;

    return unless defined $candle;

    # actualizar bins
    # recalcular POC
    # recalcular VAH
    # recalcular VAL
}

sub compute_profile {
    my ($self, $mode, %opts) = @_;
    # mode: 'session', 'structural', 'fallback'
    my $md = $self->{md};
    my @slice = _slice_for_mode($md, $mode, %opts);
    return unless @slice;

    # horizontal buckets by price ticks (use 0.5% of price as tick by default)
    my $tick = $opts{tick} || 0.001; # relative fraction
    my %vol_by_price;
    for my $c (@slice) {
        my $v = $c->{volume} || 0;
        my $p = ($c->{high} + $c->{low} + $c->{close})/3;
        my $bucket = sprintf("%.5f", $p * (1/$tick));
        $vol_by_price{$bucket} += $v;
    }

    # find POC, VAH, VAL using simple cumulative from sorted prices
    my @pairs = map { [$_, $vol_by_price{$_}] } keys %vol_by_price;
    @pairs = sort { $b->[1] <=> $a->[1] } @pairs;
    my $poc = $pairs[0] ? $pairs[0]->[0] : undef;

    # compute VAH/VAL as price levels containing 70% of volume around POC
    my $total = 0; $total += $_->[1] for @pairs;
    my $acc = 0; my $vah = $poc; my $val = $poc;
    for my $pr (@pairs) {
        $acc += $pr->[1];
        if ($acc >= 0.15*$total && !defined $val) { $val = $pr->[0]; }
        if ($acc >= 0.85*$total) { $vah = $pr->[0]; last; }
    }

    $self->{last_profile} = { poc => $poc, vah => $vah, val => $val, total => $total };
    return $self->{last_profile};
}

sub _slice_for_mode {
    my ($md, $mode, %opts) = @_;
    my @out;
    my $arr = $md->get_slice(0, $md->last_index() || 0);
    if ($mode eq 'session') {
        # find most recent midnight timestamp and slice from there
        my $last_idx = $md->last_index() || 0;
        for my $i (reverse 0 .. $last_idx) {
            my $c = $md->get_candle($i);
            last unless $c;
            if ($c->{timestamp} =~ /T00:00:/) { @out = map { $md->get_candle($_) } ($i .. $last_idx); last; }
        }
        @out = @out ? @out : map { $md->get_candle($_) } (0 .. $last_idx);
    } elsif ($mode eq 'structural') {
        # require an anchor_idx passed in opts
        my $ai = $opts{anchor_idx} // 0;
        my $last = $md->last_index() || 0;
        @out = map { $md->get_candle($_) } ($ai .. $last);
    } else {
        # fallback: use fixed far-past window
        my $last = $md->last_index() || 0;
        my $start = $last - ($opts{window} || 5000);
        $start = 0 if $start < 0;
        @out = map { $md->get_candle($_) } ($start .. $last);
    }
    return grep { defined $_ } @out;
}

sub export { return shift->{last_profile} }

1;

# -------------------- Anchored VWAP Multi-Pivot --------------------
package Market::Indicators::AnchoredVWAP;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        md => $args{market_data},
        anchors => [], # { idx => N, label => 'session' }
        last_values => {},
    };
    bless $self, $class;
    return $self;
}

sub reset { my ($self) = @_; $self->{anchors} = []; $self->{last_values} = {}; }

sub add_anchor {
    my ($self, $idx, $label) = @_;
    push @{ $self->{anchors} }, { idx=>$idx, label=>$label };
}

sub remove_anchor_by_label {
    my ($self, $label) = @_;
    @{ $self->{anchors} } = grep { $_->{label} ne $label } @{ $self->{anchors} };
}

sub update_on_new_candle {
    my ($self, $md, $idx) = @_;
    my $last = $md->last_index();
    return unless defined $last;

    # Recompute VWAP for each anchor
    foreach my $a (@{ $self->{anchors} }) {
        my $start = $a->{idx};
        next unless defined $start && $start <= $last;
        my $num = 0; my $den = 0;
        for my $i ($start .. $last) {
            my $c = $md->get_candle($i) or next;
            my $p = ($c->{high} + $c->{low} + $c->{close})/3;
            my $v = $c->{volume} || 0;
            $num += $p * $v; $den += $v;
        }
        my $vwap = $den ? $num/$den : undef;
        $self->{last_values}->{ $a->{label} } = { vwap=>$vwap, anchor_idx=>$start };
    }
}

sub export {

    my ($self) = @_;

    return {
        bins => $self->{bins},
        poc  => $self->{poc},
        vah  => $self->{vah},
        val  => $self->{val},
    };

}
1;
