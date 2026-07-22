package Market::Indicators::ZigZagTrend;

use strict;
use warnings;

# SPDX-License-Identifier: MPL-2.0
# Port of only the ZigZag trend/pivot detection logic from:
#   "ZigZag Volume Profile [ChartPrime]" (Pine Script v6)
# Original indicator copyright: © ChartPrime
#
# This module intentionally excludes the volume profile, POC, drawing objects,
# labels, and all TradingView rendering behavior. It keeps the streaming ZigZag
# state machine and pivot semantics, including the original repaint behavior:
# while a trend leg remains active, its endpoint is moved when a new pivot for
# that leg is confirmed.

# ============================================================
#  Market::Indicators::ZigZagTrend
#
#  Streaming macro-trend detector based on the ChartPrime ZigZag
#  logic:
#    - swingHigh/swingLow are highest/lowest over the last N bars,
#      including the current bar.
#    - isBullish becomes true when high == swingHigh.
#    - isBullish becomes false when low == swingLow.
#    - If both happen on one bar, high is evaluated first and low
#      second, so the final state is bearish.
#    - High pivots are confirmed from bar[1]. For fidelity, their
#      default price is low[1], not high[1].
#    - Low pivots are confirmed from bar[1] with price low[1].
# ============================================================

sub new {
    my ($class, %args) = @_;

    my $swing_length = $args{swingLength} // $args{swing_length} // 150;
    die 'ZigZagTrend::new: swingLength debe ser > 0'
        unless defined $swing_length && $swing_length =~ /^\d+$/ && $swing_length > 0;

    my $high_pivot_price_source =
        $args{high_pivot_price_source}
        // $args{highPivotPriceSource}
        // 'low';
    die 'ZigZagTrend::new: high_pivot_price_source debe ser low o high'
        unless $high_pivot_price_source eq 'low' || $high_pivot_price_source eq 'high';

    my $self = {
        swing_length            => $swing_length + 0,
        high_pivot_price_source => $high_pivot_price_source,

        values       => [],
        highs        => [],
        lows         => [],
        times        => [],
        swing_highs  => [],
        swing_lows   => [],
        trend_flags  => [],

        _last_high_pivot => undef,
        _last_low_pivot  => undef,
        _active_segment  => undef,

        _segments        => [],
    };

    bless $self, $class;
    return $self;
}

# --- update_last --------------------------------------------
# Input : $market -> objeto MarketData (timeframe activo)
# Output: estado de la vela procesada, o undef si ya esta al dia.
# Procesa exactamente una vela nueva por llamada.
sub update_last {
    my ($self, $market) = @_;

    my $idx = scalar @{ $self->{values} };
    return undef if $idx >= $market->size;

    my $candle = $market->get_candle($idx);
    return $self->update_candle($candle, $idx);
}

