# Changelog

## 0.2.0

- Keep polygon holes and small valid pieces intact when reading and writing.
- Use PRJ and CPG files for projections and text encoding.
- Support field types and decimal precision while preserving IDs, missing values and zero.
- Check exported geometry and attributes, and report values that would be cut off.
- Fix ZIP creation, preserve original files and add callbacks for temporary imports and exports.
- Update dependencies, tests, documentation and CI.

### Upgrade from 0.1

- Requires Elixir 1.20 or later.
- `write/3` returns `{:ok, files}` or `{:error, message}`. Use `write/4` for options.
- Numbers and booleans keep their types; numeric-looking strings stay text.
- A known PRJ converts read coordinates to WGS84. Use `reproject: false` to keep the original coordinates. Unknown projections have `srid: nil`.
- Existing output is preserved. Choose a new filename for another export.
- `extract/1` includes PRJ/CPG paths and `extraction_dir`. Use `with_extract` for automatic cleanup.
