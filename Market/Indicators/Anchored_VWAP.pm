package Market::Indicators::Anchored_VWAP;

use strict;
use warnings;
use List::Util qw(max);

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

sub get_anchors {
    my ($self) = @_;
    my $res = $self->{last_result};
    return [] unless $res && $res->{segments};
    
    my @mapped;
    for my $seg (@{ $res->{segments} }) {
        my @vals = map { $_->{value} } @{ $seg->{points} // [] };
        push @mapped, {
            anchor_type => $seg->{anchor_type} // 'missedPivotAuto',
            start_idx   => $seg->{start_index},
            end_idx     => $seg->{end_index},
            vwap_values => \@vals,
        };
    }
    return \@mapped;
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

sub calculate_for_window_new {
    my ($self, $market_data, $start, $end, $full_smc, $vp_profs, $pmr_raw, $vis) = @_;
    
    my $max_idx = $market_data->size() - 1;
    my $candles = $market_data->get_slice(0, $max_idx);
    my $tf = $market_data->{current_tf} // '1m';
    
    my @all_segments;
    my @all_anchors;
    my @all_instances;

    # 1. Automatic VWAP
    if ($vis->{vwap_auto_missed_pivot}) {
        my $settings = {
            show => 1,
            hide_on_1d_or_above => $vis->{vwap_auto_hide_1d} // 0,
            context_bars => $self->{context_bars},
        };
        
        my $pmr_events = $pmr_raw ? ($pmr_raw->{regularPivots} // []) : [];
        my @mapped_events = map {
            my %c = %$_;
            $c{kind} = 'missedPivot';
            $c{confirmed} = 1;
            \%c
        } @$pmr_events;
        
        my $pmr_provisional = $pmr_raw ? $pmr_raw->{provisionalPivot} : undef;
        
        my $auto_res = $self->compute_missed_pivot_auto(
            candles => $candles,
            max_visible_index => $end,
            timeframe => $tf,
            events => \@mapped_events,
            provisionalPivot => $pmr_provisional,
            settings => $settings,
        );
        
        if ($auto_res->{visible}) {
            push @all_segments, @{ $auto_res->{segments} // [] };
            push @all_anchors, @{ $auto_res->{anchors} // [] };
            push @all_instances, @{ $auto_res->{instances} // [] };
        }
    }

    # 2. Manual VWAP
    if ($vis->{vwap_manual_show}) {
        my $manual_time = $vis->{vwap_manual_anchor_time};
        if ($manual_time) {
            my $settings = {
                show               => 1,
                anchor_type        => 'manual',
                manual_anchor_time => $manual_time,
                context_bars       => $self->{context_bars},
            };
            my $manual_res = $self->compute(
                candles           => $candles,
                max_visible_index => $end,
                timeframe         => $tf,
                settings          => $settings,
            );
            if ($manual_res->{visible}) {
                for my $seg (@{ $manual_res->{segments} // [] }) {
                    $seg->{namespace} = 'manualAvwap';
                    push @all_segments, $seg;
                }
                for my $anc (@{ $manual_res->{anchors} // [] }) {
                    $anc->{namespace} = 'manualAvwap';
                    push @all_anchors, $anc;
                }
                push @all_instances, {
                    id => 'MANUAL_AVWAP_1',
                    namespace => 'manualAvwap',
                    anchorIndex => $manual_res->{anchors}[0]{index},
                    anchorTime => $manual_res->{anchors}[0]{time},
                    segments => $manual_res->{segments},
                    vwap_values => [ map { $_->{value} } @{ $manual_res->{segments}[0]{points} // [] } ],
                };
            }
        }
    }

    $self->{last_result} = {
        visible => (@all_segments > 0) ? 1 : 0,
        segments => \@all_segments,
        anchors => \@all_anchors,
        instances => \@all_instances,
    };
    
    return $self->{last_result};
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

    $max_idx = $#$candles unless defined $max_idx;
    $max_idx = $#$candles if $max_idx > $#$candles;

    return _empty_auto_result($settings, $tf, 'desactivado') unless $settings->{show};
    return _empty_auto_result($settings, $tf, 'sin datos suficientes') if $max_idx < 0;

    my @confirmed = grep { _is_confirmed_missed_pivot($_, $candles, $max_idx, $tf, $symbol) } @$events;
    my $provisional = _eligible_provisional_ghost($provisional_raw, $candles, $max_idx, $tf, $symbol);
    my $latest_ghost = _select_latest_ghost(\@confirmed, $provisional);
    
    my (@segments, @anchors, @instances);

    for my $ev (grep { defined } $latest_ghost) {
        my $anchor_idx = _event_anchor_index($ev, $candles, $max_idx, $tf);
        next unless defined $anchor_idx && $anchor_idx >= 0 && $anchor_idx <= $max_idx;

        my $anchor_time = $candles->[$anchor_idx]{time} // _event_pivot_time($ev);
        next unless defined $anchor_time && length $anchor_time;

        my $event_id = _missed_pivot_auto_event_id($symbol, $tf, $ev);
        
        my @anchored_candles = @{ $candles }[$anchor_idx .. $max_idx];
        my $anchored_max_idx = $#anchored_candles;

        my $manual_settings = { %$settings, show => 1, anchor_type => 'manual', manual_anchor_time => $anchor_time };
        my $avwap = __PACKAGE__->compute(
            candles           => \@anchored_candles,
            max_visible_index => $anchored_max_idx,
            timeframe         => $tf,
            settings          => $manual_settings,
        );
        next unless $avwap->{visible};
        _shift_avwap_result_indices($avwap, $anchor_idx);

        for my $seg (@{ $avwap->{segments} // [] }) {
            $seg->{namespace} = 'missedPivotAutoAvwap';
            push @segments, $seg;
        }
        for my $anchor (@{ $avwap->{anchors} // [] }) {
            $anchor->{namespace} = 'missedPivotAutoAvwap';
            push @anchors, $anchor;
        }
        push @instances, {
            id => $event_id,
            namespace => 'missedPivotAutoAvwap',
            anchorIndex => $anchor_idx,
            segments => $avwap->{segments},
        };
    }

    return {
        settings => $settings, timeframe => $tf,
        visible => @segments ? 1 : 0,
        segments => \@segments, anchors => \@anchors, instances => \@instances,
    };
}

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles    = $args{candles}    or die 'Anchored_VWAP::compute: falta candles';
    my $max_idx    = $args{max_visible_index};
    $max_idx = $#$candles unless defined $max_idx;
    $max_idx = $#$candles if $max_idx > $#$candles;
    
    my $tf         = $args{timeframe}  // '1m';
    my $settings   = _normalize_settings($args{settings} // {});
    my $structures = $args{structure_events} // [];
    my $zigzag     = $args{zigzag};
    my $poc_events = $args{poc_events} // [];

    return _empty_result($settings, 'desactivado') unless $settings->{show};
    return _empty_result($settings, 'sin datos suficientes') if $max_idx < 0;

    my $has_volume = 0;
    for my $i (0 .. $max_idx) {
        if (($candles->[$i]{volume} // 0) > 0) { $has_volume = 1; last; }
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
    
    my $sum_pv = 0;
    my $sum_v = 0;
    my $sum_v_d2 = 0;
    my @prices;
    my @volumes;

    my $manual_mode = ($settings->{anchor_type} // '') eq 'manual' ? 1 : 0;
    return _empty_result($settings, 'sin ancla manual visible') if $manual_mode && !%$anchor_map;

    for my $i (0 .. $max_idx) {
        my $c = $candles->[$i];
        my $anchor = $anchor_map->{$i};
        next if $manual_mode && !$current && !$anchor;

        if ($anchor || !$current) {
            push @segments, $current if $current && @{ $current->{points} };
            $current = _new_segment($i, $c, $settings, $anchor);
            $sum_pv = 0;
            $sum_v = 0;
            @prices = ();
            @volumes = ();
        }

        my $price = _source_price($c, $settings->{source});
        my $vol   = $c->{volume} // 0;
        
        if (!defined $price || $vol <= 0) {
            next;
        }

        $sum_pv += $price * $vol;
        $sum_v += $vol;
        
        push @prices, $price;
        push @volumes, $vol;

        my $vwap = $sum_v > 0 ? $sum_pv / $sum_v : $price;
        
        # Calculate standard deviation if needed
        my $variance = 0;
        if ($sum_v > 0) {
            my $sum_diff_sq = 0;
            for my $j (0 .. $#prices) {
                my $d = $prices[$j] - $vwap;
                $sum_diff_sq += $volumes[$j] * $d * $d;
            }
            $variance = $sum_diff_sq / $sum_v;
        }
        my $stdev = $variance > 0 ? sqrt($variance) : 0;

        my $point = {
            index             => $i,
            time              => $c->{time},
            source_price      => sprintf('%.10f', $price) + 0,
            volume            => sprintf('%.4f', $vol) + 0,
            cumulative_volume => sprintf('%.4f', $sum_v) + 0,
            value             => sprintf('%.10f', $vwap) + 0,
            stdev             => sprintf('%.10f', $stdev) + 0,
        };

        for my $band (@{ $settings->{bands} }) {
            next unless $band->{show};
            my $n = $band->{number};
            my $m = $band->{multiplier};
            $point->{"upper$n"} = sprintf('%.10f', $vwap + $m * $stdev) + 0;
            $point->{"lower$n"} = sprintf('%.10f', $vwap - $m * $stdev) + 0;
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
        segments        => \@segments,
        anchors         => [ sort { ($a->{index} // 0) <=> ($b->{index} // 0) } values %$anchor_map ],
    };
}

sub _normalize_settings {
    my ($raw) = @_;
    my $source = lc($raw->{source} // 'hlc3');
    $source = 'hlc3' unless $SOURCE_KEYS{$source};

    my $anchor = lc($raw->{anchor_type} // $raw->{anchor} // 'session_start');
    $anchor = 'session_start' unless $ANCHOR_KEYS{$anchor};

    my $scope = lc($raw->{scope} // 'external');
    $scope = 'external' unless $SCOPE_KEYS{$scope};

    my @bands;
    for my $n (1 .. 3) {
        my $show = $raw->{"show_band$n"} // ($n == 1 ? 1 : 0);
        push @bands, {
            number     => $n,
            show       => $show,
            multiplier => $raw->{"band${n}_multiplier"} // $n,
        };
    }

    return {
        show               => $raw->{show} // 1,
        source             => $source,
        anchor_type        => $anchor,
        scope              => $scope,
        bands              => \@bands,
        manual_anchor_time => $raw->{manual_anchor_time},
        context_bars       => $raw->{context_bars} // 500,
    };
}

sub _empty_result {
    my ($settings, $warning) = @_;
    return {
        settings => $settings, visible => 0, warning => $warning,
        segments => [], anchors => []
    };
}

sub _empty_auto_result {
    my ($settings, $tf, $warning) = @_;
    return {
        settings => $settings, timeframe => $tf, visible => 0,
        warning => $warning, segments => [], anchors => [], instances => []
    };
}

sub _source_price {
    my ($c, $source) = @_;
    my ($o, $h, $l, $c_pr) = ($c->{open}, $c->{high}, $c->{low}, $c->{close});
    return undef unless defined $o && defined $h && defined $l && defined $c_pr;

    if ($source eq 'hlc3') { return ($h + $l + $c_pr) / 3; }
    if ($source eq 'hl2')  { return ($h + $l) / 2; }
    if ($source eq 'ohlc4'){ return ($o + $h + $l + $c_pr) / 4; }
    return $c->{$source};
}

sub _new_segment {
    my ($i, $c, $settings, $anchor) = @_;
    my $reason = $anchor ? $anchor->{reason} : 'default';
    return {
        id           => 'AVWAP_SEG_' . $i,
        start_index  => $i,
        start_time   => $c->{time},
        end_index    => $i,
        end_time     => $c->{time},
        anchor_type  => $settings->{anchor_type},
        reason       => $reason,
        points       => [],
    };
}

sub _anchor_map {
    my %args = @_;
    my ($candles, $max_idx, $tf, $settings, $structures, $zigzag, $poc_events) =
        @args{qw(candles max_idx timeframe settings structures zigzag poc_events)};

    my $anchor_type = $settings->{anchor_type};
    my $ctx_bars = $settings->{context_bars} // 500;
    my %map;
    
    my $start_idx = $max_idx - $ctx_bars;
    $start_idx = 0 if $start_idx < 0;

    if ($anchor_type eq 'session_start') {
        my $last_date = '';
        for my $i ($start_idx .. $max_idx) {
            my $t = $candles->[$i]{time};
            next unless $t;
            my ($date) = $t =~ /^(\d{4}-\d{2}-\d{2})/;
            if ($date && $date ne $last_date) {
                $map{$i} = { index => $i, time => $t, type => $anchor_type, reason => 'new_day' };
                $last_date = $date;
            }
        }
    }
    elsif ($anchor_type eq 'manual') {
        my $target = $settings->{manual_anchor_time};
        if ($target) {
            for my $i (0 .. $max_idx) {
                if (($candles->[$i]{time} // '') eq $target) {
                    $map{$i} = { index => $i, time => $candles->[$i]{time}, type => 'manual', reason => 'manual_match' };
                    last;
                }
            }
        }
    }

    return \%map;
}

sub _event_time_sort_key { $_[0] // '' }

sub _missed_pivot_auto_event_id {
    my ($symbol, $tf, $ev) = @_;
    my $base = $ev->{id} // $ev->{original_id} // 'UNK';
    return join(':', 'auto-avwap', $symbol // 'DEFAULT', $tf // '1m', $base);
}

sub _missed_pivot_auto_instance_id {
    my ($symbol, $tf, $event_id) = @_;
    return join(':', 'auto-avwap', $symbol // 'DEFAULT', $tf // '1m', $event_id // 'unknown');
}

sub _event_pivot_time { $_[0]->{time} }
sub _event_confirmation_time { $_[0]->{confirmed_time} // $_[0]->{confirmation_time} }
sub _event_is_provisional { 0 }
sub _event_confirmation_index { $_[0]->{confirmed_at} }
sub _is_daily_or_above { $_[0] =~ /^[1-9]\d*[dwM]/i }

sub _shift_avwap_result_indices {
    my ($avwap, $delta) = @_;
    return $avwap unless $avwap && $delta;

    for my $anchor (@{ $avwap->{anchors} // [] }) {
        $anchor->{index} += $delta if defined $anchor->{index};
    }
    for my $seg (@{ $avwap->{segments} // [] }) {
        $seg->{start_index} += $delta if defined $seg->{start_index};
        $seg->{end_index}   += $delta if defined $seg->{end_index};
        for my $pt (@{ $seg->{points} // [] }) {
            $pt->{index} += $delta if defined $pt->{index};
        }
    }
    return $avwap;
}

sub _is_confirmed_missed_pivot {
    my ($ev, $candles, $max_idx, $tf, $symbol) = @_;
    return 1;
}

sub _eligible_provisional_ghost {
    my ($prov, $candles, $max_idx, $tf, $symbol) = @_;
    return $prov;
}

sub _select_latest_ghost {
    my ($confirmed_ref, $provisional) = @_;
    my @valid = @$confirmed_ref;
    push @valid, $provisional if $provisional;
    return @valid ? $valid[-1] : undef;
}

sub _event_anchor_index {
    my ($ev, $candles, $max_idx, $tf) = @_;
    my $target_time = $ev->{time};
    return undef unless $target_time;
    for my $i (0 .. $max_idx) {
        return $i if ($candles->[$i]{time} // '') eq $target_time;
    }
    return undef;
}

1;
