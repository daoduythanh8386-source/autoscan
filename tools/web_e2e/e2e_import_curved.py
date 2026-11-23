import asyncio
from playwright.async_api import async_playwright
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        ctx = await b.new_context(viewport={'width':390,'height':844}, device_scale_factor=2, is_mobile=True, has_touch=True, accept_downloads=True)
        pg = await ctx.new_page(); errs=[]; pg.on('pageerror', lambda e: errs.append(str(e)))
        await pg.goto('http://localhost:8765/'); await pg.wait_for_timeout(600)
        await pg.set_input_files('#fileImport', ['/tmp/e2e/book.jpg','/tmp/e2e/curl.jpg'])
        await pg.wait_for_selector('#doc.active, #sheet [data-r="1"]', timeout=90000)
        if await pg.is_visible('#sheet [data-r="1"]') and not await pg.is_visible('#doc.active'):
            print('ghi chú:', (await pg.inner_text('#sheet')).replace('\n',' ')[:300]); await pg.click('#sheet [data-r="1"]')
        await pg.wait_for_selector('#doc.active', timeout=30000); await pg.wait_for_timeout(1200)
        await pg.wait_for_timeout(500)
        print('các trang:', [t.replace('\n',' | ') for t in await pg.locator('.page-item .info').all_inner_texts()])
        await pg.screenshot(path='/tmp/e2e/10_doc_curved.png')
        async with pg.expect_download(timeout=90000) as dl:
            await pg.click('#docExport'); await pg.wait_for_timeout(400); await pg.click('#exSave')
        d = await dl.value; await d.save_as('/tmp/e2e/curved.pdf')
        print('lỗi JS:', errs or 'không')
        await b.close()
asyncio.run(main())
