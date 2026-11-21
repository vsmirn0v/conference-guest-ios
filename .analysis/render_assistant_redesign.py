from PIL import Image, ImageDraw, ImageFont
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "design" / "assistant-talk-redesign-draft.png"
FONT = ROOT / ".analysis" / "SFNS.ttf"
S = 2
W, H = 1600, 1000

C = {
    "bg": (29, 29, 31),
    "sidebar": (32, 32, 34),
    "top": (31, 31, 33),
    "card": (39, 39, 42),
    "field": (34, 34, 37),
    "border": (61, 61, 66),
    "primary": (244, 244, 246),
    "secondary": (160, 160, 166),
    "tertiary": (108, 108, 116),
    "blue": (47, 126, 235),
    "orange": (224, 151, 71),
    "orange_text": (238, 171, 96),
    "green": (60, 200, 120),
    "black": (12, 12, 14),
}

im = Image.new("RGB", (W * S, H * S), C["bg"])
d = ImageDraw.Draw(im)
fonts = {}

def f(size, bold=False):
    key = (size, bold)
    if key not in fonts:
        font = ImageFont.truetype(str(FONT), size * S)
        if bold:
            try:
                font.set_variation_by_name("Semibold")
            except Exception:
                pass
        fonts[key] = font
    return fonts[key]

def b(box):
    return tuple(int(round(v * S)) for v in box)

def rect(box, fill, outline=None, width=1):
    d.rectangle(b(box), fill=fill, outline=outline, width=width * S)

def rr(box, radius, fill, outline=None, width=1):
    d.rounded_rectangle(b(box), radius=radius * S, fill=fill, outline=outline, width=width * S)

def line(points, fill, width=2):
    d.line([(int(x * S), int(y * S)) for x, y in points], fill=fill, width=width * S, joint="curve")

def circle(cx, cy, r, fill=None, outline=None, width=1):
    d.ellipse(b((cx-r, cy-r, cx+r, cy+r)), fill=fill, outline=outline, width=width*S)

def arc(box, start, end, fill, width=2):
    d.arc(b(box), start=start, end=end, fill=fill, width=width*S)

def poly(points, fill):
    d.polygon([(int(x*S), int(y*S)) for x, y in points], fill=fill)

def text(x, y, value, size=20, color=None, bold=False, anchor="lm"):
    d.text((int(x*S), int(y*S)), value, font=f(size, bold), fill=color or C["primary"], anchor=anchor)

