## 27

### Fixed

- Handle rune literals

## 26

### Added

- Autocomplete shows source file, struct fields and enum values
- Sort completions
- Current file shown first in completion list

## 25

### Fixed

- Go to definition jumps to the correct line after undo

## 24

### Changed

- Cleaner hovers

### Fixed

- Faster hashing

## 23

### Added

- Hover handles more types

### Fixed

- Go to definition jumps to the correct line

## 22

### Fixed

- Don't break on adding or deleting import aliases
- More robust type parsing

## 21

### Fixed

- Don't suggest removed imports

## 20

### Added

- Show which import
- Index walrus operator declarations

### Fixed

- Aware of switch case
- Can handle spaces between colons

## 19

### Added

- Jumplist

### Fixed

- Autocomplete always works

## 18

### Fixed

- Go to definition for unsaved buffers 

## 17

### Added

- Go to definition for procedures
- Hover for procedures
- Autocomplete for procedures

### Fixed

- Don't leak memory on index rebuild

## 16

### Added

- Autocomplete for pointers

### Fixed

- Start faster

## 15

### Added

- Hover for pointers

## 14

### Fixed

- Autocomplete filter on what you've already entered

## 13

### Fixed

- Improved performance for hover and autocomplete
- Hover and autocomplete work for local variables and proc parameters

## 12

### Fixed

- Faster startup
- Lower memory usage

## 11

### Added

- Go to definition

## 10

### Fixed

- Only re-indexes files that actually changed

## 9

### Fixed

- Better memory management
- Resolve name conflicts between imported packages
- Lexer doesn't hang on broken block comments

## 8

### Added

- Persistent Unix socket for the daemon
- Hover on a variable shows the full struct body

### Removed

- Debugging

## 7

### Added

- Project root detection
- Clean shutdown

### Changed

- K toggles hover

## 6

### Added

- Hover
- Debugging

## 5

### Added

- Cross-file autocomplete within the current directory

## 4

### Added

- Autocomplete for imported libraries
- Autocomplete for type aliases
- MIT license

## 3

### Added

- POSIX-compliant
- Help file

## 2

### Fixed

- Resolve correct type even without a unique name

## 1

### Added

- Autocomplete for enums and structs defined in the current file