# --- update_candle ------------------------------------------
# Input : hashref OHLC[V], indice opcional
# Output: estado calculado para esa vela.
# No usa lookahead: solo consume datos hasta la vela actual.
sub update_candle {
    my ($self, $candle, $index) = @_;

    die 'ZigZagTrend::update_candle: falta candle' unless $candle;
    die 'ZigZagTrend::update_candle: candle sin high' unless defined $candle->{high};
    die 'ZigZagTrend::update_candle: candle sin low'  unless defined $candle->{low};

    my $idx = scalar @{ $self->{values} };
    $index = $idx unless defined $index;
    die 'ZigZagTrend::update_candle: indice fuera de secuencia'
        unless $index == $idx;

    my $high = $candle->{high} + 0;
    my $low  = $candle->{low}  + 0;
    my $time = $candle->{time};

    push @{ $self->{highs} }, $high;
    push @{ $self->{lows}  }, $low;
    push @{ $self->{times} }, $time;

    my $swing_high = $self->_highest_from_window($self->{highs}, $idx);
    my $swing_low  = $self->_lowest_from_window($self->{lows},  $idx);

    push @{ $self->{swing_highs} }, $swing_high;
    push @{ $self->{swing_lows}  }, $swing_low;

    my $prev_is_bullish = @{ $self->{trend_flags} }
        ? $self->{trend_flags}[-1]
        : undef;
    my $is_bullish = $prev_is_bullish;

    # Pine order is significant. If both conditions are true on the
    # same bar, the low condition runs last and leaves the trend bearish.
    $is_bullish = 1 if $high == $swing_high;
    $is_bullish = 0 if $low  == $swing_low;

    my $prev_high_price = $self->{_last_high_pivot}
        ? $self->{_last_high_pivot}{price}
        : undef;
    my $prev_low_price = $self->{_last_low_pivot}
        ? $self->{_last_low_pivot}{price}
        : undef;

    my ($high_pivot, $low_pivot);
    if ($idx >= 1) {
        if ($self->{highs}[$idx - 1] == $self->{swing_highs}[$idx - 1]
            && $high < $swing_high) {

            my $price_field = $self->{high_pivot_price_source};
            my $price = $price_field eq 'high'
                ? $self->{highs}[$idx - 1]
                : $self->{lows}[$idx - 1];

            $high_pivot = {
                kind               => 'high',
                index              => $idx - 1,
                time               => $self->{times}[$idx - 1],
                price              => $price,
                price_source       => $price_field . '[1]',
                confirmed_at       => $idx,
                confirmed_time     => $time,
                chartprime_fidelity=> $price_field eq 'low' ? 1 : 0,
            };
            $self->{_last_high_pivot} = _copy_hash($high_pivot);
        }

        if ($self->{lows}[$idx - 1] == $self->{swing_lows}[$idx - 1]
            && $low > $swing_low) {

            $low_pivot = {
                kind           => 'low',
                index          => $idx - 1,
                time           => $self->{times}[$idx - 1],
                price          => $self->{lows}[$idx - 1],
                price_source   => 'low[1]',
                confirmed_at   => $idx,
                confirmed_time => $time,
            };
            $self->{_last_low_pivot} = _copy_hash($low_pivot);
        }
    }

    push @{ $self->{trend_flags} }, $is_bullish;

    my $trend_changed =
        defined $prev_is_bullish
        && defined $is_bullish
        && $prev_is_bullish != $is_bullish
            ? 1
            : 0;

    my $completed_segment;
    if ($trend_changed) {
        $completed_segment = $self->_close_active_segment($idx, $time);
        $self->{_active_segment} = $self->_new_active_segment($is_bullish, $idx, $time);
    }

    my $high_price_changed = _value_changed(
        $prev_high_price,
        $self->{_last_high_pivot} ? $self->{_last_high_pivot}{price} : undef,
    );
    my $low_price_changed = _value_changed(
        $prev_low_price,
        $self->{_last_low_pivot} ? $self->{_last_low_pivot}{price} : undef,
    );

    if (defined $is_bullish && $is_bullish && $high_price_changed) {
        $self->_update_active_end($self->{_last_high_pivot}, $idx, $time);
    }
    elsif (defined $is_bullish && !$is_bullish && $low_price_changed) {
        $self->_update_active_end($self->{_last_low_pivot}, $idx, $time);
    }

    my $value = {
        index               => $idx,
        time                => $time,
        swing_high          => $swing_high,
        swing_low           => $swing_low,
        is_bullish          => $is_bullish,
        trend               => _trend_name($is_bullish),
        trend_changed       => $trend_changed,
        high_pivot          => _copy_hash($high_pivot),
        low_pivot           => _copy_hash($low_pivot),
        last_high_pivot     => _copy_hash($self->{_last_high_pivot}),
        last_low_pivot      => _copy_hash($self->{_last_low_pivot}),
        completed_segment   => _copy_hash($completed_segment),
        active_segment      => _copy_hash($self->{_active_segment}),
        completed_segments  => scalar @{ $self->{_segments} },
    };

    push @{ $self->{values} }, $value;
    return $value;
}

# --- compute ------------------------------------------------
# Convenience batch wrapper around the streaming API.
sub compute {
    my ($class_or_self, %args) = @_;

    my $candles = $args{candles} or die 'ZigZagTrend::compute: falta candles';
    my $max_idx = $args{max_visible_index};
    $max_idx = $#$candles unless defined $max_idx;

    my $self = ref($class_or_self)
        ? $class_or_self
        : $class_or_self->new(%args);

    if (defined $self->{_last_idx} && $max_idx < $self->{_last_idx}) {
        $self->reset;
        $self->{_last_idx} = undef;
    }

    my $start_idx = defined $self->{_last_idx} ? $self->{_last_idx} + 1 : 0;
    
    for my $i ($start_idx .. $max_idx) {
        last if $i > $#$candles;
        $self->update_candle($candles->[$i], $i);
    }
    
    $self->{_last_idx} = $max_idx;

    return {
        values          => $self->get_values,
        segments        => $self->completed_segments,
        active_segment  => $self->active_segment,
        last_high_pivot => $self->last_high_pivot,
        last_low_pivot  => $self->last_low_pivot,
        trend           => $self->current_trend,
    };
}

# --- getters -----------------------------------------------
sub get_values {
    my ($self) = @_;
    return $self->{values};
}

sub last_value {
    my ($self) = @_;
    return $self->{values}[-1];
}

