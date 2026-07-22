package Market::Overlays::ZonaInterna;

use strict;
use warnings;
use utf8;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},
        # Colores para ratios específicos de Fibonacci
        colors => {
            '0.618' => '#2962FF',  # Azul fuerte
            '0.786' => '#d32f2f',  # Rojo fuerte
            '1'     => '#388e3c',  # Verde
            '1.272' => '#7b1fa2',  # Morado
            '1.414' => '#fbc02d',  # Amarillo oscuro
            '1.618' => '#e64a19',  # Naranja
        },
        default_color => '#78909c', # Gris
    };
    bless $self, $class;
    return $self;
}

sub render {
    my ($self, $scale, $zi_levels, $start_idx_viewport, $visibility) = @_;
    my $c = $self->{canvas};

    $c->delete('zona_interna_overlay');

    $visibility //= {};
    return unless ($visibility->{zona_interna} // 1);
    return unless $zi_levels && @$zi_levels;

    $start_idx_viewport //= 0;

    my $width        = $c->width;
    my $height       = $c->height;
    my $min_val      = $scale->{min_val};
    my $max_val      = $scale->{max_val};
    my $visible_bars = $scale->{visible_bars};
    my $offset_frac  = $scale->{offset};

    my $range = $max_val - $min_val;
    return if $range <= 0;

    my $candle_width = $width / $visible_bars;
    my $right_margin_x = $width - 70; # Límite del área de dibujo antes de la escala Y

    for my $lvl (@$zi_levels) {
        next unless defined $lvl->{x1_index} && defined $lvl->{price};

        # Convertir x1 a píxeles
        my $rel_from = $lvl->{x1_index} - $start_idx_viewport;
        my $x1 = ($rel_from - $offset_frac) * $candle_width + ($candle_width / 2);
        
        # Extender hacia la derecha hasta el margen de precios
        my $x2 = $right_margin_x;

        # Omitir si la línea empieza a la derecha del gráfico
        next if $x1 > $right_margin_x;
        $x1 = 0 if $x1 < 0; # Limitar por la izquierda

        my $y = $scale->value_to_y($lvl->{price});

        # Elegir color basado en el ratio
        my $ratio_str = sprintf("%.3f", $lvl->{ratio});
        $ratio_str =~ s/0+$//;
        $ratio_str =~ s/\.$//;

        my $color = $self->{colors}->{$ratio_str} // $self->{default_color};

        # Dibujar línea horizontal
        $c->createLine(
            $x1, $y, $x2, $y,
            -fill  => $color,
            -width => 1.5,
            -dash  => '-',
            -tags  => ['zona_interna_overlay'],
        );

        # Escribir la etiqueta (ratio y precio redondeado) justo antes del margen derecho
        $c->createText(
            $x2 - 5, $y - 8,
            -text   => $lvl->{text},
            -fill   => $color,
            -font   => 'Helvetica 8 bold',
            -anchor => 'e',
            -tags   => ['zona_interna_overlay'],
        );
    }

    $c->lower('zona_interna_overlay');
}

1;
