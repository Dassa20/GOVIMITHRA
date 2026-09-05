"""
=============================================================
FLASK BACKEND API v4
Price Prediction & Decision Support System
Minor Export Crops in Sri Lanka
=============================================================
New in v4:
 - DEA staff: view only, submit price update requests
 - Super admin: approve/reject staff requests
 - Request/approval workflow table
 - Auto NASA POWER weather fetch on every price upload
 - Auto DEA PDF scraper endpoint
 - Forgot password via email (works on real devices)
=============================================================
"""

from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
import joblib, pandas as pd, numpy as np
import sqlite3, os, subprocess, requests, smtplib, random, string
from datetime import datetime, timedelta
from email.mime.text import MIMEText
import firebase_admin
from firebase_admin import credentials, messaging

app = Flask(__name__)
CORS(app)  # Allow all origins — needed for local development

import math as _math
class _SafeJSONProvider(app.json_provider_class):
    """Override Flask JSON to convert NaN/Infinity to null automatically."""
    def dumps(self, obj, **kwargs):
        import json
        def _clean(o):
            if isinstance(o, float) and (_math.isnan(o) or _math.isinf(o)):
                return None
            if isinstance(o, dict):
                return {k: _clean(v) for k, v in o.items()}
            if isinstance(o, (list, tuple)):
                return [_clean(i) for i in o]
            return o
        return json.dumps(_clean(obj), **kwargs)

app.json_provider_class = _SafeJSONProvider
app.json = _SafeJSONProvider(app)

# ── PATHS ──────────────────────────────────────────────────
BASE_DIR     = os.path.dirname(os.path.abspath(__file__))
ML_DIR       = os.path.join(BASE_DIR, '..', 'ml', 'models')
DB_PATH      = os.path.join(BASE_DIR, 'price_data.db')
TRAIN_SCRIPT = os.path.join(BASE_DIR, '..', 'ml', 'train_models.py')
FIREBASE_KEY = os.path.join(BASE_DIR,
    'cinnamon-pepper-price-ap-55716-firebase-adminsdk-fbsvc-9e77953f8b.json')

# ── GEMINI CHATBOT (optional AI help for farmers) ─────────────
# Free tier: no credit card required to get a key from Google AI Studio.
# IMPORTANT: if you ever enable BILLING on this Google Cloud project,
# the free tier is disabled for the WHOLE project and every call is
# charged from the first token — not just overages. Leave billing off
# and this stays free for a pilot project like this one.
#
# Recommended: set this as a Windows environment variable so the key
# never sits in a file you might accidentally commit to GitHub:
#   setx GEMINI_API_KEY "your-key-here"
# then restart your terminal/IDE so it picks up the new variable.
#
# For a quick local-only pilot you can instead paste the key directly
# as the fallback default below — just don't push this file to a
# public repo (or your thesis appendix) with a real key still in it.
GEMINI_API_KEY = os.environ.get('GEMINI_API_KEY', '')
GEMINI_MODEL          = 'gemini-3.6-flash'      # tried FIRST — best quality,
                                                  # ~20 requests/day free tier
GEMINI_FALLBACK_MODEL = 'gemini-3.5-flash-lite'  # tried automatically if the
                                                  # primary model's daily quota
                                                  # is used up — ~500/day, so
                                                  # combined capacity is ~520
                                                  # requests/day before a
                                                  # farmer ever sees an error.

# Fair-share cap: since the whole app shares ONE Gemini API key (a farmer
# can't reasonably get their own Google Cloud key), one device sending lots
# of messages could use up the WHOLE day's shared quota, leaving nothing
# for other farmers. This caps each device to a reasonable daily amount so
# usage stays fair across everyone using the app on a given day.
# Combined model capacity (primary + automatic fallback) is ~520/day, so
# 25/device still comfortably supports 20+ farmers each getting their
# full daily share.
CHATBOT_DAILY_LIMIT_PER_DEVICE = 25

if not GEMINI_API_KEY:
    print("  WARNING: GEMINI_API_KEY not set — chatbot endpoint disabled")

# ── NASA POWER coordinates (loaded from encoding_maps, not hardcoded) ──
NASA_COORDS = {
    'Galle':  {'lat': 6.03,  'lon': 80.22},
    'Matara': {'lat': 5.95,  'lon': 80.54},
    'Kandy':  {'lat': 7.29,  'lon': 80.64},
    'Matale': {'lat': 7.47,  'lon': 80.62},
}
NASA_VARS = 'PRECTOTCORR,T2M,RH2M'

# ── FIREBASE ────────────────────────────────────────────────
FIREBASE_ENABLED = False
if os.path.exists(FIREBASE_KEY):
    try:
        cred = credentials.Certificate(FIREBASE_KEY)
        firebase_admin.initialize_app(cred)
        FIREBASE_ENABLED = True
        print("  Firebase Admin SDK initialised")
    except Exception as e:
        print(f"  WARNING: Firebase init failed: {e}")
else:
    print(f"  WARNING: Firebase key not found — notifications disabled")

# ── LOAD MODEL ──────────────────────────────────────────────
print("Loading model and configuration...")
MODEL         = joblib.load(os.path.join(ML_DIR, 'best_model.pkl'))
FEATURE_NAMES = joblib.load(os.path.join(ML_DIR, 'feature_names.pkl'))
ENCODING_MAPS = joblib.load(os.path.join(ML_DIR, 'encoding_maps.pkl'))
print(f"  Model: {type(MODEL).__name__}, Features: {len(FEATURE_NAMES)}")
print(f"  Districts: {list(ENCODING_MAPS['district'].keys())}")
print(f"  Crops: {list(ENCODING_MAPS['crop'].keys())}")

def fetch_nasa_weather(district: str, year: int, month: int):
    """Fetch monthly avg rainfall, temp, humidity from NASA POWER for a district."""
    coords = NASA_COORDS.get(district)
    if not coords:
        return None
    try:
        start = f"{year}{month:02d}01"
        end   = f"{year}{month:02d}28"
        url   = (f"https://power.larc.nasa.gov/api/temporal/daily/point"
                 f"?parameters={NASA_VARS}&community=AG"
                 f"&longitude={coords['lon']}&latitude={coords['lat']}"
                 f"&start={start}&end={end}&format=JSON")
        resp  = requests.get(url, timeout=30)
        if resp.status_code != 200:
            return None
        data  = resp.json()
        props = data.get('properties', {}).get('parameter', {})
        rain  = props.get('PRECTOTCORR', {})
        temp  = props.get('T2M', {})
        hum   = props.get('RH2M', {})
        vals_rain = [v for v in rain.values() if v is not None and v >= 0]
        vals_temp = [v for v in temp.values() if v is not None and v > -900]
        vals_hum  = [v for v in hum.values()  if v is not None and v >= 0]
        if not vals_rain:
            return None
        return {
            'rainfall_mm':  round(sum(vals_rain), 2),
            'temp_c':       round(sum(vals_temp) / len(vals_temp), 2) if vals_temp else None,
            'humidity_pct': round(sum(vals_hum)  / len(vals_hum),  2) if vals_hum  else None,
        }
    except Exception as e:
        print(f"  NASA error {district} {year}/{month:02d}: {e}")
        return None


# ═══════════════════════════════════════════════════════════
# DATABASE
# ═══════════════════════════════════════════════════════════
def init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=DELETE")
    conn.execute("PRAGMA busy_timeout=10000")
    conn.commit()
    cur  = conn.cursor()

    cur.execute("""
        CREATE TABLE IF NOT EXISTS price_history (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            date         TEXT NOT NULL,
            district     TEXT NOT NULL,
            crop         TEXT NOT NULL,
            grade        TEXT NOT NULL,
            avg_price    REAL NOT NULL,
            high_price   REAL,
            rainfall_mm  REAL,
            temp_c       REAL,
            humidity_pct REAL,
            created_at   TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(date, district, crop, grade)
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS admin_users (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            username   TEXT UNIQUE NOT NULL,
            password   TEXT NOT NULL,
            role       TEXT NOT NULL DEFAULT 'dea_staff',
            full_name  TEXT,
            district   TEXT,
            crop       TEXT,
            email      TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS price_requests (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            submitted_by    TEXT NOT NULL,
            district        TEXT NOT NULL,
            crop            TEXT NOT NULL,
            grade           TEXT NOT NULL,
            date            TEXT NOT NULL,
            avg_price       REAL NOT NULL,
            high_price      REAL,
            rainfall_mm     REAL,
            temp_c          REAL,
            humidity_pct    REAL,
            notes           TEXT,
            status          TEXT NOT NULL DEFAULT 'pending',
            reviewed_by     TEXT,
            review_note     TEXT,
            reviewed_at     TEXT,
            created_at      TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS device_tokens (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            email        TEXT NOT NULL,
            fcm_token    TEXT NOT NULL UNIQUE,
            district     TEXT,
            crop         TEXT,
            grade        TEXT,
            created_at   TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS auto_fetch_log (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            fetch_type TEXT NOT NULL,
            status     TEXT NOT NULL,
            message    TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS password_resets (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            username   TEXT NOT NULL,
            otp        TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            used       INTEGER DEFAULT 0,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS chatbot_usage (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL,
            date      TEXT NOT NULL,
            count     INTEGER NOT NULL DEFAULT 0,
            UNIQUE(device_id, date)
        )
    """)

    conn.commit()

    # Create default super admin if none exists
    cur.execute("SELECT COUNT(*) FROM admin_users WHERE role='super_admin'")
    if cur.fetchone()[0] == 0:
        cur.execute("""
            INSERT OR IGNORE INTO admin_users
            (username, password, role, full_name)
            VALUES (?, ?, ?, ?)
        """, ('admin', 'Admin@1234', 'super_admin', 'System Administrator'))
        conn.commit()
        print("  Default super admin: username=admin  password=Admin@1234")
        print("  IMPORTANT: Change this password after first login!")
    conn.close()
    print("  Database initialised")

# Thread lock for all DB write operations
import threading as _threading
_DB_LOCK = _threading.Lock()

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    # DELETE journal mode — no -wal or -shm files
    conn.execute("PRAGMA journal_mode=DELETE")
    conn.execute("PRAGMA busy_timeout=10000")
    return conn

