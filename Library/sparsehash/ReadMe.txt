 sparsehash
An extremely memory-efficient hash_map implementation 
An extremely memory-efficient hash_map implementation. 2 bits/entry overhead! The SparseHash library contains several hash-map implementations, including implementations that optimize for space or speed.

These hashtable implementations are similar in API to SGI's hash_map class and the tr1 unordered_map class, but with different performance characteristics. It's easy to replace hash_map or unordered_map by sparse_hash_map or dense_hash_map in C++ code.

They also contain code to serialize and unserialize from disk.

Recent news:
23 Ferbruary 2012

A backwards incompatibility arose from flattening the include headers structure for the <google> folder.

This is now fixed in 2.0.2. You only need to upgrade if you had previously included files from the <google/sparsehash> folder.
1 February 2012

A minor bug related to the namespace switch from google to sparsehash stopped the build from working when perftools is also installed.

This is now fixed in 2.0.1. You only need to upgrade if you have perftools installed.
31 January 2012

I've just released sparsehash 2.0.

The google-sparsehash project has been renamed to sparsehash. I (csilvers) am stepping down as maintainer, to be replaced by the team of Donovan Hide and Geoff Pike. Welcome to the team, Donovan and Geoff! Donovan has been an active contributor to sparsehash bug reports and discussions in the past, and Geoff has been closely involved with sparsehash inside Google (in addition to writing the CityHash hash function). The two of them together should be a formidable force. For good.

I bumped the major version number up to 2 to reflect the new community ownership of the project. All the changes are related to the renaming.

The only functional change from sparsehash 1.12 is that I've renamed the google/ include-directory to be sparsehash/ instead. New code should #include <sparsehash/sparse_hash_map>/etc. I've kept the old names around as forwarding headers to the new, so `#include <google/sparse_hash_map>` will continue to work.

Note that the classes and functions remain in the google C++ namespace (I didn't change that to sparsehash as well); I think that's a trickier transition, and can happen in a future release.
18 January 2011

The google-sparsehash Google Code page has been renamed to sparsehash, in preparation for the project being renamed to sparsehash. In the coming weeks, I'll be stepping down as maintainer for the sparsehash project, and as part of that Google is relinquishing ownership of the project; it will now be entirely community run. The name change reflects that shift.
20 December 2011

I've just released sparsehash 1.12. This release features improved I/O (serialization) support. Support is finally added to serialize and unserialize dense_hash_map/set, paralleling the existing code for sparse_hash_map/set. In addition, the serialization API has gotten simpler, with a single serialize() method to write to disk, and an unserialize() method to read from disk. Finally, support has gotten more generic, with built-in support for both C FILE*s and C++ streams, and an extension mechanism to support arbitrary sources and sinks.

There are also more minor changes, including minor bugfixes, an improved deleted-key test, and a minor addition to the sparsetable API. See the ChangeLog for full details.
23 June 2011

I've just released sparsehash 1.11. The major user-visible change is that the default behavior is improved -- using the hash_map/set is faster -- for hashtables where the key is a pointer. We now notice that case and ignore the low 2-3 bits (which are almost always 0 for pointers) when hashing.

Another user-visible change is we've removed the tests for whether the STL (vector, pair, etc) is defined in the 'std' namespace. gcc 2.95 is the most recent compiler I know of to put STL types and functions in the global namespace. If you need to use such an old compiler, do not update to the latest sparsehash release.

We've also changed the internal tools we use to integrate Googler-supplied patches to sparsehash into the opensource release. These new tools should result in more frequent updates with better change descriptions. They will also result in future ChangeLog entries being much more verbose (for better or for worse).

A full list of changes is described in ChangeLog.
21 January 2011

I've just released sparsehash 1.10. This fixes a performance regression in sparsehash 1.8, where sparse_hash_map would copy hashtable keys by value even when the key was explicitly a reference. It also fixes compiler warnings from MSVC 10, which uses some c++0x features that did not interact well with sparsehash.

There is no reason to upgrade unless you use references for your hashtable keys, or compile with MSVC 10. A full list of changes is described in ChangeLog.
24 September 2010

I've just released sparsehash 1.9. This fixes a size regression in sparsehash 1.8, where the new allocator would take up space in sparse_hash_map, doubling the sparse_hash_map overhead (from 1-2 bits per bucket to 3 or so). All users are encouraged to upgrade.

This change also marks enums as being Plain Old Data, which can speed up hashtables with enum keys and/or values. A full list of changes is described in ChangeLog.
29 July 2010

I've just released sparsehash 1.8 (and 1.8.1 to get rid of a troublesome -Werror flag in the Makefile). This includes improved support for Allocator, including supporting the allocator constructor arg and get_allocator() access method.

To work around a bug in gcc 4.0.x, I've renamed the static variables HT_OCCUPANCY_FLT and HT_SHRINK_FLT to HT_OCCUPANCY_PCT and HT_SHRINK_PCT, and changed their type from float to int. This should not be a user-visible change, since these variables are only used in the internal hashtable classes (sparsehash clients should use max_load_factor() and min_load_factor() instead of modifying these static variables), but if you do access these constants, you will need to change your code.

Internally, the biggest change is a revamp of the test suite. It now has more complete coverage, and a more capable timing tester. There are other, more minor changes as well. A full list of changes is described in the ChangeLog.
31 March 2010

I've just released sparsehash 1.7. The major news here is the addition of Allocator support. Previously, these hashtable classes would just ignore the Allocator template parameter. They now respect it, and even inherit size_type, pointer, etc. from the allocator class. By default, they use a special allocator we provide that uses libc malloc and free to allocate. The hash classes notice when this special allocator is being used, and use realloc when it can. This means that the default allocator is significantly faster than custom allocators are likely to be (since realloc-like functionality is not supported by STL allocators).

There are a few more minor changes as well. A full list of changes is described in the ChangeLog.
11 January 2010

I've just released sparsehash 1.6. The API has widened a bit with the addition of deleted_key() and empty_key(), which let you query what values these keys have. A few rather obscure bugs have been fixed (such as an error when copying one hashtable into another when the empty_keys differ). A full list of changes is described in the ChangeLog.
9 May 2009

I've just released sparsehash 1.5.1. Hot on the heels of sparsehash 1.5, this release fixes a longstanding bug in the sparsehash code, where equal_range would always return an empty range. It now works as documented. All sparsehash users are encouraged to upgrade.
7 May 2009

I've just released sparsehash 1.5. This release introduces tr1 compatibility: I've added rehash, begin(i), and other methods that are expected to be part of the unordered_map API once tr1 in introduced. This allows sparse_hash_map, dense_hash_map, sparse_hash_set, and dense_hash_set to be (almost) drop-in replacements for unordered_map and unordered_set.

There is no need to upgrade unless you need this functionality, or need one of the other, more minor, changes described in the ChangeLog. 