#!/bin/bash
# STARTUP-SCRIPT untuk helper VM UBUNTU (wajib Ubuntu, butuh OpenZFS).
# Fungsi: edit config.xml di disk ZFS pfSense secara offline untuk:
#   1) Mengaktifkan SERIAL CONSOLE menu (enableserial + primaryconsole=serial)
#   2) (opsional) Menambah rule WAN agar webGUI bisa diakses
#
# Cara pakai (di luar VM):
#   1. Stop VM pfsense, detach boot disk-nya.
#   2. Buat helper Ubuntu dengan disk pfsense terpasang sbg disk kedua + script ini:
#        gcloud compute instances create zfs-helper \
#          --zone=ZONE --machine-type=e2-medium --project=PROJECT \
#          --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud \
#          --disk=name=DISK-PFSENSE,device-name=pfdisk,boot=no,mode=rw \
#          --metadata-from-file=startup-script=zfs-edit-config.sh \
#          --metadata=serial-port-enable=true
#   3. Baca hasil:  gcloud compute instances get-serial-port-output zfs-helper --port=1 ...
#   4. Hapus helper, reattach disk ke pfsense (--boot), start.
#
# GANTI nilai SRC_IP di bawah dengan IP publik Anda (untuk rule WAN). Set "" untuk skip rule.

SRC_IP="114.10.64.131"     # <- ganti dengan IP publik admin Anda, atau "" untuk tidak menambah rule
WEB_PORT="80"              # port webGUI pfSense (build ini = 80)

exec > /dev/ttyS0 2>&1
set -x
echo "===== ZFS EDIT START ====="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y zfsutils-linux
modprobe zfs || true
sleep 2

zpool import -f -R /mnt pfSense || { echo "ERROR import"; echo "===== ZFS EDIT FAILED ====="; exit 1; }
# Dataset root & cf ber-canmount=noauto -> WAJIB mount eksplisit
zfs mount pfSense/ROOT/default
zfs mount pfSense/ROOT/default/cf

CFG=/mnt/cf/conf/config.xml      # <- config AKTIF (BUKAN /mnt/conf.default/config.xml)
if [ ! -f "$CFG" ]; then echo "ERROR: $CFG tidak ada"; ls -la /mnt/cf; echo "===== ZFS EDIT FAILED ====="; zpool export pfSense; exit 1; fi
cp "$CFG" "${CFG}.bak.$(date +%s)"

# 1) Aktifkan serial console menu
if ! grep -q "<enableserial>" "$CFG"; then
  sed -i 's#</system>#<enableserial></enableserial><serialspeed>115200</serialspeed><primaryconsole>serial</primaryconsole></system>#' "$CFG"
  echo "serial console ENABLED"
fi

# 2) (opsional) rule WAN untuk webGUI
if [ -n "$SRC_IP" ] && ! grep -q "ALLOW WAN mgmt" "$CFG"; then
  sed -i "s#<filter>#<filter><rule><type>pass</type><interface>wan</interface><ipprotocol>inet</ipprotocol><protocol>tcp</protocol><source><address>${SRC_IP}</address></source><destination><network>wanip</network><port>${WEB_PORT}</port></destination><descr>ALLOW WAN mgmt</descr></rule>#" "$CFG"
  echo "WAN rule ADDED (port ${WEB_PORT} dari ${SRC_IP})"
fi

echo "=== verifikasi ==="
grep -oE "<primaryconsole>[a-z]*</primaryconsole>" "$CFG" || true
python3 -c "import xml.dom.minidom; xml.dom.minidom.parse('$CFG'); print('XML_OK')" 2>&1 || echo "XML_PARSE_WARNING"
sync
umount /mnt/cf 2>/dev/null
zpool export pfSense
echo "===== ZFS EDIT DONE ====="
