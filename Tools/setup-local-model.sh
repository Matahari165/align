#!/bin/sh
set -eu

model_name='rtmpose-m-halpe26-end2end.onnx'
expected_sha256='26f3a19e61304a600dfb82d1001d41d24343b89fc70a33ffc84657e0b0bf2ecf'

usage() {
  cat <<'EOF'
Usage: ./Tools/setup-local-model.sh

Verify the locally-owned RTMPose model and copy it into the ignored build
checkout. No network access or download is performed.

The source defaults to:
  ~/Library/Application Support/Align/Models/rtmpose-m-halpe26-end2end.onnx

Override the source path with:
  ALIGN_RTMPOSE_MODEL_PATH=/absolute/path/to/rtmpose-m-halpe26-end2end.onnx
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    ;;
  *)
    echo "Argument inattendu : $1" >&2
    usage >&2
    exit 2
    ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
destination_dir="$repo_root/Align/Pose/RTMPose/Models"
destination="$destination_dir/$model_name"

if [ -z "${HOME:-}" ]; then
  echo "Impossible de déterminer le dossier utilisateur : HOME est vide." >&2
  exit 1
fi

source_path=${ALIGN_RTMPOSE_MODEL_PATH:-"$HOME/Library/Application Support/Align/Models/$model_name"}

if [ ! -f "$source_path" ]; then
  echo "Modèle RTMPose absent : $source_path" >&2
  echo "Placez votre copie autorisée à cet emplacement ou définissez ALIGN_RTMPOSE_MODEL_PATH." >&2
  echo "Aucun téléchargement automatique n'est effectué." >&2
  exit 1
fi

actual_sha256=$(shasum -a 256 "$source_path" | awk '{print $1}')
if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "SHA-256 RTMPose inattendu pour : $source_path" >&2
  echo "  attendu : $expected_sha256" >&2
  echo "  obtenu  : $actual_sha256" >&2
  echo "Vérifiez que le fichier est bien le modèle RTMPose-M Halpe26 attendu." >&2
  exit 1
fi

mkdir -p "$destination_dir"
temporary_destination=$(mktemp "$destination_dir/.$model_name.tmp.XXXXXX")
cleanup() {
  rm -f "$temporary_destination"
}
trap cleanup EXIT HUP INT TERM

# Copy and rename in the same directory so a build never observes a partial
# model file. The source remains outside the repository and is never removed.
cp -p "$source_path" "$temporary_destination"
mv -f "$temporary_destination" "$destination"
trap - EXIT HUP INT TERM

copied_sha256=$(shasum -a 256 "$destination" | awk '{print $1}')
if [ "$copied_sha256" != "$expected_sha256" ]; then
  echo "Échec de vérification après copie : $destination" >&2
  exit 1
fi

echo "Modèle RTMPose prêt pour le build : $destination"
echo "SHA-256 vérifié : $expected_sha256"
