package Market::Indicators::InternalZigZag;

use strict;
use warnings;

# ============================================================
#  Market::Indicators::InternalZigZag
#
#  ZigZag estructural interno estilo SMC:
#    - pivotes confirmados con ventana izquierda/derecha
#    - sin lookahead: un pivot en center se confirma en center + length
#    - alternancia obligatoria HIGH -> LOW -> HIGH -> LOW
#    - si aparece un extremo mas fuerte del mismo tipo, reemplaza el
#      endpoint de la pierna actual en vez de crear micro-segmentos
#    - filtro por barras minimas y desplazamiento minimo ATR
#
#  No mezcla BOS/CHoCH/liquidez. Solo pivotes y segmentos internos.
# ============================================================

sub new {
    my ($class, %args) = @_;

    my $pivot_length = $args{pivot_length} // 5;
    my $min_leg_bars = $args{min_leg_bars} // 4;
    my $atr_multiplier = $args{atr_multiplier} // 1.0;
    my $min_price_move = $args{min_price_move} // 0;

    die 'InternalZigZag::new: pivot_length debe ser > 0'
        unless defined $pivot_length && $pivot_length =~ /^\d+$/ && $pivot_length > 0;
    die 'InternalZigZag::new: min_leg_bars debe ser >= 0'
        unless defined $min_leg_bars && $min_leg_bars =~ /^\d+$/;

    my $self = {
        pivot_length  => $pivot_length + 0,
        min_leg_bars  => $min_leg_bars + 0,
        atr_multiplier=> $atr_multiplier + 0,
        min_price_move=> $min_price_move + 0,
    };

    bless $self, $class;
    return $self;
}

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles = $args{candles} or die 'InternalZigZag::compute: falta candles';
    my $atr = $args{atr_series} // [];
    my $max_idx = $args{max_visible_index};
    $max_idx = $#$candles unless defined $max_idx;
    my $tf = $args{timeframe} // '1m';

    my $self = ref($class_or_self)
        ? $class_or_self
        : $class_or_self->new(%args);

    my @pivots;
    my $len = $self->{pivot_length};

    for my $confirm_idx (0 .. $max_idx) {
        last if $confirm_idx > $#$candles;
        my $center = $confirm_idx - $len;
        next if $center < $len;
        next if $center + $len > $max_idx;

        my ($is_high, $is_low) = $self->_confirmed_pivot_flags($candles, $center, $confirm_idx);
        next unless $is_high || $is_low;

        my @candidates = $self->_ordered_candidates(
            $candles, $atr, $center, $confirm_idx, $is_high, $is_low, \@pivots,
        );
        for my $candidate (@candidates) {
            $self->_apply_candidate(\@pivots, $candidate);
        }
    }

    my ($segments, $active_segment) = _segments_from_pivots(\@pivots);

    return {
        timeframe         => $tf,
        max_visible_index => $max_idx,
        pivot_length      => $self->{pivot_length},
        min_leg_bars      => $self->{min_leg_bars},
        atr_multiplier    => $self->{atr_multiplier},
        min_price_move    => $self->{min_price_move},
        pivots            => [ map { _copy_hash($_) } @pivots ],
        debug_pivots      => [ map { _debug_pivot($_) } @pivots ],
        segments          => $segments,
        active_segment    => $active_segment,
        trend             => $active_segment ? $active_segment->{direction} : undef,
    };
}

sub debug_pivots {
    my ($class_or_self, %args) = @_;
    my $result = $class_or_self->compute(%args);
    return $result->{debug_pivots};
}

sub _confirmed_pivot_flags {
    my ($self, $candles, $center, $confirm_idx) = @_;
    my $len = $self->{pivot_length};
    my $start = $center - $len;
    my $end = $center + $len;

    my $high = $candles->[$center]{high};
    my $low  = $candles->[$center]{low};
    my ($is_high, $is_low) = (1, 1);

    for my $i ($start .. $end) {
        next if $i == $center;

        my $h = $candles->[$i]{high};
        if ($h > $high || ($h == $high && $i > $center)) {
            $is_high = 0;
        }

        my $l = $candles->[$i]{low};
        if ($l < $low || ($l == $low && $i > $center)) {
            $is_low = 0;
        }

        last if !$is_high && !$is_low;
    }

    return ($is_high, $is_low);
}

