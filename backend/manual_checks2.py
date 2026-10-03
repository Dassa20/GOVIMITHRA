"""Remaining checks: BE-024 (chatbot daily limit), AI-007 and AI-008 (retraining evidence).
Run from the backend folder:   python manual_checks2.py
It uses a fake Gemini reply (no real API call) and a test device id, then removes the test rows."""
import os, sqlite3, datetime, json
def hdr(t): print('\n' + '=' * 70 + '\n' + t + '\n' + '=' * 70)
import app as A
client = A.app.test_client()

hdr('BE-024  chatbot per-device daily limit (25/day)')
A.GEMINI_API_KEY = 'test-key'
A._call_gemini_model = lambda model, message, system_prompt: {'ok': True, 'reply': 'test reply'}
dev = 'be024-test-device'
codes = []
for i in range(1, 27):
    r = client.post('/chatbot', json={'message': 'hello %d' % i, 'device_id': dev, 'language': 'en'})
    codes.append(r.status_code)
print('status codes for messages 1 to 26:', codes)
last = client.post('/chatbot', json={'message': 'one more', 'device_id': dev}).get_json()
print('response after the limit:', json.dumps(last))
print('RESULT:', 'limit enforced at message 26' if codes[:25] == [200] * 25 and codes[25] == 429 else 'UNEXPECTED, check the codes above')
conn = sqlite3.connect(A.DB_PATH); conn.execute("DELETE FROM chatbot_usage WHERE device_id=?", (dev,)); conn.commit(); conn.close()
print('test rows removed')

hdr('AI-007 / AI-008  model files and current model metrics')
for name in ('best_model.pkl', 'XGBoost.pkl', 'Random_Forest.pkl', 'Linear_Regression.pkl'):
    p = os.path.join(A.ML_DIR, name)
    print(name, datetime.datetime.fromtimestamp(os.path.getmtime(p)) if os.path.exists(p) else 'not found')
m = client.get('/admin/model-metrics').get_json()
print('current model metrics from /admin/model-metrics:')
print(json.dumps(m, indent=2)[:1200])
print('\nThesis XGBoost figures for comparison: R2 0.8599, MAE 110.29, RMSE 184.86')
print('\nDONE')
