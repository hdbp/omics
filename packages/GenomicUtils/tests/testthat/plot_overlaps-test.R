# file: R/grl_overlap_plots.R

#' Plot overlaps (Venn + UpSet) for a `GRangesList` without `sf`
#'
#' @title Plot set overlaps for genomic ranges
#'
#' @description
#' Given a `GRangesList` of genomic sets, compute a disjoint "universe" of
#' segments and their membership across sets, then optionally draw:
#' (1) a Venn diagram via **ggvenn** (no `sf` dependency, up to 5 sets), and
#' (2) an UpSet plot via **ComplexUpset**.
#'
#' @details
#' Workflow:
#' 1. Validate input and drop empty sets.
#' 2. Build a disjoint universe with `GenomicRanges::disjoin()`, respecting `ignore.strand`.
#' 3. Compute a logical membership matrix with `IRanges::overlapsAny()` using `minoverlap`.
#' 4. If requested and `ncol <= 5`, draw a Venn diagram using **ggvenn** with gradient fills.
#' 5. If requested, draw an UpSet plot using **ComplexUpset**.
#'
#' Names:
#' - Existing `names(grl)` are preserved; when absent/duplicated, unique names are generated.
#'
#' Dependencies:
#' - Core: **GenomicRanges**, **IRanges**, **S4Vectors** (validated at runtime).
#' - Optional for plotting: **ggvenn**, **ggplot2** (for Venn) and **ComplexUpset**, **ggplot2** (for UpSet).
#'
#' Edge cases:
#' - If all sets are empty or disjoin returns no segments, no plots are drawn and an empty result is returned.
#'
#' @note
#' **ggvenn** cannot show counts *and* percentages simultaneously in region labels.
#' Only up to 5 sets are supported for the Venn diagram; use UpSet for larger numbers.
#'
#' @param grl A `GRangesList` containing ≥2 non-empty genomic sets. Names are
#'   used as set labels; missing/duplicated names are uniquified.
#' @param ignore.strand `logical(1)`. If `TRUE`, strand is ignored for both disjoin
#'   and overlap membership.
#' @param minoverlap `integer(1)`. Minimum overlap for membership via
#'   `IRanges::overlapsAny()`. Defaults to `1L`.
#' @param do_venn `logical(1)`. Draw Venn diagram via **ggvenn** when `ncol(membership) <= 5`.
#' @param do_upset `logical(1)`. Draw UpSet plot via **ComplexUpset**.
#' @param return_plots `logical(1)`. If `TRUE`, return `ggplot` objects
#'   `venn_plot` and `upset_plot` (may be `NULL` when not drawn or packages missing).
#'
#' @param venn_title Optional `character(1)` title for the Venn plot.
#' @param venn_fill_low  `character(1)`. Low color for Venn gradient across sets (hex or R color).
#' @param venn_fill_high `character(1)`. High color for Venn gradient across sets.
#' @param venn_edge_color `character(1)`. Edge (stroke) color for Venn regions.
#'
#' @param venn_region_label `character(1)`. Region label content:
#'   one of `"percent"`, `"count"`, `"both"`, or `"none"`. For ggvenn, `"both"`
#'   degrades to percentages with a message due to package limitation; `"none"` shows no labels.
#' @param percent_digits `integer(1)`. Decimal digits for percentages in Venn labels.
#' @param venn_region_label_color `character(1)`. Color for Venn region labels.
#' @param venn_region_label_size  `numeric(1)`. Size for Venn region labels (mapped to ggvenn `text_size`).
#'
#' @param venn_set_label_color `character(1)`. Color for Venn set (group) labels.
#' @param venn_set_label_size  `numeric(1)`. Size for Venn set labels (mapped to ggvenn `set_name_size`).
#' @param venn_set_label_fontface `character(1)`. Font face for Venn set labels (e.g., `"bold"`).
#'
#' @param upset_title Optional `character(1)` title for the UpSet plot.
#'
#' @return
#' An `invisible` `list` with:
#' - `universe`: a `GRanges` of disjoint segments.
#' - `membership`: a `logical` matrix (`nrow(universe)` × `length(grl)`) indicating segment membership per set.
#' - `venn_plot`: `ggplot` or `NULL` (only when `return_plots = TRUE`).
#' - `upset_plot`: `ggplot` or `NULL` (only when `return_plots = TRUE`).
#'
#' Side effects:
#' - Prints ggplot objects for Venn/UpSet when corresponding packages are available and plotting is enabled.
#'
#' @examples
#' \dontrun{
#' if (requireNamespace("GenomicRanges", quietly = TRUE)) {
#'   library(GenomicRanges)
#'   g1 <- GRanges("chr1", IRanges::IRanges(c(1, 20), width = 10))
#'   g2 <- GRanges("chr1", IRanges::IRanges(c(5, 28), width = 8))
#'   g3 <- GRanges("chr1", IRanges::IRanges(c(50), width = 12))
#'   grl <- GenomicRanges::GRangesList(A = g1, B = g2, C = g3)
#'
#'   res <- plot_grl_overlaps(grl, do_venn = TRUE, do_upset = TRUE, return_plots = TRUE)
#'   res$venn_plot; res$upset_plot
#' }
#' }
#'
#' @seealso
#' - **ggvenn**: `ggvenn::ggvenn()`
#' - **ComplexUpset**: `ComplexUpset::upset()`
#' - **GenomicRanges**: `GenomicRanges::disjoin()`
#' - **IRanges**: `IRanges::overlapsAny()`
#'
#' @importFrom GenomicRanges disjoin
#' @importFrom IRanges overlapsAny
#' @importFrom methods is
#' @importFrom grDevices colorRampPalette
#' @export
plot_grl_overlaps <- function(
    grl,
    ignore.strand = TRUE,
    minoverlap = 1L,
    do_venn = TRUE,
    do_upset = TRUE,
    return_plots = FALSE,
    # Venn styling
    venn_title = NULL,
    venn_fill_low  = "#F7FBFF",
    venn_fill_high = "#6BAED6",
    venn_edge_color = "grey40",
    # Region labels
    venn_region_label = c("percent","count","both","none"),
    percent_digits = 1,
    venn_region_label_color = "black",
    venn_region_label_size  = 3.6,  # used by ggvenn as `text_size`
    # Group (set) labels
    venn_set_label_color = "black",
    venn_set_label_size  = 5,        # used by ggvenn as `set_name_size`
    venn_set_label_fontface = "bold",
    # UpSet title
    upset_title = NULL
) {
  venn_region_label <- match.arg(venn_region_label)
  
  # core deps
  need <- c("GenomicRanges","IRanges","S4Vectors")
  miss <- need[!vapply(need, requireNamespace, TRUE, quietly = TRUE)]
  if (length(miss)) stop("Missing packages: ", paste(miss, collapse = ", "),
                         ". Install via BiocManager::install().", call. = FALSE)
  
  # input checks
  if (!methods::is(grl, "GRangesList")) stop("`grl` must be a GRangesList.", call. = FALSE)
  if (length(grl) < 2) stop("Provide \u22652 sets.", call. = FALSE)
  
  # names: keep user's; uniquify only if needed
  if (is.null(names(grl)) || anyNA(names(grl)) || anyDuplicated(names(grl))) {
    names(grl) <- make.unique(ifelse(is.null(names(grl)), paste0("set_", seq_along(grl)), names(grl)))
  }
  
  # drop empties
  non_empty <- lengths(grl) > 0L
  if (!all(non_empty)) {
    grl <- grl[non_empty]
    if (length(grl) < 2) stop("After dropping empty sets, <2 remain.", call. = FALSE)
  }
  
  # disjoint universe; base::unlist so S4 dispatch finds GRangesList method
  universe <- GenomicRanges::disjoin(
    unlist(grl, use.names = FALSE),
    ignore.strand = ignore.strand
  )
  if (length(universe) == 0L) {
    message("No disjoint segments found; nothing to plot.")
    out <- list(
      universe = universe,
      membership = matrix(nrow = 0, ncol = length(grl))
    )
    if (isTRUE(return_plots)) {
      out$venn_plot <- NULL
      out$upset_plot <- NULL
    }
    return(invisible(out))
  }
  
  # membership matrix (rows: segments; cols: sets)
  mem <- vapply(
    grl,
    function(g) IRanges::overlapsAny(universe, g,
                                     ignore.strand = ignore.strand,
                                     minoverlap = minoverlap),
    FUN.VALUE = logical(length(universe))
  )
  colnames(mem) <- names(grl)
  
  # plot holders
  p_venn <- NULL
  p_upset <- NULL
  
  # ===== Venn (≤5 sets) via ggvenn (no sf) =====
  if (isTRUE(do_venn) && ncol(mem) <= 5) {
    if (requireNamespace("ggvenn", quietly = TRUE) &&
        requireNamespace("ggplot2", quietly = TRUE)) {
      
      # list of element indices per set; names from grl
      idx_list <- lapply(seq_len(ncol(mem)), function(j) which(mem[, j]))
      names(idx_list) <- colnames(mem)
      
      # palette: gradient from low->high across sets
      fills <- grDevices::colorRampPalette(c(venn_fill_low, venn_fill_high))(length(idx_list))
      
      # map requested label mode to ggvenn knobs
      show_pct   <- venn_region_label %in% c("percent","both")
      show_count <- venn_region_label %in% c("count","both")
      show_percentage <- isTRUE(show_pct)  # ggvenn: either percentage or counts
      show_elements   <- FALSE
      
      p_venn <- ggvenn::ggvenn(
        idx_list,
        show_elements   = show_elements,
        show_percentage = show_percentage,
        digits          = percent_digits,
        # styles
        fill_color      = fills,
        stroke_color    = venn_edge_color,
        set_name_color  = venn_set_label_color,
        set_name_size   = venn_set_label_size,
        text_color      = venn_region_label_color,
        text_size       = venn_region_label_size
      )
      
      if (!is.null(venn_title)) {
        p_venn <- p_venn + ggplot2::labs(title = venn_title) +
          ggplot2::theme(plot.title = ggplot2::element_text(hjust = 0.5))
      }
      
      if (show_count && show_pct) {
        message("ggvenn limitation: showing percentages; counts+percent together not supported.")
      }
      
      print(p_venn)
    } else {
      message("Install 'ggvenn' (no sf) to draw the Venn: install.packages('ggvenn').")
    }
  } else if (isTRUE(do_venn) && ncol(mem) > 5) {
    message("Venn suppressed: more than 5 sets; consider UpSet instead.")
  }
  
  # ===== UpSet (ComplexUpset) =====
  if (isTRUE(do_upset)) {
    if (requireNamespace("ComplexUpset", quietly = TRUE) &&
        requireNamespace("ggplot2", quietly = TRUE)) {
      df <- as.data.frame(mem, optional = TRUE, stringsAsFactors = FALSE)
      sets <- colnames(df)
      p_upset <- ComplexUpset::upset(
        df, intersect = sets,
        base_annotations = list(
          "Intersection size" = ComplexUpset::intersection_size(text = list(vjust = -0.5))
        )
      ) + ggplot2::labs(title = upset_title, x = NULL, y = "segments") +
        ggplot2::theme(plot.title = ggplot2::element_text(hjust = 0.5))
      print(p_upset)
    } else {
      message("Install 'ComplexUpset' + 'ggplot2' for the UpSet plot.")
    }
  }
  
  out <- list(universe = universe, membership = mem)
  if (isTRUE(return_plots)) {
    out$venn_plot <- p_venn
    out$upset_plot <- p_upset
  }
  invisible(out)
}

