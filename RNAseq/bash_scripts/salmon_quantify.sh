#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Genome resources (refgenie or manual):
  --salmon-index PATH        path to salmon index (skips refgenie lookup)
  --refgenie-genome NAME     genome key for refgenie seek (default: mm10_primary)
  --refgenie-salmon-asset N  refgenie asset name for salmon index (default: salmon_index)
  --refgenie PATH            path to refgenie config file
                             priority: --refgenie > \$REFGENIE env var > refgenie default

Input options:
  --fastq-dir PATH           directory containing trimmed FASTQ files (default: ./trimmed)
  --metadata PATH            tab-separated metadata file (default: ./metadata/metadata.txt)
  --r1-suffix STR            R1 filename suffix (default: _R1_001.fastq.gz)
  --r2-suffix STR            R2 filename suffix (default: _R2_001.fastq.gz)
  --col-prefix N             metadata column for FASTQ prefix (default: 1)
  --col-celltype N           metadata column for cell type   (default: 8)
  --col-genotype N           metadata column for genotype    (default: 9)
  --col-id N                 metadata column for sample ID   (default: 11)

Output options:
  --out-dir PATH             output directory for salmon results (default: ./salmon)
  --log-dir PATH             output directory for logs (default: ./logs)
  --threads N                number of threads (default: nproc-4 if nproc>8, else nproc)

Behaviour:
  --dry-run                  print commands without running salmon
  --force                    remove existing outputs and re-run
  -h, --help                 show this help and exit

Layout detection:
  Auto-detected per sample. If <prefix><r2-suffix> exists alongside R1, the
  sample is quantified as paired-end; otherwise as single-end. Mixed datasets
  are handled correctly because detection runs per sample.
  Note: --gcBias is only applied for paired-end samples.

Metadata format (tab-separated, header on row 1):
  Default column mapping:
    col 1:  FASTQ prefix  — matched against trimmed FASTQ filenames
    col 8:  cell type     — used in output name  (e.g. CD4, B, CD8)
    col 9:  genotype      — used in output name  (e.g. WT, cTKO)
    col 11: sample ID     — used in output name  (e.g. 2M, 1F)

  Output name pattern: {celltype}-{genotype}-{id}  (e.g. CD4-WT-2M)

Output per sample:
  OUT_DIR/{CellType}-{Genotype}-{ID}/quant.sf
  LOG_DIR/{CellType}-{Genotype}-{ID}.salmon.<timestamp>.log

Examples:
  # Minimal — uses ./trimmed, refgenie resolves index automatically:
  $(basename "$0")

  # Explicit index (no refgenie needed):
  $(basename "$0") --salmon-index /path/to/mm10_primary/salmon_sa_index

  # Custom FASTQ directory and metadata:
  $(basename "$0") --fastq-dir ./fastq --metadata ./metadata/metadata.txt

  # Dry-run preview, then force re-run:
  $(basename "$0") --dry-run
  $(basename "$0") --force
EOF
}

# --- Defaults -----------------------------------------------------------------
if command -v nproc >/dev/null 2>&1; then
  TOTAL_CPUS=$(nproc)
else
  TOTAL_CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
fi
THREADS_DEFAULT=$(( TOTAL_CPUS > 8 ? TOTAL_CPUS - 4 : 4 ))

REFGENIE="${REFGENIE:-}"
FASTQ_DIR="${FASTQ_DIR:-./trimmed}"
OUT_DIR="${OUT_DIR:-./salmon}"
LOG_DIR="${LOG_DIR:-./logs}"
METADATA="${METADATA:-./metadata/metadata.txt}"
R1_SUFFIX="${R1_SUFFIX:-_R1_001.fastq.gz}"
R2_SUFFIX="${R2_SUFFIX:-_R2_001.fastq.gz}"
COL_PREFIX="${COL_PREFIX:-1}"
COL_CELLTYPE="${COL_CELLTYPE:-8}"
COL_GENOTYPE="${COL_GENOTYPE:-9}"
COL_ID="${COL_ID:-11}"
SALMON_INDEX="${SALMON_INDEX:-}"
REFGENIE_GENOME="${REFGENIE_GENOME:-mm10_primary}"
REFGENIE_SALMON_ASSET="${REFGENIE_SALMON_ASSET:-salmon_index}"
THREADS="${THREADS:-$THREADS_DEFAULT}"
DRY_RUN=0
FORCE=0

