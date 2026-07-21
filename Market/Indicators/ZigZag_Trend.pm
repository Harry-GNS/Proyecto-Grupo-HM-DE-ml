# This Perl code is a port of the ZigZag algorithm from:
#   "ZigZag Multi Time Frame with Fibonacci Retracement" (Pine Script® v4)
#   Subject to the terms of the Mozilla Public License 2.0
#   https://mozilla.org/MPL/2.0/
#   © LonesomeTheBlue
#
# Port author: Proyecto-Machine-Learning
# Only the core ZigZag detection logic (pivots, direction, array) is ported.
# Fibonacci retracement levels, labels, multi-timeframe resolution, and all
# drawing code are excluded.
#
# Equivalence map (Pine → Perl):
#   prd                          → $self->{prd}        (period, default 2)
#   highestbars(high, len)==0    → current high == max of last prd highs
#   lowestbars(low, len)==0      → current low  == min of last prd lows
#   ph / pl                      → $ph / $pl
#   var dir = 0                  → $self->{_dir}        (0=init, 1=up, -1=down)
#   var zigzag = array           → $self->{_zigzag}     ([val0,bar0,val1,bar1,...])
#   add_to_zigzag(v,b)           → _add_to_zigzag($v,$b)
#   update_zigzag(v,b)           → _update_zigzag($v,$b)
#   dirchanged                   → $dir_changed

package Market::Indicators::ZigZag_Trend;

use strict;
use warnings;
use List::Util qw(max min);

# =============================================================================
# CONSTRUCTOR
# =============================================================================
# Parámetros:
#   prd          => int  (default 2, rango 2–10 como en el original)
#                        Equivale a "ZigZag Period" del Pine Script.
#                        Controla cuántas barras debe ser el high/low el extremo
#                        de la ventana para considerarse un pivote.
#   swing_length => int  Alias de prd (compatibilidad con versión anterior).
#
# Nota: El parámetro `tf` (timeframe) del original no se porta; el módulo
# opera sobre la temporalidad ya seleccionada en MarketData. Para simular
# tf=D en datos de 1m, construye las velas D con build_tf_candles y pasa
# ese MarketData con set_timeframe('D').
# =============================================================================
sub new {
    my ($class, %args) = @_;
    my $prd = $args{prd} // $args{swing_length} // 2;

    my $self = {
        # --- Parámetros ---
        prd              => $prd,
        max_zigzag_pairs => 50,    # max_array_size del Pine (guarda 50 pivotes)

        # --- Estado interno (var en Pine) ---
        _highs_window => [],       # ventana deslizante de prd highs
        _lows_window  => [],       # ventana deslizante de prd lows

        # dir: 0=inicial, 1=alcista, -1=bajista
        # Pine: var dir = 0
        _dir => 0,

        # zigzag array: [val0,bar0, val1,bar1, val2,bar2, ...]
        # Índice 0 = pivote más reciente, índice 2 = segundo más reciente, etc.
        # Pine: var zigzag = array.new_float(0)
        _zigzag => [],

        # --- Salida por barra ---
        data => [],
    };
    bless $self, $class;
    return $self;
}

# =============================================================================
# INTERFAZ PÚBLICA ESTÁNDAR (compatible con IndicatorManager)
# =============================================================================

sub update_last {
    my ($self, $market_data) = @_;
    my $idx = $market_data->last_index();
    return unless defined $idx;
    my $candle = $market_data->get_candle($idx);
    return unless defined $candle;
    $self->_process_bar($idx, $candle);
}

sub calculate_batch {
    my ($self, $market_data) = @_;
    $self->reset();
    my $size = $market_data->size();
    for my $i (0 .. $size - 1) {
        my $candle = $market_data->get_candle($i);
        $self->_process_bar($i, $candle);
    }
}

sub get_values {
    my ($self) = @_;
    return $self->{data};
}

sub reset {
    my ($self) = @_;
    $self->{_highs_window} = [];
    $self->{_lows_window}  = [];
    $self->{_dir}          = 0;
    $self->{_zigzag}       = [];
    $self->{data}          = [];
}

# =============================================================================
# FUNCIONES INTERNAS DEL ZIGZAG — traducción directa del Pine Script
# =============================================================================

