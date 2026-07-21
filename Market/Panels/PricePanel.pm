package Market::Panels::PricePanel;

use strict;
use warnings;
use List::Util qw(min max);

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas    => $args{canvas},
        scale     => undef,
        crosshair => {},
    };
    bless $self, $class;
    $self->_init_crosshair_objects();
    return $self;
}

sub _init_crosshair_objects {
    my ($self) = @_;
    my $c = $self->{canvas};

    $self->{crosshair}->{vline} = $c->createLine(0,0,0,0, -fill=>'#9598a1', -dash=>'.', -state=>'hidden');
    $self->{crosshair}->{hline} = $c->createLine(0,0,0,0, -fill=>'#9598a1', -dash=>'.', -state=>'hidden');

    $self->{crosshair}->{y_bg}   = $c->createRectangle(0,0,0,0, -fill=>'#2962FF', -outline=>'#2962FF', -state=>'hidden');
    $self->{crosshair}->{y_text} = $c->createText(0,0, -text=>'', -fill=>'white', -anchor=>'e', -state=>'hidden');

    $self->{crosshair}->{x_bg}   = $c->createRectangle(0,0,0,0, -fill=>'#2962FF', -outline=>'#2962FF', -state=>'hidden');
    $self->{crosshair}->{x_text} = $c->createText(0,0, -text=>'', -fill=>'white', -anchor=>'s', -state=>'hidden');

    $self->{crosshair}->{ohlc_text} = $c->createText(
        10, 10,
        -text   => '',
        -fill   => '#d1d4dc',
        -anchor => 'nw',
        -font   => ['Helvetica', 10, 'bold']
    );
}

sub get_y_range {
    my ($self, $data_slice) = @_;
    return (0, 1) unless @$data_slice;

    my $min_price = $data_slice->[0]->{low};
    my $max_price = $data_slice->[0]->{high};

    foreach my $candle (@$data_slice) {
        $min_price = min($min_price, $candle->{low});
        $max_price = max($max_price, $candle->{high});
    }

    my $padding = ($max_price - $min_price) * 0.05;
    return ($min_price - $padding, $max_price + $padding);
}

sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

sub render {
    my ($self, $data_slice) = @_;

    $self->{current_slice} = $data_slice;

    my $c = $self->{canvas};
    my $s = $self->{scale};

    return unless $s && @$data_slice;

    $c->delete('candle');
    $c->delete('volume');

    $self->draw_time_axis($data_slice);
    $self->draw_volume($data_slice);

    # ================================================================
    # DIBUJAR VELAS ANCLADAS AL PIVOTE (primera vela del día)
    # El índice visual de cada vela se calcula respecto al pivote del
    # día al que pertenece, para que el grid no se desplace con el drag.
    # ================================================================
    for my $i (0 .. $#{$data_slice}) {
        my $candle = $data_slice->[$i];

        my $x_left   = $s->index_to_x($i);
        my $x_right  = $s->index_to_x($i + 1) - 1;
        my $x_center = $s->index_to_center_x($i);

        my $y_open  = $s->value_to_y($candle->{open});
        my $y_close = $s->value_to_y($candle->{close});
        my $y_high  = $s->value_to_y($candle->{high});
        my $y_low   = $s->value_to_y($candle->{low});

        my $color = ($candle->{close} >= $candle->{open}) ? '#089981' : '#F23645';

        $c->createLine($x_center, $y_high, $x_center, $y_low,
            -fill => $color, -tags => 'candle');

        $c->createRectangle($x_left, $y_open, $x_right, $y_close,
            -fill => $color, -outline => $color, -tags => 'candle');
    }

    $s->_draw_y_scale($c);
    $self->render_last_visible_price($data_slice);
}

