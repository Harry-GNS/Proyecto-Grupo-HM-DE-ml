package Market::Indicators::PivotMissedReversal;

use strict;
use warnings;
use utf8;

# ============================================================
#  Market::Indicators::PivotMissedReversal
#
#  Port aislado del indicador Pine:
#    "Pivot Points High Low & Missed Reversal Levels [LuxAlgo]"
#
#  Mantiene la maquina de estado secuencial del Pine:
#    max/min, max_x1/min_x1, follow_max/follow_min,
#    follow_max_x1/follow_min_x1, os, px1/py1.
#
#  No dibuja. Devuelve una estructura explicita para overlays:
#    regularPivots, missedPivots, segments, ghostLevels,
#    provisionalPivot.
# ============================================================

use constant DEFAULT_LENGTH => 10;
use constant MAX_LENGTH     => 500;

sub new {
    my ($class, %args) = @_;
    my $length = _normalize_length($args{length} // $args{pivot_length} // DEFAULT_LENGTH);

    my $self = {
        length       => $length,
        show_regular => exists $args{show_regular} ? ($args{show_regular} ? 1 : 0) : 1,
        show_missed  => exists $args{show_missed}  ? ($args{show_missed}  ? 1 : 0) : 1,
        timeframe    => $args{timeframe} // '1m',
    };
    bless $self, $class;
    $self->reset;
    return $self;
}

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles = $args{candles} or die 'PivotMissedReversal::compute: falta candles';
    my $max_idx = $args{max_visible_index};
    $max_idx = $#$candles unless defined $max_idx;
    $max_idx = $#$candles if $max_idx > $#$candles;

    my $self = ref($class_or_self)
        ? $class_or_self
        : $class_or_self->new(%args);
    $self->reset if ref($class_or_self);

    $self->{timeframe} = $args{timeframe} // $self->{timeframe} // '1m';
    $self->{show_regular} = $args{show_regular} ? 1 : 0 if exists $args{show_regular};
    $self->{show_missed}  = $args{show_missed}  ? 1 : 0 if exists $args{show_missed};
    $self->{length} = _normalize_length($args{length} // $args{pivot_length})
        if defined($args{length}) || defined($args{pivot_length});

    for my $i (0 .. $max_idx) {
        last if $i > $#$candles;
        $self->update_candle($candles->[$i], $i);
    }

    return $self->_result($max_idx);
}

sub update_last {
    my ($self, $market) = @_;
    my $idx = scalar @{ $self->{candles} };
    return undef if $idx >= $market->size;
    return $self->update_candle($market->get_candle($idx), $idx);
}

sub update_candle {
    my ($self, $candle, $index) = @_;
    die 'PivotMissedReversal::update_candle: falta candle' unless $candle;
    die 'PivotMissedReversal::update_candle: candle sin high' unless defined $candle->{high};
    die 'PivotMissedReversal::update_candle: candle sin low'  unless defined $candle->{low};

    my $idx = scalar @{ $self->{candles} };
    $index = $idx unless defined $index;
    die 'PivotMissedReversal::update_candle: indice fuera de secuencia'
        unless $index == $idx;

    push @{ $self->{candles} }, { %$candle };
    push @{ $self->{highs} }, ($candle->{high} + 0);
    push @{ $self->{lows}  }, ($candle->{low}  + 0);
    push @{ $self->{times} }, $candle->{time};

    my $value = $self->_process_bar($idx);
    push @{ $self->{values} }, $value;
    return $value;
}

sub get_values {
    my ($self) = @_;
    return $self->{values};
}

sub reset {
    my ($self) = @_;

    $self->{candles} = [];
    $self->{highs}   = [];
    $self->{lows}    = [];
    $self->{times}   = [];
    $self->{values}  = [];

    $self->{regularPivots} = [];
    $self->{missedPivots}  = [];
    $self->{segments}      = [];
    $self->{ghostLevels}   = [];
    $self->{active_ghost}  = undef;

    $self->{max} = undef;
    $self->{min} = undef;
    $self->{max_x1} = 0;
    $self->{min_x1} = 0;
    $self->{follow_max} = undef;
    $self->{follow_min} = undef;
    $self->{follow_max_x1} = 0;
    $self->{follow_min_x1} = 0;
    $self->{os}  = 0;
    $self->{px1} = undef;
    $self->{py1} = undef;
    $self->{has_confirmed_pivot} = 0;

    return;
}

sub _process_bar {
    my ($self, $n) = @_;
    my $len = $self->{length};
    my $center = $n - $len;

    my $os_prev = $self->{os};
    my ($ph, $pl);

    if ($center >= 0) {
        my $h = $self->{highs}[$center];
        my $l = $self->{lows}[$center];

        if (!defined $self->{max}) {
            $self->{max} = $h;
            $self->{max_x1} = $center;
        }
        if (!defined $self->{min}) {
            $self->{min} = $l;
            $self->{min_x1} = $center;
        }
        if (!defined $self->{follow_max}) {
            $self->{follow_max} = $h;
            $self->{follow_max_x1} = $center;
        }
        if (!defined $self->{follow_min}) {
            $self->{follow_min} = $l;
            $self->{follow_min_x1} = $center;
        }

        my $prev_max = $self->{max};
        my $prev_min = $self->{min};
        my $prev_follow_max = $self->{follow_max};
        my $prev_follow_min = $self->{follow_min};

        $self->{max} = _max($h, $self->{max});
        $self->{min} = _min($l, $self->{min});
        $self->{follow_max} = _max($h, $self->{follow_max});
        $self->{follow_min} = _min($l, $self->{follow_min});

        if ($self->{max} > $prev_max) {
            $self->{max_x1} = $center;
            $self->{follow_min} = $l;
        }
        if ($self->{min} < $prev_min) {
            $self->{min_x1} = $center;
            $self->{follow_max} = $h;
        }

        if ($self->{follow_min} < $prev_follow_min) {
            $self->{follow_min_x1} = $center;
        }
        if ($self->{follow_max} > $prev_follow_max) {
            $self->{follow_max_x1} = $center;
        }

        if ($center >= $len) {
            $ph = $self->{highs}[$center] if $self->_is_pivot_high($center);
            $pl = $self->{lows}[$center]  if $self->_is_pivot_low($center);
        }
    }

    $self->_extend_active_ghost($n);

    $self->_handle_pivot_high($n, $center, $ph, $os_prev) if defined $ph;
    $self->_handle_pivot_low ($n, $center, $pl, $os_prev) if defined $pl;

    return {
        index       => $n,
        time        => $self->{times}[$n],
        pivot_high  => defined $ph ? _clone($self->{regularPivots}[-1]) : undef,
        pivot_low   => defined $pl ? _clone($self->{regularPivots}[-1]) : undef,
        os          => $self->{os},
        px1         => $self->{px1},
        py1         => $self->{py1},
    };
}

sub _handle_pivot_high {
    my ($self, $n, $idx, $ph, $os_prev) = @_;

    if ($self->{show_missed} && $self->{has_confirmed_pivot}) {
        if ($os_prev == 1) {
            my $miss = $self->_add_missed_pivot('low', $self->{min_x1}, $self->{min}, $n, 'os_previous_high');
            $self->_add_segment($self->{px1}, $self->{py1}, $self->{min_x1}, $self->{min},
                'dashed', 'pivot_missed_reversal_missed_high', 'missed_low_after_high', $n);
            $self->{px1} = $self->{min_x1};
            $self->{py1} = $self->{min};

            $self->_close_active_ghost($self->{px1}, $n);
            $self->_start_ghost_level('low', $self->{px1}, $self->{py1}, $n);
            $miss->{ghost_level_id} = $self->{active_ghost}{id} if $miss && $self->{active_ghost};
        }
        elsif ($ph < $self->{max}) {
            my $miss_hi = $self->_add_missed_pivot('high', $self->{max_x1}, $self->{max}, $n, 'pivot_high_below_tracked_max');
            $self->_add_missed_pivot('low', $self->{follow_min_x1}, $self->{follow_min}, $n, 'follow_min_after_tracked_max');

            $self->_add_segment($self->{px1}, $self->{py1}, $self->{max_x1}, $self->{max},
                'dashed', 'pivot_missed_reversal_missed_low', 'missed_high', $n);
            $self->{px1} = $self->{max_x1};
            $self->{py1} = $self->{max};
            $self->_close_active_ghost($self->{px1}, $n);
            $self->_start_ghost_level('high', $self->{px1}, $self->{py1}, $n);
            $miss_hi->{ghost_level_id} = $self->{active_ghost}{id} if $miss_hi && $self->{active_ghost};

            $self->_add_segment($self->{px1}, $self->{py1}, $self->{follow_min_x1}, $self->{follow_min},
                'dashed', 'pivot_missed_reversal_missed_high', 'follow_min_after_missed_high', $n);
            $self->{px1} = $self->{follow_min_x1};
            $self->{py1} = $self->{follow_min};
            $self->_close_active_ghost($self->{px1}, $n);
            $self->_start_ghost_level('low', $self->{px1}, $self->{py1}, $n);
        }
    }

    if ($self->{show_regular}) {
        my $pivot = $self->_add_regular_pivot('high', $idx, $ph, $n);
        if ($self->{has_confirmed_pivot}) {
            my $style = ($ph < $self->{max} || $os_prev == 1) ? 'dashed' : 'solid';
            $self->_add_segment($self->{px1}, $self->{py1}, $idx, $ph,
                $style, 'pivot_missed_reversal_missed_low', 'regular_high', $n,
                $pivot ? $pivot->{id} : undef);
        }
    }

    $self->{py1} = $ph;
    $self->{px1} = $idx;
    $self->{os}  = 1;
    $self->{max} = $ph;
    $self->{min} = $ph;
    $self->{has_confirmed_pivot} = 1;
    return;
}

sub _handle_pivot_low {
    my ($self, $n, $idx, $pl, $os_prev) = @_;

    if ($self->{show_missed} && $self->{has_confirmed_pivot}) {
        if ($os_prev == 0) {
            my $miss = $self->_add_missed_pivot('high', $self->{max_x1}, $self->{max}, $n, 'os_previous_low');
            $self->_add_segment($self->{px1}, $self->{py1}, $self->{max_x1}, $self->{max},
                'dashed', 'pivot_missed_reversal_missed_low', 'missed_high_after_low', $n);
            $self->{px1} = $self->{max_x1};
            $self->{py1} = $self->{max};

            $self->_close_active_ghost($self->{px1}, $n);
            $self->_start_ghost_level('high', $self->{px1}, $self->{py1}, $n);
            $miss->{ghost_level_id} = $self->{active_ghost}{id} if $miss && $self->{active_ghost};
        }
        elsif ($pl > $self->{min}) {
            my $miss_hi = $self->_add_missed_pivot('high', $self->{follow_max_x1}, $self->{follow_max}, $n, 'follow_max_after_tracked_min');
            $self->_add_missed_pivot('low', $self->{min_x1}, $self->{min}, $n, 'pivot_low_above_tracked_min');

            $self->_add_segment($self->{px1}, $self->{py1}, $self->{min_x1}, $self->{min},
                'dashed', 'pivot_missed_reversal_missed_high', 'missed_low', $n);
            $self->{px1} = $self->{min_x1};
            $self->{py1} = $self->{min};
            $self->_close_active_ghost($self->{px1}, $n);
            $self->_start_ghost_level('low', $self->{px1}, $self->{py1}, $n);

            $self->_add_segment($self->{px1}, $self->{py1}, $self->{follow_max_x1}, $self->{follow_max},
                'dashed', 'pivot_missed_reversal_missed_low', 'follow_max_after_missed_low', $n);
            $self->{px1} = $self->{follow_max_x1};
            $self->{py1} = $self->{follow_max};
            $self->_close_active_ghost($self->{px1}, $n);
            $self->_start_ghost_level('high', $self->{px1}, $self->{py1}, $n);
            $miss_hi->{ghost_level_id} = $self->{active_ghost}{id} if $miss_hi && $self->{active_ghost};
        }
    }

    if ($self->{show_regular}) {
        my $pivot = $self->_add_regular_pivot('low', $idx, $pl, $n);
        if ($self->{has_confirmed_pivot}) {
            my $style = ($pl > $self->{min} || $os_prev == 0) ? 'dashed' : 'solid';
            $self->_add_segment($self->{px1}, $self->{py1}, $idx, $pl,
                $style, 'pivot_missed_reversal_missed_high', 'regular_low', $n,
                $pivot ? $pivot->{id} : undef);
        }
    }

    $self->{py1} = $pl;
    $self->{px1} = $idx;
    $self->{os}  = 0;
    $self->{max} = $pl;
    $self->{min} = $pl;
    $self->{has_confirmed_pivot} = 1;
    return;
}

sub _is_pivot_high {
    my ($self, $center) = @_;
    my $len = $self->{length};
    my $price = $self->{highs}[$center];

    for my $i (($center - $len) .. ($center + $len)) {
        next if $i == $center;
        my $h = $self->{highs}[$i];
        return 0 if $h > $price || ($h == $price && $i > $center);
    }
    return 1;
}

sub _is_pivot_low {
    my ($self, $center) = @_;
    my $len = $self->{length};
    my $price = $self->{lows}[$center];

    for my $i (($center - $len) .. ($center + $len)) {
        next if $i == $center;
        my $l = $self->{lows}[$i];
        return 0 if $l < $price || ($l == $price && $i > $center);
    }
    return 1;
}

sub _add_regular_pivot {
    my ($self, $type, $idx, $price, $confirm_idx) = @_;
    return undef unless defined $idx && defined $price;

    my $is_high = $type eq 'high';
    my $pivot = {
        id                => join('_', 'pivotMissedReversal', 'regular', $type, $idx, $confirm_idx),
        source            => 'regular',
        type              => $type,
        index             => $idx,
        time              => $self->{times}[$idx],
        pivotTime         => $self->{times}[$idx],
        pivot_time        => $self->{times}[$idx],
        confirmationIndex => $confirm_idx,
        confirmationTime  => $self->{times}[$confirm_idx],
        confirmed_at      => $confirm_idx,
        confirmed_time    => $self->{times}[$confirm_idx],
        price             => $price + 0,
        label             => $is_high ? '▼' : '▲',
        tooltip           => _fmt_price($price),
        pivot_length      => $self->{length},
        color_role        => $is_high
            ? 'pivot_missed_reversal_regular_high'
            : 'pivot_missed_reversal_regular_low',
    };
    push @{ $self->{regularPivots} }, $pivot;
    return $pivot;
}

sub _add_missed_pivot {
    my ($self, $type, $idx, $price, $confirm_idx, $reason) = @_;
    return undef unless defined $idx && defined $price;

    my $is_high = $type eq 'high';
    my $pivot = {
        id                => join('_', 'pivotMissedReversal', 'missed', $type, $idx, $confirm_idx, scalar @{ $self->{missedPivots} }),
        kind              => 'missedPivot',
        status            => 'confirmed',
        confirmed         => 1,
        eventType         => $is_high ? 'missedPivotHigh' : 'missedPivotLow',
        pivotType         => $type,
        source            => 'missed',
        type              => $type,
        index             => $idx,
        time              => $self->{times}[$idx],
        pivotTime         => $self->{times}[$idx],
        pivot_time        => $self->{times}[$idx],
        confirmationIndex => $confirm_idx,
        confirmationTime  => $self->{times}[$confirm_idx],
        confirmed_at      => $confirm_idx,
        confirmed_time    => $self->{times}[$confirm_idx],
        price             => $price + 0,
        label             => 'G',
        tooltip           => _fmt_price($price),
        pivot_length      => $self->{length},
        reason            => $reason,
        color_role        => $is_high
            ? 'pivot_missed_reversal_missed_high'
            : 'pivot_missed_reversal_missed_low',
    };
    $pivot->{missedPivotId} = $pivot->{id};
    $pivot->{event_id}      = $pivot->{id};
    push @{ $self->{missedPivots} }, $pivot;
    return $pivot;
}

sub _add_segment {
    my ($self, $from_idx, $from_price, $to_idx, $to_price, $style, $color_role, $source, $created_idx, $target_id) = @_;
    return undef unless defined $from_idx && defined $from_price && defined $to_idx && defined $to_price;
    return undef unless $from_idx >= 0 && $to_idx >= 0;

    my $seg = {
        id                => join('_', 'pivotMissedReversal', 'segment', scalar @{ $self->{segments} }, $from_idx, $to_idx, $created_idx),
        source            => $source // 'segment',
        source_id         => $target_id,
        fromIndex         => $from_idx,
        fromTime          => $self->{times}[$from_idx],
        fromPrice         => $from_price + 0,
        toIndex           => $to_idx,
        toTime            => $self->{times}[$to_idx],
        toPrice           => $to_price + 0,
        x1_index          => $from_idx,
        x2_index          => $to_idx,
        y1_price          => $from_price + 0,
        y2_price          => $to_price + 0,
        style             => $style // 'solid',
        line_style        => $style // 'solid',
        color_role        => $color_role,
        createdIndex      => $created_idx,
        createdTime       => $self->{times}[$created_idx],
        created_at        => $created_idx,
        created_time      => $self->{times}[$created_idx],
        pivot_length      => $self->{length},
    };
    push @{ $self->{segments} }, $seg;
    return $seg;
}

sub _extend_active_ghost {
    my ($self, $idx) = @_;
    my $ghost = $self->{active_ghost} or return;
    return unless $ghost->{active};
    $ghost->{endIndex} = $idx;
    $ghost->{endTime}  = $self->{times}[$idx];
    $ghost->{x2_index} = $idx;
    return;
}

sub _close_active_ghost {
    my ($self, $end_idx, $closed_by_idx) = @_;
    my $ghost = $self->{active_ghost} or return;
    return unless $ghost->{active};

    $ghost->{endIndex} = $end_idx;
    $ghost->{endTime}  = $self->{times}[$end_idx];
    $ghost->{x2_index} = $end_idx;
    $ghost->{active}   = 0;
    $ghost->{closedByIndex} = $closed_by_idx;
    $ghost->{closedByTime}  = $self->{times}[$closed_by_idx];
    return;
}

sub _start_ghost_level {
    my ($self, $type, $idx, $price, $created_idx) = @_;
    return undef unless defined $idx && defined $price;

    my $level = {
        id          => join('_', 'pivotMissedReversal', 'ghostLevel', scalar @{ $self->{ghostLevels} }, $type, $idx, $created_idx),
        source      => 'ghost_level',
        type        => $type,
        startIndex  => $idx,
        startTime   => $self->{times}[$idx],
        startPrice  => $price + 0,
        endIndex    => $created_idx,
        endTime     => $self->{times}[$created_idx],
        endPrice    => $price + 0,
        x1_index    => $idx,
        x2_index    => $created_idx,
        y1_price    => $price + 0,
        y2_price    => $price + 0,
        active      => 1,
        line_style  => 'solid',
        line_width  => 2,
        opacity     => 0.50,
        color_role  => $type eq 'high'
            ? 'pivot_missed_reversal_ghost_high'
            : 'pivot_missed_reversal_ghost_low',
        createdIndex => $created_idx,
        createdTime  => $self->{times}[$created_idx],
    };
    push @{ $self->{ghostLevels} }, $level;
    $self->{active_ghost} = $level;
    return $level;
}

sub _provisional_pivot {
    my ($self, $max_idx) = @_;
    return undef unless $self->{show_missed};
    return undef unless $self->{has_confirmed_pivot};
    return undef unless defined $max_idx && $max_idx > $self->{px1};

    my $start = $self->{px1} + 1;
    my $end   = $max_idx;
    my ($best_idx, $best_price);
    my $last_state_high = $self->{os} == 1 ? 1 : 0;

    for (my $i = $end; $i >= $start; $i--) {
        my $price = $last_state_high ? $self->{lows}[$i] : $self->{highs}[$i];
        next unless defined $price;
        if (!defined $best_price
            || ($last_state_high ? $price < $best_price : $price > $best_price)) {
            $best_idx = $i;
            $best_price = $price + 0;
        }
    }
    return undef unless defined $best_idx && defined $best_price;

    my $type = $last_state_high ? 'low' : 'high';
    my $line_role = $last_state_high
        ? 'pivot_missed_reversal_missed_high'
        : 'pivot_missed_reversal_missed_low';
    my $label_role = $type eq 'high'
        ? 'pivot_missed_reversal_missed_high'
        : 'pivot_missed_reversal_missed_low';
    my $ghost_role = $type eq 'high'
        ? 'pivot_missed_reversal_ghost_high'
        : 'pivot_missed_reversal_ghost_low';

    return {
        id                => join('_', 'pivotMissedReversal', 'provisional', $type, $best_idx, $max_idx),
        kind              => 'provisionalPivot',
        status            => 'temporary',
        confirmed         => 0,
        source            => 'provisional',
        type              => $type,
        pivotType         => $type,
        index             => $best_idx,
        time              => $self->{times}[$best_idx],
        pivotTime         => $self->{times}[$best_idx],
        pivot_time        => $self->{times}[$best_idx],
        confirmationIndex => undef,
        confirmationTime  => undef,
        price             => $best_price,
        label             => 'G',
        tooltip           => _fmt_price($best_price),
        color_role        => $label_role,
        fromIndex         => $self->{px1},
        fromTime          => $self->{times}[ $self->{px1} ],
        fromPrice         => $self->{py1} + 0,
        toIndex           => $best_idx,
        toTime            => $self->{times}[$best_idx],
        toPrice           => $best_price,
        endIndex          => $max_idx,
        endTime           => $self->{times}[$max_idx],
        segment           => {
            id         => join('_', 'pivotMissedReversal', 'provisionalSegment', $self->{px1}, $best_idx, $max_idx),
            fromIndex  => $self->{px1},
            fromTime   => $self->{times}[ $self->{px1} ],
            fromPrice  => $self->{py1} + 0,
            toIndex    => $best_idx,
            toTime     => $self->{times}[$best_idx],
            toPrice    => $best_price,
            line_style => 'dashed',
            style      => 'dashed',
            color_role => $line_role,
        },
        ghostLevel        => {
            id         => join('_', 'pivotMissedReversal', 'provisionalGhostLevel', $best_idx, $max_idx),
            type       => $type,
            startIndex => $best_idx,
            startTime  => $self->{times}[$best_idx],
            startPrice => $best_price,
            endIndex   => $max_idx,
            endTime    => $self->{times}[$max_idx],
            endPrice   => $best_price,
            line_style => 'solid',
            line_width => 2,
            opacity    => 0.50,
            color_role => $ghost_role,
        },
        pivot_length      => $self->{length},
        provisional       => 1,
        last_state        => $last_state_high ? 'high' : 'low',
    };
}

sub _result {
    my ($self, $max_idx) = @_;
    my $provisional = $self->_provisional_pivot($max_idx);

    return {
        indicator           => 'Pivot Points High Low & Missed Reversal Levels',
        namespace           => 'pivotMissedReversal',
        timeframe           => $self->{timeframe},
        max_visible_index   => $max_idx,
        pivot_length        => $self->{length},
        settings            => {
            enabled      => 1,
            pivot_length => $self->{length},
            show_regular => $self->{show_regular} ? 1 : 0,
            show_missed  => $self->{show_missed}  ? 1 : 0,
        },
        regularPivots       => _clone($self->{regularPivots}),
        missedPivots        => _clone($self->{missedPivots}),
        missedPivotEvents   => _clone($self->{missedPivots}),
        segments            => _clone($self->{segments}),
        ghostLevels         => _clone($self->{ghostLevels}),
        provisionalPivot    => _clone($provisional),
        final_state         => {
            max => $self->{max} + 0,
            min => $self->{min} + 0,
            max_x1 => $self->{max_x1},
            min_x1 => $self->{min_x1},
            follow_max => $self->{follow_max} + 0,
            follow_min => $self->{follow_min} + 0,
            follow_max_x1 => $self->{follow_max_x1},
            follow_min_x1 => $self->{follow_min_x1},
            os  => $self->{os},
            px1 => $self->{px1},
            py1 => $self->{py1} + 0,
        },
        no_lookahead        => 1,
    };
}

sub _normalize_length {
    my ($v) = @_;
    $v = DEFAULT_LENGTH unless defined $v && $v =~ /^\d+$/;
    $v = int($v);
    $v = 1 if $v < 1;
    $v = MAX_LENGTH if $v > MAX_LENGTH;
    return $v;
}

sub _max {
    my ($a, $b) = @_;
    return $a > $b ? $a : $b;
}

sub _min {
    my ($a, $b) = @_;
    return $a < $b ? $a : $b;
}

sub _fmt_price {
    my ($price) = @_;
    return undef unless defined $price;
    my $s = sprintf('%.4f', $price + 0);
    $s =~ s/0+$//;
    $s =~ s/\.$//;
    return $s;
}

sub _clone {
    my ($v) = @_;
    return undef unless defined $v;
    if (ref($v) eq 'HASH') {
        return { map { $_ => _clone($v->{$_}) } keys %$v };
    }
    if (ref($v) eq 'ARRAY') {
        return [ map { _clone($_) } @$v ];
    }
    return $v;
}

1;