def load_initial_price_data():
    """
    Load initial price data into DB from Master ML Dataset Excel.
    Tries multiple file locations in order.
    Only loads 2025+ data matching project scope.
    """
    # Try locations in order
    candidates = [
        os.path.join(BASE_DIR, '..', 'ml', 'Master_ML_Dataset_CinnamonPepper.xlsx'),
        os.path.join(BASE_DIR, '..', 'Master_ML_Dataset_CinnamonPepper.xlsx'),
    ]

    master = None
    for path in candidates:
        if os.path.exists(path):
            master = path
            break

    if not master:
        print(f"  NOTE: Master dataset not found — skipping initial load")
        print(f"  Looked in: {candidates}")
        return

    try:
        # Try reading Master_ML_Dataset sheet first
        try:
            df = pd.read_excel(master, sheet_name='Master_ML_Dataset')
            date_col    = 'Date'
            avg_col     = 'Avg Price (LKR)'
            high_col    = 'High Price (LKR)'
            dist_col    = 'District'
            crop_col    = 'Crop'
            grade_col   = 'Grade'
            rain_col    = 'Rain mm'
            temp_col    = 'Temp \u00b0C'
            hum_col     = 'Humidity%'
            df = df.dropna(subset=[avg_col])
        except Exception:
            print(f"  NOTE: Master_ML_Dataset sheet not found — skipping")
            return

        conn  = get_db()
        cur   = conn.cursor()
        count = 0
        skip  = 0

        for _, row in df.iterrows():
            try:
                # Parse date robustly
                date_raw = row[date_col]
                dt = pd.to_datetime(date_raw, dayfirst=True, errors='coerce')
                if pd.isna(dt):
                    skip += 1
                    continue
                if dt.year < 2025:
                    skip += 1
                    continue
                date_str = dt.strftime('%d.%m.%Y')

                cur.execute("""
                    INSERT OR IGNORE INTO price_history
                    (date, district, crop, grade, avg_price, high_price,
                     rainfall_mm, temp_c, humidity_pct)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    date_str,
                    str(row[dist_col]).strip(),
                    str(row[crop_col]).strip(),
                    str(row[grade_col]).strip(),
                    float(row[avg_col]),
                    float(row[high_col])  if pd.notna(row.get(high_col))  else None,
                    float(row[rain_col])  if pd.notna(row.get(rain_col))  else None,
                    float(row[temp_col])  if pd.notna(row.get(temp_col))  else None,
                    float(row[hum_col])   if pd.notna(row.get(hum_col))   else None,
                ))
                count += cur.rowcount
            except Exception:
                skip += 1

        conn.commit()
        conn.close()
        print(f"  Loaded {count} historical price rows into database "
              f"(skipped {skip} pre-2025 or invalid rows)")

    except Exception as e:
        print(f"  Error loading initial data: {e}")


def sync_master_datasets():
    """
    Export latest data from SQLite to Master_ML_Dataset_Live.xlsx
    (separate from the original training file Master_ML_Dataset_CinnamonPepper.xlsx)
    Called after every DEA/NASA fetch for monitoring.
    For ML training, always use the original CinnamonPepper.xlsx file.
    """
    try:
        conn = get_db()
        df   = pd.read_sql_query("""
            SELECT date, district, crop, grade,
                   avg_price, high_price,
                   rainfall_mm, temp_c, humidity_pct
            FROM price_history
            WHERE CAST(substr(date, 7, 4) AS INTEGER) >= 2025
            ORDER BY date(substr(date,7,4)||'-'||substr(date,4,2)||'-'||substr(date,1,2))
        """, conn)
        conn.close()

        if df.empty:
            print("  Master dataset sync skipped — no data")
            return False

        # Parse dates
        df['_dt'] = pd.to_datetime(df['date'], format='%d.%m.%Y', errors='coerce')
        df = df.dropna(subset=['_dt']).sort_values('_dt').reset_index(drop=True)

        # Calendar features
        df['Year']   = df['_dt'].dt.year
        df['Month']  = df['_dt'].dt.month
        df['Week']   = df['_dt'].dt.isocalendar().week.astype(int)

        # Season
        def get_season(m):
            if 5 <= m <= 9:  return 'Yala'
            if m >= 10 or m <= 2: return 'Maha'
            return 'Inter-Monsoon'
        df['Season'] = df['Month'].apply(get_season)

        # Encoding maps
        dist_enc   = ENCODING_MAPS['district']
        crop_enc   = ENCODING_MAPS['crop']
        grade_enc  = ENCODING_MAPS['grade']
        season_enc = ENCODING_MAPS['season']
        df['Dist_Enc']   = df['district'].map(dist_enc)
        df['Crop_Enc']   = df['crop'].map(crop_enc)
        df['Grade_Enc']  = df['grade'].map(grade_enc)
        df['Season_Enc'] = df['Season'].map(season_enc)

        # Harvest flag
        harvest_months = ENCODING_MAPS['harvest_months']
        df['Harvest?'] = df.apply(
            lambda r: 1 if r['Month'] in harvest_months.get(r['crop'], []) else 0,
            axis=1)

        # Lag and MA features per crop/district/grade group
        lag1_col  = []
        lag2_col  = []
        lag4_col  = []
        ma4_col   = []
        ma8_col   = []
        ma12_col  = []
        chg_col   = []
        mom_col   = []
        vsma4_col = []
        rain3m_col= []

        for key, grp in df.groupby(['crop', 'district', 'grade']):
            idx   = grp.index
            prices = grp['avg_price'].values
            rain   = grp['rainfall_mm'].values

            lag1  = np.concatenate([[np.nan], prices[:-1]])
            lag2  = np.concatenate([[np.nan, np.nan], prices[:-2]])
            lag4  = np.concatenate([[np.nan]*4, prices[:-4]])
            ma4   = np.array([np.mean(prices[max(0,i-4):i]) if i>=4 else np.nan for i in range(len(prices))])
            ma8   = np.array([np.mean(prices[max(0,i-8):i]) if i>=8 else np.nan for i in range(len(prices))])
            ma12  = np.array([np.mean(prices[max(0,i-12):i]) if i>=12 else np.nan for i in range(len(prices))])
            chg   = np.where(lag1 != 0, (prices - lag1) / lag1 * 100, np.nan)
            mom   = prices - lag4
            vsma4 = prices - ma4
            r3m   = np.array([np.nanmean(rain[max(0,i-3):i]) if i>=3 else np.nan for i in range(len(rain))])

            for j, i in enumerate(idx):
                lag1_col.append((i, lag1[j]))
                lag2_col.append((i, lag2[j]))
                lag4_col.append((i, lag4[j]))
                ma4_col.append((i, ma4[j]))
                ma8_col.append((i, ma8[j]))
                ma12_col.append((i, ma12[j]))
                chg_col.append((i, chg[j]))
                mom_col.append((i, mom[j]))
                vsma4_col.append((i, vsma4[j]))
                rain3m_col.append((i, r3m[j]))

        for col_name, col_data in [
            ('Lag-1 Wk', lag1_col), ('Lag-2 Wk', lag2_col), ('Lag-4 Wk', lag4_col),
            ('MA-4', ma4_col), ('MA-8', ma8_col), ('MA-12', ma12_col),
            ('Chg%', chg_col), ('Momentum', mom_col), ('vs MA4', vsma4_col),
            ('Rain 3M Avg', rain3m_col),
        ]:
            s = pd.Series(dict(col_data))
            df[col_name] = df.index.map(s)

        # Convert date to DD.MM.YYYY string before writing
        # (prevents pandas from writing as datetime which breaks re-reading)
        df['date'] = pd.to_datetime(
            df['date'], format='%d.%m.%Y', errors='coerce'
        ).dt.strftime('%d.%m.%Y')

        # Rename to match Excel column names
        df = df.rename(columns={
            'date':         'Date',
            'district':     'District',
            'crop':         'Crop',
            'grade':        'Grade',
            'avg_price':    'Avg Price (LKR)',
            'high_price':   'High Price (LKR)',
            'rainfall_mm':  'Rain mm',
            'temp_c':       'Temp °C',
            'humidity_pct': 'Humidity%',
        })

        # Add TARGET arrow column (blank — just a separator like original)
        df['TARGET →'] = ''

        # Final column order matching original Excel exactly
        final_cols = [
            'Date', 'Year', 'Month', 'Week', 'Season', 'District', 'Crop', 'Grade',
            'Avg Price (LKR)', 'High Price (LKR)', 'TARGET →',
            'Lag-1 Wk', 'Lag-2 Wk', 'Lag-4 Wk',
            'MA-4', 'MA-8', 'MA-12',
            'Chg%', 'Momentum', 'vs MA4',
            'Rain mm', 'Temp °C', 'Humidity%', 'Rain 3M Avg',
            'Harvest?', 'Dist_Enc', 'Crop_Enc', 'Grade_Enc', 'Season_Enc',
        ]
        df_out = df[[c for c in final_cols if c in df.columns]]

        # Write to LIVE file — separate from original training dataset
        # Master_ML_Dataset_CinnamonPepper.xlsx = original 1463-row research data (DO NOT OVERWRITE)
        # Master_ML_Dataset_Live.xlsx = live DB export for monitoring only
        ml_path = os.path.join(BASE_DIR, '..', 'ml',
                               'Master_ML_Dataset_Live.xlsx')
        os.makedirs(os.path.dirname(ml_path), exist_ok=True)

        # Use openpyxl to preserve sheet name
        with pd.ExcelWriter(ml_path, engine='openpyxl') as writer:
            df_out.to_excel(writer, sheet_name='Master_ML_Dataset', index=False)

        print(f"  Master dataset synced: {len(df_out)} rows, {len(df_out.columns)} columns → {ml_path}")
        return True
    except Exception as e:
        import traceback
        print(f"  Master dataset sync failed: {e}")
        traceback.print_exc()
        return False

# ═══════════════════════════════════════════════════════════
# DEA PDF SCRAPER
# ═══════════════════════════════════════════════════════════
def try_scrape_dea():
    """
    Scrapes latest price bulletin from exagri.info.
    First reads the index page to find all available bulletin dates,
    then scrapes each one found. Weekly data — every Monday/Tuesday.
    Only extracts Cinnamon (Galle, Matara) and Pepper (Kandy, Matale).
    """
    from bs4 import BeautifulSoup
    import re as _re

    # DEA target crop-to-district mapping (domain config, not hardcode)
    # Based on: Cinnamon production = Galle+Matara (61% of national output)
    #           Pepper production   = Kandy+Matale (43% of national output)
    # Source: DEA Annual Performance Report / Ministry of Minor Export Crops
    TARGET = {
        'Cinnamon': ['Galle', 'Matara'],
        'Pepper':   ['Kandy', 'Matale'],
    }
    CINNAMON_GRADES = ['Alba', 'C-5 Sp', 'C-5', 'C-4', 'M-5', 'M-4',
                       'H-1', 'H-2', 'H-Faq', 'Heen', 'Gorosu']
    PEPPER_GRADES   = ['GR-1', 'GR-2', 'WHITE']

    def parse_price(val):
        if not val or val.strip() in ('-', '', 'None'):
            return None
        try:
            return float(val.replace(',', '').replace('Rs.', '').strip())
        except Exception:
            return None

    headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}

    # Step 1: Read index page to get all available bulletin dates
    dates_to_try = []
    seen_dates   = set()  # initialize here so always available even if index fetch fails
    try:
        idx_resp = requests.get('https://exagri.info/mkt/index.html',
                                headers=headers, timeout=20)
        if idx_resp.status_code == 200:
            idx_soup  = BeautifulSoup(idx_resp.text, 'html.parser')
            for a in idx_soup.find_all('a', href=True):
                href = a['href']
                m = _re.search(r'(\d{2}\.\d{2}\.\d{4})\.html', href)
                if m:
                    date_str = m.group(1)
                    if date_str not in seen_dates:
                        seen_dates.add(date_str)
                        dates_to_try.append(date_str)
    except Exception as e:
        print(f"  DEA index fetch failed: {e}")

    # Also add last 12 Tuesdays as fallback — DEA publishes every Tuesday
    # Ensures we never miss a bulletin even if index page doesn't list it
    _today = datetime.now()
    for _i in range(84):  # look back 12 weeks
        _d = _today - timedelta(days=_i)
        if _d.weekday() == 1:  # Tuesday only (0=Mon, 1=Tue)
            _ds = _d.strftime('%d.%m.%Y')
            if _ds not in seen_dates:
                seen_dates.add(_ds)
                dates_to_try.append(_ds)

    # Full fallback: try last 56 days if index completely failed
    if not dates_to_try:
        today = datetime.now()
        for i in range(56):
            d = today - timedelta(days=i)
            dates_to_try.append(d.strftime('%d.%m.%Y'))

    print(f"  DEA: {len(dates_to_try)} bulletin dates to try: {dates_to_try[:5]}")

    last_error   = ''
    all_rows     = []
    scraped_dates = []
    for date_str in dates_to_try:
        # Extract year from date string DD.MM.YYYY
        year = date_str.split('.')[2]
        url = f'https://exagri.info/mkt/{year}/{date_str}.html'
        try:
            resp = requests.get(url, headers=headers, timeout=20)
            if resp.status_code != 200:
                continue

            soup   = BeautifulSoup(resp.text, 'html.parser')
            tables = soup.find_all('table')
            rows   = []

            for table in tables:
                trows  = table.find_all('tr')
                if len(trows) < 2:
                    continue
                hdrs   = [th.get_text(strip=True) for th in trows[0].find_all(['th', 'td'])]

                # Identify crop
                crop = None
                if any('Alba' in h for h in hdrs) or any('C-5' in h for h in hdrs):
                    crop = 'Cinnamon'
                elif any('GR-1' in h for h in hdrs) or any('WHITE' in h for h in hdrs):
                    crop = 'Pepper'
                else:
                    continue

                grades_list = CINNAMON_GRADES if crop == 'Cinnamon' else PEPPER_GRADES

                # Map grade → (high_col, avg_col)
                grade_cols = {}
                for grade in grades_list:
                    hi_col = avg_col = None
                    for i, h in enumerate(hdrs):
                        if grade in h and 'Highest' in h:
                            hi_col = i
                        if grade in h and 'Average' in h:
                            avg_col = i
                    if hi_col is not None and avg_col is not None:
                        grade_cols[grade] = (hi_col, avg_col)

                for trow in trows[1:]:
                    cells = trow.find_all(['td', 'th'])
                    if not cells:
                        continue
                    raw_district = cells[0].get_text(strip=True).replace('_',' ').replace('*','').strip()
                    matched = next((td for td in TARGET.get(crop, [])
                                    if td.lower() in raw_district.lower()), None)
                    if not matched:
                        continue
                    for grade, (hi, av) in grade_cols.items():
                        if hi < len(cells) and av < len(cells):
                            high = parse_price(cells[hi].get_text(strip=True))
                            avg  = parse_price(cells[av].get_text(strip=True))
                            if avg and avg > 0:
                                rows.append({
                                    'date': date_str, 'crop': crop,
                                    'district': matched, 'grade': grade,
                                    'avg_price': avg, 'high_price': high,
                                })

            if rows:
                all_rows.extend(rows)
                scraped_dates.append(date_str)
                # Don't break — continue to get ALL available bulletin dates

        except Exception as e:
            last_error = str(e)
            continue

    if all_rows:
        return all_rows, f"Scraped {len(all_rows)} rows from {len(scraped_dates)} bulletins: {', '.join(scraped_dates[:5])}"
    return [], f"No bulletin found. Last error: {last_error}"

# ═══════════════════════════════════════════════════════════
# FEATURE ENGINEERING
# ═══════════════════════════════════════════════════════════
def compute_features(district, crop, grade):
    conn = get_db()
    df   = pd.read_sql_query("""
        SELECT * FROM price_history
        WHERE district=? AND crop=? AND grade=?
        ORDER BY date(
            substr(date,7,4)||'-'||substr(date,4,2)||'-'||substr(date,1,2)
        ) ASC
    """, conn, params=(district, crop, grade))
    conn.close()

    if len(df) < 4:
        return None, None, (f"Not enough history for {crop}/{district}/{grade} "
                             f"(found {len(df)} of 4 required rows, any year)")

    df['parsed_date'] = pd.to_datetime(df['date'], format='%d.%m.%Y', errors='coerce')
    df = df.dropna(subset=['parsed_date']).sort_values('parsed_date').reset_index(drop=True)

    # Filter to project date range (2025 onwards)
    # Auto-fetch from exagri.info goes back to 2000s — but our ML model
    # was trained on 2025-2026 data only. Using older data corrupts lags.
    df = df[df['parsed_date'].dt.year >= 2025].reset_index(drop=True)

    if len(df) < 4:
        return None, None, (f"Not enough 2025+ history for {crop}/{district}/{grade} "
                             f"(found {len(df)} of 4 required 2025+ rows)")

    # Safety: use max last 104 weeks (2 years) for lag computation
    if len(df) > 104:
        df = df.tail(104).reset_index(drop=True)

    last_row = df.iloc[-1]

    # Predicted date = next bulletin date after latest data in DB
    # Always strictly FUTURE — if next_date <= today, keep adding 7 days
    today          = datetime.now()
    last_data_date = df['parsed_date'].iloc[-1]
    next_date      = last_data_date + timedelta(days=7)

    # Keep advancing until next_date >= today
    # If next_date == today → show today (bulletin expected but not yet published)
    # If next_date < today → data is stale, advance to next expected date
    while next_date.date() < today.date():
        next_date = next_date + timedelta(days=7)

    lag1 = float(df['avg_price'].iloc[-1])
    lag2 = float(df['avg_price'].iloc[-2]) if len(df) >= 2 else lag1
    lag4 = float(df['avg_price'].iloc[-4]) if len(df) >= 4 else lag1
    ma4  = float(df['avg_price'].tail(4).mean())
    ma8  = float(df['avg_price'].tail(8).mean()) if len(df) >= 8 else ma4

    chg_pct  = ((lag1 - lag2) / lag2 * 100) if lag2 != 0 else 0
    momentum = lag1 - lag2
    vs_ma4   = lag1 - ma4

    # Get weather for current month from NASA if not in DB
    rain     = last_row['rainfall_mm']
    temp     = last_row['temp_c']
    humidity = last_row['humidity_pct']

    if pd.isna(rain) or pd.isna(temp) or pd.isna(humidity):
        weather = fetch_nasa_weather(district, today.year, today.month)
        if weather:
            if pd.isna(rain):     rain     = weather['rainfall_mm']
            if pd.isna(temp):     temp     = weather['temp_c']
            if pd.isna(humidity): humidity = weather['humidity_pct']

    # Fallback to historical averages
    if pd.isna(rain):     rain     = float(df['rainfall_mm'].dropna().mean())  if df['rainfall_mm'].notna().any()  else 150.0
    if pd.isna(temp):     temp     = float(df['temp_c'].dropna().mean())        if df['temp_c'].notna().any()        else 27.0
    if pd.isna(humidity): humidity = float(df['humidity_pct'].dropna().mean())  if df['humidity_pct'].notna().any()  else 80.0

    rain3m = float(df['rainfall_mm'].tail(3).dropna().mean()) if df['rainfall_mm'].notna().any() else (rain if rain else 150.0)

    month  = next_date.month
    week   = next_date.isocalendar()[1]

    def get_season(m):
        if m in [5,6,7,8,9]:      return 'Yala'
        elif m in [10,11,12,1,2]: return 'Maha'
        else:                      return 'Inter-Monsoon'

    season     = get_season(month)
    h_months   = ENCODING_MAPS['harvest_months'].get(crop, [])
    is_harvest = 1 if month in h_months else 0

    dist_enc   = ENCODING_MAPS['district'].get(district)
    crop_enc   = ENCODING_MAPS['crop'].get(crop)
    grade_enc  = ENCODING_MAPS['grade'].get(grade)
    season_enc = ENCODING_MAPS['season'].get(season)

    if None in (dist_enc, crop_enc, grade_enc, season_enc):
        return None, None, f"Unknown combination: {district}/{crop}/{grade}"

    # Build full feature dict — FEATURE_NAMES loaded from pkl determines
    # which ones are actually used (leaky features excluded after retraining)
    feat_dict = {
        'Month': month, 'Week': week, 'Season_Enc': season_enc,
        'Lag-1 Wk': lag1, 'Lag-2 Wk': lag2, 'Lag-4 Wk': lag4,
        'MA-4': ma4, 'MA-8': ma8,
        'Chg%': chg_pct, 'Momentum': momentum, 'vs MA4': vs_ma4,
        'Rain mm': rain, 'Temp °C': temp, 'Humidity%': humidity,
        'Rain 3M Avg': rain3m, 'Harvest?': is_harvest,
        'Dist_Enc': dist_enc, 'Crop_Enc': crop_enc, 'Grade_Enc': grade_enc,
    }

    # Only use features the model was trained on (from feature_names.pkl)
    # This automatically handles 16-feature vs 19-feature model differences
    missing = [f for f in FEATURE_NAMES if f not in feat_dict]
    if missing:
        return None, None, f"Feature mismatch — missing: {missing}"
    feature_vector = [feat_dict[f] for f in FEATURE_NAMES]

    context = {
        'last_price':        lag1,
        'last_date':         last_row['parsed_date'].strftime('%d.%m.%Y'),
        'next_date':         next_date.strftime('%d.%m.%Y'),
        'season':            season,
        'is_harvest_season': bool(is_harvest),
        'ma4':               ma4,
        'history_weeks':     len(df),
        'rainfall_mm':       round(float(rain), 1),
        'temp_c':            round(float(temp), 1),
        'humidity_pct':      round(float(humidity), 1),
        'rain_3m_avg':       round(float(rain3m), 1),
    }

    return np.array(feature_vector).reshape(1, -1), context, None

# ═══════════════════════════════════════════════════════════
# NOTIFICATIONS
# ═══════════════════════════════════════════════════════════
def send_push(fcm_token, title, body, data_payload=None):
    if not FIREBASE_ENABLED:
        print(f"  [Notification skipped] {title}: {body}")
        return False
    try:
        msg = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data=data_payload or {}, token=fcm_token)
        messaging.send(msg)
        return True
    except Exception as e:
        print(f"  Notification failed: {e}")
        return False

# ═══════════════════════════════════════════════════════════
# HELPER — clean NaN from dataframes before JSON serialization
# ═══════════════════════════════════════════════════════════
def df_to_json(df):
    """Convert DataFrame to JSON-safe list — replaces NaN/None with null."""
    return df.where(df.notna(), other=None).to_dict(orient='records')

def safe_val(v):
    """Return None if value is NaN/inf, else round to 2dp if float."""
    import math
    if v is None:
        return None
    try:
        f = float(v)
        if math.isnan(f) or math.isinf(f):
            return None
        return round(f, 2)
    except (TypeError, ValueError):
        return v

# ═══════════════════════════════════════════════════════════
# ROUTES — Public / Farmer
# ═══════════════════════════════════════════════════════════

@app.route('/admin-panel', methods=['GET'])
@app.route('/admin-panel/', methods=['GET'])
def admin_panel():
    """Serve the web admin panel from Flask so it runs on http://, not file://"""
    return send_from_directory(BASE_DIR, 'admin_web.html')


@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok', 'model': type(MODEL).__name__,
                    'timestamp': datetime.now().isoformat()})