sub render_last_visible_price {
    my ($self, $data_slice) = @_;
    my $c = $self->{canvas};

    $c->delete('last_price_label');
    return unless @$data_slice;

    my $last_candle = $data_slice->[-1];
    my $price = $last_candle->{close};
    my $y_pos = $self->{scale}->value_to_y($price);
    my $width = $self->{scale}->{width};
    my $chart_end_x = $self->{scale}->_drawable_width();

    my $color = ($price >= $last_candle->{open}) ? '#089981' : '#F23645';
    my $display_val = sprintf("%.2f", $price);

    # Línea horizontal de último precio punteada estilo TradingView
    $c->createLine(
        0, $y_pos, $chart_end_x, $y_pos,
        -fill  => $color,
        -dash  => '.',
        -width => 1,
        -tags  => 'last_price_label'
    );

    my $text_id = $c->createText(
        $width - 5, $y_pos,
        -text   => $display_val,
        -fill   => 'white',
        -anchor => 'e',
        -font   => ['Helvetica', 10, 'bold'],
        -tags   => 'last_price_label'
    );

    my @bbox = $c->bbox($text_id);
    if (@bbox) {
        my ($x1,$y1,$x2,$y2) = ($bbox[0]-4, $bbox[1]-2, $bbox[2]+4, $bbox[3]+2);
        my $bg_id = $c->createRectangle($x1,$y1,$x2,$y2,
            -fill=>$color, -outline=>$color, -tags=>'last_price_label');
        $c->lower($bg_id, $text_id);
    }
}

sub draw_crosshair {
    my ($self, $x, $y) = @_;
    my $c = $self->{canvas};
    my $s = $self->{scale};

    if (!defined $x || !$s || !$self->{current_slice}) {
        if (exists $self->{crosshair}->{ohlc_text} && $self->{current_slice} && @{$self->{current_slice}}) {
            my $last = $self->{current_slice}->[-1];
            my $change = $last->{close} - $last->{open};
            my $pct = $last->{open} > 0 ? ($change / $last->{open}) * 100 : 0;
            my $sign = $change >= 0 ? '+' : '';
            my $ohlc_str = sprintf("NQ1! · 1m · TradingView   O: %.2f   H: %.2f   L: %.2f   C: %.2f   %s%.2f (%s%.2f%%)",
                $last->{open}, $last->{high}, $last->{low}, $last->{close}, $sign, $change, $sign, $pct);
            $c->itemconfigure($self->{crosshair}->{ohlc_text}, -text => $ohlc_str);
            $c->raise($self->{crosshair}->{ohlc_text});
        }
        foreach my $key (qw(vline hline y_bg y_text x_bg x_text)) {
            $c->itemconfigure($self->{crosshair}->{$key}, -state => 'hidden')
                if exists $self->{crosshair}->{$key};
        }
        return;
    }

    my $width  = $s->{width};
    my $height = $s->{height};

    # Línea vertical
    $c->coords($self->{crosshair}->{vline}, $x, 0, $x, $height);
    $c->itemconfigure($self->{crosshair}->{vline}, -state => 'normal');

    # Calcular índice bajo el cursor usando el scale correcto
    my $float_idx = $s->x_to_index_float($x);
    my $local_index = int($float_idx);

    my $ts    = "";
    my $slice = $self->{current_slice};

    if ($local_index >= 0 && $local_index < @$slice) {
        my $hovered = $slice->[$local_index];

        # Crosshair X: fecha completa + hora  "DD/MM/AAAA HH:MM"
        my $raw = $hovered->{timestamp};
        if ($raw =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}:\d{2})/) {
            $ts = "$3/$2/$1 $4";
        }

        if (exists $self->{crosshair}->{ohlc_text}) {
            my $change = $hovered->{close} - $hovered->{open};
            my $pct = $hovered->{open} > 0 ? ($change / $hovered->{open}) * 100 : 0;
            my $sign = $change >= 0 ? '+' : '';
            my $ohlc_str = sprintf("NQ1! · 1m · TradingView   O: %.2f   H: %.2f   L: %.2f   C: %.2f   %s%.2f (%s%.2f%%)",
                $hovered->{open}, $hovered->{high}, $hovered->{low}, $hovered->{close}, $sign, $change, $sign, $pct);
            $c->itemconfigure($self->{crosshair}->{ohlc_text}, -text => $ohlc_str);
        }
    }

    $c->coords($self->{crosshair}->{x_text}, $x, $height - 10);
    $c->itemconfigure($self->{crosshair}->{x_text}, -text => $ts, -state => 'normal');

    my @x_bbox = $c->bbox($self->{crosshair}->{x_text});
    if (@x_bbox && $ts ne "") {
        $c->coords($self->{crosshair}->{x_bg}, $x_bbox[0]-4, $x_bbox[1]-2, $x_bbox[2]+4, $x_bbox[3]+2);
        $c->itemconfigure($self->{crosshair}->{x_bg}, -state => 'normal');
    } else {
        $c->itemconfigure($self->{crosshair}->{x_bg}, -state => 'hidden');
    }

