# Plan triển khai PrasenzPrinter cho Windows

## 1. Mục tiêu và quyết định kỹ thuật

Thêm một app Windows trong cùng repo, có UI nhỏ ở system tray tương tự app macOS. Các backend hiện tại tiếp tục gửi PDF qua HTTP hoặc Cloudflare Tunnel bằng API hiện có.

| Hạng mục | Quyết định |
| --- | --- |
| App Windows | C# + WinForms, chạy trong phiên người dùng |
| Runtime | .NET 10 LTS; app target `net10.0-windows`, core target `net10.0` |
| HTTP server | ASP.NET Core/Kestrel được host bên trong tray app |
| In PDF | Gọi SumatraPDF portable qua một adapter riêng |
| Tunnel | App quản lý subprocess `cloudflared.exe` |
| Phân phối | ZIP self-contained trước, installer per-user sau |
| Kiến trúc v1 | `win-x64` |
| Tự khởi động | Registry `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` |
| Tương thích backend | Giữ endpoint, headers, JSON response và ý nghĩa enqueue của macOS |

Target nghiệm thu ban đầu: Windows 10 22H2 x64 và Windows 11 x64. Chốt thêm edition/build Windows 10 thực tế của máy khách ở giai đoạn 0. Khả năng chạy trên máy mục tiêu phải được kiểm tra với đúng bộ .NET, cloudflared, SumatraPDF và driver được đóng gói; self-contained không tự bảo đảm mọi phiên bản Windows 10 đều chạy được.

Phạm vi v1 là tray app: hoạt động sau khi user đăng nhập, dùng các máy in user đó thấy được. Các server gọi tới là HTTP clients, không cần chạy cùng OS với app. Windows Service, Windows x86/ARM64, printer alias và một API print-options mới là các hạng mục bổ sung sau v1 nếu cần.

## 2. Baseline từ code hiện tại

Nguồn tham chiếu chính:

- `src-swift/AppDelegate.swift`: UI, settings, print queue, tunnel, HTTP routes.
- `src-swift/HttpServer.swift`: HTTP listener/parser dựa trên Apple Network framework.
- `src-swift/NewRelicLogger.swift`: gửi log theo batch, có `p-req-id`.
- `scripts/build.sh`: build Swift universal binary và đóng gói `.app`.
- `README.md`: hướng dẫn sử dụng và ví dụ request.

Các chi tiết cần dùng code làm chuẩn thay vì chỉ dựa vào README:

1. `POST /print` trả thành công ngay sau enqueue, in chạy bất đồng bộ.
2. Queue được tách theo máy in; hiện mỗi máy in cho phép tối đa 3 subprocess đồng thời.
3. `queueLength` chỉ đếm job đang chờ, không tính job đang xử lý.
4. Header `p-req-id` được chuyển vào log.
5. Tunnel có retry/backoff, xử lý network chưa sẵn sàng khi login và reconnect sau sleep/wake.
6. Settings có `TUNNEL_TOKEN`, `PORT`, `NEW_RELIC_LICENSE_KEY`; `PORT` hiện lưu dạng string.

## 3. Cấu trúc repo

Thêm `src-windows/` bên cạnh `src-swift/`. Cấu trúc hiện tại đủ để mở rộng; chưa cần di chuyển source macOS để triển khai Windows.

```text
prasenz-print-client/
├── src-swift/                         # App macOS hiện tại
├── src-windows/
│   ├── PrasenzPrinter.sln
│   ├── global.json                    # Pin SDK được kiểm chứng
│   ├── Directory.Build.props
│   ├── PrasenzPrinter.Core/
│   │   ├── Configuration/
│   │   ├── Http/
│   │   ├── Printing/
│   │   ├── Tunnel/
│   │   └── Logging/
│   ├── PrasenzPrinter.Windows/
│   │   ├── Program.cs
│   │   ├── TrayApplicationContext.cs
│   │   ├── UI/
│   │   ├── Printing/
│   │   ├── Startup/
│   │   └── Resources/
│   ├── PrasenzPrinter.Core.Tests/
│   └── PrasenzPrinter.Windows.Tests/
├── contracts/
│   └── http-v1/
│       ├── README.md
│       └── fixtures/                  # Requests, expected responses, sample PDFs
├── docs/
│   ├── windows-implementation-plan.md
│   └── windows.md                     # Hướng dẫn sau khi có app
├── scripts/
│   ├── build.sh                       # Build macOS hiện tại
│   ├── build-windows.sh               # Cross-publish từ Mac
│   ├── build-windows.ps1              # Publish/package trên Windows và CI
│   ├── fetch-windows-deps.ps1
│   └── windows-dependencies.json      # Version, URL, checksum của dependencies
├── packaging/
│   └── windows/
│       ├── installer.iss
│       └── THIRD-PARTY-NOTICES.txt
├── assets/
├── bin/                               # Cache dependencies, không commit executable
├── dist/
│   ├── PrasenzPrinter.app             # Giữ output macOS hiện tại
│   └── windows/win-x64/
└── .github/workflows/
    └── build-windows.yml
```