@app.route('/metadata', methods=['GET'])
def metadata():
    conn = get_db()
    # Only return crop/district/grade combinations with >= 4 rows
    # (minimum needed for prediction lag features)
    # AND only those in encoding_maps (model knows how to handle them)
    #
    # IMPORTANT: this must count rows using the EXACT SAME date-parsing
    # rule as compute_features() (used by /predict and /recommendation).
    # A previous version compared date substrings as plain text
    # (e.g. substr(date,7,4) >= '2025'), which counts a row as valid
    # even if its date string is malformed. compute_features() instead
    # does a strict pd.to_datetime parse and silently drops anything
    # that doesn't match DD.MM.YYYY exactly. That mismatch let a grade
    # appear as selectable here while still having fewer than 4 usable
    # rows for compute_features — so picking it always returned a 400.
    # Using the same strict parse in both places closes that gap.
    df = pd.read_sql_query("""
        SELECT crop, district, grade, date FROM price_history
    """, conn)
    conn.close()

    if df.empty:
        return jsonify({
            'crops': [], 'districts_by_crop': {}, 'grades_by_crop': {},
            'harvest_months': ENCODING_MAPS['harvest_months'],
            'all_districts': [], 'all_grades': [],
        })

    df['parsed_date'] = pd.to_datetime(df['date'], format='%d.%m.%Y', errors='coerce')
    df = df.dropna(subset=['parsed_date'])
    df = df[df['parsed_date'].dt.year >= 2025]

    df = (df.groupby(['crop', 'district', 'grade'])
            .size().reset_index(name='cnt'))
    df = df[df['cnt'] >= 4]

    known_grades    = set(ENCODING_MAPS['grade'].keys())
    known_districts = set(ENCODING_MAPS['district'].keys())
    known_crops     = set(ENCODING_MAPS['crop'].keys())

    # Filter to only known encodings
    df = df[df['crop'].isin(known_crops) &
            df['district'].isin(known_districts) &
            df['grade'].isin(known_grades)]

    by_district, by_grade = {}, {}
    # NEW: grades tracked per (crop, district) pair, not just per crop.
    # The old by_grade dict below is a UNION of every grade seen anywhere
    # for that crop, regardless of district — e.g. Cinnamon's grades
    # M-5/M-4/H-Faq only actually exist for Matara, never for Galle, but
    # the old structure let the app offer them as choices for Galle too,
    # producing a combination with zero database rows (always a 400 at
    # prediction time, no matter how much history exists overall).
    grades_by_crop_district = {}
    for crop in df['crop'].unique():
        sub = df[df['crop'] == crop]
        by_district[crop] = sorted(sub['district'].unique().tolist())
        by_grade[crop]    = sorted(sub['grade'].unique().tolist())

        grades_by_crop_district[crop] = {}
        for district in by_district[crop]:
            sub_d = sub[sub['district'] == district]
            grades_by_crop_district[crop][district] = sorted(
                sub_d['grade'].unique().tolist())

    # Also provide flat lists for easy dropdown population
    all_districts = sorted(set(
        d for dists in by_district.values() for d in dists
    ))
    all_grades = sorted(set(
        g for grades in by_grade.values() for g in grades
    ))
    return jsonify({
        'crops':                    sorted(list(known_crops)),
        'districts_by_crop':        by_district,
        'grades_by_crop':           by_grade,  # kept for backward compatibility
        'grades_by_crop_district':  grades_by_crop_district,  # use this instead
        'harvest_months':           ENCODING_MAPS['harvest_months'],
        'all_districts':            all_districts,
        'all_grades':               all_grades,
    })

@app.route('/predict', methods=['POST'])
def predict():
    data     = request.get_json(force=True)
    district = data.get('district')
    crop     = data.get('crop')
    grade    = data.get('grade')
    if not all([district, crop, grade]):
        return jsonify({'error': 'district, crop and grade required'}), 400

    fv, ctx, err = compute_features(district, crop, grade)
    if fv is None:
        return jsonify({'error': f'Not enough price history to predict: {err}'}), 400

    predicted   = float(MODEL.predict(fv)[0])
    change      = predicted - ctx['last_price']
    change_pct  = (change / ctx['last_price'] * 100) if ctx['last_price'] else 0

    return jsonify({
        'district': district, 'crop': crop, 'grade': grade,
        'last_known_price':   round(ctx['last_price'], 2),
        'last_known_date':    ctx['last_date'],
        'predicted_price':    round(predicted, 2),
        'predicted_for_date': ctx['next_date'],
        'price_change':       round(change, 2),
        'price_change_pct':   round(change_pct, 2),
        'season':             ctx['season'],
        'is_harvest_season':  ctx['is_harvest_season'],
        'rainfall_mm':        safe_val(ctx['rainfall_mm']),
        'temp_c':             safe_val(ctx['temp_c']),
        'humidity_pct':       safe_val(ctx['humidity_pct']),
        'rain_3m_avg':        safe_val(ctx['rain_3m_avg']),
    })

