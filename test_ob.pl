use strict;
use warnings;
use Market::MarketData;
use Market::IndicatorManager;

my $md = Market::MarketData->new();
$md->load_csv('Data/datos.csv');
my $im = Market::IndicatorManager->new();

$md->start_replay(15000);
$im->{indicators}{ATR} = Market::Indicators::ATR->new(period => 14);
require Market::Indicators::InternalZigZag;
$im->{indicators}{InternalZigZag} = Market::Indicators::InternalZigZag->new();
require Market::Indicators::ZigZagTrend;
$im->{indicators}{ZigZagTrend} = Market::Indicators::ZigZagTrend->new();
require Market::Indicators::SMC_Structures;
$im->{indicators}{SMC_Structures} = Market::Indicators::SMC_Structures->new();

$im->recalculate_all($md);

my $smc = $im->get_raw('SMC_Structures');
if ($smc && $smc->{order_blocks}) {
    print "Found " . scalar(@{$smc->{order_blocks}}) . " Order Blocks\n";
    for my $ob (@{$smc->{order_blocks}}) {
        print "OB: dir=$ob->{direction}, source=$ob->{source_index}, conf=$ob->{id}\n";
    }
} else {
    print "No SMC_Structures raw data or order blocks\n";
}
