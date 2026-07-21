#!/usr/bin/perl
# =============================================================================
# zigzag_export.pl — Exportación de tendencia ZigZag a CSV
#
# Lee:   Data/datos.csv  (columnas: time,open,high,low,close,Volume)
# Escribe: zigzag_output.csv con una fila por barra, columnas:
#   bar, timestamp, trend, trend_changed, swing_high, swing_low,
#   pivot_high_bar, pivot_high_price, pivot_low_bar, pivot_low_price
#
# Uso:
#   perl scripts/zigzag_export.pl [--length N] [--input archivo.csv] [--output salida.csv]
#
# Ejemplo comparación contra TradingView:
#   perl scripts/zigzag_export.pl --length 150
# =============================================================================

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Getopt::Long;

use Market::Indicators::ZigZag_Trend;

# =============================================================================
# 1. Argumentos de línea de comandos
# =============================================================================
my $swing_length = 150;
my $input_file   = "$FindBin::Bin/../Data/datos.csv";
my $output_file  = "$FindBin::Bin/../zigzag_output.csv";
my $pivot_high_uses_low = 1;    # 1 = fiel al original ChartPrime

GetOptions(
    'length=i'            => \$swing_length,
    'input=s'             => \$input_file,
    'output=s'            => \$output_file,
    'pivot-high-uses-low=i' => \$pivot_high_uses_low,
) or die "Uso: $0 [--length N] [--input archivo.csv] [--output salida.csv]\n";

print "ZigZag Export — Configuración:\n";
print "  swing_length        = $swing_length\n";
print "  pivot_high_uses_low = $pivot_high_uses_low (1=low[1] fiel al original, 0=high[1])\n";
print "  input               = $input_file\n";
print "  output              = $output_file\n\n";

# =============================================================================
# 2. Lectura del CSV de entrada (streaming barra a barra)
# =============================================================================
open(my $fh_in, '<', $input_file)
    or die "Error: No se pudo abrir '$input_file': $!\n";

