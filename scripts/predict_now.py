import pandas as pd
import numpy as np
import os
import joblib
import sys
from tensorflow.keras.models import load_model

# Paths
DATA_CSV = "Data/lstm_dataset.csv"
MODEL_PATH = "Data/lstm_model.h5"
SCALER_X_PATH = "Data/scaler_x.pkl"
SCALER_Y_PATH = "Data/scaler_y.pkl"

if not os.path.exists(MODEL_PATH) or not os.path.exists(SCALER_X_PATH):
    print("Error: The model or scalers do not exist. Please run train_lstm.py first.")
    sys.exit(1)

print("Loading model and scalers...")
model = load_model(MODEL_PATH)
scaler_x = joblib.load(SCALER_X_PATH)
scaler_y = joblib.load(SCALER_Y_PATH)

print(f"Loading latest market data from {DATA_CSV}...")
df = pd.read_csv(DATA_CSV)

feature_cols = [
    'supply_bottom_pips_60m', 'demand_top_pips_60m', 'demand_bottom_pips_60m',
    'trendline_upper_pips_60m', 'trendline_lower_pips_60m', 'channel_width_pips_60m',
    'ghost_high_pips_60m', 'ghost_low_pips_60m',
    'ob_top_pips', 'ob_bottom_pips', 'fvg_top_pips', 'fvg_bottom_pips',
    'bos_choch_pips', 'eq_level_pips', 'vwap_pips',
    'poc_pips', 'vah_pips', 'val_pips', 'atr_1m'
]

SEQ_LEN = 10

if len(df) < SEQ_LEN:
    print(f"Error: Not enough data for prediction. Need at least {SEQ_LEN} candles.")
    sys.exit(1)

# Get the last SEQ_LEN rows (current state)
df_current = df.tail(SEQ_LEN).copy()
df_current[feature_cols] = df_current[feature_cols].fillna(0)

# Scale
X_current_scaled = scaler_x.transform(df_current[feature_cols])
# Reshape for LSTM (1, SEQ_LEN, NUM_FEATURES)
X_input = X_current_scaled.reshape(1, SEQ_LEN, len(feature_cols))

print("Predicting target_5m (Price displacement in 5 minutes)...")
pred_scaled = model.predict(X_input)
pred = scaler_y.inverse_transform(pred_scaled)

target_value = pred[0][0]
current_close = df_current['close'].iloc[-1]
current_time = df_current['time'].iloc[-1]

print("\n=========================================")
print(f"CURRENT STATE (Time: {current_time})")
print(f"Current Close Price: {current_close:.2f}")
print("=========================================")
print(f"PREDICTION (5 minutes ahead):")
if target_value > 0:
    print(f"Direction: UP ⬆️")
    print(f"Expected Move: +{target_value:.2f} points")
    print(f"Projected Price: {current_close + target_value:.2f}")
else:
    print(f"Direction: DOWN ⬇️")
    print(f"Expected Move: {target_value:.2f} points")
    print(f"Projected Price: {current_close + target_value:.2f}")
print("=========================================\n")
