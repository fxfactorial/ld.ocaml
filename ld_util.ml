open Printf
open Ld_header

let debug = ref true

external ld_extract_headers : string -> string = "ld_extract_headers"

let readfile file =
  let b = Buffer.create 13 in
  let buf = String.create 1024 in
  let ic = open_in file in
  let rec loop () = match input ic buf 0 1024 with
      0 -> close_in ic; Buffer.contents b
    | n -> Buffer.add_substring b buf 0 n; loop ()
  in loop ()

let matches re s =
  try
    ignore (Str.search_forward re s 0); true
  with Not_found -> false

let finally fin f x = try let y = f x in fin (); y with e -> fin (); raise e

let manual_header_extraction filename =
  let rec data_section_offset ic = match input_line ic with
      l when matches (Str.regexp "\\.data") l -> begin
        match Str.split (Str.regexp "[ \t]+") l with
            _::_::_::off::_ -> Scanf.sscanf off "%x" (fun n -> n)
          | _ -> failwith "Couldn't find .data offset"
      end
    | _ -> data_section_offset ic in

  let rec header_offset ic = match input_line ic with
      l when matches (Str.regexp "caml_plugin_header") l -> begin
        match Str.split (Str.regexp "[ \t]+") l with
            off::_ -> Scanf.sscanf off "%x" (fun n -> n)
          | _ -> failwith "Couldn't find caml_plugin_header symbol."
      end
    | _ -> header_offset ic in

  let ic = Unix.open_process_in (sprintf "objdump -h %S" filename) in
  let data_off = finally (fun () -> close_in ic) data_section_offset ic in
  if !debug then eprintf "Got .data offset: %x\n" data_off;
  let ic = Unix.open_process_in (sprintf "objdump -T %S" filename) in
  let header_off = finally (fun () -> close_in ic) header_offset ic in
  if !debug then eprintf "Got caml_plugin_header offset: %x\n" header_off;
  let actual_off = header_off - data_off in
  let tmp = Filename.temp_file (Filename.basename filename) "_ldocaml" in
    ignore
      (Sys.command
         (sprintf "objcopy -O binary -j .data %S %S" filename tmp));
    let data = readfile tmp in
      Sys.remove tmp;
      String.sub data actual_off (String.length data - actual_off)

let extract_headers file =
  try
    ld_extract_headers file
  with _ -> manual_header_extraction file

let extract_units filename =
  let dll = dll_filename filename in
    try
      let data = extract_headers dll in
      let header : dynheader = Marshal.from_string data 0 in
        if header.magic <> dyn_magic_number then
          failwith (filename ^ " is not an OCaml shared library.");
        header.units
    with
      |  Failure msg ->
          failwith (sprintf "Ld_util.extract_units (%S): %s" filename msg)
      | e ->
          failwith (sprintf "Ld_util.extract_units (%S): %s" filename
                      (Printexc.to_string e))

module DEP =
struct
  type t = string * Digest.t
  let compare = compare
end

module DS = Set.Make(DEP)
module DM = Map.Make(DEP)
module M = Map.Make(String)

type lib = {
  lib_filename : string;
  lib_units : dynunit list;
}

type catalog = {
  cat_intf_map : lib list DM.t;
}

type state = {
  st_libs : lib list;
  st_impls : Digest.t M.t;
  st_intfs : Digest.t M.t;
}

let empty_state = { st_libs = []; st_impls = M.empty; st_intfs = M.empty; }
let empty_catalog = { cat_intf_map = DM.empty }

let hex_to_digest s =
  let digest = String.create 16 in
    for i = 0 to 15 do
      Scanf.sscanf (String.sub s (2*i) 2) "%x" (fun n -> digest.[i] <- char_of_int n)
    done;
    digest

let state_of_known_modules ~known_interfaces ~known_implementations =
  let build_map l =
    List.fold_left
      (fun m (name, hex) -> M.add name (hex_to_digest hex) m)
      M.empty
      l
  in
    {
      st_libs = [];
      st_impls = build_map known_implementations;
      st_intfs = build_map known_interfaces;
    }

let (|>) x f = f x

let add_dep state s d =
  (* FIXME: omit base modules and those in state *)
  (* FIXME: raise Not_found if dep not compatible with those in state *)
  DS.add d s

let check_conflicts deps tbl =
  List.iter
    (fun (name, digest) ->
       if M.mem name tbl && M.find name tbl <> digest then
         raise Not_found)
    deps

let add_lib lib st =
  {
    st_libs = st.st_libs @ [lib];
    st_impls =
      List.fold_left (fun m u -> M.add u.name u.crc m) st.st_impls lib.lib_units;
    st_intfs =
      List.fold_left
        (fun m u ->
           let digest = List.assoc u.name u.imports_cmi in
             M.add u.name digest m)
        st.st_intfs
        lib.lib_units;
  }

