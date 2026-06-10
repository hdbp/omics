if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(clusterProfiler)
library(enrichplot)
library(msigdbr)
library(org.Mm.eg.db)
library(patchwork)
library(cowplot)
library(ggplotify)

source("helper_functions/functions.R")

res_list     <- readRDS(file.path(dirs$data, "res_list.rds"))
ranked_lists <- lapply(res_list, make_ranked_list)

# ── GO Biological Process ──────────────────────────────────────────────────────
gsea_go_list <- lapply(ranked_lists, function(gl) {
  gseGO(
    geneList      = gl,
    OrgDb         = org.Mm.eg.db,
    keyType       = "SYMBOL",
    ont           = "BP",
    minGSSize     = 10,
    maxGSSize     = 500,
    pvalueCutoff  = 0.05,
    pAdjustMethod = "BH",
    verbose       = FALSE,
    seed          = TRUE
  )
})

go_ridge_panel <- wrap_plots(
  lapply(names(gsea_go_list), function(ct) {
    ridgeplot(gsea_go_list[[ct]], showCategory = 15, label_format = 40) + labs(title = ct)
  }),
  ncol = length(gsea_go_list)
) + plot_annotation(
  title = "GO Biological Process GSEA — cTKO vs WT",
  theme = theme(plot.title = element_text(face = "bold", hjust = 0.5))
)
ggsave(file.path(dirs$plots, "cTKO_RNAseq_GO_ridgeplot_panel.pdf"),
       go_ridge_panel, width = 18, height = 8)

# ── MSigDB Hallmark ────────────────────────────────────────────────────────────
hallmark_df <- msigdbr(species = "Mus musculus", category = "H") %>%
  dplyr::select(gs_name, gene_symbol)

gsea_hallmark_list <- lapply(ranked_lists, function(gl) {
  GSEA(
    geneList      = gl,
    TERM2GENE     = hallmark_df,
    minGSSize     = 10,
    maxGSSize     = 500,
    pvalueCutoff  = 0.25,
    pAdjustMethod = "BH",
    verbose       = FALSE,
    seed          = TRUE
  )
})

hallmark_dot_panel <- wrap_plots(
  lapply(names(gsea_hallmark_list), function(ct) {
    dotplot(gsea_hallmark_list[[ct]], showCategory = 15, font.size = 8) + labs(title = ct)
  }),
  ncol = length(gsea_hallmark_list)
) + plot_annotation(
  title = "Hallmark GSEA — cTKO vs WT",
  theme = theme(plot.title = element_text(face = "bold", hjust = 0.5))
)
ggsave(file.path(dirs$plots, "cTKO_RNAseq_Hallmark_dotplot_panel.pdf"),
       hallmark_dot_panel, width = 18, height = 8)

# ── Hallmark mountain plots (top 2 per cell type) ─────────────────────────────
all_mountain_plots <- unlist(
  lapply(names(gsea_hallmark_list), function(ct) {
    make_mountains(gsea_hallmark_list[[ct]], ct, n = 2)
  }),
  recursive = FALSE
)
mountain_panel <- cowplot::plot_grid(
  plotlist = lapply(all_mountain_plots, ggplotify::as.grob),
  ncol = 3, byrow = FALSE
)
ggsave(
  file.path(dirs$plots, "cTKO_RNAseq_Hallmark_mountain_panel.pdf"),
  mountain_panel,
  width  = 15,
  height = 5 * ceiling(length(all_mountain_plots) / 3)
)

# ── Save R objects ─────────────────────────────────────────────────────────────
saveRDS(gsea_go_list,       file.path(dirs$data, "gsea_go_list.rds"))
saveRDS(gsea_hallmark_list, file.path(dirs$data, "gsea_hallmark_list.rds"))

message("GSEA done. RDS & plots in ", dirs$data, " | plots in ", dirs$plots)