Các folder/file trên là cấu trúc dự kiến, tạo ở phase tương ứng. Update `.gitignore` để bỏ qua .NET `bin/`, `obj/`, `TestResults/` và dependency cache Windows; phân biệt với root `bin/` hiện dùng cho cloudflared.

Chia sẻ contract và fixtures giữa hai nền tảng. Core C# phục vụ bản Windows và test chạy được trên Mac; app Swift không phụ thuộc vào core này. Nếu sau này chuẩn hóa thành `apps/macos/` và `apps/windows/`, thực hiện trong một thay đổi riêng, cập nhật script/resource paths và kiểm tra build macOS.

## 4. Contract HTTP v1

### `POST /print`

- Body: PDF binary như hiện tại; hỗ trợ `Content-Length` và chunked qua Kestrel.
- `x-printer-name`: bắt buộc, tên máy in Windows do UI cung cấp.
- `x-print-options`: optional; mặc định `-o fit-to-page` khi header không có. Header có nhưng rỗng được phân biệt với header bị thiếu.
- `p-req-id`: optional, giữ nguyên trong log của job.
- Headers được đọc case-insensitive.
- Không thêm yêu cầu xác thực local vào contract v1. Cloudflare Access tiếp tục xác thực tại gateway; client vẫn gửi `CF-Access-Client-Id`/`CF-Access-Client-Secret` nếu hostname được bảo vệ.

Responses baseline:

| Trường hợp | HTTP | JSON |
| --- | --- | --- |
| Enqueue thành công | 200 | `{"success":true,"message":"Successfully enqueued print job"}` |
| Thiếu/rỗng tên máy in | 400 | `{"error":"Missing x-printer-name header"}` |
| Body rỗng | 400 | `{"error":"Input PDF data is empty"}` |
| Endpoint hoặc method không có | 404 | `{"error":"Not Found"}` |

Tránh để routing mặc định của framework đổi unsupported method thành `405` hoặc đổi lỗi baseline sang `ProblemDetails`. Không yêu cầu thêm `Content-Type: application/pdf` để chấp nhận request vốn chạy được trên macOS.

`200` nghĩa là app đã nhận job vào queue, không bảo đảm PDF hợp lệ, spool thành công hay giấy đã in xong. Máy in không tồn tại, PDF lỗi hoặc subprocess lỗi được báo trong log sau enqueue, giống mô hình hiện tại. Queue v1 nằm trong memory; job chờ không sống qua lần app crash/restart.

Với giới hạn body/queue cần thiết cho vận hành, định nghĩa cụ thể giá trị cùng response bổ sung (`413`/`503` dạng `{"error":"..."}`), dựa trên workload ở phase 0. Document đây là giới hạn Windows thay vì tuyên bố tương thích mọi request không giới hạn.

### `GET /health`

Giữ tên field, kiểu dữ liệu và ý nghĩa:

```json
{
  "status": "ok",
  "version": "<app-version>",
  "arch": "x86_64",
  "uptime": 120,
  "queueLength": 0,
  "tunnelActive": true,
  "tunnelStatus": "connected",
  "tunnelErrorMessage": ""
}
```

- `uptime`: số giây nguyên từ lúc process khởi động, không reset khi đổi port.
- `queueLength`: tổng job chờ của các máy in.
- `tunnelStatus`: `disconnected`, `connecting`, `connected`, `error`.
- `tunnelActive`: chỉ true khi connected, không chỉ dựa vào process còn sống.
- `status: "ok"` thể hiện HTTP app hoạt động; không thay bằng lỗi chỉ vì tunnel bị ngắt.
- `version` lấy từ build metadata của bản Windows; không hardcode version macOS.

### Truy cập từ server khác

