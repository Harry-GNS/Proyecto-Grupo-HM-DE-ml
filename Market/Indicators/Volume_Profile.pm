# =============================================================================
# Market::Indicators::Volume_Profile
# Sección 7 de la Especificación — Perfil de Volumen Avanzado
#
# Calcula distribución horizontal de volumen y determina dinámicamente:
#   - POC  : Point of Control (nodo de mayor volumen acumulado)
#   - VAH  : Value Area High  (límite superior del 70% del volumen)
#   - VAL  : Value Area Low   (límite inferior del 70% del volumen)
#
# Modos de anclaje:
#   'session'     : Reinicia en cada apertura de sesión cronológica.
#   'bos_choch'   : Acumula entre eventos estructurales BOS/CHOCH de HTF.
#   'historical'  : Contingencia — calcula desde la primera vela disponible.
#
# Optimización de memoria (Sección 2):
#   Los cálculos se realizan únicamente sobre las velas del rango visible
#   más una ventana de contexto configurable (context_bars).
# =============================================================================

package Market::Indicators::Volume_Profile;

use strict;
use warnings;
use List::Util qw(min max);
use POSIX      qw(floor);

# =============================================================================
# CONSTRUCTOR
# =============================================================================
sub new {
    my ($class, %args) = @_;
    my $self = {
        # --- Parámetros configurables ---
        mode         => $args{mode}         // 'session', # session|bos_choch|historical
        price_levels => (
            defined $args{price_levels}
            && $args{price_levels} > 5
        )
        ? $args{price_levels}
        : 100,
        value_area_pct => $args{value_area_pct} // 0.70,  # 70% para VA por defecto
        context_bars => $args{context_bars} // 500,       # ventana de contexto indexado

        # --- Datos pre-calculados: un perfil por "zona de anclaje" ---
        # Cada perfil es un hash:
        #   { start_idx, end_idx, poc, vah, val, histogram => [...] }
        profiles  => [],

        # --- Caché de la última ventana procesada (para invalidación lazy) ---
        _last_window_start => -1,
        _last_window_end   => -1,

        # --- Array de salida alineado por vela (compatible con slice_array) ---
        data => [],
    };
    bless $self, $class;
    return $self;
}

# =============================================================================
# INTERFAZ ESTÁNDAR — IndicatorManager
# =============================================================================

sub reset {
    my ($self) = @_;
    $self->{profiles}           = [];
    $self->{data}               = [];
    $self->{_last_window_start} = -1;
    $self->{_last_window_end}   = -1;
}

sub update_last {
    my ($self, $market_data) = @_;
    # En streaming, añadimos una celda vacía; el cálculo real es lazy (en calculate_batch)
    push @{ $self->{data} }, { poc => undef, vah => undef, val => undef, profile_idx => undef };
}

sub calculate_batch {
    my ($self, $market_data) = @_;

    return unless defined $market_data;

    $self->_calculate_full($market_data);
}

sub get_values {
    my ($self) = @_;
    return [ @{ $self->{data} } ];
}

# Entrada de punto de consulta para el Overlay: recalcula perfiles si la ventana cambió.
sub calculate_for_window {
    my ($self, $market_data, $win_start, $win_end, $smc_data_ref) = @_;

    # Invalidación lazy: solo recalcula si la ventana cambió
    return if $self->{_last_window_start} == $win_start
           && $self->{_last_window_end}   == $win_end;

    $self->{_last_window_start} = $win_start;
    $self->{_last_window_end}   = $win_end;

    # Expandir la ventana de análisis con el contexto de validación
    my $ctx_start = max(0, $win_start - $self->{context_bars});
    my $ctx_end   = $win_end;

    $self->_build_profiles($market_data, $ctx_start, $ctx_end, $smc_data_ref);
}

# Acceso directo a los perfiles calculados para el Overlay
sub get_profiles {

    my ($self)=@_;

    return [ @{ $self->{profiles} } ];

}

