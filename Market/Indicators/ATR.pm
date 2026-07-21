package Market::Indicators::ATR;

use strict;
use warnings;
use List::Util qw(max);

sub new {
    my ($class, $period) = @_;
    my $self = {
        period => $period, # Periodo n de la media móvil [cite: 257]
        values => [],      # Almacena la serie completa del ATR [cite: 272]
    };
    bless $self, $class;
    return $self;
}

sub update_last {
    my ($self, $market_data) = @_;
    
    my $current_index = $market_data->last_index();
    return unless defined $current_index;

    my $current_candle = $market_data->get_candle($current_index);
    my $n = $self->{period};
    
    # Cálculo del True Range (TR)
    my $tr;
    if ($current_index == 0) {
        # Para la primera vela, no hay Cierre anterior
        $tr = $current_candle->{high} - $current_candle->{low};
    } else {
        my $prev_candle = $market_data->get_candle($current_index - 1);
        my $hl = $current_candle->{high} - $current_candle->{low};
        my $h_pc = abs($current_candle->{high} - $prev_candle->{close});
        my $l_pc = abs($current_candle->{low} - $prev_candle->{close});
        
        $tr = max($hl, $h_pc, $l_pc);
    }
    
    # Cálculo Incremental del ATR (Suavizado de Wilder)
    my $atr_value;
    
    if ($current_index < $n) {
        # Fase de inicialización: Simple Media (SMA) del TR temporal
        # Para un resultado estricto, sumamos el TR hasta llegar a n
        # Aquí simplificamos asignando el TR directamente si no hay suficientes datos
        $atr_value = $tr; 
    } else {
        # O(1) Cálculo suavizado continuo
        my $prev_atr = $self->{values}->[$current_index - 1];
        $atr_value = (($prev_atr * ($n - 1)) + $tr) / $n;
    }
    
    # Si la vela se está actualizando en vivo (stream), sobreescribimos.
    # Si es una vela nueva, agregamos al vector.
    $self->{values}->[$current_index] = $atr_value;
}

sub get_values {
    my ($self) = @_;
    # Devuelve la serie completa [cite: 262]
    return $self->{values};
}

sub reset {
    my ($self) = @_;
    # Limpia el estado en memoria para un nuevo timeframe [cite: 264]
    $self->{values} = [];
}

sub calculate_batch {
    my ($self, $market_data) = @_;
    my $total = $market_data->size();
    
    for my $current_index (0 .. $total - 1) {
        my $current_candle = $market_data->get_candle($current_index);
        my $n = $self->{period};
        
        my $tr;
        if ($current_index == 0) {
            $tr = $current_candle->{high} - $current_candle->{low};
        } else {
            my $prev_candle = $market_data->get_candle($current_index - 1);
            my $hl = $current_candle->{high} - $current_candle->{low};
            my $h_pc = abs($current_candle->{high} - $prev_candle->{close});
            my $l_pc = abs($current_candle->{low} - $prev_candle->{close});
            $tr = max($hl, $h_pc, $l_pc);
        }
        
        my $atr_value;
        if ($current_index < $n) {
            $atr_value = $tr; 
        } else {
            my $prev_atr = $self->{values}->[$current_index - 1];
            $atr_value = (($prev_atr * ($n - 1)) + $tr) / $n;
        }
        
        $self->{values}->[$current_index] = $atr_value;
    }
}

1;