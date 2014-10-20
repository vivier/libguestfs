(* virt-v2v
 * Copyright (C) 2009-2014 Red Hat Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *)

(** [-i libvirt] when the source is VMware vCenter *)

open Common_gettext.Gettext
open Common_utils

open Types
open Xml
open Utils
open Input_libvirt_other

open Printf

let esx_re = Str.regexp "^\\[\\(.*\\)\\] \\(.*\\)\\.vmdk$"

let session_cookie = ref ""

(* Map an ESX <source/> to a qemu URI using the cURL driver
 * in qemu.  The 'path' will be something like
 *
 *   "[datastore1] Fedora 20/Fedora 20.vmdk"
 *
 * including those literal spaces in the string.
 *
 * XXX Old virt-v2v could also handle snapshots, ie:
 *
 *   "[datastore1] Fedora 20/Fedora 20-NNNNNN.vmdk"
 *
 * XXX Need to handle templates.  The file is called "-delta.vmdk" in
 * place of "-flat.vmdk".
 *)
let rec map_path_to_uri verbose uri scheme server ?readahead path format =
  if not (Str.string_match esx_re path 0) then
    path, format
  else (
    let datastore = Str.matched_group 1 path
    and path = Str.matched_group 2 path in

    (* Get the datacenter. *)
    let datacenter = get_datacenter uri scheme in

    let port =
      match uri.uri_port with
      | 443 -> ""
      | n when n >= 1 -> ":" ^ string_of_int n
      | _ -> "" in

    let url =
      sprintf
        "https://%s%s/folder/%s-flat.vmdk?dcPath=%s&dsName=%s"
        server port
        (uri_quote path) (uri_quote datacenter) (uri_quote datastore) in

    (* If no_verify=1 was passed in the libvirt URI, then we have to
     * turn off certificate verification here too.
     *)
    let sslverify =
      match uri.uri_query_raw with
      | None -> true
      | Some query ->
        (* XXX only works if the query string is not URI-quoted *)
        string_find query "no_verify=1" = -1 in

    (* Now we have to query the server to get the session cookie. *)
    let session_cookie = get_session_cookie verbose scheme uri sslverify url in

    (* Construct the JSON parameters. *)
    let json_params = [
      "file.driver", JSON.String "https";
      "file.url", JSON.String url;
      "file.timeout", JSON.Int 600;
    ] in

    let json_params =
      match readahead with
      | None -> json_params
      | Some readahead ->
        ("file.readahead", JSON.Int readahead) :: json_params in

    let json_params =
      if sslverify then json_params
      else ("file.sslverify", JSON.String "off") :: json_params in

    let json_params =
      match session_cookie with
      | None -> json_params
      | Some cookie -> ("file.cookie", JSON.String cookie) :: json_params in

    if verbose then
      printf "esx: json parameters: %s\n" (JSON.string_of_doc json_params);

    (* Turn the JSON parameters into a 'json:' protocol string.
     * Note this requires qemu-img >= 2.1.0.
     *)
    let qemu_uri = "json: " ^ JSON.string_of_doc json_params in

    (* The libvirt ESX driver doesn't normally specify a format, but
     * the format of the -flat file is *always* raw, so force it here.
     *)
    qemu_uri, Some "raw"
  )