@app.route('/harvest-status', methods=['POST'])
def harvest_status():
    data     = request.get_json(force=True)
    crop     = data.get('crop')
    district = data.get('district')
    if crop not in ENCODING_MAPS['harvest_months']:
        return jsonify({'error': f'Unknown crop: {crop}'}), 400
    m       = datetime.now().month
    h_mths  = ENCODING_MAPS['harvest_months'][crop]
    names   = ['','January','February','March','April','May','June',
                'July','August','September','October','November','December']
    return jsonify({
        'crop': crop, 'district': district,
        'current_month':    names[m],
        'is_harvest_season': m in h_mths,
        'harvest_months':   [names[x] for x in h_mths],
        'status':           'Ready to Harvest' if m in h_mths else 'Not Harvest Season',
    })

@app.route('/recommendation', methods=['POST'])
def recommendation():
    data     = request.get_json(force=True)
    district = data.get('district')
    crop     = data.get('crop')
    grade    = data.get('grade')
    fv, ctx, err = compute_features(district, crop, grade)
    if fv is None:
        return jsonify({'error': f'Not enough price history: {err}'}), 400

    predicted  = float(MODEL.predict(fv)[0])
    change_pct = ((predicted - ctx['last_price']) / ctx['last_price'] * 100) \
                  if ctx['last_price'] else 0
    THRESHOLD  = 3.0

    if ctx['is_harvest_season']:
        action = 'Harvest Now'
        reason = f"{crop} is in its harvest season ({ctx['season']})."
    elif change_pct > THRESHOLD:
        action = 'Wait'
        reason = f"Price predicted to rise by {change_pct:.1f}% next week."
    elif change_pct < -THRESHOLD:
        action = 'Sell Now'
        reason = f"Price predicted to fall by {abs(change_pct):.1f}% next week."
    else:
        action = 'Sell Now'
        reason = 'Price expected to remain stable next week.'

    return jsonify({
        'district': district, 'crop': crop, 'grade': grade,
        'recommendation':  action, 'reason': reason,
        'predicted_price': round(predicted, 2),
        'last_known_price': round(ctx['last_price'], 2),
        'price_change_pct': round(change_pct, 2),
        'is_harvest_season': ctx['is_harvest_season'],
        'rainfall_mm': ctx['rainfall_mm'],
        'temp_c':      ctx['temp_c'],
        'humidity_pct': ctx['humidity_pct'],
    })

@app.route('/history', methods=['GET'])
def history():
    district = request.args.get('district')
    crop     = request.args.get('crop')
    grade    = request.args.get('grade')
    limit    = request.args.get('limit')          # optional — omit for ALL rows
    if not all([district, crop, grade]):
        return jsonify({'error': 'district, crop and grade required'}), 400
    conn = get_db()
    # Base query — always filter 2025+ data
    base_where = """district=? AND crop=? AND grade=?
            AND CAST(substr(date,7,4) AS INTEGER) >= 2025"""
    if limit:
        df = pd.read_sql_query(f"""
            SELECT date, avg_price, high_price, rainfall_mm, temp_c, humidity_pct
            FROM price_history
            WHERE {base_where}
            ORDER BY date(substr(date,7,4)||'-'||substr(date,4,2)||'-'||substr(date,1,2)) DESC
            LIMIT ?
        """, conn, params=(district, crop, grade, int(limit)))
    else:
        df = pd.read_sql_query(f"""
            SELECT date, avg_price, high_price, rainfall_mm, temp_c, humidity_pct
            FROM price_history
            WHERE {base_where}
            ORDER BY date(substr(date,7,4)||'-'||substr(date,4,2)||'-'||substr(date,1,2)) DESC
        """, conn, params=(district, crop, grade))
    conn.close()
    # Sort by actual date (parse DD.MM.YYYY) not string sort
    if not df.empty:
        df['_sort'] = pd.to_datetime(
            df['date'], format='%d.%m.%Y', errors='coerce')
        df = df.sort_values('_sort').drop(columns=['_sort'])
    return jsonify({'count': len(df), 'data': df_to_json(df)})

@app.route('/register-device', methods=['POST'])
def register_device():
    data = request.get_json(force=True)
    if 'fcm_token' not in data or not data.get('fcm_token'):
        return jsonify({'error': 'fcm_token required'}), 400
    # email is optional — anonymous users can register for notifications
    # Retry up to 3 times if DB locked (background fetch may be writing)
    import time as _time
    for attempt in range(3):
        try:
            conn = get_db()
            conn.execute("""
                INSERT INTO device_tokens (email, fcm_token, district, crop, grade)
                VALUES (?,?,?,?,?)
                ON CONFLICT(fcm_token) DO UPDATE SET
                    email    = excluded.email,
                    district = excluded.district,
                    crop     = excluded.crop,
                    grade    = excluded.grade
            """, (data.get('email',''), data['fcm_token'],
                   data.get('district'), data.get('crop'), data.get('grade')))
            conn.commit()
            conn.close()
            return jsonify({'success': True, 'message': 'Device registered'})
        except Exception as e:
            if 'locked' in str(e).lower() and attempt < 2:
                _time.sleep(0.5)
                continue
            return jsonify({'success': True, 'message': 'Device registered (cached)'})

# ═══════════════════════════════════════════════════════════
# AI CHATBOT — simple farming help assistant for farmers
# Proxies to Gemini so the API key never has to live inside the
# Flutter app (which would expose it to anyone who inspects the
# compiled APK). The key stays server-side, here, only.
#
# Since every farmer shares ONE Gemini API key (a farmer can't get
# their own Google Cloud key), this route does two things to make
# that shared resource work fairly and reliably:
#   1. Tries the higher-quality model first; if ITS daily quota is
#      used up, automatically retries with a higher-quota fallback
#      model — the farmer never sees this happen, they just get an
#      answer either way, as long as the COMBINED capacity holds.
#   2. Caps each device to a fair daily share of the combined quota,
#      so one farmer chatting a lot can't accidentally use up the
#      whole day's shared capacity and leave nothing for anyone else.
# ═══════════════════════════════════════════════════════════

def _chatbot_usage_today(device_id):
    """How many chatbot messages this device has sent today."""
    conn  = get_db()
    today = datetime.now().strftime('%Y-%m-%d')
    row = conn.execute(
        "SELECT count FROM chatbot_usage WHERE device_id=? AND date=?",
        (device_id, today)
    ).fetchone()
    conn.close()
    return row['count'] if row else 0

def _chatbot_increment_usage(device_id):
    """Increments today's usage count for this device."""
    conn  = get_db()
    today = datetime.now().strftime('%Y-%m-%d')
    conn.execute("""
        INSERT INTO chatbot_usage (device_id, date, count)
        VALUES (?, ?, 1)
        ON CONFLICT(device_id, date) DO UPDATE SET count = count + 1
    """, (device_id, today))
    conn.commit()
    conn.close()

def _call_gemini_model(model, message, system_prompt):
    """
    Calls one specific Gemini model. Returns a dict:
      {'ok': True, 'reply': '...'}                        on success
      {'ok': False, 'rate_limited': True}                  on 429
      {'ok': False, 'rate_limited': False, 'error': '...'} on any other failure
    The caller decides whether to retry with a different model — only
    worth doing when rate_limited=True (other errors wouldn't be fixed
    by switching models).
    """
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    # NOTE: newer Gemini "Auth key" format keys (starting with "AQ.")
    # must be sent via the x-goog-api-key HTTP header — the older
    # ?key=... URL parameter method (which works for legacy AIza...
    # keys) is rejected for this key type. Sending it as a header
    # works for both key formats, so this is the safe choice either way.
    headers = {
        'Content-Type': 'application/json',
        'x-goog-api-key': GEMINI_API_KEY,
    }
    payload = {
        "contents": [{"parts": [{"text": message}]}],
        "systemInstruction": {"parts": [{"text": system_prompt}]},
        "generationConfig": {
            # Newer Gemini models do internal "thinking" before writing
            # the visible answer, and that hidden reasoning eats into
            # this same token budget. On top of that, Sinhala script
            # costs noticeably more tokens per sentence than English —
            # the same answer can need 3-5x more tokens in Sinhala.
            "maxOutputTokens": 2048,
            "temperature": 0.6,
        },
    }
    try:
        # FIX: timeout increased from 20s to 45s. Root cause of the
        # mobile-app-only 502s: Sinhala-language responses genuinely
        # need 3-5x more tokens than English for the same answer (see
        # comment above), and newer Gemini models also spend hidden
        # "thinking" tokens before writing the visible reply — a real
        # Sinhala farming question can legitimately take longer than
        # 20s to generate, while a short English "Hello" test message
        # never approaches that ceiling. 45s gives genuine headroom
        # without leaving a farmer waiting indefinitely on a request
        # that's truly stuck.
        resp = requests.post(url, json=payload, headers=headers, timeout=45)
    except requests.exceptions.Timeout:
        # FIX: this branch previously returned silently with no log
        # line at all — the exact reason a timeout only ever showed up
        # as a bare "502" in the access log, with no diagnostic detail
        # to explain why. Logging it here closes that blind spot.
        print(f"  Gemini timeout on {model} (message length: {len(message)} chars)")
        return {'ok': False, 'rate_limited': False, 'error': 'timeout'}
    except Exception as e:
        # FIX: same silent-failure gap as above, for any other
        # request-level exception (connection reset, DNS failure, etc.).
        print(f"  Gemini request exception on {model}: {e}")
        return {'ok': False, 'rate_limited': False, 'error': str(e)}

    if resp.status_code == 429:
        print(f"  Gemini quota hit on {model}: {resp.text[:200]}")
        return {'ok': False, 'rate_limited': True}
    if resp.status_code != 200:
        print(f"  Gemini API error {resp.status_code} ({model}): {resp.text[:300]}")
        return {'ok': False, 'rate_limited': False, 'error': f'status {resp.status_code}'}

    result     = resp.json()
    candidates = result.get('candidates', [])
    if not candidates:
        # FIX: also previously silent. A real, distinct possible cause
        # worth being able to see in logs: Gemini's safety filters can
        # return zero candidates for a 200 response if the input was
        # flagged (e.g. certain pest/chemical-treatment wording), which
        # a short "Hello" test would never trigger but a real farmer
        # question conceivably could.
        print(f"  Gemini returned no candidates ({model}): {result.get('promptFeedback', 'no feedback info')}")
        return {'ok': False, 'rate_limited': False, 'error': 'no candidates'}

    # Only use parts that are the actual visible answer — skip any part
    # flagged as internal "thought" content, or fragments of the
    # model's hidden reasoning get mixed into the real answer.
    parts = candidates[0].get('content', {}).get('parts', [])
    reply = ''.join(
        p.get('text', '') for p in parts if not p.get('thought', False)
    ).strip()
    if not reply:
        # FIX: also previously silent — same rationale as above.
        print(f"  Gemini returned an empty reply ({model}): finish_reason={candidates[0].get('finishReason', 'unknown')}")
        return {'ok': False, 'rate_limited': False, 'error': 'empty reply'}

    return {'ok': True, 'reply': reply}