# file: tests/testthat/test-grl_overlap_plots.R

test_that("basic universe and membership behave", {
  skip_if_not_installed("GenomicRanges")
  skip_if_not_installed("IRanges")
  library(GenomicRanges)
  
  g1 <- GRanges("chr1", IRanges::IRanges(c(1, 20), width = 10))
  g2 <- GRanges("chr1", IRanges::IRanges(c(5, 28), width = 8))
  g3 <- GRanges("chr1", IRanges::IRanges(c(50), width = 12))
  grl <- GenomicRanges::GRangesList(A = g1, B = g2, C = g3)
  
  res <- plot_grl_overlaps(grl, do_venn = FALSE, do_upset = FALSE)
  expect_s4_class(res$universe, "GRanges")
  expect_true(NROW(res$membership) == length(res$universe))
  expect_equal(colnames(res$membership), c("A","B","C"))
  expect_type(res$membership, "logical")
})

test_that("minoverlap changes membership", {
  skip_if_not_installed("GenomicRanges")
  library(GenomicRanges)
  g1 <- GRanges("chr1", IRanges::IRanges(1, width = 10))
  g2 <- GRanges("chr1", IRanges::IRanges(10, width = 1))
  grl <- GenomicRanges::GRangesList(A = g1, B = g2)
  
  r1 <- plot_grl_overlaps(grl, minoverlap = 1L, do_venn = FALSE, do_upset = FALSE)
  r2 <- plot_grl_overlaps(grl, minoverlap = 2L, do_venn = FALSE, do_upset = FALSE)
  expect_false(identical(r1$membership, r2$membership))
})

