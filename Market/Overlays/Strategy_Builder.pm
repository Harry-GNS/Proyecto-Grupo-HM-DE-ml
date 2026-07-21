package Market::Overlays::Strategy_Builder;

use strict;
use warnings;
use utf8;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},
        color_fvg_bull => $args{color_fvg_bull} || '#2979FF',
        color_fvg_bear => $args{color_fvg_bear} || '#FF5252',
        color_sd_supply => $args{color_sd_supply} || '#FF5252',
        color_sd_demand => $args{color_sd_demand} || '#00E676',
        color_vwap => $args{color_vwap} || '#FFD600',
    };
    bless $self, $class;
    return $self;
}

sub render {
    my ($self, $scale, $strategy_data, $start_idx_viewport) = @_;
    my $c = $self->{canvas};
    $c->delete('strategy_overlay');

    return unless $strategy_data;

    my $width  = $c->width;
    my $height = $c->height;
    my $min_val = $scale->{min_val};
    my $max_val = $scale->{max_val};
    my $visible_bars = $scale->{visible_bars};
    my $offset_frac = $scale->{offset} || 0;
    my $range = $max_val - $min_val;
    return if $range <= 0;
    my $candle_width = $width / $visible_bars;

    # 1. Dibujar FVGs
    if (exists $strategy_data->{fvgs} && ref $strategy_data->{fvgs} eq 'ARRAY') {
        for my $fvg (@{ $strategy_data->{fvgs} }) {
            next unless $fvg->{top} && $fvg->{bottom} && defined $fvg->{start_idx};
            my $rel_start = $fvg->{start_idx} - ($start_idx_viewport // 0);
            my $x1 = ($rel_start - $offset_frac) * $candle_width + ($candle_width / 2);
            my $x2 = $width + 2000;
            if (defined $fvg->{mitigated_idx}) {
                my $rel_end = $fvg->{mitigated_idx} - ($start_idx_viewport // 0);
                $x2 = ($rel_end - $offset_frac) * $candle_width + ($candle_width / 2);
            }
            my $y1 = $height - ((($fvg->{top} - $min_val) / $range) * $height);
            my $y2 = $height - ((($fvg->{bottom} - $min_val) / $range) * $height);
            my $color = $fvg->{type} eq 'bullish_fvg' ? $self->{color_fvg_bull} : $self->{color_fvg_bear};
            $c->createRectangle($x1, $y1, $x2, $y2, -fill => $color, -outline => $color, -stipple => 'gray25', -tags => ['strategy_overlay']);
            $c->createLine($x1, ($y1+$y2)/2, $x2, ($y1+$y2)/2, -dash => '-', -fill => $color, -width => 1, -tags => ['strategy_overlay']);
        }
    }

    # 2. Dibujar Supply & Demand zones (solo relevantes)
    if (exists $strategy_data->{sd_zones} && ref $strategy_data->{sd_zones} eq 'ARRAY') {
        for my $z (@{ $strategy_data->{sd_zones} }) {
            next unless defined $z->{price};
            # filtrar: mostrar sólo relevantes o order blocks/liq_take
            next unless $z->{relevant} || $z->{type} eq 'liquidity_take';
            # order blocks: puntos verdes horizontales
            if ($z->{type} eq 'demand') {
                my $rel = ($z->{start_idx} || 0) - ($start_idx_viewport // 0);
                my $x = ($rel - $offset_frac) * $candle_width + ($candle_width/2);
                my $y = $height - ((($z->{price} - $min_val) / $range) * $height);
                $c->createOval($x-3, $y-3, $x+3, $y+3, -fill => $self->{color_sd_demand}, -outline => '', -tags => ['strategy_overlay']);
            } elsif ($z->{type} eq 'supply') {
                my $rel = ($z->{start_idx} || 0) - ($start_idx_viewport // 0);
                my $x = ($rel - $offset_frac) * $candle_width + ($candle_width/2);
                my $y = $height - ((($z->{price} - $min_val) / $range) * $height);
                $c->createOval($x-3, $y-3, $x+3, $y+3, -fill => $self->{color_sd_supply}, -outline => '', -tags => ['strategy_overlay']);
            } elsif ($z->{type} eq 'liquidity_take') {
                my $rel = ($z->{idx} || 0) - ($start_idx_viewport // 0);
                my $x = ($rel - $offset_frac) * $candle_width + ($candle_width/2);
                my $y = $height - (((($z->{price} - $min_val) / $range) * $height));
                $c->createText($x, $y-8, -text=>'LT', -fill => '#FF9100', -font=>'Helvetica 8 bold', -tags=>['strategy_overlay']);
            }
        }
    }

    # 3. Dibujar Perfil de Volumen (POC, VAH, VAL) en la región derecha
    if (exists $strategy_data->{volume_profile} && ref $strategy_data->{volume_profile} eq 'HASH') {
        my $vp = $strategy_data->{volume_profile};
        if ($vp->{poc}) {
            my $poc_price = $vp->{poc} / 1; # bucket numeric
            my $y = $height - (((($poc_price - $min_val) / $range) * $height));
            $c->createLine($width-80, $y, $width, $y, -fill => '#FFD600', -width => 2, -tags => ['strategy_overlay']);
            $c->createText($width-85, $y, -text => 'POC', -fill => '#FFD600', -anchor => 'e', -font => 'Helvetica 8 bold', -tags => ['strategy_overlay']);
        }
        if ($vp->{vah}) {
            my $vah_price = $vp->{vah} / 1;
            my $y = $height - (((($vah_price - $min_val) / $range) * $height));
            $c->createLine($width-60, $y, $width, $y, -fill => '#B39DDB', -dash => '.', -tags => ['strategy_overlay']);
        }
        if ($vp->{val}) {
            my $val_price = $vp->{val} / 1;
            my $y = $height - (((($val_price - $min_val) / $range) * $height));
            $c->createLine($width-60, $y, $width, $y, -fill => '#B39DDB', -dash => '.', -tags => ['strategy_overlay']);
        }
    }

    # 4. Dibujar Anchored VWAPs
    if (exists $strategy_data->{anchored_vwap} && ref $strategy_data->{anchored_vwap} eq 'HASH') {
        my $avs = $strategy_data->{anchored_vwap};
        my $i = 0;
        for my $label (keys %$avs) {
            my $rec = $avs->{$label};
            next unless $rec && defined $rec->{vwap};
            my $p = $rec->{vwap};
            my $y = $height - (((($p - $min_val) / $range) * $height));
            my $col = $self->{color_vwap};
            $c->createLine(0, $y, $width, $y, -fill => $col, -dash => ($i%2?'-':'- '), -width => 1.5, -tags => ['strategy_overlay']);
            $c->createText(5, $y - 8 - ($i*12), -text => "VWAP:$label", -fill => $col, -anchor=>'w', -font=>'Helvetica 8', -tags=>['strategy_overlay']);
            $i++;
        }
    }

    # 5. Trendlines y Canal paralelo: usar últimos swings relevantes
    if (exists $strategy_data->{sd_zones} && ref $strategy_data->{sd_zones} eq 'ARRAY') {
        # recopilar swings marcados relevantes
        my @swings = grep { $_->{relevant} && ($_->{type} eq 'supply' || $_->{type} eq 'demand') } @{ $strategy_data->{sd_zones} };
        if (@swings >= 2) {
            # tomar los dos más recientes
            my @sorted = sort { ($b->{start_idx}//0) <=> ($a->{start_idx}//0) } @swings;
            my $a = $sorted[0];
            my $b = $sorted[1];
            # coords
            my $rel_a = ($a->{start_idx}||0) - ($start_idx_viewport//0);
            my $rel_b = ($b->{start_idx}||0) - ($start_idx_viewport//0);
            my $xa = ($rel_a - $offset_frac) * $candle_width + ($candle_width/2);
            my $xb = ($rel_b - $offset_frac) * $candle_width + ($candle_width/2);
            my $ya = $height - ((($a->{price} - $min_val) / $range) * $height);
            my $yb = $height - ((($b->{price} - $min_val) / $range) * $height);
            # trendline
            $c->createLine($xa, $ya, $xb, $yb, -fill=>'#9E9E9E', -width=>1.5, -tags=>['strategy_overlay']);
            # parallel channel: offset by distance between points and lowest point
            my $dx = $xb - $xa; my $dy = $yb - $ya;
            # proyectar otra línea paralela desplazada hacia el otro lado por 40 pixels
            my $offset_px = 40;
            my ($nx1, $ny1) = ($xa - $dy * ($offset_px/($dx||1)), $ya + $dx * ($offset_px/($dx||1)));
            my ($nx2, $ny2) = ($xb - $dy * ($offset_px/($dx||1)), $yb + $dx * ($offset_px/($dx||1)));
            $c->createLine($nx1,$ny1,$nx2,$ny2, -dash=>'--', -fill=>'#9E9E9E', -tags=>['strategy_overlay']);
        }
    }

    # 6. Fibonacci (ultimo swing high -> low relevante)
    # Fibonacci: usar niveles calculados por el indicador (si existen)
    if (exists $strategy_data->{fibonacci_levels} && ref $strategy_data->{fibonacci_levels} eq 'ARRAY') {
        for my $lev (@{ $strategy_data->{fibonacci_levels} }) {
            next unless defined $lev->{price} && defined $lev->{ratio};
            my $p = $lev->{price};
            my $r = $lev->{ratio};
            my $y = $height - (((($p - $min_val) / $range) * $height));
            my $col = '#C5CAE9';
            $c->createLine(0,$y,$width,$y, -dash=>'.', -fill=>$col, -tags=>['strategy_overlay']);
            $c->createText($width-5, $y, -text => sprintf('F%.3g',$r), -fill=>$col, -anchor=>'e', -font=>'Helvetica 8', -tags=>['strategy_overlay']);
        }
    }

    # 7. Dibujar niveles de liquidez (líneas horizontales)
    if (exists $strategy_data->{liquidity_levels} && ref $strategy_data->{liquidity_levels} eq 'ARRAY') {
        for my $p (@{ $strategy_data->{liquidity_levels} }) {
            next unless defined $p;
            my $y = $height - (((($p - $min_val) / $range) * $height));
            $c->createLine(0,$y,$width,$y, -dash => '-', -fill => '#00C853', -stipple=>'gray12', -tags=>['strategy_overlay']);
            $c->createText(8, $y+6, -text=>'LQ', -fill=>'#00C853', -anchor=>'w', -font=>'Helvetica 7 bold', -tags=>['strategy_overlay']);
        }
    }

    # Push layer back
    $c->lower('strategy_overlay');
}

1;