# Eje Y
    if (defined $y) {
        my $raw_val  = $s->y_to_value($y);
        
        # Redondeo exacto al 0.25 más cercano
        my $val = int(($raw_val / 0.25) + 0.5) * 0.25;
        my $snapped_y = $s->value_to_y($val);

        $c->coords($self->{crosshair}->{hline}, 0, $snapped_y, $width, $snapped_y);
        $c->itemconfigure($self->{crosshair}->{hline}, -state => 'normal');

        # Formateo estricto a 2 decimales
        my $display_val = sprintf("%.2f", $val);
        
        $c->coords($self->{crosshair}->{y_text}, $width - 5, $snapped_y);
        $c->itemconfigure($self->{crosshair}->{y_text}, -text => $display_val, -state => 'normal');

        my @y_bbox = $c->bbox($self->{crosshair}->{y_text});
        if (@y_bbox) {
            $c->coords($self->{crosshair}->{y_bg}, $y_bbox[0]-4, $y_bbox[1]-2, $y_bbox[2]+4, $y_bbox[3]+2);
            $c->itemconfigure($self->{crosshair}->{y_bg}, -state => 'normal');
        }
    } else {
        $c->itemconfigure($self->{crosshair}->{hline},  -state => 'hidden');
        $c->itemconfigure($self->{crosshair}->{y_bg},   -state => 'hidden');
        $c->itemconfigure($self->{crosshair}->{y_text}, -state => 'hidden');
    }

    $c->raise($self->{crosshair}->{vline});
    $c->raise($self->{crosshair}->{x_bg});
    $c->raise($self->{crosshair}->{x_text});
    if (defined $y) {
        $c->raise($self->{crosshair}->{hline});
        $c->raise($self->{crosshair}->{y_bg});
        $c->raise($self->{crosshair}->{y_text});
    }
    $c->raise($self->{crosshair}->{ohlc_text}) if exists $self->{crosshair}->{ohlc_text};
}

