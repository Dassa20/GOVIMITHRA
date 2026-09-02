module.exports = {
  testDir: '.',
  testMatch: '**/*_test.js',
  timeout: 60000, // increased from default 30s -- real app.py has extra
                   // startup overhead (Firebase init, background
                   // auto-fetch) that the retry logic needs headroom for
  use: {
    headless: true,
  },
};
