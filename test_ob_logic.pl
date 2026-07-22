use strict;
use warnings;
use Market::MarketData;
use Market::IndicatorManager;

my $market = Market::MarketData->new();
open(my $fh, '<', 'Data/datos.csv') or die $!;
my $header = <$fh>;
my $limit = 500;
my $i = 0;
while (my $line = <$fh>) {
    last if $i++ > $limit;
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
require Market::Indicators::SMC_Structures;

# Override push to print
no warnings 'redefine';
my $orig_push = \&Market::Indicators::SMC_Structures::_build_order_blocks;

$indicators->register('SMC_Structures', Market::Indicators::SMC_Structures->new());

$indicators->recalculate_all($market);
my $smc = $indicators->get_raw('SMC_Structures');
print "Done.\n";