# =============================================================================
# LÓGICA INTERNA: Cálculo completo sobre todos los datos (para calculate_batch)
# =============================================================================
sub _calculate_full {
    my ($self, $market_data) = @_;
    my $total = $market_data->size();
    return unless $total > 0;

    $self->{data} = [];
    for (0 .. $total - 1) {
        push @{ $self->{data} }, { poc => undef, vah => undef, val => undef, profile_idx => undef };
    }

    $self->_build_profiles($market_data, 0, $total - 1, undef);

    # Propagar los valores del perfil a cada vela del rango data[]
    my $pidx = 0;
    for my $prof (@{ $self->{profiles} }) {
        for my $i ($prof->{start_idx} .. $prof->{end_idx}) {
            next if $i > $#{ $self->{data} };
            $self->{data}[$i]{poc}         = $prof->{poc};
            $self->{data}[$i]{vah}         = $prof->{vah};
            $self->{data}[$i]{val}         = $prof->{val};
            $self->{data}[$i]{profile_idx} = $pidx;
        }
        $pidx++;
    }
}

# =============================================================================
# LÓGICA INTERNA: Construir perfiles sobre un rango de velas
# =============================================================================
sub _build_profiles {
    my ($self, $market_data, $ctx_start, $ctx_end, $smc_data_ref) = @_;
    $self->{profiles} = [];

    my $mode = $self->{mode};

    if ($mode eq 'session') {
        $self->_build_session_profiles($market_data, $ctx_start, $ctx_end);
    }
    elsif ($mode eq 'bos_choch') {
        $self->_build_bos_choch_profiles($market_data, $ctx_start, $ctx_end, $smc_data_ref);
    }
    else {
        # 'historical' o contingencia: perfil único desde ctx_start hasta ctx_end
        $self->_compute_and_push_profile($market_data, $ctx_start, $ctx_end);
    }

    # Si ningún perfil fue generado (ausencia de datos o eventos), activar contingencia
    if (!@{ $self->{profiles} }) {
        $self->_compute_and_push_profile($market_data, $ctx_start, $ctx_end);
    }
}

# --- Modo: Session -----------------------------------------------------------
sub _build_session_profiles {
    my ($self, $market_data, $ctx_start, $ctx_end) = @_;

    my $seg_start = $ctx_start;
    my $prev_date = '';

    for my $i ($ctx_start .. $ctx_end) {
        my $candle = $market_data->get_candle($i);
        next unless defined $candle;

        my $ts = $candle->{timestamp} // '';
        my $date = '';
        if ($ts =~ /^(\d{4}-\d{2}-\d{2})/) { $date = $1; }

        # Nueva sesión detectada cuando cambia la fecha
        if ($date ne $prev_date && $prev_date ne '') {
            $self->_compute_and_push_profile($market_data, $seg_start, $i - 1);
            $seg_start = $i;
        }
        $prev_date = $date;
    }

    # Cerrar el último segmento abierto
    $self->_compute_and_push_profile($market_data, $seg_start, $ctx_end)
        if $seg_start <= $ctx_end;
}

# --- Modo: BOS / CHOCH (con contingencia histórica integrada) ----------------
sub _build_bos_choch_profiles {
    my ($self, $market_data, $ctx_start, $ctx_end, $smc_data_ref) = @_;

    # Si no hay datos SMC disponibles, activar contingencia histórica
    unless (defined $smc_data_ref && @$smc_data_ref) {
        $self->_compute_and_push_profile($market_data, $ctx_start, $ctx_end);
        return;
    }

    my $seg_start   = $ctx_start;
    my $has_events  = 0;

    for my $i ($ctx_start .. $ctx_end) {
        # El smc_data_ref está alineado por índice absoluto
        my $smc = $smc_data_ref->[$i];
        next unless defined $smc;
        next unless exists $smc->{events} && @{ $smc->{events} };

        # Confirmar BOS o CHOCH en esta vela → cierra el perfil anterior
        for my $ev (@{ $smc->{events} }) {
            if ($ev->{type} eq 'BOS' || $ev->{type} eq 'CHOCH') {
                $self->_compute_and_push_profile($market_data, $seg_start, $i);
                $seg_start  = $i + 1;
                $has_events = 1;
                last;
            }
        }
    }

    # Perfil final tras el último evento (o contingencia si no hubo eventos)
    if ($seg_start <= $ctx_end) {
        $self->_compute_and_push_profile($market_data, $seg_start, $ctx_end);
    }

    # Contingencia: sin eventos SMC en el rango → perfil histórico completo
    unless ($has_events) {
        $self->{profiles} = [];
        $self->_compute_and_push_profile($market_data, $ctx_start, $ctx_end);
    }
}

