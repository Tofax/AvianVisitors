#!/usr/bin/env python3

from pathlib import Path
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

from PIL import Image
from playwright.sync_api import sync_playwright

URL = "http://127.0.0.1/"

OUTPUT = Path("/home/ferran/BirdSongs/Extracted/frame/frame.png")
RAW = OUTPUT.parent / ".frame.raw.png"
TMP = OUTPUT.parent / ".frame.tmp.png"

# Imatge que volem mostrar quan no hi ha ocells.
EMPTY_IMAGE = Path("/home/ferran/BirdNET-Pi/avian/frontend/nest.webp")

VIEW_W = 800
VIEW_H = 480

# Només ocells de l'última hora
RECENT_HOURS = 1

# Text que apareix quan no hi ha ocells
EMPTY_TEXT = "no s'han detectat ocells en aquest període"

# Zona aproximada del collage quan HI HA ocells
BIRDS_CROP_X = 85
BIRDS_CROP_Y = 155
BIRDS_CROP_W = 625
BIRDS_CROP_H = 245

# Marges i ajustos del collage d'ocells
BIRDS_MARGIN = 8
BIRDS_AUTO_PAD = 12
BIRDS_TRIM_THRESHOLD = 245
BIRDS_WHITE_THRESHOLD = 250

# Mida màxima del niu en estat buit
EMPTY_TARGET_W = 560
EMPTY_TARGET_H = 360
EMPTY_WHITE_THRESHOLD = 253

OUTPUT.parent.mkdir(parents=True, exist_ok=True)


def auto_trim_near_white(
    img: Image.Image,
    threshold: int = 245,
    pad: int = 12,
) -> Image.Image:
    """
    Retalla vores gairebé blanques.
    Només s'utilitza quan hi ha ocells.
    """
    gray = img.convert("L")
    mask = gray.point(lambda p: 255 if p < threshold else 0)

    bbox = mask.getbbox()
    if not bbox:
        return img

    left, top, right, bottom = bbox

    left = max(0, left - pad)
    top = max(0, top - pad)
    right = min(img.width, right + pad)
    bottom = min(img.height, bottom + pad)

    return img.crop((left, top, right, bottom))


def force_pure_white_background(
    img: Image.Image,
    threshold: int,
) -> Image.Image:
    """
    Converteix a blanc pur els píxels gairebé blancs.
    Això evita tramats/puntets al fons de l'e-paper.
    """
    img = img.convert("RGB")
    pixels = img.load()

    for y in range(img.height):
        for x in range(img.width):
            r, g, b = pixels[x, y]
            if r >= threshold and g >= threshold and b >= threshold:
                pixels[x, y] = (255, 255, 255)

    return img


def render_empty_state() -> Image.Image:
    """
    Genera directament el frame buit a partir de la imatge del niu,
    sense dependre de cap captura de pantalla del navegador.
    """
    if not EMPTY_IMAGE.exists():
        raise FileNotFoundError(f"No existeix la imatge del niu: {EMPTY_IMAGE}")

    nest = Image.open(EMPTY_IMAGE).convert("RGBA")

    # Si té transparència, retallem el bounding box real del contingut.
    alpha = nest.getchannel("A")
    bbox = alpha.getbbox()
    if bbox:
        nest = nest.crop(bbox)

    scale = min(
        EMPTY_TARGET_W / nest.width,
        EMPTY_TARGET_H / nest.height,
    )

    new_w = max(1, round(nest.width * scale))
    new_h = max(1, round(nest.height * scale))

    nest = nest.resize(
        (new_w, new_h),
        Image.Resampling.LANCZOS,
    )

    canvas = Image.new(
        "RGB",
        (VIEW_W, VIEW_H),
        (255, 255, 255),
    )

    x = (VIEW_W - new_w) // 2
    y = (VIEW_H - new_h) // 2

    canvas.paste(nest, (x, y), nest)

    canvas = force_pure_white_background(
        canvas,
        threshold=EMPTY_WHITE_THRESHOLD,
    )

    return canvas


def filter_recent_to_last_hour(route):
    """
    Força l'API recent a utilitzar només l'última hora,
    sense modificar el comportament normal del frontend.
    """
    url = route.request.url

    if "birdnet-api.php" in url and "action=recent" in url:
        parts = urlsplit(url)
        query = dict(parse_qsl(parts.query))
        query["hours"] = str(RECENT_HOURS)

        filtered_url = urlunsplit((
            parts.scheme,
            parts.netloc,
            parts.path,
            urlencode(query),
            parts.fragment,
        ))

        print(f"Recent birds URL: {filtered_url}")
        route.continue_(url=filtered_url)
    else:
        route.continue_()


def save_canvas(canvas: Image.Image):
    canvas.save(TMP)
    TMP.replace(OUTPUT)


with sync_playwright() as p:
    browser = p.chromium.launch(
        headless=True,
    )

    page = browser.new_page(
        viewport={
            "width": VIEW_W,
            "height": VIEW_H,
        },
        device_scale_factor=1,
    )

    page.route("**/*", filter_recent_to_last_hour)
    page.set_default_timeout(120_000)

    page.goto(
        URL,
        wait_until="networkidle",
        timeout=120_000,
    )

    # Temps perquè acabin de carregar dades, il·lustracions i layout
    page.wait_for_timeout(5000)

    page_text = page.locator("body").inner_text().lower()
    is_empty = EMPTY_TEXT in page_text

    if is_empty:
        browser.close()

        canvas = render_empty_state()
        save_canvas(canvas)

        RAW.unlink(missing_ok=True)

        print(f"Frame generated: {OUTPUT}")
        print(f"Recent hours: {RECENT_HOURS}")
        print("Empty state: True")
        print(f"Frame size: {VIEW_W}x{VIEW_H}")
        raise SystemExit(0)

    # Cas normal: hi ha ocells
    page.screenshot(
        path=str(RAW),
        clip={
            "x": BIRDS_CROP_X,
            "y": BIRDS_CROP_Y,
            "width": BIRDS_CROP_W,
            "height": BIRDS_CROP_H,
        },
        timeout=120_000,
    )

    browser.close()


# Processament del collage d'ocells
content = Image.open(RAW).convert("RGB")

content = auto_trim_near_white(
    content,
    threshold=BIRDS_TRIM_THRESHOLD,
    pad=BIRDS_AUTO_PAD,
)

target_w = VIEW_W - 2 * BIRDS_MARGIN
target_h = VIEW_H - 2 * BIRDS_MARGIN

scale = min(
    target_w / content.width,
    target_h / content.height,
)

new_w = max(1, round(content.width * scale))
new_h = max(1, round(content.height * scale))

content = content.resize(
    (new_w, new_h),
    Image.Resampling.LANCZOS,
)

canvas = Image.new(
    "RGB",
    (VIEW_W, VIEW_H),
    (255, 255, 255),
)

canvas.paste(
    content,
    (
        (VIEW_W - new_w) // 2,
        (VIEW_H - new_h) // 2,
    ),
)

canvas = force_pure_white_background(
    canvas,
    threshold=BIRDS_WHITE_THRESHOLD,
)

save_canvas(canvas)

RAW.unlink(missing_ok=True)

print(f"Frame generated: {OUTPUT}")
print(f"Recent hours: {RECENT_HOURS}")
print("Empty state: False")
print(f"Rendered content: {new_w}x{new_h}")
print(f"Frame size: {VIEW_W}x{VIEW_H}")
