# Isochrone Accessibility App

An interactive R Shiny tool that answers a simple spatial question for non-GIS users: **what can people reach from here in 5, 10, 15 minutes, on foot, by bike or by car?**

Click a point on the map (or search an address), pick travel modes and OpenStreetMap amenities, and the app draws travel-time isochrones, overlays the amenities that fall inside them, and exports everything as a **QGIS-ready GeoPackage**.

I built it during my internship at Fundación RIA (Casa RIA, Santiago de Compostela) so that architects could run accessibility analyses for site and exhibition research without writing code or opening a GIS.

<!--
SCREENSHOTS: add images to docs/images/ and uncomment the lines below.

![Walking isochrones and amenities around Praza do Obradoiro](docs/images/overview.png)
![Multi-mode comparison with layer control](docs/images/multi-mode.png)
-->

## Features

- **Two ways to set an origin:** click the map or geocode an address (OpenStreetMap Nominatim).
- **Isochrones for walking, cycling and driving**, computed with the [OpenRouteService](https://openrouteservice.org) API. Choose any combination of modes and up to 10 time thresholds (e.g. `5, 10, 15` minutes). Requests are checked against ORS's per-mode range limits.
- **Amenity overlay from OpenStreetMap:** 20 presets (schools, pharmacies, supermarkets, parks, bus stops, …) or any custom `key=value` OSM tag such as `amenity=veterinary`. Polygon features (e.g. parks) are reduced to centroids.
- **Reachability attribute per amenity:** each amenity is tagged with the smallest time band that contains it, per mode (`walk_min`, `bike_min`, `drive_min`). Amenities outside every isochrone are dropped.
- **Readable map:** one colour per mode, ring opacity scaled by travel time, a layer control to toggle each mode and each amenity type, optional name labels, and a "named amenities only" filter to cut duplicates.
- **Robust to a flaky public server:** each Overpass query runs in its own background R process with a timeout (via `callr`), so a slow or overloaded Overpass server produces a warning instead of freezing the app.
- **One-click export:** a single `.gpkg` with `isochrones`, `amenities` and `origin_point` layers, ready to drop into QGIS.

## How it works

```mermaid
flowchart LR
    A[Click map / search address<br/>Nominatim] --> B[Origin point]
    B --> C[Isochrone polygons per mode<br/>OpenRouteService API]
    C --> D[Bounding box of isochrones]
    D --> E[Amenities per OSM tag<br/>Overpass via osmdata + callr]
    C --> F[Spatial join: smallest time band<br/>containing each amenity]
    E --> F
    F --> G[Leaflet map with layer control]
    F --> H[GeoPackage export for QGIS]
```

| File | Role |
|---|---|
| [`app/app.R`](app/app.R) | Shiny UI (bslib sidebar layout) and reactive server logic: origin, isochrone and amenity state, map drawing, layer control, export. |
| [`app/helpers.R`](app/helpers.R) | Core logic, kept separate from the UI: `geocode_address()`, `parse_times()`, `clamp_times_for_profile()`, `get_isochrone()`, `fetch_amenities()`, `assign_time_bands()`. |

## Setup

**Requirements:** R ≥ 4.1 and a free OpenRouteService API key ([sign up](https://openrouteservice.org/dev/#/signup)). The `sf` package needs the system GDAL/GEOS/PROJ libraries; see the [sf installation notes](https://r-spatial.github.io/sf/#installing) if installation fails.

```r
install.packages(c("shiny", "bslib", "leaflet", "sf", "httr", "jsonlite", "osmdata", "callr"))
```

**Add your API key.** The key is read from the `ORS_API_KEY` environment variable and is never stored in the code.

```bash
cp .Renviron.example .Renviron   # then edit .Renviron and paste your key
```

Restart R from the project root so `.Renviron` is loaded (or open `isochrone-accessibility-app.Rproj` in RStudio), then run:

```r
shiny::runApp("app")
```

## Usage

1. **Set an origin** by clicking the map or searching an address.
2. **Enter isochrone times** in minutes, comma-separated (default `5, 10, 15`).
3. **Choose travel mode(s).**
4. **Pick amenities** from the presets, or type a custom OSM `key=value` tag.
5. Press **Generate map**, toggle layers as needed, then **Download .gpkg**.

The map opens on Santiago de Compostela, Galicia, but the app works anywhere OpenStreetMap and ORS have coverage.

## Notes and limitations

- It relies on free public services (ORS, Nominatim, Overpass), so it is subject to their rate limits and usage policies. It is meant for interactive, small-scale use rather than bulk analysis.
- Amenity completeness depends on OpenStreetMap coverage in the area.
- Isochrones come from ORS's road and path network and default settings; no custom routing graph is used.
- There is no automated test suite yet, and the app is not deployed to a public URL.

## Related work

- [isochrone-accessibility-maps](https://github.com/madelinelebreton/isochrone-accessibility-maps): accessibility analysis for Porto Alegre using H3 hexagonal grids and isochrones.
- [amenity-filtering](https://github.com/madelinelebreton/amenity-filtering): extracting and filtering OSM amenities from `.osm.pbf` files with PyOsmium into GIS-ready formats.

## Author

Madeline LeBreton, Mechatronics Engineering, McMaster University. Work focused on geospatial analysis and data visualization for architecture and territorial research.

## License

[MIT](LICENSE)

Map data © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors. Routing by [OpenRouteService](https://openrouteservice.org). Basemap © [CARTO](https://carto.com/attributions).
