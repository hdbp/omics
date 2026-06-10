#' @title Chunked Nucleosome Repeat Length (NRL) and Area Under Curve (AUC) Analysis
#'
#' @description
#' Computes nucleosome repeat length (NRL) and area under curve (AUC) metrics across the genome
#' by dividing a \code{GRanges} or \code{GRangesList} of reads into equal-sized chunks.
#' Each chunk (default 10,000 reads) is smoothed, peaks/minima are identified, and local NRL and AUC
#' are measured. This allows genome-wide mapping of NRL variation.
#'
#' @param reads_gr A \code{GRanges} or \code{GRangesList} object containing aligned read fragments.
#' @param chunk_size Integer. Number of reads per genomic window (default 10,000).
#' @param chromosome Optional character. Restrict analysis to a specific chromosome.
#' @param smooth_k Integer. Rolling mean window size for smoothing fragment length distributions (default: 5).
#' @param peak_window Integer. Half-window size (bp) used for peak detection (default: 50).
#' @param minima_window Integer. Half-window size (bp) for minima detection (default: 50).
#' @param minima_radius Integer. Distance (bp) around a peak within which minima are searched for AUC estimation (default: 150).
#'
#' @details
#' The function smooths the fragment length histogram per chunk using a rolling mean,
#' detects peaks and minima, and computes:
#' \itemize{
#'   \item NRL: Distance between second and third local maxima (in bp).
#'   \item AUC: Area under the curve between local minima flanking the second peak.
#' }
#' This provides high-resolution profiles of nucleosome spacing heterogeneity.
#'
#' @return A tibble with columns:
#' \describe{
#'   \item{chr}{Chromosome.}
#'   \item{start}{Start coordinate of the chunk.}
#'   \item{end}{End coordinate of the chunk.}
#'   \item{n_reads}{Number of reads in the chunk.}
#'   \item{NRL}{Nucleosome repeat length in bp.}
#'   \item{AUC}{Area under curve value.}
#' }
#'
#' @examples
#' \dontrun{
#' library(GenomicRanges)
#' reads <- GRanges(
#'   seqnames = Rle("chr1"),
#'   ranges = IRanges(1:100000, width = sample(150:250, 100000, TRUE))
#' )
#' res <- chunked_NRL_AUC(reads, chunk_size = 10000)
#' head(res)
#' }
#'
#' @export
#' @importFrom dplyr filter count arrange mutate bind_rows
#' @importFrom tibble tibble
#' @importFrom GenomicRanges width seqnames start end sort
#' @importFrom GenomeInfoDb sortSeqlevels
#' @importFrom zoo rollmean

