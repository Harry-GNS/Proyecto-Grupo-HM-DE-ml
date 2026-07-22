package Market::MarketData;

use strict;
use warnings;
use POSIX qw(floor);

sub new {
    my ($class) = @_;
    my $self = {
        data         => {},
        current_tf   => '1m',
        # Variables nativas para el Sistema Replay
        replay_mode  => 0,
        replay_index => 0,
    };
    bless $self, $class;
    return $self;
}

sub add_candle {
    my ($self, $candle) = @_;
    # Los indicadores (VWAP anclado, Volume Profile por sesión, Liquidez, etc.)
    # leen $candle->{time}; el loader entrega la marca temporal como 'timestamp'.
    # Reflejamos el valor para que la detección de sesiones/anclas funcione.
    $candle->{time} //= $candle->{timestamp};
    push @{ $self->{data}->{'1m'} }, $candle;
}

sub build_tf_candles {
    my ($self, $target_tf) = @_;

    # Parsear dinámicamente minutos, horas, días o semanas
    my $n;
    if ($target_tf =~ /^(\d+)m$/) {
        $n = $1;
    } elsif ($target_tf =~ /^(\d+)h$/) {
        $n = $1 * 60;
    } elsif ($target_tf eq 'D') {
        $n = 1440;
    } elsif ($target_tf eq 'W') {
        $n = 10080;
    }
    
    return unless $n && $n > 0;
    return unless exists $self->{data}->{'1m'} && @{ $self->{data}->{'1m'} } > 0;

    my $base_data = $self->{data}->{'1m'};
    my @aggregated;
    my %bucket_map;

    for my $candle (@$base_data) {
        my $ts = $candle->{timestamp};

        my ($date, $hour, $min);
        if ($ts =~ /(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/) {
            $date = $1;
            $hour = $2 + 0;
            $min  = $3 + 0;
        } else {
            next; 
        }

        my $day_minute = $hour * 60 + $min;
        my $bucket     = floor($day_minute / $n) * $n;
        my $key        = "$date:$bucket";

        if (!exists $bucket_map{$key}) {
            my $bucket_hour = floor($bucket / 60);
            my $bucket_min  = $bucket % 60;
            my $bucket_ts   = sprintf("%sT%02d:%02d:00", $date, $bucket_hour, $bucket_min);
            if ($ts =~ /([-+]\d{2}:\d{2})$/) { $bucket_ts .= $1; }

            push @aggregated, {
                timestamp => $bucket_ts,
                time      => $bucket_ts,
                open      => $candle->{open},
                high      => $candle->{high},
                low       => $candle->{low},
                close     => $candle->{close},
                volume    => $candle->{volume},
            };
            $bucket_map{$key} = $#aggregated;
        } else {
            my $idx = $bucket_map{$key};
            $aggregated[$idx]->{high}   = $candle->{high}   if $candle->{high}   > $aggregated[$idx]->{high};
            $aggregated[$idx]->{low}    = $candle->{low}    if $candle->{low}    < $aggregated[$idx]->{low};
            $aggregated[$idx]->{close}  = $candle->{close};
            $aggregated[$idx]->{volume} += $candle->{volume};
        }
    }

    $self->{data}->{$target_tf} = \@aggregated;
}

sub build_timeframes {
    my ($self) = @_;
    # Generar todas las temporalidades soportadas exigidas
    foreach my $tf (qw(5m 15m 1h 2h 4h D W)) {
        $self->build_tf_candles($tf);
    }
    $self->set_timeframe('1m');
}

sub set_timeframe {
    my ($self, $tf) = @_;
    if (exists $self->{data}->{$tf}) {
        $self->{current_tf} = $tf;
    } else {
        warn "La temporalidad $tf no ha sido construida aún.\n";
    }
}

# =====================================================================
# RUTINAS DE ACCESO BLINDADAS CONTRA UNDEF
# =====================================================================
sub _active_array {
    my ($self) = @_;
    # BLINDAJE MAESTRO: Si la temporalidad actual no tiene datos o es undef, 
    # devolvemos un arreglo vacío [] en lugar de undef.
    return $self->{data}->{ $self->{current_tf} } // [];
}

# =====================================================================
# SISTEMA REPLAY: Filtrado Estricto de Datos
# =====================================================================
sub start_replay {
    my ($self, $index) = @_;
    $self->{replay_mode} = 1;
    $self->{replay_index} = $index // 0;
}

sub stop_replay {
    my ($self) = @_;
    $self->{replay_mode} = 0;
}

sub step_replay {
    my ($self, $steps) = @_;
    return unless $self->{replay_mode};
    my $array_ref = $self->_active_array();
    
    $self->{replay_index} += $steps;
    # Protegemos el avance comprobando primero que el arreglo tenga elementos
    $self->{replay_index} = $#{$array_ref} if @$array_ref && $self->{replay_index} > $#{$array_ref};
    $self->{replay_index} = 0 if $self->{replay_index} < 0;
}

sub size {
    my ($self) = @_;
    my $array_ref = $self->_active_array();
    # Si el arreglo está vacío, el tamaño es 0 directo
    return 0 unless @$array_ref; 
    return $self->{replay_mode} ? $self->{replay_index} + 1 : scalar @{$array_ref};
}

sub get_slice {
    my ($self, $start, $end) = @_;
    my $array_ref = $self->_active_array();
    return [] unless @$array_ref;
    
    my $max_limit = $self->{replay_mode} ? $self->{replay_index} : $#{$array_ref};
    
    $start = 0 if $start < 0;
    $end = $max_limit if $end > $max_limit;
    
    return [] if $start > $end;
    return [ @{$array_ref}[$start .. $end] ];
}

sub last_candle {
    my ($self) = @_;
    my $array_ref = $self->_active_array();
    return undef unless @$array_ref;
    
    my $idx = $self->{replay_mode} ? $self->{replay_index} : $#{$array_ref};
    return $array_ref->[$idx] if $idx >= 0;
    return undef;
}

sub get_timestamp {
    my ($self, $index) = @_;
    my $array_ref = $self->_active_array();
    return undef unless @$array_ref;
    
    return $array_ref->[$index]->{timestamp} if defined $array_ref->[$index];
    return undef;
}

sub last_index {
    my ($self) = @_;
    my $array_ref = $self->_active_array();
    return undef unless @$array_ref;
    
    return $self->{replay_mode} ? $self->{replay_index} : $#{$array_ref};
}

sub get_candle {
    my ($self, $index) = @_;
    my $array_ref = $self->_active_array();
    return undef unless @$array_ref;
    
    return undef if !defined $index || $index < 0 || $index > $#{$array_ref};
    return undef if $self->{replay_mode} && $index > $self->{replay_index};
    
    return $array_ref->[$index];
}

1;