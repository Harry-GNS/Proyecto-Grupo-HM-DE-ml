package Market::Indicators::Liquidity;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        depth => $args{depth} || 3,
        n_run => $args{n_run} || 3,
        data  => [],
    };
    bless $self, $class;
    return $self;
}

sub calculate {
    my ($self, $market_data) = @_;
    my $size = $market_data->size();
    my $k = $self->{depth};
    my $n_run = $self->{n_run};

    $self->{data} = [];

    for (0 .. $size - 1) {
        push @{$self->{data}}, { state => 'none', events => [] };
    }

    # FASE 1: Detección de Swing Points (Picos y Valles)
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
            $self->{data}->[$i]->{state} = 'swing_high';
            $self->{data}->[$i]->{price} = $current->{high};
        } elsif ($is_swing_low) {
            $self->{data}->[$i]->{state} = 'swing_low';
            $self->{data}->[$i]->{price} = $current->{low};
        }
    }

    # =========================================================================
    # NUEVO: Cálculo dinámico e integrado del ATR (Periodo 14) O(N)
    # =========================================================================
    my @atr;
    my $n_atr = 14;
    for my $i (0 .. $size - 1) {
        my $c = $market_data->get_candle($i);
        my $tr = $c->{high} - $c->{low};
        if ($i > 0) {
            my $pc = $market_data->get_candle($i - 1)->{close};
            my $h_pc = abs($c->{high} - $pc);
            my $l_pc = abs($c->{low} - $pc);
            $tr = $h_pc if $h_pc > $tr;
            $tr = $l_pc if $l_pc > $tr;
        }
        if ($i < $n_atr) {
            $atr[$i] = $tr;
        } else {
            $atr[$i] = (($atr[$i-1] * ($n_atr - 1)) + $tr) / $n_atr;
        }
    }

    # FASE 2: Escáner Lineal con Tolerancia Dinámica (EQH / EQL)
    my @active_highs;
    my @active_lows;

    for my $i (0 .. $size - 1) {
        my $type = $self->{data}->[$i]->{state};
        my $candle = $market_data->get_candle($i);
        
        # Calcular umbral de tolerancia exacto para esta vela (ATR * 0.10)
        my $current_atr = $atr[$i] // 0;
        my $tolerance = $current_atr * 0.10; 

        # 1. Agrupar Pivotes Cercanos en EQH / EQL basados en la tolerancia
        if ($type eq 'swing_high') {
            my $matched = 0;
            for my $origin_idx (@active_highs) {
                my $old_price = $self->{data}->[$origin_idx]->{price};
                if (abs($old_price - $candle->{high}) <= $tolerance) {
                    # Convertir el nivel antiguo en Equal High
                    $self->{data}->[$origin_idx]->{state} = 'eqh';
                    # Ajustar el precio al extremo más alto para evitar auto-barrido
                    $self->{data}->[$origin_idx]->{price} = $candle->{high} > $old_price ? $candle->{high} : $old_price;
                    $matched = 1;
                    last;
                }
            }
            # Solo crear una nueva línea si no hizo "match" con un nivel pasado
            push @active_highs, $i if !$matched;
        }
        elsif ($type eq 'swing_low') {
            my $matched = 0;
            for my $origin_idx (@active_lows) {
                my $old_price = $self->{data}->[$origin_idx]->{price};
                if (abs($old_price - $candle->{low}) <= $tolerance) {
                    # Convertir el nivel antiguo en Equal Low
                    $self->{data}->[$origin_idx]->{state} = 'eql';
                    # Ajustar el precio al extremo más bajo
                    $self->{data}->[$origin_idx]->{price} = $candle->{low} < $old_price ? $candle->{low} : $old_price;
                    $matched = 1;
                    last;
                }
            }
            push @active_lows, $i if !$matched;
        }

        # 2. Evaluar Rupturas (Sweeps, Grabs, Runs)
        # --- BSL y EQH ---
        my @new_active_highs;
        for my $origin_idx (@active_highs) {
            if ($i <= $origin_idx + $k) {
                push @new_active_highs, $origin_idx;
                next;
            }

            my $level_price = $self->{data}->[$origin_idx]->{price};
            
            if ($candle->{high} > $level_price) {
                my $resolved = 0;
                
                if ($candle->{close} < $level_price) {
                    $self->{data}->[$origin_idx]->{end_index} = $i;
                    $self->{data}->[$origin_idx]->{resolution} = 'sweep';
                    push @{$self->{data}->[$i]->{events}}, { type => 'sweep_up', price => $level_price, origin => $origin_idx };
                    $resolved = 1;
                }
                
                if (!$resolved && $i + $n_run - 1 < $size) {
                    my $is_run = 1;
                    for my $m (0 .. $n_run - 1) {
                        if ($market_data->get_candle($i + $m)->{close} <= $level_price) {
                            $is_run = 0; last;
                        }
                    }
                    if ($is_run) {
                        $self->{data}->[$origin_idx]->{end_index} = $i;
                        $self->{data}->[$origin_idx]->{resolution} = 'run';
                        push @{$self->{data}->[$i]->{events}}, { type => 'run_up', price => $level_price, origin => $origin_idx };
                        $resolved = 1;
                    }
                }
                
                if (!$resolved) {
                    my $is_grab = 0;
                    my $grab_end_idx = $i;
                    for my $m (1 .. 3) {
                        if ($i + $m < $size) {
                            if ($market_data->get_candle($i + $m)->{close} < $level_price) {
                                $is_grab = 1;
                                $grab_end_idx = $i + $m;
                                last;
                            }
                        }
                    }
                    if ($is_grab) {
                        $self->{data}->[$origin_idx]->{end_index} = $grab_end_idx;
                        $self->{data}->[$origin_idx]->{resolution} = 'grab';
                        push @{$self->{data}->[$grab_end_idx]->{events}}, { type => 'grab_up', price => $level_price, origin => $origin_idx };
                        $resolved = 1;
                    }
                }

                if (!$resolved) {
                    $self->{data}->[$origin_idx]->{end_index} = $i;
                    # FIX: Keep in memory until definitive resolution (for Replay persistence)
                    push @new_active_highs, $origin_idx;
                }
            } else {
                push @new_active_highs, $origin_idx;
            }
        }
        @active_highs = @new_active_highs;

        # --- SSL y EQL ---
        my @new_active_lows;
        for my $origin_idx (@active_lows) {
            if ($i <= $origin_idx + $k) {
                push @new_active_lows, $origin_idx;
                next;
            }

            my $level_price = $self->{data}->[$origin_idx]->{price};
            
            if ($candle->{low} < $level_price) {
                my $resolved = 0;
                
                if ($candle->{close} > $level_price) {
                    $self->{data}->[$origin_idx]->{end_index} = $i;
                    $self->{data}->[$origin_idx]->{resolution} = 'sweep';
                    push @{$self->{data}->[$i]->{events}}, { type => 'sweep_down', price => $level_price, origin => $origin_idx };
                    $resolved = 1;
                }
                
                if (!$resolved && $i + $n_run - 1 < $size) {
                    my $is_run = 1;
                    for my $m (0 .. $n_run - 1) {
                        if ($market_data->get_candle($i + $m)->{close} >= $level_price) {
                            $is_run = 0; last;
                        }
                    }
                    if ($is_run) {
                        $self->{data}->[$origin_idx]->{end_index} = $i;
                        $self->{data}->[$origin_idx]->{resolution} = 'run';
                        push @{$self->{data}->[$i]->{events}}, { type => 'run_down', price => $level_price, origin => $origin_idx };
                        $resolved = 1;
                    }
                }
                
                if (!$resolved) {
                    my $is_grab = 0;
                    my $grab_end_idx = $i;
                    for my $m (1 .. 3) {
                        if ($i + $m < $size) {
                            if ($market_data->get_candle($i + $m)->{close} > $level_price) {
                                $is_grab = 1;
                                $grab_end_idx = $i + $m;
                                last;
                            }
                        }
                    }
                    if ($is_grab) {
                        $self->{data}->[$origin_idx]->{end_index} = $grab_end_idx;
                        $self->{data}->[$origin_idx]->{resolution} = 'grab';
                        push @{$self->{data}->[$grab_end_idx]->{events}}, { type => 'grab_down', price => $level_price, origin => $origin_idx };
                        $resolved = 1;
                    }
                }

                if (!$resolved) {
                    $self->{data}->[$origin_idx]->{end_index} = $i;
                    # FIX: Keep in memory until definitive resolution (for Replay persistence)
                    push @new_active_lows, $origin_idx;
                }
            } else {
                push @new_active_lows, $origin_idx;
            }
        }
        @active_lows = @new_active_lows;
    }

    # Limpieza final
    for my $origin_idx (@active_highs, @active_lows) {
        $self->{data}->[$origin_idx]->{end_index} = $size - 1;
        $self->{data}->[$origin_idx]->{resolution} = 'active';
    }
}

sub update_last {
    my ($self, $market_data) = @_;
    push @{$self->{data}}, { state => 'none', events => [] };
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