chunked_NRL_AUC <- function(
  reads_gr,
  chunk_size = 10000,
  chromosome = NULL,
  smooth_k = 5,
  peak_window = 50,
  minima_window = 50,
  minima_radius = 150
) {
  # --- 1. Validation -----------------------------------------------------------
  if (!inherits(reads_gr, c("GRanges", "GRangesList"))) {
    stop("`reads_gr` must be a GRanges or GRangesList object.")
  }
  if (!is.numeric(chunk_size) || chunk_size <= 0) {
    stop("`chunk_size` must be a positive integer.")
  }
  if (!is.null(chromosome) && !is.character(chromosome)) {
    stop("`chromosome` must be a character string if provided.")
  }

  # --- 2. Encapsulated helpers -------------------------------------------------
  helpers <- local({
    detect_local_peaks <- function(x, y, halfwin = 50, min_height_frac = 0.02) {
      thr <- max(y, na.rm = TRUE) * min_height_frac
      pk <- vapply(seq_along(y), function(i) {
        l <- max(1, i - halfwin)
        r <- min(length(y), i + halfwin)
        !is.na(y[i]) && y[i] >= thr && y[i] == max(y[l:r], na.rm = TRUE)
      }, logical(1))
      x[pk]
    }

    detect_local_minima <- function(x, y, halfwin = 50) {
      if (length(y) < 3) {
        return(numeric(0))
      }
      dy <- diff(y)
      idx <- which(diff(sign(dy)) == 2) + 1
      idx <- idx[sapply(idx, function(i) {
        l <- max(1, i - halfwin)
        r <- min(length(y), i + halfwin)
        y[i] == min(y[l:r], na.rm = TRUE)
      })]
      x[idx]
    }

    compute_chunk_metrics <- function(fragment_lengths,
                                      smooth_k = 5,
                                      peak_window = 50,
                                      minima_window = 50,
                                      minima_radius = 150) {
      if (length(fragment_lengths) < 50) {
        return(c(NRL = NA_real_, AUC = NA_real_))
      }

      df <- tibble::tibble(len = as.integer(fragment_lengths)) |>
        dplyr::filter(len >= 50, len <= 1000) |>
        dplyr::count(len, name = "n") |>
        dplyr::arrange(len) |>
        dplyr::mutate(
          norm = n / sum(n),
          smooth = zoo::rollmean(norm, k = smooth_k, fill = NA)
        ) |>
        dplyr::filter(!is.na(smooth) & smooth > 0)

      if (nrow(df) <= 5) {
        return(c(NRL = NA_real_, AUC = NA_real_))
      }

      x <- df$len
      y <- df$smooth

      peaks <- detect_local_peaks(x, y, halfwin = peak_window)
      if (length(peaks) < 3) {
        return(c(NRL = NA_real_, AUC = NA_real_))
      }

      peak2 <- peaks[2]
      peak3 <- peaks[3]
      NRL <- peak3 - peak2

      minima <- detect_local_minima(x, y, halfwin = minima_window)
      lc <- minima[minima < peak2 & minima >= peak2 - minima_radius]
      rc <- minima[minima > peak2 & minima <= peak2 + minima_radius]

      if (length(lc) && length(rc)) {
        left <- max(lc)
        right <- min(rc)
        idx <- which(x >= left & x <= right)
        AUC <- if (length(idx) >= 2) {
          sum(diff(x[idx]) * (head(y[idx], -1) + tail(y[idx], -1)) / 2)
        } else {
          NA_real_
        }
      } else {
        AUC <- NA_real_
      }

      c(NRL = NRL, AUC = AUC)
    }

    list(
      detect_local_peaks = detect_local_peaks,
      detect_local_minima = detect_local_minima,
      compute_chunk_metrics = compute_chunk_metrics
    )
  })

  # --- 3. Prepare input --------------------------------------------------------
  if (inherits(reads_gr, "GRangesList")) {
    reads_gr <- base::unlist(reads_gr)
  }

  if (!is.null(chromosome)) {
    reads_gr <- reads_gr[GenomicRanges::seqnames(reads_gr) == chromosome]
    if (length(reads_gr) == 0) {
      stop("No reads found on chromosome ", chromosome)
    }
  }

  reads_gr <- GenomicRanges::sortSeqlevels(reads_gr)
  reads_gr <- GenomicRanges::sort(reads_gr)

  n_frag <- length(reads_gr)
  idx_start <- seq(1L, n_frag, by = chunk_size)
  idx_end <- pmin(idx_start + chunk_size - 1L, n_frag)

  out <- vector("list", length(idx_start))

  # --- 4. Chunk processing -----------------------------------------------------
  for (i in seq_along(idx_start)) {
    rng <- reads_gr[idx_start[i]:idx_end[i]]
    frag_lengths <- GenomicRanges::width(rng)

    metrics <- helpers$compute_chunk_metrics(
      fragment_lengths = frag_lengths,
      smooth_k = smooth_k,
      peak_window = peak_window,
      minima_window = minima_window,
      minima_radius = minima_radius
    )

    out[[i]] <- tibble::tibble(
      chr = as.character(GenomicRanges::seqnames(rng)[1]),
      start = min(GenomicRanges::start(rng)),
      end = max(GenomicRanges::end(rng)),
      n_reads = length(rng),
      NRL = metrics["NRL"],
      AUC = metrics["AUC"]
    )
  }

  # --- 5. Output aggregation ---------------------------------------------------
  dplyr::bind_rows(out)
}
