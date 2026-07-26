package Market::Overlays::Strategy_Builder;

use strict;
use warnings;
use utf8;

# ============================================================
#  Market::Overlays::Strategy_Builder
#
#  Dibuja el resultado de Market::Indicators::Strategy_Builder.
#  No calcula nada: consume el hash que IndicatorManager deja en
#  el cache bajo 'Strategy_Builder_raw' (paso 9 de recalculate_all).
#
#  Capas, cada una con su flag de visibilidad:
#    - sd_zones       Supply / Demand            (requisito 10)
#    - sr_htf         S/R de 4h, diario, semanal (requisito 6)
#    - sb_channels    Canales de tendencia       (requisito 11)
#    - sb_trendlines  Trendlines sueltas
#    - daily_levels   Cuerpo/mecha de la vela diaria previa
#
#  No dibuja Order Blocks ni FVG: ya los dibuja
#  Market::Overlays::SMC_Structures y se duplicarian en pantalla.
#  Tampoco VWAP, Volume Profile ni Fibonacci, que tienen overlay propio.
# ============================================================

# Tope de elementos por capa. El indicador emite miles de zonas sobre el
# historico completo; dibujarlas todas satura el canvas sin aportar nada,
# asi que se conservan las mas recientes dentro del viewport.
use constant MAX_ZONES => 40;

sub new {
    my ($class, %args) = @_;

    my $self = {
        canvas          => $args{canvas},
        color_supply    => $args{color_supply}    || '#FF5252',
        color_demand    => $args{color_demand}    || '#00E676',
        color_channel   => $args{color_channel}   || '#7E57C2',
        color_trendline => $args{color_trendline} || '#78909C',
        color_daily     => $args{color_daily}     || '#FF9100',
        # Un color por temporalidad alta, para distinguir los S/R de un vistazo
        color_sr        => $args{color_sr} || {
            '4h' => '#00B0FF',
            'D'  => '#FFD600',
            'W'  => '#E040FB',
        },
    };

    bless $self, $class;
    return $self;
}

