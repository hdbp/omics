#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --fastq-dir PATH          directory containing FASTQ files (default: ./fastq)

Genome resources (refgenie or manual):
  --refgenie-genome NAME    genome key for refgenie seek (default: mm10)
  --refgenie-star-asset N   refgenie asset name for STAR index (default: star_index)
  --refgenie-gtf-asset N    refgenie asset name for GTF        (default: gencode_gtf)
  --genome-dir PATH         path to STAR genome index (skips refgenie lookup)
  --gtf PATH                path to GTF annotation file (skips refgenie lookup)
  --refgenie PATH           path to refgenie config file
                            priority: --refgenie > \$REFGENIE env var > refgenie default

Input options:
  --metadata PATH           tab-separated metadata file (default: ./metadata/metadata.txt)
  --r1-suffix SUFFIX        R1 filename suffix (default: _R1_001.fastq.gz)
  --r2-suffix SUFFIX        R2 filename suffix (default: _R2_001.fastq.gz)
  --col-prefix N            metadata column for FASTQ prefix (default: 1)
  --col-celltype N          metadata column for cell type   (default: 8)
  --col-genotype N          metadata column for genotype    (default: 9)
  --col-id N                metadata column for sample ID   (default: 11)

Output options:
  --out-dir PATH            output directory for BAMs  (default: ./bam)
  --log-dir PATH            output directory for logs  (default: ./logs)
  --threads N               number of threads (default: total CPUs - 4, minimum 1)

Behaviour:
  --dry-run                 print commands without running STAR (safe validation)
  --verbose                 write the exact STAR command to each per-sample log
  --force                   remove existing outputs and re-run (default: skip completed samples)
  -h, --help                show this help and exit

Paired-end vs single-end
  Auto-detected per sample. If <prefix><r2-suffix> exists alongside R1, the
  sample is aligned as paired-end; otherwise as single-end. Mixed datasets are
  handled correctly because detection runs per sample.

Notes:
  - Genome resources: if --genome-dir or --gtf are omitted the script calls
    refgenie seek <genome>/<star-asset> and <genome>/<gtf-asset> (gencode_gtf
    by default). Use
    --refgenie-star-asset and --refgenie-gtf-asset to change the asset names.
    Supply --genome-dir and --gtf together to run without refgenie entirely.
  - GTF processing: .gz GTF files are decompressed automatically. Chromosome
    naming mismatches between the STAR index (UCSC chr*) and GTF (Ensembl)
    are detected from chrName.txt and corrected automatically (MT ↔ chrM).
  - Resume: samples with an existing BAM and .bai index are skipped unless
    --force is used.
  - Logs: each sample writes to LOG_DIR/<sample>.star.<timestamp>.log.
    Use --verbose to also record the exact STAR invocation in that log.

Examples:
  # Minimal — uses ./fastq, refgenie resolves genome and GTF automatically:
  $(basename "$0") --refgenie-genome mm10

  # Custom FASTQ directory:
  $(basename "$0") --fastq-dir /data/fastq --refgenie-genome mm10

  # Explicit genome resources (no refgenie needed):
  $(basename "$0") --genome-dir /idx/mm10 --gtf /ref/mm10.gtf

  # Custom FASTQ suffix and metadata columns:
  $(basename "$0") --r1-suffix _R1.fastq.gz --col-id 5

  # Force re-run with dry-run preview first:
  $(basename "$0") --dry-run
  $(basename "$0") --force

Metadata format (tab-separated)
  Columns are read by position — the header row is ignored and column names
  do not matter. Configure which column holds each value with --col-* options.

  Default column mapping:
    col 1:  FASTQ prefix — suffix appended to build FASTQ filenames
    col 8:  cell type    — used in output sample name  (e.g. B, CD4, CD8)
    col 9:  genotype     — used in output sample name  (e.g. WT, cTKO)
    col 11: sample ID    — used in output sample name  (e.g. 2M, 1F)

  Output sample name pattern: {celltype}-{genotype}-{id}  (e.g. B-WT-2M)

  Output files per sample:
    OUT_DIR/<sample>/Aligned.sortedByCoord.out.bam
    OUT_DIR/<sample>/Aligned.sortedByCoord.out.bam.bai
    OUT_DIR/<sample>/ReadsPerGene.out.tab
    LOG_DIR/<sample>.star.<timestamp>.log
EOF
}