# --- Parse args ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --refgenie)              REFGENIE="$2";               shift 2;;
    --fastq-dir)             FASTQ_DIR="$2";              shift 2;;
    --out-dir)               OUT_DIR="$2";                shift 2;;
    --log-dir)               LOG_DIR="$2";                shift 2;;
    --metadata)              METADATA="$2";               shift 2;;
    --r1-suffix)             R1_SUFFIX="$2";              shift 2;;
    --r2-suffix)             R2_SUFFIX="$2";              shift 2;;
    --col-prefix)            COL_PREFIX="$2";             shift 2;;
    --col-celltype)          COL_CELLTYPE="$2";           shift 2;;
    --col-genotype)          COL_GENOTYPE="$2";           shift 2;;
    --col-id)                COL_ID="$2";                 shift 2;;
    --salmon-index)          SALMON_INDEX="$2";           shift 2;;
    --refgenie-genome)       REFGENIE_GENOME="$2";        shift 2;;
    --refgenie-salmon-asset) REFGENIE_SALMON_ASSET="$2";  shift 2;;
    --threads)               THREADS="$2";                shift 2;;
    --dry-run)               DRY_RUN=1;                   shift;;
    --force)                 FORCE=1;                     shift;;
    -h|--help)               usage; exit 0;;
    --) shift; break;;
    -*|--*) echo "ERROR: unknown option: $1" >&2; usage; exit 1;;
    *) break;;
  esac
done

echo "[INFO] FASTQ_DIR:  ${FASTQ_DIR}"
echo "[INFO] METADATA:   ${METADATA}"
echo "[INFO] OUT_DIR:    ${OUT_DIR}"
echo "[INFO] LOG_DIR:    ${LOG_DIR}"
echo "[INFO] THREADS:    ${THREADS}"
echo "[INFO] Metadata columns — prefix:${COL_PREFIX} celltype:${COL_CELLTYPE} genotype:${COL_GENOTYPE} id:${COL_ID}"

mkdir -p "$OUT_DIR" "$LOG_DIR"

# --- Validate dependencies ----------------------------------------------------
command -v salmon >/dev/null 2>&1 || { echo "ERROR: salmon not found in PATH" >&2; exit 2; }
if [[ -z "$SALMON_INDEX" ]]; then
  command -v refgenie >/dev/null 2>&1 || {
    echo "ERROR: refgenie not found in PATH (required when --salmon-index not supplied)" >&2
    exit 2
  }
fi

# --- Resolve salmon index via refgenie ----------------------------------------
[[ -n "$REFGENIE" ]] && export REFGENIE

if [[ -z "$SALMON_INDEX" ]]; then
  SALMON_INDEX=$(refgenie seek "${REFGENIE_GENOME}/${REFGENIE_SALMON_ASSET}") || {
    echo "ERROR: refgenie could not resolve ${REFGENIE_GENOME}/${REFGENIE_SALMON_ASSET}" >&2; exit 3
  }
  echo "[refgenie] salmon index: ${SALMON_INDEX}"
else
  echo "[INFO] salmon index: ${SALMON_INDEX} (user-supplied)"
fi

# --- Validate inputs ----------------------------------------------------------
if [[ ! -d "$FASTQ_DIR" ]]; then
  echo "ERROR: FASTQ directory not found: ${FASTQ_DIR}" >&2; exit 4
fi

if [[ ! -f "$METADATA" ]]; then
  echo "ERROR: metadata file not found: ${METADATA}" >&2; exit 4
