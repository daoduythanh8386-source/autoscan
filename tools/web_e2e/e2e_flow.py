import asyncio, time, sys
from playwright.async_api import async_playwright
OUT='/tmp/e2e'
async def wait_screen(pg, sid, t=60000): await pg.wait_for_selector(f'#{sid}.active', timeout=t)
async def wait_idle(pg):
    await pg.wait_for_function("document.querySelector('#modal').classList.contains('hidden')", timeout=90000)
async def run(name, fake_fail=False, camera=True, files=None):
    async with async_playwright() as p:
        args=['--use-fake-ui-for-media-stream','--use-fake-device-for-media-stream','--use-file-for-fake-video-capture=/tmp/doc.y4m']
        b = await p.chromium.launch(args=args)
        ctx = await b.new_context(viewport={'width':390,'height':844}, device_scale_factor=2, is_mobile=True, has_touch=True, permissions=['camera'], accept_downloads=True)
        if fake_fail: await ctx.add_init_script("window.createImageBitmap=()=>Promise.reject(new DOMException('An error occured reading the Blob argument to createImageBitmap','InvalidStateError'))")
        pg = await ctx.new_page(); errs=[]; pg.on('pageerror', lambda e: errs.append(str(e)))
        await pg.goto('http://localhost:8765/'); await pg.wait_for_timeout(500)
        if name=='camera': await pg.screenshot(path=f'{OUT}/f0_home_empty.png')
        T=time.time()
        if camera:
            await pg.click('#btnScan'); await wait_screen(pg,'camera')
            await pg.wait_for_timeout(1500); await pg.screenshot(path=f'{OUT}/f1_camera.png')
            await wait_screen(pg,'crop', 60000)
        else:
            await pg.set_input_files('#fileImport', files); await wait_screen(pg,'crop', 90000)
        t1=time.time(); await pg.wait_for_timeout(900)
        await pg.screenshot(path=f'{OUT}/f2_crop_{name}.png')
        n = len(files) if files else 1
        for i in range(n):
            await wait_screen(pg,'crop'); await pg.wait_for_timeout(400)
            await pg.click('#cropNext'); await wait_screen(pg,'filter')
            await pg.wait_for_selector('#filSpin.hidden', state='attached', timeout=30000); await pg.wait_for_timeout(1200)
            if i==0: await pg.screenshot(path=f'{OUT}/f3_filter_{name}.png')
            t2=time.time(); await pg.click('#filDone'); await wait_idle(pg)
            print(f'  trang {i+1}: hoàn tất A4 300DPI {time.time()-t2:.1f}s')
        await wait_screen(pg,'doc'); await pg.wait_for_timeout(600)
        await pg.screenshot(path=f'{OUT}/f4_doc_{name}.png')
        t3=time.time()
        async with pg.expect_download(timeout=60000) as dl: await pg.click('#docPdf')
        d=await dl.value; await d.save_as(f'{OUT}/flow_{name}.pdf')
        print(f'{name}: tới màn Cắt {t1-T:.1f}s | PDF {time.time()-t3:.1f}s | file {d.suggested_filename}')
        await pg.click('#docBack'); await pg.wait_for_timeout(700)
        await pg.screenshot(path=f'{OUT}/f5_home_{name}.png')
        print('  lỗi JS:', errs or 'không')
        await b.close()
async def main():
    await run('camera')
    await run('curved', camera=False, files=['/tmp/e2e/book.jpg','/tmp/e2e/curl.jpg'])
    await run('safari', fake_fail=True, camera=False, files=['/tmp/real/real.png'])
asyncio.run(main())
