package Market::IndicatorManager;

use strict;
use warnings;

sub new {
    my ($class) = @_;
    my $self = {
        indicators => {}, # Hash para registrar instancias de indicadores
    };
    bless $self, $class;
    return $self;
}

sub register {
    my ($self, $name, $indicator) = @_;
    # Registra un indicador permitiendo extensibilidad [cite: 205, 206]
    $self->{indicators}->{$name} = $indicator;
}

sub update_last {
    my ($self, $market_data) = @_;
    # Delega la actualización a cada indicador registrado [cite: 208]
    foreach my $name (keys %{ $self->{indicators} }) {
        $self->{indicators}->{$name}->update_last($market_data);
    }
}

sub get {
    my ($self, $name) = @_;
    # Obtiene los valores precalculados de un indicador [cite: 211]
    return [] unless exists $self->{indicators}->{$name};
    return $self->{indicators}->{$name}->get_values();
}

sub slice_array {
    my ($self, $name, $start, $end) = @_;
    # Devuelve una porción de valores sincronizada con la ventana visible [cite: 213]
    my $values = $self->get($name);
    
    $start = 0 if $start < 0;
    $end = $#{$values} if $end > $#{$values};
    
    return [ @{$values}[$start .. $end] ];
}

sub reset_all {
    my ($self) = @_;
    # Reinicia el estado interno de todos los indicadores al cambiar de timeframe [cite: 215]
    foreach my $name (keys %{ $self->{indicators} }) {
        $self->{indicators}->{$name}->reset();
    }
}

sub recalculate_all {
    my ($self, $market_data) = @_;
    foreach my $name (keys %{ $self->{indicators} }) {
        # Verificamos que el indicador soporte el cálculo en lote
        if ($self->{indicators}->{$name}->can('calculate_batch')) {
            $self->{indicators}->{$name}->calculate_batch($market_data);
        }
    }
}


1;