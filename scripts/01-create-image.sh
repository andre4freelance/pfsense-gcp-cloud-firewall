#!/usr/bin/env bash
# Buat GCP image pfSense yang UEFI-compatible.
# Bisa dari file installer di GCS, ATAU dari disk yang sudah berisi pfSense.
#
# Pakai:
#   Dari GCS  : ./01-create-image.sh gcs  NAMA-IMAGE  gs://bucket/img/file.tar.gz
#   Dari disk : ./01-create-image.sh disk NAMA-IMAGE  NAMA-DISK
set -euo pipefail

PROJECT="ics-ms-sandbox"
ZONE="asia-southeast2-b"
FAMILY="bsd"
USER_LABEL="andre"

MODE="${1:-}"; IMAGE="${2:-}"; SRC="${3:-}"
if [[ -z "$MODE" || -z "$IMAGE" || -z "$SRC" ]]; then
  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1
fi

# Hapus image lama kalau namanya sama (image GCP harus unik)
gcloud compute images delete "$IMAGE" --project="$PROJECT" --quiet 2>/dev/null || true

case "$MODE" in
  gcs)
    gcloud compute images create "$IMAGE" \
      --source-uri="$SRC" \
      --project="$PROJECT" \
      --family="$FAMILY" \
      --labels=name="$IMAGE",user="$USER_LABEL" \
      --guest-os-features=UEFI_COMPATIBLE
    ;;
  disk)
    gcloud compute images create "$IMAGE" \
      --source-disk="$SRC" --source-disk-zone="$ZONE" \
      --project="$PROJECT" \
      --family="$FAMILY" \
      --labels=name="$IMAGE",user="$USER_LABEL" \
      --guest-os-features=UEFI_COMPATIBLE \
      --force
    ;;
  *) echo "MODE harus 'gcs' atau 'disk'"; exit 1 ;;
esac

echo "Selesai. Verifikasi fitur UEFI:"
gcloud compute images describe "$IMAGE" --project="$PROJECT" \
  --format="value(name,status,guestOsFeatures)"
