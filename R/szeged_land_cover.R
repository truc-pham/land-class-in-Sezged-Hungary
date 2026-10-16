# =============================================================================
# Land cover of Szeged, Hungary, from ESA WorldCover 10 m (2021, v200)
#
# Author: Truc Pham
#
# 1. City boundary  : official administrative boundary from OpenStreetMap
#                     (admin_level 8), cached in data/szeged_boundary.gpkg
# 2. Land cover     : ESA WorldCover 2021 v200 tile N45E018, read straight from
#                     the public AWS bucket (only the Szeged window is downloaded)
# 3. Area by class  : true cell areas (terra::cellSize), so no reprojection of
#                     the categorical raster is needed
# 4. Outputs        : map with locator inset, bar chart of class shares, CSV table
#
# Run from the project root: source("R/szeged_land_cover.R")
# =============================================================================

suppressPackageStartupMessages({
  library(terra)
  library(sf)
  library(ggplot2)
  library(patchwork)
})

dir.create("data/raw", recursive = TRUE, showWarnings = FALSE)
dir.create("outputs", showWarnings = FALSE)

# --- 1. City boundary ------------------------------------------------------------
boundary_file <- "data/szeged_boundary.gpkg"

if (!file.exists(boundary_file)) {
  # Needs internet once; the result is cached for later runs.
  if (!requireNamespace("osmdata", quietly = TRUE)) install.packages("osmdata")
  szeged <- osmdata::getbb("Szeged, Csongrád-Csanád, Hungary", format_out = "sf_polygon")
  if (!inherits(szeged, "sf")) {   # a list of polygon / multipolygon results
    szeged <- if (!is.null(szeged$multipolygon)) szeged$multipolygon else szeged$polygon
  }
  szeged <- st_make_valid(st_union(szeged))
  st_write(st_sf(name = "Szeged", geometry = szeged), boundary_file, quiet = TRUE)
}
boundary <- st_read(boundary_file, quiet = TRUE) |> st_transform(4326)

# --- 2. ESA WorldCover tile --------------------------------------------------------
# Tiles are 3 x 3 degrees, named after their south-west corner.
# Szeged (46.25 N, 20.15 E) lies in tile N45E018.
tile_name  <- "ESA_WorldCover_10m_2021_v200_N45E018_Map.tif"
local_tile <- file.path("data/raw", tile_name)
remote     <- paste0("/vsicurl/https://esa-worldcover.s3.eu-central-1.amazonaws.com/",
                     "v200/2021/map/", tile_name)

src <- if (file.exists(local_tile)) local_tile else remote
lc  <- rast(src)
lc  <- crop(lc, vect(boundary), snap = "out")
lc  <- mask(lc, vect(boundary))
names(lc) <- "class"
writeRaster(lc, "outputs/szeged_worldcover_2021.tif", overwrite = TRUE,
            datatype = "INT1U", gdal = "COMPRESS=DEFLATE")

# Official WorldCover legend (Product User Manual v2.0)
legend <- data.frame(
  class = c(10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 100),
  label = c("Tree cover", "Shrubland", "Grassland", "Cropland", "Built-up",
            "Bare / sparse vegetation", "Snow and ice", "Permanent water bodies",
            "Herbaceous wetland", "Mangroves", "Moss and lichen"),
  colour = c("#006400", "#ffbb22", "#ffff4c", "#f096ff", "#fa0000", "#b4b4b4",
             "#f0f0f0", "#0064c8", "#0096a0", "#00cf75", "#fae6a0"))

# --- 3. Area by class --------------------------------------------------------------
cell_km2 <- cellSize(lc, unit = "km", mask = TRUE)
area     <- zonal(cell_km2, lc, fun = "sum", na.rm = TRUE)
names(area) <- c("class", "area_km2")
area <- merge(area, legend, by = "class")
area$share_pct <- round(100 * area$area_km2 / sum(area$area_km2), 1)
area$area_km2  <- round(area$area_km2, 2)
area <- area[order(-area$area_km2), ]
write.csv(area[, c("class", "label", "area_km2", "share_pct")],
          "outputs/szeged_land_cover_by_class.csv", row.names = FALSE)
print(area[, c("label", "area_km2", "share_pct")], row.names = FALSE)

# --- 4. Figures --------------------------------------------------------------------
present <- legend[legend$class %in% area$class, ]
pal     <- setNames(present$colour, present$label)

# Plot at 20 m (modal) to keep the figure light; statistics above use 10 m.
lc_plot <- aggregate(lc, fact = 2, fun = "modal", na.rm = TRUE)
df <- as.data.frame(lc_plot, xy = TRUE, na.rm = TRUE)
df$label <- factor(legend$label[match(df$class, legend$class)], levels = present$label)

ink2 <- "#52514e"; muted <- "#898781"
caption_txt <- paste0("Land cover: ESA WorldCover 10 m 2021 v200 (Zanaga et al., 2022), CC BY 4.0.\n",
                      "Boundary: (c) OpenStreetMap contributors (ODbL). Map: Truc Pham.")

main_map <- ggplot() +
  geom_raster(data = df, aes(x, y, fill = label)) +
  geom_sf(data = boundary, fill = NA, colour = "#0b0b0b", linewidth = 0.4) +
  scale_fill_manual(values = pal, name = NULL, drop = TRUE) +
  coord_sf(expand = FALSE) +
  labs(x = NULL, y = NULL) +
  theme_minimal(base_size = 10) +
  theme(panel.grid = element_blank(), axis.text = element_text(colour = muted),
        legend.position = "none")

hungary <- rnaturalearthdata::countries50
hungary <- hungary[hungary$admin == "Hungary", ]
inset <- ggplot() +
  geom_sf(data = hungary, fill = "#f0efec", colour = "#898781", linewidth = 0.3) +
  geom_sf(data = st_centroid(boundary), colour = "#d03b3b", size = 2) +
  theme_void() +
  theme(panel.border = element_rect(fill = NA, colour = "#c3c2b7"))

area$label_f <- factor(area$label, levels = rev(area$label))
bars <- ggplot(area, aes(share_pct, label_f, fill = label)) +
  geom_col(width = 0.7, show.legend = FALSE) +
  geom_text(aes(label = sprintf("%.1f%%", share_pct)), hjust = -0.15, size = 3,
            colour = ink2) +
  scale_fill_manual(values = pal) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.25))) +
  labs(x = "Share of city area", y = NULL) +
  theme_minimal(base_size = 10) +
  theme(panel.grid = element_blank(), axis.text.x = element_blank(),
        axis.text.y = element_text(colour = ink2), axis.title.x = element_text(colour = muted))

total_km2 <- sum(area$area_km2)
inset <- inset + labs(title = "Location in Hungary") +
  theme(plot.title = element_text(size = 9, colour = muted, hjust = 0.5))
fig <- main_map + bars + inset +
  plot_layout(design = "AB\nAC", widths = c(2.2, 1), heights = c(1.4, 1)) +
  plot_annotation(
    title = "Land cover of Szeged, Hungary (2021)",
    subtitle = sprintf("ESA WorldCover at 10 m resolution within the city boundary (%.0f km2)",
                       total_km2),
    caption = caption_txt,
    theme = theme(plot.title = element_text(face = "bold", size = 14),
                  plot.subtitle = element_text(colour = ink2),
                  plot.caption = element_text(colour = muted, hjust = 0),
                  plot.background = element_rect(fill = "#fcfcfb", colour = NA)))

ggsave("outputs/szeged_land_cover_map.png", fig, width = 12, height = 7, dpi = 250,
       bg = "#fcfcfb")
message("Done. Outputs written to outputs/.")