# --- Defaults ----------------------------------------------------------------
if command -v nproc >/dev/null 2>&1; then
  TOTAL_CPUS=$(nproc)
else
  TOTAL_CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
fi
THREADS_DEFAULT=$(( TOTAL_CPUS > 4 ? TOTAL_CPUS - 4 : 1 ))

REFGENIE="${REFGENIE:-}"
FASTQ_DIR="${FASTQ_DIR:-./fastq}"
THREADS="${THREADS:-$THREADS_DEFAULT}"
GENOME_DIR="${GENOME_DIR:-}"
GTF="${GTF:-}"
REFGENIE_GENOME="${REFGENIE_GENOME:-mm10}"
REFGENIE_STAR_ASSET="${REFGENIE_STAR_ASSET:-star_index}"
REFGENIE_GTF_ASSET="${REFGENIE_GTF_ASSET:-gencode_gtf}"
R1_SUFFIX="${R1_SUFFIX:-_R1_001.fastq.gz}"
R2_SUFFIX="${R2_SUFFIX:-_R2_001.fastq.gz}"
COL_PREFIX="${COL_PREFIX:-1}"
COL_CELLTYPE="${COL_CELLTYPE:-8}"
COL_GENOTYPE="${COL_GENOTYPE:-9}"
COL_ID="${COL_ID:-11}"
LOG_DIR="${LOG_DIR:-./logs}"
DRY_RUN=0
VERBOSE=0
FORCE=0

# --- Parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --refgenie)        REFGENIE="$2";        shift 2;;
    --fastq-dir)       FASTQ_DIR="$2";       shift 2;;
    --metadata)        METADATA="$2";        shift 2;;
    --out-dir)         OUT_DIR="$2";         shift 2;;
    --threads)         THREADS="$2";         shift 2;;
    --r1-suffix)       R1_SUFFIX="$2";       shift 2;;
    --r2-suffix)       R2_SUFFIX="$2";       shift 2;;
    --col-prefix)      COL_PREFIX="$2";      shift 2;;
    --col-celltype)    COL_CELLTYPE="$2";    shift 2;;
    --col-genotype)    COL_GENOTYPE="$2";    shift 2;;
    --col-id)          COL_ID="$2";          shift 2;;
    --log-dir)         LOG_DIR="$2";         shift 2;;
    --dry-run)         DRY_RUN=1;            shift;;
    --verbose)         VERBOSE=1;            shift;;
    --force)           FORCE=1;              shift;;
    --genome-dir)      GENOME_DIR="$2";      shift 2;;
    --gtf)             GTF="$2";             shift 2;;
    --refgenie-genome)      REFGENIE_GENOME="$2";      shift 2;;
    --refgenie-star-asset)  REFGENIE_STAR_ASSET="$2";  shift 2;;
    --refgenie-gtf-asset)   REFGENIE_GTF_ASSET="$2";   shift 2;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*|--*) echo "ERROR: unknown option: $1" >&2; usage; exit 1;;
    *) break;;
  esac
done

# Derived defaults computed after CLI parsing
METADATA="${METADATA:-./metadata/metadata.txt}"
OUT_DIR="${OUT_DIR:-./bam}"

echo "[INFO] FASTQ_DIR:  ${FASTQ_DIR}"
echo "[INFO] METADATA:   ${METADATA}"
echo "[INFO] OUT_DIR:    ${OUT_DIR}"
echo "[INFO] LOG_DIR:    ${LOG_DIR}"
echo "[INFO] THREADS:    ${THREADS}"
echo "[INFO] R1 suffix:  ${R1_SUFFIX}"
echo "[INFO] R2 suffix:  ${R2_SUFFIX}"
echo "[INFO] Metadata columns — prefix:${COL_PREFIX} celltype:${COL_CELLTYPE} genotype:${COL_GENOTYPE} id:${COL_ID}"

# --- Validate dependencies ---------------------------------------------------
command -v STAR     >/dev/null 2>&1 || { echo "ERROR: STAR not found in PATH"     >&2; exit 2; }
command -v samtools >/dev/null 2>&1 || { echo "ERROR: samtools not found in PATH" >&2; exit 2; }
if [[ -z "$GENOME_DIR" ]] || [[ -z "$GTF" ]]; then
  command -v refgenie >/dev/null 2>&1 || {
    echo "ERROR: refgenie not found in PATH (required when --genome-dir or --gtf not supplied)" >&2
    exit 2
  }
