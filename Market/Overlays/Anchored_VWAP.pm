# =============================================================================
# Market::Overlays::Anchored_VWAP
# Sección 8 de la Especificación — Renderizador del VWAP Multi-Pivot Anclado
#
# Dibuja sobre el Canvas de precios (price_canvas):
#   - Una línea VWAP continua por cada segmento entre anclas detectadas
#   - Marcadores visuales en el punto de cada ancla (triángulo/tick)
#   - Etiqueta del tipo de ancla: Session | Market Open | BOS | CHOCH | POC-VP
#
# Tag Tk utilizado: 'vwap_overlay'
# Integración: ChartEngine llama a render() tras cada request_render().
# =============================================================================

package Market::Overlays::Anchored_VWAP;

use strict;
use warnings;

# =============================================================================
# CONSTRUCTOR
# =============================================================================
sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},

        # --- Colores por tipo de ancla ---
        colors => {
            session     => $args{color_session}    // '#2979FF',  # Azul eléctrico
            market_open => $args{color_market_open} // '#00E5FF', # Cian
            bos         => $args{color_bos}        // '#26A69A',  # Verde teal
            choch       => $args{color_choch}       // '#FF6B35', # Naranja
            poc_vp      => $args{color_poc_vp}     // '#F7C948',  # Amarillo dorado
            default     => $args{color_default}    // '#8892A4',  # Gris azulado
        },

        # --- Opciones de renderizado ---
        line_width      => $args{line_width}      // 1.5,
        show_markers    => $args{show_markers}    // 1,
        show_labels     => $args{show_labels}     // 1,
        marker_size     => $args{marker_size}     // 5,
    };
    bless $self, $class;
    return $self;
}

# =============================================================================
# RENDER
#
# Parámetros:
#   $scale            — objeto Market::Panels::Scales
#   $vwap_indicator   — instancia de Market::Indicators::Anchored_VWAP
#   $start_idx_vp     — índice absoluto de inicio de ventana visible
#   $visibility       — hash de flags del ChartEngine
# =============================================================================
sub render {
    my ($self, $scale, $vwap_indicator, $start_idx_vp, $visibility) = @_;
    my $c = $self->{canvas};

    # Limpiar dibujos anteriores
    $c->delete('vwap_overlay');

    $visibility //= {};
    my $show = sub { $visibility->{$_[0]} // 1 };
    return unless $show->('anchored_vwap');

    my $anchors = $vwap_indicator->get_anchors();
    return unless defined $anchors && @$anchors;

    my $width  = $c->width;
    my $height = $c->height;
    return if $width <= 0 || $height <= 0;

    my $min_val      = $scale->{min_val};
    my $max_val      = $scale->{max_val};
    my $range        = $max_val - $min_val;
    return if $range <= 0;

    my $visible_bars = $scale->{visible_bars};
    my $offset_frac  = $scale->{offset};
    my $candle_w     = $width / $visible_bars;

    $start_idx_vp //= 0;

    for my $anchor (@$anchors) {
        my $type      = $anchor->{anchor_type} // 'default';
        my $seg_start = $anchor->{start_idx};
        my $seg_end   = $anchor->{end_idx};
        my $vwap_vals = $anchor->{vwap_values} // [];
        my $color     = $self->{colors}{$type} // $self->{colors}{default};

        # Calcular posición X del punto de ancla
        my $rel_anchor = $seg_start - $start_idx_vp;
        my $x_anchor   = ($rel_anchor - $offset_frac) * $candle_w + ($candle_w / 2);

        # =====================================================================
        # 1. LÍNEA DE VWAP (segmento entre anclas)
        # =====================================================================
        my @points;  # Pares (x, y) para createLine poly

        for my $local_i (0 .. $#$vwap_vals) {
            next unless defined $vwap_vals->[$local_i];

            my $abs_i  = $seg_start + $local_i;
            my $rel_i  = $abs_i - $start_idx_vp;
            my $x      = ($rel_i - $offset_frac) * $candle_w + ($candle_w / 2);

            # Clipping horizontal estricto
            next if $x < -$candle_w || $x > $width + $candle_w;

            my $vwap = $vwap_vals->[$local_i];
            my $y    = $height - (($vwap - $min_val) / $range) * $height;

            # Clipping vertical estricto
            next if $y < 0 || $y > $height;

            push @points, $x, $y;
        }

        # Dibujar la línea solo si hay al menos 2 puntos (un segmento)
        if (@points >= 4) {
            $c->createLine(
                @points,
                -fill   => $color,
                -width  => $self->{line_width},
                -smooth => 0,
                -tags   => ['vwap_overlay'],
            );
        }

        # =====================================================================
        # 2. MARCADOR EN EL PUNTO DE ANCLA (triángulo apuntando hacia arriba)
        # =====================================================================
        if ($self->{show_markers} && $show->('vwap_markers')) {
            my $vwap_at_anchor = $vwap_vals->[0];
            if (defined $vwap_at_anchor && $x_anchor >= -10 && $x_anchor <= $width + 10) {
                my $y_anchor = $height - (($vwap_at_anchor - $min_val) / $range) * $height;
                my $r        = $self->{marker_size};

                if ($y_anchor >= 0 && $y_anchor <= $height) {
                    # Triángulo pequeño como marcador de ancla
                    $c->createPolygon(
                        $x_anchor,      $y_anchor - $r,  # vértice superior
                        $x_anchor - $r, $y_anchor + $r,  # inferior izquierdo
                        $x_anchor + $r, $y_anchor + $r,  # inferior derecho
                        -fill    => $color,
                        -outline => $color,
                        -tags    => ['vwap_overlay'],
                    );
                }
            }
        }

        # =====================================================================
        # 3. ETIQUETA DEL TIPO DE ANCLA
        # =====================================================================
        if ($self->{show_labels} && $show->('vwap_labels')) {
            my $vwap_final = $vwap_vals->[-1];
            if (defined $vwap_final) {
                my $rel_end = $seg_end - $start_idx_vp;
                my $x_end   = ($rel_end - $offset_frac) * $candle_w + ($candle_w / 2);
                my $y_end   = $height - (($vwap_final - $min_val) / $range) * $height;

                # Solo dibujar si la etiqueta es visible en pantalla
                if ($x_end >= 0 && $x_end <= $width && $y_end >= 0 && $y_end <= $height) {
                    my $label_text = _anchor_label($type) . sprintf(" %.5g", $vwap_final);
                    $c->createText(
                        $x_end + 4, $y_end,
                        -text   => $label_text,
                        -fill   => $color,
                        -font   => 'Helvetica 8 bold',
                        -anchor => 'w',
                        -tags   => ['vwap_overlay'],
                    );
                }
            }
        }
    }

    # El overlay VWAP va sobre el histograma pero debajo de las velas
    $c->raise('vwap_overlay');
}

# =============================================================================
# HELPER: Texto breve para la etiqueta según tipo de ancla
# =============================================================================
sub _anchor_label {
    my ($type) = @_;
    my %labels = (
        session     => 'VWAP',
        market_open => 'VWAP(O)',
        bos         => 'VWAP-BOS',
        choch       => 'VWAP-CHoCH',
        poc_vp      => 'VWAP-POC',
        default     => 'VWAP',
    );
    return $labels{$type} // 'VWAP';
}

1;
