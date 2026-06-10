#' @title Compute Nucleosome Repeat Length (NRL) and AUC from Fragment Length Distributions
#'
#' @description
#' Calculates Nucleosome Repeat Length (NRL) and Area Under the Curve (AUC)
#' from fragment length distributions, optionally comparing control and treatment
#' conditions with ΔNRL and ΔAUC annotations. Supports both *peak→minimum* and
#' *fixed-window* AUC calculation modes.
#'
#' @param fragments_df Data frame containing fragment data. Must include fragment
#'   length and sample ID columns.
#' @param sample_id_column Character string specifying the column name of sample IDs.
#' @param fragment_length_column Character string specifying the column name with fragment lengths (in bp).
#' @param sample_condition_map Named character vector mapping sample IDs to conditions.
#' @param control_condition_name Character string specifying the name of the control condition.
#' @param smoothing_window_size Integer. Rolling mean window size for smoothing fragment distribution.
#' @param peak_merge_window_bp Integer. Minimum distance between peaks to be considered distinct (default: 100).
#' @param minima_merge_window_bp Integer. Minimum distance between minima to be considered distinct.
#' @param arrow_spacing_scale Numeric multiplier controlling vertical spacing between NRL arrows.
#' @param condition_colors Named character vector of colors for each condition.
#' @param ggplot_theme Optional ggplot2 theme object for plot customization.
#' @param plot_title_text Character string specifying the plot title.
#' @param legend_title_text Character string specifying the legend title.
#' @param auc_method Character; either `"fixed_window"` (default) or `"peak_to_minimum"`.
#'   Defines how AUC is calculated.
#' @param auc_window_bp Integer. If `auc_method = "fixed_window"`, defines the ±bp range around peak for AUC integration (default: 100).
#' @param auc_anchor_sample Character; `"control"` (default) or `"each"`, defining
#'   whether the AUC anchor is defined relative to the control sample or each condition independently.
#' @param show_delta_annotation Logical; whether to display ΔNRL and ΔAUC annotation in the top-right corner.
#'
#' @return A list with two elements:
#' \describe{
#'   \item{summary}{A tibble with detected peaks, NRLs, AUC values, and ΔNRL/ΔAUC if control is specified.}
#'   \item{plot}{A ggplot2 object showing smoothed fragment length distribution, NRL arrows, and AUC shading.}
#' }
#'
#' @export
#'
nrl <- function(
    fragments_df,
    sample_id_column = "sample",
    fragment_length_column = "length",
    sample_condition_map = NULL,
    control_condition_name = NULL,
    smoothing_window_size = 5,
    peak_merge_window_bp = 100,
    minima_merge_window_bp = 50,
    arrow_spacing_scale = 1.2,
    condition_colors = NULL,
    ggplot_theme = NULL,
    plot_title_text = "Fragment length distribution with NRL and AUC",
    legend_title_text = "Condition",
    auc_method = c("fixed_window", "peak_to_minimum"),
    auc_window_bp = 100,
    auc_anchor_sample = c("control", "each"),
    show_delta_annotation = TRUE
) {
  auc_method <- match.arg(auc_method)
  auc_anchor_sample <- match.arg(auc_anchor_sample)
  
  # --- internal helper: ensure positive baseline ---
  .safe_baseline <- function(y) {
    ymin <- suppressWarnings(min(y, na.rm = TRUE))
    if (!is.finite(ymin) || ymin <= 0) ymin <- 1e-8
    ymin
  }
  
  # --- internal helper: local minima detection ---
  .detect_local_minima <- function(x, y, window = 50L) {
    ok <- is.finite(x) & is.finite(y)
    x <- x[ok]; y <- y[ok]
    if (length(x) < 3) return(numeric(0))
    o <- order(x); x <- x[o]; y <- y[o]
    dy <- diff(y); sgn <- sign(dy); turn <- diff(sgn)
    cand_idx <- which(turn >= 2) + 1L
    if (!length(cand_idx)) return(numeric(0))
    cand <- data.frame(i = cand_idx, x = x[cand_idx], y = y[cand_idx])
    cand <- cand[order(cand$y, decreasing = FALSE), , drop = FALSE]
    selected <- logical(nrow(cand)); taken <- logical(nrow(cand))
    for (k in seq_len(nrow(cand))) {
      if (taken[k]) next
      selected[k] <- TRUE
      close <- abs(cand$x - cand$x[k]) <= window
      taken <- taken | close
    }
    cand[selected, , drop = FALSE]$x
  }
  
  # --- internal helper: local peaks detection ---
  .detect_local_peaks <- function(x, y, window = 50L) {
    ok <- is.finite(x) & is.finite(y)
    x <- x[ok]; y <- y[ok]
    if (length(x) < 3) return(numeric(0))
    o <- order(x); x <- x[o]; y <- y[o]
    dy <- diff(y); sgn <- sign(dy); turn <- diff(sgn)
    cand_idx <- which(turn <= -2) + 1L
    if (!length(cand_idx)) return(numeric(0))
    cand <- data.frame(i = cand_idx, x = x[cand_idx], y = y[cand_idx])
    cand <- cand[order(cand$y, decreasing = TRUE), , drop = FALSE]
    selected <- logical(nrow(cand)); taken <- logical(nrow(cand))
    for (k in seq_len(nrow(cand))) {
      if (taken[k]) next
      selected[k] <- TRUE
      close <- abs(cand$x - cand$x[k]) <= window
      taken <- taken | close
    }
    cand[selected, , drop = FALSE]$x
  }
  
  # --- AUC calculation methods ---
  .auc_peak_to_minimum <- function(x, y, left_peak, minima_x) {
    right_mins <- minima_x[minima_x > left_peak]
    pick_right <- if (length(right_mins)) min(right_mins) else max(x)
    rng <- x >= left_peak & x <= pick_right
    if (sum(rng) < 3L) return(NA_real_)
    xi <- x[rng]; yi <- y[rng]
    sum(diff(xi) * (head(yi, -1) + tail(yi, -1)) / 2)
  }
  
  .auc_fixed_window <- function(x, y, peak, width_bp) {
    left <- max(min(x), peak - width_bp)
    right <- min(max(x), peak + width_bp)
    rng <- x >= left & x <= right
    if (sum(rng) < 3L) return(NA_real_)
    xi <- x[rng]; yi <- y[rng]
    sum(diff(xi) * (head(yi, -1) + tail(yi, -1)) / 2)
  }
  
  # --- Prepare data and map conditions ---
  if (!"condition" %in% colnames(fragments_df)) {
    if (is.null(sample_condition_map))
      stop("Provide sample_condition_map if 'condition' column is missing.")
    fragments_df <- fragments_df %>%
      mutate(condition = sample_condition_map[match(.data[[sample_id_column]], names(sample_condition_map))])
  }
  
  norm_frag <- fragments_df %>%
    dplyr::filter(.data[[fragment_length_column]] >= 50 & .data[[fragment_length_column]] <= 1000) %>%
    group_by(condition, .data[[fragment_length_column]]) %>%
    summarise(count = n(), .groups = "drop_last") %>%
    mutate(norm_count = count / sum(count)) %>%
    group_by(condition) %>%
    mutate(smooth = zoo::rollmean(norm_count, k = smoothing_window_size, fill = NA)) %>%
    ungroup()
  
  peaks_list <- norm_frag %>%
    group_by(condition) %>%
    arrange(.data[[fragment_length_column]], .by_group = TRUE) %>%
    group_modify(~ {
      df <- .x
      tibble(
        peaks  = list(.detect_local_peaks(df[[fragment_length_column]], df$smooth, window = peak_merge_window_bp)),
        minima = list(.detect_local_minima(df[[fragment_length_column]], df$smooth, window = minima_merge_window_bp))
      )
    }) %>%
    ungroup()
  
  summary_table <- peaks_list %>%
    mutate(
      peak1 = map_dbl(peaks, ~ if (length(.) >= 1) .[1] else NA_real_),
      peak2 = map_dbl(peaks, ~ if (length(.) >= 2) .[2] else NA_real_),
      peak3 = map_dbl(peaks, ~ if (length(.) >= 3) .[3] else NA_real_),
      use_23 = !is.na(peak2) & !is.na(peak3) & (peak3 - peak2) >= 100,
      use_12 = !use_23 & !is.na(peak1) & !is.na(peak2),
      left_peak  = dplyr::case_when(use_23 ~ peak2, use_12 ~ peak1, TRUE ~ NA_real_),
      right_peak = dplyr::case_when(use_23 ~ peak3, use_12 ~ peak2, TRUE ~ NA_real_),
      method = dplyr::case_when(use_23 ~ "2-3", use_12 ~ "1-2", TRUE ~ NA_character_)
    )
  
  summary_table <- summary_table %>%
    mutate(
      AUC_value = map2_dbl(condition, left_peak, ~ {
        rows <- norm_frag %>% dplyr::filter(condition == .x)
        x <- rows[[fragment_length_column]]; y <- rows$smooth
        if (auc_method == "peak_to_minimum") {
          mins <- .detect_local_minima(x, y, window = minima_merge_window_bp)
          .auc_peak_to_minimum(x, y, .y, mins)
        } else {
          .auc_fixed_window(x, y, .y, auc_window_bp)
        }
      }),
      NRL = right_peak - left_peak
    )
  
  # --- Compute deltas using mean of replicates ---
  delta_NRL <- delta_AUC_pct <- NA_real_
  if (length(unique(fragments_df$condition)) > 1 && !is.null(control_condition_name)) {
    ctrl <- summary_table %>% filter(condition == control_condition_name)
    trt  <- summary_table %>% filter(condition != control_condition_name)
    if (nrow(ctrl) >= 1 && nrow(trt) >= 1) {
      delta_NRL <- mean(trt$NRL, na.rm = TRUE) - mean(ctrl$NRL, na.rm = TRUE)
      delta_AUC_pct <- (mean(trt$AUC_value, na.rm = TRUE) / mean(ctrl$AUC_value, na.rm = TRUE)) * 100 - 100
    }
  }
  
  # --- Plot assembly ---
  max_smooth <- max(norm_frag$smooth, na.rm = TRUE)
  base_spacing <- max_smooth * 0.05
  arrow_spacing <- base_spacing * arrow_spacing_scale
  summary_table <- summary_table %>%
    mutate(arrow_y = max_smooth * 0.9 - (row_number() - 1) * arrow_spacing,
           text_y = arrow_y - arrow_spacing / 3)
  
  p <- ggplot(norm_frag, aes(x = .data[[fragment_length_column]], y = smooth, color = condition)) +
    geom_line(size = 0.8) +
    geom_vline(data = summary_table, aes(xintercept = left_peak, color = condition), linetype = "dotted") +
    geom_vline(data = summary_table, aes(xintercept = right_peak, color = condition), linetype = "dashed") +
    geom_segment(data = summary_table,
                 aes(x = left_peak, xend = right_peak, y = arrow_y, yend = arrow_y),
                 color = "black", arrow = arrow(length = unit(0.15, "cm"))) +
    geom_text(data = summary_table,
              aes(x = (left_peak + right_peak)/2, y = text_y,
                  label = paste0("NRL (", method, "): ", round(NRL, 1), " bp")),
              vjust = 1, hjust = 0.5, color = "black") +
    labs(x = "Fragment length (bp)", y = "Normalized count",
         color = legend_title_text, title = plot_title_text) +
    scale_y_log10()
  
  # --- Add AUC ribbons ---
  for (i in seq_len(nrow(summary_table))) {
    cond <- summary_table$condition[i]
    center <- summary_table$left_peak[i]
    if (is.na(center)) next
    if (auc_method == "peak_to_minimum") {
      rows <- norm_frag %>% filter(condition == cond)
      mins <- .detect_local_minima(rows[[fragment_length_column]], rows$smooth, window = minima_merge_window_bp)
      right_min <- mins[mins > center]
      right <- if (length(right_min)) min(right_min) else max(rows[[fragment_length_column]])
      left <- center
    } else {
      right <- center + auc_window_bp; left <- center - auc_window_bp
    }
    ribbon_df <- norm_frag %>% filter(condition == cond,
                                      .data[[fragment_length_column]] >= left, .data[[fragment_length_column]] <= right)
    if (nrow(ribbon_df) > 2) {
      y0 <- .safe_baseline(ribbon_df$smooth)
      ribbon_df$y0 <- y0
      p <- p + geom_ribbon(data = ribbon_df,
                           aes(x = .data[[fragment_length_column]], ymin = y0, ymax = smooth),
                           inherit.aes = FALSE,
                           fill = if (!is.null(condition_colors) && cond %in% names(condition_colors))
                             condition_colors[[cond]] else "grey50",
                           alpha = 0.5)
    }
  }
  
  if (!is.null(condition_colors)) p <- p + scale_color_manual(values = condition_colors)
  if (!is.null(ggplot_theme)) p <- p + ggplot_theme else p <- p + theme_minimal()
  
  # --- Add delta annotation (two-line version, directional) ---
  if (show_delta_annotation && !is.na(delta_NRL) && !is.na(delta_AUC_pct)) {
    nrl_arrow <- if (delta_NRL > 0) "↑" else if (delta_NRL < 0) "↓" else ""
    nrl_label <- if (delta_NRL == 0) "NRL: no change" else
      paste0("ΔNRL: ", abs(round(delta_NRL, 1)), " bp ",
             ifelse(delta_NRL > 0, "(longer)", "(shorter)"), " ", nrl_arrow)
    
    auc_arrow <- if (delta_AUC_pct > 0) "↑" else if (delta_AUC_pct < 0) "↓" else ""
    auc_label <- if (delta_AUC_pct == 0) "AUC: no change" else
      paste0("ΔAUC: ", abs(round(delta_AUC_pct, 1)), "% ",
             ifelse(delta_AUC_pct > 0, "(higher)", "(lower)"), " ", auc_arrow)
    
    label_text <- paste(nrl_label, auc_label, sep = "\n")
    
    p <- p + annotate("text",
                      x = max(norm_frag[[fragment_length_column]], na.rm = TRUE),
                      y = max(norm_frag$smooth, na.rm = TRUE) * 0.95,
                      label = label_text, hjust = 1, vjust = 1,
                      size = 11/ggplot2::.pt, fontface = "bold",
                      color = "black")
  }
  
  list(summary = summary_table, plot = p)
}