fi

# --- Resolve genome resources ------------------------------------------------
[[ -n "$REFGENIE" ]] && export REFGENIE

if [[ -z "$GENOME_DIR" ]]; then
  GENOME_DIR=$(refgenie seek "${REFGENIE_GENOME}/${REFGENIE_STAR_ASSET}") || {
    echo "ERROR: refgenie could not resolve ${REFGENIE_GENOME}/${REFGENIE_STAR_ASSET}" >&2; exit 3
  }
  echo "[refgenie] STAR index : ${GENOME_DIR}"
else
  echo "[INFO] STAR index     : ${GENOME_DIR} (user-supplied)"
fi

if [[ -z "$GTF" ]]; then
  GTF=$(refgenie seek "${REFGENIE_GENOME}/${REFGENIE_GTF_ASSET}") || {
    echo "ERROR: refgenie could not resolve ${REFGENIE_GENOME}/${REFGENIE_GTF_ASSET}" >&2; exit 3
  }
  echo "[refgenie] GTF        : ${GTF}"
else
  echo "[INFO] GTF            : ${GTF} (user-supplied)"
fi

# --- Raise open-file limit (STAR BAM sorter opens many temp files per thread) -
ULIMIT_TARGET=65536
if ! ulimit -n "$ULIMIT_TARGET" 2>/dev/null; then
  echo "[WARN] Could not raise open-file limit to ${ULIMIT_TARGET} (current: $(ulimit -n))"
  echo "[WARN] Consider reducing --threads or running: ulimit -n ${ULIMIT_TARGET}"
fi

# --- Process GTF: decompress if .gz, fix chromosome naming if mismatched -----
GTF_TMP=$(mktemp -t "star_gtf.XXXXXX")
trap "rm -f '${GTF_TMP}'" EXIT

if [[ "$GTF" == *.gz ]]; then
  echo "[INFO] Decompressing GTF..."
  zcat "$GTF" > "$GTF_TMP"
else
  cp "$GTF" "$GTF_TMP"
fi

# Compare first chromosome name in the index vs GTF and convert if needed.
# STAR index always has chrName.txt listing its chromosome names.
if [[ -f "${GENOME_DIR}/chrName.txt" ]]; then
  STAR_CHR=$(head -1 "${GENOME_DIR}/chrName.txt")
  GTF_CHR=$(awk '!/^#/{print $1; exit}' "$GTF_TMP")

  if [[ "$STAR_CHR" == chr* && "$GTF_CHR" != chr* ]]; then
    echo "[INFO] Chromosome name mismatch — STAR index: UCSC (chr*), GTF: Ensembl — adding chr prefix (MT → chrM)..."
    awk 'BEGIN{OFS="\t"} /^#/{print; next} {if ($1=="MT") $1="chrM"; else $1="chr"$1; print}' \
      "$GTF_TMP" > "${GTF_TMP}.conv" && mv "${GTF_TMP}.conv" "$GTF_TMP"

  elif [[ "$STAR_CHR" != chr* && "$GTF_CHR" == chr* ]]; then
    echo "[INFO] Chromosome name mismatch — STAR index: Ensembl, GTF: UCSC (chr*) — removing chr prefix (chrM → MT)..."
    awk 'BEGIN{OFS="\t"} /^#/{print; next} {if ($1=="chrM") $1="MT"; else sub(/^chr/,"",$1); print}' \
      "$GTF_TMP" > "${GTF_TMP}.conv" && mv "${GTF_TMP}.conv" "$GTF_TMP"
  fi
fi

GTF="$GTF_TMP"
echo "[INFO] GTF ready: ${GTF}"

# --- Prepare output dirs and validate metadata -------------------------------
mkdir -p "$OUT_DIR" "$LOG_DIR"

if [[ ! -f "$METADATA" ]]; then
  echo "ERROR: metadata file not found: ${METADATA}" >&2; exit 4
fi

# --- Process samples ---------------------------------------------------------
# Use process substitution (not pipe) so counters are visible after the loop
n_ok=0; n_skip=0; n_warn=0; n_fail=0

