(* virt-v2v
 * Copyright (C) 2009-2021 Red Hat Inc.
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

open Printf
open Unix

open C_utils
open Std_utils
open Tools_utils
open Common_gettext.Gettext
open Xpath_helpers

open Types
open Utils

open Create_libvirt_xml
open Output

let rec libvirt_parse_options options =
  if options.output_password <> None then
    error_option_cannot_be_used_in_output_mode "libvirt" "-op";

  let conn = lazy (Libvirt.Connect.connect ?name:options.output_conn ()) in

  (* -os is the name of the output pool.  It defaults to "default". *)
  let output_pool = Option.default "default" options.output_storage in

  (conn, options.output_alloc, options.output_format, output_pool)

and libvirt_servers dir disks output_name
                    (conn, output_alloc, output_format, output_pool) =
  let conn = Lazy.force conn in

  (* Get the capabilities from libvirt. *)
  let capabilities_xml =
    try Libvirt.Connect.get_capabilities conn
    with
      Libvirt.Virterror { message } ->
      error (f_"cannot get libvirt hypervisor capabilities: %s")
        (Option.default "" message) in
  debug "libvirt capabilities XML:\n%s" capabilities_xml;

  (* This just checks that the capabilities XML is well-formed,
   * early so that we catch parsing errors before conversion.
   *)
  ignore (Xml.parse_memory capabilities_xml);

  (* Does the domain already exist on the target?  (RHBZ#889082) *)
  if Libvirt_utils.domain_exists conn output_name then
    error (f_"a libvirt domain called ‘%s’ already exists on the target.\n\nIf using virt-v2v directly, use the ‘-on’ option to select a different name. Or delete the existing domain on the target using the ‘virsh undefine’ command.\n\nIf using virt-p2v, select a different ‘Name’ in the ‘Target properties’. Or delete the existing domain on the target using the ‘virsh undefine’ command.")
      output_name;

  (* Connect to output libvirt instance and check that the pool exists
   * and dump out its XML.
   *)
  let pool = Libvirt_utils.get_pool conn output_pool in
  let xml = Libvirt.Pool.get_xml_desc (Libvirt.Pool.const pool) in
  let doc = Xml.parse_memory xml in
  let xpathctx = Xml.xpath_new_context doc in
  let xpath_string = xpath_string xpathctx in

  (* We can only output to a pool of type 'dir' (directory). *)
  if xpath_string "/pool/@type" <> Some "dir" then
    error (f_"-o libvirt: output pool ‘%s’ is not a directory (type='dir').  See virt-v2v-output-local(1)") output_pool;
  let target_path =
    match xpath_string "/pool/target/path/text()" with
    | None ->
       error (f_"-o libvirt: output pool ‘%s’ does not have /pool/target/path element.  See virt-v2v-output-local(1)") output_pool
    | Some dir when not (is_directory dir) ->
       error (f_"-o libvirt: output pool ‘%s’ has type='dir' but the /pool/target/path element is not a local directory.  See virt-v2v-output-local(1)") output_pool
    | Some dir -> dir in

  (* Get the name of the pool, since we have to use that
   * (and not the UUID) in the XML of the guest.
   *)
  let pool_name = Libvirt.Pool.get_name (Libvirt.Pool.const pool) in

  (* Set up the NBD servers. *)
  List.iter (
    fun (i, size) ->
      let socket = sprintf "%s/out%d" dir i in
      On_exit.unlink socket;

      (* Create the actual output disk. *)
      let outdisk = target_path // output_name ^ "-sd" ^ (drive_name i) in
      output_to_local_file output_alloc output_format outdisk size socket
  ) disks;

  (capabilities_xml, pool_name)

and libvirt_finalize dir source inspect target_meta
                     (conn, output_alloc, output_format, output_pool)
                     (capabilities_xml, pool_name) =
  (match target_meta.target_firmware with
   | TargetBIOS -> ()
   | TargetUEFI ->
      (* XXX Can remove this method when libvirt supports
       * <loader type="efi"/> since then it will be up to
       * libvirt to check this.
       *)
      error_unless_uefi_firmware target_meta.guestcaps.gcaps_arch
  );

  let conn = Lazy.force conn in

  (* We copied directly into the final pool directory.  However we
   * have to tell libvirt.
   *)
  (try
     let pool = Libvirt_utils.get_pool conn output_pool in
     Libvirt.Pool.refresh (Libvirt.Pool.const pool)
   with
     Libvirt.Virterror { message } ->
     warning (f_"could not refresh libvirt pool ‘%s’: %s")
       output_pool (Option.default "" message)
  );

  (* Parse the capabilities XML in order to get the supported features. *)
  let doc = Xml.parse_memory capabilities_xml in
  let target_features =
    target_features_of_capabilities_doc doc target_meta.guestcaps.gcaps_arch in

  (* Create the metadata. *)
  let doc =
    create_libvirt_xml ~pool:pool_name source inspect target_meta
      target_features
      (fun i -> target_meta.output_name ^ "-sd" ^ (drive_name i))
      output_format in

  let tmpfile, chan = Filename.open_temp_file "v2vlibvirt" ".xml" in
  DOM.doc_to_chan chan doc;
  close_out chan;

  if verbose () then (
    eprintf "resulting XML for libvirt:\n%!";
    DOM.doc_to_chan Stdlib.stderr doc;
    eprintf "\n%!";
  );

  (* Define the domain in libvirt. *)
  (try
     ignore (Libvirt.Domain.define_xml conn (DOM.doc_to_string doc));
     (try Unix.unlink tmpfile with _ -> ())
   with
     Libvirt.Virterror { message } ->
     warning (f_"could not define libvirt domain: %s.\nThe libvirt XML is still available in ‘%s’.  Try running ‘virsh -c %s define %s’ yourself instead.")
       (Option.default "" message) tmpfile
       (Libvirt.Connect.get_uri conn) tmpfile
  )

and arch_is_sane_or_die =
  let rex = PCRE.compile ~caseless:true "^[-_a-z0-9]+$" in
  fun arch -> assert (PCRE.matches rex arch)

and target_features_of_capabilities_doc doc arch =
  let xpathctx = Xml.xpath_new_context doc in
  let expr =
    (* Check the arch is sane.  It comes from untrusted input.  This
     * avoids XPath injection below.
     *)
    arch_is_sane_or_die arch;
    (* NB: Pay attention to the square brackets.  This returns the
     * <guest> nodes!
     *)
    sprintf "/capabilities/guest[arch[@name='%s']/domain/@type='kvm']" arch in
  let obj = Xml.xpath_eval_expression xpathctx expr in

  if Xml.xpathobj_nr_nodes obj < 1 then (
    (* Old virt-v2v used to die here, but that seems unfair since the
     * user has gone through conversion before we reach here.
     *)
    warning (f_"the target hypervisor does not support a %s KVM guest") arch;
    []
  ) else (
    let node (* first matching <guest> *) = Xml.xpathobj_node obj 0 in
    Xml.xpathctx_set_current_context xpathctx node;

    (* Get guest/features/* nodes. *)
    let features = xpath_get_nodes xpathctx "features/*" in
    List.map Xml.node_name features
  )

module Libvirt_ = struct
  type t = string * string

  let setup dir options source =
    if options.output_options <> [] then
      error (f_"no -oo (output options) are allowed here");
    let data = libvirt_parse_options options in
    let output_name = get_output_name options source in
    let disks = get_disks dir in
    libvirt_servers dir disks output_name data

  let finalize dir options source inspect target_meta t =
    let data = libvirt_parse_options options in
    libvirt_finalize dir source inspect target_meta data t

  let query_output_options () =
    printf (f_"No output options can be used in this mode.\n")
end