Mặc định bind cả IPv4/IPv6 loopback để Cloudflare trỏ tới `http://localhost:37588`. Nếu cần server trong LAN gọi trực tiếp, cung cấp cấu hình bind LAN riêng, document port/firewall tương ứng và kiểm tra ở phase 6. Đây là cấu hình network, không đổi contract HTTP.

Đổi port trong app không tự đổi upstream của hostname trong Cloudflare Dashboard; UI/hướng dẫn phải nhắc cập nhật cả hai. Tên máy in khác giữa OS có thể cần đổi ở cấu hình backend. Không yêu cầu sửa code tích hợp backend cho các request thuộc tập option đã hỗ trợ.

## 5. Các module và trách nhiệm

### Core: test được trên macOS

- `AppCoordinator`: quản lý start, apply settings, restart và shutdown; không phụ thuộc control WinForms.
- `SettingsStore`: đọc/ghi JSON atomically, defaults, validation, schema version.
- `PrintHttpServer`: Kestrel, routes và response contract.
- `LegacyPrintOptionsParser`: parse header CUPS thành model trung gian, trả lỗi có cấu trúc.
- `PrintQueue`: queue theo printer, trạng thái chờ/đang xử lý, cancellation và kết quả job.
- `IPrinterCatalog`, `IPrintBackend`: interface cho adapter Windows và fake backend trong test.
- `TunnelManager`: state machine, subprocess, restart/backoff và observer network qua abstraction.
- `LogBuffer`, `NewRelicLogForwarder`: log UI/file, correlation ID và forward bất đồng bộ.

### Windows: WinForms và adapters OS

- `TrayApplicationContext`: lifetime, `NotifyIcon`, menu Settings/Exit, single-instance mutex theo user.
- `SettingsForm`: token, port, New Relic key, checkbox autostart, status, printer list, log viewer; thiết kế bằng code để phát triển trên Mac không phụ thuộc visual designer.
- `WindowsPrinterCatalog`: lấy tên qua `PrinterSettings.InstalledPrinters`, refresh theo yêu cầu.
- `SumatraPrintBackend`: launch subprocess với `UseShellExecute=false`, `CreateNoWindow=true` và `ArgumentList`, không ghép shell command.
- `WindowsStartupManager`: đọc/ghi entry HKCU Run, quote executable path có dấu cách.
- `WindowsNetworkObserver`: thông báo network change và resume sau sleep cho tunnel manager.
- Process ownership: dùng Windows Job Object hoặc cơ chế tương đương để process con không bị bỏ lại nếu app crash; graceful shutdown khi Exit.

UI marshal event về UI thread; HTTP, in, đọc subprocess và upload log không block thread giao diện.

## 6. PDF printing và tương thích options

Chọn/pin một release SumatraPDF portable x64 chạy được trên máy mục tiêu. Tài liệu CLI online có thể mô tả option mới hơn bản được đóng gói; xác nhận khả năng trên binary thực tế trước khi chốt mapping.

Ví dụ lệnh do adapter tạo:

```text
SumatraPDF.exe -print-to "Tên máy in" -print-settings "fit,paper=A4" -silent "job.pdf"
```

Mỗi job dùng PDF tạm tên UUID trong data directory `jobs/` của app; giữ file tới khi subprocess kết thúc. Thu exit code, timeout, lỗi launch; cleanup khi hoàn tất và dọn file cũ thuộc app ở lần mở sau. Exit code thành công không chứng minh máy in đã in giấy.

### Bảng mapping v1

| CUPS input | Mapping/chiến lược Windows |
| --- | --- |
| Không có header | `fit`, cùng mặc định API hiện tại |
| `-o fit-to-page` | `fit` |
| `-o scaling=100` | `noscale`; kiểm tra PDF ViewerPreferences không override |
| `-o media=A4` / `Letter` | `paper=A4` / `paper=letter` |
| `-n N` / `-o copies=N` | Print setting số bản; kiểm tra với release được pin |
| `-o sides=one-sided` | `simplex` |
| `-o sides=two-sided-long-edge` / `two-sided-short-edge` | `duplexlong` / `duplexshort` |
| `-o media=custom_80x200mm` | Thử custom paper CLI nếu release hỗ trợ, hoặc ánh xạ tới paper form trong driver |
| `-o page-left/right/top/bottom=0` | Không có bảo đảm CLI tương đương; kiểm tra printable area/driver và profile receipt thực tế |
| Scaling khác 100, margins khác 0, option khác | Chưa hỗ trợ cho tới khi có mapping được kiểm chứng |