while IFS=$'\t' read -ra fields; do
  fastqPrefix="${fields[$((COL_PREFIX   - 1))]}"
  CellType="${fields[$((COL_CELLTYPE - 1))]}"
  Genotype="${fields[$((COL_GENOTYPE - 1))]}"
  ID="${fields[$((COL_ID        - 1))]}"

  R1="${FASTQ_DIR}/${fastqPrefix}${R1_SUFFIX}"
  R2="${FASTQ_DIR}/${fastqPrefix}${R2_SUFFIX}"

  if [[ ! -f "$R1" ]]; then
    echo "[WARN] R1 not found for ${fastqPrefix}, skipping. (${R1})"
    n_warn=$((n_warn + 1))
    continue
  fi

  # Auto-detect paired vs single-end from R2 presence
  if [[ -f "$R2" ]]; then
    read_args=( --readFilesIn "$R1" "$R2" )
    mates_gap_arg=( --alignMatesGapMax 1000000 )
    layout="paired-end"
  else
    read_args=( --readFilesIn "$R1" )
    mates_gap_arg=()
    layout="single-end"
  fi

  SAMPLE_NAME="${CellType}-${Genotype}-${ID}"
  SAMPLE_OUT="${OUT_DIR}/${SAMPLE_NAME}/"
  mkdir -p "$SAMPLE_OUT"

  OUT_BAM="${SAMPLE_OUT}Aligned.sortedByCoord.out.bam"
  OUT_BAI="${OUT_BAM}.bai"
  OUT_COUNTS="${SAMPLE_OUT}ReadsPerGene.out.tab"
  LOG_FILE="${LOG_DIR}/${SAMPLE_NAME}.star.$(date +%Y%m%dT%H%M%S).log"

  # Resume: skip completed samples unless --force
  if [[ -f "$OUT_BAM" ]] && [[ -f "$OUT_BAI" ]] && [[ $FORCE -eq 0 ]]; then
    echo "[SKIP] ${SAMPLE_NAME} — outputs exist, use --force to re-run"
    n_skip=$((n_skip + 1))
    continue
  fi

  # --force: remove existing outputs
  if [[ $FORCE -eq 1 ]]; then
    rm -f "$OUT_BAM" "$OUT_BAI" "$OUT_COUNTS"
    rm -f "${LOG_DIR}/${SAMPLE_NAME}".star.*.log
    rm -rf "${SAMPLE_OUT}_STARtmp"
  fi

  cmd=( STAR
    --runThreadN            "$THREADS"
    --genomeDir             "$GENOME_DIR"
    --sjdbGTFfile           "$GTF"
    "${read_args[@]}"
    --readFilesCommand      zcat
    --outSAMtype            BAM SortedByCoordinate
    --outSAMattributes      NH HI AS NM MD jM jI
    --outSAMstrandField     intronMotif
    --outFilterIntronMotifs RemoveNoncanonical
    --outFilterMultimapNmax 1
    --alignSJoverhangMin    8
    --alignSJDBoverhangMin  1
    --alignSJstitchMismatchNmax 5 -1 5 5
    --alignIntronMin        20
    --alignIntronMax        1000000
    ${mates_gap_arg[@]+"${mates_gap_arg[@]}"}
    --outFileNamePrefix     "$SAMPLE_OUT"
    --outBAMsortingThreadN  "$THREADS"
    --quantMode             GeneCounts
    --twopassMode           Basic )

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] ${SAMPLE_NAME} (${layout}, source: ${fastqPrefix}):"
    printf '    %s\n' "${cmd[@]}"
    echo ""
    continue
  fi

  echo "[STAR] Aligning ${SAMPLE_NAME} (${layout}, source: ${fastqPrefix})..."

  [[ $VERBOSE -eq 1 ]] && printf '%s\n' "[CMD] ${cmd[*]}" >>"$LOG_FILE"

  if ! "${cmd[@]}" >>"$LOG_FILE" 2>&1; then
    echo "[ERROR] STAR failed for ${SAMPLE_NAME} — see ${LOG_FILE}" >&2
    n_fail=$((n_fail + 1))
    continue
  fi

  samtools index "${OUT_BAM}" >>"$LOG_FILE" 2>&1
  echo "[DONE] ${SAMPLE_NAME} (log: ${LOG_FILE})"
  n_ok=$((n_ok + 1))

done < <(tail -n +2 "$METADATA")

echo ""
echo "[STAR] Finished — aligned: ${n_ok}  skipped: ${n_skip}  warned: ${n_warn}  failed: ${n_fail}"
[[ $n_fail -gt 0 ]] && exit 1 || exit 0