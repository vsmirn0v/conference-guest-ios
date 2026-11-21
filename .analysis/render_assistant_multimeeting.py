from pathlib import Path

# Reuse the draft's native-style drawing helpers, before it renders the first screen.
source = (Path(__file__).parent / "render_assistant_redesign.py").read_text()
exec(source.split("# Window and native chrome")[0], globals())
OUT = ROOT / "design" / "assistant-talk-multiple-meetings-draft.png"

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

# The sidebar remains the only active-meeting list and owns meeting media controls.
text(20,88,"Активные встречи · 3",16,C["tertiary"],bold=True)
meetings=[("d2v2","Микрофон включён"),("CTO Daily","Только прослушивание"),("Devops2","Без звука")]
for i,(title,status) in enumerate(meetings):
    y=126+i*58
    icon("mic_off" if i != 0 else "waveform",38,y,20,(84,153,220) if i != 0 else C["green"])
    text(68,y-9,title,19,bold=True)
    text(68,y+14,status,13,C["secondary"])
    icon("speaker",280,y,19,C["secondary"])

nav=[("home","Главная"),("tray","Ассистент"),("star","Избранное"),("calendar","Календарь"),("clock","Недавние встречи"),("gear","Настройки")]
for i,(ic,label) in enumerate(nav):
    y=340+i*52
    if label=="Ассистент":
        rr((12,y-23,308,y+23),12,C["blue"])
    icon(ic,42,y,23,(255,255,255) if label=="Ассистент" else (66,155,230))
    text(76,y,label,20,(255,255,255) if label=="Ассистент" else C["primary"],bold=label=="Ассистент")
text(20,680,"Избранное",16,C["tertiary"],bold=True)
for i,label in enumerate(["Видеовстреча","Inference"]):
    y=722+i*47
    icon("star",40,y,22,(67,155,232))
    text(74,y,label,19)
icon("cloud",34,964,24,C["secondary"])
text(66,964,"Всё синхронизировано",16,C["secondary"],bold=True)

# Assistant sections; no second meeting list or automatic video surface.
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
line([(320,132),(W,132)],C["border"],1)

icon("waveform",960,403,46,C["secondary"])
text(960,467,"Поговорить с Ассистентом",30,bold=True,anchor="mm")
text(960,514,"Спросите о d2v2 или выберите другую встречу в поле ниже.",19,C["secondary"],anchor="mm")
text(960,548,"Введите запрос или удерживайте ⌥Space. Речь распознаётся на этом Mac.",17,C["tertiary"],anchor="mm")

# The only added UI: an explicit command target attached to the composer.
line([(320,830),(W,830)],C["border"],1)
rr((352,840,586,874),9,C["card"],C["border"])
text(368,857,"Для Ассистента: d2v2",15,C["primary"])
icon("chevron",564,857,14,C["secondary"])
text(606,857,"3 встречи подключены · переключение не меняет микрофон или звук",14,C["secondary"])
rr((352,880,1568,954),15,C["field"],C["border"])
text(380,917,"Спросите о d2v2 или попросите выполнить действие…",19,C["tertiary"])
rr((1240,892,1382,942),11,C["card"])
icon("waveform",1266,917,19,C["secondary"])
text(1290,917,"Слушать",17,C["primary"])
rr((1394,892,1552,942),11,C["orange"])
text(1473,917,"Спросить  ↑",17,(39,32,25),bold=True,anchor="mm")
text(366,974,"↩ — отправить запрос",14,C["tertiary"])
text(1560,974,"Отправляемые действия всегда подтверждают выбранную встречу",14,C["tertiary"],anchor="rm")

im = im.resize((W,H), Image.Resampling.LANCZOS)
OUT.parent.mkdir(parents=True, exist_ok=True)
im.save(OUT, quality=95)
print(OUT)