# add_to_zigzag(value, bindex) del Pine:
#   array.unshift(zigzag, bindex)
#   array.unshift(zigzag, value)
#   → zigzag[0]=value, zigzag[1]=bindex (más reciente al frente)
#
# REPAINT: Cada vez que se llama, el pivote actual se convierte en el
# segundo más reciente, empujando todo hacia atrás.
sub _add_to_zigzag {
    my ($self, $value, $bar_idx) = @_;
    unshift @{ $self->{_zigzag} }, $bar_idx;   # primero bindex (queda en [1])
    unshift @{ $self->{_zigzag} }, $value;     # luego value  (queda en [0])

    # Limitar a max_zigzag_pairs pares (= max_array_size del Pine)
    my $max_elements = $self->{max_zigzag_pairs} * 2;
    while (scalar @{ $self->{_zigzag} } > $max_elements) {
        pop @{ $self->{_zigzag} };   # elimina el elemento más antiguo (valor)
        pop @{ $self->{_zigzag} };   # elimina el bar_index asociado
    }
}

# update_zigzag(value, bindex) del Pine:
#   Si el zigzag está vacío → add_to_zigzag
#   Si dir==1 y value > zigzag[0]  → reemplazar el pivote más reciente (nuevo máximo)
#   Si dir==-1 y value < zigzag[0] → reemplazar el pivote más reciente (nuevo mínimo)
#
# REPAINT: Mientras la tendencia continúa, el extremo del tramo activo
# se actualiza barra a barra hasta que ocurra un cambio de dirección.
sub _update_zigzag {
    my ($self, $value, $bar_idx) = @_;
    my $zz  = $self->{_zigzag};
    my $dir = $self->{_dir};

    if (!@$zz) {
        $self->_add_to_zigzag($value, $bar_idx);
        return;
    }

    # Actualizar solo si el nuevo valor supera al actual en la dirección correcta
    if (($dir == 1 && $value > $zz->[0]) || ($dir == -1 && $value < $zz->[0])) {
        $zz->[0] = $value;    # actualizar valor
        $zz->[1] = $bar_idx;  # actualizar bar_index
    }
}

