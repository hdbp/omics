#' Plot stranded genomic coverage and transcripts for a gene
#'
#' Visualize strand-specific coverage (e.g., ChIP-seq, ATAC-seq, PRO-seq)
#' alongside transcript models for a specified gene in mouse (\code{mm10}) or
#' human (\code{hg38}) genomes.
#'
#' This wrapper combines \pkg{BRGenomics} for stranded coverage estimation and
#' \pkg{tidyGenomeBrowser} for visual layout, automatically fetching
#' transcript annotations from \pkg{TxDb} and \pkg{org.*.eg.db} databases.
#'
#' @param gr A \code{GRanges} object containing genomic signal (e.g., reads, coverage, or scores).
#' @param gene Character or numeric; gene name (symbol or Entrez ID).
#' @param genome Character; genome assembly, either \code{"mm10"} or \code{"hg38"} (default: \code{"mm10"}).
#' @param ylim Optional numeric vector of length 2 specifying y-axis limits for the coverage track.
#' @param heights Optional numeric vector specifying relative heights of coverage and transcript panels.
#' @param flank_bp Integer; number of base pairs to include as flanking regions (default: \code{1000}).
#' @param ncores Integer; number of cores used for \code{BRGenomics::getStrandedCoverage} (default: \code{24}).
#'
#' @details
#' The function detects the genome assembly and automatically loads the appropriate
#' annotation and gene ID mapping databases:
#' \itemize{
#'   \item Mouse: \pkg{TxDb.Mmusculus.UCSC.mm10.knownGene}, \pkg{org.Mm.eg.db}
#'   \item Human: \pkg{TxDb.Hsapiens.UCSC.hg38.knownGene}, \pkg{org.Hs.eg.db}
#' }
#'
#' @return A \code{ggplot} object showing stranded coverage and annotated transcripts,
#' combined using \pkg{patchwork} stacking.
#'
#' @seealso \code{\link[BRGenomics]{getStrandedCoverage}}, \code{\link[tidyGenomeBrowser]{browseStack}}
#' @export
#'
#' @importFrom BRGenomics getStrandedCoverage
#' @importFrom GenomicRanges GRanges GRangesList resize width seqnames
#' @importFrom GenomicFeatures exonsBy genes
#' @importFrom ggplot2 scale_size_manual theme_minimal ylim labs
#' @importFrom tidyGenomeBrowser browseSignal browseTranscripts browseStack
#' @importFrom patchwork plot_annotation
#'
#' @import magrittr
#' @examples
#' \dontrun{
#' library(BRGenomics)
#' library(GenomicRanges)
#' gr <- GRanges(seqnames = "chr1", ranges = IRanges(1, 1000))
#' plot_browser(gr, gene = "Actb", genome = "mm10")
#' }
plot_browser <- function(
    gr,
    gene,
    sample_names,
    genome = c("mm10", "hg38"),
    ylim = NULL,
    heights = c(5,1),
    flank_bp = 1000,
    signal_color=signal_color,
    ncores = 24) {
  genome <- match.arg(genome)
  gr <- GRangesList(gr)
  

  
  # --- 1. Validate inputs
  if (!inherits(gr, c("GRanges",'GRangesList'))) {
    stop("`gr` must be a GRanges or GRangesList object.")
  }
  if (!is.numeric(flank_bp) || flank_bp < 0) {
    stop("`flank_bp` must be a non-negative integer.")
  }
  if (!is.numeric(ncores) || ncores < 1) {
    stop("`ncores` must be a positive integer.")
  }

  # --- 2. Compute stranded coverage
  # --- 2. Compute stranded coverage
  normalize_and_get_coverage <- function(gr, ncores = 24) {
    if (inherits(gr, "GRanges")) {
      lib.size <- sum(gr$score, na.rm = TRUE)
      gr$score <- gr$score / (lib.size / 1e6)
      cov <- BRGenomics::getStrandedCoverage(gr, ncores = ncores)
    } else if (inherits(gr, "GRangesList")) {
      gr <- lapply(gr, function(g) {
        lib.size <- sum(g$score, na.rm = TRUE)
        g$score <- g$score / (lib.size / 1e6)
        g
      })
      cov <- BRGenomics::getStrandedCoverage(gr, ncores = ncores)
    } else {
      stop("`gr` must be a GRanges or GRangesList object.")
    }
    cov
  }
  
  cov <- normalize_and_get_coverage(gr, ncores = ncores)
  names(cov) <- sample_names
  
  cov <- BRGenomics::mergeReplicates(cov,makeBRG = F,exact_overlaps = F,ncores = 24) #sample_names = paste('Sample_rep',seq(1,length(cov)),sep = ''))
  
    # --- 3. Load genome-specific databases safely
  txdb <- orgdb <- NULL
  if (genome == "mm10") {
    if (!requireNamespace("TxDb.Mmusculus.UCSC.mm10.knownGene", quietly = TRUE) ||
      !requireNamespace("org.Mm.eg.db", quietly = TRUE)) {
      stop("Required packages for mm10 not installed: TxDb.Mmusculus.UCSC.mm10.knownGene and org.Mm.eg.db")
    }
    txdb <- get("TxDb.Mmusculus.UCSC.mm10.knownGene", asNamespace("TxDb.Mmusculus.UCSC.mm10.knownGene"))
    orgdb <- get("org.Mm.eg.db", asNamespace("org.Mm.eg.db"))
    } else if (genome == "hg38") {
    if (!requireNamespace("TxDb.Hsapiens.UCSC.hg38.knownGene", quietly = TRUE) ||
      !requireNamespace("org.Hs.eg.db", quietly = TRUE)) {
      stop("Required packages for hg38 not installed: TxDb.Hsapiens.UCSC.hg38.knownGene and org.Hs.eg.db")
    }
    txdb <- get("TxDb.Hsapiens.UCSC.hg38.knownGene", asNamespace("TxDb.Hsapiens.UCSC.hg38.knownGene"))
    orgdb <- get("org.Hs.eg.db", asNamespace("org.Hs.eg.db"))
  }

  # --- 4. Retrieve annotation models
  meta_models <- GenomicFeatures::exonsBy(txdb, by = "gene",use.names=F)
  genes_all <- GenomicFeatures::genes(txdb)

  # --- 5. Map gene symbol or Entrez ID
  gene_key_type <- if (is.numeric(gene)) "ENTREZID" else "SYMBOL"
  anno <- AnnotationDbi::select(
    orgdb,
    keys = as.character(gene),
    keytype = gene_key_type,
    columns = c("ALIAS", "ENTREZID", "SYMBOL")
  )

  
  if (nrow(anno) == 0) stop("Gene not found in ", genome)
  entrez_id <- unique(anno$ENTREZID[!is.na(anno$ENTREZID)])
  if (length(entrez_id) == 0) {
    stop("No Entrez ID mapping found for ", gene)
  }

  gene_range <- genes_all[genes_all$gene_id == entrez_id]
  if (length(gene_range) == 0) {
    stop("No genomic range found for ", gene)
  }

  # --- 6. Expand genomic window symmetrically
  ranges <- GenomicRanges::resize(
    gene_range,
    width = GenomicRanges::width(gene_range) + 2 * flank_bp,
    fix = "center",
    ignore.strand = TRUE
  )

  # --- 7. Plot stranded coverage
  options(tidyGenomeBrowser.strand=c(`+`="blue",
                                     `-`="red",
                                     `*`= signal_color))
  options(tidyGenomeBrowser.name=FALSE)
  
  
  
  signal <- tidyGenomeBrowser::browseSignal(
    GenomicRanges::GRangesList(cov),
    region = ranges) +
    ggplot2::scale_size_manual(values = 2) +
    # ggplot2::scale_fill_manual(breaks = 'Sample',values = fill) +
   # theme_custom() +
    theme(legend.position = 'none',
          panel.grid.major = element_blank(),
          panel.grid.minor=element_blank())#+ scale_fill_manual(values = c( entrez_id = trx_color))  + scale_color_manual(values = c( entrez_id = trx_color))
  

  if (!is.null(ylim)) {
    signal <- signal + ggplot2::ylim(ylim)
  }

  # --- 8. Transcript track
  track <- tidyGenomeBrowser::browseTranscripts(meta_models, region = ranges) +
    #theme_custom() + 
    ylim(0.5,1.5)+
    theme_custom()+
    theme(axis.text.y = element_blank(), 
          axis.ticks.y = element_blank(),
          panel.grid.major = element_blank(),
          panel.grid.minor=element_blank())#+ scale_fill_manual(values = c( entrez_id = trx_color))  + scale_color_manual(values = c( entrez_id = trx_color))

  # --- 9. Stack both tracks
  tidy_list <- list(signal, track)
  stacked_plot <- if (!is.null(heights)) {
    tidyGenomeBrowser::browseStack(tidy_list, heights = heights)
  } else {
    tidyGenomeBrowser::browseStack(tidy_list)
  }

  # --- 10. Final annotated plot
  stacked_plot + patchwork::plot_annotation(
    title = anno$SYMBOL[1],
    subtitle = paste0(genome, " | ", anno$ENTREZID[1]),
    theme = ggplot2::theme(
      plot.title = ggplot2::element_text(face = "bold", hjust = 0.5)
    )
  ) #+ theme_custom()
}
