if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
source("helper_functions/helpers.R")
library(ChIPseeker)
library(TxDb.Mmusculus.UCSC.mm9.knownGene)
library(org.Mm.eg.db)
library(patchwork)

# ============================================================================
# Thresholds
# ============================================================================

atac_fdr_thresh <- 0.05
rna_padj_thresh <- 0.05
rna_lfc_thresh  <- 1       # minimum |log2FC| for RNA significance
distal_kb       <- 50      # window around TSS for candidate enhancer peaks

cat("\n=== ATAC-seq x RNA-seq integration ===\n")
cat(sprintf("ATAC: FDR <= %.2f\n", atac_fdr_thresh))
cat(sprintf("RNA:  padj <= %.2f  |  |log2FC| >= %.1f\n", rna_padj_thresh, rna_lfc_thresh))
cat(sprintf("Distal window: +/- %d kb from TSS\n\n", distal_kb))

# ============================================================================
# Load upstream results
# ============================================================================

atac_analysis <- readRDS(file.path(atac_data, "csaw_atac_analysis_results.rds"))
rna_list      <- readRDS(file.path(rna_data,  "res_list.rds"))

txdb      <- TxDb.Mmusculus.UCSC.mm9.knownGene
shared_ct <- intersect(names(atac_analysis), names(rna_list))
cat("Cell types:", paste(shared_ct, collapse = ", "), "\n")

# ============================================================================
# Analysis 1 — Promoter accessibility
# Peaks annotated as Promoter by ChIPseeker.
# Most direct link between chromatin state and transcriptional output.
# ============================================================================

cat("\n\n====== ANALYSIS 1: PROMOTER PEAKS ======\n")

promo_list    <- run_integration(atac_analysis, rna_list, shared_ct,
                                 atac_fdr_thresh, rna_padj_thresh, rna_lfc_thresh,
                                 feature = "promoter")
promo_combined <- bind_rows(promo_list)

walk(shared_ct, function(ct) {
  cat("\n", ct, "— promoter concordance:\n", sep = "")
  print(dplyr::count(promo_list[[ct]], concordance) %>% arrange(desc(n)))
})

# ============================================================================
# Analysis 2 — Distal peaks within 50 kb of TSS (candidate enhancers)
# Non-promoter peaks in the vicinity of a gene that may act as cis-regulatory
# elements. Concordance with expression changes suggests enhancer activity.
# ============================================================================

cat("\n\n====== ANALYSIS 2: DISTAL PEAKS (+/-", distal_kb, "kb) ======\n")

distal_list    <- run_integration(atac_analysis, rna_list, shared_ct,
                                  atac_fdr_thresh, rna_padj_thresh, rna_lfc_thresh,
                                  feature = "distal", distal_kb = distal_kb)
distal_combined <- bind_rows(distal_list)

walk(shared_ct, function(ct) {
  cat("\n", ct, "— distal concordance:\n", sep = "")
  print(dplyr::count(distal_list[[ct]], concordance) %>% arrange(desc(n)))
})

# ============================================================================
# Plot helpers
# ============================================================================

conc_colors <- c(
  "Concordant activation" = "#E41A1C",
  "Concordant repression" = "#377EB8",
  "Discordant"            = "#984EA3",
  "ATAC only"             = "#FF7F00",
  "RNA only"              = "#4DAF4A",
  "Neither"               = adjustcolor("grey60", 0.3)
)
conc_order <- c("Concordant activation", "Concordant repression",
                "Discordant", "ATAC only", "RNA only", "Neither")

make_scatter <- function(df, title) {
  df %>%
    dplyr::filter(!is.na(atac_logFC), !is.na(rna_log2FC)) %>%
    mutate(concordance = factor(concordance, levels = conc_order),
           cell_type   = factor(cell_type,   levels = cell_types)) %>%
    arrange(concordance == "Neither") %>%
    ggplot(aes(x = atac_logFC, y = rna_log2FC, color = concordance)) +
    geom_point(size = 0.8, alpha = 0.7) +
    geom_hline(yintercept = c(-rna_lfc_thresh, rna_lfc_thresh),
               linetype = "dashed", color = "grey40", linewidth = 0.4) +
    geom_vline(xintercept = 0,
               linetype = "dashed", color = "grey40", linewidth = 0.4) +
    facet_wrap(~ cell_type, nrow = 1) +
    scale_color_manual(values = conc_colors, name = NULL) +
    labs(title    = title,
         subtitle = sprintf("ATAC: FDR ≤ %.2f  |  RNA: padj ≤ %.2f, |log2FC| ≥ %.1f",
                            atac_fdr_thresh, rna_padj_thresh, rna_lfc_thresh),
         x = "ATAC log2FC (cTKO / WT)", y = "RNA log2FC (cTKO / WT)") +
    theme_minimal(base_size = 11) +
    theme(plot.title       = element_text(face = "bold"),
          panel.grid.minor = element_blank(),
          strip.text       = element_text(face = "bold"),
          legend.position  = "bottom") +
    guides(color = guide_legend(override.aes = list(size = 3, alpha = 1)))
}

