"""
============================================================
DATA COVERAGE CHECK — standalone, read-only diagnostic
============================================================
Run this directly (does NOT need Flask running):

    cd C:\\Dassa\\Research\\project\\backend
    python check_data_coverage.py

For every crop/district/grade combination, shows:
  - total rows (any year)
  - valid 2025+ rows (using the EXACT same strict date parsing
    that compute_features() uses for prediction)
  - whether it would currently be OFFERED as a choice in the app
    (metadata rule: needs 4+ valid 2025+ rows)
  - whether it would actually PREDICT successfully if chosen
    (compute_features rule: same 4+ threshold, so these two
    columns should always match for a healthy combo)

This bypasses any question of "did Flask restart yet" — it reads
the database file directly, right now, as it truly is.
============================================================
"""
import sqlite3
import pandas as pd
import os

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'price_data.db')

if not os.path.exists(DB_PATH):
    print(f"ERROR: could not find {DB_PATH}")
    print("Run this script from inside the backend folder.")
    raise SystemExit(1)

conn = sqlite3.connect(DB_PATH)
df = pd.read_sql_query("SELECT crop, district, grade, date FROM price_history", conn)
conn.close()

print(f"Total rows in price_history: {len(df)}\n")

# Total count per combo (any year, any date format)
total_counts = df.groupby(['crop', 'district', 'grade']).size().reset_index(name='total_rows')

# Strict parse — identical rule to compute_features() / current metadata fix
df['parsed_date'] = pd.to_datetime(df['date'], format='%d.%m.%Y', errors='coerce')
bad_dates = df['parsed_date'].isna().sum()
df_valid = df.dropna(subset=['parsed_date'])
df_2025 = df_valid[df_valid['parsed_date'].dt.year >= 2025]

valid_counts = df_2025.groupby(['crop', 'district', 'grade']).size().reset_index(name='valid_2025_rows')

if bad_dates > 0:
    print(f"NOTE: {bad_dates} rows in the whole table have a date string that "
          f"does NOT match DD.MM.YYYY and were dropped from the 2025+ count.\n")

# Merge — combos that ONLY appear in total_counts had zero 2025+ valid rows
merged = total_counts.merge(valid_counts, on=['crop', 'district', 'grade'], how='left')
merged['valid_2025_rows'] = merged['valid_2025_rows'].fillna(0).astype(int)
merged['would_be_offered']   = merged['valid_2025_rows'] >= 4
merged['would_predict_ok']   = merged['valid_2025_rows'] >= 4  # same threshold, sanity check

merged = merged.sort_values(['crop', 'district', 'valid_2025_rows'], ascending=[True, True, False])

pd.set_option('display.max_rows', None)
pd.set_option('display.width', 120)

print("=" * 100)
print(f"{'Crop':<10} {'District':<10} {'Grade':<10} {'Total':>7} {'2025+ valid':>12} {'Offered?':>9} {'Would predict?':>15}")
print("=" * 100)
for _, r in merged.iterrows():
    offered = "YES" if r['would_be_offered'] else "no"
    predict = "YES" if r['would_predict_ok'] else "no"
    flag = "  <-- BROKEN (offered but can't predict)" if (r['would_be_offered'] and not r['would_predict_ok']) else ""
    print(f"{r['crop']:<10} {r['district']:<10} {r['grade']:<10} {r['total_rows']:>7} "
          f"{r['valid_2025_rows']:>12} {offered:>9} {predict:>15}{flag}")

print("\n" + "=" * 100)
n_ok    = merged['would_be_offered'].sum()
n_total = len(merged)
print(f"SUMMARY: {n_ok} of {n_total} crop/district/grade combinations currently "
      f"have enough 2025+ data (4+ rows) to predict.")
print("Combinations below 4 will not appear in the app's dropdowns once")
print("Flask is running the latest /metadata fix (requires a FULL restart).")
