# pfSense CE sebagai Cloud Firewall di GCP

Catatan lengkap cara deploy **pfSense CE 2.7.x** sebagai firewall/router di Google Cloud Platform (GCP), termasuk semua jebakan (pitfall) yang sudah ditemukan dan cara mengatasinya.

> **Ditulis supaya bisa diikuti oleh Junior IT / AI.** Setiap perintah bisa di-copy-paste. Ganti nilai yang **HURUF KAPITAL** atau ditandai `<...>` sesuai lingkungan Anda.

---

## 1. Gambaran Arsitektur

pfSense punya 2 kaki (NIC):

```
                 Internet
                    │
            ┌───────┴────────┐
            │   WAN (vtnet0) │  <- punya External IP, ada di VPC "untrust"
            │                │
            │    pfSense VM  │  (e2-medium, UEFI, IP forwarding ON)
            │                │
            │   LAN (vtnet1) │  <- TANPA External IP, ada di VPC "workload"
            └───────┬────────┘
                    │
              VM workload (server di belakang firewall)
```

| Komponen | Nilai di project ini | Catatan |
|----------|----------------------|---------|
| Zone | `asia-southeast2-b` | Jakarta |
| WAN | network `vpc-untrust`, subnet `subnet-untrust-jkt` | dapat External IP |
| LAN | network `vpc-workload`, subnet `subnet-workload-jkt` | `--no-address` |
| Machine type | `e2-medium` | |
| OS di pfSense | FreeBSD 14 (pfSense 2.7.1) | filesystem **ZFS** |

---

## 2. Konsep Penting (WAJIB dipahami dulu)

Kalau tiga hal ini tidak dipahami, deployment pasti gagal/blank.

### 2.1 pfSense WAJIB pakai UEFI, bukan BIOS
pfSense 2.7.x menginstal bootloader **EFI saja** (tidak ada bootloader MBR/BIOS). Kalau VM jalan dengan firmware BIOS (SeaBIOS, default GCP), hasilnya **"No bootable device"**.

Cara memaksa GCP pakai firmware UEFI:
1. **Image** harus punya fitur `UEFI_COMPATIBLE` (hanya bisa diset lewat gcloud CLI, **tidak ada** opsinya di web console).
2. **VM** harus dibuat dengan flag `--shielded-secure-boot` (inilah yang memaksa firmware jadi UEFI di e2-medium).

### 2.2 Secure Boot harus DIMATIKAN setelah VM dibuat
Bootloader EFI pfSense **tidak ditandatangani (unsigned)**, jadi kalau Secure Boot menyala → error **"Security Violation"**. Tapi kita butuh `--shielded-secure-boot` saat *create* untuk dapat UEFI. Solusinya pola **3 langkah**:

```
create (Secure Boot ON)  →  stop  →  update --no-shielded-secure-boot  →  start
```
(VM **harus** berstatus TERMINATED sebelum `update`.)

### 2.3 Serial console butuh 2 lapis pengaturan
Karena VM cloud tidak punya layar, kita lihat pfSense lewat **serial console**. Ada 2 lapis:

| Lapis | File | Efek kalau tidak ada |
|-------|------|----------------------|
| Loader/kernel | `/EFI/freebsd/loader.env` di partisi EFI (FAT) | Layar serial blank setelah `Start @ ...` |
| Menu pfSense (rc.initial) | `config.xml`: `<enableserial>` + `<primaryconsole>serial</primaryconsole>` | Pesan boot muncul, tapi menu/login TIDAK muncul (tekan Enter tak ada reaksi) |

Image reusable di repo ini (`pfsense-2-7`) **sudah** punya kedua lapis ini.

---

## 3. Cara Cepat (kalau sudah punya image `pfsense-2-7`)

Image `pfsense-2-7` adalah hasil akhir yang sudah beres semua. Spin-up firewall baru:

```bash
bash scripts/02-create-vm.sh NAMA-VM-BARU
```

Script itu menjalankan pola 3 langkah (create Secure Boot ON → stop → matikan Secure Boot → start) plus `--can-ip-forward` dan 2 NIC. Selesai, pfSense langsung boot dengan serial console aktif.

Akses webGUI: **http://EXTERNAL-IP** (lihat bagian 5).

---

## 4. Cara dari Nol (bikin image dari awal)

Hanya perlu kalau image `pfsense-2-7` belum ada / mau versi baru. Urutan ringkas:

