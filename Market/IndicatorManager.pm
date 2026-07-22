package Market::IndicatorManager;

use strict;
use warnings;

sub new {
    my ($class) = @_;
    my $self = {
        indicators => {}, # Hash para registrar instancias de indicadores
    };
    bless $self, $class;
    return $self;
}

sub register {
    my ($self, $name, $indicator) = @_;
    # Registra un indicador permitiendo extensibilidad [cite: 205, 206]
    $self->{indicators}->{$name} = $indicator;
}

sub update_last {
    my ($self, $market_data) = @_;
    foreach my $name (keys %{ $self->{indicators} }) {
        my $ind = $self->{indicators}->{$name};
        if ($ind->can('update_last')) {
            $ind->update_last($market_data);
        }
    }
}

sub get {
    my ($self, $name) = @_;
    if (exists $self->{computed_cache} && exists $self->{computed_cache}->{$name}) {
        return $self->{computed_cache}->{$name};
    }
    return [] unless exists $self->{indicators}->{$name};
    return $self->{indicators}->{$name}->get_values();
}

sub get_raw {
    my ($self, $name) = @_;
    if (exists $self->{computed_cache} && exists $self->{computed_cache}->{"${name}_raw"}) {
        return $self->{computed_cache}->{"${name}_raw"};
    }
    return undef;
}

sub slice_array {
    my ($self, $name, $start, $end) = @_;
    my $values = $self->get($name);
    return [] unless $values && @$values;
    
    $start = 0 if $start < 0;
    $end = $#{$values} if $end > $#{$values};
    return [] if $start > $end;
    
    return [ @{$values}[$start .. $end] ];
}

sub reset_all {
    my ($self) = @_;
    # Reinicia el estado interno de todos los indicadores al cambiar de timeframe [cite: 215]
    foreach my $name (keys %{ $self->{indicators} }) {
        my $ind = $self->{indicators}->{$name};
        if ($ind->can('reset')) {
            $ind->reset();
        }
    }
    $self->{computed_cache} = {};
}

