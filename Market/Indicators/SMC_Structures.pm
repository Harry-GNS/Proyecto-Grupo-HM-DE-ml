package Market::Indicators::SMC_Structures;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        depth => $args{depth} || 3, # k=3 para los pivotes estructurales
        data  => [],
    };
    bless $self, $class;
    return $self;
}

sub calculate {
    my ($self, $market_data) = @_;
    my $size = $market_data->size();
    my $k = $self->{depth};

    $self->{data} = [];
    
    # Inicialización del arreglo
    for (0 .. $size - 1) {
        push @{$self->{data}}, {
            state  => 'none', # Guardará HH, HL, LH, LL
            events => [],     # Guardará BOS, CHOCH
            fvgs   => [],     # Guardará los Fair Value Gaps detectados aquí
            active_fvgs => [],
        };
    }

    # =========================================================================
    # 1. DETECCIÓN DE FAIR VALUE GAPS (FVG) Y SU MITIGACIÓN
    # =========================================================================
    my @active_fvgs;
    for my $i (2 .. $size - 1) {
        my $c1 = $market_data->get_candle($i - 2);
        my $c2 = $market_data->get_candle($i - 1);
        my $c3 = $market_data->get_candle($i);

        # Bullish FVG (El Low de la vela 3 es mayor al High de la vela 1)
        if ($c3->{low} > $c1->{high}) {
            my $fvg = { type => 'bullish_fvg', top => $c3->{low}, bottom => $c1->{high}, start_idx => $i - 1, mitigated_idx => undef };
            push @{$self->{data}->[$i - 1]->{fvgs}}, $fvg;
            push @active_fvgs, $fvg;
        }
        # Bearish FVG (El High de la vela 3 es menor al Low de la vela 1)
        elsif ($c3->{high} < $c1->{low}) {
            my $fvg = { type => 'bearish_fvg', top => $c1->{low}, bottom => $c3->{high}, start_idx => $i - 1, mitigated_idx => undef };
            push @{$self->{data}->[$i - 1]->{fvgs}}, $fvg;
            push @active_fvgs, $fvg;
        }

        # Mitigación de FVG: Si el precio posterior rellena el bloque activo
        my @remaining_fvgs;
        for my $fvg (@active_fvgs) {
            my $mitigated = 0;
            
            # SOLUCIÓN: Solo evaluar si la vela actual es estrictamente 
            # posterior a la vela de confirmación del FVG.
            if ($i > $fvg->{start_idx} + 1) {
                if ($fvg->{type} eq 'bullish_fvg' && $c3->{low} <= $fvg->{top}) {
                    $fvg->{mitigated_idx} = $i; 
                    $mitigated = 1;
                }
                elsif ($fvg->{type} eq 'bearish_fvg' && $c3->{high} >= $fvg->{bottom}) {
                    $fvg->{mitigated_idx} = $i;
                    $mitigated = 1;
                }
            }
            
            push @remaining_fvgs, $fvg if !$mitigated;
        }
        @active_fvgs = @remaining_fvgs;
        # Propaga los FVGs activos a la vela actual para que el Overlay pueda verlos
        $self->{data}->[$i]->{active_fvgs} = [ @active_fvgs ];
    }

    # =========================================================================
    # 2. DETECCIÓN DE ESTRUCTURA Y MÁQUINA DE ESTADOS (HH, HL, LH, LL)
    # =========================================================================
    my $last_high = undef;
    my $last_low  = undef;

    for my $i ($k .. $size - $k - 1) {
        my $current = $market_data->get_candle($i);
        my $is_swing_high = 1;
        my $is_swing_low  = 1;

        for my $j (1 .. $k) {
            my $left  = $market_data->get_candle($i - $j);
            my $right = $market_data->get_candle($i + $j);
            if ($left->{high} >= $current->{high} || $right->{high} >= $current->{high}) { $is_swing_high = 0; }
            if ($left->{low} <= $current->{low} || $right->{low} <= $current->{low}) { $is_swing_low = 0; }
        }

        if ($is_swing_high) {
            my $state = 'HH'; # Higher High por defecto
            if (defined $last_high && $current->{high} < $last_high->{price}) { $state = 'LH'; } # Lower High
            
            $self->{data}->[$i]->{state} = $state;
            $self->{data}->[$i]->{price} = $current->{high};
            $last_high = { index => $i, price => $current->{high}, state => $state };
        }
        elsif ($is_swing_low) {
            my $state = 'HL'; # Higher Low por defecto
            if (defined $last_low && $current->{low} < $last_low->{price}) { $state = 'LL'; } # Lower Low
            
            $self->{data}->[$i]->{state} = $state;
            $self->{data}->[$i]->{price} = $current->{low};
            $last_low = { index => $i, price => $current->{low}, state => $state };
        }
    }

    # =========================================================================
    # 3. DETECCIÓN DE RUPTURAS INSTITUCIONALES (BOS y CHOCH)
    # =========================================================================
    my $trend = 'bullish'; # Asumimos una tendencia inicial alcista
    my $active_strong_high = undef;
    my $active_strong_low  = undef;

    for my $i (0 .. $size - 1) {
        my $candle = $market_data->get_candle($i);
        my $state = $self->{data}->[$i]->{state};

        # Registrar el pivote fuerte cuando ocurre
        if ($state ne 'none') {
            if ($state eq 'HH' || $state eq 'LH') {
                $active_strong_high = { index => $i, price => $self->{data}->[$i]->{price}, state => $state };
            } elsif ($state eq 'HL' || $state eq 'LL') {
                $active_strong_low = { index => $i, price => $self->{data}->[$i]->{price}, state => $state };
            }
        }

        # Evaluar ruptura estructural con el cierre de vela
        if ($trend eq 'bullish') {
            # BOS: Rompe el último techo alcista (HH o LH)
            if (defined $active_strong_high && $candle->{close} > $active_strong_high->{price}) {
                push @{$self->{data}->[$i]->{events}}, { type => 'BOS', dir => 'bullish', origin => $active_strong_high->{index}, price => $active_strong_high->{price} };
                $active_strong_high = undef; 
            }
            # CHOCH: Rompe el último suelo alcista (HL)
            elsif (defined $active_strong_low && $active_strong_low->{state} eq 'HL' && $candle->{close} < $active_strong_low->{price}) {
                push @{$self->{data}->[$i]->{events}}, { type => 'CHOCH', dir => 'bearish', origin => $active_strong_low->{index}, price => $active_strong_low->{price} };
                $active_strong_low = undef; 
                $trend = 'bearish'; # ¡Giro a la baja!
            }
        }
        elsif ($trend eq 'bearish') {
            # BOS: Rompe el último suelo bajista (LL o HL)
            if (defined $active_strong_low && $candle->{close} < $active_strong_low->{price}) {
                push @{$self->{data}->[$i]->{events}}, { type => 'BOS', dir => 'bearish', origin => $active_strong_low->{index}, price => $active_strong_low->{price} };
                $active_strong_low = undef;
            }
            # CHOCH: Rompe el último techo bajista (LH)
            elsif (defined $active_strong_high && $active_strong_high->{state} eq 'LH' && $candle->{close} > $active_strong_high->{price}) {
                push @{$self->{data}->[$i]->{events}}, { type => 'CHOCH', dir => 'bullish', origin => $active_strong_high->{index}, price => $active_strong_high->{price} };
                $active_strong_high = undef;
                $trend = 'bullish'; # ¡Giro al alza!
            }
        }
    }
}

# --- Interfaz estándar obligatoria para el IndicatorManager ---
sub update_last {
    my ($self, $market_data) = @_;
    push @{$self->{data}}, { state => 'none', events => [], fvgs => [] };
}
sub calculate_batch {
    my ($self, $market_data) = @_;
    $self->calculate($market_data);
}
sub get_values {
    my ($self) = @_;
    return $self->{data};
}
sub reset {
    my ($self) = @_;
    $self->{data} = [];
}

1;