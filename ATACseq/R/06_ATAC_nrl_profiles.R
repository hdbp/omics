if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(csaw)
library(GenomicUtils)

cat("\n=== Fragment size distributions & NRL profiles ===\n")

# ============================================================================
# PE fragment sizes
# ============================================================================

readParam <- csaw::readParam(
  minq     = 10L,
  pe       = "both",
  dedup    = TRUE,
  restrict = paste0("chr", 1:19)
)

PEsizes <- lapply(metadata$bam.files, csaw::getPESizes, readParam)
names(PEsizes) <- metadata$sample

dg     <- map(PEsizes, "diagnostics")
mapped <- map_vec(dg, "mapped.reads")
sf     <- 1e6 / mapped

frag.sizes <- map(PEsizes, "sizes")

frag.sizes.df <- as_tibble(stack(frag.sizes)) %>%
  dplyr::rename(sample = ind) %>%
  inner_join(metadata[c("sample", "Cell type", "Genotype")], by = "sample") %>%
  dplyr::rename(cell_type = `Cell type`, genotype = Genotype)

p_frag <- frag.sizes.df %>%
  filter(values >= 200, values <= 1000) %>%
  group_by(cell_type, genotype, sample) %>%
  reframe(
    x = density(values, from = 140, to = 1000, n = 512)$x,
    y = density(values, from = 140, to = 1000, n = 512)$y
  ) %>%
  ggplot(aes(x = x, y = y, color = genotype, fill = genotype)) +
  stat_summary(fun.data = mean_se, geom = "ribbon", alpha = 0.3, color = NA) +
  stat_summary(fun = mean, geom = "line", linewidth = 1.5) +
  facet_wrap(~cell_type) +
  scale_color_manual(values = c(WT = "black", cTKO = "red")) +
  scale_fill_manual(values  = c(WT = "black", cTKO = "red")) +
  labs(x = "Fragment size (bp)", y = "Density",
       title = "Fragment size distribution — nucleosomal range") +
  theme_minimal()

ggsave(
  file.path(dirs$meta, "atac_fragment_size_distribution.pdf"),
  p_frag, width = 12, height = 4
)

# ============================================================================
# NRL profiles per cell type
# ============================================================================

metadata_list <- split(metadata, metadata$`Cell type`)

nrl_results <- list()

for (ct in names(metadata_list)) {
  df_nrl <- metadata_list[[ct]] %>%
    dplyr::rename(cell_type = `Cell type`, condition = Genotype)

  condition_map <- deframe(df_nrl %>% select(sample, condition))
  frag_ct       <- frag.sizes.df %>% filter(sample %in% names(condition_map))

  nrl_results[[ct]] <- GenomicUtils::nrl(
    fragments_df           = frag_ct,
    sample_id_column       = "sample",
    fragment_length_column = "values",
    sample_condition_map   = condition_map,
    control_condition_name = "WT",
    plot_title_text        = ct,
    arrow_spacing_scale    = 6,
    condition_colors       = c(WT = "black", cTKO = "red"),
    smoothing_window_size = 25,minima_merge_window_bp = 100,auc_window_bp=80,
    auc_method='peak_to_minimum',ggplot_theme=theme_custom()
  )
}

saveRDS(nrl_results, file.path(dirs$data, "atac_nrl_results.rds"))

nrl_panel <- wrap_plots(lapply(nrl_results, `[[`, "plot"), ncol = 1) +
  plot_annotation(title = "NRL profiles — all cell types")
print(nrl_panel)

ggsave(
  file.path(dirs$meta, "atac_nrl_panel.pdf"),
  nrl_panel, width = 7.5, height = 10
)

cat("\n=== 06_nrl_profiles.R complete ===\n")
cat("Output: ../../results/ATACseq/metagene/ | ../../results/ATACseq/data/\n")
