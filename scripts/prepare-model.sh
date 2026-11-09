#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v uv >/dev/null || { echo 'Install uv from https://docs.astral.sh/uv/ before preparing the model.' >&2; exit 1; }
export UV_CACHE_DIR="$PWD/.cache/uv"
export UV_PYTHON_INSTALL_DIR="$PWD/.tools/python"
if [[ ! -x .venv-models/bin/python ]]; then
    uv venv --python 3.12.13 .venv-models
fi
uv pip install --python .venv-models/bin/python --only-binary :all: -r tools/model-requirements.lock.txt
python3 tools/fetch_arcface.py
.venv-models/bin/python tools/validate_arcface.py
python3 tools/check_model_assets.py