and get_datacenter uri scheme =
  let default_dc = "ha-datacenter" in
  match scheme with
  | "vpx" ->           (* Hopefully the first part of the path. *)
    (match uri.uri_path with
    | None ->
      warning ~prog (f_"esx: URI (-ic parameter) contains no path, so we cannot determine the datacenter name");
      default_dc
    | Some path ->
      let path =
        let len = String.length path in
        if len > 0 && path.[0] = '/' then
          String.sub path 1 (len-1)
        else path in
      let len =
        try String.index path '/' with Not_found -> String.length path in
      String.sub path 0 len
    );
  | "esx" -> (* Connecting to an ESXi hypervisor directly, so it's fixed. *)
    default_dc
  | _ ->                            (* Don't know, so guess. *)
    default_dc

and get_session_cookie verbose scheme uri sslverify url =
  (* Memoize the session cookie. *)
  if !session_cookie <> "" then
    Some !session_cookie
  else (
    let cmd =
      sprintf "curl -s%s%s%s -I %s ||:"
        (if not sslverify then " --insecure" else "")
        (match uri.uri_user with Some _ -> " -u" | None -> "")
        (match uri.uri_user with Some user -> " " ^ quote user | None -> "")
        (quote url) in
    let lines = external_command ~prog cmd in

    let dump_response chan =
      fprintf chan "%s\n" cmd;
      List.iter (fun x -> fprintf chan "%s\n" x) lines
    in

    if verbose then dump_response stdout;

    (* Look for the last HTTP/x.y NNN status code in the output. *)
    let status = ref "" in
    List.iter (
      fun line ->
        let len = String.length line in
        if len >= 12 && String.sub line 0 5 = "HTTP/" then
          status := String.sub line 9 3
    ) lines;
    let status = !status in
    if status = "" then (
      dump_response stderr;
      error (f_"esx: no status code in output of 'curl' command.  Is 'curl' installed?")
    );

    if status = "401" then (
      dump_response stderr;
      if uri.uri_user <> None then
        error (f_"esx: incorrect username or password")
      else
        error (f_"esx: incorrect username or password.  You might need to specify the username in the URI like this: %s://USERNAME@[etc]")
          scheme
    );

    if status = "404" then (
      dump_response stderr;
      error (f_"esx: URL not found: %s") url
    );

    if status <> "200" then (
      dump_response stderr;
      error (f_"esx: invalid response from server")
    );

    (* Get the cookie. *)
    List.iter (
      fun line ->
        let len = String.length line in
        if len >= 12 && String.sub line 0 12 = "Set-Cookie: " then (
          let line = String.sub line 12 (len-12) in
          let cookie, _ = string_split ";" line in
          session_cookie := cookie
        )
    ) lines;
    if !session_cookie = "" then (
      dump_response stderr;
      warning ~prog (f_"esx: could not read session cookie from the vCenter Server, conversion may consume all sessions on the server and fail part way through");
      None
    )
    else
      Some !session_cookie
  )

(* Subclass specialized for handling VMware vCenter over https. *)
class input_libvirt_vcenter_https
  verbose libvirt_uri parsed_uri scheme server guest =
object
  inherit input_libvirt verbose libvirt_uri guest

  val mutable mapf = fun ?readahead uri format -> uri, format
  val saved_uri = Hashtbl.create 13

  method source () =
    if verbose then printf "input_libvirt_vcenter_https: source()\n%!";

    error_if_libvirt_backend ();

    (* Get the libvirt XML.  This also checks (as a side-effect)
     * that the domain is not running.  (RHBZ#1138586)
     *)
    let xml = Domainxml.dumpxml ?conn:libvirt_uri guest in
    let { s_disks = disks } as source =
      Input_libvirtxml.parse_libvirt_xml ~verbose xml in

    (* Save the mapf function and the original s_qemu_uri fields, so
     * we can get them in the adjust_overlay_parameters method below.
     *)
    mapf <- map_path_to_uri verbose parsed_uri scheme server;
    List.iter (
      fun disk ->
        Hashtbl.add saved_uri disk.s_disk_id (disk.s_qemu_uri, disk.s_format)
    ) disks;

    let disks = List.map (
      fun ({ s_qemu_uri = uri; s_format = format } as disk) ->
        let uri, format = mapf uri format in
        { disk with s_qemu_uri = uri; s_format = format }
    ) disks in

    { source with s_disks = disks }

  (* See RHBZ#1151033 and RHBZ#1153589 for why this is necessary. *)
  method adjust_overlay_parameters overlay =
    let orig_uri, orig_format =
      try Hashtbl.find saved_uri overlay.ov_source.s_disk_id
      with Not_found -> failwith "internal error in adjust_overlay_parameters" in
    let backing_file, _ =
      mapf ~readahead:(64 * 1024 * 1024) orig_uri orig_format in

    (* Rebase the qcow2 overlay to adjust the readahead parameter. *)
    let cmd =
      sprintf "qemu-img rebase -u -b %s %s"
        (quote backing_file) (quote overlay.ov_overlay_file) in
    if verbose then printf "%s\n%!" cmd;
    if Sys.command cmd <> 0 then
      warning ~prog (f_"qemu-img rebase failed, see earlier errors")
end

let input_libvirt_vcenter_https = new input_libvirt_vcenter_https