Đặc biệt phải nghiệm thu request trong README có `scaling=100` và cả bốn margin bằng 0. Không đơn giản bỏ các margin rồi tuyên bố tương thích. Nếu CLI không tái hiện được kết quả cần thiết, bổ sung renderer/Windows printing adapter sau cùng interface, hoặc document driver profile bắt buộc nếu profile đó đáp ứng đúng output.

Parser chỉ nhận options đã định nghĩa, xử lý thứ tự/option lặp theo quy tắc được document. Unsupported option trả `400` với JSON `error` trước enqueue. Đây là khác biệt có chủ đích với macOS vốn đưa option cho `lp`; contract document phải nêu tập tương thích thay vì hứa hỗ trợ toàn bộ CUPS.

Queue Windows v1 dùng một worker mỗi máy in để giảm rủi ro đảo thứ tự receipt; các máy in khác nhau vẫn chạy song song. Đây là khác biệt concurrency nội bộ với max 3 hiện tại, không đổi HTTP response. Không tự retry job đã bắt đầu submit tới spooler khi kết quả không chắc chắn, tránh in trùng. Retry tunnel được quản lý riêng.

## 7. UI, settings và vòng đời app

### UI tối thiểu

- Left-click tray mở settings; right-click có Open settings và Exit.
- Đóng cửa sổ settings chỉ ẩn UI, không dừng HTTP server.
- Tunnel token, port mặc định `37588`, New Relic key; che token/key trong UI.
- Danh sách máy in với Refresh/Copy; hiển thị đúng tên dùng trong header.
- Checkbox Start with Windows, Save & Apply, Restart tunnel.
- Status riêng của HTTP và tunnel, log viewer có `p-req-id` và lỗi in.
- Lần chạy đầu mở settings; lần sau khởi động trong tray.
- Chạy lại executable không tạo listener/tunnel thứ hai; mở UI của instance đang chạy.

### Settings

Lưu tại `%LOCALAPPDATA%\PrasenzPrinter\settings.json`, log tại `logs/`, file job tạm tại `jobs/` trong cùng data directory. Không ghi settings/log vào folder cài đặt.

Giữ các key `TUNNEL_TOKEN`, `PORT`, `NEW_RELIC_LICENSE_KEY` và `PORT` dạng string để dễ nhận diện/copy config. Thêm `SCHEMA_VERSION` và bind-address setting nếu cần. Autostart đọc trạng thái registry thực tế. File không chứa token/key thật trong repo hoặc artifact; log không ghi token/key.

Save & Apply phải validate port `1024..65535`, lưu atomically và báo chính xác kết quả apply. Nếu bind port mới thất bại, giữ/khôi phục listener cũ và không báo started successfully. Đổi settings không làm mất queue đang chờ. Exit ngừng nhận job, chờ job active trong thời gian grace có giới hạn, ghi log job chưa xử lý và đóng process con.

## 8. Tunnel và logging

Tunnel chạy `cloudflared tunnel run --token ...` từ executable đóng gói. Token rỗng không ngăn HTTP server local hoạt động.

Port các behavior có giá trị từ bản macOS:

- Startup khi network chưa sẵn sàng: chờ best-effort với timeout, rồi retry có backoff.
- Unexpected exit: retry single-flight, backoff khoảng 3–30 giây, reset sau kết nối ổn định.
- Sleep/wake, network change và lỗi network kéo dài: cho phép reconnect, tránh restart storm.
- Event từ process cũ không được ghi đè trạng thái process mới sau Save/Restart.
- Đọc stdout/stderr liên tục, không deadlock vì pipe đầy.
- Không đánh dấu connected chỉ vì `Process.Start` thành công; dùng connection events/metrics có trong version cloudflared được pin.
- Restart/Exit không để lại cloudflared cũ và không tự bật lại tunnel sau thao tác stop.

Logging Windows có bounded UI buffer, file rotation và optional New Relic batch forwarder. Giữ `service.name=prasenz-print-client`, `hostname`, `version`, `level`, `p-req-id`; có thể thêm attribute `platform=windows`. New Relic mất mạng hoặc key sai không block in và không gây vòng lặp log vô hạn.

## 9. Build và đóng gói

### Cross-publish trên Mac

Thiết lập project WinForms với `UseWindowsForms=true`, `OutputType=WinExe`, reference `Microsoft.AspNetCore.App`; bật Windows targeting khi cross-build. Tránh Native AOT và trimming ở v1.

Lệnh dự kiến sau khi tạo project:

