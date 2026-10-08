// The operating system's own SQLite: Windows ships it as winsqlite3 (since
// Windows 10, with the header in the Windows SDK); Linux and Apple platforms
// provide sqlite3. Linking is chosen per platform in Package.swift.
#if defined(_WIN32)
#include <winsqlite/winsqlite3.h>
#else
#include <sqlite3.h>
#endif
