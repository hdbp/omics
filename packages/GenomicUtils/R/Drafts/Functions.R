if (interactive() && requireNamespace("tidyverse", quietly = TRUE)) {
  theme_custom <- function(
  title_size = 16, title_face = "bold",
  subtitle_size = 14, subtitle_face = "plain", subtitle_color = "red",
  axis_title_size = 12, axis_title_face = "bold",
  axis_text_size = 10, axis_text_face = "plain",
  legend_text_size = 10, legend_text_face = "plain",
  legend_title_size = 12, legend_title_face = "bold",
  grid_major = TRUE, grid_minor = FALSE
) {
  
  theme_minimal() +
    theme(
      axis.line = element_line(),
      axis.ticks = element_line(),
      
      plot.title = element_text(size = title_size, face = title_face),
      plot.subtitle = element_text(size = subtitle_size, face = subtitle_face, colour = subtitle_color),
      
      axis.title = element_text(size = axis_title_size, face = axis_title_face),
      axis.text = element_text(size = axis_text_size, face = axis_text_face),
      
      legend.text = element_text(size = legend_text_size, face = legend_text_face),
      legend.title = element_text(size = legend_title_size, face = legend_title_face),
      
      panel.grid.major = if(grid_major) element_line(color = "grey80") else element_blank(),
      panel.grid.minor = if(grid_minor) element_line(color = "grey90") else element_blank()
    )
}
}


if (interactive() && requireNamespace("tidyverse", quietly = TRUE)) {
  t <- theme_minimal() +
      theme(
      axis.line = element_line(),
      axis.ticks = element_line(),
      plot.title = element_text(size = 14, face = "bold"),
      plot.subtitle = element_text(colour = "red", face = "bold"),
      axis.title = element_text(face = "bold"),
      legend.text = element_text(face = "bold"),
      legend.title = element_text(face = "bold")
    )
}


# Function to calculate % GC
add_percent_gc <- function(gr, genome) {
  # Ensure inputs are of the correct type
  if (!inherits(gr, "GRanges")) stop("`gr` must be a GRanges object.")
  if (!inherits(genome, "BSgenome")) stop("`genome` must be a BSgenome object.")

  # Ensure seqlevels style match
  GenomeInfoDb::seqlevelsStyle(gr) <- GenomeInfoDb::seqlevelsStyle(genome)[1]

  # Extract DNA sequences for each genomic interval
  seqs <- Biostrings::getSeq(genome, gr)

  # Compute GC counts per sequence
  gc_counts <- Biostrings::letterFrequency(seqs, letters = c("G", "C"), as.prob = FALSE)

  # Get total width (length) of each sequence
  total_counts <- BiocGenerics::width(seqs)

  # Compute percent GC content
  percent_gc <- rowSums(gc_counts) / total_counts * 100

  # Add %GC to metadata columns
  mcols(gr)$percent_gc <- percent_gc

  return(gr)
}


# get_density() Function
get_density <- function(x, y, ...) {
  dens <- MASS::kde2d(x, y, ...)
  ix <- findInterval(x, dens$x)
  iy <- findInterval(y, dens$y)
  ii <- cbind(ix, iy)
  return(dens$z[ii])
}

find_peaks <- function(x, m = 3) {
  shape <- diff(sign(diff(x, na.pad = FALSE)))
  pks <- sapply(which(shape < 0), FUN = function(i) {
    z <- i - m + 1
    z <- ifelse(z > 0, z, 1)
    w <- i + m + 1
    w <- ifelse(w < length(x), w, length(x))
    if (all(x[c(z:i, (i + 2):w)] <= x[i + 1])) {
      return(i + 1)
    } else {
      return(numeric(0))
    }
  })
  unlist(pks)
}

