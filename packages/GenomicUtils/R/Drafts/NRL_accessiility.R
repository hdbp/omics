# library(dplyr)
# library(ggplot2)
# library(purrr)
# library(zoo)
# library(grid)
# 
# # Updated detect_local_peaks to use 'window' argument
# detect_local_peaks <- function(x_pos, y_val, window = 50, min_height_frac = 0.02) {
#   n <- length(y_val)
#   if (n == 0) return(numeric(0))
#   peaks_idx <- integer(0)
#   thr <- max(y_val, na.rm = TRUE) * min_height_frac
#   for (i in seq_len(n)) {
#     l <- max(1, i - window)
#     r <- min(n, i + window)
#     # local maximum
#     if (!is.na(y_val[i]) && y_val[i] >= thr && y_val[i] == max(y_val[l:r], na.rm = TRUE)) {
#       peaks_idx <- c(peaks_idx, i)
#     }
#   }
#   x_pos[peaks_idx]
# }
# 
# analyze_fragment_NRL_plot <- function(fragment_df, sample_col = "sample", length_col = "length",
#                                       sample_conditions = NULL, control_condition = NULL,
#                                       smooth_k = 5, smooth_window = 10, peak_window = 100,
#                                       arrow_spacing_factor = 1.2, colors = NULL, custom_theme = NULL) {
# 
#   # Add condition column if not already present
#   if (!"condition" %in% colnames(fragment_df)) {
#     if (is.null(sample_conditions)) stop("You must provide sample_conditions if no 'condition' column exists")
#     fragment_df <- fragment_df %>%
#       dplyr::mutate(condition = sample_conditions[match(.data[[sample_col]], names(sample_conditions))])
#   }
# 
#   # Filter fragment lengths and summarize
#   norm_frag <- fragment_df %>%
#     dplyr::filter(.data[[length_col]] >= 50 & .data[[length_col]] <= 1000) %>%
#     dplyr::group_by(condition, .data[[length_col]]) %>%
#     dplyr::summarise(count = dplyr::n(), .groups = "drop_last") %>%
#     dplyr::mutate(norm_count = count / sum(count)) %>%
#     dplyr::group_by(condition) %>%
#     dplyr::mutate(smooth = zoo::rollmean(norm_count, k = smooth_k, fill = NA)) %>%
#     dplyr::ungroup()
# 
#   # Detect peaks per condition using updated 'window' argument
#   peaks_list <- norm_frag %>%
#     dplyr::group_by(condition) %>%
#     dplyr::summarise(
#       peaks = list(detect_local_peaks(.data[[length_col]], smooth, window = smooth_window)),
#       .groups = "drop"
#     )
# 
#   # Use 2nd and 3rd peaks
#   summary_table <- peaks_list %>%
#     dplyr::mutate(
#       peak2 = purrr::map_dbl(peaks, ~ if(length(.) >= 2) .[2] else NA_real_),
#       peak3 = purrr::map_dbl(peaks, ~ if(length(.) >= 3) .[3] else NA_real_),
#       NRL = peak3 - peak2,
#       AUC2 = purrr::map2_dbl(peak2, condition, ~{
#         if(is.na(.x)) return(NA_real_)
#         rows <- norm_frag %>% dplyr::filter(condition == .y,
#                                             .data[[length_col]] >= (.x - peak_window),
#                                             .data[[length_col]] <= (.x + peak_window))
#         sum(rows$smooth, na.rm = TRUE)
#       })
#     )
# 
#   # Compute deltas if control/treatment specified
#   delta_NRL <- delta_AUC2_pct <- NA_real_
#   if (!is.null(control_condition) && control_condition %in% summary_table$condition) {
#     treatment_condition <- setdiff(summary_table$condition, control_condition)
#     if (length(treatment_condition) == 1) {
#       delta_NRL <- summary_table$NRL[summary_table$condition == treatment_condition] -
#         summary_table$NRL[summary_table$condition == control_condition]
# 
#       AUC_ctrl <- summary_table$AUC2[summary_table$condition == control_condition]
#       AUC_trt <- summary_table$AUC2[summary_table$condition == treatment_condition]
#       delta_AUC2_pct <- (AUC_trt - AUC_ctrl) / AUC_ctrl * 100
#     }
#   }
# 
#   # Prepare arrow positions
#   max_smooth <- max(norm_frag$smooth, na.rm = TRUE)
#   n_conditions <- nrow(summary_table)
#   base_spacing <- max_smooth * 0.05
#   arrow_spacing <- base_spacing * arrow_spacing_factor
# 
#   summary_table <- summary_table %>%
#     dplyr::mutate(
#       arrow_y = max_smooth * 0.9 - (dplyr::row_number() - 1) * arrow_spacing,
#       text_y  = arrow_y - arrow_spacing / 3
#     )
# 
#   # Build plot
#   p <- ggplot(norm_frag, aes(x = .data[[length_col]], y = smooth, color = condition)) +
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
#   if (!is.null(colors)) p <- p + scale_color_manual(values = colors)
# 
#   # Apply custom theme if provided
#   if (!is.null(custom_theme)) p <- p + custom_theme else p <- p + theme_minimal()
# 
#   # Add delta annotations below legend
#   if (!is.na(delta_NRL) && !is.na(delta_AUC2_pct)) {
#     p <- p + annotate("text",
#                       x = max(norm_frag[[length_col]], na.rm = TRUE),
#                       y = max(norm_frag$smooth, na.rm = TRUE)*0.95,
#                       label = paste0("ΔNRL: ", round(delta_NRL,1), " bp\n",
#                                      "ΔAUC2: ", round(delta_AUC2_pct,1), "%"),
#                       hjust = 1, vjust = 1.2, size = 4, color = "black")
#   }
# 
#   return(list(summary = summary_table, plot = p))
# }
# 
# library(dplyr)
# library(ggplot2)
# library(purrr)
# library(zoo)
# library(grid)
# 
# 
# # Updated detect_local_peaks to use a moving window defined by the 'window' argument
# # if the new max in the window is 2% higher - 'min_height_frac' -than the previous
# # then it's recorded as a new max # otherwise it is considered noise and is not recorded
# 
# detect_local_peaks <- function(x_pos, y_val, window = 50, min_height_frac = 0.02) {
#   n <- length(y_val)
#   if (n == 0) return(numeric(0))
#   peaks_idx <- integer(0)
#   thr <- max(y_val, na.rm = TRUE) * min_height_frac
#   for (i in seq_len(n)) {
#     l <- max(1, i - window)
#     r <- min(n, i + window)
#     # local maximum
#     if (!is.na(y_val[i]) && y_val[i] >= thr && y_val[i] == max(y_val[l:r], na.rm = TRUE)) {
#       peaks_idx <- c(peaks_idx, i)
#     }
#   }
#   x_pos[peaks_idx]
# }
# 
# 
# analyze_fragment_NRL_plot <- function(fragment_df, sample_col = "sample", length_col = "length",
#                                       sample_conditions = NULL, control_condition = NULL,
#                                       smooth_k = 5, smooth_window = 100, peak_window = 20,
#                                       arrow_spacing_factor = 1.2, colors = NULL, custom_theme = NULL) {
# 
#   # Add condition column if not already present
#   if (!"condition" %in% colnames(fragment_df)) {
#     if (is.null(sample_conditions)) stop("You must provide sample_conditions if no 'condition' column exists")
#     fragment_df <- fragment_df %>%
#       dplyr::mutate(condition = sample_conditions[match(.data[[sample_col]], names(sample_conditions))])
#   }
# 
#   # Filter fragment lengths and summarize
#   norm_frag <- fragment_df %>%
#     dplyr::filter(.data[[length_col]] >= 50 & .data[[length_col]] <= 1000) %>%
#     dplyr::group_by(condition, .data[[length_col]]) %>%
#     dplyr::summarise(count = dplyr::n(), .groups = "drop_last") %>%
#     dplyr::mutate(norm_count = count / sum(count)) %>%
#     dplyr::group_by(condition) %>%
#     dplyr::mutate(smooth = zoo::rollmean(norm_count, k = smooth_k, fill = NA)) %>%
#     dplyr::ungroup()
# 
#   # Detect peaks per condition using existing detect_local_peaks()
#   peaks_list <- norm_frag %>%
#     dplyr::group_by(condition) %>%
#     dplyr::summarise(
#       peaks = list(detect_local_peaks(.data[[length_col]],  smooth, window = smooth_window)),
#       .groups = "drop"
#     )
# 
#   # Use 2nd and 3rd peaks, compute trapezoid AUC around 2nd peak
#   summary_table <- peaks_list %>%
#     dplyr::mutate(
#       peak2 = purrr::map_dbl(peaks, ~ if(length(.) >= 2) .[2] else NA_real_),
#       peak3 = purrr::map_dbl(peaks, ~ if(length(.) >= 3) .[3] else NA_real_),
#       NRL = peak3 - peak2,
#       AUC2 = purrr::map2_dbl(peak2, condition, ~{
#         if(is.na(.x)) return(NA_real_)
#         rows <- norm_frag %>% dplyr::filter(condition == .y,
#                                             .data[[length_col]] >= (.x - peak_window),
#                                             .data[[length_col]] <= (.x + peak_window))
#         x <- rows[[length_col]]
#         y <- rows$smooth
#         if(length(x) <= 1) return(NA_real_)
#         sum(diff(x) * (head(y,-1) + tail(y,-1))/2)  # trapezoid rule
#       })
#     )
# 
#   # Compute deltas
#   delta_NRL <- delta_AUC2_pct <- NA_real_
#   if (!is.null(control_condition) && control_condition %in% summary_table$condition) {
#     treatment_condition <- setdiff(summary_table$condition, control_condition)
#     if (length(treatment_condition) == 1) {
#       delta_NRL <- summary_table$NRL[summary_table$condition == treatment_condition] -
#         summary_table$NRL[summary_table$condition == control_condition]
# 
#       AUC_ctrl <- summary_table$AUC2[summary_table$condition == control_condition]
#       AUC_trt <- summary_table$AUC2[summary_table$condition == treatment_condition]
#       delta_AUC2_pct <- (AUC_trt - AUC_ctrl) / AUC_ctrl * 100
#     }
#   }
# 
#   # Prepare arrow positions
#   max_smooth <- max(norm_frag$smooth, na.rm = TRUE)
#   n_conditions <- nrow(summary_table)
#   base_spacing <- max_smooth * 0.05
#   arrow_spacing <- base_spacing * arrow_spacing_factor
# 
#   summary_table <- summary_table %>%
#     dplyr::mutate(
#       arrow_y = max_smooth * 0.9 - (dplyr::row_number() - 1) * arrow_spacing,
#       text_y  = arrow_y - arrow_spacing / 3
#     )
# 
#   # Build plot
#   p <- ggplot(norm_frag, aes(x = .data[[length_col]], y = smooth, color = condition)) +
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
#          title = "Fragment length distribution with NRL (2nd-3rd peak)") +
#     scale_y_log10()
# 
#   if (!is.null(colors)) p <- p + scale_color_manual(values = colors)
#   if (!is.null(custom_theme)) p <- p + custom_theme else p <- p + theme_minimal()
# 
#   # Add delta annotations with directional arrows
#   if (!is.na(delta_NRL) && !is.na(delta_AUC2_pct)) {
#     nrl_arrow <- if(delta_NRL > 0) "\u2192" else if(delta_NRL < 0) "\u2190" else ""
#     auc_arrow <- if(delta_AUC2_pct > 0) "\u2191" else if(delta_AUC2_pct < 0) "\u2193" else ""
# 
#     p <- p + annotate("text",
#                       x = max(norm_frag[[length_col]], na.rm = TRUE),
#                       y = max(norm_frag$smooth, na.rm = TRUE)*0.95,
#                       label = paste0("ΔNRL: ", round(delta_NRL,1), " bp ", nrl_arrow, "\n",
#                                      "ΔAUC2: ", round(delta_AUC2_pct,1), "% ", auc_arrow),
#                       hjust = 1, vjust = 1.2, size = 4, color = "black")
#   }
# 
#   return(list(summary = summary_table, plot = p))
# }
library(dplyr)
library(ggplot2)
library(purrr)
library(zoo)
library(grid)

