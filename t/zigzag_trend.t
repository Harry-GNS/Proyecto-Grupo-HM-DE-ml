#!/usr/bin/perl
# Tests unitarios para Market::Indicators::ZigZag_Trend
# Usa velas sintéticas con pivotes conocidos de antemano.
#
# Ejecutar con:  perl t/zigzag_trend.t
#
# Dependencias: solo módulos del proyecto + Test::More (Perl core)

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";

use Test::More;
use Market::Indicators::ZigZag_Trend;

# =============================================================================
# HELPERS: MarketData mínimo en memoria para los tests
# =============================================================================
{
    package FakeMarketData;
    sub new       { bless { candles => [] }, shift }
    sub add_candle {
        my ($self, $c) = @_;
        push @{ $self->{candles} }, $c;
    }
    sub size       { scalar @{ $_[0]->{candles} } }
    sub last_index { $#{ $_[0]->{candles} } }
    sub get_candle {
        my ($self, $i) = @_;
        return undef if $i < 0 || $i > $#{ $self->{candles} };
        return $self->{candles}[$i];
    }
}

# Construye un marketdata en memoria y ejecuta calculate_batch
sub run_batch {
    my ($candles_ref, %opts) = @_;
    my $md = FakeMarketData->new();
    $md->add_candle($_) for @$candles_ref;
    my $zz = Market::Indicators::ZigZag_Trend->new(%opts);
    $zz->calculate_batch($md);
    return $zz->get_values();
}

# Genera una vela simple (OHLC todos iguales excepto high y low explícitos)
sub candle {
    my ($o, $h, $l, $c) = @_;
    return { open => $o, high => $h, low => $l, close => $c, volume => 100 };
}

# =============================================================================
# TEST 1: Tendencia inicial indefinida (undef) hasta acumular N barras
# =============================================================================
{
    # Con swing_length=3, se necesitan al menos 1 barra para calcular el swing.
    # El estado inicial de isBullish es undef: solo se define cuando high==swing_high
    # o low==swing_low por primera vez.
    # Con velas todas iguales: high == swing_high Y low == swing_low en la misma barra,
    # por lo que la tendencia quedará 'bearish' (el segundo if sobreescribe).
    # Verificamos que ANTES de cualquier condición el estado es undef.

    my @flat_candles = map { candle(100, 100, 100, 100) } (1..3);

    # Creamos el indicador a mano para inspeccionar estado barra a barra
    my $md = FakeMarketData->new();
    my $zz = Market::Indicators::ZigZag_Trend->new(swing_length => 3);

    # Antes de procesar cualquier barra, el estado interno es undef
    is($zz->{_is_bullish}, undef, "Test 1a: estado inicial es undef antes de cualquier barra");

    # Procesamos barra 0 (sola): high==swing_high y low==swing_low (vela flat)
    # Ambas condiciones → queda bearish (0), no undef
    $md->add_candle($flat_candles[0]);
    $zz->update_last($md);
    my $d0 = $zz->get_values()->[0];
    # Dado que high == low en vela flat, ambas condiciones son true → bearish
    is($d0->{trend}, 'bearish', "Test 1b: vela flat activa bearish (low==swing_low sobreescribe)");
}

# =============================================================================
# TEST 2: Transición a bullish cuando high == swing_high
# =============================================================================
{
    # Con swing_length=3:
    #   Barras 0,1: high moderado (80)
    #   Barra 2: high extremo (200) → es el mayor de las últimas 3 → isBullish = true
    #   Barra 3: high < 200, low normal → no cambia el swing_high todavía
    my @candles = (
        candle(100, 110, 90,  100),   # 0
        candle(100, 115, 88,  102),   # 1
        candle(100, 200, 95,  105),   # 2  — high extremo → bullish
        candle(100, 130, 92,  103),   # 3  — high < 200 → swing_high sigue siendo 200
    );
    my $data = run_batch(\@candles, swing_length => 3);

    is($data->[2]{trend}, 'bullish', "Test 2: high==swing_high activa tendencia bullish");
    is($data->[3]{trend}, 'bullish', "Test 2b: tendencia se mantiene bullish si no hay nueva condición");
}

# =============================================================================
# TEST 3: Transición a bearish cuando low == swing_low
# =============================================================================
{
    my @candles = (
        candle(100, 110, 90,  100),   # 0
        candle(100, 115, 88,  102),   # 1
        candle(100, 200, 95,  105),   # 2  — bullish
        candle(100, 130, 50,  103),   # 3  — low extremo (50) → bearish
        candle(100, 125, 70,  100),   # 4  — low > 50 → swing_low sigue siendo 50
    );
    my $data = run_batch(\@candles, swing_length => 3);

    is($data->[2]{trend}, 'bullish', "Test 3: setup bullish en barra 2");
    is($data->[3]{trend}, 'bearish', "Test 3b: low==swing_low activa tendencia bearish");
    is($data->[4]{trend}, 'bearish', "Test 3c: tendencia bearish se mantiene");
}

# =============================================================================
# TEST 4: EDGE CASE — misma barra tiene el high más alto Y el low más bajo
#         Resultado esperado: bearish (el segundo `if` sobreescribe al primero)
# =============================================================================
{
    # Barra 0,1: precios normales
    # Barra 2: high extremo (999) Y low extremo (1) en la MISMA BARRA
    # → ambas condiciones verdaderas → queda bearish (fiel al original Pine)
    my @candles = (
        candle(100, 110, 90, 100),   # 0
        candle(100, 115, 88, 102),   # 1
        candle(100, 999,  1, 100),   # 2  — HIGH y LOW extremos simultáneos
    );
    my $data = run_batch(\@candles, swing_length => 3);

    is($data->[2]{trend}, 'bearish',
        "Test 4 (edge case): high==swing_high Y low==swing_low en misma barra → bearish (igual que Pine)");
}

# =============================================================================
# TEST 5: Pivote alto confirmado — barIndexHigh y priceHigh = low[1]
# =============================================================================
{
    # Secuencia diseñada para que se confirme un pivote alto:
    #   Necesitamos: high[1] == swingHigh[1]  Y  high < swingHigh
    #   Es decir: la barra anterior fue el máximo de la ventana,
    #   y la barra actual tiene un high menor (ya no es el máximo).
    #
    # Con swing_length=2:
    #   Barra 0: high=100, low=90
    #   Barra 1: high=200, low=85  ← máximo → swingHigh[1]=200, high[1]=200
    #   Barra 2: high=150, low=80  ← high(150) < swingHigh anterior(200)
    #            → confirma pivote alto en barra 1, precio = low[1] = 85
    my @candles = (
        candle(100, 100, 90, 100),   # 0
        candle(100, 200, 85, 100),   # 1  — swing_high de la ventana [0..1]
        candle(100, 150, 80, 100),   # 2  — high < 200 → confirma pivote alto en barra 1
    );
    my $data = run_batch(\@candles, swing_length => 2, pivot_high_uses_low => 1);

    my $ph = $data->[2]{pivot_high};
    ok(defined $ph, "Test 5: pivote alto definido en barra 2");
    is($ph->{bar_index}, 1,  "Test 5b: barIndexHigh == 1 (barra anterior)");
    is($ph->{price},     85, "Test 5c: priceHigh == low[1] == 85 (fiel al original)");
}

# =============================================================================
# TEST 6: Pivote bajo confirmado — barIndexLow y priceLow = low[1]
# =============================================================================
{
    # Con swing_length=2:
    #   Barra 0: low=90
    #   Barra 1: low=50  ← mínimo → swingLow[1]=50, low[1]=50
    #   Barra 2: low=70  ← low(70) > swingLow anterior(50)
    #            → confirma pivote bajo en barra 1, precio = low[1] = 50
    my @candles = (
        candle(100, 110, 90, 100),   # 0
        candle(100, 105, 50, 100),   # 1  — swing_low de la ventana
        candle(100, 108, 70, 100),   # 2  — low > 50 → confirma pivote bajo en barra 1
    );
    my $data = run_batch(\@candles, swing_length => 2);

    my $pl = $data->[2]{pivot_low};
    ok(defined $pl, "Test 6: pivote bajo definido en barra 2");
    is($pl->{bar_index}, 1,  "Test 6b: barIndexLow == 1 (barra anterior)");
    is($pl->{price},     50, "Test 6c: priceLow == low[1] == 50");
}

# =============================================================================
# TEST 7: Tramo completado al cambiar tendencia
# =============================================================================
{
    # Construimos una secuencia con un cambio de tendencia claro:
    # - Primero bull (high extremo)
    # - Luego bear (low extremo)
    # Al girar a bear debe haber al menos 1 tramo en _segments
    my @candles = (
        candle(100, 110, 90,  100),   # 0
        candle(100, 115, 88,  102),   # 1
        candle(100, 200, 95,  105),   # 2  bullish
        candle(100, 130, 92,  103),   # 3
        candle(100, 125, 10,  100),   # 4  bearish ← low extremo
        candle(100, 122, 50,  100),   # 5
    );
    my $data = run_batch(\@candles, swing_length => 3);

    my $segs_at_5 = $data->[5]{segments};
    ok(defined $segs_at_5 && scalar @$segs_at_5 >= 1,
        "Test 7: al menos 1 tramo completado tras el cambio de tendencia");

    if (scalar @$segs_at_5 >= 1) {
        my $seg = $segs_at_5->[-1];
        ok(defined $seg->{from_bar}   && defined $seg->{to_bar},   "Test 7b: tramo tiene from_bar y to_bar");
        ok(defined $seg->{from_price} && defined $seg->{to_price},  "Test 7c: tramo tiene from_price y to_price");
        ok($seg->{direction} =~ /^(bullish|bearish)$/,              "Test 7d: tramo tiene direction válido");
    }
}

# =============================================================================
# TEST 8: Parámetro pivot_high_uses_low=0 → precio del pivote alto = high[1]
# =============================================================================
{
    # Misma secuencia del Test 5, pero con pivot_high_uses_low=0
    my @candles = (
        candle(100, 100, 90, 100),   # 0
        candle(100, 200, 85, 100),   # 1  — high=200, low=85
        candle(100, 150, 80, 100),   # 2  — confirma pivote alto en barra 1
    );
    my $data = run_batch(\@candles, swing_length => 2, pivot_high_uses_low => 0);

    my $ph = $data->[2]{pivot_high};
    ok(defined $ph, "Test 8: pivote alto definido con pivot_high_uses_low=0");
    is($ph->{price}, 200, "Test 8b: priceHigh == high[1] == 200 cuando pivot_high_uses_low=0");
}

# =============================================================================
# TEST 9: trend_changed se activa solo en la barra del cambio
# =============================================================================
{
    my @candles = (
        candle(100, 110, 90,  100),   # 0
        candle(100, 115, 88,  102),   # 1
        candle(100, 200, 95,  105),   # 2  bullish
        candle(100, 125, 10,  100),   # 3  bearish
        candle(100, 122, 50,  100),   # 4  sigue bearish
    );
    my $data = run_batch(\@candles, swing_length => 3);

    # Barra 4: tendencia no cambió → trend_changed debe ser 0
    is($data->[4]{trend_changed}, 0,
        "Test 9: trend_changed=0 cuando la tendencia no cambia en la barra");
}

# =============================================================================
done_testing();
