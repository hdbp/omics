# Shared colour palette for significance categories across all RNA-seq plots.
sig_colors <- c(Up = "#D62728", Down = "#1F77B4", NS = "grey70")

# Adds a `sig` column classifying each gene as Up, Down, or NS based on
# adjusted p-value and absolute log2FC thresholds. Used as input by
# make_ma() and make_volcano() to colour points consistently.
label_sig <- function(df, lfc_cut = 1, padj_cut = 0.05) {
  df %>% mutate(
    sig = case_when(
      padj < padj_cut & log2FoldChange >  lfc_cut ~ "Up",
      padj < padj_cut & log2FoldChange < -lfc_cut ~ "Down",
      TRUE ~ "NS"
    )
  )
}

# Builds an MA plot: log10 mean expression on x, log2FC on y.
# Up/Down genes are coloured; counts of each are annotated in the corners.
make_ma <- function(df, title) {
  df <- label_sig(df)
  n_up   <- sum(df$sig == "Up")
  n_down <- sum(df$sig == "Down")
  ggplot(df, aes(x = log10(baseMean), y = log2FoldChange, color = sig)) +
    geom_point(size = 0.6, alpha = 0.5, shape = 16) +
    geom_hline(yintercept = 0, linewidth = 0.4, linetype = "dashed", color = "black") +
    scale_color_manual(values = sig_colors, guide = "none") +
    annotate("text", x = -Inf, y =  Inf, label = paste0("Up: ",   n_up),
             hjust = -0.15, vjust =  1.5, size = 3, color = sig_colors["Up"]) +
    annotate("text", x = -Inf, y = -Inf, label = paste0("Down: ", n_down),
             hjust = -0.15, vjust = -0.5, size = 3, color = sig_colors["Down"]) +
    labs(title = title,
         x = expression(log[10](mean~expression)),
         y = expression(log[2]~FC)) +
    theme_classic(base_size = 10) +
    theme(plot.title = element_text(face = "bold", hjust = 0.5))
}

# Builds a volcano plot: log2FC on x, -log10 adjusted p-value on y.
# Up/Down genes are coloured; the top 10 by absolute fold change are labelled
# with gene symbols via ggrepel to avoid overplotting.
make_volcano <- function(df, title) {
  df <- label_sig(df)
  top_genes <- df %>%
    dplyr::filter(sig != "NS") %>%
    slice_max(order_by = abs(log2FoldChange), n = 10)
  n_up   <- sum(df$sig == "Up")
  n_down <- sum(df$sig == "Down")
  ggplot(df, aes(x = log2FoldChange, y = -log10(padj), color = sig)) +
    geom_point(size = 0.6, alpha = 0.5, shape = 16) +
    geom_vline(xintercept = c(-1, 1), linewidth = 0.3, linetype = "dashed", color = "grey40") +
    geom_hline(yintercept = -log10(0.05), linewidth = 0.3, linetype = "dashed", color = "grey40") +
    coord_cartesian(xlim = c(-5, 5)) +
    geom_text_repel(data = top_genes, aes(label = SYMBOL),
                    size = 2.5, max.overlaps = 15, segment.size = 0.2, show.legend = FALSE) +
    scale_color_manual(values = sig_colors, guide = "none") +
    annotate("text", x =  Inf, y = Inf, label = paste0("Up: ",   n_up),
             hjust =  1.1, vjust = 1.5, size = 3, color = sig_colors["Up"]) +
    annotate("text", x = -Inf, y = Inf, label = paste0("Down: ", n_down),
             hjust = -0.1, vjust = 1.5, size = 3, color = sig_colors["Down"]) +
    labs(title = title,
         x = expression(log[2]~FC),
         y = expression(-log[10](p[adj]))) +
    theme_classic(base_size = 10) +
    theme(plot.title = element_text(face = "bold", hjust = 0.5))
}

# Converts a DESeq2 result data frame into a named numeric vector of Wald
# statistics sorted in decreasing order, ready for use as GSEA input.
# Removes genes with missing stats or duplicate symbols to avoid errors.
make_ranked_list <- function(df) {
  df %>%
    filter(!is.na(stat), !is.na(SYMBOL), !duplicated(SYMBOL)) %>%
    { setNames(.$stat, .$SYMBOL) } %>%
    sort(decreasing = TRUE)
}

# Returns the IDs of the top n pathways from a GSEA result object,
# ranked by adjusted p-value. Used internally by make_mountains().
top_paths <- function(gsea_obj, n = 2) {
  as.data.frame(gsea_obj) %>%
    arrange(p.adjust) %>%
    slice_head(n = n) %>%
    pull(ID)
}

# Generates GSEA enrichment (mountain) plots for the top n pathways
# of a given cell type. Returns a list of ggplot objects, one per pathway,
# with a p-value table included in each panel.
make_mountains <- function(gsea_obj, cell_label, n = 2) {
  paths <- top_paths(gsea_obj, n)
  lapply(paths, function(p) {
    gseaplot2(gsea_obj, geneSetID = p, title = cell_label, pvalue_table = TRUE)
  })
}
