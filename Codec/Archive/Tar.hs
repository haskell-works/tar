-----------------------------------------------------------------------------
-- |
-- Module      :  Codec.Archive.Tar
-- Copyright   :  (c) 2007 Bjorn Bringert,
--                    2008 Andrea Vezzosi,
--                    2008-2009 Duncan Coutts
-- License     :  BSD3
--
-- Maintainer  :  duncan@haskell.org
-- Portability :  portable
--
-- Reading, writing and manipulating \"@.tar@\" archive files.
--
-- This module uses common names and so is designed to be imported qualified:
--
-- > import qualified Codec.Archive.Tar as Tar
--
-----------------------------------------------------------------------------
module Codec.Archive.Tar (

  -- | Tar archive files are used to store a collection of other files in a
  -- single file. They consists of a sequence of entries. Each entry describes
  -- a file or directory (or some other special kind of file). The entry stores
  -- a little bit of meta-data, in particular the file or directory name.
  --
  -- Unlike some other archive formats, a tar file contains no index. The
  -- information about each entry is stored next to the entry. Because of this,
  -- tar files are almost always processed linearly rather than in a
  -- random-access fashion.
  --
  -- The functions in this module are designed for working on tar files
  -- linearly and lazily. This makes it possible to do many operations in
  -- constant space rather than having to load the entire archive into memory.
  --
  -- It can read and write standard and GNU format tar files and can preserve
  -- all the information in them. The convenience functions that are provided
  -- for creating achive entries are primarily designed for standard portable
  -- archives. If you need to construct GNU format archives or exactly preserve
  -- file ownership and permissions then you will need to write some extra
  -- helper functions.

  -- * High level \"all in one\" operations
  create,
  extract,

  -- ** Compressed tar archives
  -- | Tar files are commonly used in conjuction with gzip compression, as in
  -- \"@.tar.gz@\" or \"@.tar.bz2@\" files. This module does not directly
  -- handle compressed tar files however they can be handled easily by
  -- composing functions from this module and the modules
  -- "Codec.Compression.GZip" or "Codec.Compression.BZip".
  --
  -- Creating a compressed \"@.tar.gz@\" file is just a minor variation on the
  -- 'create' function, but where throw compression into the pipeline:
  --
  -- > BS.writeFile tar . GZip.compress . Tar.write =<< Tar.pack base dir
  --
  -- Similarly, extracting a compressed \"@.tar.gz@\" is just a minor variation
  -- on the 'extract' function where we use decompression in the pipeline:
  --
  -- > Tar.unpack dir . Tar.read . GZip.decompress =<< BS.readFile tar
  --

  -- * Converting between internal and external representation
  read,
  write,

  -- * Packing and unpacking files to\/from internal representation
  pack,
  unpack,

  -- * Checking tarball contents
  checkSecurity,
  checkTarbomb,
--  checkPortability,

  -- * Representation types and utilities
  -- ** Tar entry and associated types
  Entry(..),
  fileName,
  ExtendedHeader(..),
  FileSize,
  FileMode,
  EpochTime,
  UserId,
  GroupId,
  DevMajor,
  DevMinor,
  FileType(..),

  -- ** Constructing simple entry values
  emptyEntry,
  fileEntry,
  directoryEntry,

  -- ** Constructing entries from disk files
  packFileEntry,
  packDirectoryEntry,
  getDirectoryContentsRecursive,

  -- ** Standard file modes
  -- | For maximum portability when constructing archives use only these file
  -- modes.
  ordinaryFileMode,
  executableFileMode,
  directoryFileMode,

  -- ** TarPaths
  TarPath,
  toTarPath,
  fromTarPath,
  fromTarPathToPosixPath,
  fromTarPathToWindowsPath,

  -- ** Sequences of tar entries
  Entries(..),
  mapEntries,
  foldEntries,
  unfoldEntries,

  ) where

import Codec.Archive.Tar.Types

import Codec.Archive.Tar.Read
import Codec.Archive.Tar.Write

import Codec.Archive.Tar.Pack
import Codec.Archive.Tar.Unpack

import Codec.Archive.Tar.Check

import qualified Data.ByteString.Lazy as BS
import Prelude hiding (read)

-- | Create a new @\".tar\"@ file from a directory of files.
--
-- It is equivalent to calling the standard @tar@ program like so:
--
-- @$ tar -f tarball.tar -C base -c dir@
--
-- This assumes a directory @.\/base\/dir@ with files inside, eg
-- @./base/dir/foo.txt@. The file names inside the resulting tar file will be
-- relative to @dir@, eg @dir/foo.txt@.
--
-- This is a high level \"all in one\" operation. Since you may need variations
-- on this function it is instructive to see how it is written. It is just:
--
-- > BS.writeFile tar . Tar.write =<< Tar.pack base dir
--
-- Notes:
--
-- The files in the directory must not change during this operation or the
-- result is not well defined.
--
-- The intention of this function is to create tarballs that are portable
-- between systems. It is /not/ suitable for doing file system backups because
-- file ownership and permissions are not fully preserved. File ownership is
-- not preserved at all. File permissions are set to simple portable values:
--
-- * @rw-r--r--@ for normal files
--
-- * @rwxr-xr-x@ for executable files
--
-- * @rwxr-xr-x@ for directories
--
create :: FilePath  -- ^ Path of the \".tar\" file to write.
       -> FilePath  -- ^ Base directory
       -> FilePath  -- ^ Directory to archive, relative to base dir
       -> IO ()
create tar base dir = BS.writeFile tar . write =<< pack base dir

-- | Extract all the files contained in a @\".tar\"@ file.
--
-- It is equivalent to calling the standard @tar@ program like so:
--
-- @$ tar -x -f tarball.tar -C dir@
--
-- So for example if the @tarball.tar@ file contains @foo/bar.txt@ then this
-- will extract it to @dir/foo/bar.txt@.
--
-- This is a high level \"all in one\" operation. Since you may need variations
-- on this function it is instructive to see how it is written. It is just:
--
-- > Tar.unpack dir . Tar.read =<< BS.readFile tar
--
-- Notes:
--
-- Extracting can fail for a number of reasons. The tarball may be incorrectly
-- formatted. There may be IO or permission errors. In such cases an exception
-- will be thrown and extraction will not continue.
--
-- Since the extraction may fail part way through it is not atomic. For this
-- reason you may want to extract into an empty directory and, if the extraction
-- fails, recursively delete the directory.
--
-- Security: only files inside the target directory will be written. Tarballs
-- containing entries that point outside of the tarball (either absolute paths
-- or relative paths) will be caught and an exception will be thrown.
--
-- Tarbombs: a \"tarbomb\" is a @.tar@ file where not all entries are in a
-- subdirectory but instead files extract into the top level directory. The
-- extract function does not check for these however if you want to do that you
-- can use the 'checkTarbomb' function like so:
--
-- > Tar.unpack dir . Tar.checkTarbomb expectedDir
-- >                . Tar.read =<< BS.readFile tar
--
-- In this case extraction will fail if any file is outside of @expectedDir@.
--
extract :: FilePath -- ^ Destination directory
        -> FilePath -- ^ Tarball
        -> IO ()
extract dir tar = unpack dir . read =<< BS.readFile tar
