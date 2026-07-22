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
        $self->{computed_cache}->{SMC_Structures} = $smc_res->{events} // [];
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
        $self->{computed_cache}->{Liquidity} = $liq_res->{levels} // [];
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
        $self->{computed_cache}->{SMC_Structures} = $smc_res->{events} // [];
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
        my $zz_data = $self->{computed_cache}->{ZigZagTrend}
            ? $self->{indicators}->{ZigZagTrend}->compute(candles => $candles, max_visible_index => $max_idx, timeframe => $timeframe)
            : $self->{computed_cache}->{InternalZigZag_raw};
        
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

1;