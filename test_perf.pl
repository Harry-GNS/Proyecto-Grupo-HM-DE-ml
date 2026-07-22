use strict;
use warnings;
use Time::HiRes qw(time);
use Market::MarketData;
use Market::IndicatorManager;

my $md = Market::MarketData->new();
$md->load_csv('Data/datos.csv');
my $im = Market::IndicatorManager->new();

$md->start_replay(10000);
$im->{indicators}{ATR} = Market::Indicators::ATR->new(period => 14);
require Market::Indicators::InternalZigZag;
$im->{indicators}{InternalZigZag} = Market::Indicators::InternalZigZag->new();
require Market::Indicators::ZigZagTrend;
$im->{indicators}{ZigZagTrend} = Market::Indicators::ZigZagTrend->new();
require Market::Indicators::SMC_Structures;
$im->{indicators}{SMC_Structures} = Market::Indicators::SMC_Structures->new();

my $t0 = time();
$im->recalculate_all($md);
my $t1 = time();
printf("Recalculate 10000 took %.3f s\n", $t1 - $t0);

$md->step_replay(1);
my $t2 = time();
$im->recalculate_all($md);
my $t3 = time();
printf("Recalculate 10001 took %.3f s\n", $t3 - $t2);