my $header = <$fh_in>;   # descartar cabecera
chomp(my $header_clean = $header // '');
print "Cabecera detectada: $header_clean\n";

# MarketData mínimo en memoria (no depende de Market::MarketData para portabilidad)
my @candles;
my @timestamps;

while (my $line = <$fh_in>) {
    chomp $line;
    next unless $line =~ /\S/;   # saltar líneas vacías

    my ($ts, $open, $high, $low, $close, $volume) = split(/,/, $line);
    push @timestamps, $ts;
    push @candles, {
        timestamp => $ts,
        open      => $open  + 0,
        high      => $high  + 0,
        low       => $low   + 0,
        close     => $close + 0,
        volume    => defined $volume ? $volume + 0 : 0,
    };
}
close($fh_in);

printf "Barras leídas: %d\n", scalar @candles;

# =============================================================================
# 3. FakeMarketData compatible con ZigZag_Trend
# =============================================================================
{
    package FakeMarketData;
    sub new        { bless { candles => [] }, shift }
    sub add_candle { push @{ $_[0]->{candles} }, $_[1] }
    sub size        { scalar @{ $_[0]->{candles} } }
    sub last_index  { $#{ $_[0]->{candles} } }
    sub get_candle  {
        my ($self, $i) = @_;
        return undef if !defined $i || $i < 0 || $i > $#{ $self->{candles} };
        return $self->{candles}[$i];
    }
}

# =============================================================================
# 4. Procesamiento streaming barra a barra (equivalente a TradingView)
# =============================================================================
my $md = FakeMarketData->new();
my $zz = Market::Indicators::ZigZag_Trend->new(
    swing_length        => $swing_length,
    pivot_high_uses_low => $pivot_high_uses_low,
);

print "Procesando barras...\n";
for my $candle (@candles) {
    $md->add_candle($candle);
    $zz->update_last($md);
}
print "Procesamiento completado.\n\n";

# =============================================================================
# 5. Escritura del CSV de salida
# =============================================================================
open(my $fh_out, '>', $output_file)
    or die "Error: No se pudo crear '$output_file': $!\n";

# Cabecera del CSV de salida
print $fh_out join(',',
    'bar',
    'timestamp',
    'open',
    'high',
    'low',
    'close',
    'trend',
    'trend_changed',
    'swing_high',
    'swing_low',
    'pivot_high_bar',
    'pivot_high_price',
    'pivot_low_bar',
    'pivot_low_price',
    'completed_segments',
) . "\n";

my $data = $zz->get_values();

for my $i (0 .. $#candles) {
    my $d = $data->[$i];
    next unless defined $d;

    my $c = $candles[$i];

    # Formatear valores con precisión de 5 decimales (suficiente para futuros)
    my $fmt = sub { defined $_[0] ? sprintf("%.5f", $_[0]) : '' };

    my $trend         = $d->{trend}         // '';
    my $trend_changed = $d->{trend_changed} // 0;
    my $swing_high    = $fmt->($d->{swing_high});
    my $swing_low     = $fmt->($d->{swing_low});

    my ($ph_bar, $ph_price) = ('', '');
    if (defined $d->{pivot_high}) {
        $ph_bar   = $d->{pivot_high}{bar_index};
        $ph_price = $fmt->($d->{pivot_high}{price});
    }

    my ($pl_bar, $pl_price) = ('', '');
    if (defined $d->{pivot_low}) {
        $pl_bar   = $d->{pivot_low}{bar_index};
        $pl_price = $fmt->($d->{pivot_low}{price});
    }

    my $n_segs = scalar @{ $d->{segments} };

    print $fh_out join(',',
        $i,
        $timestamps[$i] // '',
        $fmt->($c->{open}),
        $fmt->($c->{high}),
        $fmt->($c->{low}),
        $fmt->($c->{close}),
        $trend,
        $trend_changed,
        $swing_high,
        $swing_low,
        $ph_bar,
        $ph_price,
        $pl_bar,
        $pl_price,
        $n_segs,
    ) . "\n";
}

close($fh_out);

printf "CSV exportado: %s\n", $output_file;
printf "Total barras exportadas: %d\n", scalar @candles;

# =============================================================================
# 6. Resumen de pivotes detectados (para validación rápida en consola)
# =============================================================================
my $total_pivots_high    = 0;
my $total_pivots_low     = 0;
my $total_trend_changes  = 0;
my $last_pivot_high_bar  = undef;
my $last_pivot_low_bar   = undef;

for my $i (0 .. $#candles) {
    my $d = $data->[$i] // next;
    $total_trend_changes++ if $d->{trend_changed};

    if (defined $d->{pivot_high}) {
        my $bar = $d->{pivot_high}{bar_index};
        if (!defined $last_pivot_high_bar || $bar != $last_pivot_high_bar) {
            $total_pivots_high++;
            $last_pivot_high_bar = $bar;
        }
    }
    if (defined $d->{pivot_low}) {
        my $bar = $d->{pivot_low}{bar_index};
        if (!defined $last_pivot_low_bar || $bar != $last_pivot_low_bar) {
            $total_pivots_low++;
            $last_pivot_low_bar = $bar;
        }
    }
}

print "\n--- Resumen de detección ---\n";
printf "  Cambios de tendencia detectados : %d\n",  $total_trend_changes;
printf "  Pivotes altos confirmados        : %d\n",  $total_pivots_high;
printf "  Pivotes bajos confirmados        : %d\n",  $total_pivots_low;
printf "  Tramos ZigZag completados        : %d\n",
    scalar @{ $data->[-1]{segments} // [] };
print "----------------------------\n";
print "\nPara validar contra TradingView:\n";
print "  1. Abre el CSV de salida en Excel o Python\n";
print "  2. Busca filas donde trend_changed=1 (cambios de tendencia)\n";
print "  3. Compara pivot_high_bar/price y pivot_low_bar/price con los\n";
print "     pivotes mostrados por el indicador ZigZag Volume Profile [ChartPrime]\n";
print "     con la misma longitud ($swing_length) en TradingView.\n";
