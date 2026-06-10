fragment_length_analysis <- function(fragment_df,
                                     sample_col = "sample",
                                     length_col = "length",
                                     sample_conditions = NULL,
                                     control_condition = NULL,
                                     smooth_k = 5,
                                     window = 50,
                                     minima_window = 50,
                                     arrow_spacing_factor = 1.2,
                                     colors = NULL,
                                     custom_theme = NULL) {
  # --- internal helper: ensure positive baseline for log-scale ribbons ---
  .safe_baseline <- function(y) {
    if (all(is.na(y))) return(1e-8)
    ymin <- suppressWarnings(min(y, na.rm = TRUE))
    if (!is.finite(ymin) || ymin <= 0) ymin <- 1e-8
    ymin
  }

  # --- internal helper: local minima detection with NMS ---
  .detect_local_minima <- function(x, y, window = 50L) {
    ok <- is.finite(x) & is.finite(y)
    x <- x[ok]; y <- y[ok]
    if (length(x) < 3) return(numeric(0))
    o <- order(x)
    x <- x[o]; y <- y[o]
    dy <- diff(y)
    sgn <- sign(dy)
    turn <- diff(sgn)
    cand_idx <- which(turn >= 2) + 1L
    if (!length(cand_idx)) return(numeric(0))
    cand <- data.frame(i = cand_idx, x = x[cand_idx], y = y[cand_idx])
    cand <- cand[order(cand$y, decreasing = FALSE), , drop = FALSE]
    selected <- logical(nrow(cand))
    taken <- logical(nrow(cand))
    for (k in seq_len(nrow(cand))) {
      if (taken[k]) next
      selected[k] <- TRUE
      close <- abs(cand$x - cand$x[k]) <= window
      taken <- taken | close
    }
    sel <- cand[selected, , drop = FALSE]
    sel <- sel[order(sel$x), , drop = FALSE]
    sel$x
  }

  # --- internal helper: local peaks with NMS ---
  .detect_local_peaks_nms <- function(x, y, window = 50L, min_prom = 0, tie_is_peak = TRUE) {
    ok <- is.finite(x) & is.finite(y)
    x <- x[ok]; y <- y[ok]
    if (length(x) < 3) return(numeric(0))
    o <- order(x)
    x <- x[o]; y <- y[o]
    if (min_prom > 0) y <- pmax(y - min(y, na.rm = TRUE), 0)
    dy <- diff(y)
    sgn <- sign(dy)
    turn <- if (tie_is_peak) (diff(sgn) <= -1) else (diff(sgn) < 0)
    cand_idx <- which(turn) + 1L
    if (!length(cand_idx)) return(numeric(0))
    cand <- data.frame(i = cand_idx, x = x[cand_idx], y = y[cand_idx])
    cand <- cand[order(cand$y, decreasing = TRUE), , drop = FALSE]
    selected <- logical(nrow(cand))
    taken <- logical(nrow(cand))
    for (k in seq_len(nrow(cand))) {
      if (taken[k]) next
      selected[k] <- TRUE
      close <- abs(cand$x - cand$x[k]) <= window
      taken <- taken | close
    }
    sel <- cand[selected, , drop = FALSE]
    sel <- sel[order(sel$x), , drop = FALSE]
    sel$x
  }

  # --- internal helper: full AUC between minima flanking anchor peak ---
  .auc_around_anchor <- function(x, y, anchor_x, minima_x, min_width_bp = 40) {
    ok <- is.finite(x) & is.finite(y)
    x <- x[ok]; y <- y[ok]
    o <- order(x); x <- x[o]; y <- y[o]
    if (!is.finite(anchor_x)) return(list(auc = NA_real_, left = NA_real_, right = NA_real_))
    left_mins  <- minima_x[minima_x < anchor_x]
    right_mins <- minima_x[minima_x > anchor_x]
    pick_left  <- if (length(left_mins))  max(left_mins)  else min(x)
    pick_right <- if (length(right_mins)) min(right_mins) else max(x)
    if ((pick_right - pick_left) < min_width_bp) {
      mid <- anchor_x
      half <- max(min_width_bp/2, 20)
      pick_left  <- max(min(x),  mid - half)
      pick_right <- min(max(x),  mid + half)
    }
    rng <- x >= pick_left & x <= pick_right
    if (sum(rng) < 3L) {
      grid <- seq(pick_left, pick_right, length.out = 25L)
      yg <- approx(x, y, xout = grid, rule = 2)$y
      auc <- sum(diff(grid) * (head(yg, -1) + tail(yg, -1)) / 2)
    } else {
      xi <- x[rng]; yi <- y[rng]
      auc <- sum(diff(xi) * (head(yi, -1) + tail(yi, -1)) / 2)
    }
    list(auc = auc, left = pick_left, right = pick_right)
  }

  # --- main computation ---
  if (!"condition" %in% colnames(fragment_df)) {
    if (is.null(sample_conditions)) stop("Provide sample_conditions if 'condition' column is missing")
    fragment_df <- fragment_df %>%
      mutate(condition = sample_conditions[match(.data[[sample_col]], names(sample_conditions))])
  }

  norm_frag <- fragment_df %>%
    dplyr::filter(.data[[length_col]] >= 50 & .data[[length_col]] <= 1000) %>%
    group_by(condition, .data[[length_col]]) %>%
    summarise(count = n(), .groups = "drop_last") %>%
    mutate(norm_count = count / sum(count)) %>%
    group_by(condition) %>%
    mutate(smooth = zoo::rollmean(norm_count, k = smooth_k, fill = NA)) %>%
    ungroup()

  peaks_list <- norm_frag %>%
    group_by(condition) %>%
    arrange(.data[[length_col]], .by_group = TRUE) %>%
    group_modify(~ {
      df <- .x
      tibble(
        peaks  = list(.detect_local_peaks_nms(df[[length_col]], df$smooth, window = window)),
        minima = list(.detect_local_minima(df[[length_col]], df$smooth, window = minima_window))
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
    mutate(AUC_obj = map2(condition, left_peak, ~ {
      rows <- norm_frag %>% dplyr::filter(condition == .x)
      x <- rows[[length_col]]; y <- rows$smooth
      mins <- .detect_local_minima(x, y, window = minima_window)
      .auc_around_anchor(x, y, anchor_x = .y, minima_x = mins)
    }),
    AUC_anchor = map_dbl(AUC_obj, "auc"),
    xmin = map_dbl(AUC_obj, "left"),
    xmax = map_dbl(AUC_obj, "right"),
    NRL = right_peak - left_peak)

  delta_NRL <- delta_AUC_pct <- NA_real_
  peaks_consistent <- NA_character_
  if (!is.null(control_condition) && control_condition %in% summary_table$condition) {
    treatment_condition <- setdiff(summary_table$condition, control_condition)
    if (length(treatment_condition) == 1) {
      ctrl <- summary_table %>% filter(condition == control_condition)
      trt  <- summary_table %>% filter(condition == treatment_condition)
      delta_NRL <- trt$NRL - ctrl$NRL
      delta_AUC_pct <- (trt$AUC_anchor / ctrl$AUC_anchor) * 100
      peaks_consistent <- ifelse(trt$method == ctrl$method,
                                 "Same peaks used for ΔNRL and ΔAUC",
                                 "Different peaks used between samples")
    }
  }

  summary_table <- summary_table %>%
    mutate(delta_NRL = delta_NRL,
           delta_AUC_pct = delta_AUC_pct,
           consistency = peaks_consistent)

  max_smooth <- max(norm_frag$smooth, na.rm = TRUE)
  base_spacing <- max_smooth * 0.05
  arrow_spacing <- base_spacing * arrow_spacing_factor
  summary_table <- summary_table %>%
    mutate(arrow_y = max_smooth * 0.9 - (row_number() - 1) * arrow_spacing,
           text_y = arrow_y - arrow_spacing / 3)

  p <- ggplot(norm_frag, aes(x = .data[[length_col]], y = smooth, color = condition)) +
    geom_line(size = 0.8) +
    geom_vline(data = summary_table, aes(xintercept = left_peak, color = condition),
               linetype = "dotted", size = 0.7) +
    geom_vline(data = summary_table, aes(xintercept = right_peak, color = condition),
               linetype = "dashed", size = 0.7) +
    geom_segment(data = summary_table,
                 aes(x = left_peak, xend = right_peak, y = arrow_y, yend = arrow_y),
                 color = "black", na.rm = TRUE,
                 arrow = arrow(length = unit(0.15, "cm"))) +
    geom_text(data = summary_table,
              aes(x = (left_peak + right_peak)/2, y = text_y,
                  label = paste0("NRL (", method, "): ", round(NRL, 1), " bp")),
              vjust = 1, hjust = 0.5, color = "black", na.rm = TRUE) +
    labs(x = "Fragment length (bp)", y = "Normalized count",
         title = "Fragment length distribution with NRL and full-peak AUC") +
    scale_y_log10()

  for (i in seq_len(nrow(summary_table))) {
    cond <- summary_table$condition[i]
    xmin <- summary_table$xmin[i]; xmax <- summary_table$xmax[i]
    if (is.na(xmin) || is.na(xmax) || xmin >= xmax) next
    ribbon_df <- norm_frag %>% filter(condition == cond,
                               .data[[length_col]] >= xmin,
                               .data[[length_col]] <= xmax) %>% arrange(.data[[length_col]])
    if (nrow(ribbon_df) < 2) next
    y0 <- .safe_baseline(ribbon_df$smooth)
    ribbon_df$y0 <- y0
    p <- p + geom_ribbon(data = ribbon_df,
                         aes(x = .data[[length_col]], ymin = y0, ymax = smooth),
                         inherit.aes = FALSE,
                         fill = if (!is.null(colors) && cond %in% names(colors)) colors[[cond]] else "grey50",
                         alpha = 0.5)
  }

  if (!is.null(colors)) p <- p + scale_color_manual(values = colors)
  if (!is.null(custom_theme)) p <- p + custom_theme else p <- p + theme_minimal()

  if (!is.na(delta_NRL) && !is.na(delta_AUC_pct)) {
    nrl_arrow <- if (delta_NRL > 0) "→" else if (delta_NRL < 0) "←" else ""
    delta_auc_change <- delta_AUC_pct - 100
    auc_arrow <- if (delta_auc_change > 0) "↑" else if (delta_auc_change < 0) "↓" else ""
    auc_label <- paste0(abs(round(delta_auc_change, 1)), "% ",
                        ifelse(delta_auc_change > 0, "higher",
                               ifelse(delta_auc_change < 0, "lower", "no change")))
    consistency_label <- paste0("Peaks used: ", peaks_consistent)
    p <- p + annotate("text",
                      x = max(norm_frag[[length_col]], na.rm = TRUE),
                      y = max(norm_frag$smooth, na.rm = TRUE) * 0.95,
                      label = paste0("ΔNRL: ", round(delta_NRL, 1), " bp ", nrl_arrow, "\n",
                                     "ΔAUC: ", auc_label, " ", auc_arrow, "\n",
                                     consistency_label),
                      hjust = 1, vjust = 1.2, size = 4, color = "black")
  }

  list(summary = summary_table, plot = p)
}