# Local peak detection (unchanged)
detect_local_peaks <- function(x_pos, y_val, window = 50, min_height_frac = 0.02) {
  n <- length(y_val)
  if (n == 0) return(numeric(0))
  peaks_idx <- integer(0)
  thr <- max(y_val, na.rm = TRUE) * min_height_frac
  for (i in seq_len(n)) {
    l <- max(1, i - window)
    r <- min(n, i + window)
    if (!is.na(y_val[i]) && y_val[i] >= thr && y_val[i] == max(y_val[l:r], na.rm = TRUE)) {
      peaks_idx <- c(peaks_idx, i)
    }
  }
  x_pos[peaks_idx]
}

# Local minima by derivative sign-change, with local window filter
detect_local_minima <- function(x, y, window = 50) {
  dy <- diff(y)
  idx <- which(diff(sign(dy)) == 2) + 1
  if (length(idx) == 0) return(numeric(0))
  min_idx <- integer(0)
  for (i in idx) {
    l <- max(1, i - window)
    r <- min(length(y), i + window)
    if (y[i] == min(y[l:r], na.rm = TRUE)) min_idx <- c(min_idx, i)
  }
  x[min_idx]
}

# Small helper: safe positive baseline for log-scale fills
.safe_baseline <- function(v) {
  vpos <- suppressWarnings(v[v > 0])
  if (length(vpos) == 0) return(1e-12)             # ultra-small positive fallback
  b <- min(vpos, na.rm = TRUE)
  if (!is.finite(b) || b <= 0) return(1e-12)
  b * 0.99                                          # just below the local minimum to avoid gaps
}