1. **Upload installer image pfSense ke GCS** lalu jadikan GCP image dengan `UEFI_COMPATIBLE` (lihat `scripts/01-create-image.sh`). Image installer kita namai `pfsense-2-7-vanila`.
2. **Buat VM installer** dari `pfsense-2-7-vanila` + disk kosong kedua (target instalasi) → pola 3 langkah UEFI.
3. **Install pfSense** lewat serial console ke disk kedua (ZFS).
4. **Stop**, lalu **buat image** dari disk hasil instalasi → `pfsense-2-7`.
5. Kalau serial menu belum muncul, jalankan perbaikan `config.xml` (lihat `scripts/zfs-edit-config.sh` dan `docs/troubleshooting.md`).

> Untuk produksi sehari-hari Anda **tidak perlu** mengulang ini. Cukup pakai bagian 3.

---

## 5. Akses webGUI pfSense

> ⚠️ Build ini melayani webGUI di **HTTP port 80**, BUKAN HTTPS 443. Buka `http://EXTERNAL-IP`.

Default login: **admin / pfsense** (ganti segera setelah masuk).

### 5.1 Buka firewall GCP (sekali saja)
```bash
gcloud compute firewall-rules create pfsense-web \
  --project=ics-ms-sandbox \
  --network=vpc-untrust \
  --direction=INGRESS --action=ALLOW \
  --rules=tcp:80,tcp:443,tcp:22 \
  --source-ranges=IP-PUBLIK-ANDA/32
```
Cari IP publik Anda: `curl ipinfo.io/ip`

### 5.2 Buka akses WAN di pfSense
Secara default pfSense memblokir webGUI dari WAN. Dari **serial console → menu 8 (Shell)**:
```sh
# cari IP internal WAN dulu
ifconfig vtnet0 | grep "inet "
# izinkan port 80 dari IP Anda ke IP WAN itu
easyrule pass wan tcp IP-PUBLIK-ANDA IP-INTERNAL-WAN 80
```
> `easyrule` butuh **IP angka**, tidak menerima kata `wanip` atau `WAN`.

### 5.3 Kalau muncul error "HTTP_REFERER / DNS Rebind"
Itu proteksi pfSense saat diakses lewat IP mentah. Matikan dari Shell:
```sh
php -r 'require_once("config.inc"); $config["system"]["webgui"]["nohttpreferercheck"]=true; $config["system"]["webgui"]["nodnsrebindcheck"]=true; write_config("disable referer/rebind");'
```

---

## 6. Isi Repo

```
.
├── README.md                     <- file ini
├── docs/
│   └── troubleshooting.md        <- semua error + solusi (BACA kalau mentok)
└── scripts/
    ├── 01-create-image.sh        <- bikin GCP image (UEFI_COMPATIBLE) dari GCS
    ├── 02-create-vm.sh           <- bikin VM pfSense (pola 3 langkah + ip-forward)
    ├── patch-esp-serial.sh       <- startup-script: tambah loader.env (serial console kernel)
    └── zfs-edit-config.sh        <- startup-script: edit config.xml di disk ZFS (enable serial menu)
```

---

## 7. Ringkasan Jebakan (cheat sheet)

| Gejala | Penyebab | Solusi |
|--------|----------|--------|
| "No bootable device / SeaBIOS" | VM jalan BIOS, bukan UEFI | image `UEFI_COMPATIBLE` + `--shielded-secure-boot` |
| "Security Violation" saat boot | Secure Boot ON, bootloader pfSense unsigned | stop → `--no-shielded-secure-boot` → start |
| Serial blank setelah `Start @ ...` | kernel pakai VGA | `loader.env` `console=comconsole` di partisi EFI |
| Boot selesai tapi menu serial tak muncul, Enter tak bereaksi | serial menu disabled di config | `config.xml`: `<enableserial>` + `<primaryconsole>serial</primaryconsole>` |
| Trafik tidak ter-route | `can-ip-forward` mati | hanya bisa diset saat create → buat ulang VM |
| webGUI timeout di https | webGUI ada di **http:80** | buka `http://IP`, cek `sockstat -4 -l \| grep nginx` |
| Error referer/DNS rebind | akses via IP mentah | matikan kedua check (bagian 5.3) |

Detail lengkap tiap error ada di [`docs/troubleshooting.md`](docs/troubleshooting.md).