# ================================================================
# ESCALA DE TIEMPO ESTILO TRADINGVIEW
#
# Reglas (igual que TV):
#   - Si la vela es la PRIMERA DEL DÍA → mostrar "DD/MM" (pivote)
#   - Si NO es primera del día          → mostrar "HH:MM"
#   - Las etiquetas se recalculan en cada render (se mueven con drag)
#   - El pivote lleva una línea vertical más brillante
#   - Espaciado mínimo entre etiquetas para evitar solapamiento
# ================================================================
sub draw_time_axis {
    my ($self, $data_slice) = @_;
    my $c = $self->{canvas};
    my $s = $self->{scale};

    return unless @$data_slice;

    my $height       = $s->{height};
    my $chart_width  = $s->_drawable_width();
    my $n            = @$data_slice;

    $c->delete('time_axis');

    # --- Paso 1: marcar índices pivote (primera vela de cada día) ---
    my %is_pivot;
    my $prev_day = '';
    for my $i (0 .. $n - 1) {
        my $ts = $data_slice->[$i]->{timestamp};
        if ($ts =~ /(\d{4}-\d{2}-\d{2})T/) {
            my $day = $1;
            if ($day ne $prev_day) {
                $is_pivot{$i} = $day;
                $prev_day = $day;
            }
        }
    }

    # --- Paso 2: calcular paso mínimo entre etiquetas ---
    # Queremos etiquetas cada ~80px como mínimo (evitar solapamiento)
    my $min_px_gap   = 80;
    my $candle_w     = $chart_width / $s->{visible_bars};
    my $min_idx_gap  = ($candle_w > 0) ? int($min_px_gap / $candle_w) : 1;
    $min_idx_gap     = 1 if $min_idx_gap < 1;

    # --- Paso 3: seleccionar qué índices dibujar ---
    # Siempre incluimos los pivotes, y llenamos el resto respetando el gap
    my @label_indices;
    my $last_drawn = -9999;

    for my $i (0 .. $n - 1) {
        my $is_piv = exists $is_pivot{$i};
        if ($is_piv || ($i - $last_drawn) >= $min_idx_gap) {
            push @label_indices, $i;
            $last_drawn = $i;
        }
    }

    # --- Paso 4: dibujar ---
    for my $i (@label_indices) {
        my $candle = $data_slice->[$i];
        my $x      = $s->index_to_center_x($i);
        my $ts     = $candle->{timestamp};

        my ($label, $is_piv);
        if (exists $is_pivot{$i}) {
            # Pivote → mostrar fecha corta  "DD/MM"
            if ($ts =~ /\d{4}-(\d{2})-(\d{2})T/) {
                $label = "$2/$1";
            }
            $is_piv = 1;
        } else {
            # Hora normal → solo "HH:MM"
            if ($ts =~ /T(\d{2}:\d{2})/) {
                $label = $1;
            }
            $is_piv = 0;
        }

        next unless defined $label;

        # Línea vertical de fondo
        if ($is_piv) {
            # Pivote: línea más brillante y sólida
            $c->createLine($x, 0, $x, $height,
                -fill  => '#4a4f66',
                -width => 1,
                -tags  => 'time_axis'
            );
        } else {
            $c->createLine($x, 0, $x, $height,
                -fill => '#2a2e39',
                -dash => '.',
                -tags => 'time_axis'
            );
        }

        # Texto de la etiqueta
        $c->createText(
            $x, $height - 10,
            -text   => $label,
            -fill   => $is_piv ? '#ffffff' : '#d1d4dc',
            -anchor => 's',
            -font   => $is_piv ? ['Helvetica', 9, 'bold'] : ['Helvetica', 9],
            -tags   => 'time_axis'
        );
    }
}

sub draw_volume {
    my ($self, $data_slice) = @_;
    my $c = $self->{canvas};
    my $s = $self->{scale};

    return unless @$data_slice;

    my $max_vol = 0;
    foreach my $candle (@$data_slice) {
        $max_vol = $candle->{volume} if $candle->{volume} > $max_vol;
    }
    return if $max_vol == 0;

    my $height         = $s->{height};
    my $bottom_padding = 25;
    my $max_bar_height = ($height - $bottom_padding) * 0.20;

    for my $i (0 .. $#{$data_slice}) {
        my $candle = $data_slice->[$i];
        my $vol    = $candle->{volume};
        next unless $vol > 0;

        my $bar_height = ($vol / $max_vol) * $max_bar_height;
        my $x_left     = $s->index_to_x($i);
        my $x_right    = $s->index_to_x($i + 1) - 1;
        my $y_bottom   = $height - $bottom_padding;
        my $y_top      = $y_bottom - $bar_height;
        my $color      = ($candle->{close} >= $candle->{open}) ? '#1d5c4d' : '#7a2524';

        $c->createRectangle($x_left, $y_top, $x_right, $y_bottom,
            -fill => $color, -outline => $color, -tags => 'volume');
    }
}

1;