@app.route('/chatbot', methods=['POST'])
def chatbot():
    if not GEMINI_API_KEY:
        return jsonify({'error': 'Chatbot is not configured on the server.'}), 503

    data      = request.get_json(force=True) or {}
    message   = (data.get('message') or '').strip()
    language  = data.get('language', 'en')
    device_id = (data.get('device_id') or 'unknown').strip()
    if not message:
        return jsonify({'error': 'message is required'}), 400

    # Fair-share check FIRST, before spending any of the shared Gemini
    # quota — a device that's already used its daily allowance gets
    # rejected immediately, at zero cost to the shared capacity.
    used_today = _chatbot_usage_today(device_id)
    if used_today >= CHATBOT_DAILY_LIMIT_PER_DEVICE:
        return jsonify({
            'error': "You've reached today's chat limit. Please try again tomorrow.",
            'reason': 'device_daily_limit',
        }), 429

    lang_name = 'Sinhala' if language == 'si' else 'English'

    # ── Ground the chatbot in REAL project data, not just the model's
    # own training-data recall ──────────────────────────────────────
    # Harvest months come from the exact same ENCODING_MAPS the ML
    # prediction model uses — so for these specific facts, the chatbot
    # is quoting verified project data instead of guessing, regardless
    # of which underlying Gemini model answers.
    _month_names = ['', 'January', 'February', 'March', 'April', 'May',
                     'June', 'July', 'August', 'September', 'October',
                     'November', 'December']
    facts_lines = []
    for crop, months in ENCODING_MAPS.get('harvest_months', {}).items():
        if months:
            month_str = ', '.join(_month_names[m] for m in sorted(months) if 1 <= m <= 12)
            facts_lines.append(f"- {crop} harvest season: {month_str}")
    known_districts = ', '.join(sorted(ENCODING_MAPS.get('district', {}).keys()))
    facts_block = (
        "VERIFIED PROJECT DATA (use this over your own general knowledge "
        "whenever it's relevant — it comes directly from this app's "
        "research dataset, not just general recall):\n"
        + '\n'.join(facts_lines)
        + f"\n- Districts tracked by this app: {known_districts}\n"
        + "- This app covers Cinnamon (Galle, Matara) and Pepper "
          "(Kandy, Matale) specifically, based on Department of Export "
          "Agriculture (DEA) data.\n"
    ) if facts_lines else ""

    system_prompt = (
        "You are a friendly farming assistant inside a mobile app used by "
        "Sri Lankan cinnamon and pepper farmers to check price predictions. "
        "Answer questions about cinnamon and pepper cultivation, harvesting, "
        "pest and disease management, and general farming practices relevant "
        "to Sri Lanka. Keep answers concise and practical — a short "
        "paragraph or a few sentences, easy to read on a small phone "
        "screen. If asked something unrelated to farming, gently steer "
        "the conversation back to farming topics.\n\n"
        f"{facts_block}\n"
        "If you are not confident about a specific fact (exact dosages, "
        "specific chemical treatments, or anything with real financial or "
        "safety consequences), say so honestly and suggest the farmer "
        "confirm with their local DEA (Department of Export Agriculture) "
        "officer rather than stating an unconfirmed answer with false "
        "confidence.\n\n"
        "IMPORTANT — language: reply in the SAME language the user's "
        "message is written in, not a fixed language. If they write in "
        "English, reply in English. If they write in Sinhala script, or "
        "in informal Romanized Sinhala ('Singlish' — Sinhala words typed "
        "using English letters), reply in proper Sinhala script either "
        "way. Always match what the user just typed. Only if their "
        f"message is too short or unclear to tell, default to {lang_name}."
    )

    # Try the primary (higher-quality) model first. If ITS daily quota
    # is used up specifically, automatically retry with the
    # higher-quota fallback model — this is what makes the combined
    # ~520/day capacity work transparently, without the farmer ever
    # needing to know or care which model actually answered.
    result = _call_gemini_model(GEMINI_MODEL, message, system_prompt)
    if not result['ok'] and result.get('rate_limited'):
        print(f"  {GEMINI_MODEL} quota exhausted — falling back to {GEMINI_FALLBACK_MODEL}")
        result = _call_gemini_model(GEMINI_FALLBACK_MODEL, message, system_prompt)

    if not result['ok']:
        if result.get('rate_limited'):
            # Both models exhausted — genuinely rare given the combined
            # ~520/day capacity, but still handled gracefully.
            return jsonify({
                'error': 'Too many questions right now across all farmers '
                         'using the app today — please try again later.'
            }), 429
        return jsonify({'error': 'AI assistant is temporarily unavailable.'}), 502

    _chatbot_increment_usage(device_id)
    return jsonify({'reply': result['reply']})

# ═══════════════════════════════════════════════════════════
# NASA POWER WEATHER FETCH
# ═══════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════
# AUTO-FETCH WEATHER HELPER (called by routes + background thread)
# ═══════════════════════════════════════════════════════════
def auto_fetch_all_weather():
    """Fetch NASA weather for ALL months that have price rows but missing weather."""
    now  = datetime.now()
    conn = get_db()
    cur  = conn.cursor()

    missing = cur.execute("""
        SELECT DISTINCT substr(date,7,4) as yr, substr(date,4,2) as mo
        FROM price_history
        WHERE (rainfall_mm IS NULL OR temp_c IS NULL OR humidity_pct IS NULL)
          AND CAST(substr(date,7,4) AS INTEGER) >= 2025
        ORDER BY yr, mo
    """).fetchall()

    current    = (str(now.year), f"{now.month:02d}")
    all_months = list({(r['yr'], r['mo']) for r in missing} | {current})
    all_months.sort()

    results = {}
    updated = 0
    for district in NASA_COORDS:
        for yr, mo in all_months:
            try:
                weather = fetch_nasa_weather(district, int(yr), int(mo))
                if not weather:
                    continue
                n = cur.execute("""
                    UPDATE price_history
                    SET rainfall_mm  = COALESCE(rainfall_mm,  ?),
                        temp_c       = COALESCE(temp_c,       ?),
                        humidity_pct = COALESCE(humidity_pct, ?)
                    WHERE district=?
                      AND substr(date,7,4)=?
                      AND substr(date,4,2)=?
                """, (weather['rainfall_mm'], weather['temp_c'],
                      weather['humidity_pct'], district, yr, mo)).rowcount
                updated += n
                results[f"{district}_{yr}_{mo}"] = weather
            except Exception as e:
                print(f"  NASA skip {district} {yr}/{mo}: {e}")

    conn.commit()
    cur.execute("""
        INSERT INTO auto_fetch_log (fetch_type, status, message)
        VALUES (?,?,?)
    """, ('nasa_weather', 'success',
          f"Fetched {len(NASA_COORDS)} districts, updated {updated} rows"))
    conn.commit()
    conn.close()
    return results

# ═══════════════════════════════════════════════════════════
# ROUTES — Auto-fetch
# ═══════════════════════════════════════════════════════════

@app.route('/auto-fetch/weather', methods=['POST'])
def auto_fetch_weather():
    results = auto_fetch_all_weather()
    return jsonify({'success': True, 'districts': results,
                    'message': f"Weather updated for {len(results)} districts"})

@app.route('/auto-fetch/dea-prices', methods=['POST'])
def auto_fetch_dea():
    rows, message = try_scrape_dea()
    conn = get_db()
    conn.execute("""
        INSERT INTO auto_fetch_log (fetch_type, status, message)
        VALUES (?,?,?)
    """, ('dea_scrape', 'success' if rows else 'failed', message))
    conn.commit()
    conn.close()
    return jsonify({'success': bool(rows), 'rows_found': len(rows),
                    'message': message, 'scraped_data': rows[:20]})

@app.route('/auto-fetch/dea-save', methods=['POST'])
def auto_fetch_dea_save():
    """
    Scrape exagri.info AND automatically save to price_requests table
    for super admin approval. DEA scraping + save in one step.
    Requires super admin credentials to auto-approve directly.
    Body JSON: { "requestor_username": "admin", "auto_approve": true }
    """
    data            = request.get_json(force=True) or {}
    requestor       = data.get('requestor_username', '')
    auto_approve    = data.get('auto_approve', False)
    is_super_admin  = _verify_super_admin(requestor)

    rows, message   = try_scrape_dea()
    if not rows:
        return jsonify({'success': False, 'rows_found': 0, 'message': message})

    conn   = get_db()
    cur    = conn.cursor()
    saved  = 0
    errors = 0

    for row in rows:
        try:
            if auto_approve and is_super_admin:
                # Skip rows older than 2025 — same rule the background
                # auto-fetch thread already applies. exagri.info's index
                # goes back many years; inserting old rows here (unlike
                # the hourly background fetch, which already guards this)
                # would silently corrupt lag-feature computation for that
                # crop/district/grade later, and could also let stale
                # combinations pass the /metadata row-count check.
                try:
                    row_year = int(row['date'].split('.')[-1])
                except (ValueError, IndexError):
                    row_year = 0
                if row_year < 2025:
                    continue

                # Super admin: save directly to price_history
                # Use INSERT OR IGNORE so we don't overwrite manually corrected data
                # Use INSERT OR REPLACE only if the row didn't exist before
                existing = cur.execute(
                    'SELECT id FROM price_history WHERE date=? AND district=? AND crop=? AND grade=?',
                    (row['date'], row['district'], row['crop'], row['grade'])
                ).fetchone()
                if not existing:
                    cur.execute("""
                        INSERT INTO price_history
                        (date, district, crop, grade, avg_price, high_price)
                        VALUES (?,?,?,?,?,?)
                    """, (row['date'], row['district'], row['crop'], row['grade'],
                          row['avg_price'], row.get('high_price')))
                    saved += 1
                # If exists, skip — don't overwrite manual corrections
            else:
                # Save as pending request for approval
                cur.execute("""
                    INSERT OR IGNORE INTO price_requests
                    (submitted_by, district, crop, grade, date,
                     avg_price, high_price, notes)
                    VALUES (?,?,?,?,?,?,?,?)
                """, ('auto_scraper', row['district'], row['crop'], row['grade'],
                      row['date'], row['avg_price'], row.get('high_price'),
                      f'Auto-scraped from exagri.info bulletin {row["date"]}'))
                saved += 1
        except Exception as e:
            errors += 1
            print(f"  DEA save error: {e}")

    conn.commit()
    cur.execute("""
        INSERT INTO auto_fetch_log (fetch_type, status, message)
        VALUES (?,?,?)
    """, ('dea_scrape_save',
          'success' if saved > 0 else 'failed',
          f'{message} | Saved: {saved} | Errors: {errors} | Mode: {"direct" if (auto_approve and is_super_admin) else "pending"}'))
    conn.commit()
    conn.close()

    return jsonify({
        'success':      saved > 0,
        'rows_found':   len(rows),
        'rows_saved':   saved,
        'errors':       errors,
        'message':      message,
        'save_mode':    'direct_to_history' if (auto_approve and is_super_admin) else 'pending_approval',
        'scraped_data': rows[:20],
    })


@app.route('/auto-fetch/all', methods=['POST'])
def auto_fetch_all():
    """
    Master auto-fetch: scrapes DEA prices + fetches NASA weather in one call.
    Called automatically by the admin panel on page load if enabled.
    Body JSON: { "requestor_username": "admin", "auto_approve": true }
    """
    data       = request.get_json(force=True) or {}
    requestor  = data.get('requestor_username', '')
    is_super   = _verify_super_admin(requestor)

    results = {'dea': {}, 'weather': {}}

    # Step 1: Fetch DEA prices from exagri.info — ALL available bulletin dates
    try:
        rows, dea_msg = try_scrape_dea()
        if rows:
            conn  = get_db()
            cur   = conn.cursor()
            saved = 0
            for row in rows:
                try:
                    if is_super:
                        # Skip rows older than 2025 — same rule the
                        # background auto-fetch thread already applies
                        # (see also auto_fetch_dea_save above).
                        try:
                            row_year = int(row['date'].split('.')[-1])
                        except (ValueError, IndexError):
                            row_year = 0
                        if row_year < 2025:
                            continue

                        # INSERT OR IGNORE — never overwrite manually corrected data
                        existing = cur.execute(
                            'SELECT id FROM price_history WHERE date=? AND district=? AND crop=? AND grade=?',
                            (row['date'], row['district'], row['crop'], row['grade'])
                        ).fetchone()
                        if not existing:
                            cur.execute("""
                                INSERT INTO price_history
                                (date, district, crop, grade, avg_price, high_price)
                                VALUES (?,?,?,?,?,?)
                            """, (row['date'], row['district'], row['crop'],
                                   row['grade'], row['avg_price'], row.get('high_price')))
                    else:
                        cur.execute("""
                            INSERT OR IGNORE INTO price_requests
                            (submitted_by, district, crop, grade, date,
                             avg_price, high_price, notes)
                            VALUES (?,?,?,?,?,?,?,?)
                        """, ('auto_scraper', row['district'], row['crop'],
                               row['grade'], row['date'], row['avg_price'],
                               row.get('high_price'),
                               f'Auto-scraped from exagri.info {row["date"]}'))
                    saved += 1
                except Exception:
                    pass
            conn.commit()
            conn.close()
            results['dea'] = {'success': True, 'rows': saved, 'message': dea_msg}
        else:
            results['dea'] = {'success': False, 'rows': 0, 'message': dea_msg}
    except Exception as e:
        results['dea'] = {'success': False, 'message': str(e)}

    # Step 2: Fetch NASA weather for all districts
    try:
        weather = auto_fetch_all_weather()
        results['weather'] = {'success': True, 'districts': len(weather)}
    except Exception as e:
        results['weather'] = {'success': False, 'message': str(e)}

    # Log it
    conn = get_db()
    conn.execute("""
        INSERT INTO auto_fetch_log (fetch_type, status, message)
        VALUES (?,?,?)
    """, ('auto_fetch_all',
           'success' if results['dea'].get('success') else 'partial',
           f"DEA: {results['dea'].get('rows',0)} rows | Weather: {results['weather'].get('districts',0)} districts"))
    conn.commit()
    conn.close()

    # Sync Excel master datasets so ML training always has latest data
    sync_master_datasets()

    return jsonify({'success': True, 'results': results})


