package Market::Indicators::Volume_Profile;

use strict;
use warnings;
use List::Util qw(max min);

# ============================================================
#  Market::Indicators::Volume_Profile
#
#  Perfil de volumen anclado por sesion, estructura BOS/CHoCH o
#  ZigZag. No dibuja; entrega perfiles con bins, POC, VAH/VAL y
#  una lista pocs compatible con Anchored VWAP.
#
#  Sin datos tick-by-tick, el volumen de cada vela se distribuye
#  proporcionalmente por la interseccion entre su rango High-Low y
#  el rango de cada bin.
# ============================================================

my %MODE_KEYS = map { $_ => 1 } qw(visible_range session structure zigzag missed_pivot_auto);
my %EVENT_KEYS = map { $_ => 1 } qw(bos choch both);
my %SCOPE_KEYS = map { $_ => 1 } qw(internal external both);

sub new {
    my ($class, %args) = @_;
    my $self = {
        mode           => $args{mode} // 'session',
        price_levels   => $args{price_levels} // 100,
        value_area_pct => $args{value_area_pct} // 0.70,
        context_bars   => $args{context_bars} // 500,
    };
    return bless $self, $class;
}
sub reset {
    my ($self) = @_;
    $self->{last_result} = undef;
}
sub get_values { [] }

sub calculate_for_window {
    my ($self, $market_data, $start, $end, $full_smc) = @_;
    
    my $max_idx = $market_data->size() - 1;
    my $candles = $market_data->get_slice(0, $max_idx);
    
    my $settings = {
        mode           => $self->{mode},
        price_levels   => $self->{price_levels},
        value_area_pct => $self->{value_area_pct},
        context_bars   => $self->{context_bars},
    };
    
    my $res = $self->compute(
        candles           => $candles,
        max_visible_index => $end,
        visible_start     => $start,
        settings          => $settings,
        structure_events  => $full_smc // [],
    );
    
    $self->{last_result} = $res;
    return $res;
}

sub get_profiles {
    my ($self) = @_;
    return [] unless $self->{last_result} && $self->{last_result}{profiles};
    
    my @mapped;
    for my $prof (@{ $self->{last_result}{profiles} }) {
        push @mapped, {
            %$prof,
            start_idx => $prof->{start_index},
            end_idx   => $prof->{end_index},
            vah_price => $prof->{vah},
            val_price => $prof->{val},
        };
    }
    return \@mapped;
}

sub get_pocs {
    my ($self) = @_;
    return $self->{last_result} ? $self->{last_result}{pocs} : [];
}

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles = $args{candles} or die 'Volume_Profile::compute: falta candles';
    my $max_idx = $args{max_visible_index};
    my $settings = _normalize_settings($args{settings} // \%args);

    $max_idx = $#$candles unless defined $max_idx;
    $max_idx = $#$candles if $max_idx > $#$candles;
    return _empty_result($settings, 'sin datos suficientes') if $max_idx < 0;

    my $has_volume = 0;
    for my $i (0 .. $max_idx) {
        my $v = $candles->[$i]{volume};
        if (defined $v && $v > 0) { $has_volume = 1; last; }
    }
    return _empty_result($settings, 'sin volumen valido') unless $has_volume;

    my $ranges = _profile_ranges(
        candles          => $candles,
        max_idx          => $max_idx,
        visible_start    => $args{visible_start},
        settings         => $settings,
        anchor_event     => $args{anchor_event},
        structure_events => $args{structure_events} // [],
        zigzag           => $args{zigzag} // {},
    );

    my @profiles;
    for my $range (@$ranges) {
        my $profile = _build_profile($candles, $range, $settings, scalar @profiles);
        push @profiles, $profile if $profile;
    }

    my @pocs = map { _poc_contract($_) } @profiles;
    return {
        visible     => @profiles ? 1 : 0,
        warning     => @profiles ? undef : 'sin perfiles calculables',
        settings    => $settings,
        profiles    => \@profiles,
        pocs        => \@pocs,
        bins        => $settings->{number_of_bins},
        source      => 'advanced_volume_profile',
        timeframe   => $args{timeframe} // '1m',
        method      => 'overlap_high_low_volume_distribution',
    };
}

