import assert from 'node:assert/strict';
import { detectBlockedPage, detectGalleryContext, parseResults } from '../src/parser.js';

const url = 'https://gall.dcinside.com/mgallery/board/lists/?id=lawschool&page=1';

async function fetchLive() {
  const response = await fetch(url, {
    headers: {
      'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36',
      'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
      'accept-language': 'ko-KR,ko;q=0.9,en-US;q=0.7,en;q=0.6'
    }
  });
  const html = await response.text();
  return { response, html };
}

test('live lawschool list is reachable and current parser sees post rows', async () => {
  const { response, html } = await fetchLive();
  assert.equal(response.status, 200, `live HTTP status=${response.status}; body=${html.slice(0, 240)}`);
  const blocked = detectBlockedPage(html, response.status);
  assert.equal(blocked.blocked, false, `blocked=${JSON.stringify(blocked)}; body=${html.slice(0, 240)}`);
  const context = detectGalleryContext(html, url);
  assert.equal(context.ok, true, `context=${JSON.stringify(context)}; body=${html.slice(0, 240)}`);
  assert.equal(context.galleryId, 'lawschool');
  const parsed = parseResults(html, url, 0);
  assert.equal(parsed.ok, true, `parse=${JSON.stringify(parsed.errors)} diagnostics=${JSON.stringify(parsed.diagnostics)} body=${html.slice(0, 400)}`);
  assert.ok(parsed.results.length > 0, 'no live post rows parsed');
});