```bash
dotnet test src-windows/PrasenzPrinter.Core.Tests/PrasenzPrinter.Core.Tests.csproj

dotnet publish src-windows/PrasenzPrinter.Windows/PrasenzPrinter.Windows.csproj \
  -c Release -r win-x64 --self-contained true \
  -p:EnableWindowsTargeting=true -p:PublishTrimmed=false \
  -o dist/windows/win-x64
```

Mac chạy core tests và cross-build; không chạy WinForms, Windows printer adapters hoặc test driver thực tế. Build script trên Mac phải stage dependency Windows theo manifest như script PowerShell, không chỉ publish executable.

### Artifact và CI

- ZIP chứa `PrasenzPrinter.exe`, toàn bộ self-contained runtime files, `tools/cloudflared.exe`, `tools/SumatraPDF.exe`, notices và hướng dẫn.
- Pin version/URL/checksum của dependencies; tải từ nguồn chính thức, cache theo version. Không dùng `latest` trong release build Windows.
- Kiểm tra điều kiện phân phối SumatraPDF và các thành phần đi kèm của release chọn; đóng gói notices và source/source-access theo nghĩa vụ license tương ứng.
- GitHub Actions trên Windows runner: restore, build, core tests, Windows integration tests không cần printer vật lý, publish và upload ZIP.
- Trigger PR thay đổi Windows/contracts, manual workflow và release tags phù hợp repo. Run workflow không chứa tunnel token hay New Relic key trong artifact.
- Hosted Windows runner không thay thế nghiệm thu Windows 10 thật: runner thường là Windows Server và không có driver/máy in khách hàng.
- Installer Inno Setup per-user sau khi ZIP đạt acceptance: cài vào path ổn định, shortcut, upgrade, cleanup autostart khi uninstall; nâng cấp giữ settings và uninstall cho chọn giữ/xóa data.

## 10. Các giai đoạn triển khai

### Phase 0 — Chốt contract và spike trên Windows 10

1. Viết `contracts/http-v1/README.md`, fixture JSON và sample PDFs không chứa dữ liệu khách hàng từ behavior code hiện tại.
2. Thu các tổ hợp `x-print-options` backend đang gửi, model máy in, driver, khổ giấy và Windows edition/build.
3. Chốt SDK patch, cloudflared release, SumatraPDF release và manifest dependencies.
4. Spike publish WinForms + Kestrel self-contained trên Mac/CI; chạy trên Windows 10 không cài .NET riêng.
5. Spike SumatraPDF với A4 và receipt 80 mm, nhất là request có custom media/margins. Chốt mappings và giới hạn body/queue theo workload.

**Hoàn tất khi:** có contract baseline, build chạy được trên Windows mục tiêu, và kết quả xác định được adapter in có đáp ứng options thực tế hay cần adapter bổ sung. Không triển khai toàn bộ UI trước khi kiểm chứng đường in này.

### Phase 1 — Scaffold và core HTTP

1. Tạo solution/projects, settings model/store, abstractions và AppCoordinator.
2. Host Kestrel, implement `/print` và `/health` với fake backend.
3. Implement queue theo máy in và metrics đúng contract.
4. Thêm core tests cho HTTP contract, parser, queue và lifecycle.

**Hoàn tất khi:** core tests chạy trên Mac; enqueue trả ngay, health phản ánh job chờ, unsupported method/path trả đúng 404.

### Phase 2 — Windows printing adapter

1. Implement printer discovery và mapping options đã chốt ở phase 0.
2. Implement subprocess/temp-file lifecycle, timeout, cleanup và error reporting.
3. Thêm Windows integration tests cho executable missing, tên/path có dấu cách/Unicode, exit lỗi và cancellation.
4. Kiểm tra sample PDFs trên printer thật; thêm adapter thay thế nếu spike yêu cầu.

**Hoàn tất khi:** A4 và receipt mục tiêu in đúng kích thước/scaling, không bật print dialog; job lỗi không chặn các job sau hoặc máy in khác.

### Phase 3 — Tray UI và settings

1. Implement tray lifetime, single-instance, settings form và printer list/Copy.
2. Save & Apply với validation, HTTP restart và rollback nếu bind thất bại.
3. Implement Start with Windows theo user, log viewer, close-to-tray và Exit.

**Hoàn tất khi:** người dùng cấu hình được qua UI, app khởi động sau login, thay đổi port có kết quả chính xác và UI không treo khi đang in.

### Phase 4 — Tunnel và observability

