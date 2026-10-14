# ---------------------------------------------------------------------------
# helpers.R
# Author: Madeline LeBreton
# Core logic for Accessibility Mapping
# - geocode_address(): Nominatim (OSM) address search
# - parse_times(): parse the text input into minutes
# - clamp_times_for_profile(): enforce ORS max time limit per travel mode
# - get_isochrone(): OpenRouteService isochrones call -> sf polygons
# - fetch_amenities(): Overpass (via osmdata) query for selected OSM tags
# - assign_time_bands(): tag each amenity with fastest reachable time
# ---------------------------------------------------------------------------

# Intuitive labels for ORS profile codes 
MODE_LABELS <- c(
  "foot-walking"    = "Walking",
  "cycling-regular" = "Cycling",
  "driving-car"     = "Driving"
)

# Short codes used for gpkg / data-frame column names (e.g. "walk_min")
MODE_SHORT <- c(
  "foot-walking"    = "walk",
  "cycling-regular" = "bike",
  "driving-car"     = "drive"
)

# Colors used consistently for each mode across polygons, legend, and markers
MODE_COLORS <- c(
  "foot-walking"    = "#2563eb",  # blue
  "cycling-regular" = "#16a34a",  # green
  "driving-car"     = "#ea580c"   # orange
)

# ORS's documented maximum isochrone range time per profile (minutes)
# See: https://openrouteservice.org/restrictions/
MODE_MAX_MINUTES <- c(
  "foot-walking"    = 20 * 60,
  "cycling-regular" = 5 * 60,
  "driving-car"     = 60
)

# List of common OSM key=value pairs (see full list at
# https://wiki.openstreetmap.org/wiki/Map_features). Shown as presets in the
# amenity picker; users can also type any other key=value pair directly.
AMENITY_PRESETS <- c(
  "School"            = "amenity=school",
  "Kindergarten"      = "amenity=kindergarten",
  "Hospital"          = "amenity=hospital",
  "Clinic"            = "amenity=clinic",
  "Pharmacy"          = "amenity=pharmacy",
  "Restaurant"        = "amenity=restaurant",
  "Cafe"              = "amenity=cafe",
  "Bank"              = "amenity=bank",
  "Place of worship"  = "amenity=place_of_worship",
  "Community centre"  = "amenity=community_centre",
  "Supermarket"       = "shop=supermarket",
  "Convenience store" = "shop=convenience",
  "Bakery"            = "shop=bakery",
  "Park"              = "leisure=park",
  "Sports centre"     = "leisure=sports_centre",
  "Playground"        = "leisure=playground",
  "Hotel"             = "tourism=hotel",
  "Bus stop"          = "highway=bus_stop",
  "Train station"     = "railway=station",
  "Bicycle parking"   = "amenity=bicycle_parking"
)

# ---------------------------------------------------------------------------
# geocode_address(): free-text address -> lon/lat via OSM Nominatim
# Nominatim requires a descriptive User-Agent 
# https://operations.osmfoundation.org/policies/nominatim/
# ---------------------------------------------------------------------------
geocode_address <- function(address) {
  if (is.null(address) || trimws(address) == "") return(NULL)
  
  res <- tryCatch(
    httr::GET(
      url = "https://nominatim.openstreetmap.org/search",
      query = list(q = address, format = "json", limit = 1),
      httr::add_headers(
        `User-Agent` = "isochrone-accessibility-app/1.0 (https://github.com/madelinelebreton/isochrone-accessibility-app)"
      ),
      httr::timeout(10)
    ),
    error = function(e) NULL
  )
  
  if (is.null(res) || httr::status_code(res) != 200) return(NULL)
  
  parsed <- jsonlite::fromJSON(httr::content(res, as = "text", encoding = "UTF-8"))
  if (length(parsed) == 0 || is.null(nrow(parsed)) || nrow(parsed) == 0) return(NULL)
  
  list(
    lon = as.numeric(parsed$lon[1]),
    lat = as.numeric(parsed$lat[1]),
    display_name = parsed$display_name[1]
  )
}

# ---------------------------------------------------------------------------
# parse_times(): "5, 10, 15" -> c(5, 10, 15)
# Cleans and caps at 10 values (ORS's max intervals
# per isochrone request).
# ---------------------------------------------------------------------------
parse_times <- function(x) {
  if (is.null(x) || trimws(x) == "") return(numeric(0))
  vals <- suppressWarnings(as.numeric(trimws(strsplit(x, ",")[[1]])))
  vals <- vals[!is.na(vals) & vals > 0]
  vals <- sort(unique(round(vals)))
  if (length(vals) > 10) vals <- vals[1:10]
  vals
}

# ---------------------------------------------------------------------------
# clamp_times_for_profile(): drop time values above ORS's max
# ---------------------------------------------------------------------------
clamp_times_for_profile <- function(times_min, profile) {
  max_min <- MODE_MAX_MINUTES[[profile]]
  keep <- times_min <= max_min
  if (any(!keep)) {
    warning(sprintf(
      "%s: dropped times above the %d-minute limit for this mode.",
      MODE_LABELS[[profile]], max_min
    ))
  }
  times_min[keep]
}

