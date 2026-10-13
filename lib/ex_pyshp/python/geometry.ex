defmodule ExPyshp.Python.Geometry do
  @moduledoc """
  Embedded Python helpers for polygon borders and holes.

  The helpers check ring direction accurately enough to retain very thin
  polygons and small holes. Writing uses clockwise outside borders and
  counterclockwise holes, preserving the original coordinates.

  `ExPyshp.Runtime` combines the source from `code/0` with the reader and writer.
  """

  @code ~S'''
  """Check polygon ring direction without moving vertices or removing parts."""

  import math
  from decimal import Decimal, localcontext

  import shapefile
  from shapely.geometry import Polygon


  def ring_signed_area(ring):
      """Return twice the signed area, retaining the sign under cancellation."""
      x0, y0 = ring[0][:2]
      products = [
          ((a[0] - x0) * (b[1] - y0), (b[0] - x0) * (a[1] - y0))
          for a, b in zip(ring, ring[1:])
      ]
      area = math.fsum(left - right for left, right in products)
      # Thin rings can lose their direction through floating-point cancellation.
      # Recalculate from the exact stored doubles instead of changing the vertices.
      if abs(area) <= math.fsum(abs(left) + abs(right) for left, right in products) * 1e-14:
          with localcontext() as context:
              context.prec = 80
              points = [
                  (Decimal.from_float(float(p[0])), Decimal.from_float(float(p[1])))
                  for p in ring
              ]
              dx, dy = points[0]
              area = sum(
                  (x - dx) * (ny - dy) - (nx - dx) * (y - dy)
                  for (x, y), (nx, ny) in zip(points, points[1:])
              )
      return area


  def clockwise_ring(ring, clockwise):
      """Reverse a ring only when needed to give it the requested direction."""
      area = ring_signed_area(ring)
      if area == 0:
          raise ValueError("Polygon ring has no area")
      return list(reversed(ring)) if (area < 0) != clockwise else ring


  def oriented_output(geometry):
      """Give polygon borders clockwise direction and holes counterclockwise direction."""
      multipart = geometry["type"] == "MultiPolygon"
      polygons = geometry["coordinates"] if multipart else [geometry["coordinates"]]
      polygons = [
          [clockwise_ring(ring, index == 0) for index, ring in enumerate(polygon)]
          for polygon in polygons
      ]
      return {
          "type": geometry["type"],
          "coordinates": polygons if multipart else polygons[0],
      }


  def shapefile_geo_interface(record):
      """Use stable ring direction when pyshp's area calculation loses precision.

      Otherwise keep pyshp's interpretation. With multiple shells, attach each hole
      to the smallest containing shell. Preserve orphan rings instead of dropping
      source geometry. This changes ring classification, not topology or coordinates.
      """
      if record.shapeType not in (shapefile.POLYGON, shapefile.POLYGONM, shapefile.POLYGONZ):
          return record.__geo_interface__
      starts = list(record.parts) + [len(record.points)]
      rings = [record.points[a:b] for a, b in zip(starts, starts[1:])]
      if not rings:
          return record.__geo_interface__
      areas = [ring_signed_area(ring) for ring in rings]
      if all((area < 0) == shapefile.is_cw(ring) for ring, area in zip(rings, areas)):
          return record.__geo_interface__

      exteriors = [ring for ring, area in zip(rings, areas) if area < 0]
      holes = [ring for ring, area in zip(rings, areas) if area >= 0]
      if len(exteriors) == 1:
          polygons = [[exteriors[0]] + holes]
      elif not exteriors:
          polygons = [[ring] for ring in holes]
      else:
          polygons = [[ring] for ring in exteriors]
          shells = [Polygon(ring) for ring in exteriors]
          for ring in holes:
              hole = Polygon(ring)
              parents = [index for index, shell in enumerate(shells) if shell.covers(hole)]
              if parents:
                  parent = min(parents, key=lambda index: abs(ring_signed_area(exteriors[index])))
                  polygons[parent].append(ring)
              else:
                  polygons.append([ring])
      return {
          "type": "Polygon" if len(polygons) == 1 else "MultiPolygon",
          "coordinates": polygons[0] if len(polygons) == 1 else polygons,
      }
  '''

  @doc """
  Return embedded Python helpers for polygon ring direction and hole assignment.

  `ExPyshp.Runtime` combines this source with the other Python helpers at compile
  time. Calling this function returns a string; it does not execute Python.
  """
  @spec code() :: String.t()
  def code, do: @code
end