# =============================================================================
# NÚCLEO ALGORÍTMICO: Calcular un perfil (POC / VAH / VAL) para un segmento
# =============================================================================
sub _compute_and_push_profile {
    my ($self, $market_data, $start_idx, $end_idx) = @_;

    return if $start_idx > $end_idx;

    # 1. Determinar el rango de precios en el segmento
    my ($range_min, $range_max) = (undef, undef);
    for my $i ($start_idx .. $end_idx) {
        my $c = $market_data->get_candle($i);
        next unless defined $c;
        $range_min = defined $range_min ? min($range_min, $c->{low})  : $c->{low};
        $range_max = defined $range_max ? max($range_max, $c->{high}) : $c->{high};
    }
    return unless defined $range_min && defined $range_max;
    return if ($range_max - $range_min) <= 0;

    # 2. Construir histograma horizontal de volumen
    my $levels    = $self->{price_levels};
    my $tick_size = ($range_max - $range_min) / $levels;
    my @histogram = (0) x $levels;  # volumen acumulado por nivel de precio
    my $total_vol = 0;
    return if $levels <= 0;

    for my $i ($start_idx .. $end_idx) {
        my $c = $market_data->get_candle($i);
        next unless defined $c && $c->{volume} > 0;

        # Distribuir el volumen de la vela proporcionalmente entre su high y low
        my $c_range = $c->{high} - $c->{low};
        for my $lvl (0 .. $levels - 1) {
            my $lvl_low  = $range_min + $lvl       * $tick_size;
            my $lvl_high = $range_min + ($lvl + 1) * $tick_size;

            # Intersección entre el rango de la vela y el nivel
            my $ovlp_low  = max($c->{low},  $lvl_low);
            my $ovlp_high = min($c->{high}, $lvl_high);

            if ($ovlp_high > $ovlp_low) {
                my $frac = ($c_range > 0)
                    ? ($ovlp_high - $ovlp_low) / $c_range
                    : 1.0 / $levels;
                my $vol_contrib = $c->{volume} * $frac;
                $histogram[$lvl] += $vol_contrib;
                $total_vol       += $vol_contrib;
            }
        }
    }

    return if $total_vol <= 0;

    # 3. Determinar el POC (nivel con mayor volumen)
    my $poc_lvl = 0;
    for my $lvl (0 .. $levels - 1) {
        $poc_lvl = $lvl if $histogram[$lvl] > $histogram[$poc_lvl];
    }
    my $poc_price = $range_min + ($poc_lvl + 0.5) * $tick_size;

    # 4. Expandir Value Area (70% del volumen total desde el POC hacia afuera)
    my $va_target = $total_vol * $self->{value_area_pct};
    my $va_vol    = $histogram[$poc_lvl];
    my $va_high   = $poc_lvl;
    my $va_low    = $poc_lvl;

    while ($va_vol < $va_target) {
        my $next_up   = ($va_high < $levels - 1) ? $histogram[$va_high + 1] : 0;
        my $next_down = ($va_low  > 0)            ? $histogram[$va_low  - 1] : 0;

        if ($next_up >= $next_down && $va_high < $levels - 1) {
            $va_high++;
            $va_vol += $histogram[$va_high];
        }
        elsif ($va_low > 0) {
            $va_low--;
            $va_vol += $histogram[$va_low];
        }
        else {
            last;  # Sin más niveles disponibles
        }
    }

    my $vah_price = $range_min + ($va_high + 1) * $tick_size;
    my $val_price = $range_min + $va_low        * $tick_size;

    push @{ $self->{profiles} }, {
        start_idx => $start_idx,
        end_idx   => $end_idx,
        poc       => $poc_price,
        vah       => $vah_price,
        val       => $val_price,
        poc_lvl   => $poc_lvl,
        va_high   => $va_high,
        va_low    => $va_low,
        range_min => $range_min,
        range_max => $range_max,
        tick_size => $tick_size,
        histogram => \@histogram,
        total_vol => $total_vol,
    };
}

1;
