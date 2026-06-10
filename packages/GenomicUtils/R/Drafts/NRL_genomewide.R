# ============================================================
#  Chunked NRL & AUC computation on a sorted GRanges
# ============================================================
#  • reads_gr    : GRanges or GRangesList (one range per fragment)
#  • chunk_size  : number of reads per block   (default 10 000)
#  • chromosome  : single chr string (e.g. "chr19") or NULL to use all
#  • smooth_k    : rolling-mean window for histogram smoothing
#  • peak_window : halfwindow (bins) for local-peak detection
#  • minima_window  : halfwindow for local-min detection
#  • minima_radius  : ± bp window around peak2 in which to search minima
#  ------------------------------------------------------------
#  Returns a data.frame  chr | start | end | n_reads | NRL | AUC
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(GenomicRanges)
  library(zoo)
})

# ---------- helper: local peaks ----------------------------------------------
detect_local_peaks <- function(x, y, halfwin = 50, min_height_frac = 0.02) {
  thr <- max(y, na.rm = TRUE) * min_height_frac
  pk  <- vapply(seq_along(y), function(i) {
    l <- max(1, i - halfwin); r <- min(length(y), i + halfwin)
    !is.na(y[i]) && y[i] >= thr && y[i] == max(y[l:r], na.rm = TRUE)
  }, logical(1))
  x[pk]
}

# ---------- helper: local minima ---------------------------------------------
detect_local_minima <- function(x, y, halfwin = 50) {
  if (length(y) < 3) return(numeric(0))
  dy  <- diff(y)
  idx <- which(diff(sign(dy)) == 2) + 1
  idx <- idx[sapply(idx, function(i) {
    l <- max(1, i - halfwin); r <- min(length(y), i + halfwin)
    y[i] == min(y[l:r], na.rm = TRUE)
  })]
  x[idx]
}

# ---------- compute metrics for one chunk ------------------------------------
compute_chunk_metrics <- function(fragment_lengths,
                                  smooth_k      = 5,
                                  peak_window   = 50,
                                  minima_window = 50,
                                  minima_radius = 150) {
  
  if (length(fragment_lengths) < 50)
    return(c(NRL = NA_real_, AUC = NA_real_))
  
  df <- tibble(len = as.integer(fragment_lengths)) |>
    filter(len >= 50, len <= 1000) |>
    count(len, name = "n") |>
    arrange(len) |>
    mutate(norm   = n / sum(n),
           smooth = zoo::rollmean(norm, k = smooth_k, fill = NA)) |>
    filter(!is.na(smooth) & smooth > 0)
  
  if (nrow(df) <= 5) return(c(NRL = NA_real_, AUC = NA_real_))
  
  x <- df$len
  y <- df$smooth
  
  peaks <- detect_local_peaks(x, y, halfwin = peak_window)
  if (length(peaks) < 3) return(c(NRL = NA_real_, AUC = NA_real_))
  
  peak2 <- peaks[2]; peak3 <- peaks[3]
  NRL   <- peak3 - peak2
  
  minima <- detect_local_minima(x, y, halfwin = minima_window)
  lc <- minima[minima <  peak2 & minima >= peak2 - minima_radius]
  rc <- minima[minima >  peak2 & minima <= peak2 + minima_radius]
  
  if (length(lc) && length(rc)) {
    left  <- max(lc); right <- min(rc)
    idx   <- which(x >= left & x <= right)
    AUC   <- if (length(idx) >= 2)
      sum(diff(x[idx]) * (head(y[idx], -1) + tail(y[idx], -1)) / 2)
    else NA_real_
  } else AUC <- NA_real_
  
  c(NRL = NRL, AUC = AUC)
}

# ---------- main wrapper ------------------------------------------------------
chunked_NRL_AUC <- function(reads_gr,
                            chunk_size     = 10000,
                            chromosome     = NULL,   # <-- new argument
                            smooth_k       = 5,
                            peak_window    = 50,
                            minima_window  = 50,
                            minima_radius  = 150) {
  
  if (inherits(reads_gr, "GRangesList"))
    reads_gr <- GenomicRanges::unlist(reads_gr)
  if (!inherits(reads_gr, "GRanges"))
    stop("reads_gr must be a GRanges or GRangesList")
  
  # optional chromosome filter
  if (!is.null(chromosome)) {
    reads_gr <- reads_gr[seqnames(reads_gr) == chromosome]
    if (length(reads_gr) == 0)
      stop("No reads found on chromosome ", chromosome)
  }
  
  # sort by chromosome then start
  reads_gr <- sortSeqlevels(reads_gr)
  reads_gr <- sort(reads_gr)          # genomic order
  
  n_frag <- length(reads_gr)
  idx_start <- seq(1L, n_frag, by = chunk_size)
  idx_end   <- pmin(idx_start + chunk_size - 1L, n_frag)
  
  out <- vector("list", length(idx_start))
  
  for (i in seq_along(idx_start)) {
    rng <- reads_gr[idx_start[i]:idx_end[i]]
    frag_lengths <- width(rng)
    
    metrics <- compute_chunk_metrics(
      frag_lengths,
      smooth_k, peak_window,
      minima_window, minima_radius
    )
    
    out[[i]] <- tibble(
      chr     = as.character(seqnames(rng)[1]),
      start   = min(start(rng)),
      end     = max(end(rng)),
      n_reads = length(rng),
      NRL     = metrics["NRL"],
      AUC     = metrics["AUC"]
    )
  }
  
  bind_rows(out)
}

# ---------------- example -----------------------------------------------------
# usage:
# result <- chunked_NRL_AUC(
#   reads_gr   = my_reads,
#   chunk_size = 10000,
#   chromosome = "chr19",       # set NULL to use all chromosomes
#   smooth_k   = 7
# )
# head(result)






library(dplyr)
library(tidyr)
library(ggplot2)
library(viridis)   # nice perceptually-uniform palette

## ---- 1. your data.frame ------------------------------------------------------
# Assume df is the data you pasted
# df <- readr::read_tsv("…")   # or however you built it

## ---- 2. tidy-up & derive window index ---------------------------------------
df_clean <- result_chr19 %>%                   # keep original if you like
  mutate(NRL = replace_na(NRL, 0),
         AUC = replace_na(AUC, 0)) %>%
  group_by(chr) %>%
  arrange(start, .by_group = TRUE) %>%
  mutate(win_id = row_number()) %>%   # 1,2,3 … per chromosome
  ungroup()

## ---- 3. a helper for quick heat-maps ----------------------------------------
plot_heat <- function(data, value_col, title, palette = "viridis") {
  ggplot(data, aes(x = win_id,        # columns left→right
                   y = chr,           # rows per chromosome
                   fill = .data[[value_col]])) +
    geom_tile(color = "grey30", size = 0.1) +
    scale_fill_viridis_c(option = palette, na.value = "white") +
    labs(x = "Window (#)", y = NULL, fill = value_col, title = title) +
    theme_minimal(base_size = 12) +
    theme(panel.grid = element_blank(),
          axis.text.x = element_blank(),
          axis.ticks.x = element_blank(),
          legend.position = "right",
          plot.title = element_text(face = "bold"))
}

## ---- 4. draw the two heat-maps ----------------------------------------------
heat_nrl <- plot_heat(df_clean, "NRL", "NRL Heat-map")
heat_auc <- plot_heat(df_clean, "AUC", "AUC Heat-map", palette = "magma")

# Print them (in RStudio you’ll see two plots)
heat_nrl
heat_auc

heat_nrl / heat_auc  # or combine with patchwork if you like