# =============================================================================
# LÓGICA PRINCIPAL — PROCESAMIENTO DE UNA BARRA
# =============================================================================
sub _process_bar {
    my ($self, $bar_idx, $candle) = @_;
    my $prd = $self->{prd};

    # ------------------------------------------------------------------
    # 1. Mantener ventana deslizante de prd highs y lows
    #    Equivale a highestbars(high, len)==0 / lowestbars(low, len)==0
    #    del Pine, donde len = prd (asumiendo misma temporalidad que tf).
    # ------------------------------------------------------------------
    push @{ $self->{_highs_window} }, $candle->{high};
    push @{ $self->{_lows_window}  }, $candle->{low};

    if (scalar @{ $self->{_highs_window} } > $prd) {
        shift @{ $self->{_highs_window} };
        shift @{ $self->{_lows_window}  };
    }

    my $max_h = max(@{ $self->{_highs_window} });
    my $min_l = min(@{ $self->{_lows_window}  });

    # ph: la barra actual tiene el high más alto de la ventana (highestbars==0)
    # pl: la barra actual tiene el low  más bajo  de la ventana (lowestbars==0)
    # Pine: ph := highestbars(high, nz(len,1)) == 0 ? high : na
    my $ph = ($candle->{high} == $max_h) ? $candle->{high} : undef;
    my $pl = ($candle->{low}  == $min_l) ? $candle->{low}  : undef;

    # ------------------------------------------------------------------
    # 2. Actualizar dirección
    #    Pine: dir := iff(ph and na(pl), 1, iff(pl and na(ph), -1, dir))
    #    • Solo ph  → dir = 1  (alcista)
    #    • Solo pl  → dir = -1 (bajista)
    #    • Ambos o ninguno → dir no cambia
    # ------------------------------------------------------------------
    my $prev_dir = $self->{_dir};
    my $dir      = $self->{_dir};

    if (defined $ph && !defined $pl) {
        $dir = 1;
    }
    elsif (defined $pl && !defined $ph) {
        $dir = -1;
    }
    # si ambas o ninguna: dir queda igual

    $self->{_dir} = $dir;

    # ------------------------------------------------------------------
    # 3. Actualizar el array zigzag cuando hay pivote detectado
    #    Pine:
    #      bool dirchanged = (dir != dir[1])
    #      if ph or pl
    #          if dirchanged → add_to_zigzag(dir==1 ? ph : pl, bar_index)
    #          else          → update_zigzag(dir==1 ? ph : pl, bar_index)
    # ------------------------------------------------------------------
    if (defined $ph || defined $pl) {
        my $dir_changed = ($dir != $prev_dir);

        # El valor a usar es el high si dir==1, el low si dir==-1.
        # Si dir==0 (caso de arranque con ambas condiciones falsas), usa lo que haya.
        my $val;
        if ($dir == 1) {
            $val = $ph;
        }
        elsif ($dir == -1) {
            $val = $pl;
        }
        else {
            $val = defined $ph ? $ph : $pl;
        }

        if ($dir_changed) {
            $self->_add_to_zigzag($val, $bar_idx);
        }
        else {
            $self->_update_zigzag($val, $bar_idx);
        }
    }

    # ------------------------------------------------------------------
    # 4. Construir salida a partir del array zigzag
    #
    #    Layout del array (más reciente primero):
    #    [val0, bar0,  val1, bar1,  val2, bar2, ...]
    #     ^--- P0       ^--- P1       ^--- P2
    #     (más reciente)
    #
    #    Segmento activo (REPAINT): P1 → P0
    #    Segmentos completados: P2→P1, P3→P2, P4→P3, ...
    # ------------------------------------------------------------------
    my $zz = $self->{_zigzag};
    my $n  = scalar @$zz;   # número de elementos (siempre par)

    # --- Tendencia ---
    my $trend = ($dir ==  1) ? 'bullish'
              : ($dir == -1) ? 'bearish'
              : undef;

    my $trend_changed = ($dir != 0 && $dir != $prev_dir) ? 1 : 0;

    # --- Segmento activo (entre P1 y P0) ---
    # REPAINT: zigzag[0] y zigzag[1] cambian barra a barra mientras dir no gira
    my $active_segment = undef;
    if ($n >= 4) {
        $active_segment = {
            from_bar   => $zz->[3],   # bar  de P1 (segundo más reciente)
            from_price => $zz->[2],   # valor de P1
            to_bar     => $zz->[1],   # bar  de P0 (más reciente)
            to_price   => $zz->[0],   # valor de P0
            direction  => ($zz->[0] > $zz->[2]) ? 'bullish' : 'bearish',
        };
    }

    # --- Segmentos completados (P_{k+1} → P_k para k ≥ 1) ---
    # Ordenados del más antiguo al más reciente para renderizado natural.
    my @completed;
    for (my $i = $n - 2; $i >= 4; $i -= 2) {
        push @completed, {
            from_bar   => $zz->[$i+1],   # bar  del punto más antiguo
            from_price => $zz->[$i],     # valor del punto más antiguo
            to_bar     => $zz->[$i-1],   # bar  del punto más nuevo
            to_price   => $zz->[$i-2],   # valor del punto más nuevo
            direction  => ($zz->[$i-2] > $zz->[$i]) ? 'bullish' : 'bearish',
        };
    }

    # --- Pivotes confirmados ---
    # Si dir==1: P0 es un HIGH, P1 es un LOW
    # Si dir==-1: P0 es un LOW, P1 es un HIGH
    my ($pivot_high, $pivot_low) = (undef, undef);
    if ($n >= 4) {
        if ($dir == 1) {
            $pivot_high = { bar_index => $zz->[1], price => $zz->[0] };
            $pivot_low  = { bar_index => $zz->[3], price => $zz->[2] };
        }
        elsif ($dir == -1) {
            $pivot_low  = { bar_index => $zz->[1], price => $zz->[0] };
            $pivot_high = { bar_index => $zz->[3], price => $zz->[2] };
        }
    }
    elsif ($n >= 2) {
        # Solo un pivote conocido aún
        if ($dir == 1)  { $pivot_high = { bar_index => $zz->[1], price => $zz->[0] }; }
        elsif ($dir == -1) { $pivot_low  = { bar_index => $zz->[1], price => $zz->[0] }; }
    }

    # ------------------------------------------------------------------
    # 5. Guardar resultado de la barra
    # ------------------------------------------------------------------
    $self->{data}[$bar_idx] = {
        trend          => $trend,
        trend_changed  => $trend_changed,

        # Extremos de la ventana actual (equivalentes a highestbars/lowestbars)
        swing_high => $max_h,
        swing_low  => $min_l,

        # Pivotes confirmados (posición fija hasta que se confirme uno nuevo)
        pivot_high => $pivot_high,
        pivot_low  => $pivot_low,

        # Tramos del zigzag
        segments       => [@completed],    # completados (inmutables)
        active_segment => $active_segment, # en curso (REPAINT)

        # Número de pivotes en el array (diagnóstico)
        zigzag_points => int($n / 2),
    };
}

1;
