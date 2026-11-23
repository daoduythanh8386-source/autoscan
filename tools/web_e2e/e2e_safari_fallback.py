import asyncio
from playwright.async_api import async_playwright
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        ctx = await b.new_context(viewport={'width':390,'height':844}, device_scale_factor=2, is_mobile=True, has_touch=True)
        # Giả lập lỗi Safari: createImageBitmap(Blob) luôn thất bại
        await ctx.add_init_script("window.createImageBitmap = () => Promise.reject(new DOMException('An error occured reading the Blob argument to createImageBitmap','InvalidStateError'));")
        pg = await ctx.new_page(); errs=[]; pg.on('pageerror', lambda e: errs.append(str(e)))
        await pg.goto('http://localhost:8765/'); await pg.wait_for_timeout(600)
        await pg.screenshot(path='/tmp/e2e/n1_home.png')
        await pg.set_input_files('#fileImport', ['/tmp/real/real.png'])
        await pg.wait_for_selector('#doc.active, #sheet [data-r="1"]', timeout=60000)
        if await pg.is_visible('#sheet [data-r="1"]') and not await pg.is_visible('#doc.active'):
            print('ghi chú:', (await pg.inner_text('#sheet')).replace('\n',' ')[:200]); await pg.click('#sheet [data-r="1"]')
        await pg.wait_for_selector('#doc.active'); await pg.wait_for_timeout(800)
        print('trang:', [t.replace('\n',' | ') for t in await pg.locator('.page-item .info').all_inner_texts()])
        await pg.click('.page-item [data-a="edit"]'); await pg.wait_for_timeout(1500)
        await pg.click('.tabs button[data-tab="crop"]'); await pg.wait_for_timeout(700)
        await pg.screenshot(path='/tmp/e2e/n2_crop.png')
        await pg.click('[data-act="snap"]'); await pg.wait_for_timeout(2500)
        print('sau bắt mép – toast:', await pg.inner_text('#toast'))
        await pg.click('.tabs button[data-tab="light"]'); await pg.wait_for_timeout(1500)
        await pg.screenshot(path='/tmp/e2e/n3_light.png')
        # kéo thanh trượt độ sáng → xem trước tức thì
        s = pg.locator('input[data-k="brightness"]')
        await s.evaluate("e => { e.dispatchEvent(new Event('pointerdown')); e.value = 0.3; e.dispatchEvent(new Event('input')); }")
        await pg.wait_for_timeout(250); await s.evaluate("e => e.dispatchEvent(new Event('change'))"); await pg.wait_for_timeout(1200)
        await pg.click('.tabs button[data-tab="color"]'); await pg.wait_for_timeout(1500)
        await pg.screenshot(path='/tmp/e2e/n4_color.png')
        await pg.click('[data-act="done"]'); await pg.wait_for_timeout(1500)
        async with pg.expect_download(timeout=60000) as dl:
            await pg.click('#docExport'); await pg.wait_for_timeout(300); await pg.click('#exSave')
        d = await dl.value; await d.save_as('/tmp/e2e/real.pdf'); print('PDF xuất được:', d.suggested_filename)
        print('lỗi JS:', errs or 'không')
        await b.close()
asyncio.run(main())
