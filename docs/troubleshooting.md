# Troubleshooting pfSense di GCP

Daftar lengkap masalah yang **benar-benar terjadi** saat deployment ini, beserta akar masalah dan solusinya. Diurutkan sesuai tahapan boot.

---

## A. VM tidak bisa boot — "No bootable device" / muncul "SeaBIOS"

**Gejala:** Serial console menampilkan `No bootable device` atau banner `SeaBIOS`.

**Akar masalah:** VM jalan dengan firmware **BIOS**, padahal pfSense 2.7 hanya memasang bootloader **EFI**. BIOS tidak menemukan bootloader → gagal.

**Solusi:**
1. Pastikan image punya fitur UEFI:
   ```bash
   gcloud compute images describe NAMA-IMAGE --project=PROJECT \
     --format="value(guestOsFeatures)"
   # harus ada: UEFI_COMPATIBLE
   ```
   Kalau belum, buat ulang image dengan `--guest-os-features=UEFI_COMPATIBLE`.
2. Buat VM dengan `--shielded-secure-boot` (ini yang memaksa firmware UEFI).

> Catatan: `UEFI_COMPATIBLE` di image **saja tidak cukup**. Flag `--shielded-secure-boot` di VM-lah yang benar-benar mengganti firmware ke UEFI di e2-medium.

---

## B. "Security Violation" saat boot UEFI

**Gejala:** Layar UEFI menampilkan `Security Violation` lalu berhenti.

**Akar masalah:** Secure Boot menyala, tapi bootloader EFI pfSense **tidak ditandatangani**.

**Solusi (pola 3 langkah):**
```bash
Z=asia-southeast2-b ; P=ics-ms-sandbox ; VM=pfsense
gcloud compute instances stop   $VM --zone=$Z --project=$P
gcloud compute instances update $VM --zone=$Z --project=$P --no-shielded-secure-boot
gcloud compute instances start  $VM --zone=$Z --project=$P
```
> `update` hanya jalan kalau VM **TERMINATED**. Kalau menjalankan 3 perintah beruntun, `stop` bersifat sinkron (menunggu sampai benar-benar mati), jadi aman.

---

## C. Serial console blank setelah baris `Start @ 0x...`

**Gejala:** Menu boot pfSense muncul di serial, kernel mulai load, lalu setelah `Start @ 0xffffffff...` **layar diam total**.

**Akar masalah:** Bootloader memakai EFI console (di-mirror GCP ke serial), tapi begitu kernel jalan, pfSense pindah ke **VGA console** (`vidconsole`) yang tidak terlihat lewat serial.

**Solusi:** Tambahkan file `/EFI/freebsd/loader.env` di **partisi EFI (FAT)** disk pfSense, berisi:
```
boot_serial=YES
console=comconsole
comconsole_speed=115200
```
`console=comconsole` ini diteruskan ke kernel sehingga kernel output ke serial.

Cara menulis file ini ke disk yang sudah ada (tanpa SSH) → pakai helper VM + startup-script: lihat [`../scripts/patch-esp-serial.sh`](../scripts/patch-esp-serial.sh).

> Partisi EFI itu FAT16/FAT32 → **bisa** ditulis dari Linux biasa. Partisi root pfSense itu **ZFS/UFS** → tidak bisa ditulis dari Linux biasa (butuh helper khusus, lihat bagian E).

---

## D. Boot selesai ("Bootup complete") tapi menu serial tidak muncul, tekan Enter tidak bereaksi

**Gejala:** Pesan boot lengkap sampai `Bootup complete`, tapi tidak ada menu console (0–16) maupun `login:`. Tekan Enter berkali-kali tidak ada apa-apa.

**Akar masalah:** Pesan boot kernel keluar ke serial (dari `loader.env`), TAPI menu interaktif pfSense (`rc.initial`) + getty hanya jalan kalau serial console **diaktifkan di config.xml**. Image varian VGA defaultnya OFF.

**Cara memastikan:** dari serial output, cek tidak ada `Enter an option` / `0) Logout`.

**Solusi:** Edit `config.xml`, di dalam blok `<system>` tambahkan:
```xml
<enableserial></enableserial>
<serialspeed>115200</serialspeed>
<primaryconsole>serial</primaryconsole>
```
config.xml ada di partisi ZFS → lihat bagian E untuk cara edit offline.

---

## E. Cara edit `config.xml` di disk ZFS pfSense (offline, tanpa SSH/console)

Ini bagian paling rumit. Linux biasa **tidak bisa menulis** ZFS. Solusi: helper VM **Ubuntu** (punya OpenZFS) + startup-script.

### Lokasi file penting di disk pfSense (ZFS)
| Path saat di-mount | Isi | Catatan |
|--------------------|-----|---------|
| dataset `pfSense/ROOT/default` → `/` | root filesystem | **canmount=noauto** |
| dataset `pfSense/ROOT/default/cf` → `/cf` | **config aktif** ada di `/cf/conf/config.xml` | **canmount=noauto** |
| `/conf.default/config.xml` | config pabrik (template) | **JANGAN edit yang ini** |

> Karena kedua dataset `noauto`, perintah `zfs mount -a` TIDAK akan mount-nya. Wajib mount eksplisit:
> ```bash
> zpool import -f -R /mnt pfSense
> zfs mount pfSense/ROOT/default
> zfs mount pfSense/ROOT/default/cf
> # file aktif: /mnt/cf/conf/config.xml
> ```

