#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --fastq-dir PATH   directory containing FASTQ files (default: ./fastq)
  --out-dir PATH     output directory for trimmed reads (default: ./trimmed)
  --log-dir PATH     output directory for logs (default: ./logs)
  --r1-suffix STR    R1 filename suffix (default: _R1_001.fastq.gz)
  --r2-suffix STR    R2 filename suffix (default: _R2_001.fastq.gz)
  --threads N        number of threads (default: nproc-4 if nproc>8, else nproc)
  --dry-run          print commands without running fastp
  --force            overwrite existing trimmed files
  -h, --help         show this help and exit

Layout detection:
  Auto-detected per sample. If <prefix><r2-suffix> exists alongside R1, the
  sample is trimmed as paired-end; otherwise as single-end. Mixed datasets
  are handled correctly because detection runs per sample.

Output per sample:
  OUT_DIR/<prefix><r1-suffix>              trimmed R1
  OUT_DIR/<prefix><r2-suffix>              trimmed R2 (paired-end only)
  OUT_DIR/<prefix>_fastp.json              QC report (JSON)
  OUT_DIR/<prefix>_fastp.html              QC report (HTML)
  LOG_DIR/<prefix>.fastp.<timestamp>.log   per-sample log

Examples:
  $(basename "$0")
  $(basename "$0") --fastq-dir /data/fastq --threads 16
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

FASTQ_DIR="${FASTQ_DIR:-./fastq}"
OUT_DIR="${OUT_DIR:-./trimmed}"
LOG_DIR="${LOG_DIR:-./logs}"
R1_SUFFIX="${R1_SUFFIX:-_R1_001.fastq.gz}"
R2_SUFFIX="${R2_SUFFIX:-_R2_001.fastq.gz}"
THREADS="${THREADS:-$THREADS_DEFAULT}"
DRY_RUN=0
FORCE=0

# --- Parse args ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fastq-dir) FASTQ_DIR="$2"; shift 2;;
    --out-dir)   OUT_DIR="$2";   shift 2;;
    --log-dir)   LOG_DIR="$2";   shift 2;;
    --r1-suffix) R1_SUFFIX="$2"; shift 2;;
    --r2-suffix) R2_SUFFIX="$2"; shift 2;;
    --threads)   THREADS="$2";   shift 2;;
    --dry-run)   DRY_RUN=1;      shift;;
    --force)     FORCE=1;        shift;;
    -h|--help)   usage; exit 0;;
    --) shift; break;;
    -*|--*) echo "ERROR: unknown option: $1" >&2; usage; exit 1;;
    *) break;;
  esac
done

echo "[INFO] FASTQ_DIR: ${FASTQ_DIR}"
echo "[INFO] OUT_DIR:   ${OUT_DIR}"
echo "[INFO] LOG_DIR:   ${LOG_DIR}"
echo "[INFO] THREADS:   ${THREADS}"
echo "[INFO] R1 suffix: ${R1_SUFFIX}"
echo "[INFO] R2 suffix: ${R2_SUFFIX}"

mkdir -p "$OUT_DIR" "$LOG_DIR"

# --- Validate -----------------------------------------------------------------
command -v fastp >/dev/null 2>&1 || { echo "ERROR: fastp not found in PATH" >&2; exit 2; }

if [[ ! -d "$FASTQ_DIR" ]]; then
  echo "ERROR: FASTQ directory not found: ${FASTQ_DIR}" >&2; exit 3
fi

# --- Process samples ----------------------------------------------------------
n_ok=0; n_skip=0; n_fail=0

while IFS= read -r r1_path; do
  r1_base=$(basename "$r1_path")
  prefix="${r1_base%${R1_SUFFIX}}"

  R2="${FASTQ_DIR}/${prefix}${R2_SUFFIX}"
  OUT_R1="${OUT_DIR}/${prefix}${R1_SUFFIX}"
  OUT_R2="${OUT_DIR}/${prefix}${R2_SUFFIX}"
  LOG_FILE="${LOG_DIR}/${prefix}.fastp.$(date +%Y%m%dT%H%M%S).log"

  # Auto-detect layout
  if [[ -f "$R2" ]]; then
    layout="paired-end"
  else
    layout="single-end"
  fi

  # Resume: skip completed samples unless --force
  if [[ $FORCE -eq 0 ]]; then
    if [[ "$layout" == "paired-end" ]] && [[ -f "$OUT_R1" ]] && [[ -f "$OUT_R2" ]]; then
      echo "[SKIP] ${prefix} (${layout}) — trimmed outputs exist, use --force to re-run"
      n_skip=$((n_skip + 1))
      continue
    elif [[ "$layout" == "single-end" ]] && [[ -f "$OUT_R1" ]]; then
      echo "[SKIP] ${prefix} (${layout}) — trimmed output exists, use --force to re-run"
      n_skip=$((n_skip + 1))
      continue
    fi
  fi

  # --force: remove existing outputs
  if [[ $FORCE -eq 1 ]]; then
    rm -f "$OUT_R1" "$OUT_R2"
    rm -f "${OUT_DIR}/${prefix}_fastp.json" "${OUT_DIR}/${prefix}_fastp.html"
    rm -f "${LOG_DIR}/${prefix}".fastp.*.log
  fi

  if [[ "$layout" == "paired-end" ]]; then
    cmd=( fastp
      --in1 "$r1_path" --in2 "$R2"
      --out1 "$OUT_R1" --out2 "$OUT_R2"
      --json "${OUT_DIR}/${prefix}_fastp.json"
      --html "${OUT_DIR}/${prefix}_fastp.html"
      --detect_adapter_for_pe
      --trim_poly_g
      --length_required 20
      --thread "$THREADS" )
  else
    cmd=( fastp
      --in1 "$r1_path"
      --out1 "$OUT_R1"
      --json "${OUT_DIR}/${prefix}_fastp.json"
      --html "${OUT_DIR}/${prefix}_fastp.html"
      --trim_poly_g
      --length_required 20
      --thread "$THREADS" )
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] ${prefix} (${layout}):"
    printf '    %s\n' "${cmd[@]}"
    echo ""
    continue
  fi

  echo "[fastp] Trimming ${prefix} (${layout})..."

  if ! "${cmd[@]}" >>"$LOG_FILE" 2>&1; then
    echo "[ERROR] fastp failed for ${prefix} — see ${LOG_FILE}" >&2
    n_fail=$((n_fail + 1))
    continue
  fi

  echo "[DONE] ${prefix} (log: ${LOG_FILE})"
  n_ok=$((n_ok + 1))

done < <(find "$FASTQ_DIR" -maxdepth 1 -name "*${R1_SUFFIX}" | sort)

echo ""
echo "[fastp] Finished — trimmed: ${n_ok}  skipped: ${n_skip}  failed: ${n_fail}"
[[ $n_fail -gt 0 ]] && exit 1 || exit 0
