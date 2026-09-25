# Magpie release shrinking rules. Libraries (Media3, Credentials, Coil, AppFunctions,
# coroutines) ship their own consumer rules; add app rules here only for code reached
# by reflection or from outside the app, with a comment saying why.

# Keep readable stack traces in Play's crash reports; upload the mapping file with each bundle.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