def icon(kind, cx, cy, size=24, color=None):
    color = color or C["secondary"]
    u = size / 24.0
    def p(x, y): return (cx + x*u, cy + y*u)
    if kind == "home":
        line([p(-10,-1), p(0,-10), p(10,-1)], color)
        line([p(-7,-3), p(-7,10), p(7,10), p(7,-3)], color)
        line([p(-2,10), p(-2,3), p(2,3), p(2,10)], color)
    elif kind == "tray":
        rr((cx-10*u, cy-7*u, cx+10*u, cy+9*u), 3*u, None, color)
        line([p(-10,1), p(-4,1), p(-2,5), p(2,5), p(4,1), p(10,1)], color)
    elif kind == "star":
        pts=[]
        for i in range(10):
            a=-math.pi/2+i*math.pi/5
            r=10 if i%2==0 else 4.5
            pts.append(p(math.cos(a)*r, math.sin(a)*r))
        poly(pts, color)
    elif kind == "calendar":
        rr((cx-9*u,cy-8*u,cx+9*u,cy+9*u),2*u,None,color)
        line([p(-9,-2),p(9,-2)],color)
        line([p(-5,-11),p(-5,-5)],color)
        line([p(5,-11),p(5,-5)],color)
        for x in (-4,1,6):
            for y in (3,7): circle(*p(x,y),1.1*u,fill=color)
    elif kind == "clock":
        circle(cx,cy,10*u,outline=color,width=2)
        line([p(0,0),p(0,-6),p(5,-2)],color)
    elif kind == "gear":
        circle(cx,cy,7*u,outline=color,width=2)
        circle(cx,cy,2.3*u,outline=color,width=2)
        for i in range(8):
            a=i*math.pi/4
            line([p(math.cos(a)*8,math.sin(a)*8),p(math.cos(a)*11,math.sin(a)*11)],color)
    elif kind == "mic_off":
        rr((cx-3.5*u,cy-10*u,cx+3.5*u,cy+2*u),3.5*u,None,color)
        arc((cx-7*u,cy-5*u,cx+7*u,cy+8*u),0,180,color)
        line([p(0,8),p(0,12),p(-4,12),p(4,12)],color)
        line([p(-9,-10),p(9,11)],color,2)
    elif kind == "speaker":
        poly([p(-10,-4),p(-6,-4),p(-1,-9),p(-1,9),p(-6,4),p(-10,4)],color)
        arc((cx-3*u,cy-7*u,cx+10*u,cy+7*u),-55,55,color)
        arc((cx-1*u,cy-11*u,cx+15*u,cy+11*u),-52,52,color)
    elif kind == "pip":
        rr((cx-11*u,cy-8*u,cx+11*u,cy+8*u),2*u,None,color)
        rr((cx+1*u,cy+0*u,cx+8*u,cy+6*u),1.5*u,color)
    elif kind == "waveform":
        for x,h in [(-9,8),(-5,15),(-1,24),(3,17),(7,10)]:
            line([p(x,-h/2),p(x,h/2)],color,2)
    elif kind == "bolt":
        poly([p(2,-12),p(-8,2),p(-1,2),p(-3,12),p(9,-4),p(2,-4)],color)
    elif kind == "chevron":
        line([p(-4,-2),p(0,3),p(4,-2)],color,2)
    elif kind == "lock":
        rr((cx-7*u,cy-1*u,cx+7*u,cy+9*u),2*u,None,color)
        arc((cx-5*u,cy-10*u,cx+5*u,cy+3*u),180,360,color)
    elif kind == "cloud":
        arc((cx-11*u,cy-3*u,cx+1*u,cy+9*u),80,270,color)
        arc((cx-5*u,cy-10*u,cx+9*u,cy+5*u),180,345,color)
        arc((cx+2*u,cy-4*u,cx+12*u,cy+7*u),200,80,color)
        line([p(-9,6),p(9,6)],color)
    elif kind == "plus":
        line([p(-8,0),p(8,0)],color)
        line([p(0,-8),p(0,8)],color)

# Window and native chrome
rect((0,0,W,H), C["bg"])
rect((0,0,320,H), C["sidebar"])
rect((0,0,W,64), C["top"])
line([(320,64),(320,H)], C["border"], 1)
line([(320,64),(W,64)], C["border"], 1)
for x,color in [(30,(237,95,86)),(58,(232,190,57)),(86,(92,194,76))]:
    circle(x,32,10,fill=color)
text(360,32,"Ассистент",22,bold=True)
rr((1530,14,1574,52),10,C["card"])
icon("plus",1552,33,22,C["secondary"])

# Sidebar: active meeting and destinations
text(20,98,"Идёт встреча",16,C["tertiary"],bold=True)
icon("mic_off",42,143,23,(84,153,220))
text(74,137,"d2v2",21,bold=True)
text(74,164,"Подключено · микрофон выключен",14,C["secondary"])
icon("speaker",281,145,21,C["secondary"])

nav=[("home","Главная"),("tray","Ассистент"),("star","Избранное"),("calendar","Календарь"),("clock","Недавние встречи"),("gear","Настройки")]
for i,(ic,label) in enumerate(nav):
    y=238+i*54
    if label=="Ассистент":
        rr((12,y-24,308,y+24),12,C["blue"])
    icon(ic,42,y,24,(255,255,255) if label=="Ассистент" else (66,155,230))
    text(76,y,label,21,(255,255,255) if label=="Ассистент" else C["primary"],bold=label=="Ассистент")
