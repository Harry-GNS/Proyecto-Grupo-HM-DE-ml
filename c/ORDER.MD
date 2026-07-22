#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";

use Test::More;

use Market::Indicators::Strategy_Builder;
use Market::Overlays::Strategy_Builder;

sub candle {
    my ($i, $open, $high, $low, $close, $volume) = @_;
    return {
        time   => sprintf('2026-06-29T00:%02d:00', $i),
        open   => $open,
        high   => $high,
        low    => $low,
        close  => $close,
        volume => $volume // 100,
    };
}

sub strategy_for_prefix {
    my ($candles, $max_idx) = @_;
    return Market::Indicators::Strategy_Builder->compute(
        candles           => $candles,
        atr_series        => [ map { 1 } @$candles ],
        liquidity_levels  => [],
        liquidity_events  => [],
        structure_events  => [{
            id          => 'BOS_1',
            type        => 'BOS',
            scope       => 'external',
            break_index => 2,
        }],
        pivots            => [],
        max_visible_index => $max_idx,
        timeframe         => '1m',
    );
}

sub order_block_shapes {
    my ($strategy, $max_idx) = @_;
    my $shapes = Market::Overlays::Strategy_Builder->build_shapes(
        strategy          => $strategy,
        max_visible_index => $max_idx,
        timeframe         => '1m',
    );
    return [ grep {
        ($_->{kind} // '') eq 'rectangle'
            && ($_->{color_role} // '') =~ /^order_block_/
    } @$shapes ];
}

my $bullish_touch = [
    candle(0, 106, 107,  99, 103),
];
my $bullish_mitigated =
    Market::Indicators::Strategy_Builder::_resolve_order_block(
        $bullish_touch, 0, 0, 'demand', 100, 105,
    );
is($bullish_mitigated->{end_index}, 0,
   'bullish OB ends when price mitigates the zone');
is($bullish_mitigated->{status}, 'mitigated',
   'bullish touch moves OB to a terminal mitigated state');

my $bullish_break = [
    candle(0, 106, 108, 106, 107),
    candle(1, 103, 104,  98,  99),
];
my $bullish_consumed =
    Market::Indicators::Strategy_Builder::_resolve_order_block(
        $bullish_break, 0, 1, 'demand', 100, 105,
    );
is($bullish_consumed->{end_index}, 1,
   'bullish OB ends when close reaches the distal low');
is($bullish_consumed->{status}, 'invalidated',
   'bullish distal close moves OB to a terminal state');

my $bearish_touch = [
    candle(0,  94, 101,  93,  97),
];
my $bearish_mitigated =
    Market::Indicators::Strategy_Builder::_resolve_order_block(
        $bearish_touch, 0, 0, 'supply', 95, 100,
    );
is($bearish_mitigated->{end_index}, 0,
   'bearish OB ends when price mitigates the zone');
is($bearish_mitigated->{status}, 'mitigated',
   'bearish touch moves OB to a terminal mitigated state');

my $bearish_break = [
    candle(0,  94,  94.5, 93,  94.2),
    candle(1,  97, 102,   96, 101),
];
my $bearish_consumed =
    Market::Indicators::Strategy_Builder::_resolve_order_block(
        $bearish_break, 0, 1, 'supply', 95, 100,
    );
is($bearish_consumed->{end_index}, 1,
   'bearish OB ends when close reaches the distal high');
is($bearish_consumed->{status}, 'invalidated',
   'bearish distal close moves OB to a terminal state');

my $overlay_strategy = {
    order_blocks => [
        {
            id => 'BULL_ACTIVE', ob_side => 'bullish', start_index => 2,
            confirmed_index => 3, low => 90, high => 95,
            active => 1, status => 'active', ob_scope => 'internal',
        },
        {
            id => 'BEAR_ACTIVE', ob_side => 'bearish', start_index => 5,
            confirmed_index => 6, low => 110, high => 115,
            active => 1, status => 'active', ob_scope => 'external',
        },
        {
            id => 'BULL_USED', ob_side => 'bullish', start_index => 1,
            confirmed_index => 2, end_index => 7, low => 80, high => 85,
            active => 0, status => 'mitigated',
        },
        {
            id => 'BEAR_INVALID', ob_side => 'bearish', start_index => 4,
            confirmed_index => 5, end_index => 8, low => 120, high => 125,
            active => 0, status => 'invalidated',
        },
    ],
    supply_zones => [{
        id => 'SUPPLY_HISTORY', start_index => 1, confirmed_index => 2,
        end_index => 7, low => 120, high => 125,
        active => 0, status => 'mitigated',
    }],
};
my $overlay_shapes = Market::Overlays::Strategy_Builder->build_shapes(
    strategy          => $overlay_strategy,
    max_visible_index => 12,
    timeframe         => '1m',
);
my @visible_obs = grep {
    ($_->{kind} // '') eq 'rectangle'
        && ($_->{color_role} // '') =~ /^order_block_/
} @$overlay_shapes;
is(scalar @visible_obs, 2,
   'renderer emits every pending OB and excludes all terminal OBs');
is_deeply(
    [ sort map { $_->{color_role} } @visible_obs ],
    [qw(order_block_external_bearish order_block_internal_bullish)],
    'internal and external pending OBs remain visible simultaneously',
);
ok(!scalar(grep { $_->{x2_index} != 12 } @visible_obs),
   'every pending OB extends to the current candle');
ok(!scalar(grep { defined($_->{text}) && length($_->{text}) } @visible_obs),
   'OB rectangles do not draw large text inside the zone');
my @ob_labels = grep {
    ($_->{kind} // '') eq 'label'
        && ($_->{color_role} // '') =~ /^order_block_/
} @$overlay_shapes;
is_deeply(
    [ sort map { $_->{text} } @ob_labels ],
    ['External OB', 'Internal OB'],
    'OB labels identify scope with compact text outside the rectangle',
);
ok(!scalar(grep { ($_->{label_position} // '') ne 'above' } @ob_labels),
   'OB labels are positioned above the zone');
is_deeply(
    [ sort map { $_->{x1_index} } @ob_labels ],
    [12, 12],
    'OB labels are anchored at the projected end of active blocks',
);
ok(!scalar(grep { !$_->{extend_right} } @visible_obs),
   'pending OB rectangles are marked for right-edge extension');
is_deeply(
    [ sort { $a->[0] <=> $b->[0] }
      map { [$_->{x1_index}, $_->{y1_price}, $_->{y2_price}] } @visible_obs ],
    [[2, 90, 95], [5, 110, 115]],
    'renderer preserves origin and price boundaries');
is(scalar(grep { ($_->{color_role} // '') eq 'supply' } @$overlay_shapes), 1,
   'active-only filter is restricted to order blocks');

my $dedupe_candles = [
    candle(0, 102, 103, 100, 101,  100),
    candle(1, 100, 105,  99, 104,  100),
    candle(2, 104, 104,  96,  97, 1000),
    candle(3, 112, 113, 105, 106, 1000),
    candle(4, 104, 104,  96,  97, 1000),
];
my $before_consumption = strategy_for_prefix($dedupe_candles, 2);
my $at_consumption     = strategy_for_prefix($dedupe_candles, 3);
my $after_consumption  = strategy_for_prefix($dedupe_candles, 4);

is(scalar @{ $before_consumption->{order_blocks} }, 1,
   'first structural movement creates one canonical OB');
is($before_consumption->{order_blocks}[0]{status}, 'active',
   'canonical OB is pending before the distal close');
is_deeply(
    [@{ $before_consumption->{order_blocks}[0] }{qw(start_index low high)}],
    [1, 100, 105],
    'canonical OB keeps the original candle and bounds',
);
is(scalar @{ order_block_shapes($before_consumption, 2) }, 1,
   'pending canonical OB is rendered before consumption');

is(scalar @{ $at_consumption->{order_blocks} }, 1,
   'same origin is not duplicated on the consumption candle');
is($at_consumption->{order_blocks}[0]{status}, 'invalidated',
   'canonical OB records the terminal state on consumption');
is(scalar @{ order_block_shapes($at_consumption, 3) }, 0,
   'OB rectangle disappears on the terminal candle');

is(scalar @{ $after_consumption->{order_blocks} }, 1,
   'later displacement does not recreate the consumed origin');
is(scalar(grep { $_->{active} } @{ $after_consumption->{order_blocks} }), 0,
   'consumed OB remains non-pending in later prefixes');
is(scalar @{ order_block_shapes($after_consumption, 4) }, 0,
   'consumed OB stays absent from later renders');

my $dual_scope_strategy = Market::Indicators::Strategy_Builder->compute(
    candles           => $dedupe_candles,
    atr_series        => [ map { 1 } @$dedupe_candles ],
    liquidity_levels  => [],
    liquidity_events  => [],
    structure_events  => [
        {
            id          => 'BOS_EXT',
            type        => 'BOS',
            scope       => 'external',
            break_index => 2,
        },
        {
            id          => 'BOS_INT',
            type        => 'BOS',
            scope       => 'internal',
            break_index => 2,
        },
    ],
    pivots            => [],
    max_visible_index => 2,
    timeframe         => '1m',
);
is_deeply(
    [ sort map { $_->{ob_scope} // '' } @{ $dual_scope_strategy->{order_blocks} } ],
    [qw(external internal)],
    'same origin can create independent external and internal OBs',
);

done_testing();
