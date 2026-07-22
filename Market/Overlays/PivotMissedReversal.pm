package Market::Overlays::PivotMissedReversal;

use strict;
use warnings;
use utf8;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas              => $args{canvas},
        color_regular_high  => '#f44336',  # rojo
        color_regular_low   => '#4caf50',  # verde
        color_missed_high   => '#ff9800',  # naranja
        color_missed_low    => '#9c27b0',  # morado
        color_ghost_high    => '#ffb74d',  # naranja claro
        color_ghost_low     => '#b39ddb',  # morado claro
    };
    bless $self, $class;
    return $self;
}

sub render {
    my ($self, $scale, $pmr_raw, $start_idx_viewport, $visibility) = @_;
    my $c = $self->{canvas};

    $c->delete('pmr_overlay');

    $visibility //= {};
    return unless ($visibility->{pivot_missed} // 1);
    return unless $pmr_raw;

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

    # 1. Dibujar segmentos
    if ($visibility->{pmr_regular} // 1) {
        my $segments = $pmr_raw->{segments} // [];
        for my $seg (@$segments) {
            next unless defined $seg->{x1_index} && defined $seg->{x2_index};
            next unless defined $seg->{y1_price} && defined $seg->{y2_price};

            my $rel_from = $seg->{x1_index} - $start_idx_viewport;
            my $rel_to   = $seg->{x2_index} - $start_idx_viewport;

            my $x1 = ($rel_from - $offset_frac) * $candle_width + ($candle_width / 2);
            my $x2 = ($rel_to   - $offset_frac) * $candle_width + ($candle_width / 2);

            my $y1 = $height - ((($seg->{y1_price} - $min_val) / $range) * $height);
            my $y2 = $height - ((($seg->{y2_price} - $min_val) / $range) * $height);

            next if ($x1 < 0 && $x2 < 0) || ($x1 > $width && $x2 > $width);

            my $color = ($seg->{color_role} // '') =~ /high/i ? $self->{color_regular_high} : $self->{color_regular_low};
            if (($seg->{source} // '') eq 'missed_low' || ($seg->{source} // '') eq 'missed_high' || ($seg->{source} // '') =~ /missed/i) {
                $color = ($seg->{color_role} // '') =~ /high/i ? $self->{color_missed_high} : $self->{color_missed_low};
            }

            my $style = $seg->{line_style} // $seg->{style} // 'solid';
            my $dash = $style eq 'dashed' ? '-' : undef;

            $c->createLine(
                $x1, $y1, $x2, $y2,
                -fill  => $color,
                -width => 1.5,
                ($dash ? (-dash => $dash) : ()),
                -tags  => ['pmr_overlay'],
            );
        }
    }

    # 2. Dibujar Ghost Levels (horizontales)
    if ($visibility->{pmr_ghost} // 1) {
        my $ghosts = $pmr_raw->{ghostLevels} // [];
        
        # Combinar con provisional ghost level si está disponible
        my @all_ghosts = @$ghosts;
        if (defined $pmr_raw->{provisionalPivot} && defined $pmr_raw->{provisionalPivot}{ghostLevel}) {
            push @all_ghosts, $pmr_raw->{provisionalPivot}{ghostLevel};
        }

        for my $g (@all_ghosts) {
            next unless defined $g->{x1_index} && defined $g->{x2_index};
            next unless defined $g->{y1_price};

            my $rel_from = $g->{x1_index} - $start_idx_viewport;
            my $rel_to   = $g->{x2_index} - $start_idx_viewport;

            my $x1 = ($rel_from - $offset_frac) * $candle_width + ($candle_width / 2);
            my $x2 = ($rel_to   - $offset_frac) * $candle_width + ($candle_width / 2);
            my $y  = $scale->value_to_y($g->{y1_price});

            # Dibujar extendiendo hacia la derecha si está activo
            $x2 = $width + 100 if ($g->{active} // 0) || ($g->{status} // '') eq 'temporary';

            next if $x1 > $width && $x2 > $width;

            my $color = ($g->{type} // '') eq 'high' ? $self->{color_ghost_high} : $self->{color_ghost_low};
            my $dash = '.'; # Guiones punteados para niveles fantasma

            $c->createLine(
                $x1, $y, $x2, $y,
                -fill  => $color,
                -width => 1,
                -dash  => $dash,
                -tags  => ['pmr_overlay'],
            );
        }
    }

    # 3. Dibujar Pivots Regulares
    if ($visibility->{pmr_regular} // 1) {
        my $pivots = $pmr_raw->{regularPivots} // [];
        for my $p (@$pivots) {
            next unless defined $p->{index} && defined $p->{price};

            my $rel = $p->{index} - $start_idx_viewport;
            my $px  = ($rel - $offset_frac) * $candle_width + ($candle_width / 2);
            my $py  = $scale->value_to_y($p->{price});
            my $oy  = ($p->{type} // '') eq 'high' ? -12 : 12;

            next if $px < -20 || $px > $width + 20;

            my $color = ($p->{type} // '') eq 'high' ? $self->{color_regular_high} : $self->{color_regular_low};

            $c->createText(
                $px, $py + $oy,
                -text => $p->{label} // (($p->{type} // '') eq 'high' ? '▼' : '▲'),
                -fill => $color,
                -font => 'Helvetica 9 bold',
                -tags => ['pmr_overlay'],
            );
        }
    }

    # 4. Dibujar Missed Pivots (Ghost pivots 👻)
    if ($visibility->{pmr_missed} // 1) {
        my $missed = $pmr_raw->{missedPivots} // [];
        
        # Agregar provisional pivot si está disponible
        my @all_missed = @$missed;
        if (defined $pmr_raw->{provisionalPivot}) {
            push @all_missed, $pmr_raw->{provisionalPivot};
        }

        for my $p (@all_missed) {
            next unless defined $p->{index} && defined $p->{price};

            my $rel = $p->{index} - $start_idx_viewport;
            my $px  = ($rel - $offset_frac) * $candle_width + ($candle_width / 2);
            my $py  = $scale->value_to_y($p->{price});
            my $oy  = ($p->{type} // '') eq 'high' ? -12 : 12;

            next if $px < -20 || $px > $width + 20;

            my $color = ($p->{type} // '') eq 'high' ? $self->{color_missed_high} : $self->{color_missed_low};

            my $cy = $py + $oy;
            my $r = 7;

            # Círculo medalla de fondo en color contrastante con borde blanco
            $c->createOval(
                $px - $r, $cy - $r,
                $px + $r, $cy + $r,
                -fill    => $color,
                -outline => '#ffffff',
                -width   => 1,
                -tags    => ['pmr_overlay'],
            );

            # Texto "G" (Ghost) en negrita centrado dentro de la medalla
            $c->createText(
                $px, $cy,
                -text => 'G',
                -fill => '#ffffff',
                -font => 'Helvetica 7 bold',
                -tags => ['pmr_overlay'],
            );
        }
    }

    $c->lower('pmr_overlay');
}

1;