@app.route('/auto-fetch/status', methods=['GET'])
def auto_fetch_status():
    conn = get_db()
    df   = pd.read_sql_query(
        "SELECT * FROM auto_fetch_log ORDER BY created_at DESC LIMIT 20", conn)
    conn.close()
    return jsonify({'log': df_to_json(df)})

# ═══════════════════════════════════════════════════════════
# ROUTES — Admin login & password
# ═══════════════════════════════════════════════════════════

@app.route('/admin/login', methods=['POST'])
def admin_login():
    data = request.get_json(force=True)
    conn = get_db()
    cur  = conn.cursor()
    cur.execute("""
        SELECT id, username, role, full_name, district, crop, email
        FROM admin_users WHERE username=? AND password=?
    """, (data.get('username'), data.get('password')))
    user = cur.fetchone()
    conn.close()
    if user:
        return jsonify({
            'success':   True,
            'role':      user['role'],
            'full_name': user['full_name'],
            'district':  user['district'],
            'crop':      user['crop'],
            'username':  user['username'],
            'email':     user['email'],
        })
    return jsonify({'success': False, 'message': 'Invalid credentials'}), 401

@app.route('/admin/change-password', methods=['POST'])
def admin_change_password():
    data = request.get_json(force=True)
    conn = get_db()
    cur  = conn.cursor()
    cur.execute("SELECT id FROM admin_users WHERE username=? AND password=?",
                (data.get('username'), data.get('old_password')))
    if not cur.fetchone():
        conn.close()
        return jsonify({'error': 'Current password is incorrect'}), 401
    cur.execute("UPDATE admin_users SET password=? WHERE username=?",
                (data.get('new_password'), data.get('username')))
    conn.commit()
    conn.close()
    return jsonify({'success': True, 'message': 'Password changed successfully'})

@app.route('/admin/forgot-password/request', methods=['POST'])
def forgot_password_request():
    """
    Admin forgot password — generates OTP and returns it
    (in production this would be emailed; for FYP it returns
    the OTP directly for the admin panel to display).
    """
    data     = request.get_json(force=True)
    username = data.get('username')
    conn     = get_db()
    cur      = conn.cursor()
    cur.execute("SELECT id, email FROM admin_users WHERE username=?", (username,))
    user = cur.fetchone()
    if not user:
        conn.close()
        return jsonify({'error': 'Username not found'}), 404

    otp        = ''.join(random.choices(string.digits, k=6))
    expires_at = (datetime.now() + timedelta(minutes=15)).isoformat()
    cur.execute("""
        INSERT INTO password_resets (username, otp, expires_at)
        VALUES (?,?,?)
    """, (username, otp, expires_at))
    conn.commit()
    conn.close()

    return jsonify({
        'success': True,
        'otp':     otp,           # In production, email this — for FYP show it
        'message': f"OTP generated. Valid for 15 minutes.",
        'expires_at': expires_at,
    })

@app.route('/admin/forgot-password/reset', methods=['POST'])
def forgot_password_reset():
    """Reset password using OTP."""
    data         = request.get_json(force=True)
    username     = data.get('username')
    otp          = data.get('otp')
    new_password = data.get('new_password')
    conn         = get_db()
    cur          = conn.cursor()
    cur.execute("""
        SELECT id FROM password_resets
        WHERE username=? AND otp=? AND used=0
          AND datetime(expires_at) > datetime('now')
        ORDER BY created_at DESC LIMIT 1
    """, (username, otp))
    row = cur.fetchone()
    if not row:
        conn.close()
        return jsonify({'error': 'Invalid or expired OTP'}), 400
    cur.execute("UPDATE admin_users SET password=? WHERE username=?",
                (new_password, username))
    cur.execute("UPDATE password_resets SET used=1 WHERE id=?", (row['id'],))
    conn.commit()
    conn.close()
    return jsonify({'success': True, 'message': 'Password reset successfully'})

# ═══════════════════════════════════════════════════════════
# ROUTES — Super Admin: account management
# ═══════════════════════════════════════════════════════════

def _verify_super_admin(username):
    conn = get_db()
    cur  = conn.cursor()
    cur.execute("SELECT role FROM admin_users WHERE username=?", (username,))
    row = cur.fetchone()
    conn.close()
    return row and row['role'] == 'super_admin'

@app.route('/admin/create-account', methods=['POST'])
def admin_create_account():
    data = request.get_json(force=True)
    if not _verify_super_admin(data.get('requestor_username')):
        return jsonify({'error': 'Only super admin can create accounts'}), 403
    conn = get_db()
    try:
        conn.execute("""
            INSERT INTO admin_users
            (username, password, role, full_name, district, crop, email)
            VALUES (?,?,?,?,?,?,?)
        """, (
            data.get('username'), data.get('password'),
            data.get('role', 'dea_staff'),
            data.get('full_name', ''),
            data.get('district'),
            data.get('crop'),
            data.get('email'),
        ))
        conn.commit()
        return jsonify({'success': True, 'message': f"Account created for {data.get('username')}"})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 409
    finally:
        conn.close()

@app.route('/admin/list-accounts', methods=['POST'])
def admin_list_accounts():
    data = request.get_json(force=True)
    if not _verify_super_admin(data.get('requestor_username')):
        return jsonify({'error': 'Only super admin can view accounts'}), 403
    conn = get_db()
    df   = pd.read_sql_query("""
        SELECT id, username, role, full_name, district, crop, email, created_at
        FROM admin_users ORDER BY created_at DESC
    """, conn)
    conn.close()
    return jsonify({'accounts': df_to_json(df)})

@app.route('/admin/delete-account', methods=['POST'])
def admin_delete_account():
    data      = request.get_json(force=True)
    requestor = data.get('requestor_username')
    target    = data.get('target_username')
    if not _verify_super_admin(requestor):
        return jsonify({'error': 'Only super admin can delete accounts'}), 403
    if target == requestor:
        return jsonify({'error': 'Cannot delete your own account'}), 400
    conn = get_db()
    conn.execute("DELETE FROM admin_users WHERE username=?", (target,))
    conn.commit()
    conn.close()
    return jsonify({'success': True, 'message': f'Account {target} deleted'})

# ═══════════════════════════════════════════════════════════
# ROUTES — Price requests (DEA staff submit, super admin approves)
# ═══════════════════════════════════════════════════════════

@app.route('/admin/submit-price-request', methods=['POST'])
def submit_price_request():
    """
    DEA staff submits a new price entry for super admin approval.
    DEA staff CANNOT directly update price_history.
    Weather data is auto-fetched from NASA if not provided.
    """
    data     = request.get_json(force=True)
    username = data.get('submitted_by')

    # Verify the submitter is a valid admin
    conn = get_db()
    cur  = conn.cursor()
    cur.execute("SELECT role, district, crop FROM admin_users WHERE username=?",
                (username,))
    user = cur.fetchone()
    if not user:
        conn.close()
        return jsonify({'error': 'Unauthorized'}), 401

    # Auto-fetch weather if not provided
    weather_data = {}
    if not data.get('rainfall_mm') or not data.get('temp_c'):
        try:
            date_parts = data.get('date', '').split('.')
            if len(date_parts) == 3:
                w = fetch_nasa_weather(
                    data.get('district'), int(date_parts[2]), int(date_parts[1]))
                if w:
                    weather_data = w
        except Exception:
            pass

    cur.execute("""
        INSERT INTO price_requests
        (submitted_by, district, crop, grade, date,
         avg_price, high_price, rainfall_mm, temp_c, humidity_pct, notes)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
    """, (
        username,
        data.get('district'), data.get('crop'), data.get('grade'),
        data.get('date'),
        float(data.get('avg_price', 0)),
        float(data.get('high_price'))  if data.get('high_price')  else None,
        float(data.get('rainfall_mm')) if data.get('rainfall_mm') else weather_data.get('rainfall_mm'),
        float(data.get('temp_c'))      if data.get('temp_c')      else weather_data.get('temp_c'),
        float(data.get('humidity_pct'))if data.get('humidity_pct')else weather_data.get('humidity_pct'),
        data.get('notes', ''),
    ))
    request_id = cur.lastrowid
    conn.commit()
    conn.close()

    return jsonify({
        'success':    True,
        'request_id': request_id,
        'message':    'Price update request submitted. Awaiting super admin approval.',
        'weather_auto_fetched': bool(weather_data),
    })

@app.route('/admin/pending-requests', methods=['POST'])
def pending_requests():
    """Super admin views all pending price requests."""
    data = request.get_json(force=True)
    if not _verify_super_admin(data.get('requestor_username')):
        return jsonify({'error': 'Only super admin can view requests'}), 403
    conn = get_db()
    df   = pd.read_sql_query("""
        SELECT * FROM price_requests
        WHERE status='pending'
        ORDER BY created_at DESC
    """, conn)
    conn.close()
    return jsonify({'requests': df_to_json(df)})

@app.route('/admin/all-requests', methods=['POST'])
def all_requests():
    """Super admin views all requests (pending, approved, rejected)."""
    data = request.get_json(force=True)
    if not _verify_super_admin(data.get('requestor_username')):
        return jsonify({'error': 'Only super admin can view requests'}), 403
    conn = get_db()
    df   = pd.read_sql_query("""
        SELECT * FROM price_requests ORDER BY created_at DESC LIMIT 100
    """, conn)
    conn.close()
    return jsonify({'requests': df_to_json(df)})

# ═══════════════════════════════════════════════════════════
# ADMIN — INLINE EDIT ROW (super admin direct edit)
# ═══════════════════════════════════════════════════════════
@app.route('/admin/edit-price', methods=['POST'])
def admin_edit_price():
    """Super admin: directly edit any row in price_history by date/crop/district/grade."""
    data  = request.get_json(force=True)
    reqby = data.get('requestor_username', '')
    conn  = get_db()
    user  = conn.execute('SELECT role FROM admin_users WHERE username=?', (reqby,)).fetchone()
    if not user or user['role'] != 'super_admin':
        conn.close()
        return jsonify({'success': False, 'error': 'Super admin only'}), 403
    required = ['date', 'district', 'crop', 'grade', 'avg_price']
    if not all(k in data for k in required):
        conn.close()
        return jsonify({'success': False, 'error': 'Missing required fields'}), 400
    conn.execute("""
        UPDATE price_history
        SET avg_price=?, high_price=?, rainfall_mm=?, temp_c=?, humidity_pct=?
        WHERE date=? AND district=? AND crop=? AND grade=?
    """, (
        float(data['avg_price']),
        float(data['high_price'])   if data.get('high_price')   else None,
        float(data['rainfall_mm'])  if data.get('rainfall_mm')  else None,
        float(data['temp_c'])       if data.get('temp_c')       else None,
        float(data['humidity_pct']) if data.get('humidity_pct') else None,
        data['date'], data['district'], data['crop'], data['grade'],
    ))
    conn.commit()
    conn.close()
    sync_master_datasets()
    return jsonify({'success': True, 'message': 'Row updated successfully'})

# ═══════════════════════════════════════════════════════════
# ADMIN — DEA STAFF SUBMIT EDIT REQUEST
# ═══════════════════════════════════════════════════════════
@app.route('/admin/request-edit', methods=['POST'])
def admin_request_edit():
    """DEA staff: request edit of existing row — goes pending for super admin approval."""
    data  = request.get_json(force=True)
    reqby = data.get('submitted_by', '')
    conn  = get_db()
    user  = conn.execute('SELECT role FROM admin_users WHERE username=?', (reqby,)).fetchone()
    if not user:
        conn.close()
        return jsonify({'success': False, 'error': 'Not authenticated'}), 403
    required = ['date', 'district', 'crop', 'grade', 'avg_price']
    if not all(k in data for k in required):
        conn.close()
        return jsonify({'success': False, 'error': 'Missing required fields'}), 400
    conn.execute("""
        INSERT INTO price_requests
        (submitted_by, date, district, crop, grade,
         avg_price, high_price, rainfall_mm, temp_c, humidity_pct, notes, status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    """, (
        reqby, data['date'], data['district'], data['crop'], data['grade'],
        float(data['avg_price']),
        float(data['high_price'])   if data.get('high_price')   else None,
        float(data['rainfall_mm'])  if data.get('rainfall_mm')  else None,
        float(data['temp_c'])       if data.get('temp_c')       else None,
        float(data['humidity_pct']) if data.get('humidity_pct') else None,
        data.get('notes', 'Edit request from DEA staff'), 'pending'
    ))
    conn.commit()
    conn.close()
    return jsonify({'success': True, 'message': 'Edit request submitted for approval'})

