import subprocess, sys, pathlib
from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).parent.resolve()
FPS, DUR = 30, 42
mode = sys.argv[1] if len(sys.argv) > 1 else "video"

with sync_playwright() as pw:
    b = pw.chromium.launch(channel="chrome")
    pg = b.new_page(viewport={"width": 1920, "height": 1080})
    errors = []
    pg.on("pageerror", lambda e: errors.append(str(e)))
    pg.goto((HERE / "promo.html").as_uri())
    pg.wait_for_function("window.ready === true")
    if mode == "stills":
        for t in map(float, sys.argv[2:]):
            pg.evaluate(f"render({t})")
            pg.screenshot(path=str(HERE / f"still_{t:05.2f}.png"))
    else:
        ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", str(FPS), "-i", "-",
                               "-i", str(HERE / "music.wav"), "-c:v", "libx264", "-preset", "slow", "-crf", "17",
                               "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart",
                               str(HERE / "ScreenBeam-promo.mp4")], stdin=subprocess.PIPE)
        for i in range(FPS * DUR):
            pg.evaluate(f"render({i / FPS})")
            ff.stdin.write(pg.screenshot(type="png"))
            if i % 150 == 0: print("frame", i, flush=True)
        ff.stdin.close(); ff.wait()
    print("errors:", errors)
    b.close()
