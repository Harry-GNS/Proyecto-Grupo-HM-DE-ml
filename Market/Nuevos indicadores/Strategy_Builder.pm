package Market::Indicators::Strategy_Builder;

use strict;
use warnings;
use List::Util qw(max min sum);

# ============================================================
#  Market::Indicators::Strategy_Builder
#
#  Motor analitico para estrategias y contexto operativo.
#  No dibuja; entrega estructuras listas para Market::Overlays.
#
#  Implementa:
#    - SuperTrend con ATR y multiplicador configurable.
#    - HalfTrend aproximado con filtro de reversión por ATR.
#    - Range Filter con rango suavizado.
#    - Supply/Demand derivados de desplazamiento, OB o reaccion estructural.
#    - Order Blocks validados por desplazamiento fuerte y BOS/CHoCH/MSS cercano.
#    - Support/Resistance por niveles pivot de la vela cerrada previa.
#    - Trendlines y canales a partir de swings confirmados.
#    - Niveles de cuerpo/mecha de la vela diaria cerrada previa.
#
#  Regla Replay:
#    Ningun calculo usa velas con index > max_visible_index.
# ============================================================

use constant ST_MULT          => 3.0;
use constant HT_AMP           => 6;
use constant HT_ATR_MULT      => 1.4;
use constant RF_PERIOD        => 14;
use constant RF_MULT          => 2.5;
use constant VOL_WIN          => 20;
use constant ZONE_LOOKBACK    => 8;
use constant ZONE_MIN_VOL     => 1.15;
use constant ZONE_MIN_BODY    => 0.55;
use constant ZONE_ATR_FACTOR  => 1.05;
use constant SR_MAX_PIVOTS    => 180;
use constant SR_MIN_TOUCHES   => 2;
use constant TL_MAX_LINES     => 28;

my %TREND_CHANNEL_CONFIG = (
    pivot_left                    => 3,
    pivot_right                   => 3,
    minimum_duration_minutes      => 60,
    minimum_candles               => 8,
    atr_period                    => 14,
    contact_tolerance_atr         => 0.15,
    breakout_tolerance_atr        => 0.25,
    strong_breakout_tolerance_atr => 0.40,
    contact_merge_bars            => 3,
    contact_merge_minutes         => 10,
    minimum_main_line_touches     => 2,
    minimum_opposite_line_touches => 2,
    minimum_total_touches         => 4,
    minimum_containment_ratio     => 0.85,
    minimum_width_atr             => 0.75,
    maximum_width_atr             => 8.0,
    minimum_directional_move_atr  => 0.50,
    maximum_pivot_lookback        => 20,
    candidate_score_threshold     => 0.55,
    minimum_visible_score         => 0.70,
    strong_channel_score          => 0.85,
    max_visible_channels          => 3,
);

my $NEXT_ID = 1;
sub _new_id { return 'STG_' . sprintf('%04d', $NEXT_ID++) }

sub new  { bless {}, shift }
sub reset { $NEXT_ID = 1 }
sub get_values { [] }

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles    = $args{candles}           or die 'Strategy_Builder::compute: falta candles';
    my $atr_series = $args{atr_series}        // [];
    my $max_idx    = $args{max_visible_index} // $#$candles;
    my $tf         = $args{timeframe}         // '1m';
    my $liq_lvls   = $args{liquidity_levels}  // [];
    my $liq_evts   = $args{liquidity_events}  // [];
    my $structs    = $args{structure_events}  // [];
    my $pivots     = $args{pivots}            // [];
    my $daily      = $args{daily_candles}     // [];

    $NEXT_ID = 1;
    $max_idx = $#$candles if $max_idx > $#$candles;
    return _empty_result() if $max_idx < 1;
    return _empty_result() unless _candles_have_required_ohlcv($candles, $max_idx);

    my $vol_avg = _volume_average($candles, $max_idx);

    my $supertrend   = _build_supertrend($candles, $atr_series, $max_idx, $tf);
    my $halftrend    = _build_halftrend($candles, $atr_series, $max_idx, $tf);
    my $range_filter = _build_range_filter($candles, $max_idx, $tf);
    my ($supply, $demand, $order_blocks) =
        _build_zones($candles, $atr_series, $vol_avg, $liq_evts, $structs, $max_idx, $tf);
    my $support_resistance =
        _build_support_resistance($pivots, $candles, $atr_series, $max_idx, $tf);
    my ($trendlines, $channels) =
        _build_trendlines_and_channels($pivots, $candles, $atr_series, $max_idx, $tf);
    my $daily_levels =
        _build_daily_levels($candles, $daily, $atr_series, $max_idx, $tf);

    return {
        supertrend          => $supertrend,
        halftrend           => $halftrend,
        range_filter        => $range_filter,
        supply_zones        => $supply,
        demand_zones        => $demand,
        order_blocks        => $order_blocks,
        support_resistance  => $support_resistance,
        trendlines          => $trendlines,
        channels            => $channels,
        daily_levels        => $daily_levels,
        liquidity_links     => _strategy_liquidity_links($liq_lvls, $liq_evts, $max_idx),
    };
}

sub _empty_result {
    return {
        supertrend         => [],
        halftrend          => [],
        range_filter       => [],
        supply_zones       => [],
        demand_zones       => [],
        order_blocks       => [],
        support_resistance => [],
        trendlines         => [],
        channels           => [],
        daily_levels       => [],
        liquidity_links    => [],
    };
}

sub _candles_have_required_ohlcv {
    my ($candles, $max_idx) = @_;
    return 0 unless $candles && @$candles;
    $max_idx = $#$candles if !defined($max_idx) || $max_idx > $#$candles;
    for my $i (0 .. $max_idx) {
        my $c = $candles->[$i] or return 0;
        for my $field (qw(open high low close volume)) {
            return 0 unless _finite_number($c->{$field});
        }
        return 0 if ($c->{high} + 0) < ($c->{low} + 0);
    }
    return 1;
}

sub _build_supertrend {
    my ($candles, $atr_series, $max_idx, $tf) = @_;
    my @out;
    my ($final_upper, $final_lower, $dir);

    for my $i (0 .. $max_idx) {
        my $c = $candles->[$i];
        my $atr = _atr_at($atr_series, $candles, $i);
        my $hl2 = ($c->{high} + $c->{low}) / 2;
        my $basic_upper = $hl2 + ST_MULT * $atr;
        my $basic_lower = $hl2 - ST_MULT * $atr;

        if ($i == 0) {
            $final_upper = $basic_upper;
            $final_lower = $basic_lower;
            $dir = 'bullish';
        }
        else {
            my $prev_close = $candles->[$i - 1]{close};
            $final_upper = ($basic_upper < $final_upper || $prev_close > $final_upper)
                ? $basic_upper : $final_upper;
            $final_lower = ($basic_lower > $final_lower || $prev_close < $final_lower)
                ? $basic_lower : $final_lower;

            if ($dir eq 'bearish' && $c->{close} > $final_upper) {
                $dir = 'bullish';
            }
            elsif ($dir eq 'bullish' && $c->{close} < $final_lower) {
                $dir = 'bearish';
            }
        }

        push @out, {
            id         => _new_id(),
            index      => $i,
            time       => $c->{time},
            timeframe  => $tf,
            direction  => $dir,
            value      => $dir eq 'bullish' ? $final_lower : $final_upper,
            upper_band => $final_upper,
            lower_band => $final_lower,
            atr        => $atr,
        };
    }

    return \@out;
}