test_that("names are uniquified when missing/duplicated", {
  skip_if_not_installed("GenomicRanges")
  library(GenomicRanges)
  g1 <- GRanges("chr1", IRanges::IRanges(1, 10))
  g2 <- GRanges("chr1", IRanges::IRanges(20, 10))
  grl <- GenomicRanges::GRangesList(g1, g2) # no names
  
  res <- plot_grl_overlaps(grl, do_venn = FALSE, do_upset = FALSE)
  expect_false(any(is.na(colnames(res$membership))))
  expect_equal(ncol(res$membership), 2L)
  
  grl2 <- GenomicRanges::GRangesList(A = g1, A = g2) # dup names
  res2 <- plot_grl_overlaps(grl2, do_venn = FALSE, do_upset = FALSE)
  expect_equal(ncol(res2$membership), 2L)
  expect_false(anyDuplicated(colnames(res2$membership)))
})

test_that("Venn suppressed when >5 sets", {
  skip_if_not_installed("GenomicRanges")
  library(GenomicRanges)
  gl <- replicate(6, GRanges("chr1", IRanges::IRanges(1:2, 10)), simplify = FALSE)
  grl <- GenomicRanges::GRangesList(setNames(gl, paste0("S", 1:6)))
  # Should not error; message is acceptable
  expect_silent(plot_grl_overlaps(grl, do_venn = TRUE, do_upset = FALSE))
})