# Main function (your name & structure preserved)
analyze_fragment_NRL_plot <- function(fragment_df,
                                      sample_col = "sample",
                                      length_col = "length",
                                      sample_conditions = NULL,
                                      control_condition = NULL,
                                      smooth_k = 5,
                                      smooth_window = 100,
                                      peak_window = 20,        # kept for compatibility (no longer used for AUC)
                                      window = 50,             # peak detection window
                                      minima_window = 50,      # minima detection window
                                      minima_search_bp = 150,  # +/- bp around peak2 to look for minima
                                      arrow_spacing_factor = 1.2,
                                      colors = NULL,
                                      custom_theme = NULL) {
  
  # Add condition if missing
  if (!"condition" %in% colnames(fragment_df)) {
    if (is.null(sample_conditions)) stop("Provide sample_conditions if 'condition' column is missing")
    fragment_df <- fragment_df %>%
      mutate(condition = sample_conditions[match(.data[[sample_col]], names(sample_conditions))])
  }
  
  # Normalize and smooth (unchanged)
  norm_frag <- fragment_df %>%
    dplyr::filter(.data[[length_col]] >= 50 & .data[[length_col]] <= 1000) %>%
    group_by(condition, .data[[length_col]]) %>%
    summarise(count = n(), .groups = "drop_last") %>%
    mutate(norm_count = count / sum(count)) %>%
    group_by(condition) %>%
    mutate(smooth = zoo::rollmean(norm_count, k = smooth_k, fill = NA)) %>%
    ungroup()
  
  # Detect peaks and minima (for AUC bounds)
  peaks_list <- norm_frag %>%
    group_by(condition) %>%
    summarise(
      peaks  = list(detect_local_peaks(.data[[length_col]], smooth, window = window)),
      minima = list(detect_local_minima(.data[[length_col]], smooth, window = minima_window)),
      .groups = "drop"
    )
  
  # ---- step 1: compute peaks and AUC (flanked by minima) ----
  summary_table <- peaks_list %>%
    mutate(
      peak2 = map_dbl(peaks, ~ if (length(.) >= 2) .[2] else NA_real_),
      peak3 = map_dbl(peaks, ~ if (length(.) >= 3) .[3] else NA_real_),
      NRL   = peak3 - peak2,
      AUC2  = map2_dbl(condition, peak2, ~ {
        if (is.na(.y)) return(NA_real_)
        rows <- norm_frag %>% dplyr::filter(condition == .x)
        x <- rows[[length_col]]
        y <- rows$smooth
        min_list <- detect_local_minima(x, y, window = minima_window)
        # minima within +/- minima_search_bp of peak2
        left_candidates  <- min_list[min_list < .y & min_list >= (.y - minima_search_bp)]
        right_candidates <- min_list[min_list > .y & min_list <= (.y + minima_search_bp)]
        if (length(left_candidates) == 0 || length(right_candidates) == 0) return(NA_real_)
        left  <- max(left_candidates)
        right <- min(right_candidates)
        idx <- which(x >= left & x <= right)
        if (length(idx) < 2) return(NA_real_)
        # integrate on linear scale (trapezoid rule)
        sum(diff(x[idx]) * (head(y[idx], -1) + tail(y[idx], -1)) / 2)
      })
    )
  
  # ---- step 2: compute xmin/xmax for highlighting (do this after summary_table exists) ----
  summary_table <- summary_table %>%
    mutate(
      xmin = map2_dbl(condition, peak2, ~ {
        if (is.na(.y)) return(NA_real_)
        rows <- norm_frag %>% dplyr::filter(condition == .x)
        x <- rows[[length_col]]
        y <- rows$smooth
        min_list <- detect_local_minima(x, y, window = minima_window)
        left_candidates <- min_list[min_list < .y & min_list >= (.y - minima_search_bp)]
        if (length(left_candidates) == 0) return(NA_real_)
        max(left_candidates)
      }),
      xmax = map2_dbl(condition, peak2, ~ {
        if (is.na(.y)) return(NA_real_)
        rows <- norm_frag %>% dplyr::filter(condition == .x)
        x <- rows[[length_col]]
        y <- rows$smooth
        min_list <- detect_local_minima(x, y, window = minima_window)
        right_candidates <- min_list[min_list > .y & min_list <= (.y + minima_search_bp)]
        if (length(right_candidates) == 0) return(NA_real_)
        min(right_candidates)
      })
    )
  
  # ΔNRL and ΔAUC (% higher/lower vs control)
  delta_NRL <- delta_AUC2_pct <- NA_real_
  if (!is.null(control_condition) && control_condition %in% summary_table$condition) {
    treatment_condition <- setdiff(summary_table$condition, control_condition)
    if (length(treatment_condition) == 1) {
      delta_NRL <- summary_table$NRL[summary_table$condition == treatment_condition] -
        summary_table$NRL[summary_table$condition == control_condition]
      AUC_ctrl <- summary_table$AUC2[summary_table$condition == control_condition]
      AUC_trt  <- summary_table$AUC2[summary_table$condition == treatment_condition]
      delta_AUC2_pct <- (AUC_trt / AUC_ctrl) * 100
    }
  }
  
  # Arrow positions (unchanged)
  max_smooth <- max(norm_frag$smooth, na.rm = TRUE)
  base_spacing <- max_smooth * 0.05
  arrow_spacing <- base_spacing * arrow_spacing_factor
  summary_table <- summary_table %>%
    mutate(
      arrow_y = max_smooth * 0.9 - (row_number() - 1) * arrow_spacing,
      text_y  = arrow_y - arrow_spacing / 3
    )
  
  # Base plot (unchanged)
  p <- ggplot(norm_frag, aes(x = .data[[length_col]], y = smooth, color = condition)) +
    geom_line(size = 0.8) +
    geom_vline(data = summary_table, aes(xintercept = peak2, color = condition),
               linetype = "dotted", size = 0.7) +
    geom_vline(data = summary_table, aes(xintercept = peak3, color = condition),
               linetype = "dashed", size = 0.7) +
    geom_segment(data = summary_table,
                 aes(x = peak2, xend = peak3, y = arrow_y, yend = arrow_y),
                 color = "black", arrow = arrow(length = unit(0.15, "cm"))) +
    geom_text(data = summary_table,
              aes(x = (peak2 + peak3)/2, y = text_y,
                  label = paste0("NRL: ", NRL, " bp")),
              vjust = 1, hjust = 0.5, color = "black") +
    labs(x = "Fragment length (bp)", y = "Normalized count",
         title = "Fragment length distribution with NRL (2nd–3rd peak) and minima-flanked AUC") +
    scale_y_log10()
  
  # --- FIXED highlight: fill under the curve on log-scale via positive baseline ---
  for (i in seq_len(nrow(summary_table))) {
    cond <- summary_table$condition[i]
    xmin <- summary_table$xmin[i]
    xmax <- summary_table$xmax[i]
    if (is.na(xmin) || is.na(xmax) || xmin >= xmax) next
    
    ribbon_df <- norm_frag %>%
      dplyr::filter(condition == cond,
             .data[[length_col]] >= xmin,
             .data[[length_col]] <= xmax) %>%
      arrange(.data[[length_col]])
    
    if (nrow(ribbon_df) < 2) next
    
    # constant positive baseline for this highlighted region
    y0 <- .safe_baseline(ribbon_df$smooth)
    ribbon_df$y0 <- y0
    
    p <- p + geom_ribbon(
      data = ribbon_df,
      aes(x = .data[[length_col]], ymin = y0, ymax = smooth),
      inherit.aes = FALSE,
      fill = if (!is.null(colors) && cond %in% names(colors)) colors[[cond]] else "grey50",
      alpha = 0.5
    )
  }
  
  if (!is.null(colors)) p <- p + scale_color_manual(values = colors)
  if (!is.null(custom_theme)) p <- p + custom_theme else p <- p + theme_minimal()
  
  # Annotation: ΔNRL (bp) and ΔAUC as % higher/lower
  if (!is.na(delta_NRL) && !is.na(delta_AUC2_pct)) {
    nrl_arrow <- if (delta_NRL > 0) "\u2192" else if (delta_NRL < 0) "\u2190" else ""
    delta_auc_change <- delta_AUC2_pct - 100
    auc_arrow <- if (delta_auc_change > 0) "\u2191" else if (delta_auc_change < 0) "\u2193" else ""
    auc_label <- paste0(abs(round(delta_auc_change, 1)), "% ",
                        ifelse(delta_auc_change > 0, "higher",
                               ifelse(delta_auc_change < 0, "lower", "no change")))
    
    p <- p + annotate("text",
                      x = max(norm_frag[[length_col]], na.rm = TRUE),
                      y = max(norm_frag$smooth, na.rm = TRUE) * 0.95,
                      label = paste0("ΔNRL: ", round(delta_NRL, 1), " bp ", nrl_arrow, "\n",
                                     "AUC: ", auc_label, " ", auc_arrow),
                      hjust = 1, vjust = 1.2, size = 4, color = "black")
  }
  
  return(list(summary = summary_table, plot = p))
}