### Langkah lengkap (otomatis lewat startup-script)
1. Stop VM pfsense, **detach** boot disk-nya (disk read-write tidak bisa nempel di 2 VM).
2. Buat helper VM Ubuntu, pasang disk pfsense sebagai disk kedua, kasih startup-script [`../scripts/zfs-edit-config.sh`](../scripts/zfs-edit-config.sh).
3. Script otomatis: install `zfsutils-linux`, import pool, edit `/mnt/cf/conf/config.xml`, export pool. Progres ditulis ke `/dev/ttyS0` (baca via `get-serial-port-output --port=1`).
4. Hapus helper VM, **reattach** disk ke pfsense sebagai boot (`--boot`), start.

> **Gunakan image Ubuntu**, bukan Debian cloud — Ubuntu sudah menyertakan OpenZFS yang bisa import pool FreeBSD secara read-write.

---

## F. webGUI tidak bisa diakses

Periksa berurutan:

1. **Firewall GCP** — pastikan ada rule INGRESS allow `tcp:80` (atau 443) dari IP Anda:
   ```bash
   gcloud compute firewall-rules list --project=PROJECT \
     --filter="network~vpc-untrust AND direction=INGRESS" \
     --format="table(priority,name,allowed[].map().firewall_rule().list(),sourceRanges.list())"
   ```
2. **webGUI listen di port berapa** — dari Shell pfSense:
   ```sh
   sockstat -4 -l | grep nginx
   ```
   ⚠️ Build ini listen `*:80` (HTTP), bukan 443. Akses `http://IP`, bukan `https://`.
3. **Rule WAN pfSense** — default WAN memblokir webGUI. Tambah dengan `easyrule` (lihat README bagian 5.2). Verifikasi:
   ```sh
   pfctl -sr | grep 80
   ```
4. **Proteksi referer/DNS rebind** — kalalu GUI muncul tapi menolak, matikan check-nya (README bagian 5.3).

---

## G. Jangan reload filter dengan `php -r 'require_once("filter.inc"); filter_configure_sync();'`

**Gejala:** Muncul **crash report** dengan `Call to undefined function filter_generate_dummynet_rules()`.

**Akar masalah:** `php -r` itu tidak ikut me-load semua dependency `filter.inc`. Ini **bukan** kerusakan sistem — hanya error perintah manual yang ke-log.

**Solusi:**
- Untuk reload filter yang benar, gunakan shell pfSense:
  ```sh
  echo "filter_configure();" | pfSsh.php
  ```
- Crash report yang sudah terlanjur muncul: di webGUI klik **"Delete crash report files"** (tidak perlu submit). Aman, tidak akan berulang.

---

## H2. Instance di belakang LAN tidak dapat internet walau route + NAT sudah benar (GCP butuh LAN = DHCP)

**Gejala:** Route `0.0.0.0/0 -> pfSense` sudah ada, Outbound NAT sudah cover subnet, GCP firewall sudah allow, tapi instance workload tetap **100% packet loss** ke internet. Dari pfSense, `ping <ip-instance-workload>` malah `sendto: Host is down`, dan `arp -an` menunjukkan entry **(incomplete)**.

**Akar masalah (penting & tidak intuitif):** GCP adalah jaringan **L3 murni** — instance **tidak bisa saling ARP**. Semua komunikasi (termasuk antar-instance se-subnet) harus lewat **gateway subnet** (`.1`). Kalau interface LAN pfSense di-set **Static dengan netmask subnet (mis. /16)**, pfSense mengira seluruh subnet itu L2-langsung lalu meng-ARP tiap host → GCP tidak menjawab → ARP incomplete → balasan/return traffic tidak terkirim ke client.

Cara cek dari shell pfSense:
```sh
netstat -rn | grep '10.1'      # akan terlihat: 10.1.0.0/16  link#2  U  vtnet1  (connected = salah utk GCP)
arp -an | grep <ip-client>     # (incomplete) = ARP gagal
ifconfig vtnet1 | grep inet    # netmask 0xffff0000 = /16 (penyebabnya)
```

**Solusi (paling simpel & terbukti):** Set interface **LAN ke DHCP**.
- pfSense GUI: **Interfaces -> LAN -> IPv4 Configuration Type = DHCP -> Save -> Apply**.
- GCP lalu memberi pfSense konfigurasi yang benar: IP `/32` + route ke gateway `.1`, sehingga semua traffic LAN dilewatkan ke gateway GCP (bukan ARP L2). Routing & return langsung jalan.

> Prinsip umum: **di GCP, interface internal sebuah VM-router sebaiknya DHCP**, bukan static dengan netmask penuh. Ini berlaku untuk semua appliance (pfSense, MikroTik CHR, dll), bukan cuma pfSense.

Jika tetap mau static: pakai netmask **/32**, tambahkan gateway non-local `.1` (System -> Routing -> Gateways, centang "Use non-local gateway"), lalu static route `subnet -> gateway .1`. Tapi DHCP jauh lebih simpel.

---

## H. Perintah gcloud berisik karena neofetch (khusus environment ini)

`~/.zshrc` menjalankan neofetch sehingga output gcloud penuh ASCII art. Hindari `source ~/.zshrc`. Tambahkan gcloud ke PATH langsung:
```bash
export PATH="$HOME/google-cloud-sdk/bin:$PATH"
```
Dan untuk membaca serial log yang penuh escape ANSI:
```bash
... | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -cd '\11\12\15\40-\176'
```
