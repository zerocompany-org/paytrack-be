#!/usr/bin/env bash
# Deploy API theo tag sha-* cố định (khớp tag CI đẩy lên GHCR). Chạy SAU khi
# workflow build-be.yml push xong, nếu không sẽ ImagePullBackOff.
#
#   ./deploy.sh                # deploy commit HEAD hiện tại -> tag sha-<short>
#   ./deploy.sh sha-1a2b3c4    # deploy 1 tag cụ thể (dùng để rollback)
#
# Biến ghi đè: NAMESPACE, IMAGE.
#
# LƯU Ý: strategy=Recreate -> pod cũ bị xoá TRƯỚC khi pod mới chạy. Có vài chục
# giây API không phục vụ, và pod mới còn chạy autoMigrate trước khi mở cổng.
set -euo pipefail

NAMESPACE="${NAMESPACE:-paytrack}"
IMAGE="${IMAGE:-ghcr.io/zerocompany-org/paytrack-be/be}"
DEPLOY="paytrack-be"
CONTAINER="paytrack-be"

# --short=7 ghim do dai: docker/metadata-action (type=sha,format=short) sinh
# tag 7 ky tu. De `--short` tran thi git co the tra 8+ ky tu khi bi dung do
# prefix -> tag khong ton tai tren GHCR -> ImagePullBackOff.
TAG="${1:-sha-$(git rev-parse --short=7 HEAD)}"

echo "Deploy $IMAGE:$TAG -> deployment/$DEPLOY (ns=$NAMESPACE)"
kubectl -n "$NAMESPACE" set image "deployment/$DEPLOY" "$CONTAINER=$IMAGE:$TAG"

if ! kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOY" --timeout=240s; then
  echo "Rollout THẤT BẠI. Chẩn đoán:"
  echo "  kubectl -n $NAMESPACE describe pod -l app=$DEPLOY"
  echo "  kubectl -n $NAMESPACE logs -l app=$DEPLOY --tail=100"
  exit 1
fi
echo "Xong."
