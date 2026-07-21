# =============================================================================
# Market::Indicators::Anchored_VWAP
# Sección 8 de la Especificación — VWAP Multi-Pivot Anclado
#
# Calcula el VWAP (Volume Weighted Average Price) reinicializando acumulados
# de forma estricta (Multi-Pivot) ante cualquiera de cinco disparadores:
#
#   1. Inicio de Sesión   → primer tick/vela de la sesión activa
#   2. Apertura de Mercado → primera vela del día de negociación
#   3. BOS confirmado     → vela exacta del Break of Structure
#   4. CHOCH confirmado   → vela exacta del Change of Character
#   5. POC del VP         → anclaje dinámico coordinado con Volume Profile
#
# Fórmula de acumulación (estándar financiero):
#   típico_precio = (high + low + close) / 3
#   cumPV += típico_precio × volume
#   cumVol += volume
#   VWAP   = cumPV / cumVol
#
# Optimización de memoria (Sección 2):
#   Los cálculos se realizan únicamente sobre las velas del rango visible
#   más una ventana de contexto configurable (context_bars).
# =============================================================================

package Market::Indicators::Anchored_VWAP;

use strict;
use warnings;
use List::Util qw(max);

# =============================================================================
# CONSTRUCTOR
# =============================================================================
sub new {
    my ($class, %args) = @_;
    my $self = {
        # --- Disparadores habilitados (todos activos por defecto) ---
        anchor_session    => $args{anchor_session}    // 1,
        anchor_market_open => $args{anchor_market_open} // 1,
        anchor_bos        => $args{anchor_bos}        // 1,
        anchor_choch      => $args{anchor_choch}      // 1,
        anchor_poc        => $args{anchor_poc}        // 1,

        # Ventana de contexto extra más allá de la ventana visible
        context_bars => $args{context_bars} // 500,

        # --- Lista de anclas: cada ancla es { idx, type, vwap_values => [...] } ---
        anchors => [],

        # --- Array de salida alineado con velas (para slice_array) ---
        data => [],

        # --- Caché de invalidación lazy ---
        _last_window_start => -1,
        _last_window_end   => -1,
    };
    bless $self, $class;
    return $self;
}

# =============================================================================
# INTERFAZ ESTÁNDAR — IndicatorManager
# =============================================================================

sub reset {
    my ($self) = @_;
    $self->{anchors}            = [];
    $self->{data}               = [];
    $self->{_last_window_start} = -1;
    $self->{_last_window_end}   = -1;
}

sub update_last {
    my ($self, $market_data) = @_;
    # Placeholder en streaming; recalculo real bajo demanda (lazy)
    push @{ $self->{data} }, { vwap => undef, anchor_type => undef, anchor_idx => undef };
}

sub calculate_batch {
    my ($self, $market_data) = @_;
    $self->_calculate_full($market_data, undef, undef);
}

sub get_values {
    my ($self) = @_;
    return $self->{data};
}

# Entrada de punto de consulta para el Overlay (invalidación lazy por ventana)
sub calculate_for_window {
    my ($self, $market_data, $win_start, $win_end, $smc_data_ref, $vp_profiles_ref) = @_;

    return if $self->{_last_window_start} == $win_start
           && $self->{_last_window_end}   == $win_end;

    $self->{_last_window_start} = $win_start;
    $self->{_last_window_end}   = $win_end;

    my $ctx_start = max(0, $win_start - $self->{context_bars});
    my $ctx_end   = $win_end;

    $self->_calculate_full($market_data, $ctx_start, $ctx_end,
                           $smc_data_ref, $vp_profiles_ref);
}

# Acceso a las anclas calculadas para el Overlay
sub get_anchors { return $_[0]->{anchors}; }

