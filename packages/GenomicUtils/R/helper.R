#' Genomic Utility Helper Functions
#'
#' Helper functions for common genomic analyses including fragment length
#' extraction, GC content calculation, plotting themes, and general data utilities.
#'
#' @name GenomicUtils-helpers
#' @keywords internal
#'
#' @importFrom Rsamtools idxstatsBam testPairedEndBam ScanBamParam scanBamFlag scanBam
#' @importFrom IRanges IRanges
#' @importFrom GenomicRanges GRanges
#' @importFrom graphics par
#' @importFrom tibble tibble
#' @importFrom dplyr filter count arrange mutate bind_rows
#' @importFrom zoo rollmean
NULL


#' Compute 2D point density for scatterplots
#'
#' Computes local 2D density values for x–y points using kernel density estimation.
#'
#' @param x Numeric vector of x coordinates.
#' @param y Numeric vector of y coordinates.
#' @param ... Additional arguments passed to \code{MASS::kde2d}.
#' @return Numeric vector of density values corresponding to input points.
#' @export
get_density <- function(x, y, ...) {
  if (!requireNamespace("MASS", quietly = TRUE)) {
    stop("Package 'MASS' is required for get_density().", call. = FALSE)
  }
  dens <- MASS::kde2d(x, y, ...)
  ix <- findInterval(x, dens$x)
  iy <- findInterval(y, dens$y)
  ii <- cbind(ix, iy)
  dens$z[ii]
}

#' Identify local maxima in a numeric vector
#'
#' Finds peaks (local maxima) using a sliding window.
#' @param x Numeric vector.
#' @param m Integer; window size (default = 3).
#' @return Integer vector of indices corresponding to detected peaks.
#' @export
find_peaks <- function(x, m = 3) {
  shape <- diff(sign(diff(x, na.pad = FALSE)))
  pks <- sapply(which(shape < 0), function(i) {
    z <- max(1, i - m + 1)
    w <- min(length(x), i + m + 1)
    if (all(x[c(z:i, (i + 2):w)] <= x[i + 1])) i + 1 else numeric(0)
  })
  unlist(pks)
}

#' Fragment size distribution from paired-end BAM files
#'
#' Computes fragment length distributions from one or more paired-end BAM files.
#'
#' @param bamFiles Character vector of BAM file paths.
#' @param bamFiles.labels Character vector of labels matching each BAM file.
#' @param index Optional vector of BAM indices (default = same as bamFiles).
#' @return Named list of fragment length distributions.
#' @export
frag <- function(bamFiles, bamFiles.labels, index = bamFiles) {
  opar <- par(c("fig", "mar"))
  on.exit(par(opar))
  pe <- mapply(Rsamtools::testPairedEndBam, bamFiles, index)
  if (any(!pe)) stop(paste(bamFiles[!pe], collapse = ", "), " is not Paired-End.")

  summaryFunction <- function(seqname, seqlength, bamFile, ind, ...) {
    param <- Rsamtools::ScanBamParam(
      what = "isize",
      which = GenomicRanges::GRanges(seqname, IRanges::IRanges(1, seqlength)),
      flag = Rsamtools::scanBamFlag(
        isSecondaryAlignment = FALSE,
        isUnmappedQuery = FALSE,
        isNotPassingQualityControls = FALSE
      )
    )
    table(abs(unlist(sapply(Rsamtools::scanBam(bamFile, index = ind, param = param), `[[`, "isize"), use.names = FALSE)))
  }

  idxstats <- unique(do.call(rbind, mapply(
    function(.ele, .ind) {
      Rsamtools::idxstatsBam(.ele, index = .ind)[, c("seqnames", "seqlength")]
    },
    bamFiles, index,
    SIMPLIFY = FALSE
  )))

  idxstats <- idxstats[idxstats[, "seqnames"] != "*", , drop = FALSE]
  seqnames <- as.character(idxstats[, "seqnames"])
  seqlen <- checkMaxChrLength(as.numeric(idxstats[, "seqlength"]))

  fragment.len <- mapply(
    function(bamFile, ind) {
      summaryFunction(seqname = seqnames, seqlength = seqlen, bamFile, ind)
    },
    bamFiles, index,
    SIMPLIFY = FALSE
  )

  names(fragment.len) <- bamFiles.labels
  fragment.len
}

