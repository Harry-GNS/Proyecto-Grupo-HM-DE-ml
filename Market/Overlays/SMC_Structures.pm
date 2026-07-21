package Market::Overlays::SMC_Structures;

use strict;
use warnings;
use utf8;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},
    };
    bless $self, $class;
    return $self;
}

sub render {
    my ($self, $scale, $smc_slice, $start_idx_viewport, $visibility) = @_;
    my $c = $self->{canvas};

    # Limpiar dibujos anteriores
    $c->delete('smc_overlay');

    return unless $smc_slice && @$smc_slice;
    $start_idx_viewport //= 0;

    # Helper de visibilidad: devuelve 1 (mostrar) salvo que la clave sea explícitamente 0
    $visibility //= {};
    my $show = sub { $visibility->{$_[0]} // 1 };

    my $width        = $c->width;
    my $height       = $c->height;
    my $min_val      = $scale->{min_val};
    my $max_val      = $scale->{max_val};
    my $visible_bars = $scale->{visible_bars};
    my $offset_frac  = $scale->{offset};

    my $range = $max_val - $min_val;
    return if $range <= 0;

    my $candle_width = $width / $visible_bars;

    # 1. Recopilar FVGs a dibujar
    my @fvgs_to_draw;
    if ($show->('fvg') && exists $smc_slice->[0]->{active_fvgs}) {
        push @fvgs_to_draw, @{ $smc_slice->[0]->{active_fvgs} };
    }

    for my $i (0 .. $#$smc_slice) {
        my $punto = $smc_slice->[$i];
        next if !$punto;

        if ($show->('fvg') && exists $punto->{fvgs} && @{ $punto->{fvgs} }) {
            push @fvgs_to_draw, @{ $punto->{fvgs} };
        }

        # ==================================================================
        # 2. EVENTOS DE RUPTURA (BOS y CHOCH)
        # ==================================================================
        if ($show->('bos_choch') && exists $punto->{events} && @{ $punto->{events} }) {
            for my $ev (@{ $punto->{events} }) {
                my $rel_origin = $ev->{origin} - $start_idx_viewport;
                my $rel_break  = $i;

                my $x_start = $scale->index_to_center_x($rel_origin);
                my $x_end   = $scale->index_to_center_x($rel_break);
                my $y       = $scale->value_to_y($ev->{price});

                my $color = $ev->{dir} eq 'bullish' ? '#2979FF' : '#FF5252';

                # Atenuación de línea de contratendencia (BOS/CHOCH) usando línea de guiones
                $c->createLine($x_start, $y, $x_end, $y,
                    -dash => '-', -fill => $color, -width => 1.5, -tags => ['smc_overlay']);
                $c->createText(($x_start + $x_end) / 2, $y - 8,
                    -text => $ev->{type}, -fill => $color,
                    -font => 'Helvetica 9 bold', -tags => ['smc_overlay']);
            }
        }

        # ==================================================================
        # 3. ETIQUETAS ESTRUCTURALES HH, HL, LH, LL
        # ==================================================================
        if ($show->('structure_labels')
            && defined $punto->{state} && $punto->{state} ne 'none')
        {
            my $x = $scale->index_to_center_x($i);
            my $y = $scale->value_to_y($punto->{price});
            my $oy = ($punto->{state} =~ /H$/) ? -15 : 15;

            $c->createText($x, $y + $oy,
                -text => $punto->{state}, -fill => '#d1d4dc',
                -font => 'Helvetica 8 bold', -tags => ['smc_overlay']);
        }
    }

    # ==================================================================
    # 4. FAIR VALUE GAPS
    # ==================================================================
    if ($show->('fvg')) {
        for my $fvg (@fvgs_to_draw) {
            my $rel_start = $fvg->{start_idx} - $start_idx_viewport;
            my $x1 = $scale->index_to_center_x($rel_start);
            my $x2;

            my $is_mitigated = defined $fvg->{mitigated_idx};

            if ($is_mitigated) {
                my $rel_end = $fvg->{mitigated_idx} - $start_idx_viewport;
                next if $rel_end < $offset_frac;
                $x2 = $scale->index_to_center_x($rel_end);
            } else {
                $x2 = $width + 2000;
            }

            my $y1 = $scale->value_to_y($fvg->{top});
            my $y2 = $scale->value_to_y($fvg->{bottom});

            my $color = $fvg->{type} eq 'bullish_fvg' ? '#2979FF' : '#FF5252';
            my $outline_dash = '-';
            
            # Regla de mitigación: atenuar canales obsoletos
            if ($is_mitigated) {
                $color = '#4B5563'; # Gris tenue
                $outline_dash = '.'; # Guiones muy finos
            }

            $c->createRectangle($x1, $y1, $x2, $y2,
                -fill => $color, -outline => $color, -stipple => 'gray25',
                -tags => ['smc_overlay']);
            $c->createLine($x1, ($y1+$y2)/2, $x2, ($y1+$y2)/2,
                -dash => $outline_dash, -fill => $color, -width => 1,
                -tags => ['smc_overlay']);
        }
    }

    $c->lower('smc_overlay');
}

1;