
3

Automatic Zoom
Versión 0.1.2
Proyecto de Machine Learning/Aprendizaje 
Automático - Parte 1: Visualización de Datos 
mediante Motor de Charting usando la librería Tk
Desarrollo   de   un   motor   de   gráficos   financieros   con   indicadores   técnicos
mediante la librería Tk.
 1. Objetivo:🎯
El objetivo de la primera parte de este proyecto es desarrollar un sistema
funcional   equivalente   a   una   plataforma   de   gráficos   financieros   como
TradingView   (www.tradingview.com),   el   cual   permitirá   trabajar   el
componente   de   Visualización   de   Datos   de   Machine   Learning/Aprendizaje
Automático, el cual permitirá  la oportuna  integración de los indicadores  y
visualización   de   datos   necesarios   para   entrenar   modelos   predictivos
recurrentes a lo largo del segundo bimestre.
 2. Conceptos clave que aprenderán🧠
Este proyecto cubre:
Matemática
Transformaciones lineales 
Escalado de datos
Machine Learning/Aprendizaje Automático
Visualización de Datos
Desarrollo de indicadores
Extracción de características
Análisis de datos (2do bimestre)
Desarrollo de modelos predictivos recurrentes (2do bimestre)
Programación
Arquitectura modular 
Programación Orientada a Objetos
Separación de responsabilidades (Técnicas de Ingeniería de Software)
Trading systems
OHLC 
Indicadores técnicos 
Visualización financiera
 3. Arquitectura del proyecto🧱
El sistema está dividido en 4 capas:
1. Datos
Market/MarketData.pm 
Maneja etiquetas temporales, velas, precios, volumen 
2. Indicadores
Market/IndicatorManager.pm 
Market/Indicators/ATR.pm 
Calculan señales (ATR, etc.) 
3. Renderizado
Market/ChartEngine.pm 
Market/Panels/PricePanel.pm 
Market/Panels/ATRPanel.pm 
Market/Panels/Scales.pm 
4. Aplicación
market.pl
 4. Estructura📁Market/
│
├── ChartEngine.pm
├── MarketData.pm
├── IndicatorManager.pm
│
├── Indicators/
│   └── ATR.pm
│
└── Panels/
    ├── PricePanel.pm
    ├── ATRPanel.pm
    └── Scales.pm
 5. Funcionalidades que deben replicar 🎯
desde TradingView
Básico
Velas
Eje vertical de precios
Eje vertical del indicador ATR
Eje horizontal de tiempo.
Scroll horizontal (arrastre de mouse)
Intermedio
Zoom vertical automático / vertical manual (barra de precios) / zoom 
horizontal (eje temporal)
Crosshair sincronizado entre todos los paneles
Múltiples panel sincronizados en el tiempo
Avanzado
Indicadores desacoplados 
Escalas verticales independientes por panel 
Render incremental – Complexidad O(1)
Temporalidades de 1, 5 y 15 minutos 
 6. Metodología de trabajo🧪
Cada método debe implementarse respetando estrictamente:
Inputs definidos
Outputs esperados
Responsabilidad única de cada módulo
Documentación del código
Buenas prácticas de codificación
Técnicas de Ingeniería de Software
Validar comportamiento que sea idéntico al de TradingView
⚠  Prohibido:
No mezclar la lógica de cálculo con renderizado
No usar variables globales 
No acoplar indicadores al chart
Utilzar otras librerías sino las que están definidas en el código dado
 7. Guía de implementación por módulos🧩
Instalación de librerías:
sudo cpanm Time::Moment
sudo dnf install perl-Tk
sudo cpanm Tk
sudo cpanm Tk::Chart
sudo cpanm Chart::Clicker
Definición de las Plantillas de Trabajo:
Las plantillas descritas a continuación definen la estructura completa de un
sistema   equivalente   a   una   plataforma   de   gráficos   financieros   como
TradingView.   Cada   grupo   de   estudiantes   deberá   completar   la   lógica
siguiendo las descripciones.
 Market/MarketData.pm📦
Descripción
Clase responsable de almacenar y gestionar los datos de mercado (OHLCV).
Debe   garantizar   sincronización   temporal,   acceso   eficiente   por   índice   y
actualización incremental de datos.
new
Inicializa almacenamiento de datos OHLC.
get_data
Devuelve la estructura completa de datos.
 Acceso general.👉
add_candle
Agrega una vela nueva.
 Entrada principal de datos.👉
build_tf_candles
Construye velas en una temporalidad específica.
 Agregación (ej: 1m → 5m).👉
build_timeframes
Construye todas las temporalidades disponibles.
 Preprocesamiento completo.👉
set_timeframe
Selecciona la temporalidad activa.
 Afecta qué datos se usan.👉
_active_array
Devuelve el array activo según timeframe.
 Abstracción interna clave.👉
get_slice
Devuelve un subconjunto de velas.
 Base para indicadores y render.👉
get_candle
Obtiene una vela por índice.
size
Número total de velas.
last_candle
Devuelve la última vela.
last_index
Devuelve índice de la última vela.
get_timestamp
Obtiene timestamp de una vela.
merge_delta_row
Actualiza o inserta datos incrementales.
 Manejo de streaming.👉
compute_time_anchors
Calcula puntos clave de tiempo.
 Usado para ejes o etiquetas.👉
package Market::MarketData;
use strict;
use warnings;
sub new {
my ($class) = @_;
my $self = {
data => {},
};
bless $self, $class;
return $self;
}
sub get_data {
my ($self) = @_;
# TODO
}
sub add_candle {
my ($self, $candle) = @_;
# TODO
}
sub build_tf_candles {
my ($self, $tf) = @_;
# TODO
}
sub build_timeframes {
my ($self) = @_;
# TODO
}
sub set_timeframe {
my ($self, $tf) = @_;
# TODO
}
sub _active_array {