make_bar <- function(df, title) {
  df %>%
    dplyr::filter(concordance != "Neither") %>%
    dplyr::count(cell_type, concordance) %>%
    mutate(concordance = factor(concordance, levels = rev(conc_order)),
           cell_type   = factor(cell_type,   levels = cell_types)) %>%
    ggplot(aes(x = cell_type, y = n, fill = concordance)) +
    geom_col(width = 0.6) +
    geom_text(aes(label = n), position = position_stack(vjust = 0.5),
              size = 3, color = "white", fontface = "bold") +
    scale_fill_manual(values = conc_colors, name = NULL,
                      breaks = conc_order[conc_order != "Neither"]) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.05))) +
    labs(title = title, x = NULL, y = "Gene count") +
    theme_minimal(base_size = 11) +
    theme(plot.title         = element_text(face = "bold"),
          panel.grid.major.x = element_blank(),
          panel.grid.minor   = element_blank(),
          legend.position    = "bottom")
}

# ============================================================================
# Save individual analysis plots
# ============================================================================

promo_panel <- make_scatter(promo_combined,
                            "Promoter accessibility vs gene expression — cTKO vs WT") /
               make_bar(promo_combined, "Genes by concordance class — promoter peaks") +
               plot_layout(heights = c(2, 1)) +
               plot_annotation(
                 title = "ATAC-seq × RNA-seq — Promoter peaks",
                 theme = theme(plot.title = element_text(face = "bold", size = 13))
               )

ggsave(file.path(dirs$plots, "integration_promoter.pdf"),
       promo_panel, width = 14, height = 10)

distal_panel <- make_scatter(distal_combined,
                             sprintf("Distal accessibility (+/-%d kb) vs gene expression — cTKO vs WT",
                                     distal_kb)) /
                make_bar(distal_combined,
                         sprintf("Genes by concordance class — distal peaks (+/-%d kb)", distal_kb)) +
                plot_layout(heights = c(2, 1)) +
                plot_annotation(
                  title = sprintf("ATAC-seq × RNA-seq — Distal peaks (+/-%d kb, candidate enhancers)",
                                  distal_kb),
                  theme = theme(plot.title = element_text(face = "bold", size = 13))
                )

ggsave(file.path(dirs$plots, "integration_distal_enhancers.pdf"),
       distal_panel, width = 14, height = 10)

# ============================================================================
# Comparison figure — concordance rates: promoter vs distal side by side
# ============================================================================

compare_df <- bind_rows(
  promo_combined  %>% mutate(analysis = "Promoter"),
  distal_combined %>% mutate(analysis = sprintf("Distal (+/-%d kb)", distal_kb))
) %>%
  dplyr::filter(concordance != "Neither") %>%
  dplyr::count(analysis, cell_type, concordance) %>%
  group_by(analysis, cell_type) %>%
  mutate(pct       = n / sum(n) * 100,
         concordance = factor(concordance, levels = rev(conc_order)),
         cell_type   = factor(cell_type,   levels = cell_types),
         analysis    = factor(analysis, levels = c("Promoter",
                                                    sprintf("Distal (+/-%d kb)", distal_kb)))) %>%
  ungroup()

p_compare <- ggplot(compare_df, aes(x = cell_type, y = pct, fill = concordance)) +
  geom_col(width = 0.7) +
  geom_text(aes(label = if_else(pct >= 5, sprintf("%.0f%%", pct), "")),
            position = position_stack(vjust = 0.5),
            size = 2.8, color = "white", fontface = "bold") +
  facet_wrap(~ analysis, nrow = 1) +
  scale_fill_manual(values = conc_colors, name = NULL,
                    breaks = conc_order[conc_order != "Neither"]) +
  scale_y_continuous(labels = scales::label_percent(scale = 1),
                     expand = expansion(mult = c(0, 0.02))) +
  labs(title    = "Concordance rates: promoter vs distal peaks",
       subtitle = "Percentage of genes (excluding 'Neither') per concordance class",
       x = NULL, y = "Percentage") +
  theme_minimal(base_size = 11) +
  theme(plot.title         = element_text(face = "bold"),
        panel.grid.major.x = element_blank(),
        panel.grid.minor   = element_blank(),
        strip.text         = element_text(face = "bold"),
        legend.position    = "bottom")

ggsave(file.path(dirs$plots, "integration_promoter_vs_distal.pdf"),
       p_compare, width = 10, height = 5)

# ============================================================================
# Save tables
# ============================================================================

write_csv(promo_combined,
          file.path(dirs$data, "integration_promoter_all.csv"))
write_csv(distal_combined,
          file.path(dirs$data, "integration_distal_all.csv"))

write_csv(
  promo_combined %>%
    dplyr::filter(concordance %in% c("Concordant activation", "Concordant repression")) %>%
    arrange(cell_type, concordance, desc(abs(atac_logFC))),
  file.path(dirs$data, "integration_promoter_concordant.csv")
)
write_csv(
  distal_combined %>%
    dplyr::filter(concordance %in% c("Concordant activation", "Concordant repression")) %>%
    arrange(cell_type, concordance, desc(abs(atac_logFC))),
  file.path(dirs$data, "integration_distal_concordant.csv")
)

saveRDS(list(promoter = promo_list, distal = distal_list),
        file.path(dirs$data, "integration_atac_rna.rds"))

cat("\n=== 01_atac_rna_integration.R complete ===\n")
cat("Output: ../../results/integration/\n")
