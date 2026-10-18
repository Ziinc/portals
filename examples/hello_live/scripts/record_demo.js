// Records demo/hello_live.gif from a running `mix phx.server`.
//
//     cd examples/hello_live && mix phx.server &
//     NODE_PATH=$(npm root -g) node scripts/record_demo.js
//
// Needs the `playwright` npm package (with Chromium), ffmpeg and gifski
// (https://gif.ski). Set CHROMIUM_PATH to use an existing Chromium build.
//
// Quality: frames are captured losslessly as PNGs through the DevTools
// screencast at 2x device pixels (not via Playwright's lossy video
// recording), resampled to a constant frame rate, downscaled once with
// Lanczos, and encoded by gifski.
const { chromium } = require('playwright');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const url = process.env.DEMO_URL || 'http://localhost:4000/';
const out = path.resolve(__dirname, '../demo/hello_live.gif');
const viewport = { width: 1180, height: 720 };
const scale = 2; // capture at 2x device pixels
const outWidth = 1600; // final GIF width: sharp on HiDPI screens
const fps = 25;

// Screencasts don't show the mouse, so draw one.
const cursorScript = `
  window.addEventListener('DOMContentLoaded', () => {
    const c = document.createElement('div');
    c.style.cssText = 'position:fixed;left:0;top:0;width:18px;height:18px;margin:-9px 0 0 -9px;' +
      'border-radius:50%;background:rgba(17,24,39,.55);border:2px solid white;' +
      'box-shadow:0 0 0 1px rgba(0,0,0,.25);pointer-events:none;z-index:99999;transition:transform .08s';
    document.body.appendChild(c);
    document.addEventListener('mousemove', e => { c.style.left = e.clientX + 'px'; c.style.top = e.clientY + 'px'; });
    document.addEventListener('mousedown', () => { c.style.transform = 'scale(.7)'; });
    document.addEventListener('mouseup', () => { c.style.transform = ''; });
  });`;

(async () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'hello-live-'));
  const rawDir = path.join(work, 'raw');
  const seqDir = path.join(work, 'seq');
  fs.mkdirSync(rawDir);
  fs.mkdirSync(seqDir);

  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
  const context = await browser.newContext({ viewport, deviceScaleFactor: scale });
  await context.addInitScript(cursorScript);
  const page = await context.newPage();

  const clickOn = async (locator) => {
    const box = await locator.boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 24 });
    await page.waitForTimeout(180);
    await page.mouse.down();
    await page.waitForTimeout(60);
    await page.mouse.up();
  };
  const replies = (n) =>
    page.waitForFunction((n) => document.querySelectorAll('.timing').length >= n, n, { timeout: 10_000 });

  await page.goto(url);
  await page.waitForSelector('[data-phx-main].phx-connected');
  await page.mouse.move(600, 640);

  // Lossless frame capture. Chrome only emits a frame when the page
  // repaints, so each frame keeps its timestamp for resampling below.
  const frames = [];
  const cdp = await context.newCDPSession(page);
  cdp.on('Page.screencastFrame', async ({ data, metadata, sessionId }) => {
    const file = path.join(rawDir, `${String(frames.length).padStart(5, '0')}.png`);
    fs.writeFileSync(file, Buffer.from(data, 'base64'));
    frames.push({ file, t: metadata.timestamp });
    await cdp.send('Page.screencastFrameAck', { sessionId }).catch(() => {});
  });
  await cdp.send('Page.startScreencast', {
    format: 'png',
    everyNthFrame: 1,
    maxWidth: viewport.width * scale,
    maxHeight: viewport.height * scale,
  });
  // Nudge a first frame out of an otherwise idle page.
  await page.mouse.move(601, 640);
  await page.waitForTimeout(900);

  // Type a name and greet all six languages at once.
  await clickOn(page.locator('#name'));
  await page.keyboard.press('Control+A');
  await page.keyboard.type('Portals', { delay: 110 });
  await page.waitForTimeout(400);
  await clickOn(page.getByRole('button', { name: 'Say hello in all six' }));
  await replies(6);
  await page.waitForTimeout(2200);

  // Change the name and greet one language at a time.
  await clickOn(page.locator('#name'));
  await page.keyboard.press('Control+A');
  await page.keyboard.type('LiveView', { delay: 110 });
  await page.waitForTimeout(300);
  for (const id of ['go', 'python']) {
    await clickOn(page.locator(`#lang-${id} button`));
    await page.waitForTimeout(1100);
  }
  await page.waitForTimeout(1800);
  const end = Date.now() / 1000;

  await cdp.send('Page.stopScreencast');
  await browser.close();

  // Resample the variable-rate capture to a constant frame rate with the
  // concat demuxer (each frame lasts until the next one), downscaling once.
  const list = frames
    .map((f, i) => {
      const next = i + 1 < frames.length ? frames[i + 1].t : Math.max(end, f.t + 0.1);
      return `file '${f.file}'\nduration ${(next - f.t).toFixed(4)}`;
    })
    .join('\n');
  const listFile = path.join(work, 'frames.txt');
  fs.writeFileSync(listFile, `${list}\nfile '${frames[frames.length - 1].file}'\n`);
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'concat', '-safe', '0', '-i', listFile,
    '-vf', `fps=${fps},scale=${outWidth}:-1:flags=lanczos`, path.join(seqDir, '%05d.png')]);

  const sequence = fs.readdirSync(seqDir).sort().map((f) => path.join(seqDir, f));
  execFileSync('gifski', ['--quiet', '--fps', String(fps), '--quality', '100', '--width', String(outWidth),
    '-o', out, ...sequence]);
  fs.rmSync(work, { recursive: true, force: true });

  console.log(`wrote ${out}: ${outWidth}px, ${sequence.length} frames at ${fps} fps, ` +
    `${(fs.statSync(out).size / 1024 / 1024).toFixed(1)} MiB (from ${frames.length} captured frames)`);
})();
