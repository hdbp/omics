# library(dplyr)
# library(ggplot2)
# library(purrr)
# library(grid)
# 
# analyze_fragment_NRL_plot <- function(df, smooth_col = "smooth", window = 100,
#                                       peak_window = 20,
#                                       control_cond = NULL, treatment_cond = NULL,
#                                       colors = NULL, custom_theme = NULL,
#                                       arrow_spacing_factor = 1.2) {
#   
#   if (!smooth_col %in% colnames(df)) stop("smooth_col not found in df")
#   
#   # Detect peaks per condition
#   peaks_list <- df %>%
#     group_by(condition) %>%
#     summarise(
#       peaks = list(detect_local_peaks(length, !!sym(smooth_col), window = window)),
#       .groups = "drop"
#     )
#   
#   # Use 2nd and 3rd peaks
#   summary_table <- peaks_list %>%
#     mutate(
#       peak2 = map_dbl(peaks, ~ if(length(.) >= 2) .[2] else NA_real_),
#       peak3 = map_dbl(peaks, ~ if(length(.) >= 3) .[3] else NA_real_),
#       NRL = peak3 - peak2,
#       AUC2 = map2_dbl(peak2, condition, ~{
#         if(is.na(.x)) return(NA_real_)
#         rows <- df %>% dplyr::filter(condition == .y,
#                                      length >= (.x - peak_window),
#                                      length <= (.x + peak_window))
#         sum(rows[[smooth_col]], na.rm = TRUE)
#       })
#     )
#   
#   # Compute differences only if both control and treatment are specified
#   delta_NRL <- delta_AUC2_pct <- NA_real_
#   if (!is.null(control_cond) && !is.null(treatment_cond)) {
#     if(all(c(control_cond, treatment_cond) %in% summary_table$condition)) {
#       delta_NRL <- summary_table$NRL[summary_table$condition == treatment_cond] -
#         summary_table$NRL[summary_table$condition == control_cond]
#       
#       AUC_control <- summary_table$AUC2[summary_table$condition == control_cond]
#       AUC_treat <- summary_table$AUC2[summary_table$condition == treatment_cond]
#       delta_AUC2_pct <- (AUC_treat - AUC_control) / AUC_control * 100
#     }
#   }
#   
#   # Prepare arrow positions: stagger arrows to avoid overlap
#   max_smooth <- max(df[[smooth_col]], na.rm = TRUE)
#   n_conditions <- nrow(summary_table)
#   base_spacing <- max_smooth * 0.05
#   arrow_spacing <- base_spacing * arrow_spacing_factor
#   
#   summary_table <- summary_table %>%
#     mutate(
#       arrow_y = max_smooth * 0.9 - (row_number() - 1) * arrow_spacing,
#       text_y  = arrow_y - arrow_spacing / 3
#     )
#   
#   # Build plot
#   p <- ggplot(df, aes(x = length, y = !!sym(smooth_col), color = condition)) +
#     geom_line(size = 0.8) +
#     geom_vline(data = summary_table, aes(xintercept = peak2, color = condition),
#                linetype = "dotted", size = 0.7) +
#     geom_vline(data = summary_table, aes(xintercept = peak3, color = condition),
#                linetype = "dashed", size = 0.7) +
#     geom_segment(data = summary_table,
#                  aes(x = peak2, xend = peak3, y = arrow_y, yend = arrow_y),
#                  color = "black", arrow = arrow(length = unit(0.15, "cm"))) +
#     geom_text(data = summary_table,
#               aes(x = (peak2 + peak3)/2, y = text_y,
#                   label = paste0("NRL: ", NRL, " bp")),
#               vjust = 1, hjust = 0.5, color = "black") +
#     labs(x = "Fragment length (bp)", y = "Normalized count",
#          title = "Fragment length distribution with NRL (2nd-3rd peak)")
#   
#   # Apply custom colors if provided
#   if (!is.null(colors)) {
#     p <- p + scale_color_manual(values = colors)
#   }
#   
#   # Apply custom theme if provided
#   if (!is.null(custom_theme)) {
#     p <- p + custom_theme
#   } else {
#     p <- p + theme_minimal()
#   }
#   
#   # Add top-right corner annotation for deltas if available
#   if (!is.na(delta_NRL) && !is.na(delta_AUC2_pct)) {
#     p <- p + annotate("text",
#                       x = max(df$length, na.rm = TRUE),
#                       y = max(df[[smooth_col]], na.rm = TRUE),
#                       label = paste0("ΔNRL: ", round(delta_NRL,1), " bp\n",
#                                      "ΔAUC2: ", round(delta_AUC2_pct,1), "%"),
#                       hjust = 1, vjust = 1.2, size = 4, color = "black")
#   }
#   
#   return(list(summary = summary_table, plot = p))
# }
library(GenomicRanges)
library(Rsamtools)
library(furrr)
library(dplyr)
library(zoo)
library(ggplot2)
library(GenomicFeatures)