text(20,566,"Избранное",16,C["tertiary"],bold=True)
for i,label in enumerate(["Видеовстреча","CTO Daily","Devops2","Inference"]):
    y=612+i*49
    icon("star",40,y,23,(67,155,232))
    text(74,y,label,20)
icon("cloud",34,964,24,C["secondary"])
text(66,964,"Всё синхронизировано",16,C["secondary"],bold=True)

# Assistant sections and quick actions
seg_x,seg_y=734,80
segments=[("Моменты",142),("Итоги",108),("Разговор",154)]
rr((seg_x-5,seg_y-5,seg_x+414,seg_y+43),11,(42,42,45))
x=seg_x
for label,w in segments:
    if label=="Разговор":
        rr((x,seg_y,x+w,seg_y+38),9,C["orange"])
    text(x+w/2,seg_y+19,label,18,(40,34,29) if label=="Разговор" else C["secondary"],bold=label=="Разговор",anchor="mm")
    x+=w+5
icon("bolt",1320,100,19,C["orange_text"])
text(1337,100,"Быстрые действия",17,C["orange_text"])
icon("chevron",1533,100,16,C["orange_text"])

# Docked active-meeting context: layout reserves this space; nothing floats over Talk.
rr((352,142,1568,250),16,C["card"],C["border"])
rr((370,158,510,234),10,C["black"])
# A quiet placeholder matching the existing video preview.
text(440,192,"d2v2",18,C["secondary"],anchor="mm")
rr((380,168,426,188),9,(32,85,56))
circle(390,178,3,fill=C["green"])
text(400,178,"LIVE",10,(170,237,193),bold=True,anchor="mm")
text(532,177,"d2v2",24,bold=True)
icon("chevron",607,178,17,C["secondary"])
circle(536,213,4,fill=C["green"])
text(550,213,"Активная встреча · микрофон выключен",16,C["secondary"])
rr((1000,170,1052,222),12,C["field"])
icon("mic_off",1026,196,23,C["primary"])
rr((1064,170,1116,222),12,C["field"])
icon("speaker",1090,196,22,C["primary"])
rr((1130,170,1334,222),12,(74,54,37))
text(1232,196,"Открыть встречу",18,C["orange_text"],bold=True,anchor="mm")
rr((1348,170,1552,222),12,C["field"])
icon("pip",1376,196,21,C["primary"])
text(1396,196,"Мини-встреча",17,C["primary"])

# Conversation empty state
icon("waveform",960,403,46,C["secondary"])
text(960,467,"Поговорить с Ассистентом",30,bold=True,anchor="mm")
text(960,514,"Спросите о d2v2, попросите прочитать чат или выполнить действие.",19,C["secondary"],anchor="mm")
text(960,548,"Введите запрос или удерживайте ⌥Space. Речь распознаётся на этом Mac.",17,C["tertiary"],anchor="mm")

# A stable bottom composer, with no preview or controls layered above it.
line([(320,830),(W,830)],C["border"],1)
icon("lock",370,857,17,C["tertiary"])
text(390,857,"Контекст: d2v2 · отправка во встречу требует подтверждения",15,C["secondary"])
rr((352,880,1568,954),15,C["field"],C["border"])
text(380,917,"Спросите о встрече или попросите выполнить действие…",19,C["tertiary"])
rr((1240,892,1382,942),11,C["card"])
icon("waveform",1266,917,19,C["secondary"])
text(1290,917,"Слушать",17,C["primary"])
rr((1394,892,1552,942),11,C["orange"])
text(1473,917,"Спросить  ↑",17,(39,32,25),bold=True,anchor="mm")
text(366,979,"↩ — отправить запрос",14,C["tertiary"])
text(1560,979,"⌥Space — голосовой ввод",14,C["tertiary"],anchor="rm")

im = im.resize((W,H), Image.Resampling.LANCZOS)
OUT.parent.mkdir(parents=True, exist_ok=True)
im.save(OUT, quality=95)
print(OUT)