let check_lib_conflicts state lib =
  (* see if any of the units is already loaded *)
  List.iter
    (fun u -> if M.mem u.name state.st_intfs then raise Not_found) lib.lib_units

let map_concat f l = List.concat (List.map f l)

let remove_satisfied_deps state cmis =
  List.filter
    (fun (name, digest) ->
       if not (M.mem name state.st_intfs) then true
       else
         if M.find name state.st_intfs = digest then
           false
         else
           raise Not_found)
    cmis

let uniq_deps l = DS.elements (List.fold_left (fun s d -> DS.add d s) DS.empty l)

let update_deps state cmis lib =
  (* remove cmis satisfied by lib from list, add new deps *)
  let state = add_lib lib state in
  let cmis' = map_concat (fun u -> u.imports_cmi) lib.lib_units in
  let cmxs = map_concat (fun u -> u.imports_cmx) lib.lib_units in
    (state, (uniq_deps (remove_satisfied_deps state (cmis @ cmis')), cmxs))

let find_default d k m = try DM.find k m with Not_found -> d

let rec solve_dependencies cat state = function
      [], _ -> (* no cmi deps left *) state
    | (cmi :: rest_cmis) as all_cmis, all_cmxs ->
        check_conflicts all_cmis state.st_intfs;
        check_conflicts all_cmxs state.st_impls;
        match find_default [] cmi cat.cat_intf_map with
            [] ->
              let name, digest = cmi in
                if !debug then
                  eprintf "No implementation found for CMI %s (%s)\n"
                    name (Digest.to_hex digest);
                (* would be  raise Not_found  if all imported CMIs were
                 * guaranteed to be provided by some lib, but some aren't
                 * (e.g. Calendar_sig) since they only contain signatures and
                 * type defs *)
                (* so we just ignore the cmi and hope for the best --- we'll
                 * get a load-time error in the worst case *)
                solve_dependencies cat state (rest_cmis, all_cmxs)
          | l ->
              let rec loop = function
                  [] -> raise Not_found
                | lib :: libs ->
                    try
                      check_lib_conflicts state lib;
                      let state, (cmis, cmxs) = update_deps state all_cmis lib in
                        solve_dependencies cat state (cmis, cmxs)
                    with Not_found -> loop libs
              in loop l

let resolve cat state files =
  let units = map_concat extract_units files in
  (* FIXME: exclusions should be done for each file separately *)
  let exclude_self u = List.filter (fun (name, _) -> name <> u.name) in
  let cmis =
    map_concat (fun u -> exclude_self u u.imports_cmi) units |>
    List.filter (fun (name, digest) -> not (M.mem name state.st_intfs)) in
    (* TODO: check for & signal CMI incompatibilies, otherwise we get them at
     * load time*)
  let cmxs = map_concat (fun u -> exclude_self u u.imports_cmx) units in
    solve_dependencies cat state (uniq_deps cmis, uniq_deps cmxs)

let do_load file =
  try
    Dynlink.loadfile file
  with Dynlink.Error e ->
    printf "Dynlink error when loading %s\n" file;
    print_endline (Dynlink.error_message e);
    exit (-1)

let load_deps solution =
  List.iter (fun lib -> do_load lib.lib_filename) solution.st_libs

let run cat state files =
  let solution = resolve cat state files in
    load_deps solution;
    List.iter do_load files

let is_cmxs s =
  let len = String.length s in
    len >= 5 && String.sub s (len - 5) 5 = ".cmxs"

let subdirs dir =
  try
    let fs = List.map (Filename.concat dir) (Array.to_list (Sys.readdir dir)) in
      List.filter Sys.is_directory fs
  with Sys_error _ -> []

let default_dirs =
  ["."; "/usr/lib/ocaml"; "/usr/local/lib/ocaml"] @
  subdirs "/usr/lib/ocaml" @ subdirs "/usr/local/lib/ocaml"

let build_catalog ?(dirs = default_dirs) () =
  let cmxs_files =
    map_concat
      (fun dir ->
         try
           let files = Array.to_list (Sys.readdir dir) in
             List.map (Filename.concat dir) (List.filter is_cmxs files)
         with Sys_error _ -> [])
      dirs
  in
    List.fold_left
      (fun cat file ->
         try
           if !debug then eprintf "Scanning %s\n" file;
           let units = extract_units file in
           let cmis =
             List.map (fun u -> (u.name, List.assoc u.name u.imports_cmi)) units in
           let lib = { lib_filename = file; lib_units = units; } in
             { cat_intf_map =
                 List.fold_left
                   (fun m intf ->
                      let prev = find_default [] intf m in
                        DM.add intf (lib :: prev) m)
                   cat.cat_intf_map
                   cmis}
         with Failure msg -> eprintf "%s\n%!" msg; cat
           | e -> prerr_endline (Printexc.to_string e); cat)
      empty_catalog
      cmxs_files
