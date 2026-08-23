# Normalized theme contract

Macarchy publishes the active normalized theme at:

```text
~/.config/macarchy/current/theme.json
```

The `current` symlink and its immutable generation are authoritative. This JSON
is read-only consumer state, not a configuration file. Consumers must not write
it or retain the resolved generation path as the place to watch.

## Schema version 1

Version 1 uses UTF-8 JSON with these top-level fields:

| Field | Meaning |
|---|---|
| `schema_version` | Integer contract version; this document defines `1`. |
| `generation_id` | Opaque identifier for the rendered generation. |
| `theme_id` | Stable package identifier. |
| `appearance` | `dark` or `light`. |
| `semantic` | Theme-neutral desktop roles. |
| `terminal` | Explicit terminal colors, including all 16 ANSI slots. |

All colors are opaque sRGB strings in lowercase `#rrggbb` form. Version 1 may
add fields without changing `schema_version`; consumers must ignore unknown
fields. Removing or changing the meaning/type of a field requires a new schema
version. Consumers should reject versions they do not support rather than
silently guessing.

### Semantic versus terminal colors

Semantic colors describe purpose, not a source palette name:

```text
background, surface, overlay, border,
text, muted_text,
accent, selection,
info, success, warning, error
```

Use them for desktop/application UI. Do not infer ANSI colors from these roles.
The `terminal` object separately defines `foreground`, `background`, `cursor`,
`selection_foreground`, `selection_background`, and an `ansi` array whose
indices are exactly ANSI colors 0 through 15. This explicit separation lets a
theme preserve its intended terminal palette without adding terminal-specific
meanings to the shared desktop vocabulary.

Package-only source swatches, named application mappings, wallpapers, paths,
and adapter/reconciliation state are deliberately excluded.

## Theme package input

A schema-v1 package is one directory containing:

```text
theme.toml
mappings.toml
wallpapers/default.png
LICENSES/wallpaper.md
```

`theme.toml` requires the root keys `schema_version`, `id`, `display_name`, and
`appearance`; all semantic and terminal keys listed above; and a `[wallpaper]`
table with `path`, `source`, `author`, and `license`. The terminal `ansi` array
must contain exactly 16 colors. The wallpaper path is fixed to
`wallpapers/default.png`, must decode as PNG, and may not resolve through a
symlink outside the package.

`mappings.toml` requires `schema_version = 1` and at least one entry under
`[mappings]`. Mapping values are consumer-owned theme names, separate from the
canonical colors.

Theme IDs and mapping keys use lowercase, hyphen-separated identifiers that
start with a letter. Input colors use `#RRGGBB`; rendered colors are normalized
to lowercase. Unknown tables and keys fail validation.

To keep source-located diagnostics deterministic, schema v1 manifests use bare
keys, bare table names, ordinary single-line strings, and the shown multiline
array form. Quoted/dotted keys, quoted table names, inline tables, and multiline
strings are not accepted even when they are otherwise valid TOML.

## Reading and watching

Read `current/theme.json` on launch. Watch the parent directory of `current`,
not the old symlink target, then reopen `current/theme.json` after every event.
Also reread on wake and whenever a watcher is reattached. Macarchy posts the
Darwin notification `io.github.ramtinj95.macarchy.theme-changed` as a
payload-free latency hint. A notification never replaces the filesystem
contract: reopen `current/theme.json` after every hint.

Minimal macOS example:

```swift
import Darwin
import Dispatch
import Foundation

let root = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".config/macarchy", directoryHint: .isDirectory)

func reload() throws {
    let data = try Data(contentsOf: root.appending(path: "current/theme.json"))
    // Decode schema_version first, reject unsupported versions, then repaint.
    print("Read \(data.count) bytes")
}

try reload()
let descriptor = open(root.path, O_EVTONLY)
guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }

let watcher = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: descriptor,
    eventMask: [.write, .rename, .delete],
    queue: .main
)
watcher.setEventHandler {
    do { try reload() } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
}
watcher.setCancelHandler { close(descriptor) }
watcher.resume()
dispatchMain()
```

The standalone fixture consumer in `Tests/Fixtures/ThemeContractConsumer`
decodes this contract using Foundation only:

```sh
swift run theme-contract-consumer path/to/theme.json
```
