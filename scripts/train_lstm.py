import pandas as pd
import numpy as np
import os
import joblib
from sklearn.preprocessing import MinMaxScaler
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import LSTM, Dense, Dropout

# Paths
DATA_CSV = "Data/lstm_dataset.csv"
DATA_EXCEL = "Data/lstm_dataset.xlsx"
MODEL_PATH = "Data/lstm_model.h5"
SCALER_X_PATH = "Data/scaler_x.pkl"
SCALER_Y_PATH = "Data/scaler_y.pkl"

print(f"Loading dataset from {DATA_CSV}...")
df = pd.read_csv(DATA_CSV)

# Save to Excel as requested
print(f"Saving dataset to Excel format at {DATA_EXCEL}...")
df.to_excel(DATA_EXCEL, index=False)

# Features and target
feature_cols = [
    'supply_bottom_pips_60m', 'demand_top_pips_60m', 'demand_bottom_pips_60m',
    'trendline_upper_pips_60m', 'trendline_lower_pips_60m', 'channel_width_pips_60m',
    'ghost_high_pips_60m', 'ghost_low_pips_60m',
    'ob_top_pips', 'ob_bottom_pips', 'fvg_top_pips', 'fvg_bottom_pips',
    'bos_choch_pips', 'eq_level_pips', 'vwap_pips',
    'poc_pips', 'vah_pips', 'val_pips', 'atr_1m'
]
target_col = 'target_5m'

print("Preprocessing data...")
# Fill missing values with 0 (assuming missing means indicator not active or no distance)
df[feature_cols] = df[feature_cols].fillna(0)
# Drop rows where target is NaN (usually the end of the dataset)
df_clean = df.dropna(subset=[target_col]).copy()

# Scale features
scaler_x = MinMaxScaler()
X_scaled = scaler_x.fit_transform(df_clean[feature_cols])

# Scale target
scaler_y = MinMaxScaler()
y_scaled = scaler_y.fit_transform(df_clean[[target_col]])

# Save scalers for prediction
joblib.dump(scaler_x, SCALER_X_PATH)
joblib.dump(scaler_y, SCALER_Y_PATH)

# Create sequences
SEQ_LEN = 10
X, y = [], []
for i in range(len(X_scaled) - SEQ_LEN):
    X.append(X_scaled[i : i + SEQ_LEN])
    y.append(y_scaled[i + SEQ_LEN])

X = np.array(X)
y = np.array(y)

# Train/test split (80/20)
split = int(0.8 * len(X))
X_train, X_test = X[:split], X[split:]
y_train, y_test = y[:split], y[split:]

print(f"Training data shape: X={X_train.shape}, y={y_train.shape}")

# Build LSTM model (2 hidden layers)
model = Sequential([
    LSTM(50, return_sequences=True, input_shape=(SEQ_LEN, len(feature_cols))),
    Dropout(0.2),
    LSTM(50),
    Dropout(0.2),
    Dense(1)
])

model.compile(optimizer='adam', loss='mse')

print("Training model...")
# Keep epochs low for the demo
model.fit(X_train, y_train, epochs=5, batch_size=32, validation_data=(X_test, y_test))

print(f"Saving model to {MODEL_PATH}...")
model.save(MODEL_PATH)

print("Process completed successfully.")
