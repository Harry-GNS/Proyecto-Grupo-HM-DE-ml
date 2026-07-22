# This Perl code is a port of logic from:
#   "ZigZag Volume Profile [ChartPrime]" (Pine Script® v6)
#   Subject to the terms of the Mozilla Public License 2.0
#   https://mozilla.org/MPL/2.0/
#   © ChartPrime
#
# Port author: Proyecto-Machine-Learning
# Overlay de renderizado para Market::Indicators::ZigZag_Trend

package Market::Overlays::ZigZag_Trend;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas         => $args{canvas},
        color_bullish  => $args{color_bullish} || '#26a69a',  # verde teal
        color_bearish  => $args{color_bearish}  || '#ef5350',  # rojo
        line_width     => $args{line_width}     || 2,
    };
    bless $self, $class;
    return $self;
}

sub render {
    my ($self, $scale, $zz_indicator, $start_idx_viewport, $visibility) = @_;
    my $c = $self->{canvas};

    $c->delete('zigzag_overlay');

    $visibility //= {};
    return unless ($visibility->{zigzag} // 1);
    return unless $zz_indicator;
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

    # Tramos completados + tramo activo (si existe)
    my @all_segments = @{ $zz_indicator->completed_segments() // [] };
    push @all_segments, $zz_indicator->active_segment()
        if defined $zz_indicator->active_segment();

    # 2. Dibujar cada segmento del ZigZag como una línea
    for my $seg (@all_segments) {
        next unless defined $seg->{start_index} && defined $seg->{end_index};
        next unless defined $seg->{start_price} && defined $seg->{end_price};

        # Convertir índices absolutos a relativos a la ventana visible
        my $rel_from = $seg->{start_index} - $start_idx_viewport;
        my $rel_to   = $seg->{end_index}   - $start_idx_viewport;

        my $x1 = ($rel_from - $offset_frac) * $candle_width + ($candle_width / 2);
        my $x2 = ($rel_to   - $offset_frac) * $candle_width + ($candle_width / 2);

        my $y1 = $height - ((($seg->{start_price} - $min_val) / $range) * $height);
        my $y2 = $height - ((($seg->{end_price}   - $min_val) / $range) * $height);

        # Saltar segmentos completamente fuera de la pantalla
        next if ($x1 < 0 && $x2 < 0) || ($x1 > $width && $x2 > $width);

        my $color = ($seg->{direction} // '') eq 'bullish'
            ? $self->{color_bullish}
            : $self->{color_bearish};

        $c->createLine(
            $x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => $self->{line_width},
            -tags  => ['zigzag_overlay'],
        );
    }

    # 3. Dibujar marcadores en los pivotes confirmados
    my $ph = $zz_indicator->last_high_pivot();
    if (defined $ph && defined $ph->{index}) {
        my $rel = $ph->{index} - $start_idx_viewport;
        my $px  = ($rel - $offset_frac) * $candle_width + ($candle_width / 2);
        my $py  = $scale->value_to_y($ph->{price});
        my $r   = 4;
        if ($px >= -$r && $px <= $width + $r) {
            $c->createOval(
                $px - $r, $py - $r, $px + $r, $py + $r,
                -fill    => $self->{color_bearish},
                -outline => $self->{color_bearish},
                -tags    => ['zigzag_overlay'],
            );
        }
    }

    my $pl = $zz_indicator->last_low_pivot();
    if (defined $pl && defined $pl->{index}) {
        my $rel = $pl->{index} - $start_idx_viewport;
        my $px  = ($rel - $offset_frac) * $candle_width + ($candle_width / 2);
        my $py  = $scale->value_to_y($pl->{price});
        my $r   = 4;
        if ($px >= -$r && $px <= $width + $r) {
            $c->createOval(
                $px - $r, $py - $r, $px + $r, $py + $r,
                -fill    => $self->{color_bullish},
                -outline => $self->{color_bullish},
                -tags    => ['zigzag_overlay'],
            );
        }
    }

    # Empujar el overlay de zigzag debajo de las velas para no taparlas
    $c->lower('zigzag_overlay');
}

1;
