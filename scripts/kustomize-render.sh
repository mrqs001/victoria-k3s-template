#!/usr/bin/env bash
set -euo pipefail

DIR="${1:?usage: kustomize-render.sh <dir>}"
APP_IMAGE="${APP_IMAGE:-ghcr.io/mrqs001/victoria-k3s-template-demo-app:main}"

safe_image="${APP_IMAGE//&/\\&}"

kubectl kustomize "$DIR" | sed "s#image: demo-app:latest#image: ${safe_image}#g"

