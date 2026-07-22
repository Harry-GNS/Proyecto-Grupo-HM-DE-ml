package Market::Overlays::InternalZigZag;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas         => $args{canvas},
        color_bullish  => $args{color_bullish} || '#ffb74d',  # naranja suave
        color_bearish  => $args{color_bearish}  || '#b39ddb',  # morado suave
        line_width     => $args{line_width}     || 1,
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

    my $width        = $c->width;
    my $height       = $c->height;
    my $min_val      = $scale->{min_val};
    my $max_val      = $scale->{max_val};
    my $visible_bars = $scale->{visible_bars};
    my $offset_frac  = $scale->{offset};

    my $range = $max_val - $min_val;
    return if $range <= 0;

    my $candle_width = $width / $visible_bars;

    # 1. Recuperar segmentos y pivots
    my @all_segments = @{ $izz_raw->{segments} // [] };
    push @all_segments, $izz_raw->{active_segment} if defined $izz_raw->{active_segment};

    # 2. Dibujar segmentos
    for my $seg (@all_segments) {
        next unless defined $seg->{start_index} && defined $seg->{end_index};
        next unless defined $seg->{start_price} && defined $seg->{end_price};

        my $rel_from = $seg->{start_index} - $start_idx_viewport;
        my $rel_to   = $seg->{end_index}   - $start_idx_viewport;

        my $x1 = ($rel_from - $offset_frac) * $candle_width + ($candle_width / 2);
        my $x2 = ($rel_to   - $offset_frac) * $candle_width + ($candle_width / 2);

        my $y1 = $height - ((($seg->{start_price} - $min_val) / $range) * $height);
        my $y2 = $height - ((($seg->{end_price}   - $min_val) / $range) * $height);

        next if ($x1 < 0 && $x2 < 0) || ($x1 > $width && $x2 > $width);

        my $color = ($seg->{direction} // '') eq 'bullish' ? $self->{color_bullish} : $self->{color_bearish};

        $c->createLine(
            $x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => $self->{line_width},
            -dash  => '.',
            -tags  => ['internal_zigzag_overlay'],
        );
    }

    # 3. Dibujar circulos en los pivots
    my @pivots = @{ $izz_raw->{pivots} // [] };
    for my $p (@pivots) {
        next unless defined $p->{index} && defined $p->{price};

        my $rel = $p->{index} - $start_idx_viewport;
        my $px  = ($rel - $offset_frac) * $candle_width + ($candle_width / 2);
        my $py  = $height - ((($p->{price} - $min_val) / $range) * $height);
        my $r   = 2;

        next if $px < -$r || $px > $width + $r;

        my $color = $p->{type} eq 'HIGH' ? $self->{color_bearish} : $self->{color_bullish};

        $c->createOval(
            $px - $r, $py - $r, $px + $r, $py + $r,
            -fill    => $color,
            -outline => $color,
            -tags    => ['internal_zigzag_overlay'],
        );
    }

    $c->lower('internal_zigzag_overlay');
}

1;