sub _ordered_candidates {
    my ($self, $candles, $atr, $center, $confirm_idx, $is_high, $is_low, $pivots) = @_;
    my $c = $candles->[$center];
    my @out;

    my $high_candidate = $is_high ? $self->_candidate('HIGH', $candles, $atr, $center, $confirm_idx) : undef;
    my $low_candidate  = $is_low  ? $self->_candidate('LOW',  $candles, $atr, $center, $confirm_idx) : undef;

    if ($high_candidate && $low_candidate) {
        my $last_type = @$pivots ? $pivots->[-1]{type} : undef;
        if (($last_type // '') eq 'HIGH') {
            return ($low_candidate, $high_candidate);
        }
        if (($last_type // '') eq 'LOW') {
            return ($high_candidate, $low_candidate);
        }
        return (($c->{close} // 0) >= ($c->{open} // 0))
            ? ($low_candidate, $high_candidate)
            : ($high_candidate, $low_candidate);
    }

    push @out, $high_candidate if $high_candidate;
    push @out, $low_candidate  if $low_candidate;
    return @out;
}

sub _candidate {
    my ($self, $type, $candles, $atr, $center, $confirm_idx) = @_;
    my $c = $candles->[$center];
    my $confirm = $candles->[$confirm_idx];
    my $price = $type eq 'HIGH' ? $c->{high} : $c->{low};

    return {
        type           => $type,
        kind           => $type eq 'HIGH' ? 'high' : 'low',
        index          => $center,
        time           => $c->{timestamp} // $c->{time},
        price          => $price + 0,
        confirmed      => 1,
        confirmed_at   => $confirm_idx,
        confirmed_time => $confirm->{timestamp} // $confirm->{time},
        pivot_length   => $self->{pivot_length},
        atr            => defined $atr->[$center] ? $atr->[$center] + 0 : undef,
    };
}

sub _apply_candidate {
    my ($self, $pivots, $candidate) = @_;
    return unless $candidate;

    if (!@$pivots) {
        push @$pivots, $candidate;
        return;
    }

    my $last = $pivots->[-1];

    if ($candidate->{type} eq $last->{type}) {
        $pivots->[-1] = $candidate if _more_extreme($candidate, $last);
        return;
    }

    return unless $candidate->{index} > $last->{index};

    my $bars = $candidate->{index} - $last->{index};
    return if $bars < $self->{min_leg_bars};

    my $move = abs($candidate->{price} - $last->{price});
    my $min_move = $self->_min_move($candidate, $last);
    return if $move < $min_move;

    push @$pivots, $candidate;
    return;
}

sub _min_move {
    my ($self, $candidate, $last) = @_;
    my $atr_a = $candidate->{atr};
    my $atr_b = $last->{atr};
    my $atr = 0;
    if (defined $atr_a && defined $atr_b) {
        $atr = ($atr_a + $atr_b) / 2;
    }
    elsif (defined $atr_a) {
        $atr = $atr_a;
    }
    elsif (defined $atr_b) {
        $atr = $atr_b;
    }

    my $atr_move = $atr * $self->{atr_multiplier};
    my $min_move = $self->{min_price_move};
    $min_move = $atr_move if $atr_move > $min_move;
    return $min_move;
}

sub _more_extreme {
    my ($candidate, $last) = @_;
    return $candidate->{price} > $last->{price} if $candidate->{type} eq 'HIGH';
    return $candidate->{price} < $last->{price};
}

sub _segments_from_pivots {
    my ($pivots) = @_;
    my @segments;

    return ([], undef) if @$pivots < 2;

    for my $i (1 .. $#$pivots) {
        my $start = $pivots->[$i - 1];
        my $end = $pivots->[$i];
        my $seg = _segment_from_pair($start, $end);
        if ($i == $#$pivots) {
            return (\@segments, $seg);
        }
        push @segments, $seg;
    }

    return (\@segments, undef);
}

sub _segment_from_pair {
    my ($start, $end) = @_;
    my $direction = ($start->{type} eq 'LOW' && $end->{type} eq 'HIGH')
        ? 'bullish'
        : 'bearish';

    return {
        direction       => $direction,
        start_kind      => $start->{kind},
        start_index     => $start->{index},
        start_time      => $start->{time},
        start_price     => $start->{price},
        end_kind        => $end->{kind},
        end_index       => $end->{index},
        end_time        => $end->{time},
        end_price       => $end->{price},
        created_at      => $end->{confirmed_at},
        created_time    => $end->{confirmed_time},
        updated_at      => $end->{confirmed_at},
        updated_time    => $end->{confirmed_time},
        repaint_updates => 0,
        completed_at    => $end->{confirmed_at},
        completed_time  => $end->{confirmed_time},
    };
}

sub _debug_pivot {
    my ($p) = @_;
    return {
        index      => $p->{index},
        time       => $p->{time},
        type       => $p->{type},
        price      => $p->{price},
        confirmed  => $p->{confirmed} ? 1 : 0,
        confirmed_at => $p->{confirmed_at},
        confirmed_time => $p->{confirmed_time},
    };
}

sub _copy_hash {
    my ($hash) = @_;
    return { %$hash };
}

1;
