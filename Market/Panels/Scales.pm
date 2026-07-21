package Market::Panels::Scales;

use strict;
use warnings;

# ========================================================
# NUEVO: Definimos el margen derecho reservado para la escala
# ========================================================
use constant RIGHT_MARGIN => 70;

sub new {
    my ($class, %args) = @_;
    my $self = {
        width        => $args{width} || 1,        
        height       => $args{height} || 1,       
        min_val      => $args{min_val} || 0,      
        max_val      => $args{max_val} || 1,      
        visible_bars => $args{visible_bars} || 1, 
        offset       => $args{offset} || 0,       
    };
    bless $self, $class;
    return $self;
}

# ========================================================
# FUNCIÓN AUXILIAR: Área donde realmente se dibujan las velas
# ========================================================
sub _drawable_width {
    my ($self) = @_;
    my $w = $self->{width} - RIGHT_MARGIN;
    return $w > 0 ? $w : 1; # Evitar que sea cero o negativo
}

# ========================================================
# Transformaciones del Eje X (Tiempo) 
# (Ahora utilizan _drawable_width en lugar de width)
# ========================================================
sub index_to_x {
    my ($self, $index) = @_;
    my $candle_width = $self->_drawable_width() / $self->{visible_bars};
    return ($index - $self->{offset}) * $candle_width;
}

sub x_to_index_float {
    my ($self, $x) = @_;
    my $candle_width = $self->_drawable_width() / $self->{visible_bars};
    return ($x / $candle_width) + $self->{offset};
}

sub x_to_index {
    my ($self, $x) = @_;
    return int($self->x_to_index_float($x));
}

sub index_to_center_x {
    my ($self, $index) = @_;
    my $candle_width = $self->_drawable_width() / $self->{visible_bars};
    my $x_start = $self->index_to_x($index);
    return $x_start + ($candle_width / 2);
}

# ========================================================
# Transformaciones del Eje Y (Valores/Precios)
# ========================================================
sub value_to_y {
    my ($self, $value) = @_;
    my $range = $self->{max_val} - $self->{min_val};
    
    return $self->{height} / 2 if $range == 0; 
    
    my $normalized_val = ($value - $self->{min_val}) / $range;
    return $self->{height} - ($normalized_val * $self->{height});
}

sub y_to_value {
    my ($self, $y) = @_;
    my $range = $self->{max_val} - $self->{min_val};
    
    if ($self->{height} == 0) { return 0; } 
    
    my $normalized_y = ($self->{height} - $y) / $self->{height};
    return $self->{min_val} + ($normalized_y * $range);
}

# ========================================================
# RENDERIZADO DEL EJE ESTÁTICO DE LA DERECHA
# ========================================================
sub _draw_y_scale {
    my ($self, $canvas) = @_;
    
    $canvas->delete('y_scale');
    
    # Constante manual para evitar el uso del módulo externo si falla
    my $right_margin = 70;
    my $chart_end_x = $self->{width} - $right_margin;
    
    $canvas->createRectangle(
        $chart_end_x, 0, 
        $self->{width}, $self->{height},
        -fill    => '#131722',
        -outline => '#2a2e39',
        -tags    => 'y_scale'
    );
    
    my $range = $self->{max_val} - $self->{min_val};
    return if $range <= 0;
    
    # =========================================================
    # LÓGICA INTELIGENTE DE ESCALAS (Precios vs ATR)
    # =========================================================
    my $step;
    
    if ($self->{max_val} > 1000) {
        # Es el panel principal de Precios (Valores 27000+) -> Salto estricto de 25
        $step = 25;
    } else {
        # Es el panel ATR (Valores pequeños 3.0 - 6.0) -> Salto dinámico
        $step = $range / 4; 
    }
    
    # Encontrar el múltiplo más alto (el "techo") para dibujar de arriba hacia abajo restando
    my $start_val = int($self->{max_val} / $step) * $step;
    
    # Bucle invertido: Iteramos desde el precio más alto hacia el más bajo (restando)
    for (my $val = $start_val; $val >= $self->{min_val}; $val -= $step) {
        
        my $y_pos = $self->value_to_y($val);
        
        # Formateo estricto a 2 decimales (.00)
        my $display_val = sprintf("%.2f", $val);
        
        # Línea de cuadrícula horizontal sutil estilo TradingView
        $canvas->createLine(
            0, $y_pos,
            $chart_end_x, $y_pos,
            -fill => '#1e222d',
            -dash => '.',
            -tags => 'y_scale'
        );

        $canvas->createLine(
            $chart_end_x, $y_pos, 
            $chart_end_x + 5, $y_pos,
            -fill => '#4a4f66',
            -tags => 'y_scale'
        );
        
        $canvas->createText(
            $self->{width} - 5, $y_pos, 
            -text   => $display_val, 
            -anchor => 'e', 
            -fill   => '#d1d4dc', 
            -font   => ['Helvetica', 9],
            -tags   => 'y_scale' 
        );
    }
}

1;
