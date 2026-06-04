const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1440, height: 900 } });
  await p.goto('http://127.0.0.1:4000/', { waitUntil: 'networkidle' });
  await p.waitForTimeout(1000);
  const r = await p.evaluate(() => {
    const nav = document.querySelector('.tools-top-nav').getBoundingClientRect();
    const hero = document.querySelector('.hero').getBoundingClientRect();
    return { navTop: Math.round(nav.top), navBottom: Math.round(nav.bottom), navH: Math.round(nav.height), heroTop: Math.round(hero.top) };
  });
  console.log(JSON.stringify(r));
  await b.close();
})();