# ---------------------------------------------------------------------------
# get_isochrone(): call OpenRouteService and return an sf polygon layer
# https://giscience.github.io/openrouteservice/api-reference/endpoints/isochrones/
# ---------------------------------------------------------------------------
get_isochrone <- function(lon, lat, times_min, profile, api_key) {
  times_min <- clamp_times_for_profile(times_min, profile)
  if (length(times_min) == 0) {
    stop(sprintf("No valid isochrone times remain for %s.", MODE_LABELS[[profile]]))
  }
  times_sec <- round(times_min * 60)
  
  body <- list(
    locations   = list(c(lon, lat)),
    range       = I(as.numeric(times_sec)),
    range_type  = "time"
  )
  
  res <- httr::POST(
    url = paste0("https://api.openrouteservice.org/v2/isochrones/", profile),
    httr::add_headers(
      Authorization = api_key,
      `Content-Type` = "application/json; charset=utf-8"
    ),
    body = jsonlite::toJSON(body, auto_unbox = TRUE),
    encode = "raw",
    httr::timeout(30)
  )
  
  if (httr::status_code(res) != 200) {
    msg <- httr::content(res, as = "text", encoding = "UTF-8")
    stop(sprintf("ORS isochrone request failed for %s: %s", MODE_LABELS[[profile]], msg))
  }
  
  geojson_text <- httr::content(res, as = "text", encoding = "UTF-8")
  iso_sf <- sf::st_read(geojson_text, quiet = TRUE)
  
  iso_sf$time_min <- iso_sf$value / 60
  iso_sf$profile  <- profile
  iso_sf[, c("time_min", "profile")]
}

# ---------------------------------------------------------------------------
# .query_one_overpass_tag(): runs background process (see fetch_amenities
# below). Must be self-contained, no references to outside variables 
# since callr re-serializes it into a fresh R session.
# ---------------------------------------------------------------------------
.query_one_overpass_tag <- function(bbox, key, value, timeout_sec) {
  q <- osmdata::opq(bbox = bbox, timeout = max(5, timeout_sec - 5))
  q <- if (is.na(value)) {
    osmdata::add_osm_feature(q, key = key)
  } else {
    osmdata::add_osm_feature(q, key = key, value = value)
  }
  osmdata::osmdata_sf(q)
}

# ---------------------------------------------------------------------------
# fetch_amenities(): query Overpass (via osmdata) for each user-selected
# "key=value" tag within a bounding box, and return a combined sf point layer.
#
# Overloaded Overpass server would otherwise hang the whole app 
# ---------------------------------------------------------------------------
fetch_amenities <- function(bbox, tags, timeout_sec = 30, on_tag = NULL) {
  n <- length(tags)
  
  results <- lapply(seq_along(tags), function(i) {
    tag <- tags[i]
    if (!is.null(on_tag)) on_tag(tag, i, n)
    
    parts <- strsplit(tag, "=", fixed = TRUE)[[1]]
    key   <- trimws(parts[1])
    value <- if (length(parts) > 1) trimws(parts[2]) else NA_character_
    
    tryCatch({
      osm <- callr::r(
        .query_one_overpass_tag,
        args = list(bbox = bbox, key = key, value = value, timeout_sec = timeout_sec),
        timeout = timeout_sec
      )
      
      pts <- osm$osm_points
      
      # Buildings/parks sometimes come back as polygons; represent as a point
      if (!is.null(osm$osm_polygons) && nrow(osm$osm_polygons) > 0) {
        poly_pts <- suppressWarnings(
          sf::st_centroid(sf::st_make_valid(osm$osm_polygons))
        )
        pts <- if (!is.null(pts) && nrow(pts) > 0) {
          common <- intersect(names(pts), names(poly_pts))
          rbind(pts[, common], poly_pts[, common])
        } else {
          poly_pts
        }
      }
      
      if (is.null(pts) || nrow(pts) == 0) return(NULL)
      if (!"name" %in% names(pts)) pts$name <- NA_character_
      
      pts$name <- ifelse(is.na(pts$name) | pts$name == "", "(unnamed)", pts$name)
      pts$osm_tag <- tag
      sf::st_as_sf(as.data.frame(pts)[, c("name", "osm_tag", "geometry")])
    }, error = function(e) {
      msg <- if (inherits(e, "callr_timeout_error") ||
                 grepl("timed out|timeout", conditionMessage(e), ignore.case = TRUE)) {
        sprintf(
          "Timed out waiting for Overpass after %ds for '%s' -- the server may be slow/overloaded, or unreachable from this network.",
          timeout_sec, tag
        )
      } else {
        sprintf("No results for '%s' (%s)", tag, conditionMessage(e))
      }
      warning(msg)
      NULL
    })
  })
  
  results <- results[!vapply(results, is.null, logical(1))]
  if (length(results) == 0) return(NULL)
  do.call(rbind, results)
}

# ---------------------------------------------------------------------------
# assign_time_bands(): for each amenity point, find smallest isochrone
# separately per travel mode. 
# ---------------------------------------------------------------------------
assign_time_bands <- function(amenities_sf, isochrones_sf) {
  modes <- unique(isochrones_sf$profile)
  
  for (m in modes) {
    iso_m <- isochrones_sf[isochrones_sf$profile == m, ]
    iso_m <- iso_m[order(iso_m$time_min), ]
    
    min_time <- rep(NA_real_, nrow(amenities_sf))
    for (i in seq_len(nrow(iso_m))) {
      inside <- lengths(sf::st_within(amenities_sf, iso_m[i, ])) > 0
      needs_update <- inside & is.na(min_time)
      min_time[needs_update] <- iso_m$time_min[i]
    }
    
    amenities_sf[[paste0(MODE_SHORT[[m]], "_min")]] <- min_time
  }
  
  amenities_sf
}

# ---------------------------------------------------------------------------
# tag_group_label(): map an OSM "key=value" tag to a label group name
# ---------------------------------------------------------------------------
tag_group_label <- function(tags) {
  preset_lookup <- setNames(names(AMENITY_PRESETS), AMENITY_PRESETS)
  labels <- unname(preset_lookup[tags])
  ifelse(is.na(labels), tags, labels)
}
