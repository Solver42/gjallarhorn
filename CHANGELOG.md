## 35

### Added

- Named loops

### Fixed

- Reuse existing daemon when opening a new file
- Hover for procs from imported packages
- Completions for unions and variables from packages
- Go to definition for package-qualified and same-package symbols

## 34

### Fixed

- Gjallarhorn starts when saving a new .odin file
- Handle index in more loop cases
- Resolve types on make and new
- Nested procedures
- Named return values
- Resolve structs defined in the current procedure

## 33

### Added

- Autocomplete for local variables and procedure parameters
- Handle string types in loops
- Handle index in loops
- Resolve variable types

### Changed

- Shortcut for autocomplete is now Ctrl+X Ctrl+O

## 32

### Fixed

- Hover in loops shows correct type
- Hover don't show trailing , and } in struct fields

## Changed

- Vim9 script

## 31

### Added

- Different infered types on same walrus operator
- Infer float, rune, complex number, and quaternion types

### Fixed

- Hover in dirty buffers
- Resolve duplicate names between package-level and local scope

## 30

### Added

- Go to definition for unions
- Hover for unions
- Autocomplete for unions
- Go to definition for global variables
- Multiple field declaration
- #type
- Backtick strings

### Fixed

- Faster parsing on large files
- Lower memory usage during parsing
- Faster completions on large projects

## 29

### Fixed

- Handle string literals containing escape sequences
- Go to definition for local variables

## 28

### Added

- Hover shows constant values

### Fixed

- Handle spaces between colons

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

### Fixed

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
- Hover work for local variables and procedure parameters

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
