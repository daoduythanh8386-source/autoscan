import asyncio, json, time
from playwright.async_api import async_playwright
OUT='/tmp/e2e'
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(args=['--use-fake-ui-for-media-stream','--use-fake-device-for-media-stream',
                                          '--use-file-for-fake-video-capture=/tmp/doc.y4m'])
        ctx = await b.new_context(viewport={'width':390,'height':844}, device_scale_factor=2, is_mobile=True, has_touch=True,
                                  permissions=['camera'], accept_downloads=True, locale='vi-VN')
        pg = await ctx.new_page()
        logs=[]; pg.on('console', lambda m: logs.append(f'{m.type}: {m.text}')); pg.on('pageerror', lambda e: logs.append('PAGEERROR: '+str(e)))
        await pg.goto('http://localhost:8765/'); await pg.wait_for_timeout(800)
        await pg.screenshot(path=f'{OUT}/1_home.png')
        await pg.click('#btnScan')
        # chờ tự động chụp
        t0=time.time(); n='0'
        while time.time()-t0<40:
            await pg.wait_for_timeout(500)
            n = await pg.inner_text('#camCount')
            if n!='0': break
        hint = await pg.inner_text('#camHint')
        await pg.screenshot(path=f'{OUT}/2_camera.png')
        print('trang tự chụp:', n, '| gợi ý:', hint, '| thời gian', round(time.time()-t0,1),'s')
        # đóng hộp thoại chất lượng nếu có
        if await pg.is_visible('#modal:not(.hidden)'):
            print('hộp thoại:', (await pg.inner_text('#sheet'))[:200].replace('\n',' '))
            await pg.click('#sheet [data-r="1"]')
        # nếu mở editor (không chắc góc) thì quay lại
        if await pg.is_visible('#editor.active'):
            print('-> app mở màn chỉnh góc'); await pg.click('#edBack'); await pg.wait_for_timeout(500)
        await pg.click('#camDone'); await pg.wait_for_timeout(1200)
        await pg.screenshot(path=f'{OUT}/3_doc.png')
        items = await pg.locator('.page-item').count(); print('số trang trong tài liệu:', items)
        # mở editor
        await pg.click('.page-item [data-a="edit"]'); await pg.wait_for_timeout(2500)
        await pg.screenshot(path=f'{OUT}/4_editor.png')
        await pg.click('.tabs button[data-tab="crop"]'); await pg.wait_for_timeout(800)
        await pg.screenshot(path=f'{OUT}/5_crop.png')
        print('khung tỷ lệ:', await pg.inner_text('#aspectInfo'))
        await pg.click('#edBack'); await pg.wait_for_timeout(1500)
        # xuất PDF
        await pg.click('#docExport'); await pg.wait_for_timeout(500)
        await pg.screenshot(path=f'{OUT}/6_export.png')
        async with pg.expect_download(timeout=60000) as dl:
            await pg.click('#exSave')
        d = await dl.value; await d.save_as(f'{OUT}/out.pdf'); print('PDF:', d.suggested_filename)
        await pg.wait_for_timeout(500)
        # JPG
        await pg.click('#exFormat button[data-v="jpg"]')
        async with pg.expect_download(timeout=60000) as dl:
            await pg.click('#exSave')
        d = await dl.value; await d.save_as(f'{OUT}/out.jpg'); print('JPG:', d.suggested_filename)
        await pg.click('#exFormat button[data-v="pdf"]'); await pg.click('#exPdfQ button[data-v="lossless"]')
        async with pg.expect_download(timeout=60000) as dl:
            await pg.click('#exSave')
        d = await dl.value; await d.save_as(f'{OUT}/out_lossless.pdf'); print('PDF lossless:', d.suggested_filename)
        await pg.wait_for_timeout(300)
        await pg.screenshot(path=f'{OUT}/7_export_done.png')
        # thư viện & tải lại trang (dữ liệu còn không)
        await pg.reload(); await pg.wait_for_timeout(1200)
        print('sau khi tải lại – tài liệu gần đây:', await pg.locator('#recent .doc-item').count())
        await pg.screenshot(path=f'{OUT}/8_home_after.png', full_page=True)
        await pg.click('[data-go="settings"] >> nth=0'); await pg.wait_for_timeout(600)
        await pg.screenshot(path=f'{OUT}/9_settings.png', full_page=True)
        print('\n'.join(l for l in logs if 'error' in l.lower() or 'PAGEERROR' in l) or 'Không có lỗi JavaScript')
        await b.close()
asyncio.run(main())