1. Implement tunnel state/retry/network-resume theo mục 8.
2. Wire status lên UI và `/health`; kiểm tra Cloudflare Access end-to-end.
3. Implement New Relic forwarder và file log rotation.
4. Kiểm tra process ownership khi restart, Exit và app crash.

**Hoàn tất khi:** backend gọi qua hostname thành công, tunnel phục hồi sau network outage, không có duplicate process và log theo được `p-req-id`.

### Phase 5 — Build automation và packaging

1. Hoàn thiện build scripts, dependency manifest/cache, ignore rules và Windows CI.
2. Tạo ZIP self-contained, rồi installer per-user.
3. Bổ sung `docs/windows.md` và mục Windows trong README: setup, API/options, troubleshooting, log location và uninstall.

**Hoàn tất khi:** tải artifact về máy Windows sạch có thể cấu hình/in mà không cần SDK hoặc runtime .NET cài riêng; upgrade giữ config, uninstall gỡ autostart.

### Phase 6 — Nghiệm thu và release

1. Chạy cùng fixture requests với app macOS và Windows; so sánh status/JSON shape, các field health và async semantics, bỏ qua version/uptime/tên printer khác theo môi trường.
2. Chạy backend hiện có với URL Windows và tên printer tương ứng, không đổi code tích hợp.
3. Nghiệm thu ma trận ở mục 11 trên Windows 10 và smoke test Windows 11.
4. Kiểm tra build/flow macOS nếu thay README/build paths hoặc bổ sung workflow ảnh hưởng nền tảng này.

**Hoàn tất khi:** tất cả trường hợp bắt buộc đạt và tài liệu nêu rõ tập print-options đã kiểm chứng cho Windows.

## 11. Ma trận nghiệm thu

| Nhóm | Trường hợp bắt buộc |
| --- | --- |
| Cài/chạy | Máy không có .NET riêng; path cài có dấu cách; chạy user thường; chạy lần hai |
| UI | Mở/đóng settings, Refresh/Copy printer, Save sai port, port bị chiếm, close-to-tray |
| API | PDF binary, chunked request, header case-insensitive, thiếu printer, body rỗng, unknown path/method |
| Async semantics | Response sau enqueue; PDF lỗi/máy in sai báo log; health đếm pending đúng |
| Options | Header absent/rỗng, A4/Letter, scaling=100, fit, unsupported option, receipt custom media/margins |
| Máy in | Tên có khoảng trắng/Unicode, USB, network printer nếu có trong môi trường khách hàng |
| Queue | Nhiều request cùng printer, nhiều printer đồng thời, backend timeout/lỗi, cleanup temp file |
| Network | Token rỗng/sai, Cloudflare Access, login trước khi có mạng, mất/phục hồi mạng, sleep/wake |
| Lifecycle | Đổi token/port khi có job, Restart tunnel nhiều lần, Exit, app crash, không còn process orphan |
| Logging | `p-req-id`, New Relic disabled/key sai/offline, bounded buffer, không lộ token/key |
| Compatibility | Backend cũ gọi không đổi code; request mẫu README chạy với output in được nghiệm thu |
| Distribution | ZIP, installer, upgrade, autostart sau login, uninstall và giữ/xóa config |

Test tự động tập trung vào contract, concurrency/lifecycle và các failure path thực sự. Visual UI và chất lượng bản in kiểm tra thủ công trên Windows với máy in thật; không dùng ảnh chụp UI làm điều kiện pass cho logic in.

## 12. Thứ tự ưu tiên và đầu ra

Đường triển khai chính:

```text
Contract + spike Windows/PDF
    → Core HTTP/queue
    → Windows print adapter
    → Tray UI/settings
    → Tunnel/logging
    → Package/CI
    → Compatibility + Windows 10 acceptance
```

Đầu ra v1: app Windows có UI nhỏ, bộ executable self-contained, hướng dẫn cài dùng và contract/options matrix. Server chọn URL/tên máy in theo môi trường, còn cách gửi PDF giữ nguyên.

## Tài liệu tham chiếu

- [.NET trên Windows và bảng OS/runtime compatibility](https://learn.microsoft.com/en-us/dotnet/core/install/windows)
- [SumatraPDF CLI và printing options](https://www.sumatrapdfreader.org/docs/Command-line-arguments)
- [Cloudflared releases](https://github.com/cloudflare/cloudflared/releases)

Các tài liệu online thay đổi theo release; ghi version dependency được nghiệm thu trong manifest và tài liệu Windows khi triển khai.