# ═══════════════════════════════════════════════════════════
# ADMIN — REVIEW REQUEST (approve / reject)
# ═══════════════════════════════════════════════════════════
@app.route('/admin/review-request', methods=['POST'])
def review_request():
    """
    Super admin approves or rejects a price request.
    If approved, the price is automatically saved to price_history.
    """
    data       = request.get_json(force=True)
    requestor  = data.get('requestor_username')
    request_id = data.get('request_id')
    action     = data.get('action')      # 'approve' or 'reject'
    note       = data.get('review_note', '')

    if not _verify_super_admin(requestor):
        return jsonify({'error': 'Only super admin can review requests'}), 403

    if action not in ('approve', 'reject'):
        return jsonify({'error': 'action must be approve or reject'}), 400

    conn = get_db()
    cur  = conn.cursor()
    cur.execute("SELECT * FROM price_requests WHERE id=?", (request_id,))
    req  = cur.fetchone()
    if not req:
        conn.close()
        return jsonify({'error': 'Request not found'}), 404

    now    = datetime.now().isoformat()
    status = 'approved' if action == 'approve' else 'rejected'

    cur.execute("""
        UPDATE price_requests
        SET status=?, reviewed_by=?, review_note=?, reviewed_at=?
        WHERE id=?
    """, (status, requestor, note, now, request_id))

    if action == 'approve':
        # Capture previous price before inserting
        cur.execute("""
            SELECT avg_price FROM price_history
            WHERE district=? AND crop=? AND grade=?
            ORDER BY date(substr(date,7,4)||'-'||substr(date,4,2)||'-'||substr(date,1,2)) DESC
            LIMIT 1
        """, (req['district'], req['crop'], req['grade']))
        prev_row = cur.fetchone()
        previous_price = float(prev_row['avg_price']) if prev_row else None

        # Save to price_history
        cur.execute("""
            INSERT OR REPLACE INTO price_history
            (date, district, crop, grade, avg_price, high_price,
             rainfall_mm, temp_c, humidity_pct)
            VALUES (?,?,?,?,?,?,?,?,?)
        """, (
            req['date'], req['district'], req['crop'], req['grade'],
            req['avg_price'], req['high_price'],
            req['rainfall_mm'], req['temp_c'], req['humidity_pct'],
        ))

        conn.commit()
        sync_master_datasets()  # Keep Excel files in sync

        # Auto-notify farmers if price changed >= 3%
        if previous_price:
            change_pct = (req['avg_price'] - previous_price) / previous_price * 100
            if abs(change_pct) >= 3.0:
                direction = 'risen' if change_pct > 0 else 'fallen'
                title = f"{req['crop']} price update"
                body  = (f"{req['crop']} ({req['grade']}, {req['district']}) "
                         f"has {direction} by {abs(change_pct):.1f}% "
                         f"to Rs.{req['avg_price']:.0f}/kg")
                tokens_df = pd.read_sql_query("""
                    SELECT fcm_token FROM device_tokens
                    WHERE district=? AND crop=? AND grade=?
                """, conn, params=(req['district'], req['crop'], req['grade']))
                for token in tokens_df['fcm_token']:
                    send_push(token, title, body)
                print(f"  Auto-notification: {change_pct:+.1f}% change after approval")
    else:
        conn.commit()

    conn.close()
    return jsonify({
        'success': True,
        'message': f"Request {status} successfully.",
        'status':  status,
    })

@app.route('/admin/my-requests', methods=['POST'])
def my_requests():
    """DEA staff views their own submitted requests."""
    data     = request.get_json(force=True)
    username = data.get('username')
    conn     = get_db()
    df       = pd.read_sql_query("""
        SELECT * FROM price_requests
        WHERE submitted_by=?
        ORDER BY created_at DESC LIMIT 50
    """, conn, params=(username,))
    conn.close()
    return jsonify({'requests': df_to_json(df)})

# ═══════════════════════════════════════════════════════════
# ROUTES — Super admin: direct price management
# ═══════════════════════════════════════════════════════════

@app.route('/admin/upload-price', methods=['POST'])
def admin_upload_price():
    """
    Super admin can directly upload prices (bypasses approval workflow).
    DEA staff must use /admin/submit-price-request instead.
    """
    data     = request.get_json(force=True)
    required = ['date', 'district', 'crop', 'grade', 'avg_price']
    if not all(k in data for k in required):
        return jsonify({'error': f'Required: {required}'}), 400

    # Capture previous price before inserting
    conn0    = get_db()
    prev_row = conn0.execute("""
        SELECT avg_price FROM price_history
        WHERE district=? AND crop=? AND grade=?
        ORDER BY date(substr(date,7,4)||'-'||substr(date,4,2)||'-'||substr(date,1,2)) DESC
        LIMIT 1
    """, (data['district'], data['crop'], data['grade'])).fetchone()
    previous_price = float(prev_row['avg_price']) if prev_row else None
    conn0.close()

    # Auto-fetch weather if not provided
    weather_data = {}
    if not data.get('rainfall_mm') or not data.get('temp_c'):
        try:
            date_parts = data['date'].split('.')
            w = fetch_nasa_weather(data['district'],
                                   int(date_parts[2]), int(date_parts[1]))
            if w:
                weather_data = w
        except Exception:
            pass

    conn = get_db()
    conn.execute("""
        INSERT OR REPLACE INTO price_history
        (date, district, crop, grade, avg_price, high_price,
         rainfall_mm, temp_c, humidity_pct)
        VALUES (?,?,?,?,?,?,?,?,?)
    """, (
        data['date'], data['district'], data['crop'], data['grade'],
        float(data['avg_price']),
        float(data.get('high_price'))  if data.get('high_price')  else None,
        float(data.get('rainfall_mm')) if data.get('rainfall_mm') else weather_data.get('rainfall_mm'),
        float(data.get('temp_c'))      if data.get('temp_c')      else weather_data.get('temp_c'),
        float(data.get('humidity_pct'))if data.get('humidity_pct')else weather_data.get('humidity_pct'),
    ))
    conn.commit()
    sync_master_datasets()  # Keep Excel files in sync

    # Auto-notify farmers
    if previous_price:
        change_pct = (float(data['avg_price']) - previous_price) / previous_price * 100
        if abs(change_pct) >= 3.0:
            direction = 'risen' if change_pct > 0 else 'fallen'
            title     = f"{data['crop']} price update"
            body      = (f"{data['crop']} ({data['grade']}, {data['district']}) "
                         f"has {direction} by {abs(change_pct):.1f}%")
            tokens_df = pd.read_sql_query("""
                SELECT fcm_token FROM device_tokens
                WHERE district=? AND crop=? AND grade=?
            """, conn, params=(data['district'], data['crop'], data['grade']))
            for token in tokens_df['fcm_token']:
                send_push(token, title, body)
            print(f"  Auto-notification: {change_pct:+.1f}% change, "
                  f"notified {len(tokens_df)} farmer(s)")
    conn.close()

    return jsonify({'success': True, 'message': 'Price saved',
                    'weather_auto_fetched': bool(weather_data)})

@app.route('/admin/send-alert', methods=['POST'])
def admin_send_alert():
    data  = request.get_json(force=True)
    conn  = get_db()
    df    = pd.read_sql_query("""
        SELECT fcm_token FROM device_tokens
        WHERE district=? AND crop=? AND grade=?
    """, conn, params=(data.get('district'), data.get('crop'), data.get('grade')))
    conn.close()
    sent, failed = 0, 0
    for token in df['fcm_token']:
        ok      = send_push(token, data.get('title',''), data.get('body',''))
        sent   += 1 if ok else 0
        failed += 0 if ok else 1
    return jsonify({'success': True, 'recipients_found': len(df),
                    'sent': sent, 'failed': failed,
                    'firebase_enabled': FIREBASE_ENABLED})

@app.route('/admin/retrain', methods=['POST'])
def admin_retrain():
    try:
        env = os.environ.copy()
        env['PYTHONIOENCODING'] = 'utf-8'
        result = subprocess.run(
            ['python', TRAIN_SCRIPT],
            capture_output=True, text=True,
            timeout=600, encoding='utf-8',
            errors='replace', env=env)
        if result.returncode != 0:
            return jsonify({'success': False, 'error': result.stderr[-1000:]}), 500
        global MODEL, FEATURE_NAMES, ENCODING_MAPS
        MODEL         = joblib.load(os.path.join(ML_DIR, 'best_model.pkl'))
        FEATURE_NAMES = joblib.load(os.path.join(ML_DIR, 'feature_names.pkl'))
        ENCODING_MAPS = joblib.load(os.path.join(ML_DIR, 'encoding_maps.pkl'))
        metrics_path = os.path.join(BASE_DIR, '..', 'ml', 'results', 'model_comparison.csv')
        metrics = []
        if os.path.exists(metrics_path):
            import csv
            with open(metrics_path, newline='', encoding='utf-8') as mf:
                for row in csv.DictReader(mf):
                    metrics.append({'model': row.get('Model',''),
                                    'mae':   safe_val(row.get('MAE (Rs/kg)',0)),
                                    'rmse':  safe_val(row.get('RMSE (Rs/kg)',0)),
                                    'r2':    safe_val(row.get('R2 Score',0))})
        return jsonify({'success': True, 'message': 'Model retrained and reloaded',
                        'log_tail': result.stdout[-500:], 'metrics': metrics})
    except subprocess.TimeoutExpired:
        return jsonify({'success': False, 'error': 'Timeout'}), 500

