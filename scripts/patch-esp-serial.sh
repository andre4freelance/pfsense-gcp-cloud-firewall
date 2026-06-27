#!/bin/bash
# STARTUP-SCRIPT untuk helper VM (Debian/Ubuntu).
# Fungsi: menulis /EFI/freebsd/loader.env ke partisi EFI (FAT) disk pfSense,
#         supaya KERNEL pfSense output ke serial console (console=comconsole).
#
# Cara pakai (di luar VM):
#   1. Stop VM pfsense, detach boot disk-nya.
#   2. Buat helper VM dengan disk pfsense terpasang sbg disk kedua + script ini:
#        gcloud compute instances create esp-helper \
#          --zone=ZONE --machine-type=e2-small --project=PROJECT \
#          --image-family=debian-12 --image-project=debian-cloud --no-address \
#          --disk=name=DISK-PFSENSE,device-name=pfdisk,boot=no,mode=rw \
#          --metadata-from-file=startup-script=patch-esp-serial.sh \
#          --metadata=serial-port-enable=true
#   3. Baca hasil:  gcloud compute instances get-serial-port-output esp-helper --port=1 ...
#   4. Hapus helper, reattach disk ke pfsense (--boot), start.

exec > /dev/ttyS0 2>&1
echo "===== ESP PATCH START ====="
DISK=/dev/disk/by-id/google-pfdisk
for i in $(seq 1 15); do [ -b "$DISK" ] && break; echo "menunggu disk..."; sleep 2; done

# Cari partisi vfat (EFI System Partition)
ESP=""
for p in ${DISK}-part*; do
  [ -b "$p" ] || continue
  t=$(blkid -o value -s TYPE "$p" 2>/dev/null)
  echo "partisi $p type=$t"
  [ "$t" = "vfat" ] && ESP="$p"
done
[ -z "$ESP" ] && { echo "ERROR: ESP (vfat) tidak ketemu"; echo "===== ESP PATCH FAILED ====="; exit 1; }

mkdir -p /mnt/esp
mount "$ESP" /mnt/esp || { echo "ERROR: mount gagal"; echo "===== ESP PATCH FAILED ====="; exit 1; }
mkdir -p /mnt/esp/EFI/freebsd
printf 'boot_serial=YES\nconsole=comconsole\ncomconsole_speed=115200\n' > /mnt/esp/EFI/freebsd/loader.env
sync
echo "--- isi loader.env ---"; cat /mnt/esp/EFI/freebsd/loader.env
ls -la /mnt/esp/EFI/freebsd/
umount /mnt/esp
echo "===== ESP PATCH DONE ====="
