# Sprite source PNGs

Each PNG here is a single horizontal strip — N equal-width frames of one chibi state on a white background. `scripts/make_gifs.py` slices them, keys out the white via the magenta-key trick, and writes animated GIFs into `assets/gifs/`.

| File | Frames | State |
|---|---|---|
| `idle_blink.png` | 6 | 站立眨眼 |
| `coding.png` | 6 | 抱键盘敲代码 |
| `peek.png` | 8 | 探出窗口偷看 |
| `loading.png` | 6 | 抱进度条等待 |
| `fix_bug.png` | 6 | 拿扳手修 bug |
| `error_shrug.png` | 8 | 举 ERROR 牌摊手 |
| `celebrate.png` | 5 | 跳 100% 庆祝 |
| `supervise.png` | 8 | 叉腰盯着 |
| `sleep.png` | 4 | 趴枕头 ZZZ |

替换素材时保持文件名和帧数一致；要改帧数 / 帧时长 / 是否回弹，去改 `scripts/make_gifs.py` 顶部的 `STATES` 表。