compute_genome_wide_deltas <- function(bam_file, txdb, 
                                       window_size = 100000, step_frac = 0.5, 
                                       peak_window = 20, smooth_k = 5,
                                       n_cores = 24,
                                       chromosomes = NULL,
                                       regions = NULL) {
  
  # -------------------------
  # 1. Get chromosome lengths from TxDb
  seq_lengths <- seqlengths(txdb)
  genome <- tibble(chr = names(seq_lengths), length = as.numeric(seq_lengths))
  
  if(!is.null(chromosomes)){
    genome <- genome %>% dplyr::filter(chr %in% chromosomes)
  }
  
  # -------------------------
  # 2. Generate windows
  step_size <- round(window_size * step_frac)
  
  if(!is.null(regions)){
    # user provided specific ranges
    windows <- regions
    if(!inherits(windows, "GRanges")) stop("regions must be a GRanges object")
  } else {
    # genome-wide or selected chromosomes
    windows <- lapply(seq_len(nrow(genome)), function(i){
      chr <- genome$chr[i]
      chr_len <- genome$length[i]
      
      w <- min(window_size, chr_len)   # trim if chromosome shorter than window
      starts <- seq(1, chr_len - w + 1, by = step_size)
      GRanges(seqnames = chr, ranges = IRanges(start = starts, width = w))
    })
    windows <- do.call(c, windows)
  }
  
  # -------------------------
  # 3. Prepare BAM
  bam_index <- paste0(bam_file, ".bai")
  if(!file.exists(bam_index)) indexBam(bam_file)
  bam <- BamFile(bam_file, yieldSize = 1e6)
  
  # -------------------------
  # 4. Local peak detection
  detect_local_peaks <- function(x, y, window = 20, min_height_frac = 0.02){
    n <- length(y)
    if(n == 0) return(numeric(0))
    peaks <- integer(0)
    thr <- max(y, na.rm = TRUE) * min_height_frac
    for(i in seq_len(n)){
      l <- max(1, i - window)
      r <- min(n, i + window)
      if(!is.na(y[i]) && y[i] >= thr && y[i] == max(y[l:r], na.rm = TRUE)){
        peaks <- c(peaks, i)
      }
    }
    x[peaks]
  }
  
  # -------------------------
  # 5. Compute metrics per window
  plan(multisession, workers = n_cores)
  results <- future_map_dfr(seq_along(windows), function(i){
    gr_win <- windows[i]
    
    param <- ScanBamParam(which = gr_win)
    reads <- scanBam(bam, param = param)[[1]]
    if(length(reads$qwidth) == 0) return(tibble(NRL = NA, AUC = NA))
    
    frags <- tibble(length = reads$qwidth)
    
    counts <- table(frags$length)
    lengths <- as.numeric(names(counts))
    norm_count <- counts / sum(counts)
    smooth_count <- zoo::rollmean(norm_count, k = smooth_k, fill = NA)
    
    peaks <- detect_local_peaks(lengths, smooth_count, window = peak_window)
    if(length(peaks) < 3) return(tibble(NRL = NA, AUC = NA))
    
    NRL <- peaks[3] - peaks[2]
    
    idx <- which(lengths >= (peaks[2] - peak_window) & lengths <= (peaks[2] + peak_window))
    x <- lengths[idx]
    y <- smooth_count[idx]
    AUC <- sum(diff(x) * (head(y,-1) + tail(y,-1))/2)
    
    tibble(NRL = NRL, AUC = AUC,
           chr = as.character(seqnames(gr_win)),
           start = start(gr_win),
           end = end(gr_win),
           window_index = i)
  }, .progress = TRUE)
  
  # -------------------------
  # 6. Compute delta metrics per chromosome
  results <- results %>%
    arrange(chr, start) %>%
    group_by(chr) %>%
    mutate(delta_NRL = NRL - lag(NRL),
           delta_AUC = AUC - lag(AUC)) %>%
    ungroup()
  
  # -------------------------
  # 7. Generate plots
  plot_delta_NRL <- ggplot(results, aes(x = window_index, y = delta_NRL)) +
    geom_line() + theme_minimal() +
    labs(y = "ΔNRL (bp)", x = "Window index")
  
  plot_delta_AUC <- ggplot(results, aes(x = window_index, y = delta_AUC)) +
    geom_line() + theme_minimal() +
    labs(y = "ΔAUC", x = "Window index")
  
  list(results = results, plot_delta_NRL = plot_delta_NRL, plot_delta_AUC = plot_delta_AUC)
}

