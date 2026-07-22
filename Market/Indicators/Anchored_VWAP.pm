package Market::Indicators::Anchored_VWAP;

use strict;
use warnings;
use List::Util qw(max);

# ============================================================
#  Market::Indicators::Anchored_VWAP
#
#  Calcula VWAP anclado y bandas de desviacion ponderada por
#  volumen. No dibuja; devuelve segmentos listos para Overlays.
#
#  Regla Replay/no-lookahead:
#    consume solo velas/eventos entregados hasta max_visible_index.
# ============================================================

my %SOURCE_KEYS = map { $_ => 1 } qw(open high low close hl2 hlc3 ohlc4);
my %ANCHOR_KEYS = map { $_ => 1 } qw(session_start market_open confirmed_bos confirmed_choch volume_profile_poc manual);
my %SCOPE_KEYS  = map { $_ => 1 } qw(internal external both);

sub new {
    my ($class, %args) = @_;
    my $self = {
        anchor_session     => $args{anchor_session} // 1,
        anchor_market_open => $args{anchor_market_open} // 1,
        anchor_bos         => $args{anchor_bos} // 1,
        anchor_choch       => $args{anchor_choch} // 1,
        anchor_poc         => $args{anchor_poc} // 1,
        context_bars       => $args{context_bars} // 500,
    };
    return bless $self, $class;
}
sub reset {
    my ($self) = @_;
    $self->{last_result} = undef;
}
sub get_values { [] }

sub calculate_for_window {
    my ($self, $market_data, $start, $end, $full_smc, $vp_profs) = @_;
    
    my $max_idx = $market_data->size() - 1;
    my $candles = $market_data->get_slice(0, $max_idx);
    
    my $settings = {
        anchor_session     => $self->{anchor_session},
        anchor_market_open => $self->{anchor_market_open},
        anchor_bos         => $self->{anchor_bos},
        anchor_choch       => $self->{anchor_choch},
        anchor_poc         => $self->{anchor_poc},
        context_bars       => $self->{context_bars},
    };
    
    my $tf = $market_data->{current_tf} // '1m';
    
    my $res = $self->compute(
        candles          => $candles,
        max_visible_index => $end,
        timeframe        => $tf,
        settings         => $settings,
        structure_events => $full_smc // [],
        poc_events       => $vp_profs // [],
    );
    
    $self->{last_result} = $res;
    return $res;
}

