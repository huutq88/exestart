# ExeStart

Chạy ứng dụng Windows (`.exe`, `.msi`, `.bat`, `.lnk`) trực tiếp trên macOS, **không cần máy ảo, không cần bản quyền Windows**.

ExeStart quản lý [Wine](https://www.winehq.org/) giúp bạn: tự tải bản Wine build sẵn cho macOS, tạo các "bottle" (mỗi bottle là một ổ `C:` Windows riêng), chạy chương trình, cài thư viện Windows qua winetricks và tạo shortcut `.app` để mở chương trình như app Mac.

Gồm hai phần dùng chung một lõi (`ExeStartKit`):

- **ExeStart.app** — giao diện SwiftUI: kéo thả `.exe`, danh sách chương trình, cài thư viện, chỉnh cấu hình.
- **`exestart`** — CLI cho người thích Terminal hoặc muốn viết script.

> Dự án không chính thức, không liên quan tới Microsoft, WineHQ hay CodeWeavers.

## Yêu cầu

- macOS 14 trở lên, Apple Silicon hoặc Intel
- Apple Silicon cần Rosetta 2: `softwareupdate --install-rosetta --agree-to-license`
- Build từ mã nguồn: Xcode 16+ / Swift 6
- Tuỳ chọn, cho winetricks: `brew install cabextract`

## Cài đặt

```bash
git clone <repo-url> exestart && cd exestart
./scripts/build-app.sh --install
```

Lệnh trên tạo `~/Applications/ExeStart.app` và `~/.local/bin/exestart`. Bỏ `--install` để chỉ build vào `dist/`.

## Dùng app

1. Mở **ExeStart** → bấm **Tải và cài Wine** (khoảng 185 MB, làm một lần). App tự tạo bottle `Default`.
2. Kéo file `.exe`/`.msi` vào cửa sổ, hoặc bấm **Chạy file .exe…** (⌘O).
3. Sau khi cài, chương trình hiện trong tab **Chương trình**. Nháy đúp để mở, chuột phải → **Tạo app trong Launchpad**.
4. Trong Finder: chuột phải file `.exe` → **Open With → ExeStart**.

## Dùng CLI

```bash
exestart doctor                                  # kiểm tra Rosetta, Wine, cabextract
exestart runtime install                         # tải Wine stable mới nhất
exestart bottle create "Van phong" --windows win10
exestart run ~/Downloads/setup.exe -b "Van phong"
exestart programs -b "Van phong"                 # liệt kê chương trình đã cài
exestart shortcut "~/Library/Application Support/ExeStart/Bottles/Van phong/prefix/drive_c/Program Files/App/App.exe" -b "Van phong"
exestart tricks corefonts vcrun2022 -b "Van phong"
exestart tool winecfg -b "Van phong"             # winecfg, regedit, taskmgr, control, uninstaller, explorer, cmd
exestart bottle set "Van phong" --retina on --dpi 144
exestart kill --all                              # tắt mọi chương trình đang treo
```

Truyền tham số cho chương trình sau `--`: `exestart run app.exe -- /silent`.
Gỡ lỗi: thêm `-v` để bật log Wine chi tiết. Mỗi lần chạy đều ghi log vào thư mục `logs/` của bottle.

## Dữ liệu nằm ở đâu

```
~/Library/Application Support/ExeStart/
├── Runtimes/wine-stable-11.0_1/   # các bản Wine
├── Bottles/<tên>/
│   ├── bottle.json                # cấu hình
│   ├── prefix/drive_c/            # ổ C: của Windows
│   └── logs/
├── Cache/                         # winetricks, file tải dở
└── settings.json                  # runtime mặc định
~/Applications/ExeStart/*.app      # shortcut đã tạo
```

Đặt `EXESTART_HOME=/đường/dẫn` để dùng thư mục khác (tiện khi test).

## Cách hoạt động

- **Wine** dịch lệnh gọi Windows API sang macOS. Đây không phải giả lập hay máy ảo, chương trình chạy như tiến trình bình thường. Trên Apple Silicon, mã x86 chạy qua Rosetta 2.
- Bản Wine lấy từ [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds), chính là bản mà cask `wine-stable` của Homebrew dùng trước khi Homebrew tắt cask này (01/09/2026).
- Mỗi bottle là một `WINEPREFIX` riêng, nên chương trình trong bottle này không ảnh hưởng bottle khác.

## Giới hạn

- Không phải app nào cũng chạy được. Xem độ tương thích tại [Wine AppDB](https://appdb.winehq.org/).
- Phần mềm có anti-cheat cấp kernel, driver thiết bị, hoặc phụ thuộc sâu vào dịch vụ Windows (Office 365 bản mới, Visual Studio) thường không chạy.
- Game DirectX 10–12 cần D3DMetal hoặc DXVK, phiên bản này chưa tích hợp.
- ExeStart chạy file `.exe`, **không build** file `.exe`. Muốn build `.exe` trên Mac, dùng trình biên dịch chéo (mingw-w64, `GOOS=windows`, `dotnet publish -r win-x64`…) rồi chạy thử bằng `exestart run`.

## Phát triển

```bash
swift build                 # build tất cả
swift test                  # unit test cho ExeStartKit
swift run exestart --help
swift run ExeStartApp       # mở app không cần đóng gói
```

```
Sources/
├── ExeStartKit/   # lõi: Runtime, Bottle, Wine, Winetricks, Shortcut
├── exestart/      # CLI (swift-argument-parser)
└── ExeStartApp/   # app SwiftUI
scripts/build-app.sh
```

## Giấy phép

Chưa chọn. Wine dùng giấy phép LGPL và chỉ được tải về lúc chạy, không phân phối kèm repo này.