sub current_trend {
    my ($self) = @_;
    my $last = $self->last_value;
    return $last ? $last->{trend} : undef;
}

sub trend { shift->current_trend(@_) }

sub last_high_pivot {
    my ($self) = @_;
    return _copy_hash($self->{_last_high_pivot});
}

sub last_low_pivot {
    my ($self) = @_;
    return _copy_hash($self->{_last_low_pivot});
}

sub active_segment {
    my ($self) = @_;
    return _copy_hash($self->{_active_segment});
}

sub completed_segments {
    my ($self) = @_;
    return [ map { _copy_hash($_) } @{ $self->{_segments} } ];
}

sub reset {
    my ($self) = @_;

    $self->{values}       = [];
    $self->{highs}        = [];
    $self->{lows}         = [];
    $self->{times}        = [];
    $self->{swing_highs}  = [];
    $self->{swing_lows}   = [];
    $self->{trend_flags}  = [];
    $self->{_segments}    = [];

    $self->{_last_high_pivot} = undef;
    $self->{_last_low_pivot}  = undef;
    $self->{_active_segment}  = undef;

    return;
}

sub _highest_from_window {
    my ($self, $series, $idx) = @_;

    my $start = $idx - $self->{swing_length} + 1;
    $start = 0 if $start < 0;

    my $max = $series->[$start];
    for my $i ($start + 1 .. $idx) {
        $max = $series->[$i] if $series->[$i] > $max;
    }
    return $max;
}

sub _lowest_from_window {
    my ($self, $series, $idx) = @_;

    my $start = $idx - $self->{swing_length} + 1;
    $start = 0 if $start < 0;

    my $min = $series->[$start];
    for my $i ($start + 1 .. $idx) {
        $min = $series->[$i] if $series->[$i] < $min;
    }
    return $min;
}

sub _new_active_segment {
    my ($self, $is_bullish, $idx, $time) = @_;

    my ($direction, $start, $end);
    if ($is_bullish) {
        $direction = 'bullish';
        $start = $self->{_last_low_pivot};
        $end   = $self->{_last_high_pivot};
    }
    else {
        $direction = 'bearish';
        $start = $self->{_last_high_pivot};
        $end   = $self->{_last_low_pivot};
    }

    return {
        direction          => $direction,
        start_kind         => $start ? $start->{kind}  : undef,
        start_index        => $start ? $start->{index} : undef,
        start_time         => $start ? $start->{time}  : undef,
        start_price        => $start ? $start->{price} : undef,
        end_kind           => $end   ? $end->{kind}    : undef,
        end_index          => $end   ? $end->{index}   : undef,
        end_time           => $end   ? $end->{time}    : undef,
        end_price          => $end   ? $end->{price}   : undef,
        created_at         => $idx,
        created_time       => $time,
        updated_at         => $idx,
        updated_time       => $time,
        repaint_updates    => 0,
        completed_at       => undef,
        completed_time     => undef,
    };
}

sub _close_active_segment {
    my ($self, $idx, $time) = @_;

    my $active = $self->{_active_segment};
    return undef unless $active;

    my $segment = _copy_hash($active);
    $segment->{completed_at}   = $idx;
    $segment->{completed_time} = $time;

    return undef
        unless defined $segment->{start_index}
        && defined $segment->{start_price}
        && defined $segment->{end_index}
        && defined $segment->{end_price};

    push @{ $self->{_segments} }, $segment;
    return _copy_hash($segment);
}

sub _update_active_end {
    my ($self, $pivot, $idx, $time) = @_;
    return unless $self->{_active_segment};
    return unless $pivot;

    my $active = $self->{_active_segment};
    my $changed =
        !defined $active->{end_index}
        || !defined $active->{end_price}
        || $active->{end_index} != $pivot->{index}
        || $active->{end_price} != $pivot->{price};

    $active->{end_kind}  = $pivot->{kind};
    $active->{end_index} = $pivot->{index};
    $active->{end_time}  = $pivot->{time};
    $active->{end_price} = $pivot->{price};
    $active->{updated_at}   = $idx;
    $active->{updated_time} = $time;
    $active->{repaint_updates} += 1 if $changed;

    return;
}

sub _trend_name {
    my ($is_bullish) = @_;
    return undef unless defined $is_bullish;
    return $is_bullish ? 'bullish' : 'bearish';
}

sub _value_changed {
    my ($old, $new) = @_;
    return 0 if !defined $old && !defined $new;
    return 1 if !defined $old || !defined $new;
    return $old != $new ? 1 : 0;
}

sub _copy_hash {
    my ($hash) = @_;
    return undef unless $hash;
    return { %$hash };
}

1;
