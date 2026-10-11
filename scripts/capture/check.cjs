// Reproducible Chromium corpus and optional anonymous live-site smoke test.
// Requires Playwright; no user browser profile, cookies or account writes.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../..');
const bundle = fs.readFileSync(path.join(root, 'ios/HearfulShare/CapturePage.js'), 'utf8');
const cases = JSON.parse(fs.readFileSync(path.join(root, 'ios/HearfulTests/BrowserCaptureFixtures/capture-policy-cases.json')));
const extract = bundle + '\nnew Promise(resolve => ExtensionPreprocessingJS.run({completionFunction: resolve}));';
(async () => {
    const browser = await chromium.launch({headless: true});
    const report = {at: new Date().toISOString(), engine: await browser.version(), bundleSha256: createHash('sha256').update(bundle).digest('hex'), fixtures: [], live: []};
    try {
        for (const test of cases) {
            const page = await browser.newPage();
            try {
                await page.route('**/*', route => route.fulfill({status: test.httpStatus || 200, contentType: 'text/html', body: test.html}));
                await page.goto(test.url);
                if ('httpStatus' in test) {
                    const result = await page.evaluate(bundle + `\nMagpieCapturePolicy.navigationRetry(document, ${test.httpStatus});`);
                    assert.equal(result, test.retry);
                } else {
                    const result = await page.evaluate(extract);
                    assert.equal(result.status, test.status);
                    if (test.reason) assert.equal(result.captureFailure, test.reason);
                    for (const text of test.contains || []) assert.ok(result.html.includes(text), `Missing ${text}`);
                    for (const text of test.excludes || []) assert.ok(!result.html.includes(text), `Included ${text}`);
                    if (test.status !== 'captured') assert.equal(result.html, '');
                }
                report.fixtures.push({name: test.name, passed: true});
            } catch (error) {
                report.fixtures.push({name: test.name, passed: false, error: error.message});
            } finally { await page.close(); }
        }
        if (process.argv.includes('--live')) {
            const sites = JSON.parse(fs.readFileSync(path.join(__dirname, 'live-sites.json')));
            for (const site of sites) {
                const page = await browser.newPage();
                try {
                    const response = await page.goto(site.url, {waitUntil: 'domcontentloaded', timeout: 25000});
                    await page.waitForTimeout(2500);
                    const result = await page.evaluate(extract);
                    report.live.push({name: site.name, url: page.url(), http: response?.status(), status: result.status,
                        reason: result.captureFailure || null, title: result.title,
                        words: result.html ? await page.evaluate(html => {const d = new DOMParser().parseFromString(html, 'text/html'); return d.body.textContent.trim().split(/\s+/).length;}, result.html) : 0});
                } catch (error) { report.live.push({name: site.name, url: site.url, status: 'load-failed', error: error.message.split('\n')[0]}); }
                finally { await page.close(); }
            }
        }
    } finally { await browser.close(); }
    console.log(JSON.stringify(report, null, 2));
    if (report.fixtures.some(test => !test.passed)) process.exitCode = 1;
})().catch(error => { console.error(error); process.exitCode = 1; });