# library(dplyr)
# library(ggplot2)
# library(purrr)
# library(zoo)
# library(grid)
# 
# # Local peak detection function
# detect_local_peaks <- function(x_pos, y_val, window = 50, min_height_frac = 0.02) {
#   n <- length(y_val)
#   if (n == 0) return(numeric(0))
#   peaks_idx <- integer(0)
#   thr <- max(y_val, na.rm = TRUE) * min_height_frac
#   for (i in seq_len(n)) {
#     l <- max(1, i - window)
#     r <- min(n, i + window)
#     if (!is.na(y_val[i]) && y_val[i] >= thr && y_val[i] == max(y_val[l:r], na.rm = TRUE)) {
#       peaks_idx <- c(peaks_idx, i)
#     }
#   }
#   x_pos[peaks_idx]
# }
# 
# # Main analysis function
# analyze_fragment_NRL_plot <- function(fragment_df,
#                                       sample_col = "sample",
#                                       length_col = "length",
#                                       sample_conditions = NULL,
#                                       control_condition = NULL,
#                                       smooth_k = 5,          # window for rollmean smoothing
#                                       smooth_window = 100,   # smoothing window used for rollmean in points
#                                       peak_window = 20,      # range around peak to compute AUC
#                                       window = 50,           # peak detection window for detect_local_peaks
#                                       arrow_spacing_factor = 1.2,
#                                       colors = NULL,
#                                       custom_theme = NULL) {
#   
#   # Add condition column if missing
#   if (!"condition" %in% colnames(fragment_df)) {
#     if (is.null(sample_conditions)) stop("Provide sample_conditions if 'condition' column is missing")
#     fragment_df <- fragment_df %>%
#       mutate(condition = sample_conditions[match(.data[[sample_col]], names(sample_conditions))])
#   }
#   
#   # Filter fragment lengths and compute normalized counts with smoothing
#   norm_frag <- fragment_df %>%
#     filter(.data[[length_col]] >= 50 & .data[[length_col]] <= 1000) %>%
#     group_by(condition, .data[[length_col]]) %>%
#     summarise(count = n(), .groups = "drop_last") %>%
#     mutate(norm_count = count / sum(count)) %>%
#     group_by(condition) %>%
#     mutate(smooth = zoo::rollmean(norm_count, k = smooth_k, fill = NA)) %>%
#     ungroup()
#   
#   # Detect peaks per condition using the user-defined 'window'
#   peaks_list <- norm_frag %>%
#     group_by(condition) %>%
#     summarise(
#       peaks = list(detect_local_peaks(.data[[length_col]], smooth, window = window)),
#       .groups = "drop"
#     )
#   
#   # Extract 2nd and 3rd peaks, compute NRL and trapezoid AUC
#   summary_table <- peaks_list %>%
#     mutate(
#       peak2 = map_dbl(peaks, ~ if(length(.) >= 2) .[2] else NA_real_),
#       peak3 = map_dbl(peaks, ~ if(length(.) >= 3) .[3] else NA_real_),
#       NRL = peak3 - peak2,
#       AUC2 = map2_dbl(peak2, condition, ~ {
#         if (is.na(.x)) return(NA_real_)
#         rows <- norm_frag %>%
#           filter(condition == .y,
#                  .data[[length_col]] >= (.x - peak_window),
#                  .data[[length_col]] <= (.x + peak_window))
#         x <- rows[[length_col]]
#         y <- rows$smooth
#         if (length(x) <= 1) return(NA_real_)
#         sum(diff(x) * (head(y, -1) + tail(y, -1))/2)  # trapezoid rule
#       })
#     )
#   
#   # Compute delta NRL and delta AUC between control and treatment
#   delta_NRL <- delta_AUC2_pct <- NA_real_
#   if (!is.null(control_condition) && control_condition %in% summary_table$condition) {
#     treatment_condition <- setdiff(summary_table$condition, control_condition)
#     if (length(treatment_condition) == 1) {
#       delta_NRL <- summary_table$NRL[summary_table$condition == treatment_condition] -
#         summary_table$NRL[summary_table$condition == control_condition]
#       
#       AUC_ctrl <- summary_table$AUC2[summary_table$condition == control_condition]
#       AUC_trt <- summary_table$AUC2[summary_table$condition == treatment_condition]
#       delta_AUC2_pct <- (AUC_trt - AUC_ctrl) / AUC_ctrl * 100
#     }
#   }
#   
#   # Prepare arrow positions
#   max_smooth <- max(norm_frag$smooth, na.rm = TRUE)
#   base_spacing <- max_smooth * 0.05
#   arrow_spacing <- base_spacing * arrow_spacing_factor
#   summary_table <- summary_table %>%
#     mutate(
#       arrow_y = max_smooth * 0.9 - (row_number() - 1) * arrow_spacing,
#       text_y  = arrow_y - arrow_spacing / 3
#     )
#   
#   # Build the plot
#   p <- ggplot(norm_frag, aes(x = .data[[length_col]], y = smooth, color = condition)) +
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
#          title = "Fragment length distribution with NRL (2nd-3rd peak)") +
#     scale_y_log10()
#   
#   if (!is.null(colors)) p <- p + scale_color_manual(values = colors)
#   if (!is.null(custom_theme)) p <- p + custom_theme else p <- p + theme_minimal()
#   
#   # Add delta annotations with arrows
#   if (!is.na(delta_NRL) && !is.na(delta_AUC2_pct)) {
#     nrl_arrow <- if(delta_NRL > 0) "\u2192" else if(delta_NRL < 0) "\u2190" else ""
#     auc_arrow <- if(delta_AUC2_pct > 0) "\u2191" else if(delta_AUC2_pct < 0) "\u2193" else ""
#     
#     p <- p + annotate("text",
#                       x = max(norm_frag[[length_col]], na.rm = TRUE),
#                       y = max(norm_frag$smooth, na.rm = TRUE) * 0.95,
#                       label = paste0("ΔNRL: ", round(delta_NRL, 1), " bp ", nrl_arrow, "\n",
#                                      "ΔAUC2: ", round(delta_AUC2_pct, 1), "% ", auc_arrow),
#                       hjust = 1, vjust = 1.2, size = 4, color = "black")
#   }
#   
#   return(list(summary = summary_table, plot = p))
# }
# 
# library(dplyr)
# library(ggplot2)
# library(purrr)
# library(zoo)
# library(grid)
# library(splines)
# 
# # Local peak detection function (unchanged)
# detect_local_peaks <- function(x_pos, y_val, window = 50, min_height_frac = 0.02) {
#   n <- length(y_val)
#   if (n == 0) return(numeric(0))
#   peaks_idx <- integer(0)
#   thr <- max(y_val, na.rm = TRUE) * min_height_frac
#   for (i in seq_len(n)) {
#     l <- max(1, i - window)
#     r <- min(n, i + window)
#     if (!is.na(y_val[i]) && y_val[i] >= thr && y_val[i] == max(y_val[l:r], na.rm = TRUE)) {
#       peaks_idx <- c(peaks_idx, i)
#     }
#   }
#   x_pos[peaks_idx]
# }
# 
# # Main function with spline-based adaptive peak integration
# analyze_fragment_NRL_plot_spline <- function(fragment_df,
#                                              sample_col = "sample",
#                                              length_col = "length",
#                                              sample_conditions = NULL,
#                                              control_condition = NULL,
#                                              smooth_k = 5,
#                                              smooth_window = 100,
#                                              window = 50,
#                                              arrow_spacing_factor = 1.2,
#                                              colors = NULL,
#                                              custom_theme = NULL) {
#   
#   # Add condition column if missing
#   if (!"condition" %in% colnames(fragment_df)) {
#     if (is.null(sample_conditions)) stop("Provide sample_conditions if 'condition' column is missing")
#     fragment_df <- fragment_df %>%
#       mutate(condition = sample_conditions[match(.data[[sample_col]], names(sample_conditions))])
#   }
#   
#   # Filter fragment lengths and smooth counts
#   norm_frag <- fragment_df %>%
#     filter(.data[[length_col]] >= 50 & .data[[length_col]] <= 1000) %>%
#     group_by(condition, .data[[length_col]]) %>%
#     summarise(count = n(), .groups = "drop_last") %>%
#     mutate(norm_count = count / sum(count)) %>%
#     group_by(condition) %>%
#     mutate(smooth = zoo::rollmean(norm_count, k = smooth_k, fill = NA)) %>%
#     ungroup()
#   
#   # Detect peaks
#   peaks_list <- norm_frag %>%
#     group_by(condition) %>%
#     summarise(
#       peaks = list(detect_local_peaks(.data[[length_col]], smooth, window = window)),
#       .groups = "drop"
#     )
#   
#   # Extract 2nd and 3rd peaks
#   summary_table <- peaks_list %>%
#     mutate(
#       peak2 = map_dbl(peaks, ~ if(length(.) >= 2) .[2] else NA_real_),
#       peak3 = map_dbl(peaks, ~ if(length(.) >= 3) .[3] else NA_real_),
#       NRL = peak3 - peak2
#     )
#   
#   # Spline-based adaptive AUC
#   summary_table <- summary_table %>%
#     rowwise() %>%
#     mutate(AUC2 = {
#       if (is.na(peak2)) NA_real_ else {
#         rows <- norm_frag %>% filter(condition == cur_data()$condition)
#         x <- rows[[length_col]]
#         y <- rows$smooth
#         # Fit a spline across full x-range
#         spline_fun <- splinefun(x, y)
#         # Find approximate left/right boundaries where spline drops to 5% of peak height
#         peak_val <- spline_fun(peak2)
#         left_idx <- which(x < peak2 & spline_fun(x) <= 0.05*peak_val)
#         right_idx <- which(x > peak2 & spline_fun(x) <= 0.05*peak_val)
#         x_left <- if(length(left_idx)>0) max(x[left_idx]) else min(x)
#         x_right <- if(length(right_idx)>0) min(x[right_idx]) else max(x)
#         # Integrate spline over adaptive range
#         integrate(spline_fun, lower = x_left, upper = x_right)$value
#       }
#     }) %>% ungroup()
#   
#   # Compute deltas
#   delta_NRL <- delta_AUC2_pct <- NA_real_
#   if (!is.null(control_condition) && control_condition %in% summary_table$condition) {
#     treatment_condition <- setdiff(summary_table$condition, control_condition)
#     if (length(treatment_condition) == 1) {
#       delta_NRL <- summary_table$NRL[summary_table$condition == treatment_condition] -
#         summary_table$NRL[summary_table$condition == control_condition]
#       
#       AUC_ctrl <- summary_table$AUC2[summary_table$condition == control_condition]
#       AUC_trt <- summary_table$AUC2[summary_table$condition == treatment_condition]
#       delta_AUC2_pct <- (AUC_trt - AUC_ctrl) / AUC_ctrl * 100
#     }
#   }
#   
#   # Prepare arrows
#   max_smooth <- max(norm_frag$smooth, na.rm = TRUE)
#   base_spacing <- max_smooth * 0.05
#   arrow_spacing <- base_spacing * arrow_spacing_factor
#   summary_table <- summary_table %>%
#     mutate(
#       arrow_y = max_smooth * 0.9 - (row_number() - 1) * arrow_spacing,
#       text_y  = arrow_y - arrow_spacing / 3
#     )
#   
#   # Build plot
#   p <- ggplot(norm_frag, aes(x = .data[[length_col]], y = smooth, color = condition)) +
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
#          title = "Fragment length distribution with NRL (2nd-3rd peak)") +
#     scale_y_log10()
#   
#   if (!is.null(colors)) p <- p + scale_color_manual(values = colors)
#   if (!is.null(custom_theme)) p <- p + custom_theme else p <- p + theme_minimal()
#   
#   # Add delta annotations with arrows
#   if (!is.na(delta_NRL) && !is.na(delta_AUC2_pct)) {
#     nrl_arrow <- if(delta_NRL > 0) "\u2192" else if(delta_NRL < 0) "\u2190" else ""
#     auc_arrow <- if(delta_AUC2_pct > 0) "\u2191" else if(delta_AUC2_pct < 0) "\u2193" else ""
#     p <- p + annotate("text",
#                       x = max(norm_frag[[length_col]], na.rm = TRUE),
#                       y = max(norm_frag$smooth, na.rm = TRUE) * 0.95,
#                       label = paste0("ΔNRL: ", round(delta_NRL,1), " bp ", nrl_arrow, "\n",
#                                      "ΔAUC2: ", round(delta_AUC2_pct,1), "% ", auc_arrow),
#                       hjust = 1, vjust = 1.2, size = 4, color = "black")
#   }
#   
#   return(list(summary = summary_table, plot = p))
# }
library(dplyr)
library(ggplot2)
library(purrr)
library(zoo)
library(grid)