#' Cap chromosome lengths to maximum allowed
#' @param len Numeric vector of chromosome lengths.
#' @return Numeric vector capped at 2^29.
#' @export
checkMaxChrLength <- function(len) {
  stopifnot(is.numeric(len))
  len[len > 2^29] <- 2^29
  len
}

#' Compute total mapped reads in a BAM file
#' @param bamFile Path to BAM file.
#' @return Total number of mapped reads.
#' @export
totalMapped <- function(bamFile) {
  mapped <- Rsamtools::idxstatsBam(bamFile)
  sum(mapped$mapped)
}

#' Add percent GC content to GRanges metadata
#' @param gr A GRanges object.
#' @param genome A BSgenome object.
#' @return GRanges with added percent_gc metadata column.
#' @export
add_percent_gc <- function(gr, genome) {
  if (!inherits(gr, "GRanges")) stop("`gr` must be a GRanges object.")
  if (!inherits(genome, "BSgenome")) stop("`genome` must be a BSgenome object.")
  GenomeInfoDb::seqlevelsStyle(gr) <- GenomeInfoDb::seqlevelsStyle(genome)[1]
  seqs <- Biostrings::getSeq(genome, gr)
  gc_counts <- Biostrings::letterFrequency(seqs, letters = c("G", "C"))
  total_counts <- BiocGenerics::width(seqs)
  mcols(gr)$percent_gc <- rowSums(gc_counts) / total_counts * 100
  gr
}

#' Custom ggplot2 theme for publication-ready plots
#' @export
theme_custom <- function(
  title_size = 16, title_face = "bold",
  subtitle_size = 14, subtitle_face = "plain", subtitle_color = "red",
  axis_title_size = 12, axis_title_face = "bold",
  axis_text_size = 10, axis_text_face = "plain",
  legend_text_size = 10, legend_text_face = "plain",
  legend_title_size = 12, legend_title_face = "bold",
  grid_major = TRUE, grid_minor = FALSE
) {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop("Package 'ggplot2' is required for theme_custom().", call. = FALSE)
  }
  ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.line = ggplot2::element_line(),
      axis.ticks = ggplot2::element_line(),
      plot.title = ggplot2::element_text(size = title_size, face = title_face),
      plot.subtitle = ggplot2::element_text(
        size = subtitle_size, face = subtitle_face, colour = subtitle_color
      ),
      axis.title = ggplot2::element_text(size = axis_title_size, face = axis_title_face),
      axis.text = ggplot2::element_text(size = axis_text_size, face = axis_text_face),
      legend.text = ggplot2::element_text(size = legend_text_size, face = legend_text_face),
      legend.title = ggplot2::element_text(size = legend_title_size, face = legend_title_face),
      panel.grid.major = if (grid_major) ggplot2::element_line(color = "grey80") else ggplot2::element_blank(),
      panel.grid.minor = if (grid_minor) ggplot2::element_line(color = "grey90") else ggplot2::element_blank()
    )
}

#' Quick bold ggplot2 theme
#' @export
t <- ggplot2::theme_minimal() +
  ggplot2::theme(
    axis.line = ggplot2::element_line(),
    axis.ticks = ggplot2::element_line(),
    plot.title = ggplot2::element_text(size = 14, face = "bold"),
    plot.subtitle = ggplot2::element_text(colour = "red", face = "bold"),
    axis.title = ggplot2::element_text(face = "bold"),
    legend.text = ggplot2::element_text(face = "bold"),
    legend.title = ggplot2::element_text(face = "bold")
  )
