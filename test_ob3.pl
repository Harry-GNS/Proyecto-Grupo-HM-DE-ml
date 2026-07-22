use strict;
use warnings;
use Market::MarketData;
use Market::IndicatorManager;

my $market = Market::MarketData->new();
open(my $fh, '<', 'Data/datos.csv') or die $!;
my $header = <$fh>;
while (my $line = <$fh>) {
    $line =~ s/[\r\n]//g;
    $line =~ s/"//g;
    my ($ts, $open, $high, $low, $close, $volume) = split(/,/, $line);
    $market->add_candle({
        timestamp => $ts, open => $open+0, high => $high+0,
        low => $low+0, close => $close+0, volume => $volume+0,
    });
}
close($fh);

my $indicators = Market::IndicatorManager->new();
require Market::Indicators::ATR;
$indicators->register('ATR', Market::Indicators::ATR->new(14));
require Market::Indicators::InternalZigZag;
$indicators->register('InternalZigZag', Market::Indicators::InternalZigZag->new());
require Market::Indicators::ZigZagTrend;
$indicators->register('ZigZagTrend', Market::Indicators::ZigZagTrend->new());
require Market::Indicators::SMC_Structures;
$indicators->register('SMC_Structures', Market::Indicators::SMC_Structures->new());

$indicators->recalculate_all($market);
my $smc = $indicators->get_raw('SMC_Structures');
if ($smc && $smc->{order_blocks}) {
    print "Found " . scalar(@{$smc->{order_blocks}}) . " active Order Blocks at end\n";
    for my $ob (@{$smc->{order_blocks}}) {
        print "OB: id=$ob->{id} dir=$ob->{direction} idx=$ob->{source_index} conf=$ob->{confirmation_index}\n";
    }
} else {
    print "No active Order Blocks at end\n";
}
