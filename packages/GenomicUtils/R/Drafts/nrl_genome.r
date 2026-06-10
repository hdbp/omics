chunked_NRL_AUC <- function(reads_gr,
                            chunk_size     = 10000,
                            chromosome     = NULL,
                            smooth_k       = 5,
                            peak_window    = 50,
                            minima_window  = 50,
                            minima_radius  = 150) {
  # --- required packages ---
  suppressPackageStartupMessages({
    requireNamespace("dplyr", quietly = TRUE)
    requireNamespace("GenomicRanges", quietly = TRUE)
    requireNamespace("zoo", quietly = TRUE)
  })

  # --- internal helper: local peaks ---
  .detect_local_peaks <- function(x, y, halfwin = 50, min_height_frac = 0.02) {
    thr <- max(y, na.rm = TRUE) * min_height_frac
    pk <- vapply(seq_along(y), function(i) {
      l <- max(1, i - halfwin); r <- min(length(y), i + halfwin)
      !is.na(y[i]) && y[i] >= thr && y[i] == max(y[l:r], na.rm = TRUE)
    }, logical(1))
    x[pk]
  }

  # --- internal helper: local minima ---
  .detect_local_minima <- function(x, y, halfwin = 50) {
    if (length(y) < 3) return(numeric(0))
    dy  <- diff(y)
    idx <- which(diff(sign(dy)) == 2) + 1
    idx <- idx[sapply(idx, function(i) {
      l <- max(1, i - halfwin); r <- min(length(y), i + halfwin)
      y[i] == min(y[l:r], na.rm = TRUE)
    })]
    x[idx]
  }

  # --- internal helper: compute metrics for one chunk ---
  .compute_chunk_metrics <- function(fragment_lengths,
                                     smooth_k      = 5,
                                     peak_window   = 50,
                                     minima_window = 50,
                                     minima_radius = 150) {
    if (length(fragment_lengths) < 50)
      return(c(NRL = NA_real_, AUC = NA_real_))

    df <- dplyr::tibble(len = as.integer(fragment_lengths)) |>
      dplyr::filter(len >= 50, len <= 1000) |>
      dplyr::count(len, name = "n") |>
      dplyr::arrange(len) |>
      dplyr::mutate(norm   = n / sum(n),
                    smooth = zoo::rollmean(norm, k = smooth_k, fill = NA)) |>
      dplyr::filter(!is.na(smooth) & smooth > 0)

    if (nrow(df) <= 5) return(c(NRL = NA_real_, AUC = NA_real_))

    x <- df$len
    y <- df$smooth

    peaks <- .detect_local_peaks(x, y, halfwin = peak_window)
    if (length(peaks) < 3) return(c(NRL = NA_real_, AUC = NA_real_))

    peak2 <- peaks[2]
    peak3 <- peaks[3]
    NRL   <- peak3 - peak2

    minima <- .detect_local_minima(x, y, halfwin = minima_window)
    lc <- minima[minima <  peak2 & minima >= peak2 - minima_radius]
    rc <- minima[minima >  peak2 & minima <= peak2 + minima_radius]

    if (length(lc) && length(rc)) {
      left  <- max(lc)
      right <- min(rc)
      idx   <- which(x >= left & x <= right)
      AUC   <- if (length(idx) >= 2)
        sum(diff(x[idx]) * (head(y[idx], -1) + tail(y[idx], -1)) / 2)
      else NA_real_
    } else {
      AUC <- NA_real_
    }

    c(NRL = NRL, AUC = AUC)
  }

  # --- core logic: validate input ---
  if (inherits(reads_gr, "GRangesList"))
    reads_gr <- GenomicRanges::unlist(reads_gr)
  if (!inherits(reads_gr, "GRanges"))
    stop("reads_gr must be a GRanges or GRangesList")

  # --- optional chromosome filtering ---
  if (!is.null(chromosome)) {
    reads_gr <- reads_gr[GenomicRanges::seqnames(reads_gr) == chromosome]
    if (length(reads_gr) == 0)
      stop("No reads found on chromosome ", chromosome)
  }

  # --- sort by genomic order ---
  reads_gr <- GenomicRanges::sortSeqlevels(reads_gr)
  reads_gr <- GenomicRanges::sort(reads_gr)

  n_frag <- length(reads_gr)
  idx_start <- seq(1L, n_frag, by = chunk_size)
  idx_end   <- pmin(idx_start + chunk_size - 1L, n_frag)
  out <- vector("list", length(idx_start))

  for (i in seq_along(idx_start)) {
    rng <- reads_gr[idx_start[i]:idx_end[i]]
    frag_lengths <- GenomicRanges::width(rng)

    metrics <- .compute_chunk_metrics(
      frag_lengths,
      smooth_k,
      peak_window,
      minima_window,
      minima_radius
    )

    out[[i]] <- dplyr::tibble(
      chr     = as.character(GenomicRanges::seqnames(rng)[1]),
      start   = min(GenomicRanges::start(rng)),
      end     = max(GenomicRanges::end(rng)),
      n_reads = length(rng),
      NRL     = metrics["NRL"],
      AUC     = metrics["AUC"]
    )
  }

  dplyr::bind_rows(out)
}