test_that("return_plots returns plot objects or NULLs", {
  skip_if_not_installed("GenomicRanges")
  library(GenomicRanges)
  g1 <- GRanges("chr1", IRanges::IRanges(c(1, 20), width = 10))
  g2 <- GRanges("chr1", IRanges::IRanges(c(5, 28), width = 8))
  grl <- GenomicRanges::GRangesList(A = g1, B = g2)
  
  res <- plot_grl_overlaps(grl, do_venn = FALSE, do_upset = FALSE, return_plots = TRUE)
  expect_true(all(c("venn_plot","upset_plot") %in% names(res)))
  expect_null(res$venn_plot)
  expect_null(res$upset_plot)
  
  # If pkgs present, plots should be ggplot objects
  if (requireNamespace("ggvenn", quietly = TRUE) && requireNamespace("ggplot2", quietly = TRUE)) {
    res2 <- plot_grl_overlaps(grl, do_venn = TRUE, do_upset = FALSE, return_plots = TRUE)
    expect_true(inherits(res2$venn_plot, "ggplot"))
  }
  
  if (requireNamespace("ComplexUpset", quietly = TRUE) && requireNamespace("ggplot2", quietly = TRUE)) {
    res3 <- plot_grl_overlaps(grl, do_venn = FALSE, do_upset = TRUE, return_plots = TRUE)
    expect_true(inherits(res3$upset_plot, "ggplot"))
  }
})

test_that("empty result returns zero-row membership", {
  skip_if_not_installed("GenomicRanges")
  library(GenomicRanges)
  grl <- GenomicRanges::GRangesList(A = GRanges(), B = GRanges())
  expect_error(plot_grl_overlaps(grl, do_venn = FALSE, do_upset = FALSE), "Provide")
})