sub get_anchors {
    my ($self) = @_;
    return [] unless $self->{last_result} && $self->{last_result}{segments};
    
    my @mapped;
    for my $seg (@{ $self->{last_result}{segments} }) {
        push @mapped, {
            anchor_type => $seg->{anchor_type},
            start_idx   => $seg->{start_index},
            end_idx     => $seg->{end_index},
            vwap_values => [ map { $_->{value} } @{ $seg->{points} // [] } ],
        };
    }
    return \@mapped;
}

sub compute_missed_pivot_auto {
    my ($class_or_self, %args) = @_;

    my $candles = $args{candles} or die 'Anchored_VWAP::compute_missed_pivot_auto: falta candles';
    my $max_idx = $args{max_visible_index};
    my $tf      = $args{timeframe} // '1m';
    my $symbol  = $args{symbol} // 'DEFAULT';
    my $settings = _normalize_settings($args{settings} // {});
    my $events   = $args{missed_pivot_events} // $args{events} // [];
    my $provisional_raw = $args{provisional_pivot} // $args{provisionalPivot};
    my $total_events = ref($events) eq 'ARRAY' ? scalar @$events : 0;
    $events = [] unless ref($events) eq 'ARRAY';
    my $max_instances = 1;

    $max_idx = $#$candles unless defined $max_idx;
    $max_idx = $#$candles if $max_idx > $#$candles;

    return _empty_auto_result($settings, $tf, 'desactivado') unless $settings->{show};
    return _empty_auto_result($settings, $tf, 'sin datos suficientes') if $max_idx < 0;
    return _empty_auto_result($settings, $tf, 'oculto en 1D o superior')
        if $settings->{hide_on_1d_or_above} && _is_daily_or_above($tf);

    my @confirmed = grep {
        _is_confirmed_missed_pivot($_, $candles, $max_idx, $tf, $symbol)
    } @$events;
    my $provisional = _eligible_provisional_ghost($provisional_raw, $candles, $max_idx, $tf, $symbol);
    my $latest_ghost = _select_latest_ghost(\@confirmed, $provisional);
    my $context_key = join(':', $symbol // 'DEFAULT', $tf // '1m');

    my (@segments, @anchors, @instances);
    my $debug = {
        totalMissedPivots        => $total_events,
        totalGhosts              => scalar(@confirmed),
        validConfirmedPivots     => scalar(@confirmed),
        provisionalGhostConsidered => $provisional ? 1 : 0,
        selectedIsProvisional    => 0,
        selectedEventId          => undef,
        selectedGhostId          => undef,
        selectedPivotTime        => undef,
        selectedConfirmationTime => undef,
        normalizedPivotTime      => undef,
        anchorIndex              => undef,
        previousAutoAvwapId      => undef,
        removedAutoAvwapId       => undef,
        newAutoAvwapId           => undef,
        autoAvwapId              => undef,
        activeAutoAvwapCount     => 0,
        contextKey               => $context_key,
        firstRenderedTime        => undef,
        lastRenderedTime         => undef,
        currentReplayTime        => $candles->[$max_idx]{time},
    };

    for my $ev (grep { defined } $latest_ghost) {
        my $anchor_idx = _event_anchor_index($ev, $candles, $max_idx, $tf);
        next unless defined $anchor_idx && $anchor_idx >= 0 && $anchor_idx <= $max_idx;

        my $anchor_time = $candles->[$anchor_idx]{time} // _event_pivot_time($ev);
        next unless defined $anchor_time && length $anchor_time;

        my $is_provisional = _event_is_provisional($ev) ? 1 : 0;
        my $pivot_type = (($ev->{pivotType} // $ev->{type} // '') eq 'high') ? 'high' : 'low';
        my $event_id   = _missed_pivot_auto_event_id($symbol, $tf, $ev);
        my $instance_id = _missed_pivot_auto_instance_id($symbol, $tf, $event_id);
        my $label = $pivot_type eq 'high' ? 'Missed Pivot High' : 'Missed Pivot Low';
        my $pivot_time = _event_pivot_time($ev);
        my $confirmation_time = _event_confirmation_time($ev);
        $debug->{selectedEventId} = $event_id;
        $debug->{selectedGhostId} = $event_id;
        $debug->{selectedIsProvisional} = $is_provisional;
        $debug->{selectedPivotTime} = $pivot_time;
        $debug->{selectedConfirmationTime} = $confirmation_time;
        $debug->{normalizedPivotTime} = _event_time_sort_key($anchor_time);
        $debug->{anchorIndex} = $anchor_idx;
        $debug->{newAutoAvwapId} = $instance_id;
        $debug->{autoAvwapId} = $instance_id;

        my @anchored_candles = @{ $candles }[$anchor_idx .. $max_idx];
        my $anchored_max_idx = $#anchored_candles;

        my $manual_settings = {
            %$settings,
            show               => 1,
            anchor_type        => 'manual',
            manual_anchor_time => $anchor_time,
        };

        my $avwap = __PACKAGE__->compute(
            candles           => \@anchored_candles,
            max_visible_index => $anchored_max_idx,
            timeframe         => $tf,
            settings          => $manual_settings,
        );
        next unless $avwap->{visible};
        _shift_avwap_result_indices($avwap, $anchor_idx);

        my $meta = {
            source            => 'missedPivotAuto',
            sourceEventId     => $event_id,
            source_event_id   => $event_id,
            missedPivotId     => $event_id,
            pivotType         => $pivot_type,
            pivot_type        => $pivot_type,
            pivotPrice        => defined $ev->{price} ? $ev->{price} + 0 : undef,
            pivot_price       => defined $ev->{price} ? $ev->{price} + 0 : undef,
            pivotTime         => $pivot_time,
            pivot_time        => $pivot_time,
            confirmationIndex => _event_confirmation_index($ev),
            confirmationTime  => $confirmation_time,
            confirmation_time => $confirmation_time,
            confirmed         => $is_provisional ? 0 : 1,
            provisional       => $is_provisional,
            userModified      => 0,
            user_modified     => 0,
            namespace         => 'missedPivotAutoAvwap',
        };

        for my $seg (@{ $avwap->{segments} // [] }) {
            my %copy = %$seg;
            my $points = $copy{points} // [];
            if (@$points) {
                $debug->{firstRenderedTime} //= $points->[0]{time};
                $debug->{lastRenderedTime} = $points->[-1]{time};
            }
            $copy{id}           = $instance_id;
            $copy{source}       = 'missedPivotAuto';
            $copy{source_id}    = $event_id;
            $copy{instance_id}  = $instance_id;
            $copy{anchor_type}  = 'missed_pivot_auto';
            $copy{anchor_label} = $label;
            $copy{anchor_price} = $meta->{pivotPrice};
            $copy{anchor_meta}  = { %{ $copy{anchor_meta} // {} }, %$meta };
            push @segments, \%copy;
        }

        for my $anchor (@{ $avwap->{anchors} // [] }) {
            my %copy = %$anchor;
            $copy{id}           = $instance_id;
            $copy{type}         = 'missed_pivot_auto';
            $copy{label}        = $label;
            $copy{price}        = $meta->{pivotPrice};
            $copy{source}       = 'missedPivotAuto';
            $copy{source_id}    = $event_id;
            $copy{sourceEventId}= $event_id;
            $copy{instance_id}  = $instance_id;
            $copy{pivotType}    = $pivot_type;
            $copy{pivot_type}   = $pivot_type;
            $copy{metadata}     = { %{ $copy{metadata} // {} }, %$meta };
            push @anchors, \%copy;
        }

        push @instances, {
            id                => $instance_id,
            source            => 'missedPivotAuto',
            sourceEventId     => $event_id,
            source_event_id   => $event_id,
            anchorTime        => $anchor_time,
            anchor_time       => $anchor_time,
            anchorIndex       => $anchor_idx,
            anchor_index      => $anchor_idx,
            anchorPrice       => $meta->{pivotPrice},
            anchor_price      => $meta->{pivotPrice},
            pivotType         => $pivot_type,
            pivot_type        => $pivot_type,
            confirmationIndex => $meta->{confirmationIndex},
            confirmationTime  => $meta->{confirmationTime},
            confirmed         => $is_provisional ? 0 : 1,
            provisional       => $is_provisional,
            userModified      => 0,
            status            => 'active',
        };
        $debug->{activeAutoAvwapCount} = scalar(@instances);
    }

    return {
        settings        => { %$settings, anchor_type => 'missed_pivot_auto' },
        source          => $settings->{source},
        anchor_type     => 'missed_pivot_auto',
        timeframe       => $tf,
        namespace       => 'missedPivotAutoAvwap',
        visible         => @segments ? 1 : 0,
        warning         => @segments ? undef : 'sin missed pivots confirmados',
        segments        => \@segments,
        anchors         => \@anchors,
        instances       => \@instances,
        max_instances   => $max_instances,
        debug           => $debug,
        formula         => 'sum(source * volume) / sum(volume)',
        variance_method => 'weighted_welford',
    };
}

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles    = $args{candles}    or die 'Anchored_VWAP::compute: falta candles';
    my $max_idx    = $args{max_visible_index};
    my $tf         = $args{timeframe}  // '1m';
    my $settings   = _normalize_settings($args{settings} // {});
    my $structures = $args{structure_events} // [];
    my $zigzag     = $args{zigzag} // {};
    my $poc_events = $args{poc_events} // $args{volume_profile_pocs} // [];

    $max_idx = $#$candles unless defined $max_idx;
    $max_idx = $#$candles if $max_idx > $#$candles;

    return _empty_result($settings, 'sin datos suficientes') if $max_idx < 0;
    return _empty_result($settings, 'oculto en 1D o superior')
        if $settings->{hide_on_1d_or_above} && _is_daily_or_above($tf);

    my $has_volume = 0;
    for my $i (0 .. $max_idx) {
        my $v = $candles->[$i]{volume};
        if (defined $v && $v > 0) { $has_volume = 1; last; }
    }
    return _empty_result($settings, 'sin volumen valido') unless $has_volume;

    my $anchor_map = _anchor_map(
        candles    => $candles,
        max_idx    => $max_idx,
        timeframe  => $tf,
        settings   => $settings,
        structures => $structures,
        zigzag     => $zigzag,
        poc_events => $poc_events,
    );

    my @segments;
    my $current;
    my ($sum_w, $mean, $m2) = (0, 0, 0);
    my $manual_mode = ($settings->{anchor_type} // '') eq 'manual' ? 1 : 0;

    return _empty_result($settings, 'sin ancla manual visible')
        if $manual_mode && !%$anchor_map;

    for my $i (0 .. $max_idx) {
        next if $i > $#$candles;
        my $c = $candles->[$i];
        my $anchor = $anchor_map->{$i};
        next if $manual_mode && !$current && !$anchor;

        if ($anchor || !$current) {
            push @segments, $current if $current && @{ $current->{points} };
            $current = _new_segment($i, $c, $settings, $anchor);
            ($sum_w, $mean, $m2) = (0, 0, 0);
        }

        my $price = _source_price($c, $settings->{source});
        my $vol   = $c->{volume};
        if (!defined $price || !defined $vol || $vol <= 0) {
            next;
        }

        # Weighted Welford. mean es el VWAP acumulado y m2/sum_w
        # la varianza ponderada desde el anchor activo.
        my $prev_w = $sum_w;
        my $new_w  = $prev_w + $vol;
        my $delta  = $price - $mean;
        my $next_mean = $mean + ($vol / $new_w) * $delta;
        my $delta2 = $price - $next_mean;
        $m2 += $vol * $delta * $delta2;
        $sum_w = $new_w;
        $mean  = $next_mean;

        my $variance = $sum_w > 0 ? $m2 / $sum_w : undef;
        $variance = 0 if defined $variance && $variance < 0 && $variance > -1e-9;
        my $stdev = defined $variance && $variance >= 0 ? sqrt($variance) : undef;
        my $point = {
            index             => $i,
            time              => $c->{time},
            source_price      => sprintf('%.10f', $price) + 0,
            volume            => sprintf('%.4f', $vol) + 0,
            cumulative_volume => sprintf('%.4f', $sum_w) + 0,
            value             => sprintf('%.10f', $mean) + 0,
            stdev             => defined $stdev ? sprintf('%.10f', $stdev) + 0 : undef,
        };

        for my $band (@{ $settings->{bands} }) {
            next unless $band->{show};
            my $n = $band->{number};
            my $m = $band->{multiplier};
            $point->{"upper$n"} = defined $stdev ? sprintf('%.10f', $mean + $m * $stdev) + 0 : undef;
            $point->{"lower$n"} = defined $stdev ? sprintf('%.10f', $mean - $m * $stdev) + 0 : undef;
        }

        push @{ $current->{points} }, $point;
        $current->{end_index} = $i;
        $current->{end_time}  = $c->{time};
    }
    push @segments, $current if $current && @{ $current->{points} };

    return {
        settings        => $settings,
        source          => $settings->{source},
        anchor_type     => $settings->{anchor_type},
        timeframe       => $tf,
        visible         => @segments ? 1 : 0,
        warning         => @segments ? undef : 'sin puntos VWAP calculables',
        segments        => \@segments,
        anchors         => [ sort { ($a->{index} // 0) <=> ($b->{index} // 0) } values %$anchor_map ],
        formula         => 'sum(source * volume) / sum(volume)',
        variance_method => 'weighted_welford',
    };
}

sub _normalize_settings {
    my ($raw) = @_;
    my $source = lc($raw->{source} // 'hlc3');
    $source = 'hlc3' unless $SOURCE_KEYS{$source};

    my $anchor = lc($raw->{anchor_type} // $raw->{anchor} // 'session_start');
    $anchor =~ s/[\s-]+/_/g;
    $anchor = 'session_start' unless $ANCHOR_KEYS{$anchor};

    my $scope = lc($raw->{structure_scope} // 'external');
    $scope = 'external' unless $SCOPE_KEYS{$scope};

    my $offset = int($raw->{offset} // 0);
    my $line_style = lc($raw->{line_style} // 'solid');
    $line_style = 'solid' unless $line_style =~ /^(?:solid|dashed|dotted)$/;
    my $line_width = $raw->{line_width} // 2;
    $line_width = 1 if $line_width < 1;

    my @bands;
    for my $n (1 .. 3) {
        my $cfg = $raw->{bands} && ref($raw->{bands}) eq 'ARRAY'
            ? $raw->{bands}[$n - 1]
            : undef;
        $cfg = {} unless $cfg && ref($cfg) eq 'HASH';
        my $mult = $cfg->{multiplier};
        $mult = $n unless defined $mult && $mult =~ /^-?\d+(?:\.\d+)?$/;
        $mult = 0 if $mult < 0;
        push @bands, {
            number     => $n,
            show       => $cfg->{show} ? 1 : 0,
            multiplier => $mult + 0,
        };
    }

    return {
        show                  => exists $raw->{show} ? ($raw->{show} ? 1 : 0) : 1,
        hide_on_1d_or_above   => $raw->{hide_on_1d_or_above} ? 1 : 0,
        anchor_type           => $anchor,
        manual_anchor_time    => $raw->{manual_anchor_time} // $raw->{anchor_time},
        source                => $source,
        offset                => $offset,
        structure_scope       => $scope,
        line_style            => $line_style,
        line_width            => $line_width + 0,
        color                 => _valid_color($raw->{color}) ? $raw->{color} : '#2962FF',
        auto_missed_pivots    => exists $raw->{auto_missed_pivots} ? ($raw->{auto_missed_pivots} ? 1 : 0) : 1,
        auto_missed_max       => _normalize_auto_missed_max($raw->{auto_missed_max}),
        bands                 => \@bands,
    };
}

sub _normalize_auto_missed_max {
    my ($v) = @_;
    $v = 20 unless defined $v && $v =~ /^\d+$/;
    $v = int($v);
    $v = 1   if $v < 1;
    $v = 200 if $v > 200;
    return $v;
}

sub _empty_result {
    my ($settings, $warning) = @_;
    return {
        settings    => $settings,
        visible     => 0,
        warning     => $warning,
        segments    => [],
        anchors     => [],
        formula     => 'sum(source * volume) / sum(volume)',
    };
}

sub _valid_color {
    my ($c) = @_;
    return defined $c && $c =~ /^#[0-9a-fA-F]{6}$/ ? 1 : 0;
}

sub _is_daily_or_above {
    my ($tf) = @_;
    return ($tf // '') eq 'D' || ($tf // '') eq 'W' ? 1 : 0;
}

sub _new_segment {
    my ($i, $c, $settings, $anchor) = @_;
    return {
        id           => 'AVWAP_SEG_' . $i,
        anchor_index => $i,
        anchor_time  => $c->{time},
        anchor_type  => $settings->{anchor_type},
        anchor_label => $anchor ? ($anchor->{label} // $settings->{anchor_type}) : 'initial',
        anchor_meta  => $anchor ? ($anchor->{metadata} // {}) : {},
        start_index  => $i,
        start_time   => $c->{time},
        end_index    => $i,
        end_time     => $c->{time},
        points       => [],
    };
}

sub _source_price {
    my ($c, $source) = @_;
    return undef unless $c;
    return $c->{open}  + 0 if $source eq 'open'  && defined $c->{open};
    return $c->{high}  + 0 if $source eq 'high'  && defined $c->{high};
    return $c->{low}   + 0 if $source eq 'low'   && defined $c->{low};
    return $c->{close} + 0 if $source eq 'close' && defined $c->{close};
    return undef unless defined $c->{high} && defined $c->{low};
    return (($c->{high} + $c->{low}) / 2) if $source eq 'hl2';
    return undef unless defined $c->{close};
    return (($c->{high} + $c->{low} + $c->{close}) / 3) if $source eq 'hlc3';
    return undef unless defined $c->{open};
    return (($c->{open} + $c->{high} + $c->{low} + $c->{close}) / 4) if $source eq 'ohlc4';
    return (($c->{high} + $c->{low} + $c->{close}) / 3);
}

sub _anchor_map {
    my (%args) = @_;
    my $type = $args{settings}{anchor_type};
    return _session_anchors(%args)      if $type eq 'session_start';
    return _market_open_anchors(%args)  if $type eq 'market_open';
    return _structure_anchors(%args, wanted => 'BOS')   if $type eq 'confirmed_bos';
    return _structure_anchors(%args, wanted => 'CHOCH') if $type eq 'confirmed_choch';
    return _poc_anchors(%args)          if $type eq 'volume_profile_poc';
    return _manual_anchors(%args)       if $type eq 'manual';
    return _session_anchors(%args);
}

sub _manual_anchors {
    my (%args) = @_;
    my $candles = $args{candles};
    my $max_idx = $args{max_idx};
    my $tf      = $args{timeframe} // '1m';
    my $target  = $args{settings}{manual_anchor_time};
    my %anchors;

    return \%anchors unless defined $target && length $target;
    return \%anchors unless $candles && @$candles && $max_idx >= 0;

    my $idx = _find_manual_anchor_index($candles, $max_idx, $target, $tf);
    return \%anchors unless defined $idx && $idx >= 0 && $idx <= $max_idx;

    $anchors{$idx} = {
        index => $idx,
        time  => $candles->[$idx]{time},
        type  => 'manual',
        label => 'Manual Anchor',
        metadata => {
            requested_time => $target,
            timeframe      => $tf,
            stable_key     => $candles->[$idx]{time},
        },
    };
    return \%anchors;
}

sub _find_manual_anchor_index {
    my ($candles, $max_idx, $target, $tf) = @_;
    my $target_epoch = _iso_epoch_minute($target);
    my $tf_seconds = _tf_seconds($tf);

    for my $i (0 .. $max_idx) {
        my $ts = $candles->[$i]{time};
        next unless defined $ts;
        return $i if $ts eq $target || _iso_key($ts) eq _iso_key($target);
    }

    return undef unless defined $target_epoch;

    my $first_start = _iso_epoch_minute($candles->[0]{time});
    my $last_start  = _iso_epoch_minute($candles->[$max_idx]{time});
    my $last_end    = defined $last_start ? $last_start + $tf_seconds : undef;
    return undef if defined $first_start && $target_epoch < $first_start;
    return undef if defined $last_end && $target_epoch >= $last_end;

    for my $i (0 .. $max_idx) {
        my $start = _iso_epoch_minute($candles->[$i]{time});
        next unless defined $start;
        my $end = $i < $max_idx
            ? _iso_epoch_minute($candles->[$i + 1]{time})
            : $start + $tf_seconds;
        $end = $start + $tf_seconds unless defined $end && $end > $start;
        return $i if $target_epoch >= $start && $target_epoch < $end;
    }

    my ($best_i, $best_delta);
    for my $i (0 .. $max_idx) {
        my $start = _iso_epoch_minute($candles->[$i]{time});
        next unless defined $start;
        my $delta = abs($target_epoch - $start);
        if (!defined $best_delta || $delta < $best_delta) {
            ($best_i, $best_delta) = ($i, $delta);
        }
    }
    return $best_i;
}

sub _iso_key {
    my ($iso) = @_;
    return '' unless defined $iso;
    return substr($iso, 0, 19);
}

sub _iso_epoch_minute {
    my ($iso) = @_;
    return undef unless defined $iso && $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/;
    require Time::Local;
    my ($Y, $Mo, $D, $h, $mi) = ($1 + 0, $2 + 0, $3 + 0, $4 + 0, $5 + 0);
    return Time::Local::timegm(0, $mi, $h, $D, $Mo - 1, $Y - 1900);
}

sub _tf_seconds {
    my ($tf) = @_;
    return 5 * 60     if ($tf // '') eq '5m';
    return 15 * 60    if ($tf // '') eq '15m';
    return 60 * 60    if ($tf // '') eq '1h';
    return 120 * 60   if ($tf // '') eq '2h';
    return 240 * 60   if ($tf // '') eq '4h';
    return 1440 * 60  if ($tf // '') eq 'D';
    return 10080 * 60 if ($tf // '') eq 'W';
    return 60;
}

sub _empty_auto_result {
    my ($settings, $tf, $warning) = @_;
    return {
        settings      => { %$settings, anchor_type => 'missed_pivot_auto' },
        source        => $settings->{source},
        anchor_type   => 'missed_pivot_auto',
        timeframe     => $tf,
        namespace     => 'missedPivotAutoAvwap',
        visible       => 0,
        warning       => $warning,
        segments      => [],
        anchors       => [],
        instances     => [],
        max_instances => 1,
        formula       => 'sum(source * volume) / sum(volume)',
    };
}

# Selecciona EXCLUSIVAMENTE el ultimo fantasma: el de mayor bar_index
# (pivotTime), sea confirmado o provisional (barstate.islast). Los ghosts
# previos se ignoran por completo. En empate de bar_index se prefiere el
# confirmado sobre el provisional para no soltar un ancla estable.
sub _select_latest_ghost {
    my ($confirmed, $provisional) = @_;
    my @candidates = grep { defined } @{ $confirmed // [] };
    push @candidates, $provisional if defined $provisional;
    return undef unless @candidates;

    my $best;
    for my $ev (@candidates) {
        if (!defined $best) { $best = $ev; next; }
        $best = $ev if _ghost_is_more_recent($ev, $best);
    }
    return $best;
}

# 1 si $ev es un fantasma mas reciente que $ref segun la regla del ultimo
# fantasma (mayor bar_index primero; confirmationTime como desempate; el
# confirmado gana al provisional en empate exacto).
sub _ghost_is_more_recent {
    my ($ev, $ref) = @_;

    my $ev_pt  = _event_pivot_sort_key($ev);
    my $ref_pt = _event_pivot_sort_key($ref);

    # Clave primaria: mayor bar_index (pivotTime) = fantasma mas reciente.
    if (defined $ev_pt || defined $ref_pt) {
        return 0 unless defined $ev_pt;
        return 1 unless defined $ref_pt;
        return 1 if $ev_pt > $ref_pt;
        return 0 if $ev_pt < $ref_pt;
    }

    # Empate de posicion: gana la confirmacion mas reciente.
    my $ev_ct  = _event_confirmation_sort_key($ev);
    my $ref_ct = _event_confirmation_sort_key($ref);
    if (defined $ev_ct && (!defined $ref_ct || $ev_ct > $ref_ct)) {
        return 1;
    }

    # Empate total: preferir el confirmado frente al provisional.
    return 1 if !_event_is_provisional($ev) && _event_is_provisional($ref);
    return 0;
}

sub _event_is_provisional {
    my ($ev) = @_;
    return 0 unless $ev && ref($ev) eq 'HASH';
    return 1 if $ev->{provisional};
    return 1 if ($ev->{kind} // '') eq 'provisionalPivot';
    return 0;
}

# Valida el pivote provisional (barstate.islast) como candidato a ancla.
# No exige confirmationTime: por construccion se calcula sobre velas ya
# visibles (<= max_idx), asi que no rompe la regla de no-lookahead.
sub _eligible_provisional_ghost {
    my ($ev, $candles, $max_idx, $tf, $symbol) = @_;
    return undef unless $ev && ref($ev) eq 'HASH';
    return undef unless _event_is_provisional($ev);

    my $event_symbol = $ev->{symbol} // $ev->{ticker};
    return undef if defined $event_symbol && defined $symbol && length($event_symbol) && $event_symbol ne $symbol;

    my $event_tf = $ev->{timeframe} // $ev->{tf} // $ev->{interval};
    return undef if defined $event_tf && length($event_tf) && $event_tf ne ($tf // '1m');

    my $pivot_type = $ev->{pivotType} // $ev->{type} // '';
    return undef unless $pivot_type eq 'high' || $pivot_type eq 'low';

    my $pivot_time = _event_pivot_time($ev);
    return undef unless defined $pivot_time && length $pivot_time;
    return undef unless defined _event_time_sort_key($pivot_time);

    my $anchor_idx = _event_anchor_index($ev, $candles, $max_idx, $tf);
    return undef unless defined $anchor_idx && $anchor_idx >= 0 && $anchor_idx <= $max_idx;

    return $ev;
}

sub _shift_avwap_result_indices {
    my ($avwap, $delta) = @_;
    return $avwap unless $avwap && $delta;

    for my $anchor (@{ $avwap->{anchors} // [] }) {
        $anchor->{index} += $delta if defined $anchor->{index};
    }
    for my $seg (@{ $avwap->{segments} // [] }) {
        for my $key (qw(anchor_index start_index end_index)) {
            $seg->{$key} += $delta if defined $seg->{$key};
        }
        for my $pt (@{ $seg->{points} // [] }) {
            $pt->{index} += $delta if defined $pt->{index};
        }
    }

    return $avwap;
}

sub _is_confirmed_missed_pivot {
    my ($ev, $candles, $max_idx, $tf, $symbol) = @_;
    return 0 unless $ev && ref($ev) eq 'HASH';
    return 0 if $ev->{provisional};
    return 0 if ($ev->{kind} // '') eq 'provisionalPivot';
    return 0 unless ($ev->{kind} // '') eq 'missedPivot';
    return 0 unless $ev->{confirmed};

    my $event_symbol = $ev->{symbol} // $ev->{ticker};
    return 0 if defined $event_symbol && defined $symbol && length($event_symbol) && $event_symbol ne $symbol;

    my $event_tf = $ev->{timeframe} // $ev->{tf} // $ev->{interval};
    return 0 if defined $event_tf && length($event_tf) && $event_tf ne ($tf // '1m');

    my $pivot_time = _event_pivot_time($ev);
    my $confirm_time = _event_confirmation_time($ev);
    return 0 unless defined $pivot_time && length $pivot_time;
    return 0 unless defined $confirm_time && length $confirm_time;
    return 0 unless defined _event_time_sort_key($pivot_time);
    return 0 unless defined _event_time_sort_key($confirm_time);

    my $pivot_type = $ev->{pivotType} // $ev->{type} // '';
    return 0 unless $pivot_type eq 'high' || $pivot_type eq 'low';

    my $anchor_idx = _event_anchor_index($ev, $candles, $max_idx, $tf);
    return 0 unless defined $anchor_idx && $anchor_idx >= 0 && $anchor_idx <= $max_idx;

    my $confirm_epoch = _event_time_sort_key($confirm_time);
    my $max_epoch = _event_time_sort_key($candles->[$max_idx]{time});
    return $confirm_epoch <= $max_epoch ? 1 : 0
        if defined $confirm_epoch && defined $max_epoch;

    my $confirm_idx = _event_confirmation_index($ev);
    return 1 if defined $confirm_idx && $confirm_idx >= 0 && $confirm_idx <= $max_idx;
    return 0;
}

sub _event_anchor_index {
    my ($ev, $candles, $max_idx, $tf) = @_;
    return undef unless $ev && $candles && @$candles && $max_idx >= 0;

    my $time = _event_pivot_time($ev);
    return undef unless defined $time && length $time;

    return _find_exact_anchor_time_index($candles, $max_idx, $time);
}

sub _event_confirmation_index {
    my ($ev) = @_;
    my $idx = $ev->{confirmationIndex} // $ev->{confirmed_at} // $ev->{confirmation_index};
    return undef unless defined $idx && $idx =~ /^\d+$/;
    return int($idx);
}

sub _event_confirmation_sort_key {
    my ($ev) = @_;
    my $time = _event_confirmation_time($ev);
    return _event_time_sort_key($time);
}

sub _event_pivot_sort_key {
    my ($ev) = @_;
    my $time = _event_pivot_time($ev);
    return _event_time_sort_key($time);
}

sub _event_pivot_time {
    my ($ev) = @_;
    return undef unless $ev && ref($ev) eq 'HASH';
    return $ev->{pivotTime} // $ev->{pivot_time};
}

sub _event_confirmation_time {
    my ($ev) = @_;
    return undef unless $ev && ref($ev) eq 'HASH';
    return $ev->{confirmationTime} // $ev->{confirmed_time} // $ev->{confirmation_time};
}

sub _event_time_sort_key {
    my ($time) = @_;
    return undef unless defined $time && length "$time";

    if ($time =~ /^-?\d+(?:\.\d+)?$/) {
        my $num = $time + 0;
        $num = $num / 1000 if abs($num) > 10_000_000_000;
        return int($num);
    }

    my $raw = "$time";
    if ($raw =~ /^(\d{4})-(\d{2})-(\d{2})[T\s](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|([+-])(\d{2}):?(\d{2}))?/) {
        require Time::Local;
        my ($Y, $Mo, $D, $h, $mi, $s) = ($1 + 0, $2 + 0, $3 + 0, $4 + 0, $5 + 0, ($6 // 0) + 0);
        my $epoch = Time::Local::timegm($s, $mi, $h, $D, $Mo - 1, $Y - 1900);
        if (defined $7 && $7 ne 'Z') {
            my $sign = $8 // '+';
            my $off = (($9 // 0) * 3600) + (($10 // 0) * 60);
            $epoch += $sign eq '-' ? $off : -$off;
        }
        return $epoch;
    }

    return _iso_epoch_minute($time);
}

sub _find_exact_anchor_time_index {
    my ($candles, $max_idx, $target) = @_;
    return undef unless $candles && @$candles && defined $target && length "$target";

    my $target_epoch = _event_time_sort_key($target);
    my $target_key = _iso_key($target);
    for my $i (0 .. $max_idx) {
        my $ts = $candles->[$i]{time};
        next unless defined $ts && length $ts;
        return $i if $ts eq $target;

        my $epoch = _event_time_sort_key($ts);
        return $i if defined $target_epoch && defined $epoch && $epoch == $target_epoch;
        return $i if !defined $target_epoch && _iso_key($ts) eq $target_key;
    }
    return undef;
}

sub _missed_pivot_auto_event_id {
    my ($symbol, $tf, $ev) = @_;
    my $is_provisional = _event_is_provisional($ev);

    # El id crudo del provisional incluye max_idx y cambiaria en cada barra;
    # se deriva de su bar_index para que el ancla sea estable mientras el
    # fantasma no se mueva y solo se re-ancle cuando cambia de posicion.
    unless ($is_provisional) {
        my $raw = $ev->{missedPivotId} // $ev->{event_id} // $ev->{id};
        return $raw if defined $raw && length $raw;
    }

    my $pivot_type = $ev->{pivotType} // $ev->{type} // 'unknown';
    my $pivot_time = $ev->{pivotTime} // $ev->{pivot_time} // $ev->{time} // '';
    my $idx = $ev->{index} // $ev->{pivotIndex} // $ev->{pivot_index} // '';
    my $prefix = $is_provisional ? 'provisional-pivot' : 'missed-pivot';
    return join(':', $prefix, $symbol // 'DEFAULT', $tf // '1m', $pivot_time, $idx, $pivot_type);
}

sub _missed_pivot_auto_instance_id {
    my ($symbol, $tf, $event_id) = @_;
    return join(':', 'auto-avwap', $symbol // 'DEFAULT', $tf // '1m', $event_id // 'unknown');
}

sub _session_anchors {
    my (%args) = @_;
    my $candles = $args{candles};
    my $max_idx = $args{max_idx};
    my %anchors;
    my $prev_key = '';

    for my $i (0 .. $max_idx) {
        my $ts = $candles->[$i]{time} // next;
        my $key = substr($ts, 0, 10);
        next if $key eq $prev_key;
        $anchors{$i} = {
            index => $i,
            time  => $ts,
            type  => 'session_start',
            label => 'Session Start',
            metadata => { session_key => $key, timezone => 'data_timestamp' },
        };
        $prev_key = $key;
    }
    return \%anchors;
}

sub _market_open_anchors {
    my (%args) = @_;
    my $candles = $args{candles};
    my $max_idx = $args{max_idx};
    my $tf      = $args{timeframe} // '1m';
    my %anchors;
    my %seen_day;

    for my $i (0 .. $max_idx) {
        my $ts = $candles->[$i]{time} // next;
        my $day = substr($ts, 0, 10);
        next if $seen_day{$day}++;
        $anchors{$i} = {
            index => $i,
            time  => $ts,
            type  => 'market_open',
            label => 'Market Open',
            metadata => {
                market_open_source => 'first_available_session_candle',
                limitation => 'sin calendario oficial por simbolo; se reutiliza apertura de sesion cargada',
                timeframe => $tf,
            },
        };
    }
    return \%anchors;
}

sub _structure_anchors {
    my (%args) = @_;
    my $structures = $args{structures} // $args{structure_events} // [];
    my $max_idx = $args{max_idx};
    my $scope = $args{settings}{structure_scope} // 'external';
    my $wanted = $args{wanted};
    my %anchors;

    for my $st (@$structures) {
        next unless uc($st->{type} // '') eq $wanted;
        my $st_scope = $st->{scope} // 'external';
        next if $scope ne 'both' && $st_scope ne $scope;
        next unless ($st->{status} // 'confirmed') eq 'confirmed' || $st->{confirmed};
        my $idx = $st->{confirmation_index} // $st->{break_index};
        next unless defined $idx && $idx >= 0 && $idx <= $max_idx;
        next if exists $anchors{$idx};
        $anchors{$idx} = {
            index => $idx,
            time  => $st->{confirmation_time} // $st->{break_time},
            type  => lc("confirmed_$wanted"),
            label => $wanted eq 'BOS' ? 'Confirmed BOS' : 'Confirmed CHoCH',
            metadata => {
                structure_id => $st->{id},
                scope        => $st_scope,
                direction    => $st->{direction},
                break_index  => $st->{break_index},
            },
        };
    }
    return \%anchors;
}

sub _poc_anchors {
    my (%args) = @_;
    my $candles = $args{candles};
    my $max_idx = $args{max_idx};
    my $pocs    = $args{poc_events} // [];
    my %anchors;

    for my $poc (@$pocs) {
        my $idx = $poc->{anchor_index};
        next if $idx < 0 || $idx > $max_idx;
        $anchors{$idx} = {
            index => $idx,
            time  => $poc->{anchor_time} // $candles->[$idx]{time},
            type  => 'volume_profile_poc',
            label => 'Volume Profile POC',
            metadata => {
                profile_start_index => $poc->{profile_start_index},
                profile_end_index   => $poc->{profile_end_index},
                poc_price           => $poc->{poc_price},
                poc_volume          => $poc->{poc_volume},
                temporal_criterion  => $poc->{temporal_criterion},
                source_profile_id   => $poc->{id},
                confirmed           => $poc->{confirmed} ? 1 : 0,
            },
        };
    }

    return \%anchors;
}

1;