sub recalculate_all {
    my ($self, $market_data) = @_;
    
    my $max_idx = $market_data->size() - 1;
    return if $max_idx < 0;
    
    my $candles = $market_data->get_slice(0, $max_idx);
    my $timeframe = $market_data->{current_tf} // '1m';
    
    $self->reset_all();
    $self->{computed_cache} = {};
    
    # -- 1. ATR --
    if (exists $self->{indicators}->{ATR}) {
        my $atr_ind = $self->{indicators}->{ATR};
        for my $i (0 .. $max_idx) {
            $atr_ind->update_last($market_data);
        }
        $self->{computed_cache}->{ATR} = $atr_ind->get_values();
    }
    my $atr_series = $self->{computed_cache}->{ATR} // [];
    
    # -- 2. ZigZagTrend --
    if (exists $self->{indicators}->{ZigZagTrend}) {
        my $zz_ind = $self->{indicators}->{ZigZagTrend};
        my $res = $zz_ind->compute(
            candles => $candles,
            max_visible_index => $max_idx,
            timeframe => $timeframe,
        );
        $self->{computed_cache}->{ZigZagTrend} = $res->{values} // $zz_ind->get_values();
    }
    
    # -- 3. InternalZigZag --
    if (exists $self->{indicators}->{InternalZigZag}) {
        my $izz_ind = $self->{indicators}->{InternalZigZag};
        my $res = $izz_ind->compute(
            candles => $candles,
            atr_series => $atr_series,
            max_visible_index => $max_idx,
            timeframe => $timeframe,
        );
        $self->{computed_cache}->{InternalZigZag_raw} = $res;
        $self->{computed_cache}->{InternalZigZag} = $res->{pivots} // [];
    }
    
    # -- 4. PivotMissedReversal --
    if (exists $self->{indicators}->{PivotMissedReversal}) {
        my $pmr_ind = $self->{indicators}->{PivotMissedReversal};
        my $res = $pmr_ind->compute(
            candles => $candles,
            max_visible_index => $max_idx,
            timeframe => $timeframe,
        );
        $self->{computed_cache}->{PivotMissedReversal_raw} = $res;
        $self->{computed_cache}->{PivotMissedReversal} = $res->{regularPivots} // [];
    }
    
    # -- 5. SMC_Structures --
    my $smc_res;
    if (exists $self->{indicators}->{SMC_Structures}) {
        my $smc_ind = $self->{indicators}->{SMC_Structures};
        $smc_res = $smc_ind->compute(
            candles => $candles,
            atr_series => $atr_series,
            max_visible_index => $max_idx,
            timeframe => $timeframe,
            liquidity_events => [],
        );
        $self->{computed_cache}->{SMC_Structures_raw} = $smc_res;
        $self->{computed_cache}->{SMC_Structures} = $self->_build_smc_candles_array($smc_res, $max_idx);
    }
    
    # -- 6. Liquidity --
    my $liq_res;
    if (exists $self->{indicators}->{Liquidity}) {
        my $liq_ind = $self->{indicators}->{Liquidity};
        $liq_res = $liq_ind->compute(
            candles => $candles,
            atr_series => $atr_series,
            max_visible_index => $max_idx,
            timeframe => $timeframe,
            structure_events => $smc_res ? ($smc_res->{structures} // []) : [],
            pivots => $smc_res ? ($smc_res->{pivots} // []) : [],
        );
        $self->{computed_cache}->{Liquidity_raw} = $liq_res;
        $self->{computed_cache}->{Liquidity} = $self->_build_liquidity_candles_array($liq_res, $max_idx);
    }
    
    # -- Recompute SMC_Structures passing Liquidity events --
    if (exists $self->{indicators}->{SMC_Structures} && $liq_res) {
        my $smc_ind = $self->{indicators}->{SMC_Structures};
        $smc_res = $smc_ind->compute(
            candles => $candles,
            atr_series => $atr_series,
            max_visible_index => $max_idx,
            timeframe => $timeframe,
            liquidity_events => $liq_res->{events} // [],
        );
        $self->{computed_cache}->{SMC_Structures_raw} = $smc_res;
        $self->{computed_cache}->{SMC_Structures} = $self->_build_smc_candles_array($smc_res, $max_idx);
    }
    
    # -- 7. MarketRegime --
    if (exists $self->{indicators}->{MarketRegime}) {
        my $mr_ind = $self->{indicators}->{MarketRegime};
        my $res = $mr_ind->compute(
            candles => $candles,
            atr_series => $atr_series,
            liquidity_levels => $liq_res ? ($liq_res->{levels} // []) : [],
            liquidity_events => $liq_res ? ($liq_res->{events} // []) : [],
            structure_events => $smc_res ? ($smc_res->{structures} // []) : [],
            pivots           => $smc_res ? ($smc_res->{pivots} // []) : [],
            max_visible_index => $max_idx,
            timeframe => $timeframe,
        );
        $self->{computed_cache}->{MarketRegime_raw} = $res;
        $self->{computed_cache}->{MarketRegime} = $res;
    }
    
    # -- 8. ZonaInterna --
    if (exists $self->{indicators}->{ZonaInterna}) {
        my $zi_ind = $self->{indicators}->{ZonaInterna};
        my $zz_data = $self->{computed_cache}->{InternalZigZag_raw};
        if (!$zz_data || !ref($zz_data->{segments}) || scalar(@{$zz_data->{segments}}) < 1) {
            $zz_data = $self->{computed_cache}->{ZigZagTrend_raw};
        }
        
        my $res = $zi_ind->compute(
            zigzag => $zz_data,
            max_visible_index => $max_idx,
            timeframe => $timeframe,
        );
        $self->{computed_cache}->{ZonaInterna_raw} = $res;
        $self->{computed_cache}->{ZonaInterna} = $res->{levels} // [];
    }
    
    # Legacy fallbacks for any custom indicators
    foreach my $name (keys %{ $self->{indicators} }) {
        next if grep { $_ eq $name } qw(ATR ZigZagTrend InternalZigZag PivotMissedReversal SMC_Structures Liquidity MarketRegime ZonaInterna);
        my $ind = $self->{indicators}->{$name};
        if ($ind->can('calculate_batch')) {
            $ind->calculate_batch($market_data);
        }
    }
}

sub _build_smc_candles_array {
    my ($self, $smc_res, $max_idx) = @_;
    return [] unless $smc_res;

    my @smc_candles;
    for my $i (0 .. $max_idx) {
        $smc_candles[$i] = {
            events      => [],
            fvgs        => [],
            active_fvgs => [],
            state       => 'none',
            price       => 0,
        };
    }

    # 1. Mapear BOS, CHOCH, MSS events
    if (exists $smc_res->{structures} && ref($smc_res->{structures}) eq 'ARRAY') {
        for my $st (@{ $smc_res->{structures} }) {
            my $break_idx = $st->{break_index};
            if (defined $break_idx && $break_idx >= 0 && $break_idx <= $max_idx) {
                push @{ $smc_candles[$break_idx]->{events} }, {
                    %$st,
                    origin => $st->{pivot_index},
                    dir    => $st->{direction},
                };
            }
        }
    }

    # 2. Mapear Pivots (HH, HL, LH, LL)
    if (exists $smc_res->{pivots} && ref($smc_res->{pivots}) eq 'ARRAY') {
        for my $p (@{ $smc_res->{pivots} }) {
            my $idx = $p->{index};
            if (defined $idx && $idx >= 0 && $idx <= $max_idx && defined $p->{label}) {
                $smc_candles[$idx]->{state} = $p->{label};
                $smc_candles[$idx]->{price} = $p->{price};
            }
        }
    }

    # 3. Mapear Fair Value Gaps (FVG)
    if (exists $smc_res->{fvgs} && ref($smc_res->{fvgs}) eq 'ARRAY') {
        for my $fvg (@{ $smc_res->{fvgs} }) {
            my $start_fvg = $fvg->{start_index};
            if (defined $start_fvg && $start_fvg >= 0 && $start_fvg <= $max_idx) {
                my $mapped_fvg = {
                    %$fvg,
                    start_idx     => $fvg->{start_index},
                    mitigated_idx => $fvg->{mitigated_index},
                    top           => $fvg->{gap_high},
                    bottom        => $fvg->{gap_low},
                    type          => $fvg->{direction} eq 'bullish' ? 'bullish_fvg' : 'bearish_fvg',
                };
                
                push @{ $smc_candles[$start_fvg]->{fvgs} }, $mapped_fvg;
                
                my $end_fvg = $fvg->{mitigated_index} // $max_idx;
                $end_fvg = $max_idx if $end_fvg > $max_idx;
                for my $k ($start_fvg .. $end_fvg) {
                    push @{ $smc_candles[$k]->{active_fvgs} }, $mapped_fvg;
                }
            }
        }
    }

    return \@smc_candles;
}

# ---------------------------------------------------------------------------
# Transforma el resultado crudo de Liquidity (una lista de niveles + una lista
# de eventos) en un array paralelo a las velas (indexado por índice absoluto de
# vela, 0..$max_idx), que es la forma que espera Overlays::Liquidity —
# exactamente igual que _build_smc_candles_array hace para SMC_Structures.
#
# Cada slot tiene la estructura:
#   { state, price, end_index, resolution, events }
# donde:
#   state      -> 'swing_high'|'swing_low'|'eqh'|'eql'|'none'  (tipo de nivel)
#   price      -> precio del nivel de liquidez
#   end_index  -> índice ABSOLUTO de vela donde la línea termina (resolución, o
#                 el borde derecho $max_idx si el nivel sigue activo)
#   resolution -> 'active'|'sweep'|'grab'|'run'                (status del nivel)
#   events     -> [ { type => 'sweep_up'|'sweep_down'|'grab_up'|..., price } ]
# ---------------------------------------------------------------------------
sub _build_liquidity_candles_array {
    my ($self, $liq_res, $max_idx) = @_;
    return [] unless $liq_res;

    my @liq_candles;
    for my $i (0 .. $max_idx) {
        $liq_candles[$i] = {
            state      => 'none',
            price      => 0,
            end_index  => undef,
            resolution => '',
            events     => [],
        };
    }

    # Tipo de nivel (BSL/SSL/EQH/EQL) -> estado que dibuja el overlay
    my %state_of = (BSL => 'swing_high', SSL => 'swing_low', EQH => 'eqh', EQL => 'eql');
    # Status del nivel -> texto/estilo de resolución del overlay
    my %res_of = (
        ACTIVE     => 'active',
        SWEPT      => 'sweep',
        GRABBED    => 'grab',
        RUN        => 'run',
        BROKEN     => 'run',
        ACCEPTANCE => 'active',
    );

    # 1. Cada nivel se ancla en la vela de su pivote de origen (donde nace el
    #    nivel) y se extiende como línea horizontal hasta su vela de resolución.
    if (ref($liq_res->{levels}) eq 'ARRAY') {
        for my $lv (@{ $liq_res->{levels} }) {
            my $type  = $lv->{type} // next;
            my $state = $state_of{$type} // next;

            my $slot = $lv->{first_pivot_index} // $lv->{pivot_index} // $lv->{start_index};
            next unless defined $slot && $slot >= 0 && $slot <= $max_idx;

            # Fin de la línea: vela de resolución, o el borde derecho si sigue activo.
            my $end = $lv->{end_index} // $max_idx;
            $end = $max_idx if $end > $max_idx;
            $end = $slot    if $end < $slot;

            $liq_candles[$slot]->{state}      = $state;
            $liq_candles[$slot]->{price}      = $lv->{price} // $lv->{basePrice} // $lv->{base_price} // 0;
            $liq_candles[$slot]->{end_index}  = $end;
            $liq_candles[$slot]->{resolution} = $res_of{ $lv->{status} // 'ACTIVE' } // 'active';
        }
    }

    # 2. Eventos (sweep/grab/run) flotan sobre la vela donde se dispararon.
    #    classification -> base del tipo de evento que el overlay reconoce.
    if (ref($liq_res->{events}) eq 'ARRAY') {
        my %base_of = (SWEEP => 'sweep', GRAB => 'grab', BIG_GRAB => 'grab', RUN => 'run');
        for my $ev (@{ $liq_res->{events} }) {
            my $base = $base_of{ $ev->{classification} // '' } // next;
            my $dir  = $ev->{direction} // '';
            next unless $dir eq 'up' || $dir eq 'down';

            my $trig = $ev->{swept_index} // $ev->{resolved_index};
            next unless defined $trig && $trig >= 0 && $trig <= $max_idx;

            push @{ $liq_candles[$trig]->{events} }, {
                type  => "${base}_${dir}",
                price => $ev->{swept_price} // $ev->{level_price} // 0,
            };
        }
    }

    return \@liq_candles;
}

1;