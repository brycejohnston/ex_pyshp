defmodule ExPyshp.Python.Writer do
  @moduledoc """
  Embedded Python helpers for writing shapefiles.

  The writer checks geometry and field values, uses the same attribute order
  for every record, and writes projection and encoding companions. By default,
  it reopens completed files to check geometry, holes and attribute precision.

  `ExPyshp.Runtime` executes the source from `code/0`. Applications use
  `ExPyshp.write/4`.
  """

  @code ~S'''
  import codecs
  import datetime
  from decimal import Decimal
  from pathlib import Path

  import shapefile
  from pyproj import CRS
  from shapely.geometry import mapping, shape


  def field_definitions(records, options):
      """Build DBF fields from all rows and check names, widths and decimal settings."""
      names = sorted({name for record in records for name in record})
      if not names or len(names) > 255:
          raise ValueError("DBF requires between 1 and 255 fields")
      if any(not name.isascii() or len(name.encode("ascii")) > 10 or not name
             or name != name.strip() or any(ord(c) < 32 or ord(c) == 127 for c in name)
             for name in names):
          raise ValueError("DBF field names must be nonempty visible ASCII names of at most 10 bytes, without edge spaces")
      if len({name.casefold() for name in names}) != len(names):
          raise ValueError("DBF field names collide when compared without case")
      overrides = options.get("field_types", {})
      unknown = set(overrides) - set(names)
      if unknown:
          raise ValueError(f"Field overrides name nonexistent columns: {', '.join(sorted(unknown))}")
      fields = []
      for name in names:
          values = [record[name] for record in records if record.get(name) is not None]
          override = overrides.get(name)
          config = override if isinstance(override, dict) else {"type": override}
          kind = config.get("type")
          if kind is None:
              kind = ("boolean" if values and all(isinstance(v, bool) for v in values)
                      else "number" if values and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in values)
                      else "string")
          text_width = max((len(value.encode(options.get("encoding", "utf-8")))
                            for value in values if isinstance(value, str)), default=1)
          definitions = {
              "number": ("N", options.get("numeric_width", 18), options.get("numeric_precision", 3)),
              "integer": ("N", options.get("numeric_width", 18), 0),
              "string": ("C", text_width, 0), "boolean": ("L", 1, 0), "date": ("D", 8, 0),
          }
          if kind not in definitions:
              raise ValueError(f"Unsupported DBF type for {name}: {kind}")
          code, default_width, default_decimals = definitions[kind]
          width = config.get("width", default_width)
          decimals = config.get("decimals", default_decimals)
          maximum_width = 254 if code == "C" else 32 if code == "N" else default_width
          if isinstance(width, bool) or not isinstance(width, int) or not 1 <= width <= maximum_width:
              raise ValueError(f"Invalid DBF width for {name}")
          if isinstance(decimals, bool) or not isinstance(decimals, int) or not 0 <= decimals <= 15:
              raise ValueError(f"Invalid DBF decimals for {name}")
          if ((code != "N" and decimals != 0)
                  or (code == "N" and width < decimals + (2 if decimals else 1))):
              raise ValueError(f"DBF width/decimals do not fit {name}")
          if code in ("L", "D") and width != default_width:
              raise ValueError(f"DBF width for {name} must be {default_width}")
          fields.append((name, code, width, decimals))
      if 1 + sum(field[2] for field in fields) > 4000:
          raise ValueError("DBF record width exceeds the portable 4000-byte limit")
      return fields


  def attribute_value(value, field, encoding):
      """Prepare one DBF value, rejecting text truncation and numeric overflow."""
      name, kind, width, decimals = field
      if value is None:
          return None
      if kind == "C":
          if not isinstance(value, str):
              raise ValueError(f"{name} needs text; use an explicit numeric/boolean/date field")
          if len(value.encode(encoding)) > width:
              raise ValueError(f"Text value exceeds the {width}-byte width of {name}")
          # pyshp strips trailing whitespace and null bytes when reading DBF text.
          if value != value.rstrip() or "\x00" in value:
              raise ValueError(f"{name} contains trailing whitespace or a null byte that DBF cannot preserve")
          return value
      if kind == "N":
          if isinstance(value, bool):
              raise ValueError(f"Boolean value cannot be written as {name}")
          number = Decimal(str(value))
          if not number.is_finite():
              raise ValueError(f"{name} must contain a finite number")
          if decimals == 0 and number != number.to_integral_value():
              raise ValueError(f"{name} is an integer field but contains a fractional value")
          formatted = format(number, f".{decimals}f")
          if len(formatted) > width:
              raise ValueError(f"Numeric value overflows the {width}-byte width of {name}")
          return int(number) if decimals == 0 else number
      if kind == "L":
          if not isinstance(value, bool):
              raise ValueError(f"{name} must contain true, false or nil")
          return value
      return datetime.date.fromisoformat(value)


  def geometry_type(geometry):
      """Return the shapefile family for a valid, nonempty two-dimensional geometry."""
      families = {"Point": shapefile.POINT, "MultiPoint": shapefile.MULTIPOINT,
                  "LineString": shapefile.POLYLINE, "MultiLineString": shapefile.POLYLINE,
                  "Polygon": shapefile.POLYGON, "MultiPolygon": shapefile.POLYGON}
      if geometry.geom_type not in families:
          raise ValueError(f"Unsupported output geometry: {geometry.geom_type}")
      if geometry.has_z or getattr(geometry, "has_m", False):
          raise ValueError("Writing supports XY geometry only; convert Z/M explicitly before writing")
      if geometry.is_empty or not geometry.is_valid:
          raise ValueError("Output geometry must be nonempty and valid")
      return families[geometry.geom_type]


  def verify_shapes(path, rows, geometries, fields, encoding, projection):
      """Reopen written components and compare geometry, field definitions and values."""
      if projection is not None and not CRS.from_wkt(Path(path + ".prj").read_text()).equals(projection, ignore_axis_order=True):
          raise ValueError("Projection changed during file readback")
      if codecs.lookup(Path(path + ".cpg").read_text()).name != encoding:
          raise ValueError("Encoding changed during file readback")
      with shapefile.Reader(path, encoding=encoding) as reader:
          if reader.numRecords != len(rows) or reader.numShapes != len(rows):
              raise ValueError("Record count changed during file readback")
          # The first DBF field is its deletion flag, not a user attribute.
          actual_fields = [tuple(field) for field in reader.fields[1:]]
          if actual_fields != fields:
              raise ValueError("DBF schema changed during file readback")
          for index, (row, geometry, actual) in enumerate(zip(rows, geometries, reader.iterShapeRecords()), 1):
              if not shape(shapefile_geo_interface(actual.shape)).equals(geometry):
                  raise ValueError(f"Geometry or hole changed during readback of record {index}")
              for value, field, delivered in zip(row, fields, actual.record):
                  name, kind, _, decimals = field
                  if kind == "N" and value is not None:
                      # Allow only the rounding implied by the requested decimals.
                      if delivered is None or abs(Decimal(str(delivered)) - Decimal(str(value))) > Decimal(5).scaleb(-decimals - 1):
                          raise ValueError(f"Numeric value changed or lost precision in {name}, record {index}")
                  elif kind == "C":
                      if (value if value is not None else "") != delivered:
                          raise ValueError(f"Text changed or was truncated in {name}, record {index}")
                  elif value != delivered:
                      raise ValueError(f"Attribute changed in {name}, record {index}")


  def write_shapes(payload):
      """Validate rows, write shapefile components and check them before returning."""
      records = [row["record"] for row in payload["data"]]
      geometries = [shape(row["geometry"]) for row in payload["data"]]
      if not records:
          raise ValueError("A shapefile needs at least one complete record")
      kinds = [geometry_type(geometry) for geometry in geometries]
      if len(set(kinds)) != 1:
          raise ValueError("A shapefile cannot mix point, multipoint, line and polygon records")
      options = payload["options"]
      encoding = codecs.lookup(options.get("encoding", "utf-8")).name
      fields = field_definitions(records, options)
      rows = [[attribute_value(record.get(field[0]), field, encoding) for field in fields] for record in records]
      projection = CRS.from_user_input(options["projection_srid"]) if options.get("projection_srid") is not None else None
      projection_wkt = options.get("projection_wkt")
      if projection_wkt:
          declared = CRS.from_user_input(projection_wkt)
          if projection is not None and not projection.equals(declared, ignore_axis_order=True):
              raise ValueError("projection_srid and projection_wkt disagree")
          projection = declared
      srids = {row.get("srid") for row in payload["data"]}
      known_srids = srids - {None}
      if len(known_srids) > 1:
          raise ValueError("Geometry records have conflicting SRIDs; transform coordinates first")
      if projection is None and known_srids:
          if None in srids:
              raise ValueError("Geometry mixes known and unknown SRIDs; provide an explicit output projection")
          projection = CRS.from_epsg(next(iter(known_srids)))
      # Writing declares a projection; it must not relabel different coordinates.
      for row in payload["data"]:
          srid = row.get("srid")
          if srid is not None and projection is not None and not CRS.from_epsg(srid).equals(projection, ignore_axis_order=True):
              raise ValueError("Geometry SRID differs from the output projection; transform coordinates first")
      path = payload["path"]
      with shapefile.Writer(path, shapeType=kinds[0], encoding=encoding) as writer:
          for field in fields:
              writer.field(*field)
          for row, geometry in zip(rows, geometries):
              if geometry.geom_type in ("Polygon", "MultiPolygon"):
                  oriented = oriented_output(mapping(geometry))
                  polygons = oriented["coordinates"] if geometry.geom_type == "MultiPolygon" else [oriented["coordinates"]]
                  writer.poly([ring for polygon in polygons for ring in polygon])
              elif geometry.geom_type == "Point":
                  writer.point(geometry.x, geometry.y)
              elif geometry.geom_type == "MultiPoint":
                  writer.multipoint([list(point.coords[0]) for point in geometry.geoms])
              else:
                  parts = geometry.geoms if geometry.geom_type == "MultiLineString" else [geometry]
                  writer.line([list(part.coords) for part in parts])
              writer.record(*row)
      Path(path + ".cpg").write_text(encoding, encoding="ascii")
      if projection is not None:
          Path(path + ".prj").write_text(projection.to_wkt(version="WKT1_ESRI"), encoding="utf-8")
      if options.get("verify", True):
          verify_shapes(path, rows, geometries, fields, encoding, projection)
      return True

  '''

  @doc """
  Return embedded Python helpers for validating, writing and reopening shapefiles.

  `ExPyshp.Runtime` combines this source with the other Python helpers at compile
  time. Calling this function returns a string; it does not execute Python.
  """
  @spec code() :: String.t()
  def code, do: @code
end
