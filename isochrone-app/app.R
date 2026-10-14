# ---------------------------------------------------------------------------
# Isochrone Accessibility Mapping
# Author: Madeline LeBreton
#
# A tool for architects to generate walking/cycling/driving isochrones, overlay
# OSM amenities, and export as a QGIS-ready .gpkg
#
# Needs a free OpenRouteService API key: https://openrouteservice.org/dev/#/signup
# The CARTO basemap also needs a free API key: https://carto.com/basemaps/apikey
# ----------------------------------

library(shiny)
library(bslib)
library(leaflet)
library(sf)
library(httr)
library(jsonlite)
library(osmdata)
library(callr)

source("helpers.R")

ORS_API_KEY   <- Sys.getenv("ORS_API_KEY")
CARTO_API_KEY <- Sys.getenv("CARTO_API_KEY")

# For carto base maps
CARTO_TILE_URL <- paste0(
  "https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png?key=", CARTO_API_KEY
)
CARTO_ATTRIBUTION <- paste0(
  '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors ',
  '&copy; <a href="https://carto.com/attributions">CARTO</a>'
)

# ---------------------------------------------------------------------------
# User Interface
# ---------------------------------------------------------------------------
ui <- page_fillable(
  title = "Isochrone Accessibility Mapping",
  theme = bs_theme(version = 5, primary = "#2563eb", base_font = font_google("Inter")),
  padding = 0,
  fillable_mobile = TRUE,
  
  div(
    style = "padding: 8px 16px; border-bottom: 1px solid #e5e7eb; flex: 0 0 auto;",
    h5("Isochrone Accessibility Mapping", style = "margin: 0; font-weight: 600;")
  ),
  
  layout_sidebar(
    fillable = TRUE,
    sidebar = sidebar(
      width = 360,
      open = TRUE,
      
      tags$p("1. Set an origin", class = "fw-bold mb-1"),
      tags$p("Click anywhere on the map, or search an address:", class = "text-muted small mb-1"),
      div(
        style = "display: flex; gap: 6px; align-items: flex-end;",
        div(style = "flex: 1;",
            textInput("address", NULL, placeholder = "e.g. Praza do Obradoiro, Santiago")),
        actionButton("geocode_btn", "Search")
      ),
      
      hr(),
      tags$p("2. Isochrone times (minutes)", class = "fw-bold mb-1"),
      textInput("iso_times", NULL, value = "5, 10, 15",
                placeholder = "comma-separated, e.g. 5, 10, 15"),
      
      hr(),
      tags$p("3. Travel mode(s)", class = "fw-bold mb-1"),
      checkboxGroupInput(
        "modes", NULL,
        choices = c("Walking" = "foot-walking", "Cycling" = "cycling-regular", "Driving" = "driving-car"),
        selected = "foot-walking"
      ),
      
      hr(),
      tags$p("4. Amenities to map", class = "fw-bold mb-1"),
      tags$p(
        class = "text-muted small",
        "If the amenity lookup fails (the public Overpass server can be slow), try: ",
        tags$a("Overpass tool", href = "https://overpass-turbo.eu/", target = "_blank")
      ),
      
      selectizeInput(
        "amenity_tags", NULL,
        choices = AMENITY_PRESETS, multiple = TRUE,
        options = list(create = TRUE, placeholder = "Pick presets, or type any key=value")
      ),
      tags$p(
        class = "text-muted small",
        "Custom entries use OSM tagging, e.g. amenity=veterinary. Full list: ",
        tags$a("OSM Map Features", href = "https://wiki.openstreetmap.org/wiki/Map_features", target = "_blank")
      ),
      checkboxInput("only_named", "Show only named amenities (fewer duplicates)", value = TRUE),
      checkboxInput("show_labels", "Show amenity names on map", value = FALSE),
      
      hr(),
      actionButton("run_btn", "Generate map", class = "btn-primary w-100"),
      div(style = "height: 8px;"),
      conditionalPanel(
        condition = "output.has_results == true",
        downloadButton("download_gpkg", "Download .gpkg", class = "w-100")
      )
    ),
    
    leafletOutput("map", height = "100%")
  )
)

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------
server <- function(input, output, session) {
  
  origin       <- reactiveVal(NULL) # data.frame(lon, lat)
  iso_data     <- reactiveVal(NULL) # sf: isochrone polygons, all modes/times
  amenity_data <- reactiveVal(NULL) # sf: amenities with *_min reachability columns
  
  current_iso_groups     <- reactiveVal(character(0)) # map layer-control group names, one per mode
  current_amenity_groups <- reactiveVal(character(0)) # map layer-control group names, one per OSM tag
  
  output$map <- renderLeaflet({
    base <- leaflet()
    
    if (nzchar(CARTO_API_KEY)) {
      base <- base |> addTiles(
        urlTemplate = CARTO_TILE_URL,
        attribution = CARTO_ATTRIBUTION,
        options = tileOptions(maxZoom = 20)
      )
    } else {
      # No CARTO key set: fall back to standard OSM tiles (fine for light use)
      base <- base |> addTiles()
    }
    
    base |> setView(lng = -8.544, lat = 42.881, zoom = 12)  # default: Galicia
  })
  
  if (!nzchar(CARTO_API_KEY)) {
    showNotification(
      "CARTO_API_KEY is not set, so the app is using the standard OpenStreetMap basemap.",
      type = "message", duration = 8
    )
  }
  
  # Set origin: click on map 
  observeEvent(input$map_click, {
    click <- input$map_click
    origin(data.frame(lon = click$lng, lat = click$lat))
    leafletProxy("map") |>
      clearGroup("origin") |>
      addMarkers(lng = click$lng, lat = click$lat, group = "origin")
  })
  
  # Set origin: address search (Nominatim) 
  observeEvent(input$geocode_btn, {
    req(input$address)
    loc <- geocode_address(input$address)
    if (is.null(loc)) {
      showNotification("Address not found — try a more specific search.", type = "warning")
      return()
    }
    origin(data.frame(lon = loc$lon, lat = loc$lat))
    leafletProxy("map") |>
      clearGroup("origin") |>
      addMarkers(lng = loc$lon, lat = loc$lat, group = "origin", popup = loc$display_name) |>
      setView(lng = loc$lon, lat = loc$lat, zoom = 15)
  })
  
  # Generate isochrones + amenities 
  observeEvent(input$run_btn, {
    org <- origin()
    if (is.null(org)) {
      showNotification("Set an origin first: click the map or search an address.", type = "warning")
      return()
    }
    
    times_min <- parse_times(input$iso_times)
    if (length(times_min) == 0) {
      showNotification("Enter at least one valid isochrone time, e.g. 5, 10, 15.", type = "warning")
      return()
    }
    
    if (length(input$modes) == 0) {
      showNotification("Select at least one travel mode.", type = "warning")
      return()
    }
    
    api_key <- ORS_API_KEY
    if (identical(api_key, "")) {
      showNotification(
        "Missing ORS_API_KEY environment variable. See the Setup section of README.md.",
        type = "error", duration = NULL
      )
      return()
    }
    
    withProgress(message = "Generating isochrones...", value = 0, {
      n <- length(input$modes)
      iso_list <- vector("list", n)
      for (i in seq_len(n)) {
        incProgress(1 / n, detail = MODE_LABELS[[input$modes[i]]])
        iso_list[[i]] <- tryCatch(
          get_isochrone(org$lon, org$lat, times_min, input$modes[i], api_key),
          error = function(e) {
            showNotification(conditionMessage(e), type = "error", duration = 8)
            NULL
          }
        )
      }
      iso_list <- iso_list[!vapply(iso_list, is.null, logical(1))]
      
      if (length(iso_list) == 0) {
        iso_data(NULL)
        amenity_data(NULL)
        return()
      }
      
      iso_data(do.call(rbind, iso_list))
    })
    
    if (is.null(iso_data())) return()
    
    if (length(input$amenity_tags) > 0) {
      withProgress(message = "Fetching amenities from OpenStreetMap...", value = 0.3, {
        bbox <- sf::st_bbox(iso_data())
        warning_msgs <- character(0)
        am <- withCallingHandlers(
          tryCatch(
            fetch_amenities(
              bbox, input$amenity_tags, timeout_sec = 30,
              on_tag = function(tag, i, n) incProgress(0.6 / n, detail = tag)
            ),
            error = function(e) {
              showNotification(conditionMessage(e), type = "error")
              NULL
            }
          ),
          warning = function(w) {
            warning_msgs[[length(warning_msgs) + 1]] <<- conditionMessage(w)
            invokeRestart("muffleWarning")
          }
        )
        
        for (msg in warning_msgs) {
          showNotification(msg, type = "warning", duration = 10)
        }
        
        if (!is.null(am) && nrow(am) > 0) {
          am <- tryCatch({
            am <- sf::st_transform(am, sf::st_crs(iso_data()))
            am <- assign_time_bands(am, iso_data())
            reach_cols <- grep("_min$", names(am), value = TRUE)
            if (length(reach_cols) == 0) {
              am[0, ]
            } else {
              keep <- apply(sf::st_drop_geometry(am)[, reach_cols, drop = FALSE], 1,
                            function(x) any(!is.na(x)))
              am[keep, ]
            }
          }, error = function(e) {
            showNotification(
              paste("Error processing amenities:", conditionMessage(e)),
              type = "error", duration = 10
            )
            NULL
          })
        }
        
        amenity_data(if (is.null(am) || nrow(am) == 0) NULL else am)
      })
      
      if (is.null(amenity_data())) {
        showNotification("No amenities of the selected type(s) were found within the isochrones.", type = "message")
      }
    } else {
      amenity_data(NULL)
    }
  })
  
  # Draw isochrones (colored by mode, faded by time) 
  # Each mode gets its own map layer group so it can be toggled on/off 
  observeEvent(iso_data(), {
    iso <- iso_data()
    proxy <- leafletProxy("map")
    
    old_groups <- current_iso_groups()
    if (length(old_groups) > 0) proxy <- proxy |> clearGroup(old_groups)
    proxy <- proxy |> removeControl("legend")
    
    if (is.null(iso)) {
      current_iso_groups(character(0))
      return()
    }
    
    modes_present <- unique(iso$profile)
    new_groups <- paste0("Isochrones: ", MODE_LABELS[modes_present])
    
    for (idx in seq_along(modes_present)) {
      m   <- modes_present[idx]
      grp <- new_groups[idx]
      iso_m <- iso[iso$profile == m, ]
      iso_m <- iso_m[order(-iso_m$time_min), ]  # draw largest ring first, smallest on top
      max_t <- max(iso_m$time_min)
      for (i in seq_len(nrow(iso_m))) {
        fill_op <- 0.12 + 0.35 * (1 - iso_m$time_min[i] / max_t)
        proxy <- proxy |> addPolygons(
          data = iso_m[i, ],
          fillColor = MODE_COLORS[[m]], fillOpacity = fill_op,
          color = MODE_COLORS[[m]], weight = 1, opacity = 0.8,
          group = grp,
          label = sprintf("%s: %g min", MODE_LABELS[[m]], iso_m$time_min[i])
        )
      }
    }
    
    proxy |> addLegend(
      position = "bottomright", layerId = "legend",
      colors = unname(MODE_COLORS[modes_present]),
      labels = unname(MODE_LABELS[modes_present]),
      title = "Travel mode", opacity = 0.9
    )
    
    current_iso_groups(new_groups)
    
    bb <- sf::st_bbox(iso)
    proxy |> fitBounds(bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]])
  })
  
  # Draw amenities (loads on new data OR when toggles change, no need to redo query)
  # Each OSM tag gets its own map layer group so individual tags can be toggled
  observe({
    am_all <- amenity_data()
    proxy <- leafletProxy("map")
    
    old_groups <- current_amenity_groups()
    if (length(old_groups) > 0) proxy <- proxy |> clearGroup(old_groups)
    
    if (is.null(am_all) || nrow(am_all) == 0) {
      current_amenity_groups(character(0))
      return()
    }
    
    am <- am_all
    if (isTRUE(input$only_named)) {
      am <- am[am$name != "(unnamed)", ]
    }
    if (nrow(am) == 0) {
      current_amenity_groups(character(0))
      return()
    }
    
    tryCatch({
      # Colours use the unfiltered data so colors don't change
      pal <- leaflet::colorFactor("Set2", domain = unique(am_all$osm_tag))
      
      label_opts <- if (isTRUE(input$show_labels)) {
        leaflet::labelOptions(
          noHide = TRUE, direction = "top", textOnly = TRUE,
          style = list("font-size" = "11px", "background" = "rgba(255,255,255,0.85)",
                       "border-radius" = "3px", "padding" = "1px 4px")
        )
      } else {
        leaflet::labelOptions(noHide = FALSE)
      }
      
      tags_present <- unique(am$osm_tag)
      new_groups <- tag_group_label(tags_present)
      
      for (idx in seq_along(tags_present)) {
        tag    <- tags_present[idx]
        grp    <- new_groups[idx]
        am_tag <- am[am$osm_tag == tag, ]
        
        proxy <- proxy |> addCircleMarkers(
          data = am_tag, radius = 5, weight = 1, color = "#1f2937",
          fillColor = pal(tag), fillOpacity = 0.9,
          group = grp,
          label = ~name,
          labelOptions = label_opts,
          popup = ~paste0("<b>", name, "</b><br>", osm_tag)
        )
      }
      
      current_amenity_groups(new_groups)
    }, error = function(e) {
      showNotification(paste("Error drawing amenities:", conditionMessage(e)), type = "error", duration = 10)
      current_amenity_groups(character(0))
    })
  })
  
  # Keep the map layer control in sync with current groups
  observe({
    tryCatch({
      all_groups <- c(current_iso_groups(), current_amenity_groups())
      proxy <- leafletProxy("map") |> removeLayersControl()
      if (length(all_groups) > 0) {
        proxy |> addLayersControl(
          overlayGroups = all_groups,
          options = layersControlOptions(collapsed = FALSE)
        )
      }
    }, error = function(e) {
      showNotification(paste("Error updating layer control:", conditionMessage(e)), type = "error", duration = 10)
    })
  })
  
  # Drives conditional panel: only show download once results exist
  output$has_results <- reactive({
    !is.null(iso_data())
  })
  outputOptions(output, "has_results", suspendWhenHidden = FALSE)
  
  # Download .gpkg (isochrones + amenities + origin point as layers)
  output$download_gpkg <- downloadHandler(
    filename = function() paste0("isochrone_accessibility_", format(Sys.time(), "%Y%m%d_%H%M"), ".gpkg"),
    content = function(file) {
      iso <- iso_data()
      req(iso)
      
      # reverse order for QGIS
      iso <- iso[order(iso$profile, -iso$time_min), ]
      
      sf::st_write(iso, file, layer = "isochrones", delete_dsn = TRUE, quiet = TRUE)
      
      am <- amenity_data()
      if (isTRUE(input$only_named) && !is.null(am)) {
        am <- am[am$name != "(unnamed)", ]
      }
      if (!is.null(am) && nrow(am) > 0) {
        sf::st_write(am, file, layer = "amenities", append = FALSE, quiet = TRUE)
      }
      
      org <- origin()
      if (!is.null(org)) {
        org_sf <- sf::st_as_sf(org, coords = c("lon", "lat"), crs = 4326)
        sf::st_write(org_sf, file, layer = "origin_point", append = FALSE, quiet = TRUE)
      }
    }
  )
}

shinyApp(ui, server)