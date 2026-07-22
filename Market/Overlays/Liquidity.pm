package Market::Overlays::Liquidity;

use strict;
use warnings;
use utf8; # <-- Obligatorio para que Tk dibuje las flechas ↑ y ↓ correctamente

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},
        # Colores configurables para EQH y EQL según la Tabla 2
        color_eqh => $args{color_eqh} || '#FFD600', # Amarillo por defecto
        color_eql => $args{color_eql} || '#FFD600',
    };
    bless $self, $class;
    return $self;
}

sub render {
    my ($self, $scale, $liquidity_slice, $start_idx_viewport, $visibility) = @_;
    my $c = $self->{canvas};

    $c->delete('liquidity_overlay');

    return unless $liquidity_slice && @$liquidity_slice;

    # Índice absoluto de la primera vela de la ventana visible. Se usa para
    # convertir el end_index (absoluto) de cada nivel al espacio relativo del
    # viewport que entiende index_to_center_x (igual que Overlays::SMC_Structures).
    $start_idx_viewport //= 0;

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

    for my $i (0 .. $#$liquidity_slice) {
        my $punto = $liquidity_slice->[$i];
        next if !$punto;

        # =========================================================================
        # 1. LÍNEAS ESTRUCTURALES Y ETIQUETAS BASE O RESUELTAS (BSL, SSL, EQH, EQL)
        # =========================================================================
        if (defined $punto->{state} && $punto->{state} ne 'none') {
            my $state = $punto->{state};

            # Determinar si este tipo debe mostrarse
            my $should_show =
                ($state eq 'swing_high' && $show->('bsl'))  ||
                ($state eq 'swing_low'  && $show->('ssl'))  ||
                (($state eq 'eqh' || $state eq 'eql') && $show->('eqh_eql'));

            if ($should_show) {
                my $level_price = $punto->{price};
                # $i es relativo al viewport; end_index viene en índice absoluto.
                my $end_idx     = $punto->{end_index} // ($i + $start_idx_viewport);
                my $res         = $punto->{resolution} // '';

                my $x_start = $scale->index_to_center_x($i);
                my $x_end   = $scale->index_to_center_x($end_idx - $start_idx_viewport);
                my $y       = $scale->value_to_y($level_price);

                next if $y < -100 || $y > $height + 100;

                my $text  = '';
                my $color = '#FF5252';

                if ($state eq 'swing_high') {
                    $color = '#FF5252';
                    if ($res eq 'active') { $text = 'BSL'; }
                    elsif ($res eq 'sweep') { $text = 'SWEEP ↑'; }
                    elsif ($res eq 'grab') { $text = 'LQ GRAB'; $color = '#FF9100'; }
                    elsif ($res eq 'run') { $text = 'LQ RUN'; $color = '#2979FF'; }
                }
                elsif ($state eq 'swing_low') {
                    $color = '#00E676';
                    if ($res eq 'active') { $text = 'SSL'; }
                    elsif ($res eq 'sweep') { $text = 'SWEEP ↓'; }
                    elsif ($res eq 'grab') { $text = 'LQ GRAB'; $color = '#FF9100'; }
                    elsif ($res eq 'run') { $text = 'LQ RUN'; $color = '#2979FF'; }
                }
                elsif ($state eq 'eqh') {
                    $color = $self->{color_eqh};
                    if ($res eq 'active') { $text = 'EQH'; }
                    elsif ($res eq 'sweep') { $text = 'SWEEP ↑'; }
                    elsif ($res eq 'grab') { $text = 'LQ GRAB'; $color = '#FF9100'; }
                    elsif ($res eq 'run') { $text = 'LQ RUN'; $color = '#2979FF'; }
                }
                elsif ($state eq 'eql') {
                    $color = $self->{color_eql};
                    if ($res eq 'active') { $text = 'EQL'; }
                    elsif ($res eq 'sweep') { $text = 'SWEEP ↓'; }
                    elsif ($res eq 'grab') { $text = 'LQ GRAB'; $color = '#FF9100'; }
                    elsif ($res eq 'run') { $text = 'LQ RUN'; $color = '#2979FF'; }
                }

                if ($state eq 'swing_high' || $state eq 'eqh') {
                    $c->createLine($x_start, $y, $x_end, $y,
                        -dash => ($state eq 'eqh' ? '-' : '.'), -fill => $color, -width => ($state eq 'eqh' ? 2.0 : 1.5),
                        -tags => ['liquidity_overlay']);
                    if ($text ne '') {
                        $c->createText($x_end - 5, $y - 10,
                            -text => $text, -fill => $color, -anchor => 'e',
                            -font => 'Helvetica 8 bold', -tags => ['liquidity_overlay']);
                    }
                }
                elsif ($state eq 'swing_low' || $state eq 'eql') {
                    $c->createLine($x_start, $y, $x_end, $y,
                        -dash => ($state eq 'eql' ? '-' : '.'), -fill => $color, -width => ($state eq 'eql' ? 2.0 : 1.5),
                        -tags => ['liquidity_overlay']);
                    if ($text ne '') {
                        $c->createText($x_end - 5, $y + 10,
                            -text => $text, -fill => $color, -anchor => 'e',
                            -font => 'Helvetica 8 bold', -tags => ['liquidity_overlay']);
                    }
                }
            }
        }

        # =========================================================================
        # 2. SWEEPS, GRABS, RUNS (Liquidity Events) - Flotantes sobre vela de evento
        # =========================================================================
        if ($show->('liq_events') && exists $punto->{events} && @{ $punto->{events} }) {
            for my $ev (@{ $punto->{events} }) {
                my $x_event = $scale->index_to_center_x($i);
                my $y_event = $scale->value_to_y($ev->{price});

                next if $y_event < 0 || $y_event > $height;

                if ($ev->{type} eq 'sweep_up') {
                    $c->createText($x_event, $y_event - 15,
                        -text => 'SWEEP ↑', -fill => '#FF5252',
                        -font => 'Helvetica 9 bold', -tags => ['liquidity_overlay']);
                }
                elsif ($ev->{type} eq 'sweep_down') {
                    $c->createText($x_event, $y_event + 15,
                        -text => 'SWEEP ↓', -fill => '#00E676',
                        -font => 'Helvetica 9 bold', -tags => ['liquidity_overlay']);
                }
                elsif ($ev->{type} eq 'grab_up' || $ev->{type} eq 'grab_down') {
                    $c->createText($x_event, $y_event - 15,
                        -text => 'LQ GRAB', -fill => '#FF9100',
                        -font => 'Helvetica 9 bold', -tags => ['liquidity_overlay']);
                }
                elsif ($ev->{type} eq 'run_up' || $ev->{type} eq 'run_down') {
                    $c->createText($x_event, $y_event - 15,
                        -text => 'LQ RUN', -fill => '#2979FF',
                        -font => 'Helvetica 9 bold', -tags => ['liquidity_overlay']);
                }
            }
        }
    }
}

1;