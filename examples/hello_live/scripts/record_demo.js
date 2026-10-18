// Records demo/hello_live.gif from a running `mix phx.server`.
//
//     cd examples/hello_live && mix phx.server &
//     NODE_PATH=$(npm root -g) node scripts/record_demo.js
//
// Needs the `playwright` npm package (with Chromium) and ffmpeg. Set
// CHROMIUM_PATH to use an existing Chromium build.
const { chromium } = require('playwright');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const url = process.env.DEMO_URL || 'http://localhost:4000/';
const out = path.resolve(__dirname, '../demo/hello_live.gif');
const size = { width: 1180, height: 720 };

// Playwright videos don't show the mouse, so draw one.
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
  const videoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hello-live-'));
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
  const context = await browser.newContext({ viewport: size, recordVideo: { dir: videoDir, size } });
  await context.addInitScript(cursorScript);
  const page = await context.newPage();

  const clickOn = async (locator) => {
    const box = await locator.boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 18 });
    await page.waitForTimeout(150);
    await page.mouse.down();
    await page.mouse.up();
  };
  const replies = (n) =>
    page.waitForFunction((n) => document.querySelectorAll('.timing').length >= n, n, { timeout: 10_000 });

  await page.goto(url);
  await page.waitForSelector('[data-phx-main].phx-connected');
  await page.mouse.move(600, 640);
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
  await page.waitForTimeout(1500);

  await context.close();
  await browser.close();

  const [video] = fs.readdirSync(videoDir).filter((f) => f.endsWith('.webm'));
  const input = path.join(videoDir, video);
  // Two-pass palette for a small, clean GIF; trim the blank first frames.
  const filters = 'fps=12,scale=900:-1:flags=lanczos';
  const palette = path.join(videoDir, 'palette.png');
  execFileSync('ffmpeg', ['-y', '-ss', '0.6', '-i', input, '-vf', `${filters},palettegen=stats_mode=diff`, palette], { stdio: 'ignore' });
  execFileSync('ffmpeg', ['-y', '-ss', '0.6', '-i', input, '-i', palette, '-lavfi',
    `${filters} [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle`, out], { stdio: 'ignore' });
  console.log(`wrote ${out} (${(fs.statSync(out).size / 1024).toFixed(0)} KiB)`);
})();
