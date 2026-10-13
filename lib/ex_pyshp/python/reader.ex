defmodule ExPyshp.Python.Reader do
  @moduledoc """
  Embedded Python helpers for reading shapefiles.

  The reader pairs attributes with geometry, discovers PRJ/CPG companions and
  transforms known projections to the requested coordinate system. It keeps
  source projection details and Z/M values alongside the returned XY geometry.

  `ExPyshp.Runtime` executes the source from `code/0`. Applications use
  `ExPyshp.read/4` or `ExPyshp.read/5`.
  """

  @code ~S'''
  import codecs
  import datetime
  from pathlib import Path

  import pyproj
  import shapefile
  import shapely
  from pyproj import CRS, Transformer
  from shapely.geometry import mapping, shape


  def sidecar(path, extension):
      """Find a same-stem companion without depending on extension case."""
      source = Path(path)
      matches = [p for p in source.parent.iterdir()
                 if p.is_file() and p.stem.casefold() == source.stem.casefold()
                 and p.suffix.casefold() == extension]
      if len(matches) > 1:
          raise ValueError(f"Multiple {extension} companions for {source.name}")
      return str(matches[0]) if matches else None


  def source_projection(payload):
      """Read the PRJ and explicit source CRS, rejecting conflicting declarations."""
      prj = payload.get("prj")
      supplied = payload.get("source_crs")
      declared = None
      wkt = None
      if prj:
          wkt = Path(prj).read_text(encoding="utf-8-sig").strip()
          try:
              declared = CRS.from_user_input(wkt)
          except pyproj.exceptions.CRSError as error:
              raise ValueError(f"Cannot read projection file {Path(prj).name}: {error}") from error
      explicit = CRS.from_user_input(supplied) if supplied is not None else None
      if declared is not None and explicit is not None and not declared.equals(explicit, ignore_axis_order=True):
          raise ValueError("The source_crs option conflicts with the projection file")
      selected = explicit if explicit is not None else declared
      return selected, wkt or (selected.to_wkt() if selected is not None else None)


  def selected_encoding(payload):
      """Choose the explicit encoding, then the CPG declaration, then UTF-8."""
      selected = payload.get("encoding")
      cpg = payload.get("cpg")
      if selected is None and cpg:
          selected = Path(cpg).read_text(encoding="utf-8-sig").strip()
          # CPG files may contain a Windows code-page number instead of a name.
          if selected.isdigit():
              selected = "utf-8" if selected == "65001" else "cp" + selected
      return codecs.lookup(selected or "utf-8").name


  def read_shapes(payload):
      """Read paired attributes and geometry, transforming XY coordinates when requested."""
      for name in ("shp", "dbf", "shx"):
          if not Path(payload[name]).is_file():
              raise ValueError(f"{name.upper()} file not found: {payload[name]}")
      if payload.get("discover", True):
          if not payload.get("prj"):
              payload["prj"] = sidecar(payload["shp"], ".prj")
          if not payload.get("cpg"):
              payload["cpg"] = sidecar(payload["shp"], ".cpg")
      source, wkt = source_projection(payload)
      target = None
      if source is not None:
          target = CRS.from_user_input(payload.get("target_crs", 4326)) if payload.get("reproject", True) else source
      elif payload.get("target_crs") is not None or payload.get("require_projection", False):
          raise ValueError("The source coordinate system is unknown; provide a .prj file or source_crs")
      transformer = None
      if source is not None and not source.equals(target, ignore_axis_order=True):
          transformer = Transformer.from_crs(source, target, always_xy=True, allow_ballpark=False)
      encoding = selected_encoding(payload)
      result = []
      with shapefile.Reader(shp=payload["shp"], dbf=payload["dbf"], shx=payload["shx"],
                            encoding=encoding, encodingErrors="strict") as reader:
          if reader.numRecords != reader.numShapes:
              raise ValueError("SHP geometry count differs from DBF record count")
          names = [field[0] for field in reader.fields[1:]]
          if len({name.casefold() for name in names}) != len(names):
              raise ValueError("The DBF contains duplicate field names")
          for row in reader.iterShapeRecords():
              original = None if row.shape.shapeType == shapefile.NULL else shapefile_geo_interface(row.shape)
              geometry = original
              if transformer is not None and original is not None:
                  geometry = mapping(shapely.transform(shape(original),
                      lambda x, y: transformer.transform(x, y, errcheck=True), interleaved=False))
              entry = {
                  "record": dict(zip(names, row.record)), "geometry": geometry,
                  "original_geometry": original, "projection_wkt": wkt,
                  "projection_srid": source.to_epsg() if source is not None else None,
                  "geometry_srid": target.to_epsg() if target is not None else None,
                  "geometry_crs": target.to_wkt() if target is not None else None,
                  "encoding": encoding, "shape_type": row.shape.shapeType,
              }
              # pyshp returns XY geometry. Keep source Z/M values separately;
              # the XY coordinate transform does not transform these observations.
              for dimension in ("z", "m"):
                  if hasattr(row.shape, dimension):
                      entry[dimension + "_values"] = list(getattr(row.shape, dimension))
              result.append(entry)
      return result


  def json_value(value):
      """Convert date attributes to ISO strings for the Elixir result."""
      if isinstance(value, (datetime.datetime, datetime.date)):
          return value.isoformat()
      raise TypeError(f"Unsupported attribute value: {type(value).__name__}")

  '''

  @doc """
  Return embedded Python helpers for reading shapefiles, projections and attributes.

  `ExPyshp.Runtime` combines this source with the other Python helpers at compile
  time. Calling this function returns a string; it does not execute Python.
  """
  @spec code() :: String.t()
  def code, do: @code
end
