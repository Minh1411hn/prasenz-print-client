# 🖨️ PrasenzPrinter — Hệ Thống In Ấn Tự Động macOS (100% Pure Swift App)

<p align="center">
  <strong>Ứng dụng macOS Universal chạy ẩn góc Menu Bar, tích hợp HTTP Socket Server native, tự động in ấn và duy trì Cloudflare Tunnel bảo mật.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-10.15%2B-blue?logo=apple" alt="macOS">
  <img src="https://img.shields.io/badge/Swift-Native%20100%25-orange?logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/Universal-Intel%20%26%20Apple%20Silicon-blueviolet" alt="Universal">
  <img src="https://img.shields.io/badge/version-1.2.0-green" alt="Version">
  <img src="https://img.shields.io/badge/license-Private-red" alt="License">
</p>

---

## 📋 Mục lục

- [Tổng quan kiến trúc](#-tổng-quan-kiến-trúc)
- [Yêu cầu hệ thống](#-yêu-cầu-hệ-thống)
- [Biên dịch & Đóng gói (For Developers)](#-biên-dịch--đóng-gói-for-developers)
- [Cài đặt & Sử dụng (For End-Users)](#-cài-đặt--sử-dụng-for-end-users)
- [Cách hoạt động của Menu Bar UI](#-cách-hoạt-động-của-menu-bar-ui)
- [Hướng dẫn Setup Cloudflare Tunnel](#-hướng-dẫn-setup-cloudflare-tunnel-zero-trust)
- [Tích hợp Cloud Backend (Nuxt)](#-tích-hợp-cloud-backend-nuxt)
- [Cấu trúc thư mục ứng dụng thành phẩm](#-cấu-trúc-thư-mục-ứng-dụng-thành-phẩm)
- [Gỡ cài đặt sạch sẽ](#-gỡ-cài-đặt-sạch-sẽ)
- [Troubleshooting](#-troubleshooting)

---

## 🏗️ Tổng quan kiến trúc

PrasenzPrinter được xây dựng bằng **100% ngôn ngữ Apple Swift native**, loại bỏ hoàn toàn môi trường chạy Node.js cồng kềnh. Ứng dụng chạy như một tiến trình đơn nhất (Single Process) siêu nhẹ, đảm bảo độ ổn định và bảo mật tối đa.

```
                     ┌──────────────────────────────────────┐
                     │          PrasenzPrinter.app          │
                     │ (Tiến trình duy nhất — Native Swift) │
                     └──────────────────┬───────────────────┘
                                        │
             ┌──────────────────────────┼──────────────────────────┐
             ▼                          ▼                          ▼
    [ Menu Bar status ]        [ NWListener Server ]       [ Subprocess Manager ]
   ├── Icon 🖨️ (Template)     ├── Cổng động (mặc định:    └── Quản lý chạy ngầm
   └── Popover (AppKit GUI)        37588)                      [ cloudflared ]
                              ├── Tự đọc/ghi trực tiếp 
                              │   ~/.prasenz-printer/settings.json
                              └── Tiếp nhận POST /print
                                        │
                                        ▼ (Đưa vào hàng đợi)
                              ┌───────────────────┐
                              │ Hàng đợi in ngầm  │
                              │ (DispatchQueue)   │
                              └─────────┬─────────┘
                                        │
                                        ▼ (Thực thi lệnh native shell)
                               [ macOS CUPS (lp) ]
```

### Các công nghệ native nổi bật

* **HTTP Server Socket**: Sử dụng framework **`Network`** (`NWListener`) gốc của Apple để xử lý kết nối TCP (Cổng mặc định: `37588`), tự parse HTTP request và tích lũy dữ liệu nhị phân (phục vụ truyền file PDF dung lượng lớn lên tới 25MB) với hiệu năng cực cao.

* **Hàng đợi Thread-Safe**: Queue quản lý bằng `DispatchQueue` tuần tự, tự động ghi PDF tạm vào thư mục hệ thống và gọi máy in qua CUPS (`lp`), dọn dẹp file ngay sau khi in thành công.

---

## ⚙️ Yêu cầu hệ thống

| Thành phần | Yêu cầu |
|------------|----------|
| **Thiết bị** | Máy Mac Intel (x64) hoặc Apple Silicon M1/M2/M3/M4 (arm64) |
| **Hệ điều hành** | macOS 10.15 (Catalina) trở lên (Hỗ trợ tuyệt vời trên macOS Sequoia) |
| **Công cụ Build** | Chỉ cần **Command Line Tools** (cài qua `xcode-select --install`) |
| **Máy in** | Đã cấu hình và in thử thành công trên macOS CUPS |

---

## 🛠️ Biên dịch & Đóng gói (For Developers)

Vì dự án đã loại bỏ 100% hệ sinh thái Node.js, bạn **không cần cài đặt Node.js hay chạy lệnh `npm`** để biên dịch. Chỉ cần sử dụng Terminal mặc định của macOS để build trong vòng 3 - 5 giây:

```bash
# 1. Clone dự án về máy và truy cập vào thư mục
git clone <your-repo-url> prasenz-print-client
cd prasenz-print-client

# 2. Cấp quyền thực thi và chạy trực tiếp script biên dịch Swift
chmod +x scripts/*.sh
bash scripts/build.sh
```

**Quy trình build tự động:**
- Tải tệp thực thi Cloudflare Tunnel (`cloudflared`) tương ứng nếu chưa có.
- Sử dụng trình biên dịch `swiftc` dòng lệnh để compile code Swift sang 2 kiến trúc máy chủ (`x86_64` và `arm64`).
- Sử dụng công cụ `lipo` của Mac gộp lại thành file Universal Binary duy nhất.
- Đóng gói thành thư mục ứng dụng hoàn chỉnh tại: `dist/PrasenzPrinter.app`.

---

## 📦 Cài đặt & Sử dụng (For End-Users)

Khi đã có file **`PrasenzPrinter.app`** thành phẩm:

1. **Giải nén** file nếu nhận ở dạng `.zip`.
2. **Kéo thả trực tiếp** tệp **`PrasenzPrinter.app`** vào thư mục **`/Applications`** (Ứng dụng) trên máy Mac của cửa hàng.
3. **Click đúp** vào ứng dụng để mở.

> 🎉 **Hoàn toàn Zero-Setup!** Bạn không cần cài đặt Node.js, không cần chạy bất kỳ lệnh Terminal nào. Giao diện cấu hình sẽ tự động xuất hiện trên thanh Menu Bar và Server in ấn ngầm đã tự hoạt động.

---

## 🖨️ Cách hoạt động của Menu Bar UI

Trải nghiệm người dùng được thiết kế tối giản, tinh tế chuẩn macOS:

### 1. Click Chuột Trái (Mở nhanh cấu hình)
Bấm chuột trái vào biểu tượng máy in **🖨️** góc màn hình để trượt xuống cửa sổ Popover cấu hình mượt mà:
* **Cloud Config**: Nhập mã Cloudflare Tunnel Token.
* **Cổng kết nối (Port)**: Nhập cổng kết nối HTTP Server chạy ngầm trên máy Mac (Mặc định: `37588`).
* **Danh sách máy in**: Hiển thị danh sách các máy in của hệ thống kèm nút Copy nhanh tên máy in để dùng cho backend/API.
* **Bật/Tắt Khởi động cùng macOS**: Tích chọn hộp kiểm để tự động đăng ký chạy cùng hệ điều hành.
* Bấm **Save** để lưu và áp dụng cấu hình mới.

### 2. Click Chuột Phải (Tùy chọn nhanh)
Click chuột phải (hoặc nhấn giữ phím `Control` + Click chuột trái) để hiển thị menu ngữ cảnh gồm **đúng 2 dòng tối giản**:
* **Mở setting**: Bật cửa sổ bong bóng Popover cấu hình (giống hệt click chuột trái).
* **Thoát hoàn toàn (Quit)**: Tắt ứng dụng Swift, dừng server, đóng subprocess `cloudflared` ngầm và giải phóng 100% bộ nhớ.

---

## 🔒 Hướng dẫn Setup Cloudflare Tunnel (Zero Trust)

Giúp máy in tại quán nhận dữ liệu từ Cloud Server mà không cần IP tĩnh, không cần Port-Forwarding (mở cổng modem).

1. Truy cập [Cloudflare Zero Trust Portal](https://one.dash.cloudflare.com/).
2. Menu bên trái → **Networks** → **Tunnels** → Bấm **Create a Tunnel**.
3. Đặt tên: `prasenz-store-01` (hoặc tên quán) → **Save Tunnel**.
4. Copy đoạn mã **Tunnel Token** dài hiển thị trên màn hình.
5. Tại tab **Public Hostname** của Tunnel, cấu hình định tuyến:
   - Subdomain: `print-api` (hoặc tên bạn muốn).
   - Domain: Tên miền chính của bạn (VD: `yourdomain.com`).
   - Type: `HTTP`.
   - URL: `localhost:37588` (Cần khớp với **Cổng kết nối** đã cài đặt trong settings, mặc định: 37588).
   - Bấm **Save Hostname**.
6. Dán đoạn **Tunnel Token** đã copy vào ô "Cloudflare Tunnel Token" trên giao diện quản trị của app là hoàn tất!

---

## 🌐 Tích hợp Cloud Backend (Nuxt)

Cấu hình máy chủ Nuxt để gửi gói tin in ấn được ký bảo mật HMAC xuống máy Mac tại cửa hàng.
```
export default defineEventHandler(async (event) => {
  const body = await readBody(event);
  const { printerName, orderData } = body; 
  // printerName nhận trực tiếp tên của máy in trên macOS (VD: 'Xprinter_USB_Printer_P')

  const tunnelUrl = process.env.PRINT_TUNNEL_URL || 'https://print-api.yourdomain.com';
  
  // Các key của Cloudflare Access (Cấu hình bảo vệ cổng vào Cloudflare)
  const cfClientId = process.env.CF_ACCESS_CLIENT_ID;
  const cfClientSecret = process.env.CF_ACCESS_CLIENT_SECRET;

  // Sinh buffer file PDF thực tế
  const pdfBuffer = await generatePdfBuffer(printerName, orderData);

  try {
    await $fetch(`${tunnelUrl}/print`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/pdf',
        'x-printer-name': printerName,
        'CF-Access-Client-Id': cfClientId,
        'CF-Access-Client-Secret': cfClientSecret
      },
      body: pdfBuffer
    });

    return { success: true, message: 'Đã bắn lệnh in xuống hệ thống cửa hàng.' };
  } catch (error: any) {
    console.error('[NUXT PRINT ERROR]:', error.message);
    throw createError({
      statusCode: 500,
      statusMessage: `Lỗi kết nối hạ tầng in ấn tại cửa hàng: ${error.message}`
    });
  }
});

async function generatePdfBuffer(printerName: string, data: any): Promise<Buffer> {
  return Buffer.from("DỮ_LIỆU_PDF_MẪU_VECTOR");
}
```

---

### ⚡ Test nhanh bằng cURL (Quick Testing with cURL)

Bạn có thể dễ dàng kiểm tra nhanh chức năng in ấn bằng cách chạy script cURL trực tiếp trong Terminal của macOS. Lệnh này sẽ gửi trực tiếp tệp PDF mẫu tới HTTP Server cục bộ (mặc định cổng `37588`):

```bash
# 1. Định nghĩa các tham số cần thiết
PRINTER_NAME="Xprinter_USB_Printer_P"        # Tên máy in thật của bạn (Copy từ giao diện Settings)
PDF_FILE="/path/to/your/test_file.pdf"       # Đường dẫn tới tệp PDF thật cần in test trên máy Mac của bạn

# 2. Gửi yêu cầu in trực tiếp qua cURL
curl -X POST http://localhost:1234/print \
  -H "Content-Type: application/pdf" \
  -H "CF-Access-Client-Id: xxxx" \
  -H "CF-Access-Client-Secret: yyyy" \
  -H "x-printer-name: $PRINTER_NAME" \
  --data-binary @"$PDF_FILE"
```

---

## 📂 Cấu trúc thư mục ứng dụng thành phẩm

Ứng dụng macOS thành phẩm siêu gọn nhẹ chỉ bao gồm các thành phần sau:

```
/Applications/PrasenzPrinter.app/
└── Contents/
    ├── Info.plist                     # Metadata cấu hình hệ thống ứng dụng
    └── MacOS/
        ├── PrasenzPrinter             # File thực thi Swift (Chứa cả HTTP Server & GUI Popover)
        └── bin/
            ├── cloudflared-intel      # Bản Tunnel AMD64 Intel
            └── cloudflared-silicon    # Bản Tunnel ARM64 Apple Silicon
```

### 💾 Vị trí lưu trữ cấu hình bền vững (Persistent Config)

Để đảm bảo cấu hình của cửa hàng **không bao giờ bị mất** khi cập nhật phiên bản ứng dụng mới, tệp tin cấu hình và máy in được lưu trữ bền vững tại:
* Vị trí: **`~/.prasenz-printer/settings.json`** (Thư mục ẩn hệ thống của user hiện hành).

---

## 🗑️ Gỡ cài đặt sạch sẽ

Để gỡ cài đặt hoàn toàn PrasenzPrinter khỏi máy Mac của cửa hàng:

1. Click chuột phải vào biểu tượng **🖨️** trên Menu Bar → Chọn **Thoát hoàn toàn**.
2. Mở thư mục `/Applications`, kéo **PrasenzPrinter.app** bỏ vào Thùng rác (Trash).
3. Mở Terminal và chạy lệnh dọn dẹp trực tiếp bằng script shell để xóa sạch sẽ cấu hình:
   ```bash
   bash scripts/uninstall.sh
   
   # Hoặc tự chạy thủ công bằng tay để dọn dẹp thư mục config bền vững
   rm -rf ~/.prasenz-printer
   rm -f ~/Library/LaunchAgents/com.prasenz.printagent.plist
   rm -f /tmp/prasenz_print_agent.log /tmp/prasenz_print_agent_err.log
   ```

---

## 🔧 Troubleshooting

### Xem log trực tiếp của ứng dụng
Vì ứng dụng chạy ẩn hoàn toàn, toàn bộ logs in ấn, logs kết nối của Cloudflare Tunnel và HTTP Server được ghi nhận tại:
* Xem log hoạt động: `tail -f /tmp/prasenz_print_agent.log`
* Xem log lỗi (nếu có): `tail -f /tmp/prasenz_print_agent_err.log`

### Lỗi kết nối Popover ("This site can't be reached")
* Đảm bảo bạn đã kéo ứng dụng vào thư mục `/Applications` thay vì mở trực tiếp trong thư mục download hoặc file nén tạm.
* Mở Terminal và chạy ứng dụng trực tiếp để xem có thông báo lỗi phân quyền hoặc cổng mạng hay không:
  ```bash
  /Applications/PrasenzPrinter.app/Contents/MacOS/PrasenzPrinter
  ```

---
<p align="center">
  <strong>Prasenz Printing Service Suite © 2026</strong><br>
  Tất cả quyền được bảo lưu.
</p>
# prasenz-print-client
