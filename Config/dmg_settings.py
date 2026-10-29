# dmgbuild の設定（make dmg が使う）。dmg を開いたときのウィンドウの見た目を決める。
# アプリと背景とディスクのアイコンの場所は Makefile から -D app=… icon=… background=… で渡す。
# 背景（Design/dmg/background.tiff）は make_background.py が書き出す。中身は 600×370pt で、
# アイコンの中心の座標はそちらの APP_X・APPS_X・ICON_Y と合わせる。

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}

icon = defines["icon"]  # 開いたときのディスクのアイコン（アプリのアイコン）
background = defines["background"]

format = "ULFO"

# 高さは背景の 370pt に題の 32pt を足す
window_rect = ((200, 160), (600, 402))
icon_size = 128
text_size = 13
icon_locations = {
    "MDYomitoki.app": (150, 160),
    "Applications": (450, 160),
}