# Detect local peaks
detect_local_peaks <- function(x_pos, y_val, window = 50, min_height_frac = 0.02) {
  n <- length(y_val)
  if (n == 0) return(numeric(0))
  peaks_idx <- integer(0)
  thr <- max(y_val, na.rm = TRUE) * min_height_frac
  for (i in seq_len(n)) {
    l <- max(1, i - window)
    r <- min(n, i + window)
    if (!is.na(y_val[i]) && y_val[i] >= thr && y_val[i] == max(y_val[l:r], na.rm = TRUE)) {
      peaks_idx <- c(peaks_idx, i)
    }
  }
  x_pos[peaks_idx]
}

# Main function with Gaussian smoothing
analyze_fragment_NRL_plot_gaussian <- function(fragment_df, sample_col = "sample", length_col = "length",
                                               sample_conditions = NULL, control_condition = NULL,
                                               smooth_sigma = 5, peak_window = 20, window = 50,
                                               arrow_spacing_factor = 1.2, colors = NULL, custom_theme = NULL) {
  
  # Add condition column if not present
  if (!"condition" %in% colnames(fragment_df)) {
    if (is.null(sample_conditions)) stop("You must provide sample_conditions if no 'condition' column exists")
    fragment_df <- fragment_df %>%
      mutate(condition = sample_conditions[match(.data[[sample_col]], names(sample_conditions))])
  }
  
  # Filter fragment lengths and normalize counts
  norm_frag <- fragment_df %>%
    filter(.data[[length_col]] >= 50 & .data[[length_col]] <= 1000) %>%
    group_by(condition, .data[[length_col]]) %>%
    summarise(count = n(), .groups = "drop_last") %>%
    mutate(norm_count = count / sum(count)) %>%
    group_by(condition) %>%
    mutate(smooth = stats::filter(norm_count, dnorm(-3*smooth_sigma:3*smooth_sigma, mean=0, sd=smooth_sigma), sides=2)) %>%
    ungroup()
  
  # Detect peaks per condition
  peaks_list <- norm_frag %>%
    group_by(condition) %>%
    summarise(peaks = list(detect_local_peaks(.data[[length_col]], smooth, window = window)), .groups = "drop")
  
  # Compute 2nd & 3rd peaks, NRL, AUC2 (trapezoid)
  summary_table <- peaks_list %>%
    mutate(
      peak2 = map_dbl(peaks, ~ if(length(.) >= 2) .[2] else NA_real_),
      peak3 = map_dbl(peaks, ~ if(length(.) >= 3) .[3] else NA_real_),
      NRL = peak3 - peak2,
      AUC2 = map2_dbl(peak2, condition, ~{
        if(is.na(.x)) return(NA_real_)
        rows <- norm_frag %>% filter(condition == .y,
                                     .data[[length_col]] >= (.x - peak_window),
                                     .data[[length_col]] <= (.x + peak_window))
        x <- rows[[length_col]]
        y <- rows$smooth
        if(length(x) <= 1) return(NA_real_)
        sum(diff(x) * (head(y,-1) + tail(y,-1))/2)
      })
    )
  
  # Compute deltas relative to control
  delta_NRL <- delta_AUC2_pct <- NA_real_
  if (!is.null(control_condition) && control_condition %in% summary_table$condition) {
    treatment_condition <- setdiff(summary_table$condition, control_condition)
    if (length(treatment_condition) == 1) {
      delta_NRL <- summary_table$NRL[summary_table$condition == treatment_condition] -
        summary_table$NRL[summary_table$condition == control_condition]
      AUC_ctrl <- summary_table$AUC2[summary_table$condition == control_condition]
      AUC_trt <- summary_table$AUC2[summary_table$condition == treatment_condition]
      delta_AUC2_pct <- (AUC_trt - AUC_ctrl) / AUC_ctrl * 100
    }
  }
  
  # Arrow positions
  max_smooth <- max(norm_frag$smooth, na.rm = TRUE)
  base_spacing <- max_smooth * 0.05
  arrow_spacing <- base_spacing * arrow_spacing_factor
  summary_table <- summary_table %>%
    mutate(
      arrow_y = max_smooth * 0.9 - (row_number() - 1) * arrow_spacing,
      text_y  = arrow_y - arrow_spacing / 3
    )
  
  # Build plot
  p <- ggplot(norm_frag, aes(x = .data[[length_col]], y = smooth, color = condition)) +
    geom_line(size = 0.8) +
    geom_vline(data = summary_table, aes(xintercept = peak2, color = condition), linetype = "dotted", size = 0.7) +
    geom_vline(data = summary_table, aes(xintercept = peak3, color = condition), linetype = "dashed", size = 0.7) +
    geom_segment(data = summary_table,
                 aes(x = peak2, xend = peak3, y = arrow_y, yend = arrow_y),
                 color = "black", arrow = arrow(length = unit(0.15, "cm"))) +
    geom_text(data = summary_table,
              aes(x = (peak2 + peak3)/2, y = text_y, label = paste0("NRL: ", NRL, " bp")),
              vjust = 1, hjust = 0.5, color = "black") +
    labs(x = "Fragment length (bp)", y = "Normalized count",
         title = "Fragment length distribution with NRL (2nd-3rd peak)") +
    scale_y_log10()
  
  if (!is.null(colors)) p <- p + scale_color_manual(values = colors)
  if (!is.null(custom_theme)) p <- p + custom_theme else p <- p + theme_minimal()
  
  # Delta annotations
  if (!is.na(delta_NRL) && !is.na(delta_AUC2_pct)) {
    nrl_arrow <- if(delta_NRL > 0) "\u2192" else if(delta_NRL < 0) "\u2190" else ""
    auc_arrow <- if(delta_AUC2_pct > 0) "\u2191" else if(delta_AUC2_pct < 0) "\u2193" else ""
    
    p <- p + annotate("text",
                      x = max(norm_frag[[length_col]], na.rm = TRUE),
                      y = max(norm_frag$smooth, na.rm = TRUE)*0.95,
                      label = paste0("ΔNRL: ", round(delta_NRL,1), " bp ", nrl_arrow, "\n",
                                     "ΔAUC2: ", round(delta_AUC2_pct,1), "% ", auc_arrow),
                      hjust = 1, vjust = 1.2, size = 4, color = "black")
  }
  
  return(list(summary = summary_table, plot = p))
}