sub _build_halftrend {
    my ($candles, $atr_series, $max_idx, $tf) = @_;
    my @out;
    my $dir = $candles->[1]{close} >= $candles->[0]{close} ? 'bullish' : 'bearish';
    my $trend_value = $candles->[0]{close};

    for my $i (0 .. $max_idx) {
        my $from = $i - HT_AMP + 1;
        $from = 0 if $from < 0;
        my ($hi, $lo) = _high_low($candles, $from, $i);
        my $atr = _atr_at($atr_series, $candles, $i);
        my $dev = $atr * HT_ATR_MULT;
        my $close = $candles->[$i]{close};

        if ($dir eq 'bullish') {
            $trend_value = max($trend_value, $lo);
            if ($close < $trend_value - $dev) {
                $dir = 'bearish';
                $trend_value = $hi;
            }
        }
        else {
            $trend_value = min($trend_value, $hi);
            if ($close > $trend_value + $dev) {
                $dir = 'bullish';
                $trend_value = $lo;
            }
        }

        push @out, {
            id        => _new_id(),
            index     => $i,
            time      => $candles->[$i]{time},
            timeframe => $tf,
            direction => $dir,
            value     => $trend_value,
            high_ref  => $hi,
            low_ref   => $lo,
            atr       => $atr,
        };
    }

    return \@out;
}

sub _build_range_filter {
    my ($candles, $max_idx, $tf) = @_;
    my @out;
    my $alpha = 2 / (RF_PERIOD + 1);
    my $smooth_range = 0;
    my $filter = $candles->[0]{close};
    my $dir = 'neutral';

    for my $i (0 .. $max_idx) {
        my $close = $candles->[$i]{close};
        my $prev_close = $i > 0 ? $candles->[$i - 1]{close} : $close;
        my $abs_move = abs($close - $prev_close);
        $smooth_range = $i == 0 ? $abs_move : ($smooth_range + $alpha * ($abs_move - $smooth_range));
        my $range = $smooth_range * RF_MULT;

        if ($close > $filter + $range) {
            $filter = $close - $range;
            $dir = 'bullish';
        }
        elsif ($close < $filter - $range) {
            $filter = $close + $range;
            $dir = 'bearish';
        }

        push @out, {
            id        => _new_id(),
            index     => $i,
            time      => $candles->[$i]{time},
            timeframe => $tf,
            direction => $dir,
            value     => $filter,
            range     => $range,
        };
    }

    return \@out;
}