sub _normalize_settings {
    my ($raw) = @_;
    $raw = {} unless $raw && ref($raw) eq 'HASH';

    my $mode = lc($raw->{mode} // $raw->{profile_mode} // 'visible_range');
    $mode =~ s/[\s-]+/_/g;
    $mode = 'visible_range' if $mode eq 'visible' || $mode eq 'range' || $mode eq 'visible_window';
    $mode = 'structure' if $mode eq 'bos_choch' || $mode eq 'bos/choch';
    $mode = 'zigzag' if $mode eq 'pivot_zigzag' || $mode eq 'pivot';
    $mode = 'missed_pivot_auto'
        if $mode eq 'missed_pivot'
        || $mode eq 'missed_pivot_auto'
        || $mode eq 'anchored_missed_pivot'
        || $mode eq 'anchored_volume_profile';
    $mode = 'visible_range' unless $MODE_KEYS{$mode};

    my $event = lc($raw->{structure_event} // 'both');
    $event = 'both' unless $EVENT_KEYS{$event};

    my $scope = lc($raw->{structure_scope} // 'external');
    $scope = 'external' unless $SCOPE_KEYS{$scope};

    my $profiles = int($raw->{profiles_to_display} // 5);
    $profiles = 1 if $profiles < 1;
    $profiles = 20 if $profiles > 20;

    my $bins = int($raw->{number_of_bins} // $raw->{bins} // 20);
    $bins = 5 if $bins < 5;
    $bins = 100 if $bins > 100;

    my $va = ($raw->{value_area_percent} // 70) + 0;
    $va = 1 if $va < 1;
    $va = 100 if $va > 100;

    my $min_bars = int($raw->{min_bars} // 2);
    $min_bars = 1 if $min_bars < 1;

    return {
        show                 => exists $raw->{show} ? ($raw->{show} ? 1 : 0) : 1,
        mode                 => $mode,
        structure_event      => $event,
        structure_scope      => $scope,
        profiles_to_display  => $profiles,
        number_of_bins       => $bins,
        value_area_percent   => $va,
        min_bars             => $min_bars,
        fallback_lookback    => int($raw->{fallback_lookback} // 500),
    };
}

sub _empty_result {
    my ($settings, $warning) = @_;
    return {
        visible  => 0,
        warning  => $warning,
        settings => $settings,
        profiles => [],
        pocs     => [],
        method   => 'overlap_high_low_volume_distribution',
    };
}

sub _profile_ranges {
    my (%args) = @_;
    my $settings = $args{settings};
    my $mode = $settings->{mode};
    my $ranges =
          $mode eq 'visible_range' ? _visible_range(%args)
        : $mode eq 'structure' ? _structure_ranges(%args)
        : $mode eq 'zigzag'    ? _zigzag_ranges(%args)
        : $mode eq 'missed_pivot_auto' ? _missed_pivot_auto_ranges(%args)
        :                        _session_ranges(%args);

    my @valid = grep {
        defined $_->{start_index}
            && defined $_->{end_index}
            && $_->{start_index} <= $_->{end_index}
            && ($_->{end_index} - $_->{start_index} + 1) >= $settings->{min_bars}
    } @$ranges;

    if (!@valid && $mode ne 'missed_pivot_auto') {
        @valid = (_fallback_range(%args, reason => 'insufficient_profile_ranges'));
    }

    @valid = sort { $a->{start_index} <=> $b->{start_index} } @valid;
    if (@valid > $settings->{profiles_to_display}) {
        @valid = @valid[-$settings->{profiles_to_display} .. -1];
    }
    return \@valid;
}

sub _visible_range {
    my (%args) = @_;
    my $candles = $args{candles};
    my $max_idx = $args{max_idx};
    my $visible_start = defined $args{visible_start} ? int($args{visible_start}) : 0;
    return [] unless $candles && @$candles;
    $visible_start = 0 if $visible_start < 0;
    $visible_start = $max_idx if $visible_start > $max_idx;
    return [
        _range_hash(
            $visible_start, $max_idx, 'visible_range', $candles, 0, 0,
            { range_source => 'chart_visible_range' },
        ),
    ];
}

sub _missed_pivot_auto_ranges {
    my (%args) = @_;
    my $candles = $args{candles};
    my $max_idx = $args{max_idx};
    my $anchor = $args{anchor_event} // {};
    return [] unless $candles && @$candles;
    return [] unless $anchor && ref($anchor) eq 'HASH';

    my $anchor_idx = $anchor->{anchor_index}
        // $anchor->{index}
        // $anchor->{pivot_index}
        // $anchor->{x1_index};
    return [] unless defined $anchor_idx;
    $anchor_idx = int($anchor_idx);
    return [] if $anchor_idx < 0 || $anchor_idx > $#$candles;
    return [] unless defined $max_idx && $anchor_idx < $max_idx;

    return [
        _range_hash(
            $anchor_idx, $max_idx, 'missed_pivot_auto', $candles, 1, 0,
            {
                anchor_source       => 'pivot_missed_reversal',
                anchor_id           => $anchor->{id} // $anchor->{event_id},
                anchor_type         => $anchor->{type} // $anchor->{pivotType},
                anchor_price        => $anchor->{price},
                confirmation_index  => $anchor->{confirmationIndex} // $anchor->{confirmed_at},
                confirmation_time   => $anchor->{confirmationTime}  // $anchor->{confirmed_time},
            },
        ),
    ];
}

sub _session_ranges {
    my (%args) = @_;
    my $candles = $args{candles};
    my $max_idx = $args{max_idx};
    my $visible_start = defined $args{visible_start} ? $args{visible_start} : 0;
    my @ranges;
    my ($cur_day, $start);

    for my $i (0 .. $max_idx) {
        my $ts = $candles->[$i]{time} // next;
        my $day = substr($ts, 0, 10);
        if (!defined $cur_day || $day ne $cur_day) {
            if (defined $start) {
                push @ranges, _range_hash($start, $i - 1, 'session', $candles, 1, 0);
            }
            $cur_day = $day;
            $start = $i;
        }
    }
    push @ranges, _range_hash($start, $max_idx, 'session', $candles, 0, 0) if defined $start;

    return [ grep { $_->{end_index} >= $visible_start } @ranges ];
}

sub _structure_ranges {
    my (%args) = @_;
    my $candles = $args{candles};
    my $max_idx = $args{max_idx};
    my $visible_start = defined $args{visible_start} ? $args{visible_start} : 0;
    my $settings = $args{settings};
    my @events = sort {
        ($a->{confirmation_index} // $a->{break_index} // 0) <=>
        ($b->{confirmation_index} // $b->{break_index} // 0)
    } grep {
        my $type = lc($_->{type} // '');
        my $scope = $_->{scope} // 'external';
        my $idx = $_->{confirmation_index} // $_->{break_index};
        defined $idx && $idx <= $max_idx
            && (($settings->{structure_event} eq 'both') || $type eq $settings->{structure_event})
            && (($settings->{structure_scope} eq 'both') || $scope eq $settings->{structure_scope})
            && (($_->{status} // 'confirmed') eq 'confirmed' || $_->{confirmed})
    } @{ $args{structure_events} // [] };

    my @ranges;
    for my $i (0 .. $#events) {
        my $start = $events[$i]{confirmation_index} // $events[$i]{break_index};
        my $end = $i < $#events
            ? (($events[$i + 1]{confirmation_index} // $events[$i + 1]{break_index}) - 1)
            : $max_idx;
        next if $end < $start;
        push @ranges, _range_hash(
            $start, $end, 'structure', $candles, $i < $#events ? 1 : 0, 0,
            {
                event_id => $events[$i]{id},
                event_type => $events[$i]{type},
                event_scope => $events[$i]{scope} // 'external',
            },
        );
    }

    return [ grep { $_->{end_index} >= $visible_start } @ranges ];
}

sub _zigzag_ranges {
    my (%args) = @_;
    my $candles = $args{candles};
    my $max_idx = $args{max_idx};
    my $visible_start = defined $args{visible_start} ? $args{visible_start} : 0;
    my $zigzag = $args{zigzag} // {};
    my @segments = @{ $zigzag->{segments} // [] };
    push @segments, $zigzag->{active_segment} if $zigzag->{active_segment};

    my @ranges;
    for my $seg (@segments) {
        my $start = $seg->{start_index};
        my $end   = $seg->{end_index};
        next unless defined $start && defined $end;
        next if $start > $max_idx;
        $end = $max_idx if $end > $max_idx;
        next if $end < $start;
        push @ranges, _range_hash(
            $start, $end, 'zigzag', $candles,
            ($seg->{completed_at} && $seg->{completed_at} <= $max_idx) ? 1 : 0,
            0,
            {
                direction => $seg->{direction},
                start_price => $seg->{start_price},
                end_price => $seg->{end_price},
                active_profile => $seg->{volume_profile_active} ? 1 : 0,
            },
        );
    }

    return [ grep { $_->{end_index} >= $visible_start } @ranges ];
}

sub _fallback_range {
    my (%args) = @_;
    my $candles = $args{candles};
    my $max_idx = $args{max_idx};
    my $visible_start = defined $args{visible_start} ? $args{visible_start} : 0;
    my $lookback = $args{settings}{fallback_lookback} || 500;
    my $start = $visible_start < $max_idx ? $visible_start : max(0, $max_idx - $lookback + 1);
    $start = max(0, $max_idx - $lookback + 1) if ($max_idx - $start + 1) < $args{settings}{min_bars};
    return _range_hash(
        $start, $max_idx, 'historical_fallback', $candles, 0, 1,
        { fallback_reason => $args{reason} // 'historical_context' },
    );
}

sub _range_hash {
    my ($start, $end, $mode, $candles, $confirmed, $fallback, $meta) = @_;
    $meta //= {};
    return {
        start_index => $start,
        end_index   => $end,
        start_time  => $candles->[$start]{time},
        end_time    => $candles->[$end]{time},
        mode        => $mode,
        confirmed   => $confirmed ? 1 : 0,
        fallback    => $fallback ? 1 : 0,
        metadata    => $meta,
    };
}

sub _build_profile {
    my ($candles, $range, $settings, $seq) = @_;
    my ($start, $end) = ($range->{start_index}, $range->{end_index});
    my ($lo, $hi);

    for my $i ($start .. $end) {
        my $c = $candles->[$i] // next;
        next unless defined $c->{high} && defined $c->{low};
        $lo = defined $lo ? min($lo, $c->{low}) : $c->{low};
        $hi = defined $hi ? max($hi, $c->{high}) : $c->{high};
    }
    return undef unless defined $lo && defined $hi;

    my $bins_count = $settings->{number_of_bins};
    my $range_size = $hi - $lo;
    $range_size = 1e-9 if $range_size <= 0;
    my $bin_size = $range_size / $bins_count;

    my @bins;
    for my $b (0 .. $bins_count - 1) {
        my $b_lo = $lo + $bin_size * $b;
        my $b_hi = $b == $bins_count - 1 ? $hi : $b_lo + $bin_size;
        push @bins, {
            bin_index => $b,
            lower     => sprintf('%.10f', $b_lo) + 0,
            upper     => sprintf('%.10f', $b_hi) + 0,
            center    => sprintf('%.10f', ($b_lo + $b_hi) / 2) + 0,
            volume    => 0,
            buy_volume => 0,
            sell_volume => 0,
            percent   => 0,
            buy_percent => 0,
            sell_percent => 0,
            buy_ratio => 0,
            sell_ratio => 0,
            max_contribution => 0,
            max_contribution_index => undef,
        };
    }

    my $total = 0;
    for my $i ($start .. $end) {
        my $c = $candles->[$i] // next;
        my $v = $c->{volume};
        next unless defined $v && $v > 0;
        next unless defined $c->{high} && defined $c->{low};

        my $cl = min($c->{low}, $c->{high});
        my $ch = max($c->{low}, $c->{high});
        if ($ch == $cl) {
            my $idx = _bin_index_for_price($cl, $lo, $range_size, $bins_count);
            my $buy_ratio = _buy_volume_ratio($c);
            my $buy = $v * $buy_ratio;
            my $sell = $v - $buy;
            _add_bin_volume($bins[$idx], $v, $i, $buy, $sell);
            $total += $v;
            next;
        }

        my $candle_range = $ch - $cl;
        my $buy_ratio = _buy_volume_ratio($c);
        for my $bin (@bins) {
            my $overlap = min($ch, $bin->{upper}) - max($cl, $bin->{lower});
            next unless $overlap > 0;
            my $allocated = $v * ($overlap / $candle_range);
            my $buy = $allocated * $buy_ratio;
            my $sell = $allocated - $buy;
            _add_bin_volume($bin, $allocated, $i, $buy, $sell);
            $total += $allocated;
        }
    }
    return undef unless $total > 0;

    my $poc_idx = 0;
    for my $b (1 .. $#bins) {
        $poc_idx = $b if $bins[$b]{volume} > $bins[$poc_idx]{volume};
    }
    for my $bin (@bins) {
        my $row_volume = $bin->{volume};
        $bin->{volume}  = sprintf('%.4f', $bin->{volume}) + 0;
        $bin->{buy_volume}  = sprintf('%.4f', $bin->{buy_volume}) + 0;
        $bin->{sell_volume} = sprintf('%.4f', $bin->{sell_volume}) + 0;
        $bin->{percent} = sprintf('%.6f', ($bin->{volume} / $total) * 100) + 0;
        $bin->{buy_percent} = sprintf('%.6f', ($bin->{buy_volume} / $total) * 100) + 0;
        $bin->{sell_percent} = sprintf('%.6f', ($bin->{sell_volume} / $total) * 100) + 0;
        $bin->{buy_ratio} = $row_volume > 0 ? sprintf('%.6f', ($bin->{buy_volume} / $row_volume)) + 0 : 0;
        $bin->{sell_ratio} = $row_volume > 0 ? sprintf('%.6f', ($bin->{sell_volume} / $row_volume)) + 0 : 0;
    }

    my $va = _value_area(\@bins, $poc_idx, $total, $settings->{value_area_percent});
    my $poc_bin = $bins[$poc_idx];
    my $anchor_idx = defined $poc_bin->{max_contribution_index}
        ? $poc_bin->{max_contribution_index}
        : $start;

    return {
        id                  => 'VP_' . ($range->{mode} // 'profile') . '_' . $start . '_' . $end . '_' . $seq,
        profile_id          => 'VP_' . ($range->{mode} // 'profile') . '_' . $start . '_' . $end . '_' . $seq,
        profile_mode        => $range->{mode},
        start_index         => $start,
        end_index           => $end,
        start_time          => $range->{start_time},
        end_time            => $range->{end_time},
        profile_start_time  => $range->{start_time},
        profile_end_time    => $range->{end_time},
        confirmed           => $range->{confirmed} ? 1 : 0,
        historical_fallback => $range->{fallback} ? 1 : 0,
        metadata            => $range->{metadata} // {},
        min_price           => sprintf('%.10f', $lo) + 0,
        max_price           => sprintf('%.10f', $hi) + 0,
        total_volume        => sprintf('%.4f', $total) + 0,
        bins                => \@bins,
        poc                 => {
            poc_price     => $poc_bin->{center},
            poc_volume    => $poc_bin->{volume},
            poc_bin_index => $poc_idx,
            poc_time      => $candles->[$anchor_idx]{time},
            poc_bar_index => $anchor_idx,
        },
        poc_price           => $poc_bin->{center},
        poc_volume          => $poc_bin->{volume},
        poc_bin_index       => $poc_idx,
        poc_time            => $candles->[$anchor_idx]{time},
        poc_bar_index       => $anchor_idx,
        vah                 => $va->{vah},
        val                 => $va->{val},
        vah_bin_index       => $va->{high_index},
        val_bin_index       => $va->{low_index},
        value_area_volume   => $va->{volume},
        value_area_percent_actual => $va->{percent_actual},
    };
}

sub _add_bin_volume {
    my ($bin, $volume, $index, $buy_volume, $sell_volume) = @_;
    $bin->{volume} += $volume;
    $bin->{buy_volume} += $buy_volume // 0;
    $bin->{sell_volume} += $sell_volume // 0;
    if ($volume > ($bin->{max_contribution} // 0)) {
        $bin->{max_contribution} = $volume;
        $bin->{max_contribution_index} = $index;
    }
}

sub _buy_volume_ratio {
    my ($c) = @_;
    return 0.5 unless $c && ref($c) eq 'HASH';

    if (defined $c->{high} && defined $c->{low} && defined $c->{close}) {
        my $range = $c->{high} - $c->{low};
        if ($range > 0) {
            my $ratio = ($c->{close} - $c->{low}) / $range;
            return _clamp01($ratio);
        }
    }

    if (defined $c->{open} && defined $c->{close}) {
        return 1 if $c->{close} > $c->{open};
        return 0 if $c->{close} < $c->{open};
    }
    return 0.5;
}

sub _clamp01 {
    my ($v) = @_;
    return 0 if !defined $v || $v < 0;
    return 1 if $v > 1;
    return $v + 0;
}

sub _bin_index_for_price {
    my ($price, $lo, $range_size, $bins_count) = @_;
    my $idx = int((($price - $lo) / $range_size) * $bins_count);
    $idx = 0 if $idx < 0;
    $idx = $bins_count - 1 if $idx >= $bins_count;
    return $idx;
}

sub _value_area {
    my ($bins, $poc_idx, $total, $percent) = @_;
    my $target = $total * ($percent / 100);
    my $low = $poc_idx;
    my $high = $poc_idx;
    my $acc = $bins->[$poc_idx]{volume};

    while ($acc < $target && ($low > 0 || $high < $#$bins)) {
        my $below = $low > 0 ? $bins->[$low - 1]{volume} : -1;
        my $above = $high < $#$bins ? $bins->[$high + 1]{volume} : -1;
        if ($above >= $below) {
            $high++;
            $acc += $bins->[$high]{volume};
        }
        else {
            $low--;
            $acc += $bins->[$low]{volume};
        }
    }

    return {
        low_index      => $low,
        high_index     => $high,
        val            => $bins->[$low]{lower},
        vah            => $bins->[$high]{upper},
        volume         => sprintf('%.4f', $acc) + 0,
        percent_actual => $total > 0 ? sprintf('%.6f', ($acc / $total) * 100) + 0 : 0,
    };
}

sub _poc_contract {
    my ($profile) = @_;
    return {
        id                  => $profile->{profile_id} . '_POC',
        profile_id          => $profile->{profile_id},
        profile_mode        => $profile->{profile_mode},
        profile_start_index => $profile->{start_index},
        profile_start_time  => $profile->{start_time},
        profile_end_index   => $profile->{end_index},
        profile_end_time    => $profile->{end_time},
        poc_price           => $profile->{poc_price},
        poc_volume          => $profile->{poc_volume},
        poc_bin_index       => $profile->{poc_bin_index},
        anchor_index        => $profile->{poc_bar_index},
        anchor_time         => $profile->{poc_time},
        poc_bar_index       => $profile->{poc_bar_index},
        poc_time            => $profile->{poc_time},
        confirmed           => $profile->{confirmed} ? 1 : 0,
        temporal_criterion  => 'vela con mayor contribucion al bin POC del perfil',
    };
}

1;