# ═══════════════════════════════════════════════════════════
# MODEL METRICS ENDPOINT
# Returns MAE, RMSE, R2 for all 3 models from last training run
# ═══════════════════════════════════════════════════════════
@app.route('/admin/model-metrics', methods=['GET'])
def admin_model_metrics():
    """Return saved model metrics from last training run."""
    try:
        metrics_path = os.path.join(BASE_DIR, '..', 'ml', 'results', 'model_comparison.csv')
        if not os.path.exists(metrics_path):
            return jsonify({'success': False, 'error': 'No metrics file found. Run retraining first.'})

        import csv
        rows = []
        with open(metrics_path, newline='', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                rows.append({
                    'model':    row.get('Model', ''),
                    'mae':      safe_val(row.get('MAE (Rs/kg)', 0)),
                    'rmse':     safe_val(row.get('RMSE (Rs/kg)', 0)),
                    'r2':       safe_val(row.get('R2 Score', 0)),
                })

        # Also read accuracy summary text
        summary_path = os.path.join(BASE_DIR, '..', 'ml', 'results', 'accuracy_summary_for_thesis.txt')
        summary = ''
        if os.path.exists(summary_path):
            with open(summary_path, encoding='utf-8') as f:
                summary = f.read()

        return jsonify({'success': True, 'models': rows, 'summary': summary})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

# ═══════════════════════════════════════════════════════════
# CHATBOT STATUS (for admin panel — never exposes the actual key)
# ═══════════════════════════════════════════════════════════
@app.route('/admin/chatbot-status', methods=['GET'])
def admin_chatbot_status():
    """Lets the admin panel check whether the AI chatbot is configured
    on this server, without exposing the actual Gemini API key."""
    return jsonify({
        'configured': bool(GEMINI_API_KEY),
        'model': GEMINI_MODEL,
    })

@app.route('/admin/reset-chatbot-quota', methods=['POST'])
def admin_reset_chatbot_quota():
    """
    Super admin only: resets a device's today chatbot usage count back
    to 0, so testing isn't blocked by the same fair-share daily limit
    real farmers are subject to. This does NOT change the limit itself
    or affect any other device — it only clears today's count for the
    one device_id given, so farmer-facing fairness is unaffected.
    """
    data      = request.get_json(force=True) or {}
    requestor = data.get('requestor_username', '')
    device_id = (data.get('device_id') or '').strip()

    if not _verify_super_admin(requestor):
        return jsonify({'error': 'Only super admin can reset quota'}), 403
    if not device_id:
        return jsonify({'error': 'device_id is required'}), 400

    conn  = get_db()
    today = datetime.now().strftime('%Y-%m-%d')
    conn.execute(
        "DELETE FROM chatbot_usage WHERE device_id=? AND date=?",
        (device_id, today)
    )
    conn.commit()
    conn.close()
    return jsonify({'success': True, 'message': f'Quota reset for today.'})

# ═══════════════════════════════════════════════════════════
# NEXT FETCH INFO
# ═══════════════════════════════════════════════════════════
@app.route('/admin/next-fetch-info', methods=['GET'])
def next_fetch_info():
    """Return next expected DEA bulletin date and NASA update status."""
    try:
        from bs4 import BeautifulSoup
        import re as _re
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}

        # Check exagri index for latest + next bulletin
        latest_dea = None
        next_dea   = None
        try:
            idx = requests.get('https://exagri.info/mkt/index.html',
                               headers=headers, timeout=15)
            if idx.status_code == 200:
                soup = BeautifulSoup(idx.text, 'html.parser')
                # Find "Last Updated on" and "Next update"
                text = soup.get_text()
                last_m = _re.search(r'Last Updated on[\s\n]+(\d{1,2}-\w+-\d{4})', text)
                next_m = _re.search(r'Next update[^\n]+[\n\s]+(\d{1,2}-\w+-\d{4})', text)
                if last_m: latest_dea = last_m.group(1)
                if next_m: next_dea   = next_m.group(1)
        except Exception as e:
            print(f"  next-fetch-info DEA error: {e}")

        # NASA: current month + last update
        now = datetime.now()
        conn = get_db()
        nasa_last = conn.execute(
            "SELECT created_at FROM auto_fetch_log WHERE fetch_type='nasa_weather' ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        dea_last = conn.execute(
            "SELECT created_at, message FROM auto_fetch_log WHERE fetch_type IN ('dea_scrape_save','auto_fetch_all') ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        missing_weather = conn.execute(
            "SELECT COUNT(*) as cnt FROM price_history WHERE rainfall_mm IS NULL"
        ).fetchone()
        conn.close()

        return jsonify({
            'success': True,
            'dea': {
                'latest_bulletin': latest_dea,
                'next_bulletin':   next_dea,
                'last_fetched':    dea_last['created_at'] if dea_last else None,
                'last_message':    dea_last['message']    if dea_last else None,
            },
            'nasa': {
                'current_month':    f"{now.year}/{now.month:02d}",
                'last_fetched':     nasa_last['created_at'] if nasa_last else None,
                'missing_weather':  missing_weather['cnt']  if missing_weather else 0,
            }
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

# ═══════════════════════════════════════════════════════════
# STARTUP
# ═══════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════
# BACKGROUND AUTO-FETCH THREAD
# Runs every hour automatically — no admin panel needed
# Fetches DEA weekly prices + NASA weather for all missing months
# ═══════════════════════════════════════════════════════════
def _background_auto_fetch():
    import time
    time.sleep(30)  # Wait 30s after startup before first run
    while True:
        try:
            print("  [Auto-fetch] Starting hourly background fetch...")

            # ── DEA prices: scrape ALL available bulletin dates ──
            rows, msg = try_scrape_dea()
            if rows:
                conn  = get_db()
                cur   = conn.cursor()
                saved = 0
                for row in rows:
                    try:
                        existing = cur.execute(
                            'SELECT id FROM price_history WHERE date=? AND district=? AND crop=? AND grade=?',
                            (row['date'], row['district'], row['crop'], row['grade'])
                        ).fetchone()
                        if not existing:
                            row_year = row['date'].split('.')[-1] if '.' in row['date'] else '0'
                            try:
                                if int(row_year) >= 2025:
                                    cur.execute("""
                                        INSERT INTO price_history
                                        (date, district, crop, grade, avg_price, high_price)
                                        VALUES (?,?,?,?,?,?)
                                    """, (row['date'], row['district'], row['crop'],
                                           row['grade'], row['avg_price'], row.get('high_price')))
                                    saved += 1
                                    if saved % 100 == 0:
                                        conn.commit()
                            except (ValueError, TypeError):
                                pass
                    except Exception:
                        pass
                conn.commit()
                cur.execute("""
                    INSERT INTO auto_fetch_log (fetch_type, status, message)
                    VALUES (?,?,?)
                """, ('dea_scrape_save', 'success',
                      f'Background: {msg} | New rows saved: {saved}'))
                conn.commit()
                conn.close()
                print(f"  [Auto-fetch] DEA: {saved} new rows saved. {msg}")
                # Auto-send notifications to all registered devices when new data arrives
                if saved > 0:
                    _send_price_notifications()
            else:
                print(f"  [Auto-fetch] DEA: No new data. {msg}")
                # Log even when 0 new rows so last_fetched timestamp stays current
                try:
                    _dc = get_db()
                    _dc.execute("""INSERT INTO auto_fetch_log (fetch_type, status, message)
                        VALUES (?,?,?)""",
                        ('dea_scrape_save', 'success',
                         f'Background: {msg} | New rows saved: 0'))
                    _dc.commit(); _dc.close()
                except Exception:
                    pass

            # ── NASA weather: fill ALL months missing weather ──
            # auto_fetch_all_weather() already writes its own auto_fetch_log
            # entry internally (using the real price_history row-update
            # count). This wrapper used to ALSO write a second log entry
            # here, using len(weather) — a different number entirely (count
            # of district/month combos fetched, not rows updated) — which
            # produced two "NASA Weather" rows per cycle with two different,
            # confusing counts. Removed the duplicate; only the accurate
            # internal log entry remains.
            try:
                weather = auto_fetch_all_weather()
                print(f"  [Auto-fetch] NASA: {len(weather)} district/month combos fetched")
            except Exception as nasa_e:
                print(f"  [Auto-fetch] NASA error: {nasa_e}")

            # ── Sync Excel master datasets for ML training ──
            sync_master_datasets()

        except Exception as e:
            print(f"  [Auto-fetch] Background error: {e}")

        time.sleep(3600)  # Run every 1 hour


def _send_price_notifications():
    """
    Called automatically after DEA fetch saves new rows.
    Sends price update notifications to all registered devices.
    Groups by crop/district/grade and fetches latest price + prediction.

    NOTE: this function must be defined BEFORE the `if __name__ ==
    '__main__':` block below, since app.run() blocks forever once
    started — any code defined after it never actually loads while
    the server is running, and the background thread that calls this
    function would fail with NameError.
    """
    try:
        conn  = get_db()
        # Get all unique crop/district/grade combos with registered devices
        rows  = conn.execute("""
            SELECT DISTINCT crop, district, grade, fcm_token
            FROM device_tokens
            WHERE fcm_token IS NOT NULL AND fcm_token != ''
        """).fetchall()
        conn.close()

        if not rows:
            return

        # Group tokens by crop/district/grade
        from collections import defaultdict
        groups = defaultdict(list)
        for r in rows:
            groups[(r['crop'], r['district'], r['grade'])].append(r['fcm_token'])

        for (crop, district, grade), tokens in groups.items():
            try:
                # Get latest price from DB
                c2    = get_db()
                price = c2.execute("""
                    SELECT date, avg_price FROM price_history
                    WHERE crop=? AND district=? AND grade=?
                    ORDER BY date(substr(date,7,4)||'-'||substr(date,4,2)||'-'||substr(date,1,2)) DESC
                    LIMIT 1
                """, (crop, district, grade)).fetchone()
                c2.close()

                if not price:
                    continue

                # Get prediction — compute_features returns a 3-tuple
                # (feature_vector, context, error); use fv (not the
                # whole tuple) exactly as /predict does.
                fv, ctx, err = compute_features(district, crop, grade)
                pred_price = None
                if fv is not None:
                    pred_arr   = MODEL.predict(fv)[0]
                    pred_price = round(float(pred_arr), 2)

                # Build notification
                last_price = round(float(price['avg_price']), 0)
                last_date  = price['date']

                if pred_price:
                    change_pct = ((pred_price - last_price) / last_price) * 100
                    direction  = '▲' if change_pct >= 0 else '▼'
                    body = (f"{last_date}: Rs.{int(last_price)}/kg | "
                            f"Next week predicted: Rs.{int(pred_price)}/kg "
                            f"({direction}{abs(change_pct):.1f}%)")
                else:
                    body = f"Latest price: Rs.{int(last_price)}/kg ({last_date})"

                title = f"🌿 New Price — {crop} {grade} ({district})"

                # Send to all tokens for this combo
                import firebase_admin.messaging as _msg
                for token in tokens:
                    try:
                        msg = _msg.Message(
                            notification=_msg.Notification(title=title, body=body),
                            data={
                                'crop':     crop,
                                'district': district,
                                'grade':    grade,
                                'type':     'price_update',
                            },
                            android=_msg.AndroidConfig(
                                priority='high',
                                notification=_msg.AndroidNotification(
                                    sound='default',
                                    channel_id='price_updates',
                                )
                            ),
                            apns=_msg.APNSConfig(
                                payload=_msg.APNSPayload(
                                    aps=_msg.Aps(sound='default', badge=1)
                                )
                            ),
                            token=token,
                        )
                        firebase_admin.messaging.send(msg)
                    except Exception:
                        pass

                print(f"  [Notification] Sent to {len(tokens)} devices: {crop} {grade} {district}")

            except Exception as e:
                print(f"  [Notification] Error for {crop}/{district}/{grade}: {e}")

    except Exception as e:
        print(f"  [Notification] General error: {e}")


if __name__ == '__main__':
    init_db()

    # Clean database: remove rows outside project scope (before 2025)
    # Uses a safe check: try both DD.MM.YYYY and YYYY-MM-DD formats
    _conn = get_db()
    _rows = _conn.execute(
        "SELECT rowid, date FROM price_history"
    ).fetchall()
    _to_delete = []
    for r in _rows:
        d = str(r['date']).strip()
        try:
            # DD.MM.YYYY → year is last 4 chars after last dot
            if '.' in d and len(d) == 10:
                yr = int(d[-4:])
            # YYYY-MM-DD or YYYY/MM/DD → year is first 4 chars
            elif len(d) >= 4 and (d[4] == '-' or d[4] == '/'):
                yr = int(d[:4])
            else:
                yr = int(d[-4:])
            if yr < 2025:
                _to_delete.append(r['rowid'])
        except Exception:
            pass
    if _to_delete:
        _conn.execute(
            f"DELETE FROM price_history WHERE rowid IN ({','.join('?'*len(_to_delete))})",
            _to_delete
        )
        _conn.commit()
        print(f"  Removed {len(_to_delete)} pre-2025 rows (outside project scope)")
    _conn.close()

    load_initial_price_data()
    print("\n" + "=" * 60)
    print("Flask API v4 — http://0.0.0.0:5000")
    print("=" * 60)
    print("""
  Default super admin: admin / Admin@1234 (change after first login!)

  Farmer endpoints:
    GET  /health
    GET  /metadata
    POST /predict              (includes weather + current-week date)
    POST /harvest-status
    POST /recommendation
    GET  /history
    POST /register-device
    POST /chatbot               (AI farming help — needs GEMINI_API_KEY)

  Auto-fetch endpoints:
    POST /auto-fetch/weather   (NASA POWER)
    POST /auto-fetch/dea-prices (DEA PDF scraper)
    GET  /auto-fetch/status

  Admin endpoints:
    POST /admin/login
    POST /admin/change-password
    POST /admin/forgot-password/request  (get OTP)
    POST /admin/forgot-password/reset    (reset with OTP)

  Super admin only:
    POST /admin/create-account
    POST /admin/list-accounts
    POST /admin/delete-account
    POST /admin/upload-price   (direct, no approval needed)
    POST /admin/pending-requests
    POST /admin/all-requests
    POST /admin/review-request  (approve / reject)
    POST /admin/send-alert
    POST /admin/retrain
    POST /admin/reset-chatbot-quota (testing convenience — clears one device's daily limit)

  DEA staff:
    POST /admin/submit-price-request  (goes for approval)
    POST /admin/my-requests           (view own requests)
    """)
    # Start background auto-fetch thread (runs every hour, daemon so it stops with Flask)
    import threading
    _bg_thread = threading.Thread(target=_background_auto_fetch, daemon=True, name='AutoFetch')
    _bg_thread.start()
    print("  Background auto-fetch started — runs every hour automatically")
    print("  No need to keep admin panel open for data collection")

    # threaded=True lets Flask handle multiple requests concurrently
    # instead of queuing them one at a time. This matters because the
    # admin panel fires 3 requests at once on login for super admin
    # (metadata, pending-requests, accounts) — without this, they queue
    # behind each other and can make the metadata call time out on the
    # Flutter side under load, which crashes the admin panel screen.
    app.run(host='0.0.0.0', port=5000, debug=False, use_reloader=False,
            threaded=True)