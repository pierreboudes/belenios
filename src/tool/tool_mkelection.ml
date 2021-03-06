(**************************************************************************)
(*                                BELENIOS                                *)
(*                                                                        *)
(*  Copyright © 2012-2018 Inria                                           *)
(*                                                                        *)
(*  This program is free software: you can redistribute it and/or modify  *)
(*  it under the terms of the GNU Affero General Public License as        *)
(*  published by the Free Software Foundation, either version 3 of the    *)
(*  License, or (at your option) any later version, with the additional   *)
(*  exemption that compiling, linking, and/or using OpenSSL is allowed.   *)
(*                                                                        *)
(*  This program is distributed in the hope that it will be useful, but   *)
(*  WITHOUT ANY WARRANTY; without even the implied warranty of            *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *)
(*  Affero General Public License for more details.                       *)
(*                                                                        *)
(*  You should have received a copy of the GNU Affero General Public      *)
(*  License along with this program.  If not, see                         *)
(*  <http://www.gnu.org/licenses/>.                                       *)
(**************************************************************************)

open Serializable_builtin_t
open Serializable_j
open Signatures
open Common

module type PARAMS = sig
  val uuid : string
  val group : string
  val template : string
  val get_public_keys : unit -> string array option
  val get_threshold : unit -> string option
end

module type S = sig
  val mkelection : unit -> string
end

module type PARSED_PARAMS = sig
  val uuid : uuid
  val template : template
  module G : GROUP
  val get_public_keys : unit -> G.t trustee_public_key array option
  val get_threshold : unit -> G.t threshold_parameters option
end

let parse_params p =
  let module P = (val p : PARAMS) in
  let module R = struct
    let uuid = uuid_of_raw_string P.uuid
    let template = template_of_string P.template
    module G = (val Group.of_string P.group : GROUP)
    let get_public_keys () =
      match P.get_public_keys () with
      | None -> None
      | Some xs -> Some (Array.map (trustee_public_key_of_string G.read) xs)
    let get_threshold () =
      match P.get_threshold () with
      | None -> None
      | Some t -> Some (threshold_parameters_of_string G.read t)
  end
  in (module R : PARSED_PARAMS)

module Make (P : PARSED_PARAMS) : S = struct
  open P

  (* Setup trustees *)

  let y =
    match get_threshold () with
    | None ->
       let public_keys =
         match get_public_keys () with
         | Some keys -> keys
         | None -> failwith "trustee keys are missing"
       in
       let module K = Trustees.MakeSimple (G) (DirectRandom) in
       K.combine public_keys
    | Some t ->
       let module P = Trustees.MakePKI (G) (DirectRandom) in
       let module C = Trustees.MakeChannels (G) (DirectRandom) (P) in
       let module K = Trustees.MakePedersen (G) (DirectRandom) (P) (C) in
       K.combine t

  (* Setup election *)

  let params = {
    e_description = template.t_description;
    e_name = template.t_name;
    e_public_key = {wpk_group = G.group; wpk_y = y};
    e_questions = template.t_questions;
    e_uuid = uuid;
  }

  (* Generate and serialize election.json *)

  let mkelection () =
    string_of_params (write_wrapped_pubkey G.write_group G.write) params

end

let make params =
  let module P = (val parse_params params : PARSED_PARAMS) in
  let module R = Make (P) in
  (module R : S)
