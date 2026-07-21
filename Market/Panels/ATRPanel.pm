package Market::Panels::ATRPanel;

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
    
    # Líneas guía
    $self->{crosshair}->{vline} = $c->createLine(0, 0, 0, 0, -fill => '#9598a1', -dash => '.', -state => 'hidden');
    $self->{crosshair}->{hline} = $c->createLine(0, 0, 0, 0, -fill => '#9598a1', -dash => '.', -state => 'hidden');
    
    # Etiqueta Y (Valor en el eje derecho) - Fondo y Texto
    $self->{crosshair}->{y_bg}   = $c->createRectangle(0, 0, 0, 0, -fill => '#2962FF', -outline => '#2962FF', -state => 'hidden');
    $self->{crosshair}->{y_text} = $c->createText(0, 0, -text => '', -fill => 'white', -anchor => 'e', -state => 'hidden');

    # NUEVO: Texto en la esquina superior izquierda para el valor exacto de la vela
    $self->{crosshair}->{info_text} = $c->createText(
        10, 10, 
        -text => '', 
        -fill => '#2962FF', 
        -anchor => 'nw',
        -font => ['Helvetica', 10, 'bold']
    );
}

sub get_y_range {
    my ($self, $data_slice) = @_;
    
    # Filtramos los valores no definidos (el ATR no tiene valor en las primeras 'n' velas)
    my @valid_values = grep { defined $_ } @$data_slice;
    return (0, 1) unless @valid_values;

    my $min_val = $valid_values[0];
    my $max_val = $valid_values[0];

    foreach my $val (@valid_values) {
        $min_val = min($min_val, $val);
        $max_val = max($max_val, $val);
    }

    # Damos un margen del 10% para que la línea no golpee el techo/piso del canvas
    my $padding = ($max_val - $min_val) * 0.10;
    $padding = 0.0001 if $padding == 0; # Protección rango plano
    
    return ($min_val - $padding, $max_val + $padding);
}

sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

sub render {
    my ($self, $data_slice) = @_;
    
    # NUEVO: Guardamos los datos para leerlos luego con el cursor
    $self->{current_slice} = $data_slice;
    
    my $c = $self->{canvas};
    my $s = $self->{scale};
    
    return unless $s && @$data_slice;

    # Limpiar fotograma anterior
    $c->delete('atr_line');
    $c->delete('atr_last_label');

    my @coords;
    for my $i (0 .. $#{$data_slice}) {
        my $val = $data_slice->[$i];
        next unless defined $val; 
        
        my $x = $s->index_to_center_x($i);
        my $y = $s->value_to_y($val);
        push @coords, $x, $y;
    }
    
    if (@coords >= 4) {
        $c->createLine(
            @coords,
            -fill  => '#2962FF',
            -width => 2,
            -tags  => 'atr_line'
        );
    }
    
    $s->_draw_y_scale($c);
    $self->render_last_visible_value($data_slice);
}

sub render_last_visible_value {
    my ($self, $data_slice) = @_;
    my $c = $self->{canvas};
    my $s = $self->{scale};

    $c->delete('atr_last_label');
    return unless @$data_slice && $s;

    # Buscar el último valor definido del slice visible
    my $last_val;
    for my $i (reverse 0 .. $#{$data_slice}) {
        if (defined $data_slice->[$i]) {
            $last_val = $data_slice->[$i];
            last;
        }
    }
    return unless defined $last_val;

    my $y_pos = $s->value_to_y($last_val);
    my $width = $s->{width};

    my $display_val = sprintf("%.2f", $last_val);

    # Texto
    my $text_id = $c->createText(
        $width - 5, $y_pos,
        -text   => $display_val,
        -fill   => 'white',
        -anchor => 'e',
        -font   => ['Helvetica', 10, 'bold'],
        -tags   => 'atr_last_label'
    );

    # Fondo azul (mismo color que la línea ATR)
    my @bbox = $c->bbox($text_id);
    if (@bbox) {
        my ($x1,$y1,$x2,$y2) = ($bbox[0]-4, $bbox[1]-2, $bbox[2]+4, $bbox[3]+2);
        my $bg_id = $c->createRectangle(
            $x1, $y1, $x2, $y2,
            -fill    => '#2962FF',
            -outline => '#2962FF',
            -tags    => 'atr_last_label'
        );
        $c->lower($bg_id, $text_id);
    }

    # Línea punteada horizontal hasta el valor
    $c->createLine(
        0, $y_pos, $width - 70, $y_pos,
        -fill => '#2962FF',
        -dash => '.',
        -tags => 'atr_last_label'
    );
}

sub draw_crosshair {
    my ($self, $x, $y) = @_;
    my $c = $self->{canvas};
    my $s = $self->{scale};
    
    if (!defined $x || !$s) {
        my @hide_keys = qw(vline hline y_bg y_text);
        foreach my $key (@hide_keys) {
            $c->itemconfigure($self->{crosshair}->{$key}, -state => 'hidden') if exists $self->{crosshair}->{$key};
        }
        return;
    }

    my $width  = $s->{width};
    my $height = $s->{height};

    # ==========================================
    # EJE X (Sincronizado con PricePanel)
    # ==========================================
    $c->coords($self->{crosshair}->{vline}, $x, 0, $x, $height);
    $c->itemconfigure($self->{crosshair}->{vline}, -state => 'normal');
    
    if ($self->{current_slice}) {
        my $candle_width = $width / $s->{visible_bars};
        my $local_index = int(($x / $candle_width) + $s->{offset});
        
        if ($local_index >= 0 && $local_index < @{$self->{current_slice}}) {
            my $val = $self->{current_slice}->[$local_index];
            # CAMBIADO A %.2f
            my $str = defined $val ? sprintf("ATR: %.2f", $val) : "ATR: N/A";
            $c->itemconfigure($self->{crosshair}->{info_text}, -text => $str);
        }
    }

    # ==========================================
    # EJE Y (Valor en el lado derecho con escala 0.25)
    # ==========================================
    if (defined $y) {
        my $raw_val = $s->y_to_value($y);
        my $val = int($raw_val / 0.25 + 0.5) * 0.25;
        my $snapped_y = $s->value_to_y($val);

        $c->coords($self->{crosshair}->{hline}, 0, $snapped_y, $width, $snapped_y);
        $c->itemconfigure($self->{crosshair}->{hline}, -state => 'normal');
        
        # CAMBIADO A %.2f
        my $display_val = sprintf("%.2f", $val);
        
        $c->coords($self->{crosshair}->{y_text}, $width - 5, $snapped_y);
        $c->itemconfigure($self->{crosshair}->{y_text}, -text => $display_val, -state => 'normal');
        
        my @y_bbox = $c->bbox($self->{crosshair}->{y_text});
        if (@y_bbox) {
            $c->coords($self->{crosshair}->{y_bg}, $y_bbox[0]-4, $y_bbox[1]-2, $y_bbox[2]+4, $y_bbox[3]+2);
            $c->itemconfigure($self->{crosshair}->{y_bg}, -state => 'normal');
        }
    } else {
        $c->itemconfigure($self->{crosshair}->{hline}, -state => 'hidden');
        $c->itemconfigure($self->{crosshair}->{y_bg},  -state => 'hidden');
        $c->itemconfigure($self->{crosshair}->{y_text}, -state => 'hidden');
    }

    $c->raise($self->{crosshair}->{vline});
    $c->raise($self->{crosshair}->{info_text});
    
    if (defined $y) {
        $c->raise($self->{crosshair}->{hline});
        $c->raise($self->{crosshair}->{y_bg});
        $c->raise($self->{crosshair}->{y_text});
    }
}

1;
