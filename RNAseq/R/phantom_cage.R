if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

library(tidyverse)
library(curl)
library(AnnotationDbi)
library(TxDb.Mmusculus.UCSC.mm9.knownGene)
library(org.Mm.eg.db)

# Download Phantom5 mouse CAGE data for analysis of H1 expression in multiple cell types
dir.create('../Data/', recursive = TRUE, showWarnings = FALSE)
dir.create('../results/plots/', recursive = TRUE, showWarnings = FALSE)

url <- 'https://fantom.gsc.riken.jp/5/datafiles/latest/extra/gene_level_expression/mm9.gene_phase1and2combined_tpm.osc.txt.gz'
dest <- '../Data/phantom_cage.txt.gz'
curl::curl_download(url, dest)

# # Import CAGE Data
# cage <- read_delim(
#   file = "../Data/phantom_cage.txt.gz",
#   delim = "\t",
#   num_threads = 24,
#   progress = TRUE,
#   col_names = FALSE,
#   escape_backslash = TRUE,
#   show_col_types = FALSE
# )

genes <- genes(TxDb.Mmusculus.UCSC.mm9.knownGene)
genes$symbol <- AnnotationDbi::select(org.Mm.eg.db,keys = genes$gene_id,columns = "SYMBOL",keytype = 'ENTREZID')$SYMBOL

histones <- genes[grepl('H1f.',genes$symbol,ignore.case = T)]
print(histones)
idx <- mcols(histones)
print(idx)

# Import CAGE Data
Sys.setenv("VROOM_CONNECTION_SIZE" = 131072 * 100)

counts <- read_delim(
file = "../Data/phantom_cage.txt.gz",
delim = "\t",
progress = TRUE,
col_names = T,
escape_backslash = TRUE,
show_col_types = FALSE,skip = 1076 )

colnames(counts) <- URLdecode(colnames(counts))

counts <- counts %>% dplyr::rename('symbol'=`00Annotation`)

# Subset H1 from CAGE Data
h1_pattern <- paste('hist1h1','h1f',sep = '|')
h1_counts <- counts[grepl(pattern = h1_pattern,x = counts$symbol,ignore.case = T),]

# Total H1 Expression across subtypes
h1_total_exp <- h1_counts %>%
  summarise(across(-symbol, ~ sum(.x, na.rm = TRUE))
)
# Convert each subtype as a % of total H1
h1_percent <- h1_counts %>%
  mutate(
    across(
      -symbol,
      ~ .x / h1_total_exp[[cur_column()]] * 100
    )
)
# Number of H1 subtypes that are expressed at higher than 5% of total H1
n_exp_h1 <- h1_percent %>%
   summarise(across(where(is.numeric), ~ sum(.x > 5, na.rm = TRUE)))
n_exp_h1 <- n_exp_h1 %>% pivot_longer(.,everything(),names_to = 'sample',values_to = 'exp_h1')


# How much H1c,d and e are of total H1
h1cde <- paste('Hist1h1c','Hist1H1d','Hist1H1e',sep = '|')
h1cde_exp <- h1_percent[grepl(pattern = h1cde,x = h1_counts$symbol,ignore.case = T),] %>%
  summarise(
    across(
       -symbol,
        ~ sum(.x, na.rm = TRUE)
      )
)

# Prepare table for plotting and illustrate how dominant H1cde expression is in each cell type

perc_h1cde <- h1cde_exp %>% pivot_longer(.,everything(),names_to = 'sample',values_to = 'perc_h1cde')

perc_h1cde <- inner_join(perc_h1cde,n_exp_h1,by = 'sample')

perc_h1cde <- perc_h1cde %>%
  mutate(
  cell_type = case_when(
    #str_detect(sample, regex("regulatory T cells", ignore_case = TRUE)) ~ "T Cells",
    str_detect(sample, regex("naive conventional T cells", ignore_case = TRUE)) ~ "T Cells",
    str_detect(sample, regex("T Cells", ignore_case = TRUE)) ~ "T Cells",
    #str_detect(sample, regex("CD8", ignore_case = TRUE)) ~ "T Cells",
    str_detect(sample, regex("B Cells", ignore_case = TRUE)) ~ "B Cells",
    str_detect(sample, regex("hematopoietic stem cell", ignore_case = TRUE)) ~ "HSC",
    str_detect(sample, regex("CMP", ignore_case = TRUE)) ~ "CMP",
    str_detect(sample, regex("GMP", ignore_case = TRUE)) ~ "GMP",
    str_detect(sample, regex("megakaryocyte", ignore_case = TRUE)) ~ "Megakaryocyte",
    str_detect(sample, regex("embryonic stem cells", ignore_case = TRUE)) ~ "ESC",
    str_detect(sample, regex("myeloid", ignore_case = TRUE)) ~ "Myeloid",
    TRUE ~ "Other"
    ),
  plot_cell_type = case_when(
    cell_type %in% c("T Cells", "B Cells", "Myeloid") ~ cell_type,
    TRUE ~ "Other"
    )
  )

ggplot(perc_h1cde, aes(y = exp_h1, x = perc_h1cde)) +
  geom_jitter(
    data = perc_h1cde %>% filter(plot_cell_type == "Other"),
    color = "gray70",
    width = 0.15,
    height = 0.35,
    alpha = 0.25,
    size = 1
  ) +
  geom_jitter(
    data = perc_h1cde %>% filter(plot_cell_type != "Other"),
    aes(color = plot_cell_type),
    width = 0.15,
    height = 0.35,
    alpha = 0.85,
    size = 2
  ) +
  #geom_smooth(method = "lm", se = FALSE, linewidth = 0.5) +
  labs(
    y = "Number of expressed H1 genes",
    x = "H1c/d/e expression (% of total H1)",
    color = "Cell type",
    title = "H1c/d/e expression as a function of expressed H1 genes"
  ) +
  xlim(50, 100)+
  scale_y_continuous(breaks = seq(0,10,by = 1))+
  scale_color_manual(
    values = c(
      "T Cells" = "#1b9e77",
      "B Cells" = "#d95f02",
      "Myeloid" = "#7570b3"
    )
  ) +
  theme_bw()

ggsave(
  filename = "../results/plots/perc_h1cde_vs_exp_h1_cell_type_colors.pdf",
  width = 10,
  height = 7
)

ggplot(perc_h1cde, aes(x = fct_reorder(cell_type, perc_h1cde, .fun = median, na.rm = TRUE), y = perc_h1cde, fill = cell_type)) +
  geom_violin(trim = FALSE, alpha = 0.7, color = "gray30") +
  geom_jitter(width = 0.12, alpha = 0.5, size = 0.8) +
  stat_summary(
    fun = median,
    geom = "crossbar",
    width = 0.45,
    linewidth = 0.5,
    color = "black"
  ) +
  labs(
    x = "Cell type",
    y = "H1c/d/e expression (% of total H1)",
    fill = "Cell type",
    title = "Distribution of H1c/d/e percentage by cell type"
  ) +
  coord_cartesian(ylim = c(50, 100)) +
  theme_bw() +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    legend.position = "none"
  )

ggsave(
  filename = "../results/plots/perc_h1cde_violin_by_cell_type.pdf",
  width = 10,
  height = 7
)