# --- render -------------------------------------------------
# Input : $scale              -> Market::Panels::Scales
#         $sb                 -> hash de Strategy_Builder (o undef)
#         $start_idx_viewport -> indice absoluto de la primera vela visible
#         $visibility         -> hash de flags del ChartEngine
# Output: ninguno (efecto sobre el canvas)
sub render {
    my ($self, $scale, $sb, $start_idx_viewport, $visibility) = @_;

    my $c = $self->{canvas};
    $c->delete('strategy_overlay');

    return unless $sb && ref($sb) eq 'HASH';
    return unless $scale;

    $visibility //= {};
    my $show = sub { $visibility->{ $_[0] } // 1 };
    return unless $show->('strategy');          # master switch

    my $range = ($scale->{max_val} // 0) - ($scale->{min_val} // 0);
    return if $range <= 0;

    $start_idx_viewport //= 0;

    my %ctx = (
        canvas    => $c,
        scale     => $scale,
        vp_origin => $start_idx_viewport,
        vp_start  => $start_idx_viewport,
        vp_end    => $start_idx_viewport + ($scale->{visible_bars} // 0) + 2,
        width     => $c->width,
        height    => $c->height,
    );

    $self->_draw_zones(\%ctx, $sb)        if $show->('sd_zones');
    $self->_draw_channels(\%ctx, $sb)     if $show->('sb_channels');
    $self->_draw_trendlines(\%ctx, $sb)   if $show->('sb_trendlines');
    $self->_draw_daily_levels(\%ctx, $sb) if $show->('daily_levels');
    $self->_draw_htf_sr(\%ctx, $sb)       if $show->('sr_htf');

    # Debajo de las velas, para no taparlas.
    $c->lower('strategy_overlay');

    return;
}

# Indice absoluto de vela -> coordenada X del centro de esa vela.
sub _x_of {
    my ($ctx, $abs_index) = @_;
    return $ctx->{scale}->index_to_center_x($abs_index - $ctx->{vp_origin});
}

# =============================================================================
# Requisito 10: zonas de Supply / Demand (indicador DIY)
# =============================================================================
sub _draw_zones {
    my ($self, $ctx, $sb) = @_;

    my @zones;
    for my $spec (['supply_zones', $self->{color_supply}],
                  ['demand_zones', $self->{color_demand}]) {
        my ($key, $color) = @$spec;

        for my $z (@{ $sb->{$key} // [] }) {
            next unless defined $z->{high} && defined $z->{low};
            next unless defined $z->{start_index};

            # Una zona mitigada ya no es liquidez util: no se dibuja.
            next unless $z->{active};

            my $end = $z->{end_index} // $ctx->{vp_end};
            next if $end              < $ctx->{vp_start};
            next if $z->{start_index} > $ctx->{vp_end};

            push @zones, { %$z, _color => $color, _end => $end };
        }
    }

    # Las mas recientes primero: son las que el precio todavia puede visitar.
    @zones = sort { ($b->{start_index} // 0) <=> ($a->{start_index} // 0) } @zones;
    @zones = @zones[0 .. MAX_ZONES - 1] if @zones > MAX_ZONES;

    my $c = $ctx->{canvas};
    for my $z (@zones) {
        my $x1 = _x_of($ctx, $z->{start_index});
        my $x2 = _x_of($ctx, $z->{_end});
        $x2 = $ctx->{width} if $x2 > $ctx->{width};
        next if $x2 <= $x1;

        my $y1 = $ctx->{scale}->value_to_y($z->{high});
        my $y2 = $ctx->{scale}->value_to_y($z->{low});
        next if $y2 < -100 || $y1 > $ctx->{height} + 100;

        $c->createRectangle(
            $x1, $y1, $x2, $y2,
            -fill    => $z->{_color},
            -outline => $z->{_color},
            -stipple => 'gray25',
            -tags    => ['strategy_overlay'],
        );
    }

    return;
}

# =============================================================================
# Requisito 11: canales de tendencia
# =============================================================================
sub _draw_channels {
    my ($self, $ctx, $sb) = @_;

    my $c = $ctx->{canvas};

    for my $ch (@{ $sb->{channels} // [] }) {
        my ($i1, $i2) = ($ch->{start_index}, $ch->{end_index});
        next unless defined $i1 && defined $i2;
        next if $i2 < $ctx->{vp_start} || $i1 > $ctx->{vp_end};

        my $x1 = _x_of($ctx, $i1);
        my $x2 = _x_of($ctx, $i2);

        # Un canal roto va punteado, para no confundirlo con uno vigente.
        my $dash = $ch->{active} ? undef : '-';

        for my $edge (['upper_y1', 'upper_y2'], ['lower_y1', 'lower_y2']) {
            my ($ka, $kb) = @$edge;
            next unless defined $ch->{$ka} && defined $ch->{$kb};

            $c->createLine(
                $x1, $ctx->{scale}->value_to_y($ch->{$ka}),
                $x2, $ctx->{scale}->value_to_y($ch->{$kb}),
                -fill  => $self->{color_channel},
                -width => 2,
                ($dash ? (-dash => $dash) : ()),
                -tags  => ['strategy_overlay'],
            );
        }

        # Etiqueta con lo que el documento exige poder validar: duracion y toques.
        next unless defined $ch->{upper_y1};
        $c->createText(
            $x1 + 4, $ctx->{scale}->value_to_y($ch->{upper_y1}) - 8,
            -text   => sprintf('CANAL %s %smin %dt',
                            $ch->{direction}        // '?',
                            $ch->{duration_minutes} // '?',
                            $ch->{total_touches}    // 0),
            -fill   => $self->{color_channel},
            -anchor => 'w',
            -font   => 'Helvetica 7',
            -tags   => ['strategy_overlay'],
        );
    }

    return;
}

sub _draw_trendlines {
    my ($self, $ctx, $sb) = @_;

    my $c = $ctx->{canvas};

    for my $tl (@{ $sb->{trendlines} // [] }) {
        my ($i1, $i2) = ($tl->{start_index}, $tl->{end_index});
        next unless defined $i1 && defined $i2;
        next unless defined $tl->{y1} && defined $tl->{y2};
        next if $i2 < $ctx->{vp_start} || $i1 > $ctx->{vp_end};

        $c->createLine(
            _x_of($ctx, $i1), $ctx->{scale}->value_to_y($tl->{y1}),
            _x_of($ctx, $i2), $ctx->{scale}->value_to_y($tl->{y2}),
            -fill  => $self->{color_trendline},
            -width => 1,
            -tags  => ['strategy_overlay'],
        );
    }

    return;
}

# =============================================================================
# Niveles de cuerpo/mecha de la vela diaria previa
# =============================================================================
sub _draw_daily_levels {
    my ($self, $ctx, $sb) = @_;

    my $c = $ctx->{canvas};

    for my $lv (@{ $sb->{daily_levels} // [] }) {
        next unless defined $lv->{price} && defined $lv->{start_index};

        my $end = $lv->{end_index} // $lv->{start_index};
        next if $end < $ctx->{vp_start} || $lv->{start_index} > $ctx->{vp_end};

        my $y = $ctx->{scale}->value_to_y($lv->{price});
        next if $y < -50 || $y > $ctx->{height} + 50;

        my $x1 = _x_of($ctx, $lv->{start_index});
        my $x2 = _x_of($ctx, $end);

        $c->createLine(
            $x1, $y, $x2, $y,
            -fill  => $self->{color_daily},
            -width => 1,
            -dash  => '.',
            -tags  => ['strategy_overlay'],
        );
        $c->createText(
            $x1 + 3, $y - 6,
            -text   => $lv->{label} // '',
            -fill   => $self->{color_daily},
            -anchor => 'w',
            -font   => 'Helvetica 7',
            -tags   => ['strategy_overlay'],
        );
    }

    return;
}

# =============================================================================
# Requisito 6: soportes/resistencias de 4h, diario y semanal
#
# Sus indices pertenecen al espacio de velas de SU temporalidad, no al del
# grafico, asi que no se pueden posicionar en X: se dibujan como niveles
# horizontales de ancho completo, que es ademas como se leen en la practica.
# Solo interesa el juego vigente (el derivado de la ultima vela cerrada de
# cada temporalidad), no el historico entero.
# =============================================================================
sub _draw_htf_sr {
    my ($self, $ctx, $sb) = @_;

    my $by_tf = $sb->{support_resistance_by_tf};
    return unless $by_tf && ref($by_tf) eq 'HASH';

    my $c = $ctx->{canvas};

    for my $tf (sort keys %$by_tf) {
        my $levels = $by_tf->{$tf} // [];
        next unless @$levels;

        my $color = $self->{color_sr}{$tf} // '#B0BEC5';

        for my $lv (_latest_sr_set($levels)) {
            next unless defined $lv->{price};

            my $y = $ctx->{scale}->value_to_y($lv->{price});
            next if $y < 0 || $y > $ctx->{height};

            $c->createLine(
                0, $y, $ctx->{width}, $y,
                -fill  => $color,
                -width => 1,
                -dash  => '2 4',
                -tags  => ['strategy_overlay'],
            );
            $c->createText(
                4, $y - 6,
                -text   => sprintf('%s %s  %.2f', $tf, $lv->{label} // '', $lv->{price}),
                -fill   => $color,
                -anchor => 'w',
                -font   => 'Helvetica 7',
                -tags   => ['strategy_overlay'],
            );
        }
    }

    return;
}

# Devuelve los niveles derivados de la ultima vela cerrada de la serie, es
# decir los que comparten el source_index mas alto.
sub _latest_sr_set {
    my ($levels) = @_;

    my $max_src = -1;
    for my $lv (@$levels) {
        my $s = $lv->{source_index};
        $max_src = $s if defined $s && $s > $max_src;
    }
    return () if $max_src < 0;

    return grep { defined $_->{source_index} && $_->{source_index} == $max_src } @$levels;
}

1;