fi

# --- Build metadata lookup: prefix -> sample name ----------------------------
declare -A SAMPLE_MAP
while IFS=$'\t' read -ra fields; do
  prefix="${fields[$((COL_PREFIX   - 1))]}"
  celltype="${fields[$((COL_CELLTYPE - 1))]}"
  genotype="${fields[$((COL_GENOTYPE - 1))]}"
  id="${fields[$((COL_ID        - 1))]}"
  SAMPLE_MAP["$prefix"]="${celltype}-${genotype}-${id}"
done < <(tail -n +2 "$METADATA")

echo "[INFO] Loaded ${#SAMPLE_MAP[@]} samples from metadata"

# --- Process samples ----------------------------------------------------------
n_ok=0; n_skip=0; n_warn=0; n_fail=0

while IFS= read -r r1_path; do
  r1_base=$(basename "$r1_path")
  prefix="${r1_base%${R1_SUFFIX}}"

  # Metadata lookup
  if [[ -z "${SAMPLE_MAP[$prefix]+set}" ]]; then
    echo "[WARN] No metadata entry for prefix '${prefix}', skipping."
    n_warn=$((n_warn + 1))
    continue
  fi
  SAMPLE_NAME="${SAMPLE_MAP[$prefix]}"

  R2="${FASTQ_DIR}/${prefix}${R2_SUFFIX}"
  SAMPLE_OUT="${OUT_DIR}/${SAMPLE_NAME}"
  LOG_FILE="${LOG_DIR}/${SAMPLE_NAME}.salmon.$(date +%Y%m%dT%H%M%S).log"

  # Auto-detect layout
  if [[ -f "$R2" ]]; then
    layout="paired-end"
  else
    layout="single-end"
  fi

  # Resume: skip if quant.sf already exists
  if [[ -f "${SAMPLE_OUT}/quant.sf" ]] && [[ $FORCE -eq 0 ]]; then
    echo "[SKIP] ${SAMPLE_NAME} — quant.sf exists, use --force to re-run"
    n_skip=$((n_skip + 1))
    continue
  fi

  # --force: remove existing output directory
  if [[ $FORCE -eq 1 ]]; then
    rm -rf "$SAMPLE_OUT"
    rm -f "${LOG_DIR}/${SAMPLE_NAME}".salmon.*.log
  fi

  if [[ "$layout" == "paired-end" ]]; then
    cmd=( salmon quant
      --index "$SALMON_INDEX"
      --libType A
      --mates1 "$r1_path" --mates2 "$R2"
      --output "$SAMPLE_OUT"
      --validateMappings
      --threads "$THREADS" )
  else
    cmd=( salmon quant
      --index "$SALMON_INDEX"
      --libType A
      --unmatedReads "$r1_path"
      --output "$SAMPLE_OUT"
      --validateMappings
      --threads "$THREADS" )
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] ${SAMPLE_NAME} (${layout}, source: ${prefix}):"
    printf '    %s\n' "${cmd[@]}"
    echo ""
    continue
  fi

  echo "[salmon] Quantifying ${SAMPLE_NAME} (${layout}, source: ${prefix})..."

  if ! "${cmd[@]}" >>"$LOG_FILE" 2>&1; then
    echo "[ERROR] salmon failed for ${SAMPLE_NAME} — see ${LOG_FILE}" >&2
    n_fail=$((n_fail + 1))
    continue
  fi

  echo "[DONE] ${SAMPLE_NAME} (log: ${LOG_FILE})"
  n_ok=$((n_ok + 1))

done < <(find "$FASTQ_DIR" -maxdepth 1 -name "*${R1_SUFFIX}" | sort)

echo ""
echo "[salmon] Finished — quantified: ${n_ok}  skipped: ${n_skip}  warned: ${n_warn}  failed: ${n_fail}"
[[ $n_fail -gt 0 ]] && exit 1 || exit 0