# =============================================================================
# LÓGICA INTERNA: Cálculo completo sobre un rango
# =============================================================================
sub _calculate_full {
    my ($self, $market_data, $ctx_start, $ctx_end, $smc_data_ref, $vp_profiles_ref) = @_;

    my $total = $market_data->size();
    return unless $total > 0;

    $ctx_start //= 0;
    $ctx_end   //= $total - 1;

    # --- 1. Detectar todas las anclas en el rango de contexto ---
    my @anchor_indices = $self->_detect_anchors(
        $market_data, $ctx_start, $ctx_end, $smc_data_ref, $vp_profiles_ref
    );

    # Si no hay anclas, la primera vela del rango es el ancla por defecto
    unless (@anchor_indices) {
        @anchor_indices = ({ idx => $ctx_start, type => 'default' });
    }

    # --- 2. Calcular VWAP acumulado para cada segmento entre anclas ---
    $self->{anchors} = [];
    $self->{data}    = [] unless @{ $self->{data} } == $total;
    $self->{data}    = [(undef) x $total] unless @{ $self->{data} };

    my $num_anchors = scalar @anchor_indices;

    for my $a_idx (0 .. $num_anchors - 1) {
        my $anchor     = $anchor_indices[$a_idx];
        my $seg_start  = $anchor->{idx};
        my $seg_end    = ($a_idx < $num_anchors - 1)
                       ? $anchor_indices[$a_idx + 1]{idx} - 1
                       : $ctx_end;

        my @vwap_vals;
        my ($cum_pv, $cum_vol) = (0.0, 0.0);

        for my $i ($seg_start .. $seg_end) {
            my $c = $market_data->get_candle($i);
            unless (defined $c) {
                push @vwap_vals, undef;
                next;
            }

            # Precio típico (TP) — estándar VWAP
            my $tp = ($c->{high} + $c->{low} + $c->{close}) / 3.0;
            $cum_pv  += $tp * $c->{volume};
            $cum_vol += $c->{volume};

            my $vwap = ($cum_vol > 0) ? $cum_pv / $cum_vol : $tp;
            push @vwap_vals, $vwap;

            # Propagar al arreglo de salida global (alineado por índice absoluto)
            if ($i >= 0 && $i < $total) {
                $self->{data}[$i] = {
                    vwap        => $vwap,
                    anchor_type => $anchor->{type},
                    anchor_idx  => $seg_start,
                };
            }
        }

        push @{ $self->{anchors} }, {
            start_idx   => $seg_start,
            end_idx     => $seg_end,
            anchor_type => $anchor->{type},
            vwap_values => \@vwap_vals,
        };
    }
}

# =============================================================================
# DETECCIÓN DE ANCLAS — Los cinco disparadores Multi-Pivot
# =============================================================================
sub _detect_anchors {
    my ($self, $market_data, $ctx_start, $ctx_end, $smc_data_ref, $vp_profiles_ref) = @_;

    my %seen_idx;  # Evitar anclas duplicadas en la misma vela
    my @anchors;

    my $prev_date        = '';
    my $prev_market_date = '';

    for my $i ($ctx_start .. $ctx_end) {
        my $c = $market_data->get_candle($i);
        next unless defined $c;

        my $ts   = $c->{timestamp} // '';
        my $date = '';
        my $hour = -1;
        if ($ts =~ /^(\d{4}-\d{2}-\d{2})T(\d{2}):/) {
            $date = $1;
            $hour = $2 + 0;
        }

        # -------------------------------------------------------------------
        # Disparador 1: Inicio de Sesión (primera vela de cada día cronológico)
        # -------------------------------------------------------------------
        if ($self->{anchor_session} && $date ne '' && $date ne $prev_date) {
            unless ($seen_idx{$i}++) {
                push @anchors, { idx => $i, type => 'session' };
            }
        }

        # -------------------------------------------------------------------
        # Disparador 2: Apertura oficial de Mercado (primera vela de la hora 0)
        # -------------------------------------------------------------------
        if ($self->{anchor_market_open} && $date ne '' && $date ne $prev_market_date && $hour == 0) {
            unless ($seen_idx{$i}++) {
                push @anchors, { idx => $i, type => 'market_open' };
            }
            $prev_market_date = $date;
        }

        # -------------------------------------------------------------------
        # Disparadores 3 y 4: BOS y CHOCH confirmados
        # -------------------------------------------------------------------
        if (($self->{anchor_bos} || $self->{anchor_choch})
            && defined $smc_data_ref
            && defined $smc_data_ref->[$i])
        {
            my $smc = $smc_data_ref->[$i];
            if (exists $smc->{events} && @{ $smc->{events} }) {
                for my $ev (@{ $smc->{events} }) {
                    if ($ev->{type} eq 'BOS' && $self->{anchor_bos}) {
                        unless ($seen_idx{$i}++) {
                            push @anchors, { idx => $i, type => 'bos' };
                        }
                        last;
                    }
                    if ($ev->{type} eq 'CHOCH' && $self->{anchor_choch}) {
                        unless ($seen_idx{$i}++) {
                            push @anchors, { idx => $i, type => 'choch' };
                        }
                        last;
                    }
                }
            }
        }

        # -------------------------------------------------------------------
        # Disparador 5: POC coordinado con Volume Profile
        # POC activo cuando el precio cruza el nivel POC del perfil vigente
        # -------------------------------------------------------------------
        if ($self->{anchor_poc} && defined $vp_profiles_ref && @$vp_profiles_ref) {
            for my $prof (@$vp_profiles_ref) {
                # La ancla se genera en la primera vela del perfil VP
                if ($prof->{start_idx} == $i && defined $prof->{poc}) {
                    unless ($seen_idx{$i}++) {
                        push @anchors, { idx => $i, type => 'poc_vp' };
                    }
                    last;
                }
            }
        }

        $prev_date = $date if $date ne '';
    }

    # Ordenar anclas por índice
    @anchors = sort { $a->{idx} <=> $b->{idx} } @anchors;

    # Garantizar que la primera ancla empieza en ctx_start
    if (!@anchors || $anchors[0]{idx} > $ctx_start) {
        unshift @anchors, { idx => $ctx_start, type => 'default' };
    }

    return @anchors;
}

1;