library(dplyr)
library(ggplot2)
library(purrr)
library(zoo)
library(grid)

# Detect local maxima
detect_local_peaks <- function(x_pos, y_val, window = 50, min_height_frac = 0.02) {
  n <- length(y_val)
  if (n == 0) return(numeric(0))
  peaks_idx <- integer(0)
  thr <- max(y_val, na.rm = TRUE) * min_height_frac
  for (i in seq_len(n)) {
    l <- max(1, i - window)
    r <- min(n, i + window)
    if (!is.na(y_val[i]) && y_val[i] >= thr && y_val[i] == max(y_val[l:r], na.rm = TRUE)) {
      peaks_idx <- c(peaks_idx, i)
    }
  }
  x_pos[peaks_idx]
}

# Derivative-based local minima detection (robust)
detect_local_minima <- function(x, y, window = 50) {
  dy <- diff(y)
  idx <- which(diff(sign(dy)) == 2) + 1
  if (length(idx) == 0) return(numeric(0))
  min_idx <- integer(0)
  for (i in idx) {
    l <- max(1, i - window)
    r <- min(length(y), i + window)
    if (y[i] == min(y[l:r], na.rm = TRUE)) min_idx <- c(min_idx, i)
  }
  x[min_idx]
}

# Helper: positive baseline for log-scale ribbons
.safe_baseline <- function(v) {
  vpos <- suppressWarnings(v[v > 0])
  if (length(vpos) == 0) return(1e-12)
  b <- min(vpos, na.rm = TRUE)
  if (!is.finite(b) || b <= 0) return(1e-12)
  b * 0.99
}

