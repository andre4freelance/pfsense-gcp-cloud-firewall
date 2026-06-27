#!/usr/bin/env bash
# Buat VM pfSense dari image 'pfsense-2-7' dengan pola UEFI yang benar:
#   create (Secure Boot ON)  ->  stop  ->  matikan Secure Boot  ->  start
# Plus --can-ip-forward (wajib untuk routing) dan 2 NIC (WAN + LAN).
#
# Pakai:  ./02-create-vm.sh NAMA-VM
set -euo pipefail

PROJECT="ics-ms-sandbox"
ZONE="asia-southeast2-b"
MACHINE="e2-medium"
IMAGE="pfsense-2-7"          # image reusable hasil akhir
DISK_SIZE="20GB"
WAN_NET="vpc-untrust";   WAN_SUBNET="subnet-untrust-jkt"
LAN_NET="vpc-workload";  LAN_SUBNET="subnet-workload-jkt"
USER_LABEL="andre"

VM="${1:-}"
[[ -z "$VM" ]] && { echo "Pakai: $0 NAMA-VM"; exit 1; }

echo ">>> 1/4 create VM (Secure Boot ON supaya firmware jadi UEFI)"
gcloud compute instances create "$VM" \
  --zone="$ZONE" --machine-type="$MACHINE" --project="$PROJECT" \
  --create-disk=boot=yes,image=projects/$PROJECT/global/images/$IMAGE,size=$DISK_SIZE,type=pd-balanced,device-name=$VM,auto-delete=yes \
  --network-interface=network=$WAN_NET,subnet=$WAN_SUBNET \
  --network-interface=network=$LAN_NET,subnet=$LAN_SUBNET,no-address \
  --can-ip-forward \
  --labels=name=$VM,user=$USER_LABEL \
  --metadata=serial-port-enable=true \
  --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring

echo ">>> 2/4 stop (wajib TERMINATED sebelum ubah Secure Boot)"
gcloud compute instances stop "$VM" --zone="$ZONE" --project="$PROJECT"

echo ">>> 3/4 matikan Secure Boot (bootloader pfSense unsigned)"
gcloud compute instances update "$VM" --zone="$ZONE" --project="$PROJECT" --no-shielded-secure-boot

echo ">>> 4/4 start"
gcloud compute instances start "$VM" --zone="$ZONE" --project="$PROJECT"

echo
echo "Selesai. Cek status & IP:"
gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT" \
  --format="value(status,canIpForward,networkInterfaces[0].accessConfigs[0].natIP)"
echo "Lihat boot via serial:"
echo "  gcloud compute connect-to-serial-port $VM --zone=$ZONE --project=$PROJECT"
echo "Akses webGUI (HTTP, bukan HTTPS):  http://<EXTERNAL-IP>   login admin/pfsense"
