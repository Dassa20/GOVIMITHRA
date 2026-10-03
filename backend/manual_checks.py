"""Runs the remaining database, recommendation and harvest-status checks.
Run this from the backend folder:
    python manual_checks.py "C:\\path\\to\\Master_ML_Dataset_CinnamonPepper.xlsx"
Then copy everything it prints and send it back. It only reads the database."""
import sqlite3, sys, os, glob, random, datetime, json

DB = 'price_data.db'
def hdr(t): print('\n' + '=' * 70 + '\n' + t + '\n' + '=' * 70)

conn = sqlite3.connect(DB)
cur = conn.cursor()

hdr('DB-001  database opens without corruption')
print('tables:', [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")])
print('integrity_check:', cur.execute('PRAGMA integrity_check').fetchone()[0])

hdr('DB-002  duplicate crop + district + grade + date rows')
dups = cur.execute("SELECT date,district,crop,grade,COUNT(*) c FROM price_history GROUP BY date,district,crop,grade HAVING c>1").fetchall()
print('duplicate groups:', len(dups), dups[:5])
print('total rows in price_history:', cur.execute('SELECT COUNT(*) FROM price_history').fetchone()[0])

hdr('DB-003  chatbot_usage')
for r in cur.execute('SELECT device_id,date,count FROM chatbot_usage ORDER BY date DESC LIMIT 15'):
    print(r)
print('total rows:', cur.execute('SELECT COUNT(*) FROM chatbot_usage').fetchone()[0])
print('max count in one day:', cur.execute('SELECT MAX(count) FROM chatbot_usage').fetchone()[0])
print('rows with empty device_id:', cur.execute("SELECT COUNT(*) FROM chatbot_usage WHERE device_id IS NULL OR device_id=''").fetchone()[0])

hdr('DB-005  backup file')
found = set()
for pat in ('*backup*', '*.bak', 'backup*'):
    found.update(glob.glob(pat)); found.update(glob.glob(os.path.join('backups', pat)))
if found:
    for f in sorted(found):
        print(f, datetime.datetime.fromtimestamp(os.path.getmtime(f)))
else:
    print('NO backup file found in this folder')
print('live database last modified:', datetime.datetime.fromtimestamp(os.path.getmtime(DB)))

hdr('DB-006  spot check against the master dataset')
path = sys.argv[1] if len(sys.argv) > 1 else 'Master_ML_Dataset_CinnamonPepper.xlsx'
try:
    import openpyxl
    ws = openpyxl.load_workbook(path, data_only=True, read_only=True)['Master_ML_Dataset']
    rows = list(ws.iter_rows(min_row=2, values_only=True))
    random.seed(1)
    ok = 0
    sample = random.sample(rows, 10)
    for r in sample:
        date, district, crop, grade, avg, high = r[0], r[5], r[6], r[7], r[8], r[9]
        db = cur.execute('SELECT avg_price,high_price FROM price_history WHERE date=? AND district=? AND crop=? AND grade=?',
                         (date, district, crop, grade)).fetchone()
        match = db is not None and abs(db[0] - avg) < 0.01 and (high is None or db[1] is None or abs(db[1] - high) < 0.01)
        ok += bool(match)
        print(date, district, crop, grade, 'master', avg, high, 'db', db, 'MATCH' if match else 'DIFFERENT')
    print('matched', ok, 'of', len(sample))
except Exception as e:
    print('could not run this check:', repr(e), '(pip install openpyxl, and pass the xlsx path)')

hdr('BE-016 and AI-006  (uses app.py through the Flask test client)')
try:
    import app as A
    client = A.app.test_client()
    row = cur.execute("SELECT district,crop,grade FROM price_history GROUP BY district,crop,grade HAVING COUNT(*)>=8 ORDER BY COUNT(*) DESC LIMIT 1").fetchone()
    print('using combination:', row)
    r = client.post('/recommendation', json={'district': row[0], 'crop': row[1], 'grade': row[2]})
    j = r.get_json()
    print('status:', r.status_code)
    print(json.dumps(j, indent=2)[:900])
    need = ['recommendation', 'reason', 'predicted_price', 'last_known_price', 'price_change_pct', 'is_harvest_season', 'rainfall_mm', 'temp_c', 'humidity_pct']
    print('missing fields:', [k for k in need if k not in (j or {})])
    from unittest import mock
    import datetime as dt
    def fixed(y, m, d):
        class F(dt.datetime):
            @classmethod
            def now(cls, tz=None): return cls(y, m, d)
        return F
    for crop, y, m, d, exp in (('Cinnamon', 2026, 6, 15, 'Ready to Harvest'), ('Cinnamon', 2026, 11, 15, 'Not Harvest Season'),
                               ('Pepper', 2026, 2, 15, 'Ready to Harvest'), ('Pepper', 2026, 7, 15, 'Not Harvest Season')):
        with mock.patch.object(A, 'datetime', fixed(y, m, d)):
            rr = client.post('/harvest-status', json={'crop': crop, 'district': 'Galle'}).get_json()
        print('AI-006', crop, '%d-%02d-%02d' % (y, m, d), '->', rr.get('status'), '| expected', exp, '| OK' if rr.get('status') == exp else '| MISMATCH')
except Exception as e:
    print('could not run the app checks:', repr(e))
print('\nDONE')
