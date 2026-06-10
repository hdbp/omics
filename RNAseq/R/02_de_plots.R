if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(ggplot2)
library(ggrepel)
library(patchwork)

source("helper_functions/functions.R")

res_list <- readRDS(file.path(dirs$data, "res_list.rds"))

# ── MA panel ──────────────────────────────────────────────────────────────────
ma_panel <- wrap_plots(
  lapply(names(res_list), function(ct) make_ma(res_list[[ct]], ct)),
  ncol = length(res_list)
) + plot_annotation(
  title = "MA plots — cTKO vs WT",
  theme = theme(plot.title = element_text(face = "bold", hjust = 0.5))
)
ggsave(file.path(dirs$plots, "cTKO_RNAseq_MA_panel.pdf"), ma_panel, width = 12, height = 4)

# ── Volcano panel ─────────────────────────────────────────────────────────────
volcano_panel <- wrap_plots(
  lapply(names(res_list), function(ct) make_volcano(res_list[[ct]], ct)),
  ncol = length(res_list)
) + plot_annotation(
  title = "Volcano plots — cTKO vs WT",
  theme = theme(plot.title = element_text(face = "bold", hjust = 0.5))
)
ggsave(file.path(dirs$plots, "cTKO_RNAseq_volcano_panel.pdf"), volcano_panel, width = 12, height = 4)

message("Plots saved to ", dirs$plots)
