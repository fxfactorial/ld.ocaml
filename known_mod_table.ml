(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)

(* refer to all the std modules linked into ld_ocaml, so we can extract the
 * information automatically and create known module table *)

module Dynlink = Dynlink
module Str = Str
module Unix = Unix
module UnixLabels = UnixLabels
module Pervasives = Pervasives
module CamlinternalLazy = CamlinternalLazy
module CamlinternalOO = CamlinternalOO

(* thread *)
module Condition = Condition
module Event = Event
module Mutex = Mutex
module Thread = Thread
module ThreadUnix = Unix

(* stdlib *)
module Arg = Arg
module Array = Array
module ArrayLabels = ArrayLabels
module Buffer = Buffer
module Callback = Callback
module Char = Char
module Complex = Complex
module Digest = Digest
module Filename = Filename
module Format = Format
module Gc = Gc
module Genlex = Genlex
module Hashtbl = Hashtbl
module Int32 = Int32
module Int64 = Int64
module Lazy = Lazy
module Lexing = Lexing
module List = List
module ListLabels = ListLabels
module Map = Map
module Marshal = Marshal
module MoreLabels = MoreLabels
module Nativeint = Nativeint
module Oo = Oo
module Parsing = Parsing
module Printexc = Printexc
module Printf = Printf
module Queue = Queue
module Random = Random
module Scanf = Scanf
module Set = Set
module Sort = Sort
module Stack = Stack
module StdLabels = StdLabels
module Stream = Stream
module String = String
module StringLabels = StringLabels
module Sys = Sys
module Weak = Weak