# Main analysis function
analyze_fragment_NRL_plot_minimaAUC <- function(fragment_df,
                                                sample_col = "sample",
                                                length_col = "length",
                                                sample_conditions = NULL,
                                                control_condition = NULL,
                                                smooth_k = 5,
                                                peak_window = 50,
                                                minima_window = 50,
                                                minima_search_bp = 150,
                                                arrow_spacing_factor = 1.2,
                                                colors = NULL,
                                                custom_theme = NULL) {
  
  # Add condition column if missing
  if (!"condition" %in% colnames(fragment_df)) {
    if (is.null(sample_conditions)) stop("Provide sample_conditions if 'condition' column is missing")
    fragment_df <- fragment_df %>%
      mutate(condition = sample_conditions[match(.data[[sample_col]], names(sample_conditions))])
  }
  
  # Normalize and smooth
  norm_frag <- fragment_df %>%
    dplyr::filter(.data[[length_col]] >= 50 & .data[[length_col]] <= 1000) %>%
    group_by(condition, .data[[length_col]]) %>%
    summarise(count = n(), .groups = "drop_last") %>%
    mutate(norm_count = count / sum(count)) %>%
    group_by(condition) %>%
    mutate(smooth = zoo::rollmean(norm_count, k = smooth_k, fill = NA)) %>%
    ungroup() %>%
    dplyr::filter(!is.na(smooth) & smooth > 0)
  
  # Detect peaks and minima
  peaks_list <- norm_frag %>%
    group_by(condition) %>%
    summarise(
      peaks = list(detect_local_peaks(.data[[length_col]], smooth, window = peak_window)),
      minima = list(detect_local_minima(.data[[length_col]], smooth, window = minima_window)),
      .groups = "drop"
    )
  
  # Compute NRL and AUC
  summary_table <- peaks_list %>%
    mutate(
      peak2 = map_dbl(peaks, ~ if(length(.) >= 2) .[2] else NA_real_),
      peak3 = map_dbl(peaks, ~ if(length(.) >= 3) .[3] else NA_real_),
      NRL = peak3 - peak2,
      AUC2 = map2_dbl(condition, peak2, ~ {
        if (is.na(.y)) return(NA_real_)
        rows <- norm_frag %>% dplyr::filter(condition == .x)
        x <- rows[[length_col]]
        y <- rows$smooth
        min_list <- detect_local_minima(x, y, window = minima_window)
        left_candidates <- min_list[min_list < .y & min_list >= (.y - minima_search_bp)]
        right_candidates <- min_list[min_list > .y & min_list <= (.y + minima_search_bp)]
        if (length(left_candidates) == 0 || length(right_candidates) == 0) return(NA_real_)
        left <- max(left_candidates)
        right <- min(right_candidates)
        idx <- which(x >= left & x <= right)
        sum(diff(x[idx]) * (head(y[idx], -1) + tail(y[idx], -1)) / 2)
      }),
      xmin = map2_dbl(condition, peak2, ~ {
        if (is.na(.y)) return(NA_real_)
        rows <- norm_frag %>% dplyr::filter(condition == .x)
        x <- rows[[length_col]]
        min_list <- detect_local_minima(x, rows$smooth, window = minima_window)
        left_candidates <- min_list[min_list < .y & min_list >= (.y - minima_search_bp)]
        if (length(left_candidates) == 0) return(NA_real_)
        max(left_candidates)
      }),
      xmax = map2_dbl(condition, peak2, ~ {
        if (is.na(.y)) return(NA_real_)
        rows <- norm_frag %>% dplyr::filter(condition == .x)
        x <- rows[[length_col]]
        min_list <- detect_local_minima(x, rows$smooth, window = minima_window)
        right_candidates <- min_list[min_list > .y & min_list <= (.y + minima_search_bp)]
        if (length(right_candidates) == 0) return(NA_real_)
        min(right_candidates)
      })
    )
  
  # Compute deltas (NRL and AUC as % of control)
  delta_NRL <- delta_AUC_pct <- NA_real_
  if (!is.null(control_condition) && control_condition %in% summary_table$condition) {
    treatment_condition <- setdiff(summary_table$condition, control_condition)
    if (length(treatment_condition) == 1) {
      NRL_ctrl <- summary_table$NRL[summary_table$condition == control_condition]
      NRL_trt  <- summary_table$NRL[summary_table$condition == treatment_condition]
      AUC_ctrl <- summary_table$AUC2[summary_table$condition == control_condition]
      AUC_trt  <- summary_table$AUC2[summary_table$condition == treatment_condition]
      delta_NRL <- NRL_trt - NRL_ctrl
      delta_AUC_pct <- (AUC_trt / AUC_ctrl) * 100
    }
  }
  
  # Base plot
  p <- ggplot(norm_frag, aes(x = .data[[length_col]], y = smooth, color = condition)) +
    geom_line(size = 0.8)
  
  # --- FIXED HIGHLIGHT (fill under the curve with local baseline) ---
  for (i in seq_len(nrow(summary_table))) {
    cond <- summary_table$condition[i]
    xmin <- summary_table$xmin[i]
    xmax <- summary_table$xmax[i]
    if (is.na(xmin) || is.na(xmax) || xmin >= xmax) next
    ribbon_df <- norm_frag %>%
      dplyr::filter(condition == cond,
             .data[[length_col]] >= xmin,
             .data[[length_col]] <= xmax) %>%
      arrange(.data[[length_col]])
    if (nrow(ribbon_df) < 2) next
    y0 <- .safe_baseline(ribbon_df$smooth)
    ribbon_df$y0 <- y0
    p <- p + geom_ribbon(
      data = ribbon_df,
      aes(x = .data[[length_col]], ymin = y0, ymax = smooth),
      inherit.aes = FALSE,
      fill = if (!is.null(colors) && cond %in% names(colors)) colors[[cond]] else "grey50",
      alpha = 0.5
    )
  }
  
  # Add peaks and labels
  p <- p +
    geom_vline(data = summary_table, aes(xintercept = peak2, color = condition),
               linetype = "dotted", size = 0.7) +
    geom_vline(data = summary_table, aes(xintercept = peak3, color = condition),
               linetype = "dashed", size = 0.7) +
    labs(x = "Fragment length (bp)", y = "Normalized count",
         title = paste0("Fragment length distribution (AUC ±", minima_search_bp, " bp)")) +
    scale_y_log10()
  
  if (!is.null(colors))
    p <- p + scale_color_manual(values = colors) + scale_fill_manual(values = colors)
  if (!is.null(custom_theme)) p <- p + custom_theme else p <- p + theme_minimal()
  
  # Add ΔNRL and AUC% annotation
  if (!is.na(delta_NRL) && !is.na(delta_AUC_pct)) {
    nrl_arrow <- if (delta_NRL > 0) "\u2192" else if (delta_NRL < 0) "\u2190" else ""
    auc_arrow <- if (delta_AUC_pct > 100) "\u2191" else if (delta_AUC_pct < 100) "\u2193" else ""
    p <- p + annotate("text",
                      x = max(norm_frag[[length_col]], na.rm = TRUE),
                      y = max(norm_frag$smooth, na.rm = TRUE) * 0.95,
                      label = paste0("ΔNRL: ", round(delta_NRL, 1), " bp ", nrl_arrow, "\n",
                                     "AUC: ", round(delta_AUC_pct - 100, 1), "% ",
                                     ifelse(delta_AUC_pct > 100, "higher", "lower"), " ", auc_arrow),
                      hjust = 1, vjust = 1.2, size = 4, color = "black")
  }
  
  return(list(summary = summary_table, plot = p))
}
