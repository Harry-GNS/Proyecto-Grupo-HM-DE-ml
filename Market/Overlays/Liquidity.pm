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
    my ($self, $scale, $liq_res, $start_idx_viewport, $visibility) = @_;
    my $c = $self->{canvas};

    $c->delete('liquidity_overlay');

    return unless $liq_res && ref($liq_res) eq 'HASH';

    # Índice absoluto de la primera vela de la ventana visible.
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

    my $vp_start = int($offset_frac);
    my $vp_end   = int($offset_frac) + $visible_bars + 2;

    # =========================================================================
    # 1. LÍNEAS ESTRUCTURALES Y ETIQUETAS BASE O RESUELTAS (BSL, SSL, EQH, EQL)
    # =========================================================================
    if (ref($liq_res->{levels}) eq 'ARRAY') {
        for my $lv (@{ $liq_res->{levels} }) {
            my $type  = $lv->{type} // next;
            my $state = '';
            
            if    ($type eq 'BSL') { $state = 'swing_high' }
            elsif ($type eq 'SSL') { $state = 'swing_low' }
            elsif ($type eq 'EQH') { $state = 'eqh' }
            elsif ($type eq 'EQL') { $state = 'eql' }
            next if $state eq '';

            # Determinar si este tipo debe mostrarse
            my $should_show =
                ($state eq 'swing_high' && $show->('bsl'))  ||
                ($state eq 'swing_low'  && $show->('ssl'))  ||
                (($state eq 'eqh' || $state eq 'eql') && $show->('eqh_eql'));

            if ($should_show) {
                my $start_idx = $lv->{first_pivot_index} // $lv->{pivot_index} // $lv->{start_index} // 0;
                my $end_idx   = $lv->{end_index} // 1_000_000_000;

                # Filtro de Viewport
                next if $end_idx < $vp_start;
                next if $start_idx > $vp_end;

                my $level_price = $lv->{price} // $lv->{basePrice} // $lv->{base_price} // 0;
                my $y = $scale->value_to_y($level_price);
                next if $y < -100 || $y > $height + 100;

                my $res = $lv->{status} // 'ACTIVE';
                my $text  = '';
                my $color = '#FF5252';

                if ($state eq 'swing_high') {
                    $color = '#FF5252';
                    if ($res eq 'ACTIVE') { $text = 'BSL'; }
                    elsif ($res eq 'SWEPT') { $text = 'SWEEP ↑'; }
                    elsif ($res eq 'GRABBED' || $res eq 'BIG_GRAB') { $text = 'LQ GRAB'; $color = '#FF9100'; }
                    elsif ($res eq 'RUN' || $res eq 'BROKEN' || $res eq 'ACCEPTANCE') { $text = 'LQ RUN'; $color = '#2979FF'; }
                }
                elsif ($state eq 'swing_low') {
                    $color = '#00E676';
                    if ($res eq 'ACTIVE') { $text = 'SSL'; }
                    elsif ($res eq 'SWEPT') { $text = 'SWEEP ↓'; }
                    elsif ($res eq 'GRABBED' || $res eq 'BIG_GRAB') { $text = 'LQ GRAB'; $color = '#FF9100'; }
                    elsif ($res eq 'RUN' || $res eq 'BROKEN' || $res eq 'ACCEPTANCE') { $text = 'LQ RUN'; $color = '#2979FF'; }
                }
                elsif ($state eq 'eqh') {
                    $color = $self->{color_eqh};
                    if ($res eq 'ACTIVE') { $text = 'EQH'; }
                    elsif ($res eq 'SWEPT') { $text = 'SWEEP ↑'; }
                    elsif ($res eq 'GRABBED' || $res eq 'BIG_GRAB') { $text = 'LQ GRAB'; $color = '#FF9100'; }
                    elsif ($res eq 'RUN' || $res eq 'BROKEN' || $res eq 'ACCEPTANCE') { $text = 'LQ RUN'; $color = '#2979FF'; }
                }
                elsif ($state eq 'eql') {
                    $color = $self->{color_eql};
                    if ($res eq 'ACTIVE') { $text = 'EQL'; }
                    elsif ($res eq 'SWEPT') { $text = 'SWEEP ↓'; }
                    elsif ($res eq 'GRABBED' || $res eq 'BIG_GRAB') { $text = 'LQ GRAB'; $color = '#FF9100'; }
                    elsif ($res eq 'RUN' || $res eq 'BROKEN' || $res eq 'ACCEPTANCE') { $text = 'LQ RUN'; $color = '#2979FF'; }
                }

                if ($state eq 'eqh' || $state eq 'eql') {
                    my $last_idx = $lv->{last_pivot_index} // $start_idx;
                    my $x_start = $scale->index_to_center_x($start_idx - $start_idx_viewport);
                    my $x_end   = $scale->index_to_center_x($last_idx - $start_idx_viewport);
                    
                    $c->createLine($x_start, $y, $x_end, $y,
                        -dash => ($state eq 'eqh' ? '-' : '.'), -fill => $color, -width => ($state eq 'eqh' ? 2.0 : 1.5),
                        -tags => ['liquidity_overlay']);
                    if ($text ne '') {
                        my $mid_x = ($x_start + $x_end) / 2;
                        my $y_offset = ($state eq 'eqh') ? -10 : 10;
                        $c->createText($mid_x, $y + $y_offset,
                            -text => $text, -fill => $color, -anchor => 'c',
                            -font => 'Helvetica 8 bold', -tags => ['liquidity_overlay']);
                    }
                }
                else {
                    my $draw_end = $end_idx;
                    if ($draw_end > $vp_end + 5) {
                        $draw_end = $vp_end + 5;
                    }
                    my $x_start = $scale->index_to_center_x($start_idx - $start_idx_viewport);
                    my $x_end   = $scale->index_to_center_x($draw_end - $start_idx_viewport);
                    
                    $c->createLine($x_start, $y, $x_end, $y,
                        -dash => ($state eq 'swing_low' ? '-' : '.'), -fill => $color, -width => 1.5,
                        -tags => ['liquidity_overlay']);
                    if ($text ne '') {
                        my $y_offset = ($state eq 'swing_high') ? -10 : 10;
                        $c->createText($x_end - 5, $y + $y_offset,
                            -text => $text, -fill => $color, -anchor => 'e',
                            -font => 'Helvetica 8 bold', -tags => ['liquidity_overlay']);
                    }
                }
            }
        }
    }

    # =========================================================================
    # 2. SWEEPS, GRABS, RUNS (Liquidity Events) - Flotantes sobre vela de evento
    # =========================================================================
    if ($show->('liq_events') && ref($liq_res->{events}) eq 'ARRAY') {
        for my $ev (@{ $liq_res->{events} }) {
            my $idx = $ev->{index};
            next unless defined $idx && $idx >= $vp_start && $idx <= $vp_end;

            my $x_event = $scale->index_to_center_x($idx - $start_idx_viewport);
            my $y_event = $scale->value_to_y($ev->{price} // 0);
            next if $y_event < 0 || $y_event > $height;

            my $cls = $ev->{classification} // '';
            my $dir = $ev->{direction} // '';

            if ($cls eq 'SWEEP') {
                if ($dir eq 'up') {
                    $c->createText($x_event, $y_event - 15,
                        -text => 'SWEEP ↑', -fill => '#FF5252',
                        -font => 'Helvetica 9 bold', -tags => ['liquidity_overlay']);
                } else {
                    $c->createText($x_event, $y_event + 15,
                        -text => 'SWEEP ↓', -fill => '#00E676',
                        -font => 'Helvetica 9 bold', -tags => ['liquidity_overlay']);
                }
            }
            elsif ($cls eq 'GRAB' || $cls eq 'BIG_GRAB') {
                my $y_offset = $dir eq 'up' ? -15 : 15;
                $c->createText($x_event, $y_event + $y_offset,
                    -text => 'LQ GRAB', -fill => '#FF9100',
                    -font => 'Helvetica 9 bold', -tags => ['liquidity_overlay']);
            }
            elsif ($cls eq 'RUN' || $cls eq 'BROKEN') {
                my $y_offset = $dir eq 'up' ? -15 : 15;
                $c->createText($x_event, $y_event + $y_offset,
                    -text => 'LQ RUN', -fill => '#2979FF',
                    -font => 'Helvetica 9 bold', -tags => ['liquidity_overlay']);
            }
        }
    }
}

1;