sub _build_zones {
    my ($candles, $atr_series, $vol_avg, $liq_evts, $structs, $max_idx, $tf) = @_;
    my (@supply, @demand, @obs);
    my %seen_ob;

    for my $i (1 .. $max_idx) {
        my $c = $candles->[$i];
        my $range = $c->{high} - $c->{low};
        next unless $range > 0;
        my $body = abs($c->{close} - $c->{open});
        my $atr = _atr_at($atr_series, $candles, $i);
        my $vol_ratio = ($vol_avg->[$i] || 1) > 0 ? ($c->{volume} // 0) / ($vol_avg->[$i] || 1) : 0;

        next unless $body / $range >= ZONE_MIN_BODY;
        next unless $range >= $atr * ZONE_ATR_FACTOR;
        next unless $vol_ratio >= ZONE_MIN_VOL;

        my $bullish_impulse = $c->{close} > $c->{open};
        my $j = _last_opposite_candle($candles, $i - 1, $bullish_impulse);
        next unless defined $j;

        my $base = $candles->[$j];
        my $zone_type = $bullish_impulse ? 'demand' : 'supply';
        my ($low, $high) = _zone_bounds($base, $zone_type);
        my $resolved = _resolve_zone($candles, $i + 1, $max_idx, $zone_type, $low, $high);
        my $liq_link = _near_event($liq_evts, $i, 6);
        my @valid_structs = grep {
            (($_->{type} // '') eq 'BOS')
                || (($_->{type} // '') eq 'CHOCH')
                || (($_->{type} // '') eq 'MSS')
        } _near_structures($structs, $i, 5);
        my $struct_link = @valid_structs ? $valid_structs[-1] : undef;
        my $derived_from = @valid_structs ? 'order_block'
                         : $liq_link     ? 'liquidity_reaction'
                         :                 'displacement';

        my $zone = {
            id                    => _new_id(),
            type                  => $zone_type,
            timeframe             => $tf,
            start_index           => $j,
            start_time            => $base->{time},
            confirmed_index       => $i,
            confirmed_time        => $c->{time},
            end_index             => $resolved->{end_index},
            end_time              => $resolved->{end_time},
            low                   => $low,
            high                  => $high,
            active                => $resolved->{active},
            status                => $resolved->{status},
            displacement_index    => $i,
            displacement_time     => $c->{time},
            displacement_range    => $range,
            volume_ratio          => sprintf('%.3f', $vol_ratio) + 0,
            liquidity_context_id  => $liq_link ? $liq_link->{id} : undef,
            structure_context_id  => $struct_link ? $struct_link->{id} : undef,
            structure_context_type=> $struct_link ? $struct_link->{type} : undef,
            derived_from          => $derived_from,
        };

        if ($zone_type eq 'demand') { push @demand, $zone }
        else                        { push @supply, $zone }

        if (@valid_structs) {
            my %struct_by_scope;
            for my $st (@valid_structs) {
                my $scope = ($st->{scope} // 'external') eq 'internal' ? 'internal' : 'external';
                $struct_by_scope{$scope} = $st;
            }

            my $ob_side = $bullish_impulse ? 'bullish' : 'bearish';
            for my $scope (grep { exists $struct_by_scope{$_} } qw(external internal)) {
                my $scope_struct = $struct_by_scope{$scope};
                my $ob_key = join('|', $scope, $ob_side, $j, $low, $high);
                next if $seen_ob{$ob_key}++;

                my $ob_resolved = _resolve_order_block(
                    $candles, $i + 1, $max_idx, $zone_type, $low, $high,
                );
                push @obs, {
                    %$zone,
                    id        => _new_id(),
                    type      => $bullish_impulse ? 'bullish_ob' : 'bearish_ob',
                    ob_side   => $ob_side,
                    ob_scope  => $scope,
                    structure_scope => $scope,
                    structure_context_id   => $scope_struct->{id},
                    structure_context_type => $scope_struct->{type},
                    active    => $ob_resolved->{active},
                    status    => $ob_resolved->{status},
                    end_index => $ob_resolved->{end_index},
                    end_time  => $ob_resolved->{end_time},
                    validation => {
                        displacement       => 1,
                        volume_ratio       => sprintf('%.3f', $vol_ratio) + 0,
                        structure_event_id => $scope_struct->{id},
                        structure_type     => $scope_struct->{type},
                        structure_scope    => $scope,
                    },
                };
            }
        }
    }

    return (\@supply, \@demand, \@obs);
}

sub _build_support_resistance {
    my ($pivots, $candles, $atr_series, $max_idx, $tf) = @_;
    my @out;
    return \@out unless $candles && @$candles && $max_idx >= 1;

    for my $i (1 .. $max_idx) {
        my $prev = $candles->[$i - 1];
        my $cur  = $candles->[$i];
        next unless $prev && $cur;

        for my $lv (_pivot_levels_traditional($prev)) {
            my ($name, $type, $price) = @$lv;
            push @out, {
                id                    => _new_id(),
                kind                  => 'pivot_level',
                type                  => $type,
                label                 => $name,
                method                => 'Traditional',
                timeframe             => $tf,
                price                 => $price,
                source_index          => $i - 1,
                source_time           => $prev->{time},
                source_open           => $prev->{open},
                source_high           => $prev->{high},
                source_low            => $prev->{low},
                source_close          => $prev->{close},
                first_index           => $i,
                first_time            => $cur->{time},
                start_index           => $i,
                start_time            => $cur->{time},
                last_index            => $i,
                last_time             => $cur->{time},
                end_index             => $i + 1,
                end_time              => _add_minutes_iso($cur->{time}, _tf_minutes($tf)),
                active                => 1,
                touches               => 1,
                pivot_ids             => [],
                allow_right_projection=> 1,
            };
        }
    }

    return \@out;
}

sub _pivot_levels_traditional {
    my ($c) = @_;
    return () unless $c;
    my $h = $c->{high};
    my $l = $c->{low};
    my $close = $c->{close};
    return () unless defined $h && defined $l && defined $close;

    my $p  = ($h + $l + $close) / 3;
    my $r1 = 2 * $p - $l;
    my $s1 = 2 * $p - $h;
    my $r2 = $p + ($h - $l);
    my $s2 = $p - ($h - $l);

    return (
        ['P',  'pivot',      $p],
        ['R1', 'resistance', $r1],
        ['S1', 'support',    $s1],
        ['R2', 'resistance', $r2],
        ['S2', 'support',    $s2],
    );
}

sub _build_trendlines_and_channels {
    my ($pivots, $candles, $atr_series, $max_idx, $tf) = @_;
    my (@lines, @legacy_channels);

    if ($pivots && @$pivots) {
        my @highs = grep { $_->{kind} eq 'high' && ($_->{confirmed_at} // 9_999_999) <= $max_idx } @$pivots;
        my @lows  = grep { $_->{kind} eq 'low'  && ($_->{confirmed_at} // 9_999_999) <= $max_idx } @$pivots;

        _append_trendlines(\@lines, \@legacy_channels, \@highs, \@lows,  $candles, $max_idx, $tf, 'resistance');
        _append_trendlines(\@lines, \@legacy_channels, \@lows,  \@highs, $candles, $max_idx, $tf, 'support');

        @lines = @lines > TL_MAX_LINES ? @lines[-TL_MAX_LINES .. -1] : @lines;
    }

    my $channels = _detect_auto_trend_channels($pivots, $candles, $atr_series, $max_idx, $tf);
    return (\@lines, $channels);
}

sub _detect_auto_trend_channel {
    my ($pivots, $candles, $atr_series, $max_idx, $tf) = @_;
    my $channels = _detect_auto_trend_channels($pivots, $candles, $atr_series, $max_idx, $tf);
    return $channels && @$channels ? $channels->[0] : undef;
}

sub _detect_auto_trend_channels {
    my ($pivots, $candles, $atr_series, $max_idx, $tf) = @_;
    my $cfg = \%TREND_CHANNEL_CONFIG;
    return [] unless $candles && @$candles && $max_idx >= 2;

    my $series = _channel_candle_series($candles, $max_idx, $tf);
    return [] unless $series && @$series >= $cfg->{minimum_candles};

    my @pivots = (
        _normalize_provided_channel_pivots($pivots, $series, $max_idx, $tf),
        _find_confirmed_channel_pivots($series, $cfg),
    );
    @pivots = _dedupe_channel_pivots(\@pivots);
    return [] unless @pivots >= 3;

    my @highs = grep { ($_->{kind} // '') eq 'high' } @pivots;
    my @lows  = grep { ($_->{kind} // '') eq 'low'  } @pivots;
    return [] unless @highs && @lows;

    my @candidates;

    push @candidates, @{
        _channel_candidates_for_side(
            'bullish', 'low', \@lows, \@highs, $series, $atr_series, $tf, $cfg,
        )
    };
    push @candidates, @{
        _channel_candidates_for_side(
            'bearish', 'high', \@highs, \@lows, $series, $atr_series, $tf, $cfg,
        )
    };

    return [] unless @candidates;
    @candidates = sort {
        ($b->{score} // 0) <=> ($a->{score} // 0)
            || ($b->{end_index} // 0) <=> ($a->{end_index} // 0)
            || ($b->{source_b_confirmed_at} // 0) <=> ($a->{source_b_confirmed_at} // 0)
            || ($a->{start_index} // 0) <=> ($b->{start_index} // 0)
    } @candidates;

    my @deduped = _dedupe_channel_candidates(\@candidates, $cfg);
    $#deduped = $cfg->{max_visible_channels} - 1
        if @deduped > $cfg->{max_visible_channels};
    return \@deduped;
}

sub _channel_candle_series {
    my ($candles, $max_idx, $tf) = @_;
    $max_idx = $#$candles if !defined($max_idx) || $max_idx > $#$candles;
    return undef if $max_idx < 0;

    my @series;
    my %seen_time;
    my $prev_time_ms;

    for my $i (0 .. $max_idx) {
        my $c = $candles->[$i];
        return undef unless $c;
        for my $field (qw(open high low close volume)) {
            return undef unless _finite_number($c->{$field});
        }
        return undef if ($c->{high} + 0) < ($c->{low} + 0);

        my $time_ms = _normalize_channel_time_ms($c->{time}, $i, $tf);
        return undef unless defined $time_ms;
        return undef if $seen_time{$time_ms}++;
        return undef if defined($prev_time_ms) && $time_ms <= $prev_time_ms;
        $prev_time_ms = $time_ms;

        push @series, {
            %$c,
            index   => $i,
            time_ms => $time_ms,
            open    => $c->{open} + 0,
            high    => $c->{high} + 0,
            low     => $c->{low} + 0,
            close   => $c->{close} + 0,
            volume  => $c->{volume} + 0,
        };
    }

    return \@series;
}

sub _find_confirmed_channel_pivots {
    my ($series, $cfg) = @_;
    my $left  = $cfg->{pivot_left};
    my $right = $cfg->{pivot_right};
    my $last  = $#$series;
    my @pivots;

    return @pivots if $last < $left + $right;

    for my $i ($left .. $last - $right) {
        my $cur = $series->[$i];
        my ($is_high, $is_low) = (1, 1);

        for my $j (1 .. $left) {
            $is_high = 0 unless $cur->{high} > $series->[$i - $j]{high};
            $is_low  = 0 unless $cur->{low}  < $series->[$i - $j]{low};
        }
        for my $j (1 .. $right) {
            $is_high = 0 unless $cur->{high} > $series->[$i + $j]{high};
            $is_low  = 0 unless $cur->{low}  < $series->[$i + $j]{low};
        }

        my $confirmed_at = $i + $right;
        if ($is_high) {
            push @pivots, _channel_pivot('high', $cur, $series->[$confirmed_at], $i, $confirmed_at);
        }
        if ($is_low) {
            push @pivots, _channel_pivot('low', $cur, $series->[$confirmed_at], $i, $confirmed_at);
        }
    }

    return sort {
        ($a->{index} // 0) <=> ($b->{index} // 0)
            || ($a->{kind} cmp $b->{kind})
    } @pivots;
}

sub _channel_pivot {
    my ($kind, $candle, $confirm, $idx, $confirmed_at) = @_;
    my $price = $kind eq 'high' ? $candle->{high} : $candle->{low};
    return {
        id             => join('_', 'TC', uc($kind), $idx, $confirmed_at),
        kind           => $kind,
        type           => $kind,
        index          => $idx,
        candleIndex    => $idx,
        time           => $candle->{time},
        time_ms        => $candle->{time_ms},
        price          => $price + 0,
        confirmed      => 1,
        confirmed_at   => $confirmed_at,
        confirmed_time => $confirm->{time},
        source_logic   => 'trend_channel_pivot_3_3',
    };
}

sub _normalize_provided_channel_pivots {
    my ($pivots, $series, $max_idx, $tf) = @_;
    return () unless $pivots && ref($pivots) eq 'ARRAY' && @$pivots;

    my @out;
    for my $p (@$pivots) {
        next unless $p && ref($p) eq 'HASH';
        my $kind = $p->{kind} // $p->{type} // '';
        next unless $kind eq 'high' || $kind eq 'low';
        next unless defined $p->{index} && _finite_number($p->{price});
        my $idx = int($p->{index});
        next if $idx < 0 || $idx > $#$series;
        my $confirmed_at = defined $p->{confirmed_at} ? int($p->{confirmed_at}) : $idx;
        next if $confirmed_at > $max_idx || $confirmed_at > $#$series;
        next if exists $p->{confirmed} && !$p->{confirmed};

        my $time_ms = defined $p->{time_ms}
            ? _normalize_channel_time_ms($p->{time_ms}, $idx, $tf)
            : _normalize_channel_time_ms($p->{time} // $series->[$idx]{time}, $idx, $tf);
        $time_ms //= $series->[$idx]{time_ms};
        next unless defined $time_ms;

        push @out, {
            id             => $p->{id} // join('_', 'TC_SRC', uc($kind), $idx, $confirmed_at),
            kind           => $kind,
            type           => $kind,
            index          => $idx,
            candleIndex    => $idx,
            time           => $p->{time} // $series->[$idx]{time},
            time_ms        => $time_ms,
            price          => $p->{price} + 0,
            confirmed      => 1,
            confirmed_at   => $confirmed_at,
            confirmed_time => $p->{confirmed_time} // $series->[$confirmed_at]{time},
            source_logic   => $p->{source_logic} // 'provided_confirmed_pivot',
            scope          => $p->{scope},
            label          => $p->{label},
            swing_label_valid => $p->{swing_label_valid},
        };
    }
    return @out;
}

sub _dedupe_channel_pivots {
    my ($pivots) = @_;
    my (%seen, @out);
    for my $p (sort {
        ($a->{index} // 0) <=> ($b->{index} // 0)
            || (($a->{kind} // '') cmp ($b->{kind} // ''))
            || (_channel_pivot_source_rank($a) <=> _channel_pivot_source_rank($b))
    } @$pivots) {
        my $key = join(':', $p->{kind} // '', $p->{index} // '', sprintf('%.8f', $p->{price} // 0));
        next if $seen{$key}++;
        push @out, $p;
    }
    return @out;
}

sub _channel_pivot_source_rank {
    my ($p) = @_;
    return (($p->{source_logic} // '') eq 'provided_confirmed_pivot') ? 0 : 1;
}

sub _channel_candidates_for_side {
    my ($direction, $base_kind, $base_pts, $opposite_pts, $series, $atr_series, $tf, $cfg) = @_;
    return [] unless $base_pts && @$base_pts >= 2 && $opposite_pts && @$opposite_pts;

    my @base = @$base_pts;
    @base = @base > $cfg->{maximum_pivot_lookback}
        ? @base[-$cfg->{maximum_pivot_lookback} .. -1]
        : @base;

    my @out;
    my $max_idx = $#$series;

    for my $i (0 .. $#base - 1) {
        for my $j ($i + 1 .. $#base) {
            my $a = $base[$i];
            my $b = $base[$j];
            next unless _channel_pivot_ready($a) && _channel_pivot_ready($b);
            next if $b->{time_ms} <= $a->{time_ms};

            my $directional_move = ($b->{price} // 0) - ($a->{price} // 0);
            next if $direction eq 'bullish' && $directional_move <= 0;
            next if $direction eq 'bearish' && $directional_move >= 0;

            my $anchor_atr = _avg_atr_between_indices($atr_series, $series, $a->{index}, $b->{index});
            next if $anchor_atr > 0
                && abs($directional_move) < $anchor_atr * $cfg->{minimum_directional_move_atr};

            my $dt = $b->{time_ms} - $a->{time_ms};
            next unless $dt > 0;
            my $slope_time  = $directional_move / $dt;
            my $slope_index = $directional_move / max(1, $b->{index} - $a->{index});

            my $line = {
                type          => $base_kind eq 'low' ? 'support' : 'resistance',
                base_kind     => $base_kind,
                start_index   => $a->{index},
                start_time_ms => $a->{time_ms},
                y1            => $a->{price} + 0,
                slope_time    => $slope_time,
                slope_index   => $slope_index,
            };

            my $offsets = _channel_offset_candidates(
                $line, $opposite_pts, $series, $atr_series, $a->{index}, $max_idx, $base_kind, $cfg,
            );
            for my $offset_info (@$offsets) {
                my $channel = _evaluate_channel_candidate(
                    line        => $line,
                    offset      => $offset_info->{offset},
                    a           => $a,
                    b           => $b,
                    opposite    => $offset_info->{pivot},
                    series      => $series,
                    atr_series  => $atr_series,
                    direction   => $direction,
                    base_kind   => $base_kind,
                    timeframe   => $tf,
                    config      => $cfg,
                );
                push @out, $channel if $channel;
            }
        }
    }

    return \@out;
}

sub _channel_pivot_ready {
    my ($p) = @_;
    return $p
        && defined $p->{index}
        && defined $p->{time_ms}
        && _finite_number($p->{price})
        && ($p->{confirmed} ? 1 : 0);
}

sub _channel_offset_candidates {
    my ($line, $opposite_pts, $series, $atr_series, $start, $end, $base_kind, $cfg) = @_;
    my @out;

    for my $p (@$opposite_pts) {
        next unless _channel_pivot_ready($p);
        next unless $p->{index} >= $start && $p->{index} <= $end;

        my $off = ($p->{price} // 0) - _line_price_at_time($line, $p->{time_ms});
        next if $base_kind eq 'low'  && $off <= 0;
        next if $base_kind eq 'high' && $off >= 0;

        my $width = abs($off);
        my $atr = _avg_atr_between_indices($atr_series, $series, $start, $p->{index});
        next unless $atr > 0;
        my $width_in_atr = $width / $atr;
        next if $width_in_atr < $cfg->{minimum_width_atr};
        next if $width_in_atr > $cfg->{maximum_width_atr};

        push @out, {
            pivot        => $p,
            offset       => $off,
            width        => $width,
            width_in_atr => $width_in_atr,
        };
    }

    @out = sort {
        abs(($a->{width_in_atr} // 0) - 2.5) <=> abs(($b->{width_in_atr} // 0) - 2.5)
            || ($a->{pivot}{index} // 0) <=> ($b->{pivot}{index} // 0)
    } @out;

    return \@out;
}

sub _evaluate_channel_candidate {
    my (%args) = @_;
    my $line       = $args{line};
    my $offset     = $args{offset};
    my $a          = $args{a};
    my $b          = $args{b};
    my $opposite   = $args{opposite};
    my $series     = $args{series};
    my $atr_series = $args{atr_series};
    my $direction  = $args{direction};
    my $base_kind  = $args{base_kind};
    my $tf         = $args{timeframe};
    my $cfg        = $args{config};
    return undef unless $line && $series && @$series && _channel_pivot_ready($opposite);

    my $start_index = $a->{index};
    my $max_idx = $#$series;
    my $confirmed_at = max($a->{confirmed_at} // $a->{index}, $b->{confirmed_at} // $b->{index}, $opposite->{confirmed_at} // $opposite->{index});
    my $last_anchor = max($b->{index}, $opposite->{index});

    my $pre_break = _channel_break_info($line, $offset, $series, $atr_series, $start_index + 1, $confirmed_at, $cfg);
    return undef if $pre_break && $pre_break->{index} < $last_anchor;

    my $break = _channel_break_info($line, $offset, $series, $atr_series, $confirmed_at + 1, $max_idx, $cfg);
    my $end_index = $break ? $break->{index} : $max_idx;
    return undef if $end_index < $last_anchor;

    my $duration_ms = $series->[$end_index]{time_ms} - $series->[$start_index]{time_ms};
    return undef if $duration_ms < $cfg->{minimum_duration_minutes} * 60_000;

    my $candle_count = $end_index - $start_index + 1;
    return undef if $candle_count < $cfg->{minimum_candles};

    my $atr = _avg_atr_between_indices($atr_series, $series, $start_index, $end_index);
    return undef unless $atr > 0;
    my $width = abs($offset);
    my $width_in_atr = $width / $atr;
    return undef if $width_in_atr < $cfg->{minimum_width_atr};
    return undef if $width_in_atr > $cfg->{maximum_width_atr};

    my $touches = _channel_touch_summary($line, $offset, $series, $atr_series, $start_index, $end_index, $cfg);
    my $main_touches = $base_kind eq 'low' ? $touches->{lower_count} : $touches->{upper_count};
    my $opposite_touches = $base_kind eq 'low' ? $touches->{upper_count} : $touches->{lower_count};
    my $total_touches = $touches->{lower_count} + $touches->{upper_count};
    return undef if $main_touches < $cfg->{minimum_main_line_touches};
    return undef if $opposite_touches < $cfg->{minimum_opposite_line_touches};
    return undef if $total_touches < $cfg->{minimum_total_touches};

    my $containment = _channel_containment_ratio($line, $offset, $series, $atr_series, $start_index, $end_index, $cfg);
    return undef if $containment < $cfg->{minimum_containment_ratio};

    my $structure_score = _channel_structure_score($touches, $direction);
    my $score = _channel_candidate_score(
        touches      => $touches,
        containment  => $containment,
        structure    => $structure_score,
        duration_ms  => $duration_ms,
        width_in_atr => $width_in_atr,
        config       => $cfg,
    );
    return undef if $score < $cfg->{candidate_score_threshold};
    return undef if $score < $cfg->{minimum_visible_score};

    return _make_trend_channel(
        line        => $line,
        offset      => $offset,
        a           => $a,
        b           => $b,
        opposite    => $opposite,
        series      => $series,
        end_index   => $end_index,
        direction   => $direction,
        base_kind   => $base_kind,
        timeframe   => $tf,
        break       => $break,
        atr         => $atr,
        touches     => $touches,
        containment => $containment,
        width_in_atr=> $width_in_atr,
        score       => $score,
        duration_ms => $duration_ms,
        confirmed_at=> $confirmed_at,
        config      => $cfg,
    );
}

sub _make_trend_channel {
    my (%args) = @_;
    my $line      = $args{line};
    my $offset    = $args{offset};
    my $a         = $args{a};
    my $b         = $args{b};
    my $opposite  = $args{opposite};
    my $series    = $args{series};
    my $end_index = $args{end_index};
    my $direction = $args{direction};
    my $base_kind = $args{base_kind};
    my $tf        = $args{timeframe};
    my $break     = $args{break};
    my $cfg       = $args{config};
    return undef unless $series->[$line->{start_index}] && $series->[$end_index];

    my ($lower_start, $upper_start) = _channel_bounds_at_time($line, $offset, $series->[$line->{start_index}]{time_ms});
    my ($lower_end,   $upper_end)   = _channel_bounds_at_time($line, $offset, $series->[$end_index]{time_ms});
    my $width = abs($upper_start - $lower_start);
    return undef unless $width > 0;

    my $source_id = join(':',
        'auto_trend_channel',
        $direction,
        $base_kind,
        $a->{index} // 'NA',
        $b->{index} // 'NA',
        $opposite->{index} // 'NA',
    );

    my $status = $break ? 'broken' : 'confirmed';
    my $score = sprintf('%.4f', $args{score}) + 0;
    my $strength = $score >= $cfg->{strong_channel_score} ? 'strong' : 'valid';

    return {
        id                    => _new_id(),
        source_id             => $source_id,
        type                  => 'trend_channel',
        timeframe             => $tf,
        direction             => $direction,
        base_kind             => $base_kind,
        start_index           => $line->{start_index},
        start_time            => $series->[$line->{start_index}]{time},
        end_index             => $end_index,
        end_time              => $series->[$end_index]{time},
        lower_y1              => $lower_start,
        lower_y2              => $lower_end,
        upper_y1              => $upper_start,
        upper_y2              => $upper_end,
        center_y1             => ($lower_start + $upper_start) / 2,
        center_y2             => ($lower_end + $upper_end) / 2,
        y1                    => $lower_start,
        y2                    => $lower_end,
        slope                 => $line->{slope_time},
        slope_per_index       => $line->{slope_index},
        width                 => $width,
        offset                => $upper_start - $lower_start,
        upper_offset          => $base_kind eq 'low'  ? $width : 0,
        lower_offset          => $base_kind eq 'high' ? -$width : 0,
        source_a_index        => $a->{index},
        source_a_time         => $a->{time},
        source_a_price        => $a->{price},
        source_a_pivot_id     => $a->{id},
        source_b_index        => $b->{index},
        source_b_time         => $b->{time},
        source_b_price        => $b->{price},
        source_b_pivot_id     => $b->{id},
        source_b_confirmed_at => $b->{confirmed_at} // $b->{index},
        opposite_index        => $opposite->{index},
        opposite_time         => $opposite->{time},
        opposite_price        => $opposite->{price},
        opposite_pivot_id     => $opposite->{id},
        anchor1               => _channel_anchor_payload($a),
        anchor2               => _channel_anchor_payload($b),
        opposite_anchor       => _channel_anchor_payload($opposite),
        break_index           => $break ? $break->{index} : undef,
        break_time            => $break ? $series->[$break->{index}]{time} : undef,
        breakout_time         => $break ? $series->[$break->{index}]{time} : undef,
        breakout_direction    => $break ? $break->{direction} : undef,
        active                => $break ? 0 : 1,
        status                => $status,
        automatic             => 1,
        editable              => 1,
        locked                => 0,
        selected              => 0,
        min_duration_minutes  => $cfg->{minimum_duration_minutes},
        duration_minutes      => sprintf('%.2f', $args{duration_ms} / 60_000) + 0,
        duration_ms           => $args{duration_ms} + 0,
        upper_touches         => $args{touches}{upper_count},
        lower_touches         => $args{touches}{lower_count},
        total_touches         => $args{touches}{upper_count} + $args{touches}{lower_count},
        containment_ratio     => sprintf('%.4f', $args{containment}) + 0,
        width_in_atr          => sprintf('%.4f', $args{width_in_atr}) + 0,
        atr                   => sprintf('%.6f', $args{atr}) + 0,
        score                 => $score,
        strength              => $strength,
        confirmed_at          => $args{confirmed_at},
        confirmed_time        => $series->[$args{confirmed_at}]{time},
        detection_config      => {
            pivot_left                => $cfg->{pivot_left},
            pivot_right               => $cfg->{pivot_right},
            minimum_duration_minutes  => $cfg->{minimum_duration_minutes},
            minimum_containment_ratio => $cfg->{minimum_containment_ratio},
            minimum_visible_score     => $cfg->{minimum_visible_score},
        },
    };
}

sub _channel_anchor_payload {
    my ($p) = @_;
    return {
        time        => $p->{time},
        time_ms     => $p->{time_ms},
        price       => $p->{price} + 0,
        pivot_id    => $p->{id},
        index       => $p->{index},
        candleIndex => $p->{index},
        confirmed   => 1,
        confirmed_at=> $p->{confirmed_at},
    };
}

sub _channel_touch_summary {
    my ($line, $offset, $series, $atr_series, $start, $end, $cfg) = @_;
    my (@upper, @lower);

    for my $i ($start .. $end) {
        my $c = $series->[$i];
        my ($lo, $hi) = _channel_bounds_at_time($line, $offset, $c->{time_ms});
        my $tol = _channel_contact_tolerance($atr_series, $series, $i, $cfg);
        push @upper, { index => $i, time_ms => $c->{time_ms}, price => $c->{high} }
            if abs($c->{high} - $hi) <= $tol;
        push @lower, { index => $i, time_ms => $c->{time_ms}, price => $c->{low} }
            if abs($c->{low} - $lo) <= $tol;
    }

    @upper = _merge_channel_contacts(\@upper, $cfg);
    @lower = _merge_channel_contacts(\@lower, $cfg);

    return {
        upper       => \@upper,
        lower       => \@lower,
        upper_count => scalar @upper,
        lower_count => scalar @lower,
        distribution=> _channel_contact_distribution(\@upper, \@lower, $start, $end),
    };
}

sub _merge_channel_contacts {
    my ($contacts, $cfg) = @_;
    my @sorted = sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @$contacts;
    my @merged;
    for my $c (@sorted) {
        if (!@merged) {
            push @merged, { %$c };
            next;
        }
        my $last = $merged[-1];
        my $bar_gap = ($c->{index} // 0) - ($last->{index} // 0);
        my $minute_gap = (($c->{time_ms} // 0) - ($last->{time_ms} // 0)) / 60_000;
        if ($bar_gap < $cfg->{contact_merge_bars} || $minute_gap < $cfg->{contact_merge_minutes}) {
            $last->{index} = $c->{index};
            $last->{time_ms} = $c->{time_ms};
            $last->{price} = $c->{price};
        }
        else {
            push @merged, { %$c };
        }
    }
    return @merged;
}

sub _channel_contact_distribution {
    my ($upper, $lower, $start, $end) = @_;
    my @all = sort { ($a->{index} // 0) <=> ($b->{index} // 0) } (@$upper, @$lower);
    return 0 unless @all >= 2 && $end > $start;
    my $spread = (($all[-1]{index} // $start) - ($all[0]{index} // $start)) / ($end - $start);
    return max(0, min(1, $spread / 0.55));
}

sub _channel_containment_ratio {
    my ($line, $offset, $series, $atr_series, $start, $end, $cfg) = @_;
    my ($inside, $total) = (0, 0);
    for my $i ($start .. $end) {
        my $c = $series->[$i];
        my ($lo, $hi) = _channel_bounds_at_time($line, $offset, $c->{time_ms});
        my $tol = _channel_contact_tolerance($atr_series, $series, $i, $cfg);
        $inside++ if $c->{close} >= $lo - $tol && $c->{close} <= $hi + $tol;
        $total++;
    }
    return $total ? $inside / $total : 0;
}

sub _channel_break_info {
    my ($line, $offset, $series, $atr_series, $from, $to, $cfg) = @_;
    $from = 0 if !defined($from) || $from < 0;
    $to = $#$series if !defined($to) || $to > $#$series;
    return undef if $from > $to;

    my ($last_dir, $run) = ('', 0);
    for my $i ($from .. $to) {
        my $c = $series->[$i];
        my ($lo, $hi) = _channel_bounds_at_time($line, $offset, $c->{time_ms});
        my $atr = _atr_at($atr_series, $series, $i);
        next unless $atr > 0;
        my $break_tol = $atr * $cfg->{breakout_tolerance_atr};
        my $strong_tol = $atr * $cfg->{strong_breakout_tolerance_atr};
        my $dir = '';
        my $strong = 0;
        if ($c->{close} > $hi + $break_tol) {
            $dir = 'up';
            $strong = 1 if $c->{close} > $hi + $strong_tol;
        }
        elsif ($c->{close} < $lo - $break_tol) {
            $dir = 'down';
            $strong = 1 if $c->{close} < $lo - $strong_tol;
        }

        if ($strong) {
            return { index => $i, direction => $dir, mode => 'strong_close' };
        }
        if ($dir ne '') {
            $run = $dir eq $last_dir ? $run + 1 : 1;
            $last_dir = $dir;
            return { index => $i, direction => $dir, mode => 'two_closes' } if $run >= 2;
        }
        else {
            ($last_dir, $run) = ('', 0);
        }
    }
    return undef;
}

sub _channel_candidate_score {
    my (%args) = @_;
    my $cfg = $args{config};
    my $touches = $args{touches};
    my $total = ($touches->{upper_count} // 0) + ($touches->{lower_count} // 0);
    my $touch_quantity = min(1, (
        min(1, ($touches->{upper_count} // 0) / $cfg->{minimum_opposite_line_touches}) +
        min(1, ($touches->{lower_count} // 0) / $cfg->{minimum_main_line_touches}) +
        min(1, $total / $cfg->{minimum_total_touches})
    ) / 3);
    my $touch_score = $touch_quantity * (0.70 + 0.30 * ($touches->{distribution} // 0));
    my $containment_score = max(0, min(1, $args{containment} // 0));
    my $structure_score = max(0, min(1, $args{structure} // 0));
    my $duration_score = 0.70 + 0.30 * min(1,
        max(0, (($args{duration_ms} // 0) / 60_000) - $cfg->{minimum_duration_minutes})
            / max(1, $cfg->{minimum_duration_minutes} * 2)
    );
    my $width_mid = ($cfg->{minimum_width_atr} + $cfg->{maximum_width_atr}) / 2;
    my $width_span = max(1e-9, ($cfg->{maximum_width_atr} - $cfg->{minimum_width_atr}) / 2);
    my $pivot_quality = 1 - min(1, abs(($args{width_in_atr} // $width_mid) - $width_mid) / $width_span);
    $pivot_quality = 0.55 + 0.45 * $pivot_quality;

    return $touch_score * 0.30
        + $containment_score * 0.25
        + $structure_score * 0.20
        + $duration_score * 0.15
        + $pivot_quality * 0.10;
}

sub _channel_structure_score {
    my ($touches, $direction) = @_;
    my $rising = $direction eq 'bullish' ? 1 : 0;
    my $low_score = _monotonic_price_score($touches->{lower}, $rising);
    my $high_score = _monotonic_price_score($touches->{upper}, $rising);
    return ($low_score + $high_score) / 2;
}

sub _monotonic_price_score {
    my ($points, $rising) = @_;
    return 0.65 unless $points && @$points >= 2;
    my ($ok, $steps) = (0, 0);
    for my $i (1 .. $#$points) {
        $steps++;
        if ($rising) { $ok++ if ($points->[$i]{price} // 0) >= ($points->[$i - 1]{price} // 0) }
        else         { $ok++ if ($points->[$i]{price} // 0) <= ($points->[$i - 1]{price} // 0) }
    }
    return $steps ? $ok / $steps : 0.65;
}

sub _dedupe_channel_candidates {
    my ($candidates, $cfg) = @_;
    my @out;
    for my $ch (@$candidates) {
        next if grep { _channels_are_duplicate($_, $ch) } @out;
        push @out, $ch;
    }
    return @out;
}

sub _channels_are_duplicate {
    my ($a, $b) = @_;
    return 0 unless ($a->{direction} // '') eq ($b->{direction} // '');
    my $start = max($a->{start_index} // 0, $b->{start_index} // 0);
    my $end   = min($a->{end_index} // 0,   $b->{end_index} // 0);
    return 0 if $end <= $start;
    my $span_a = max(1, ($a->{end_index} // 0) - ($a->{start_index} // 0));
    my $span_b = max(1, ($b->{end_index} // 0) - ($b->{start_index} // 0));
    my $overlap = ($end - $start) / min($span_a, $span_b);
    return 0 if $overlap < 0.70;
    return 1 if ($a->{source_a_index} // -1) == ($b->{source_a_index} // -2)
        && $overlap >= 0.50;

    my $slope_a = $a->{slope_per_index} // 0;
    my $slope_b = $b->{slope_per_index} // 0;
    my $slope_den = max(1e-9, abs($slope_a), abs($slope_b));
    return 0 if abs($slope_a - $slope_b) / $slope_den > 0.18;

    my $width_den = max(1e-9, $a->{width} // 0, $b->{width} // 0);
    return 0 if abs(($a->{width} // 0) - ($b->{width} // 0)) / $width_den > 0.30;
    return 1;
}

sub _channel_bounds_at_time {
    my ($line, $offset, $time_ms) = @_;
    my $base = _line_price_at_time($line, $time_ms);
    my $other = $base + $offset;
    return $base <= $other ? ($base, $other) : ($other, $base);
}

sub _line_price_at_time {
    my ($line, $time_ms) = @_;
    return undef unless $line && defined $time_ms;
    return ($line->{y1} // 0) + (($line->{slope_time} // 0) * ($time_ms - ($line->{start_time_ms} // $time_ms)));
}

sub _channel_contact_tolerance {
    my ($atr_series, $series, $idx, $cfg) = @_;
    my $atr = _atr_at($atr_series, $series, $idx);
    return ($atr && $atr > 0) ? $atr * $cfg->{contact_tolerance_atr} : 0.01;
}

sub _avg_atr_between_indices {
    my ($atr_series, $series, $from, $to) = @_;
    $from = 0 if !defined($from) || $from < 0;
    $to = $#$series if !defined($to) || $to > $#$series;
    return 0 if $from > $to;
    my ($sum, $cnt) = (0, 0);
    for my $i ($from .. $to) {
        my $atr = _atr_at($atr_series, $series, $i);
        next unless defined $atr && $atr > 0;
        $sum += $atr;
        $cnt++;
    }
    return $cnt ? $sum / $cnt : 0;
}

sub _normalize_channel_time_ms {
    my ($value, $idx, $tf) = @_;
    return undef unless defined $value;
    if (!ref($value) && $value =~ /\A[+-]?\d+(?:\.\d+)?\z/) {
        my $n = $value + 0;
        return abs($n) < 100_000_000_000 ? int($n * 1000) : int($n);
    }
    return _iso_to_epoch_ms($value) if !ref($value);
    return undef;
}

sub _iso_to_epoch_ms {
    my ($iso) = @_;
    return undef unless defined $iso;
    return undef unless $iso =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?(Z|([+-])(\d{2}):?(\d{2}))?/;
    require Time::Local;
    my ($Y, $Mo, $D, $h, $mi, $s, $tz, $sign, $oh, $om) =
        ($1 + 0, $2 + 0, $3 + 0, $4 + 0, $5 + 0, ($6 // 0) + 0, $7, $8, $9, $10);
    my $epoch = Time::Local::timegm($s, $mi, $h, $D, $Mo - 1, $Y - 1900);
    if (defined $tz && $tz ne '' && $tz ne 'Z') {
        my $offset = (($oh // 0) * 60 + ($om // 0)) * 60;
        $offset *= -1 if ($sign // '+') eq '-';
        $epoch -= $offset;
    }
    return $epoch * 1000;
}

sub _finite_number {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v);
    return 0 unless "$v" =~ /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/;
    my $n = $v + 0;
    return 0 if $n != $n;
    return 0 if $n > 1e308 || $n < -1e308;
    return 1;
}

sub _append_trendlines {
    my ($lines, $channels, $pts, $opposite_pts, $candles, $max_idx, $tf, $line_type) = @_;
    return unless $pts && @$pts >= 2;

    for my $i (1 .. $#$pts) {
        my $a = $pts->[$i - 1];
        my $b = $pts->[$i];
        next if $b->{index} <= $a->{index};

        my $slope = ($b->{price} - $a->{price}) / ($b->{index} - $a->{index});
        my $y2 = $a->{price} + $slope * ($max_idx - $a->{index});
        my $dir = $slope >= 0 ? 'bullish' : 'bearish';

        my $line = {
            id          => _new_id(),
            type        => $line_type,
            timeframe   => $tf,
            start_index => $a->{index},
            start_time  => $a->{time},
            end_index   => $max_idx,
            end_time    => $candles->[$max_idx]{time},
            anchor_a_id => $a->{id},
            anchor_b_id => $b->{id},
            y1          => $a->{price},
            y2          => $y2,
            slope       => $slope,
            direction   => $dir,
        };
        push @$lines, $line;

        my $parallel = _parallel_channel($line, $opposite_pts, $candles, $max_idx);
        push @$channels, $parallel if $parallel;
    }
}

sub _parallel_channel {
    my ($line, $pts, $candles, $max_idx) = @_;
    my ($best_off, $best_abs);
    my $line_kind = $line->{type};

    for my $p (@$pts) {
        next if $p->{index} < $line->{start_index};
        my $y = _line_y_at($line, $p->{index});
        my $off = $p->{price} - $y;
        next if $line_kind eq 'support' && $off < 0;
        next if $line_kind eq 'resistance' && $off > 0;
        my $abs = abs($off);
        if (!defined $best_abs || $abs > $best_abs) {
            $best_abs = $abs;
            $best_off = $off;
        }
    }

    return undef unless defined $best_off && $best_abs > 0;
    return {
        id          => _new_id(),
        type        => $line->{type} eq 'support' ? 'channel_upper' : 'channel_lower',
        timeframe   => $line->{timeframe},
        start_index => $line->{start_index},
        start_time  => $line->{start_time},
        end_index   => $line->{end_index},
        end_time    => $line->{end_time},
        y1          => $line->{y1} + $best_off,
        y2          => $line->{y2} + $best_off,
        slope       => $line->{slope},
        direction   => $line->{direction},
        source_line_id => $line->{id},
    };
}

sub _build_daily_levels {
    my ($candles, $daily, $atr_series, $max_idx, $tf) = @_;
    return [] if $tf eq 'D' || $tf eq 'W';
    return [] unless $daily && @$daily;

    my @daily_sorted = sort { ($a->{time} // '') cmp ($b->{time} // '') } @$daily;
    my @out;
    my $i = 0;

    while ($i <= $max_idx) {
        my $date = _date_of($candles->[$i]{time});
        my $start = $i;
        my $end = $i;
        while ($end + 1 <= $max_idx && _date_of($candles->[$end + 1]{time}) eq $date) {
            $end++;
        }

        my $prev = _prev_daily_for_date(\@daily_sorted, $date);
        if ($prev) {
            my $body_high = max($prev->{open}, $prev->{close});
            my $body_low  = min($prev->{open}, $prev->{close});
            my @levels = (
                ['prev_daily_wick_high', 'PD Wick H', $prev->{high}, 'wick_high'],
                ['prev_daily_body_high', 'PD Body H', $body_high,    'body_high'],
                ['prev_daily_body_low',  'PD Body L', $body_low,     'body_low'],
                ['prev_daily_wick_low',  'PD Wick L', $prev->{low},  'wick_low'],
            );
            for my $lv (@levels) {
                my ($type, $label, $price, $zone) = @$lv;
                push @out, {
                    id          => _new_id(),
                    type        => $type,
                    label       => $label,
                    timeframe   => $tf,
                    daily_time  => $prev->{time},
                    start_index => $start,
                    start_time  => $candles->[$start]{time},
                    end_index   => $end,
                    end_time    => $candles->[$end]{time},
                    price       => $price,
                    zone        => $zone,
                    near        => _touches_daily_level($candles, $atr_series, $start, $end, $price),
                };
            }
        }

        $i = $end + 1;
    }

    return \@out;
}

sub _strategy_liquidity_links {
    my ($levels, $events, $max_idx) = @_;
    my @out;
    for my $ev (@{ $events // [] }) {
        next if ($ev->{swept_index} // 9_999_999) > $max_idx;
        push @out, {
            id => _new_id(),
            liquidity_event_id => $ev->{id},
            index => $ev->{swept_index},
            classification => $ev->{classification},
            projected_effect => $ev->{projected_effect},
        };
    }
    return \@out;
}

sub _volume_average {
    my ($candles, $max_idx) = @_;
    my @avg;
    my $sum = 0;
    for my $i (0 .. $max_idx) {
        $sum += $candles->[$i]{volume} // 0;
        $sum -= $candles->[$i - VOL_WIN]{volume} // 0 if $i >= VOL_WIN;
        my $cnt = $i + 1 < VOL_WIN ? $i + 1 : VOL_WIN;
        $avg[$i] = $cnt ? $sum / $cnt : 1;
    }
    return \@avg;
}

sub _last_opposite_candle {
    my ($candles, $from, $bullish_impulse) = @_;
    my $min_i = $from - ZONE_LOOKBACK + 1;
    $min_i = 0 if $min_i < 0;

    for (my $j = $from; $j >= $min_i; $j--) {
        my $c = $candles->[$j];
        return $j if $bullish_impulse && $c->{close} < $c->{open};
        return $j if !$bullish_impulse && $c->{close} > $c->{open};
    }
    return undef;
}

sub _zone_bounds {
    my ($c, $type) = @_;
    if ($type eq 'demand') {
        return ($c->{low}, max($c->{open}, $c->{close}));
    }
    return (min($c->{open}, $c->{close}), $c->{high});
}

sub _resolve_zone {
    my ($candles, $from, $max_idx, $type, $low, $high) = @_;
    for my $i ($from .. $max_idx) {
        my $c = $candles->[$i];
        if ($type eq 'demand') {
            if ($c->{close} < $low) {
                return { active => 0, status => 'invalidated', end_index => $i, end_time => $c->{time} };
            }
            if ($c->{low} <= $high) {
                return { active => 0, status => 'mitigated', end_index => $i, end_time => $c->{time} };
            }
        }
        else {
            if ($c->{close} > $high) {
                return { active => 0, status => 'invalidated', end_index => $i, end_time => $c->{time} };
            }
            if ($c->{high} >= $low) {
                return { active => 0, status => 'mitigated', end_index => $i, end_time => $c->{time} };
            }
        }
    }
    return { active => 1, status => 'active', end_index => undef, end_time => undef };
}

sub _resolve_order_block {
    my ($candles, $from, $max_idx, $type, $low, $high) = @_;
    for my $i ($from .. $max_idx) {
        my $c = $candles->[$i];
        if ($type eq 'demand') {
            if ($c->{close} <= $low) {
                return {
                    active    => 0,
                    status    => 'invalidated',
                    end_index => $i,
                    end_time  => $c->{time},
                };
            }
            if ($c->{low} <= $high) {
                return {
                    active    => 0,
                    status    => 'mitigated',
                    end_index => $i,
                    end_time  => $c->{time},
                };
            }
        }
        else {
            if ($c->{close} >= $high) {
                return {
                    active    => 0,
                    status    => 'invalidated',
                    end_index => $i,
                    end_time  => $c->{time},
                };
            }
            if ($c->{high} >= $low) {
                return {
                    active    => 0,
                    status    => 'mitigated',
                    end_index => $i,
                    end_time  => $c->{time},
                };
            }
        }
    }
    return { active => 1, status => 'active', end_index => undef, end_time => undef };
}

sub _sr_broken {
    my ($candles, $cl, $max_idx) = @_;
    for my $i (($cl->{last_index} // 0) + 1 .. $max_idx) {
        my $c = $candles->[$i];
        if ($cl->{type} eq 'resistance' && $c->{close} > $cl->{price} + $cl->{tolerance}) {
            return { index => $i, time => $c->{time} };
        }
        if ($cl->{type} eq 'support' && $c->{close} < $cl->{price} - $cl->{tolerance}) {
            return { index => $i, time => $c->{time} };
        }
    }
    return undef;
}

sub _near_event {
    my ($events, $idx, $pad) = @_;
    return undef unless $events && @$events;
    my @near = grep {
        defined $_->{swept_index} && abs($_->{swept_index} - $idx) <= $pad
    } @$events;
    return @near ? $near[-1] : undef;
}

sub _near_structure {
    my ($structs, $idx, $pad) = @_;
    my @near = _near_structures($structs, $idx, $pad);
    return @near ? $near[-1] : undef;
}

sub _near_structures {
    my ($structs, $idx, $pad) = @_;
    return () unless $structs && @$structs;
    my @near = grep {
        defined $_->{break_index} && abs($_->{break_index} - $idx) <= $pad
    } @$structs;
    return @near;
}

sub _touches_daily_level {
    my ($candles, $atr_series, $start, $end, $price) = @_;
    for my $i ($start .. $end) {
        my $atr = _atr_at($atr_series, $candles, $i);
        my $tol = $atr > 0 ? $atr * 0.30 : 0.01;
        return 1 if abs(($candles->[$i]{close} // 0) - $price) <= $tol;
        return 1 if $candles->[$i]{low} <= $price && $candles->[$i]{high} >= $price;
    }
    return 0;
}

sub _prev_daily_for_date {
    my ($daily, $date) = @_;
    my $prev;
    for my $d (@$daily) {
        my $d_date = _date_of($d->{time});
        last if $d_date ge $date;
        $prev = $d;
    }
    return $prev;
}

sub _date_of {
    my ($iso) = @_;
    return '' unless defined $iso;
    return substr($iso, 0, 10);
}

sub _high_low {
    my ($candles, $from, $to) = @_;
    my ($hi, $lo) = (-9**9, 9**9);
    for my $i ($from .. $to) {
        $hi = $candles->[$i]{high} if $candles->[$i]{high} > $hi;
        $lo = $candles->[$i]{low}  if $candles->[$i]{low}  < $lo;
    }
    return ($hi, $lo);
}

sub _line_y_at {
    my ($line, $idx) = @_;
    return $line->{y1} + $line->{slope} * ($idx - $line->{start_index});
}

sub _atr_at {
    my ($atr_series, $candles, $idx) = @_;
    return $atr_series->[$idx] if defined $atr_series && defined $atr_series->[$idx] && $atr_series->[$idx] > 0;
    my $from = $idx - 13;
    $from = 0 if $from < 0;
    my $sum = 0;
    my $cnt = 0;
    for my $i ($from .. $idx) {
        my $c = $candles->[$i];
        $sum += ($c->{high} - $c->{low});
        $cnt++;
    }
    return $cnt ? $sum / $cnt : 0;
}

sub _tf_minutes {
    my ($tf) = @_;
    return 1     if $tf eq '1m';
    return 5     if $tf eq '5m';
    return 15    if $tf eq '15m';
    return 60    if $tf eq '1h';
    return 120   if $tf eq '2h';
    return 240   if $tf eq '4h';
    return 1440  if $tf eq 'D';
    return 10080 if $tf eq 'W';
    return 1;
}

sub _add_minutes_iso {
    my ($iso, $minutes) = @_;
    return $iso unless defined $iso && $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/;
    require Time::Local;
    my ($Y, $Mo, $D, $h, $mi) = ($1 + 0, $2 + 0, $3 + 0, $4 + 0, $5 + 0);
    my $epoch = Time::Local::timegm(0, $mi, $h, $D, $Mo - 1, $Y - 1900);
    $epoch += (defined $minutes ? $minutes : 1) * 60;
    my @g = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:00',
        $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1]);
}

1;
