#' Plot genomic coverage and transcripts for a gene
#'
#' Wrapper for BRGenomics and tidyGenomeBrowser to visualize
#' stranded coverage and transcript models for a gene in mouse or human.
#'
#' @param gr A \code{GRanges} object with signal (e.g., ChIP-seq, ATAC-seq, PRO-seq).
#' @param gene Gene name (symbol or Entrez ID).
#' @param genome Genome assembly, either "mm10" or "hg38" (default: "mm10").
#' @param ylim Optional numeric vector of length 2 to set y-axis limits for coverage track.
#' @param heights Optional numeric vector defining relative heights of coverage and transcript tracks.
#' @param flank_bp Number of base pairs to flank the gene region (default: 1000).
#' @param ncores Number of cores for \code{BRGenomics::getStrandedCoverage} (default: 24).
#'
#' @return A ggplot object stacked with coverage and transcript tracks.
#' @export
#'
#' @examples
#' \dontrun{
#' library(BRGenomics)
#' library(GenomicRanges)
#' gr <- GRanges(seqnames = "chr1", ranges = IRanges(1, 1000))
#' plot_browser(gr, gene = "Actb", genome = "mm10")
#' }
plot_browser <- function(gr, gene, genome = c("mm10", "hg38"),
                         ylim = NULL, heights = NULL,
                         flank_bp = 1000, ncores = 24) {
  genome <- match.arg(genome)

  # Coverage
  cov <- BRGenomics::getStrandedCoverage(gr, ncores = ncores, score = "score")

  # Genome-specific databases
  if (genome == "mm10") {
    txdb <- TxDb.Mmusculus.UCSC.mm10.knownGene
    orgdb <- org.Mm.eg.db
  } else {
    txdb <- TxDb.Hsapiens.UCSC.hg38.knownGene
    orgdb <- org.Hs.eg.db
  }

  meta_models <- GenomicFeatures::exonsBy(txdb, by = "gene")
  genes_all <- GenomicFeatures::genes(txdb)

  # Map gene ID
  gene_key_type <- if (is.numeric(gene)) "ENTREZID" else "SYMBOL"
  anno <- AnnotationDbi::select(orgdb,
    keys = as.character(gene),
    keytype = gene_key_type,
    columns = c("ALIAS", "ENTREZID", "SYMBOL")
  )

  if (nrow(anno) == 0) stop("Gene not found in ", genome)

  gene_range <- genes_all[genes_all$gene_id == anno$ENTREZID]
  if (length(gene_range) == 0) stop("No genomic range found for ", gene)

  # Expand region symmetrically
  ranges <- GenomicRanges::resize(gene_range,
    width = GenomicRanges::width(gene_range) + 2 * flank_bp,
    fix = "center",
    ignore.strand = TRUE
  )

  # Coverage track
  signal <- tidyGenomeBrowser::browseSignal(GRangesList(cov), region = ranges) +
    ggplot2::scale_size_manual(values = 2) +
    ggplot2::theme_minimal()

  if (!is.null(ylim)) {
    signal <- signal + ggplot2::ylim(ylim)
  }

  # Transcript track
  track <- tidyGenomeBrowser::browseTranscripts(meta_models, region = ranges) +
    ggplot2::theme_minimal()

  tidy_list <- list(signal, track)

  if (!is.null(heights)) {
    tidyGenomeBrowser::browseStack(tidy_list, heights = heights) +
      patchwork::plot_annotation(title = anno$SYMBOL[1])
  } else {
    tidyGenomeBrowser::browseStack(tidy_list) +
      patchwork::plot_annotation(title = anno$SYMBOL[1])
  }
}
