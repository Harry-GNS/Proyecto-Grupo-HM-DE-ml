package Market::Overlays::MarketRegime;

use strict;
use warnings;
use utf8;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},
        # Colores por cada estado
        colors => {
            'TR_BULLISH'       => '#26a69a',  # Verde
            'TR_BEARISH'       => '#ef5350',  # Rojo
            'TRANSITION'       => '#ff9100',  # Naranja
            'ZM_MANIPULATION'  => '#ab47bc',  # Morado
            'LIQUIDEZ_EXTERNA' => '#2962FF',  # Azul fuerte
            'LIQUIDEZ_INTERNA' => '#00b0ff',  # Celeste
            'ZONA_INTERNA'     => '#90a4ae',  # Gris azulado
            'UNKNOWN'          => '#546e7a',  # Gris oscuro
        },
    };
    bless $self, $class;
    return $self;
}

sub render {
    my ($self, $scale, $mr_states, $start_idx_viewport, $visibility) = @_;
    my $c = $self->{canvas};

    $c->delete('market_regime_hud');

    $visibility //= {};
    return unless ($visibility->{market_regime} // 1);
    return unless $mr_states && @$mr_states;

    # Encontrar la última vela visible en el viewport para mostrar el régimen actual
    my ($start, $end) = $scale ? (0, $#$mr_states) : (0, $#$mr_states);
    # Usar el último estado disponible
    my $current = $mr_states->[-1];
    return unless $current;

    my $state  = $current->{state} // 'UNKNOWN';
    my $conf   = $current->{confidence_score} // '0.00';
    my $reason = $current->{reason} // 'Sin datos de contexto';

    my $color = $self->{colors}->{$state} // $self->{colors}->{UNKNOWN};

    # Coordenadas del panel HUD (esquina superior izquierda del canvas)
    my ($x1, $y1, $x2, $y2) = (15, 15, 380, 100);

    # 1. Dibujar fondo de tarjeta oscuro
    $c->createRectangle(
        $x1, $y1, $x2, $y2,
        -fill    => '#1c2030',
        -outline => '#2d3245',
        -width   => 1.5,
        -tags    => ['market_regime_hud'],
    );

    # 2. Dibujar barra de color lateral decorativa (estilo premium)
    $c->createRectangle(
        $x1, $y1, $x1 + 6, $y2,
        -fill    => $color,
        -outline => $color,
        -tags    => ['market_regime_hud'],
    );

    # 3. Dibujar textos del HUD
    # Título de la tarjeta
    $c->createText(
        $x1 + 20, $y1 + 15,
        -text   => 'CONTEXTO DE REGIMEN (SMC)',
        -fill   => '#78909c',
        -font   => 'Helvetica 8 bold',
        -anchor => 'w',
        -tags   => ['market_regime_hud'],
    );

    # Nombre del estado actual
    $c->createText(
        $x1 + 20, $y1 + 35,
        -text   => $state,
        -fill   => $color,
        -font   => 'Helvetica 13 bold',
        -anchor => 'w',
        -tags   => ['market_regime_hud'],
    );

    # Confianza y datos
    $c->createText(
        $x1 + 20, $y1 + 55,
        -text   => "Confianza: $conf  |  Atr: " . sprintf("%.4f", $current->{atr} // 0),
        -fill   => '#e2e5ec',
        -font   => 'Helvetica 9 bold',
        -anchor => 'w',
        -tags   => ['market_regime_hud'],
    );

    # Causa / Razón (truncado si excede el tamaño)
    my $disp_reason = length($reason) > 50 ? substr($reason, 0, 47) . '...' : $reason;
    $c->createText(
        $x1 + 20, $y1 + 72,
        -text   => "Motivo: $disp_reason",
        -fill   => '#90a4ae',
        -font   => 'Helvetica 8 italic',
        -anchor => 'w',
        -tags   => ['market_regime_hud'],
    );
}

1;
