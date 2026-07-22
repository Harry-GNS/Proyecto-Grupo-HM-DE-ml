package Market::Indicators::ZonaInterna;

use strict;
use warnings;

# ============================================================
#  Market::Indicators::ZonaInterna
#
#  Porta la logica de niveles Fibonacci del snippet Pine recibido:
#    - usa los ultimos 3 puntos del zigzag
#    - base = zigzag[2]
#    - diff = zigzag[4] - zigzag[2]
#    - niveles 0.618 / 0.786 opcionales y extensiones 1..5
#      con +0.272, +0.414 y +0.618
#    - conserva la regla stopit del Pine:
#        si stopit ya esta activo y x > shownlevels, corta.
#
#  No dibuja; solo produce niveles para consumir desde overlays.
# ============================================================

sub new {
    my ($class, %args) = @_;

    my $self = {
        enable618   => exists $args{enable618} ? ($args{enable618} ? 1 : 0) : 1,
        enable786   => exists $args{enable786} ? ($args{enable786} ? 1 : 0) : 1,
        max_x       => $args{max_x} // 5,
        mintick     => $args{mintick} // 0.25,
    };

    bless $self, $class;
    return $self;
}

sub compute {
    my ($class_or_self, %args) = @_;

    my $self = ref($class_or_self) ? $class_or_self : $class_or_self->new(%args);
    my $zigzag = $args{zigzag} // {};
    my $max_idx = $args{max_visible_index} // 0;
    my $tf = $args{timeframe} // '1m';

    my @points = _zigzag_points($zigzag);
    return _empty($tf, $max_idx) unless @points >= 3;

    my $current = $points[-1]; # equivalente a zigzag[0]/zigzag[1]
    my $prev    = $points[-2]; # equivalente a zigzag[2]/zigzag[3]
    my $before  = $points[-3]; # equivalente a zigzag[4]/zigzag[5]

    return _empty($tf, $max_idx) unless defined $current->{price}
        && defined $prev->{price}
        && defined $before->{price}
        && defined $before->{index};

    my $dir = $current->{price} > $prev->{price} ? 1
            : $current->{price} < $prev->{price} ? -1
            : 0;
    return _empty($tf, $max_idx) unless $dir;

    my ($ratios, $shownlevels) = $self->_ratios;
    my $diff = $before->{price} - $prev->{price};
    my $stopit = 0;
    my @levels;

    for my $x (0 .. $#$ratios) {
        last if $stopit && $x > $shownlevels;

        my $ratio = $ratios->[$x];
        my $price = $prev->{price} + $diff * $ratio;
        my $rounded = _round_to_mintick($price, $self->{mintick});

        push @levels, {
            index        => $x,
            ratio        => $ratio,
            price        => $price,
            rounded_price=> $rounded,
            text         => _fmt_ratio($ratio) . '(' . _fmt_price($rounded, $self->{mintick}) . ')',
            x1_index     => int($before->{index} + 0.5),
            x2_index     => $max_idx,
            direction    => $dir == 1 ? 'bullish' : 'bearish',
            color_slot   => $x % 10,
            stopit       => $stopit ? 1 : 0,
        };

        if (($dir == 1  && $price > $current->{price})
            || ($dir == -1 && $price < $current->{price})) {
            $stopit = 1;
        }
    }

    return {
        timeframe         => $tf,
        max_visible_index => $max_idx,
        direction         => $dir == 1 ? 'bullish' : 'bearish',
        shownlevels       => $shownlevels,
        base_price        => $prev->{price},
        diff              => $diff,
        current_point     => { %$current },
        previous_point    => { %$prev },
        anchor_point      => { %$before },
        levels            => \@levels,
    };
}

sub _ratios {
    my ($self) = @_;

    my @ratios;
    my $shownlevels = 0;

    push @ratios, 0.000; $shownlevels++;
    push @ratios, 0.236; $shownlevels++;
    push @ratios, 0.382; $shownlevels++;
    push @ratios, 0.500; $shownlevels++;
    push @ratios, 0.618; $shownlevels++;
    push @ratios, 0.786; $shownlevels++;
    push @ratios, 1.000; $shownlevels++;

    return (\@ratios, $shownlevels);
}

sub _zigzag_points {
    my ($zigzag) = @_;

    my @points;
    for my $seg (@{ $zigzag->{segments} // [] }) {
        _push_point(\@points, $seg->{start_index}, $seg->{start_price}, $seg->{start_time});
        _push_point(\@points, $seg->{end_index},   $seg->{end_price},   $seg->{end_time});
    }

    my $active = $zigzag->{active_segment};
    if ($active) {
        _push_point(\@points, $active->{start_index}, $active->{start_price}, $active->{start_time});
        _push_point(\@points, $active->{end_index},   $active->{end_price},   $active->{end_time});
    }

    return sort {
        ($a->{index} // 0) <=> ($b->{index} // 0)
            || ($a->{price} // 0) <=> ($b->{price} // 0)
    } @points;
}

sub _push_point {
    my ($points, $index, $price, $time) = @_;
    return unless defined $index && defined $price;

    if (@$points) {
        my $last = $points->[-1];
        return if defined $last->{index}
            && defined $last->{price}
            && $last->{index} == $index
            && $last->{price} == $price;
    }

    push @$points, {
        index => $index,
        price => $price,
        time  => $time,
    };
    return;
}

sub _empty {
    my ($tf, $max_idx) = @_;
    return {
        timeframe         => $tf,
        max_visible_index => $max_idx,
        direction         => undef,
        shownlevels       => 0,
        levels            => [],
    };
}

sub _round_to_mintick {
    my ($price, $tick) = @_;
    return $price unless defined $tick && $tick > 0;
    my $scaled = $price / $tick;
    my $rounded = $scaled >= 0 ? int($scaled + 0.5) : int($scaled - 0.5);
    return $rounded * $tick;
}

sub _fmt_ratio {
    my ($ratio) = @_;
    my $txt = sprintf('%.3f', $ratio);
    $txt =~ s/0+$//;
    $txt =~ s/\.$//;
    return $txt;
}

sub _fmt_price {
    my ($price, $tick) = @_;
    my $decimals = 2;
    if (defined $tick && $tick > 0 && $tick < 1) {
        my $t = "$tick";
        if ($t =~ /\.(\d+)/) {
            $decimals = length $1;
        }
    }
    return sprintf('%.' . $decimals . 'f', $price);
}

1;
