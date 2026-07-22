package Market::Overlays::InternalZigZag;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas         => $args{canvas},
        color_bullish  => $args{color_bullish} || '#FF9800',  # naranja vibrante
        color_bearish  => $args{color_bearish}  || '#AB47BC',  # morado vibrante
        line_width     => $args{line_width}     || 2,
    };
    bless $self, $class;
    return $self;
}

sub render {
    my ($self, $scale, $izz_raw, $start_idx_viewport, $visibility) = @_;
    my $c = $self->{canvas};

    $c->delete('internal_zigzag_overlay');

    $visibility //= {};
    return unless ($visibility->{internal_zigzag} // 1);
    return unless $izz_raw;

    $start_idx_viewport //= 0;

    my $drawable_w = $scale->_drawable_width();
    return if $drawable_w <= 0;

    # 1. Recuperar segmentos y pivots
    my @all_segments = @{ $izz_raw->{segments} // [] };
    push @all_segments, $izz_raw->{active_segment} if defined $izz_raw->{active_segment};

    # 2. Dibujar segmentos
    for my $seg (@all_segments) {
        next unless defined $seg->{start_index} && defined $seg->{end_index};
        next unless defined $seg->{start_price} && defined $seg->{end_price};

        my $rel_from = $seg->{start_index} - $start_idx_viewport;
        my $rel_to   = $seg->{end_index}   - $start_idx_viewport;

        my $x1 = $scale->index_to_center_x($rel_from);
        my $x2 = $scale->index_to_center_x($rel_to);

        my $y1 = $scale->value_to_y($seg->{start_price});
        my $y2 = $scale->value_to_y($seg->{end_price});

        next if ($x1 < 0 && $x2 < 0) || ($x1 > $drawable_w && $x2 > $drawable_w);

        my $color = ($seg->{direction} // '') eq 'bullish' ? $self->{color_bullish} : $self->{color_bearish};

        $c->createLine(
            $x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => $self->{line_width},
            -tags  => ['internal_zigzag_overlay'],
        );
    }

    # 3. Dibujar circulos en los pivots
    my @pivots = @{ $izz_raw->{pivots} // [] };
    for my $p (@pivots) {
        next unless defined $p->{index} && defined $p->{price};

        my $rel = $p->{index} - $start_idx_viewport;
        my $px  = $scale->index_to_center_x($rel);
        my $py  = $scale->value_to_y($p->{price});
        my $r   = 3;

        next if $px < -$r || $px > $drawable_w + $r;

        my $color = $p->{type} eq 'HIGH' ? $self->{color_bearish} : $self->{color_bullish};

        $c->createOval(
            $px - $r, $py - $r, $px + $r, $py + $r,
            -fill    => $color,
            -outline => $color,
            -tags    => ['internal_zigzag_overlay'],
        );
    }
}

1;
